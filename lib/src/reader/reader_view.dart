import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart' show PageRegion;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import '../data/progress_store.dart';
import 'guided.dart';
import 'layout.dart';
import 'page_cache.dart';
import 'page_painters.dart';
import 'reader_notifier.dart';
import 'region.dart';

/// How the page is fitted before any zoom.
enum Fit { page, width, height }

/// The open book on screen: decodes the pages of the current unit through a
/// [PageCache], fits them, and handles zoom and pan. Page turns come from
/// [readerProvider]; view intents arrive through [ReaderViewState.handle].
///
/// Guided view is a camera, not a re-render (design plan section 5): the
/// page stays one image, and an animated transform moves between panels
/// while the rest of the page is dimmed.
///
/// A turned comic (ReaderState.rotation) is the whole view in a
/// [RotatedBox]: everything below lays out, zooms and aims the camera in the
/// turned frame, where the viewport is the screen with its sides swapped for
/// a quarter turn, so guided view, zoom tiles and parts of the page need no
/// rotation maths of their own. Only what comes from the screen (a tapped
/// point) or goes back to it (the transform the touch layer reads) is turned.
///
/// Pages decode at the size they are shown at. Zoomed in past that, by hand
/// or by the guided camera, a sharp tile of just what is on screen is drawn
/// over the page, so memory stays near one screenful however far in the
/// view goes.
class ReaderView extends ConsumerStatefulWidget {
  const ReaderView({super.key});

  @override
  ConsumerState<ReaderView> createState() => ReaderViewState();
}

class ReaderViewState extends ConsumerState<ReaderView> with TickerProviderStateMixin, WidgetsBindingObserver {
  late final _transform = TransformationController()
    ..addListener(_scheduleReport)
    ..addListener(_scheduleTiles);
  late final _camera = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(_onCameraTick);

