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
  final _transform = TransformationController();
  late final _camera = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(_onCameraTick);
  Matrix4Tween? _cameraTween;
  RectTween? _focusTween;

  /// The dimming hole in page coordinates (0..1), or null for no dimming.
  Rect? _focus;

  /// What the camera last aimed at. A change moves the camera; null makes
  /// it cut to its target on the next frame.
  ({bool guided, int page, Panel? focus, Size viewport, Size content})? _cameraKey;
  PageCache? _cache;
  Object? _cacheBook;
  List<ui.Image> _images = const [];
  List<int> _shownUnit = const [];
  int _request = 0;
  Fit _fit = Fit.page;
  Size _viewport = Size.zero;
  Size _content = Size.zero;

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
    }
    final unit = s.unit;
    if (_listEquals(unit, _shownUnit) || _viewport == Size.zero) return;
    final request = ++_request;
    final cache = _cache!;
    final width = _targetWidth(s.guided);
    Future.wait([for (final p in unit) cache.get(p, width)]).then(
      (images) {
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

  void _setFit(Fit fit) => setState(() {
    _fit = fit;
    _transform.value = Matrix4.identity();
    _cameraKey = null;
  });

  void _recentre() => setState(() => _cameraKey = null);

  /// Points the camera at the focused panel, or back at the whole page, once
  /// the frame is laid out. Within a page the camera glides; onto a new page,
  /// or when the system asks for reduced motion, it cuts.
  void _aimCamera(ReaderState s) {
    final focus = s.focus;
    final key = (guided: s.guided, page: s.page, focus: focus, viewport: _viewport, content: _content);
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
    if (focus != null) {
      final child = _childSize;
      final origin = Offset((child.width - _content.width) / 2, (child.height - _content.height) / 2);
      final rect = Rect.fromLTWH(
        origin.dx + focus.x * _content.width,
        origin.dy + focus.y * _content.height,
        focus.w * _content.width,
        focus.h * _content.height,
      );
      final cam = cameraOn(rect, _viewport);
      target
        ..setTranslationRaw(cam.offset.dx, cam.offset.dy, 0)
        ..scaleByDouble(cam.scale, cam.scale, 1, 1);
      hole = Rect.fromLTWH(focus.x, focus.y, focus.w, focus.h);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (glide) {
        _cameraTween = Matrix4Tween(begin: _transform.value.clone(), end: target);
        _focusTween = RectTween(
          begin: _focus ?? const Rect.fromLTWH(0, 0, 1, 1),
          end: hole ?? const Rect.fromLTWH(0, 0, 1, 1),
        );
        _camera.forward(from: 0);
      } else {
        _camera.stop();
        _transform.value = target;
        setState(() => _focus = hole);
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
  Size _fitted(List<ui.Image> images, {required bool guided}) {
    if (images.isEmpty) return Size.zero;
    final h = images.map((i) => i.height).reduce(math.max).toDouble();
    final w = images.fold<double>(0, (sum, i) => sum + i.width * h / i.height);
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
        _content = _fitted(_images, guided: s.guided);
        _aimCamera(s);
        final ordered = s.rightToLeft ? _images.reversed.toList() : _images;
        final h = _content.height;
        Widget pages = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final image in ordered)
              RawImage(
                image: image,
                width: image.width * h / image.height,
                height: h,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
              ),
          ],
        );
        if (s.guided && _focus != null) {
          pages = Stack(
            children: [
              pages,
              Positioned.fill(
                child: CustomPaint(key: const Key('guided-dim'), painter: _DimPainter(_focus!)),
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

/// Dimmed and warmed, for reading in the dark. A colour matrix costs nothing.
const _night = <double>[
  0.55, 0.10, 0.05, 0, 0, //
  0.05, 0.45, 0.05, 0, 0, //
  0.02, 0.05, 0.30, 0, 0, //
  0, 0, 0, 1, 0,
];

/// Dims the page outside [hole] (page coordinates, 0..1) to 45%, so the
/// panel stands out and the reader keeps their place on the page.
class _DimPainter extends CustomPainter {
  const _DimPainter(this.hole);

  final Rect hole;

  @override
  void paint(Canvas canvas, Size size) {
    final page = Offset.zero & size;
    final cut = Rect.fromLTRB(
      hole.left * size.width,
      hole.top * size.height,
      hole.right * size.width,
      hole.bottom * size.height,
    );
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(page), Path()..addRect(cut)),
      Paint()..color = const Color(0x8C000000),
    );
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.hole != hole;
}
