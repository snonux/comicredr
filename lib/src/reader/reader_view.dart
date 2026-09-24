import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:comic_analysis/comic_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import 'guided.dart';
import 'layout.dart';
import '../data/progress_store.dart';
import 'page_cache.dart';
import 'reader_notifier.dart';

/// How the page is fitted before any zoom.
enum Fit { page, width, height }

/// The open book on screen: decodes the pages of the current unit through a
/// [PageCache], fits them, and handles zoom and pan. Page turns come from
/// [readerProvider]; view intents arrive through [ReaderViewState.handle].
///
/// Guided view is a camera, not a re-render (design plan section 5): the
/// page stays one image, and an animated transform moves between panels
/// while the rest of the page is dimmed.
class ReaderView extends ConsumerStatefulWidget {
  const ReaderView({super.key});

  @override
  ConsumerState<ReaderView> createState() => ReaderViewState();
}

class ReaderViewState extends ConsumerState<ReaderView> with SingleTickerProviderStateMixin {
  late final _transform = TransformationController()..addListener(_scheduleReport);
  late final _camera = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(_onCameraTick);
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

  /// Auto-trim's cut for each page measured so far in this book.
  final _trims = <int, Trim>{};
  bool _measuring = false;
  int _request = 0;
  Fit _fit = Fit.page;
  Size _viewport = Size.zero;
  Size _content = Size.zero;

  /// The saved zoom and scroll of the book just opened, applied once its
  /// first page is laid out. Nothing is reported back until then, so the
  /// page loading at identity does not overwrite it.
  ViewSpot? _restore;

  /// Decoded-page budget: generous on the laptop, tight on the phone.
  static int get _budget => defaultTargetPlatform == TargetPlatform.android ? 80 << 20 : 512 << 20;

  @override
  void dispose() {
    _disposeImages(_images);
    _cache?.dispose();
    _camera.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _disposeImages(List<ui.Image> images) {
    for (final i in images) {
      i.dispose();
    }
  }

  /// Decode width: the screen's width in pixels, with 1.5x headroom for zoom
  /// on the laptop. The phone decodes at screen width, so its 80 MB budget
  /// holds about ten pages rather than four (a 2610 px scan at full width
  /// is some 20 MB decoded).
  /// In guided view the camera zooms into panels, so pages decode at up to
  /// 2.5x screen width, which is a whole scan at typical sizes.
  int _targetWidth(bool guided) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final headroom = guided ? 2.5 : (defaultTargetPlatform == TargetPlatform.android ? 1.0 : 1.5);
    return (_viewport.width * dpr * headroom).round().clamp(512, 8192);
  }

  /// Loads the pages of [s]'s unit, keeping the old ones on screen until the
  /// new ones are decoded, so a page turn never flashes white.
  void _sync(ReaderState s) {
    final book = s.book;
    if (book == null) return;
    if (!identical(book, _cacheBook)) {
      _cache?.dispose();
      _cache = PageCache(book.doc, budgetBytes: _budget);
      _cacheBook = book;
      _shownUnit = const [];
      _trims.clear();
      _restore = ref.read(readerProvider.notifier).takeRestoredView();
      if (_restore case final r?) _fit = Fit.values.asNameMap()[r.fit] ?? _fit;
    }
    final unit = s.unit;
    if (_listEquals(unit, _shownUnit) || _viewport == Size.zero) return;
    final request = ++_request;
    final cache = _cache!;
    final width = _targetWidth(s.guided);
    Future.wait([for (final p in unit) cache.get(p, width)]).then(
      (images) async {
        // Measured before the swap, so a trimmed page never shows whole first.
        if (ref.read(readerProvider).trim) await _measure(unit, images);
        if (!mounted || request != _request) {
          _disposeImages(images);
          return;
        }
        final old = _images;
        setState(() {
          _images = images;
          _shownUnit = unit;
          _camera.stop();
          _cameraKey = null; // A new page: the camera jumps rather than glides.
          _focus = null;
          _transform.value = Matrix4.identity();
        });
        _disposeImages(old);
        // Warm the next two units and the previous one.
        final n = s.pageCount;
        final mode = s.guided ? PageMode.single : s.mode;
        final ahead1 = stepFrom(unit.last, 1, n, mode, coverAlone: s.coverAlone);
        final ahead2 = stepFrom(unit.last, 2, n, mode, coverAlone: s.coverAlone);
        final behind = stepFrom(unit.first, -1, n, mode, coverAlone: s.coverAlone);
        cache.prefetch({
          ...unitAt(ahead1, n, mode, coverAlone: s.coverAlone),
          ...unitAt(ahead2, n, mode, coverAlone: s.coverAlone),
          ...unitAt(behind, n, mode, coverAlone: s.coverAlone),
        }, width);
      },
      onError: (Object e) {
        if (mounted) ref.read(readerProvider.notifier).notice('Could not decode page ${unit.first + 1}: $e');
      },
    );
  }

