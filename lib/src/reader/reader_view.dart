import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import 'layout.dart';
import 'page_cache.dart';
import 'reader_notifier.dart';

/// How the page is fitted before any zoom.
enum Fit { page, width, height }

/// The open book on screen: decodes the pages of the current unit through a
/// [PageCache], fits them, and handles zoom and pan. Page turns come from
/// [readerProvider]; view intents arrive through [ReaderViewState.handle].
class ReaderView extends ConsumerStatefulWidget {
  const ReaderView({super.key});

  @override
  ConsumerState<ReaderView> createState() => ReaderViewState();
}

class ReaderViewState extends ConsumerState<ReaderView> {
  final _transform = TransformationController();
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
  int get _targetWidth {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final headroom = defaultTargetPlatform == TargetPlatform.android ? 1.0 : 1.5;
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
    final width = _targetWidth;
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
          _transform.value = Matrix4.identity();
        });
        _disposeImages(old);
        // Warm the next two units and the previous one.
        final n = s.pageCount;
        final ahead1 = stepFrom(unit.last, 1, n, s.mode, coverAlone: s.coverAlone);
        final ahead2 = stepFrom(unit.last, 2, n, s.mode, coverAlone: s.coverAlone);
        final behind = stepFrom(unit.first, -1, n, s.mode, coverAlone: s.coverAlone);
        cache.prefetch({
          ...unitAt(ahead1, n, s.mode, coverAlone: s.coverAlone),
          ...unitAt(ahead2, n, s.mode, coverAlone: s.coverAlone),
          ...unitAt(behind, n, s.mode, coverAlone: s.coverAlone),
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
    switch (c.intent) {
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
  });

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
  Matrix4 _clamped(Matrix4 m) {
    final s = m.getMaxScaleOnAxis();
    final child = _childSize;
    final t = m.getTranslation();
    final tx = t.x.clamp(math.min(0.0, _viewport.width - child.width * s), 0.0).toDouble();
    final ty = t.y.clamp(math.min(0.0, _viewport.height - child.height * s), 0.0).toDouble();
    return Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(tx, ty, 0);
  }

  Size get _childSize =>
      Size(math.max(_content.width, _viewport.width), math.max(_content.height, _viewport.height));

  /// Natural size of the unit laid side by side at a common height, then
  /// fitted to the viewport.
  Size _fitted(List<ui.Image> images) {
    if (images.isEmpty) return Size.zero;
    final h = images.map((i) => i.height).reduce(math.max).toDouble();
    final w = images.fold<double>(0, (sum, i) => sum + i.width * h / i.height);
    final scale = switch (_fit) {
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
        _content = _fitted(_images);
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
        if (s.night) {
          pages = ColorFiltered(colorFilter: const ColorFilter.matrix(_night), child: pages);
        }
        final child = _childSize;
        return InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: 1,
          maxScale: 8,
          child: SizedBox(
            width: child.width,
            height: child.height,
            child: Align(alignment: _fit == Fit.width ? Alignment.topCenter : Alignment.center, child: pages),
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