  /// The cue for a quick step held on a page shown whole
  /// (ReaderState.cue): the page zooms out and back in.
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));

  /// The last [ReaderState.cue] seen; null before the first build, so
  /// opening the reader plays nothing.
  int? _seenCue;
  Matrix4Tween? _cameraTween;
  RectTween? _focusTween;

  /// The dimming hole in page coordinates (0..1), or null for no dimming.
  Rect? _focus;

  /// The hole's real shape when the frame is not a rectangle, as points
  /// relative to [_focus] (0..1 across it), so it glides with the hole.
  List<Offset>? _holeShape;

  /// What the camera last aimed at. A change moves the camera; null makes
  /// it cut to its target on the next frame.
  /// The focus is kept as a Rect, compared by value: a balloon's framing is a
  /// new Panel on every build, and comparing those by identity restarted the
  /// glide each frame, so the camera never reached the balloon.
  ({bool guided, int page, Rect? focus, Size viewport, Size content, Trim trim})? _cameraKey;
  PageCache? _cache;
  Object? _cacheBook;
  List<ui.Image> _images = const [];
  List<int> _shownUnit = const [];
  Box? _shownBox;

  /// Runs once a resize or rotation has settled; until then the pages on
  /// screen are stretched to the new size rather than decoded every frame.
  Timer? _resizeTimer;

  /// Sharp tiles over the shown pages, by page number, while zoomed in.
  Map<int, Tile> _tiles = const {};
  Timer? _tileTimer;
  int _tileGeneration = 0;

  /// Auto-trim's cut for each page measured so far in this book.
  final _trims = <int, Trim>{};

  /// Scan clean-up's levels for each page measured so far in this book.
  final _levels = <int, Levels>{};

  /// Whether the pages on screen came from the cache sharpened (`c`).
  bool _shownSharpened = false;

  /// The pages on screen were just swapped for their sharpened (or plain)
  /// selves: the camera stays where it is, though their size in pixels,
  /// and so the fitted size by a hair, changed.
  bool _keepView = false;
  bool _measuring = false;
  int _request = 0;
  Fit _fit = Fit.page;
  Size _viewport = Size.zero;
  Size _content = Size.zero;

  /// Quarter turns clockwise of the frame last laid out (ReaderState.rotation).
  int _turns = 0;

  /// The saved zoom and scroll of the book just opened, applied once its
  /// first page is laid out. Nothing is reported back until then, so the
  /// page loading at identity does not overwrite it.
  ViewSpot? _restore;

  /// Decoded-page budget: a slice of the device's memory, read once.
  static final int _budget = pageBudgetBytes(
    phone: defaultTargetPlatform == TargetPlatform.android,
    memTotal: readMemTotal(),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// The system is short of memory: keep only what is on screen.
  @override
  void didHaveMemoryPressure() => _cache?.shed(_shownUnit.toSet());

  /// In the background the tiles go too, and come back on return; Android
  /// picks the biggest background apps to kill first.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _cache?.shed(_shownUnit.toSet());
      _clearTiles();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      _scheduleTiles();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resizeTimer?.cancel();
    _tileTimer?.cancel();
    _clearTiles();
    _disposeImages(_images);
    _cache?.dispose();
    _camera.dispose();
    _pulse.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _disposeImages(List<ui.Image> images) {
    for (final i in images) {
      i.dispose();
    }
  }

  void _clearTiles() {
    for (final t in _tiles.values) {
      t.image.dispose();
    }
    _tiles = const {};
    _tileGeneration++; // Tiles still decoding land nowhere.
  }

  /// What each page of a unit of [pages] decodes to fit: the screen in
  /// device pixels, split between the pages side by side, with the side
  /// the fit leaves free unbounded. A 2610 px scan decoded whole is some
  /// 40 MB; fitted to a phone screen it is about 7 MB, and to a laptop
  /// window in fit-page less than that. Guided view starts from the whole
  /// page and zooms with tiles.
  Box _box(bool guided, int pages) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = math.max(64, (_viewport.width * dpr / pages).ceil());
    final h = math.max(64, (_viewport.height * dpr).ceil());
    return switch (guided ? Fit.page : _frameFit) {
      Fit.page => (width: w, height: h),
      Fit.width => (width: w, height: 0),
      Fit.height => (width: 0, height: h),
    };
  }

  /// Loads the pages of [s]'s unit, keeping the old ones on screen until the
  /// new ones are decoded, so a page turn never flashes white.
  void _sync(ReaderState s) {
    final book = s.book;
    if (book == null) return;
    if (!identical(book, _cacheBook)) {
      _cache?.dispose();
      _cache = PageCache(
        book.doc,
        budgetBytes: _budget,
        // A sharpened page is at most 24 MB on the phone, 64 MB on the laptop.
        maxSharpenedPixels: defaultTargetPlatform == TargetPlatform.android ? 6 << 20 : 16 << 20,
      );
      _cacheBook = book;
      _shownUnit = const [];
      _trims.clear();
      _levels.clear();
      _restore = ref.read(readerProvider.notifier).takeRestoredView();
      if (_restore case final r?) _fit = Fit.values.asNameMap()[r.fit] ?? _fit;
    }
    final unit = s.unit;
    if (_viewport == Size.zero) return;
    final box = _box(s.guided, unit.length);
    final sharpen = s.cleanUp;
    final sameUnit = listEquals(unit, _shownUnit);
    // A new size alone waits for the resize to settle.
    if (sameUnit && sharpen == _shownSharpened && (box == _shownBox || (_resizeTimer?.isActive ?? false))) {
      // Back on the shown pages before another unit's decode landed (`G`
      // then `gg`): that decode must not replace them when it does.
      ++_request;
      return;
    }
    final request = ++_request;
    final cache = _cache!;
    _decodeAll(cache, unit, box, sharpen).then(
      (images) async {
        if (!mounted || request != _request) {
          _disposeImages(images);
          return;
        }
        // Measured before the swap, so a trimmed page never shows whole
        // first, nor a cleaned-up page yellow.
        final now = ref.read(readerProvider);
        try {
          if (now.trim || now.cleanUp) await _measure(unit, images, trim: now.trim, levels: now.cleanUp);
        } on Object {
          _disposeImages(images);
          rethrow;
        }
        if (!mounted || request != _request) {
          _disposeImages(images);
          return;
        }
        final old = _images;
        // The same pages sharper or smaller after a resize, or sharpened or
        // not (`c`), keep the view.
        final samePages = listEquals(unit, _shownUnit);
        setState(() {
          _clearTiles();
          _images = images;
          _shownUnit = unit;
          _shownBox = box;
          _shownSharpened = sharpen;
          if (samePages) {
            _keepView = true;
          } else {
            _camera.stop();
            _cameraKey = null; // A new page: the camera jumps rather than glides.
            _focus = null;
            _transform.value = Matrix4.identity();
          }
        });
        _disposeImages(old);
        // The view stayed put, so its sharp tiles come back for the new pages.
        if (samePages) _scheduleTiles();
        // Warm the next two units and the previous one.
        final n = s.pageCount;
        final mode = s.guided ? PageMode.single : s.mode;
        final ahead1 = stepFrom(unit.last, 1, n, mode, coverAlone: s.coverAlone, wide: s.wide);
        final ahead2 = stepFrom(unit.last, 2, n, mode, coverAlone: s.coverAlone, wide: s.wide);
        final behind = stepFrom(unit.first, -1, n, mode, coverAlone: s.coverAlone, wide: s.wide);
        cache.prefetch(
          {
            ...unitAt(ahead1, n, mode, coverAlone: s.coverAlone, wide: s.wide),
            ...unitAt(ahead2, n, mode, coverAlone: s.coverAlone, wide: s.wide),
            ...unitAt(behind, n, mode, coverAlone: s.coverAlone, wide: s.wide),
          },
          box,
          sharpen: sharpen,
        );
      },
      onError: (Object e) {
        if (e is PageCacheClosed || !mounted || request != _request) return;
        ref.read(readerProvider.notifier).notice('Could not decode page ${unit.first + 1}: $e');
      },
    );
  }

  /// Decodes every page of [unit]; if one fails, the others are disposed
  /// before the error goes on, rather than left to leak.
  static Future<List<ui.Image>> _decodeAll(PageCache cache, List<int> unit, Box box, bool sharpen) async {
    final pending = [for (final p in unit) cache.get(p, box, sharpen: sharpen)];
    final images = <ui.Image>[];
    Object? error;
    StackTrace? trace;
    for (final f in pending) {
      try {
        images.add(await f);
      } on Object catch (e, st) {
        error ??= e;
        trace ??= st;
      }
    }
    if (error == null) return images;
    for (final i in images) {
      i.dispose();
    }
    Error.throwWithStackTrace(error, trace!);
  }

  /// Finds the margins ([trim]) and the levels ([levels]) of [pages] not
  /// measured yet, on one small copy of each decoded page.
  Future<void> _measure(List<int> pages, List<ui.Image> images, {required bool trim, required bool levels}) async {
    final book = _cacheBook;
    for (var k = 0; k < pages.length; k++) {
      final wantTrim = trim && !_trims.containsKey(pages[k]);
      final wantLevels = levels && !_levels.containsKey(pages[k]);
      if (!wantTrim && !wantLevels) continue;
      var t = Trim.full;
      var l = Levels.none;
      try {
        final (rgba, w, h) = await smallCopy(images[k]);
        if (wantTrim) t = findTrim(rgba, w, h);
        if (wantLevels) l = findLevels(rgba, w, h);
      } catch (e) {
        debugPrint('Could not measure page ${pages[k] + 1}: $e');
      }
      // Another book opened meanwhile: its page numbers mean other pages.
      if (!identical(book, _cacheBook)) return;
      if (wantTrim) _trims[pages[k]] = t;
      if (wantLevels) _levels[pages[k]] = l;
    }
  }

  /// `t` or `c` on a page already showing: measure it, then lay it out again.
  void _measureShown(ReaderState s) {
    if (_measuring) return;
    final unit = _shownUnit;
    if ((!s.trim || unit.every(_trims.containsKey)) && (!s.cleanUp || unit.every(_levels.containsKey))) return;
    _measuring = true;
    final clones = [for (final i in _images) i.clone()];
    _measure(unit, clones, trim: s.trim, levels: s.cleanUp).whenComplete(() {
      _disposeImages(clones);
      _measuring = false;
      if (mounted) setState(() {});
    });
  }

  /// The part of shown page [k] (in unit order) to draw.
  Trim _trimOf(ReaderState s, int k) =>
      s.trim && k < _shownUnit.length ? _trims[_shownUnit[k]] ?? Trim.full : Trim.full;

  /// The levels shown page [k] (in unit order) is drawn with.
  Levels _levelsOf(ReaderState s, int k) =>
      s.cleanUp && k < _shownUnit.length ? _levels[_shownUnit[k]] ?? Levels.none : Levels.none;

  /// View intents: zoom, fit and pan. Returns false for anything else.
  bool handle(ReaderCommand c) {
    final guided = ref.read(readerProvider).guided;
    switch (c.intent) {
      case ReaderIntent.fitPage when guided:
      case ReaderIntent.zoomReset when guided:
        _recentre(); // zz re-centres the panel in guided view.
      case ReaderIntent.fitWidth:
        _setFit(Fit.width);
      case ReaderIntent.fitHeight:
        _setFit(Fit.height);
      case ReaderIntent.fitPage:
        _setFit(Fit.page);
      case ReaderIntent.zoomIn:
        _zoom(math.pow(1.25, c.times).toDouble(), at: _unturned(c.at));
      case ReaderIntent.zoomOut:
        _zoom(math.pow(0.8, c.times).toDouble(), at: _unturned(c.at));
      case ReaderIntent.zoomReset:
        _transform.value = _home();
      case ReaderIntent.zoomToggle:
        // A double-tap: back out when zoomed (re-centring the panel in
        // guided view), else about 2.4x on the spot tapped.
        if (_scale > 1.01) return handle(const ReaderCommand(ReaderIntent.zoomReset));
        _zoom(math.pow(1.25, 4).toDouble(), at: _unturned(c.at));
      case ReaderIntent.panDown:
        _pan(0.15 * _screen.height * c.times);
      case ReaderIntent.panUp:
        _pan(-0.15 * _screen.height * c.times);
      default:
        return false;
    }
    return true;
  }

  void _setFit(Fit fit) {
    setState(() {
      _fit = fit;
      _transform.value = Matrix4.identity();
      _cameraKey = null;
    });
    _scheduleReport();
  }

  bool _reportScheduled = false;

  /// Reports after the next layout, when the page size matches the transform
  /// (a page turn or a new fit resets the transform before the new layout).
  void _scheduleReport() {
    if (_reportScheduled) return;
    _reportScheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _reportScheduled = false;
        _reportView();
      })
      ..scheduleFrame();
  }

  /// Tells the reader where zoom and scroll are now, for the saved position.
  /// Guided view's camera follows the panel, so there is nothing to keep.
  void _reportView() {
    if (!mounted || _restore != null || _images.isEmpty || _viewport == Size.zero) return;
    final s = ref.read(readerProvider);
    if (s.book == null || s.guided) return;
    ref.read(readerProvider.notifier).viewChanged(_spot());
  }

  /// Where zoom and scroll are now, for tests.
  @visibleForTesting
  ViewSpot get spot => _spot();

  /// Zoom and the point in the middle of the screen, as fractions of the
  /// laid-out page, which stay true when the window changes size.
  ViewSpot _spot() {
    final zoom = _scale;
    final t = _transform.value.getTranslation();
    final child = _childSize;
    return (
      fit: _fit.name,
      zoom: zoom,
      cx: (_viewport.width / 2 - t.x) / (child.width * zoom),
      cy: (_viewport.height / 2 - t.y) / (child.height * zoom),
    );
  }

  /// The window was resized or the phone rotated from [old]. The page is
  /// fitted to the new size at once, keeping the zoom and the point in the
  /// middle of the screen; guided view's camera re-frames its panel by
  /// itself. The pages decode again at the new size once it settles.
  void _resized(Size old, ReaderState s, {bool keepView = true}) {
    if (keepView &&
        old != Size.zero &&
        _images.isNotEmpty &&
        _restore == null &&
        !s.guided &&
        !_transform.value.isIdentity()) {
      final keep = _spot();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !ref.read(readerProvider).guided) _applyRestore(keep);
      });
    }
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _sync(ref.read(readerProvider));
    });
  }

  /// Puts the saved zoom and scroll back: the saved point in the middle of
  /// the screen, clamped to the page as a drag would be.
  void _applyRestore(ViewSpot r) {
    final child = _childSize;
    final zoom = r.zoom.clamp(1.0, 8.0);
    final m = Matrix4.diagonal3Values(zoom, zoom, 1)
      ..setTranslationRaw(
        _viewport.width / 2 - r.cx * child.width * zoom,
        _viewport.height / 2 - r.cy * child.height * zoom,
        0,
      );
    _transform.value = _clamped(m);
  }

  void _recentre() => setState(() => _cameraKey = null);

  /// Points the camera at the focused panel, or the part of the page picked
  /// by hand ([ReaderState.region]), or back at the whole page, once the
  /// frame is laid out. Within a page the camera glides; onto a new page,
  /// or when the system asks for reduced motion, it cuts.
  void _aimCamera(ReaderState s) {
    final trim = _trimOf(s, 0);
    final origin = _origin(s.guided);
    // What to frame, in the child's coordinates, and the dimming hole, as
    // fractions of the shown pages.
    Rect? rect, focus;
    List<double>? outline;
    if (s.region case final r?) {
      for (final p in _pageRects(s)) {
        if (p.page != r.page) continue;
        // Parts are of the page as it is seen, turned or not.
        final part = unturnRect(partRect(r.split, r.part), _turns);
        rect = Rect.fromLTWH(
          p.rect.left + part.left * p.rect.width,
          p.rect.top + part.top * p.rect.height,
          part.width * p.rect.width,
          part.height * p.rect.height,
        );
        focus = Rect.fromLTWH(
          (rect.left - origin.dx) / _content.width,
          (rect.top - origin.dy) / _content.height,
          rect.width / _content.width,
          rect.height / _content.height,
        );
      }
    } else if (s.focus case final f?) {
      // Panels are found on the whole page; the page on screen may be trimmed.
      focus = Rect.fromLTWH(
        (f.x - trim.left) / trim.width,
        (f.y - trim.top) / trim.height,
        f.w / trim.width,
        f.h / trim.height,
      );
      rect = Rect.fromLTWH(
        origin.dx + focus.left * _content.width,
        origin.dy + focus.top * _content.height,
        focus.width * _content.width,
        focus.height * _content.height,
      );
      outline = s.focusOutline;
    }
    final key = (guided: s.guided, page: s.page, focus: focus, viewport: _viewport, content: _content, trim: trim);
    final last = _cameraKey;
    final keep = _keepView;
    _keepView = false;
    if (key == last) return;
    // Outside guided view the camera has nothing to frame unless a part of
    // the page was picked: a resize keeps the reader's own zoom and scroll
    // (_resized). Pages just swapped for their sharpened selves keep the
    // camera in guided view too.
    final kept =
        keep && (last?.guided, last?.page, last?.focus, last?.trim) == (key.guided, key.page, key.focus, key.trim);
    if (last != null &&
        (kept ||
            (!key.guided && !last.guided && key.focus == null && last.focus == null) &&
                last.page == key.page &&
                last.trim == key.trim)) {
      _cameraKey = key;
      return;
    }
    final glide =
        last != null &&
        last.page == key.page &&
        last.viewport == key.viewport &&
        !MediaQuery.disableAnimationsOf(context);
    _cameraKey = key;
    final target = rect == null ? _home() : Matrix4.identity();
    Rect? hole;
    List<Offset>? shape;
    if (rect != null && focus != null) {
      final cam = cameraOn(rect, _viewport);
      target
        ..setTranslationRaw(cam.offset.dx, cam.offset.dy, 0)
        ..scaleByDouble(cam.scale, cam.scale, 1, 1);
      hole = focus;
      // The outline goes into the trimmed page's coordinates too.
      shape = holeShape(hole, switch (outline) {
        null => null,
        final o => [
          for (final (k, v) in o.indexed) k.isEven ? (v - trim.left) / trim.width : (v - trim.top) / trim.height,
        ],
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The sharp tile for where the camera is going starts decoding now,
      // so it is ready about when the glide ends.
      _updateTiles(target);
      if (glide) {
        _cameraTween = Matrix4Tween(begin: _transform.value.clone(), end: target);
        _focusTween = RectTween(
          begin: _focus ?? const Rect.fromLTWH(0, 0, 1, 1),
          end: hole ?? const Rect.fromLTWH(0, 0, 1, 1),
        );
        _holeShape = shape;
        _camera.forward(from: 0);
      } else {
        _camera.stop();
        _transform.value = target;
        setState(() {
          _focus = hole;
          _holeShape = shape;
        });
      }
    });
  }

  void _onCameraTick() {
    final t = Curves.easeInOut.transform(_camera.value);
    _transform.value = _cameraTween!.lerp(t);
    final hole = _focusTween!.lerp(t);
    setState(() {
      // A hole the size of the page means the camera is heading home.
      _focus = _camera.isCompleted && hole == const Rect.fromLTWH(0, 0, 1, 1) ? null : hole;
    });
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  /// Zoom and pan as they are now, for the touch layer to tell a swipe that
  /// panned the page from one that could not move it. On a turned comic the
  /// pan is turned back to the screen's directions, so a sideways drag is
  /// still told by x.
  Matrix4 get transform {
    final m = _transform.value.clone();
    if (_turns == 0) return m;
    final t = m.getTranslation();
    final (x, y) = switch (_turns) {
      1 => (-t.y, t.x),
      2 => (-t.x, -t.y),
      _ => (t.y, -t.x),
    };
    return m..setTranslationRaw(x, y, 0);
  }

  /// A point on the screen (as the touch layer reports it) in the turned
  /// frame the page is laid out in.
  math.Point<double>? _unturned(math.Point<double>? at) {
    if (at == null || _turns == 0) return at;
    final v = _viewport; // The frame; the screen is v with its sides swapped for odd turns.
    return switch (_turns) {
      1 => math.Point(at.y, v.height - at.x),
      2 => math.Point(v.width - at.x, v.height - at.y),
      _ => math.Point(v.width - at.y, at.x),
    };
  }

  /// Zooms by [factor] keeping the point [at] still, or the middle of the
  /// viewport when a key asked.
  void _zoom(double factor, {math.Point<double>? at}) {
    final s = (_scale * factor).clamp(1.0, 8.0);
    final f = s / _scale;
    final c = at != null ? Offset(at.x, at.y) : _viewport.center(Offset.zero);
    final m = Matrix4.translationValues(c.dx, c.dy, 0)
      ..multiply(Matrix4.diagonal3Values(f, f, 1))
      ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0))
      ..multiply(_transform.value);
    _transform.value = _clamped(m);
  }

  /// Moves the view [dy] down the screen, whichever way the comic is turned.
  void _pan(double dy) {
    final (x, y) = switch (_turns) {
      1 => (-dy, 0.0),
      2 => (0.0, dy),
      3 => (dy, 0.0),
      _ => (0.0, -dy),
    };
    final m = Matrix4.translationValues(x, y, 0)..multiply(_transform.value);
    _transform.value = _clamped(m);
  }

  /// Keeps the zoomed content covering the viewport, as dragging does.
  /// Guided view is free to look past the page edge around a panel.
  Matrix4 _clamped(Matrix4 m) {
    if (ref.read(readerProvider).guided) return m;
    final s = m.getMaxScaleOnAxis();
    final child = _childSize;
    final t = m.getTranslation();
    final tx = t.x.clamp(math.min(0.0, _viewport.width - child.width * s), 0.0).toDouble();
    final ty = t.y.clamp(math.min(0.0, _viewport.height - child.height * s), 0.0).toDouble();
    return Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(tx, ty, 0);
  }

  /// Asks for tiles once the view has been still for a moment, so a pinch
  /// or a camera glide decodes once, where it stops.
  void _scheduleTiles() {
    _tileTimer?.cancel();
    _tileTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _updateTiles();
    });
  }

  /// Where each shown page sits in the zoomable child, in display order.
  List<({int page, Rect rect, ui.Image image, Trim trim})> _pageRects(ReaderState s) {
    final origin = _origin(s.guided);
    final top = origin.dy;
    var x = origin.dx;
    final h = _content.height;
    final out = <({int page, Rect rect, ui.Image image, Trim trim})>[];
    final order = [for (var k = 0; k < _images.length && k < _shownUnit.length; k++) k];
    for (final k in s.rightToLeft ? order.reversed : order) {
      final image = _images[k], trim = _trimOf(s, k);
      final w = image.width * trim.width * h / (image.height * trim.height);
      out.add((page: _shownUnit[k], rect: Rect.fromLTWH(x, top, w, h), image: image, trim: trim));
      x += w;
    }
    return out;
  }

  /// Keeps a sharp tile over each page the view at [at] (now, by default)
  /// magnifies past its decoded size: what is on screen plus a margin for
  /// small pans, at screen resolution. In guided view only the panel in
  /// focus, since the rest is dimmed and the camera does not pan. Zoomed
  /// back out, the tiles go.
  void _updateTiles([Matrix4? at]) {
    final cache = _cache;
    if (cache == null || _images.isEmpty || _viewport == Size.zero || _content.isEmpty) return;
    final s = ref.read(readerProvider);
    final m = at ?? _transform.value;
    final scale = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // The screen, in the child's coordinates.
    final seen = Rect.fromLTWH(-t.x / scale, -t.y / scale, _viewport.width / scale, _viewport.height / scale);
    var margin = Rect.fromLTRB(
      seen.left - seen.width * 0.1,
      seen.top - seen.height * 0.1,
      seen.right + seen.width * 0.1,
      seen.bottom + seen.height * 0.1,
    );
    final keep = <int, Tile>{};
    final wanted = <({int page, int fullWidth, PageRegion region})>[];
    for (final p in _pageRects(s)) {
      if (_cameraKey?.focus case final f? when s.guided) {
        // The panel, and a sliver around it for its border.
        final panel = Rect.fromLTWH(
          p.rect.left + f.left * p.rect.width,
          p.rect.top + f.top * p.rect.height,
          f.width * p.rect.width,
          f.height * p.rect.height,
        ).inflate(p.rect.shortestSide * 0.02);
        margin = margin.intersect(panel);
      }
      final visible = seen.intersect(margin).intersect(p.rect);
      if (visible.width <= 0 || visible.height <= 0) continue;
      // Pixels across the whole page, as the screen shows it now, but no
      // more than a stored image has, or twice that enlarged by clean-up.
      final fullWidth = math.min(
        p.rect.width * scale * dpr / p.trim.width,
        (cache.storedWidth(p.page) ?? double.infinity) * (s.cleanUp ? PageCache.maxUpscale : 1),
      );
      if (fullWidth <= p.image.width * 1.2) continue;
      PageRegion toPage(Rect r) => (
        left: p.trim.left + (r.left - p.rect.left) / p.rect.width * p.trim.width,
        top: p.trim.top + (r.top - p.rect.top) / p.rect.height * p.trim.height,
        width: r.width / p.rect.width * p.trim.width,
        height: r.height / p.rect.height * p.trim.height,
      );
      final have = _tiles[p.page];
      if (have != null &&
          _covers(have.region, toPage(visible)) &&
          have.image.width / have.region.width >= fullWidth * 0.85) {
        keep[p.page] = have;
        continue;
      }
      wanted.add((
        page: p.page,
        fullWidth: math.min(fullWidth.ceil(), 1 << 14),
        region: toPage(margin.intersect(p.rect)),
      ));
      if (have != null) keep[p.page] = have; // Blurry beats nothing until the new one lands.
    }
    for (final e in _tiles.entries) {
      if (!keep.containsKey(e.key)) e.value.image.dispose();
    }
    if (_tiles.length != keep.length) setState(() => _tiles = keep);
    _tiles = keep;
    final generation = ++_tileGeneration;
    for (final w in wanted) {
      cache
          .tile(w.page, w.fullWidth, w.region, sharpen: s.cleanUp)
          .then(
            (tile) {
              if (!mounted ||
                  generation != _tileGeneration ||
                  !identical(cache, _cache) ||
                  !_shownUnit.contains(w.page)) {
                tile.image.dispose();
                return;
              }
              final old = _tiles[w.page];
              setState(() => _tiles = {..._tiles, w.page: tile});
              old?.image.dispose();
            },
            onError: (Object e) {
              if (e is! PageCacheClosed) debugPrint('Could not decode a sharp tile of page ${w.page + 1}: $e');
            },
          );
    }
  }

  /// The sharp tiles drawn now, by page number, for tests.
  @visibleForTesting
  Map<int, Tile> get tiles => _tiles;

  static bool _covers(PageRegion outer, PageRegion inner) {
    const slack = 1e-3;
    return outer.left <= inner.left + slack &&
        outer.top <= inner.top + slack &&
        outer.left + outer.width >= inner.left + inner.width - slack &&
        outer.top + outer.height >= inner.top + inner.height - slack;
  }

  /// The screen: the frame with its sides swapped on a quarter turn.
  Size get _screen => _turns.isOdd ? _viewport.flipped : _viewport;

  /// The fit in the turned frame: fitting a comic turned a quarter to the
  /// screen's width fits it to the frame's height.
  Fit get _frameFit => !_turns.isOdd
      ? _fit
      : switch (_fit) {
          Fit.width => Fit.height,
          Fit.height => Fit.width,
          Fit.page => Fit.page,
        };

  /// Where the page sits in the zoomable child when it is smaller than the
  /// screen: fitted to the width, at the top of the screen, else centred.
  Alignment _alignment(bool guided) => guided || _fit != Fit.width
      ? Alignment.center
      : switch (_turns) {
          1 => Alignment.centerLeft,
          2 => Alignment.bottomCenter,
          3 => Alignment.centerRight,
          _ => Alignment.topCenter,
        };

  /// The top-left corner of the laid-out pages in the zoomable child.
  Offset _origin(bool guided) {
    final child = _childSize;
    return _alignment(guided).alongOffset(Offset(child.width - _content.width, child.height - _content.height));
  }

  /// The view a new page, a new fit or a reset starts from: the page's top
  /// left as the screen shows it, which on a turned comic is another corner
  /// of the frame. Upright, no transform at all.
  Matrix4 _home() {
    final child = _childSize;
    final dx = math.min(0.0, _viewport.width - child.width), dy = math.min(0.0, _viewport.height - child.height);
    final (x, y) = switch (_turns) {
      1 => (0.0, dy),
      2 => (dx, dy),
      3 => (dx, 0.0),
      _ => (0.0, 0.0),
    };
    return Matrix4.translationValues(x, y, 0);
  }

  Size get _childSize => Size(math.max(_content.width, _viewport.width), math.max(_content.height, _viewport.height));

  /// Natural size of the unit laid side by side at a common height, then
  /// fitted to the viewport. Guided view always starts from the whole page.
  Size _fitted(List<Size> pages, {required bool guided}) {
    if (pages.isEmpty) return Size.zero;
    final h = pages.map((p) => p.height).reduce(math.max);
    final w = pages.fold<double>(0, (sum, p) => sum + p.width * h / p.height);
    final scale = switch (guided ? Fit.page : _frameFit) {
      Fit.page => math.min(_viewport.width / w, _viewport.height / h),
      Fit.width => _viewport.width / w,
      Fit.height => _viewport.height / h,
    };
    return Size(w * scale, h * scale);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerProvider);
    final still = MediaQuery.disableAnimationsOf(context);
    ref.read(readerProvider.notifier).reduceMotion = still;
    if (s.cue != _seenCue) {
      // Reduced motion: the status line's hint alone.
      if (_seenCue != null && s.cue > _seenCue! && !still) _pulse.forward(from: 0);
      _seenCue = s.cue;
    }
    final view = LayoutBuilder(
      builder: (context, constraints) {
        final turned = _turns != s.rotation;
        if (turned) {
          // A new turn starts the view over, from the page's top left as
          // the screen now shows it, or from the panel in guided view.
          _turns = s.rotation;
          _cameraKey = null;
        }
        final viewport = constraints.biggest;
        if (viewport != _viewport) {
          // Measured against the old size and layout, before they change.
          _resized(_viewport, s, keepView: !turned);
          _viewport = viewport;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _sync(ref.read(readerProvider));
        });
        if (_images.isEmpty) return const Center(child: CircularProgressIndicator());
        if (s.trim || s.cleanUp) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _measureShown(ref.read(readerProvider));
          });
        }
        final shown = [
          for (var k = 0; k < _images.length; k++) (image: _images[k], trim: _trimOf(s, k), levels: _levelsOf(s, k)),
        ];
        final sizes = [for (final p in shown) Size(p.image.width * p.trim.width, p.image.height * p.trim.height)];
        _content = _fitted(sizes, guided: s.guided);
        _aimCamera(s);
        if (_restore case final r? when _shownUnit.contains(s.page)) {
          // After the camera's own post-frame cut, which resets the view.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !identical(_restore, r)) return;
            _restore = null;
            if (!ref.read(readerProvider).guided) _applyRestore(r);
          });
        }
        final ordered = s.rightToLeft ? shown.reversed.toList() : shown;
        final h = _content.height;
        final numbers = s.rightToLeft ? _shownUnit.reversed.toList() : _shownUnit;
        Widget pages = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (k, p) in ordered.indexed)
              Semantics(
                // Its own node, so the page's label is not merged into the
                // status line's.
                container: true,
                image: true,
                label: k < numbers.length ? 'Page ${numbers[k] + 1} of ${s.pageCount}' : null,
                child: CustomPaint(
                  key: const Key('page-image'),
                  size: Size(p.image.width * p.trim.width * h / (p.image.height * p.trim.height), h),
                  painter: PagePainter(p.image, p.trim, p.levels, k < numbers.length ? _tiles[numbers[k]] : null),
                ),
              ),
          ],
        );
        if (_focus != null) {
          pages = Stack(
            children: [
              pages,
              Positioned.fill(
                child: CustomPaint(key: const Key('guided-dim'), painter: DimPainter(_focus!, _holeShape)),
              ),
            ],
          );
        }
        pages = AnimatedBuilder(
          animation: _pulse,
          child: pages,
          // Out to 88% and back, easing at both ends.
          builder: (context, child) => _pulse.isAnimating
              ? Transform.scale(scale: 1 - 0.12 * math.sin(math.pi * _pulse.value), child: child)
              : child!,
        );
        if (s.night) {
          pages = ColorFiltered(colorFilter: const ColorFilter.matrix(nightMatrix), child: pages);
        }
        final child = _childSize;
        return InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: s.guided ? 0.5 : 1,
          // In guided view a one-finger drag is a swipe to the next panel
          // (ReaderTouch); letting it pan too would leave the drag's inertia
          // fighting the camera's glide.
          panEnabled: !s.guided,
          maxScale: 8,
          boundaryMargin: s.guided ? const EdgeInsets.all(double.infinity) : EdgeInsets.zero,
          child: SizedBox(
            width: child.width,
            height: child.height,
            child: Align(alignment: _alignment(s.guided), child: pages),
          ),
        );
      },
    );
    // Upright or turned, the view is laid out in its own frame (see the class).
    return RotatedBox(quarterTurns: s.rotation, child: view);
  }
}