  /// Finds the margins of [pages] not measured yet, on a small copy of
  /// each decoded page.
  Future<void> _measure(List<int> pages, List<ui.Image> images) async {
    final book = _cacheBook;
    for (var k = 0; k < pages.length; k++) {
      if (_trims.containsKey(pages[k])) continue;
      Trim trim;
      try {
        trim = await measureTrim(images[k]);
      } catch (e) {
        debugPrint('Could not measure page ${pages[k] + 1} for auto-trim: $e');
        trim = Trim.full;
      }
      // Another book opened meanwhile: its page numbers mean other pages.
      if (!identical(book, _cacheBook)) return;
      _trims[pages[k]] = trim;
    }
  }

  /// `t` on a page already showing: measure it, then lay it out again.
  void _measureShown() {
    if (_measuring) return;
    final unit = _shownUnit;
    if (unit.every(_trims.containsKey)) return;
    _measuring = true;
    final clones = [for (final i in _images) i.clone()];
    _measure(unit, clones).whenComplete(() {
      _disposeImages(clones);
      _measuring = false;
      if (mounted) setState(() {});
    });
  }

  /// The part of shown page [k] (in unit order) to draw.
  Trim _trimOf(ReaderState s, int k) =>
      s.trim && k < _shownUnit.length ? _trims[_shownUnit[k]] ?? Trim.full : Trim.full;

  static bool _listEquals(List<int> a, List<int> b) =>
      a.length == b.length && Iterable.generate(a.length).every((i) => a[i] == b[i]);

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
        _zoom(math.pow(1.25, c.times).toDouble(), at: c.at);
      case ReaderIntent.zoomOut:
        _zoom(math.pow(0.8, c.times).toDouble(), at: c.at);
      case ReaderIntent.zoomReset:
        _transform.value = Matrix4.identity();
      case ReaderIntent.panDown:
        _pan(0.15 * _viewport.height * c.times);
      case ReaderIntent.panUp:
        _pan(-0.15 * _viewport.height * c.times);
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
    final zoom = _scale;
    final t = _transform.value.getTranslation();
    final child = _childSize;
    ref.read(readerProvider.notifier).viewChanged((
      fit: _fit.name,
      zoom: zoom,
      cx: (_viewport.width / 2 - t.x) / (child.width * zoom),
      cy: (_viewport.height / 2 - t.y) / (child.height * zoom),
    ));
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

  /// Points the camera at the focused panel, or back at the whole page, once
  /// the frame is laid out. Within a page the camera glides; onto a new page,
  /// or when the system asks for reduced motion, it cuts.
  void _aimCamera(ReaderState s) {
    final trim = _trimOf(s, 0);
    // Panels are found on the whole page; the page on screen may be trimmed.
    final focus = switch (s.focus) {
      null => null,
      final f => Rect.fromLTWH(
        (f.x - trim.left) / trim.width,
        (f.y - trim.top) / trim.height,
        f.w / trim.width,
        f.h / trim.height,
      ),
    };
    final key = (guided: s.guided, page: s.page, focus: focus, viewport: _viewport, content: _content, trim: trim);
    final last = _cameraKey;
    if (key == last) return;
    final glide =
        last != null &&
        last.page == key.page &&
        last.viewport == key.viewport &&
        !MediaQuery.disableAnimationsOf(context);
    _cameraKey = key;
    final target = Matrix4.identity();
    Rect? hole;
    List<Offset>? shape;
    if (focus != null) {
      final child = _childSize;
      final origin = Offset((child.width - _content.width) / 2, (child.height - _content.height) / 2);
      final rect = Rect.fromLTWH(
        origin.dx + focus.left * _content.width,
        origin.dy + focus.top * _content.height,
        focus.width * _content.width,
        focus.height * _content.height,
      );
      final cam = cameraOn(rect, _viewport);
      target
        ..setTranslationRaw(cam.offset.dx, cam.offset.dy, 0)
        ..scaleByDouble(cam.scale, cam.scale, 1, 1);
      hole = focus;
      final outline = s.focusOutline;
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
  /// panned the page from one that could not move it.
  Matrix4 get transform => _transform.value.clone();

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

  void _pan(double dy) {
    final m = Matrix4.translationValues(0, -dy, 0)..multiply(_transform.value);
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

  Size get _childSize => Size(math.max(_content.width, _viewport.width), math.max(_content.height, _viewport.height));

  /// Natural size of the unit laid side by side at a common height, then
  /// fitted to the viewport. Guided view always starts from the whole page.
  Size _fitted(List<Size> pages, {required bool guided}) {
    if (pages.isEmpty) return Size.zero;
    final h = pages.map((p) => p.height).reduce(math.max);
    final w = pages.fold<double>(0, (sum, p) => sum + p.width * h / p.height);
    final scale = switch (guided ? Fit.page : _fit) {
      Fit.page => math.min(_viewport.width / w, _viewport.height / h),
      Fit.width => _viewport.width / w,
      Fit.height => _viewport.height / h,
    };
    return Size(w * scale, h * scale);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (viewport != _viewport) {
          _viewport = viewport;
          _shownUnit = const []; // Re-decode at the new size.
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _sync(ref.read(readerProvider));
        });
        if (_images.isEmpty) return const Center(child: CircularProgressIndicator());
        if (s.trim) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _measureShown();
          });
        }
        final shown = [for (var k = 0; k < _images.length; k++) (image: _images[k], trim: _trimOf(s, k))];
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
                image: true,
                label: k < numbers.length ? 'Page ${numbers[k] + 1} of ${s.pageCount}' : null,
                child: CustomPaint(
                  key: const Key('page-image'),
                  size: Size(p.image.width * p.trim.width * h / (p.image.height * p.trim.height), h),
                  painter: _PagePainter(p.image, p.trim),
                ),
              ),
          ],
        );
        if (s.guided && _focus != null) {
          pages = Stack(
            children: [
              pages,
              Positioned.fill(
                child: CustomPaint(key: const Key('guided-dim'), painter: _DimPainter(_focus!, _holeShape)),
              ),
            ],
          );
        }
        if (s.night) {
          pages = ColorFiltered(colorFilter: const ColorFilter.matrix(_night), child: pages);
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
            child: Align(
              alignment: !s.guided && _fit == Fit.width ? Alignment.topCenter : Alignment.center,
              child: pages,
            ),
          ),
        );
      },
    );
  }
}

