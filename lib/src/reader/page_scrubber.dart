import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'guided.dart';
import 'reader_notifier.dart';
import 'thumbnails.dart';

/// How far through the book you are, as a thin bar along the bottom of the
/// page, which also scrubs: drag along it (or hover with the mouse) and a
/// small picture of the page under the finger shows above it, with its
/// number; let go, click or tap to jump there. In fullscreen it is [hidden]
/// until the status line comes back, but still scrubs. In guided view it
/// also moves panel by panel within the page.
///
/// Lay it over the page with [Positioned.fill]: only the band along the
/// bottom takes touches, the rest passes through to the page.
class PageScrubber extends ConsumerStatefulWidget {
  const PageScrubber({super.key, required this.onPick, this.hidden = false});

  final ValueChanged<int> onPick;

  /// Draws nothing and leaves the pointer alone, for fullscreen.
  final bool hidden;

  /// The band along the bottom that takes drags and taps.
  static const band = 28.0;

  @override
  ConsumerState<PageScrubber> createState() => _PageScrubberState();
}

class _PageScrubberState extends ConsumerState<PageScrubber> {
  /// The page under the finger or pointer, and where along the bar it is;
  /// null when nothing is being previewed.
  ({int page, double x})? _at;
  bool _dragging = false;

  /// The picture shown, and the page it is of: while the next one is made
  /// the last one stays, faded, rather than flashing empty.
  ImageProvider? _image;
  int? _imagePage;
  final _used = <ImageProvider>{};

  @override
  void dispose() {
    _evict();
    super.dispose();
  }

  void _evict() {
    for (final i in _used) {
      unawaited(i.evict());
    }
    _used.clear();
  }

  int _pageAt(double x, double width) {
    final n = ref.read(readerProvider).pageCount;
    return (x / width * n).floor().clamp(0, n - 1);
  }

  void _show(double x, double width) {
    if (ref.read(readerProvider).pageCount == 0) return;
    final page = _pageAt(x, width);
    final was = _at?.page;
    setState(() => _at = (page: page, x: x));
    if (page == was) return;
    final thumbs = ref.read(thumbnailsProvider);
    unawaited(
      thumbs?.get(page).then((path) {
        if (path == null || !mounted || _at?.page != page) return;
        final px = (_previewWidth * MediaQuery.devicePixelRatioOf(context)).round();
        final image = ResizeImage(FileImage(File(path)), width: px, policy: ResizeImagePolicy.fit);
        _used.add(image);
        setState(() {
          _image = image;
          _imagePage = page;
        });
      }),
    );
  }

  void _hide() {
    setState(() {
      _at = null;
      _dragging = false;
      _image = null;
      _imagePage = null;
    });
    _evict();
  }

  void _jump(double x, double width) {
    if (ref.read(readerProvider).pageCount == 0) return;
    final page = _pageAt(x, width);
    _hide();
    widget.onPick(page);
  }

  double get _previewWidth => MediaQuery.sizeOf(context).width < 600 ? 110 : 150;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final n = state.pageCount;
    final stops = state.guided ? state.stopsOn(state.page).length : 0;
    final within = stops == 0 || state.panel >= pageEnd ? 1.0 : (state.panelIndex + 1) / stops;
    final read = state.guided ? state.page + within : (state.unit.isEmpty ? 0 : state.unit.last + 1.0);
    final active = _at != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final at = _at;
        final previewW = _previewWidth;
        return Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: PageScrubber.band,
              // A slider to a screen reader: swiping up or down on it
              // turns the page, and it reads out where you are.
              child: Semantics(
                container: true,
                slider: true,
                label: 'Page',
                value: n == 0 ? '' : '${state.page + 1} of $n',
                increasedValue: state.page + 1 < n ? '${state.page + 2} of $n' : null,
                decreasedValue: state.page > 0 ? '${state.page} of $n' : null,
                onIncrease: state.page + 1 < n ? () => widget.onPick(state.page + 1) : null,
                onDecrease: state.page > 0 ? () => widget.onPick(state.page - 1) : null,
                child: MouseRegion(
                  cursor: widget.hidden ? MouseCursor.defer : SystemMouseCursors.click,
                  onHover: (e) => _dragging ? null : _show(e.localPosition.dx, width),
                  onExit: (_) => _dragging ? null : _hide(),
                  child: GestureDetector(
                    key: const Key('scrubber'),
                    excludeFromSemantics: true,
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) {
                      _dragging = true;
                      _show(d.localPosition.dx, width);
                    },
                    onHorizontalDragUpdate: (d) => _show(d.localPosition.dx, width),
                    onHorizontalDragEnd: (_) {
                      final x = _at?.x;
                      x == null ? _hide() : _jump(x, width);
                    },
                    onHorizontalDragCancel: _hide,
                    onTapUp: (d) => _jump(d.localPosition.dx, width),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: widget.hidden && !active
                          ? const SizedBox.shrink()
                          : ExcludeSemantics(
                              child: LinearProgressIndicator(
                                key: const Key('progress'),
                                value: n == 0 ? 0 : (read / n).clamp(0.0, 1.0),
                                minHeight: active ? 6 : 3,
                                backgroundColor: active ? Colors.white24 : Colors.white12,
                                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
            // After the band, so the band keeps its place in the stack and
            // a drag under way is not lost when the preview appears.
            if (at != null)
              Positioned(
                left: (at.x - previewW / 2).clamp(8.0, width - previewW - 8).toDouble(),
                bottom: PageScrubber.band + 4,
                width: previewW,
                child: IgnorePointer(child: _preview(context, at.page, n, previewW)),
              ),
          ],
        );
      },
    );
  }

  Widget _preview(BuildContext context, int page, int n, double w) {
    final theme = Theme.of(context);
    final image = _image;
    return Material(
      key: const Key('scrubPreview'),
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: w,
            height: w * 1.5,
            child: image == null
                ? const Center(child: Icon(Icons.image_outlined, color: Colors.white24))
                : Opacity(
                    opacity: _imagePage == page ? 1 : 0.4,
                    child: Image(image: image, fit: BoxFit.contain, gaplessPlayback: true),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('${page + 1} / $n', key: const Key('scrubPage'), style: theme.textTheme.labelLarge),
          ),
        ],
      ),
    );
  }
}