/// A decoded page, drawn with auto-trim's margins cut off.
class _PagePainter extends CustomPainter {
  const _PagePainter(this.image, this.trim);

  final ui.Image image;
  final Trim trim;

  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width.toDouble(), h = image.height.toDouble();
    canvas.drawImageRect(
      image,
      Rect.fromLTRB(trim.left * w, trim.top * h, trim.right * w, trim.bottom * h),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_PagePainter old) => !identical(old.image, image) || old.trim != trim;
}

/// Finds a decoded page's scanned margins, for auto-trim (`t`): the page is
/// drawn 240 px wide, which smooths away paper grain, and its luminance
/// profile read from that.
Future<Trim> measureTrim(ui.Image image) async {
  const w = 240;
  final h = math.max(16, (image.height * w / image.width).round());
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final small = await picture.toImage(w, h);
  picture.dispose();
  final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
  small.dispose();
  return data == null ? Trim.full : findTrim(data.buffer.asUint8List(), w, h);
}

/// Dimmed and warmed, for reading in the dark. A colour matrix costs nothing.
const _night = <double>[
  0.55, 0.10, 0.05, 0, 0, //
  0.05, 0.45, 0.05, 0, 0, //
  0.02, 0.05, 0.30, 0, 0, //
  0, 0, 0, 1, 0,
];

/// The part of [outline] (a frame's real shape, page coordinates) inside
/// [hole], as points relative to [hole]; null when there is no outline and
/// the hole is its rectangle.
List<Offset>? holeShape(Rect hole, List<double>? outline) {
  if (outline == null || hole.isEmpty) return null;
  final clipped = clipConvex(
    [for (var i = 0; i + 1 < outline.length; i += 2) (outline[i], outline[i + 1])],
    [(hole.left, hole.top), (hole.right, hole.top), (hole.right, hole.bottom), (hole.left, hole.bottom)],
  );
  if (clipped.length < 3) return null;
  return [for (final (x, y) in clipped) Offset((x - hole.left) / hole.width, (y - hole.top) / hole.height)];
}

/// Dims the page outside [hole] (page coordinates, 0..1) to 45%, so the
/// panel stands out and the reader keeps their place on the page. With a
/// [shape] (relative to [hole]) the hole is that polygon, so the corners
/// of the neighbours around a slanted panel are dimmed too.
class _DimPainter extends CustomPainter {
  const _DimPainter(this.hole, [this.shape]);

  final Rect hole;
  final List<Offset>? shape;

  @override
  void paint(Canvas canvas, Size size) {
    final page = Offset.zero & size;
    final cut = Rect.fromLTRB(
      hole.left * size.width,
      hole.top * size.height,
      hole.right * size.width,
      hole.bottom * size.height,
    );
    final shape = this.shape;
    final path = shape == null
        ? (Path()..addRect(cut))
        : (Path()..addPolygon([
            for (final p in shape) Offset(cut.left + p.dx * cut.width, cut.top + p.dy * cut.height),
          ], true));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(page), path),
      Paint()..color = const Color(0x8C000000),
    );
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.hole != hole || !listEquals(old.shape, shape);
}
