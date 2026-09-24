import 'dart:async';
import 'dart:ui' as ui;

import 'package:comic_formats/comic_formats.dart';

/// Decoded pages for one open book, least recently used first out, within a
/// byte budget (design plan section 5: about 512 MB on the laptop, 80 MB on
/// the phone).
///
/// Pages decode at [targetWidth] or their own width, whichever is smaller,
/// using Flutter's native decoder, which runs off the UI thread; PDF pages
/// arrive already rendered at that width. [get]
/// returns a clone the caller owns and must dispose; the cache disposes its
/// own copy on eviction, which never invalidates a clone still on screen.
class PageCache {
  PageCache(this.doc, {required this.budgetBytes});

  final ComicDocument doc;
  final int budgetBytes;

  final _images = <(int, int), ui.Image>{}; // Insertion-ordered: oldest first.
  final _inFlight = <(int, int), Future<ui.Image>>{};

  /// In-flight pages only a prefetch asked for. The shared PDF worker
  /// serves newest first, so a prefetch sent before other requests (the
  /// next prefetches, detection) waits behind all of them; a page turned to
  /// must not inherit that wait.
  final _prefetching = <(int, int)>{};
  int _bytes = 0;
  bool _disposed = false;

  int get bytes => _bytes;

  Future<ui.Image> get(int index, int targetWidth) async {
    final image = await _load(index, _bucket(targetWidth), urgent: true);
    return image.clone();
  }

  /// Starts decoding pages the reader is likely to want next.
  void prefetch(Iterable<int> indexes, int targetWidth) {
    for (final i in indexes) {
      if (i >= 0 && i < doc.pageCount) {
        unawaited(_load(i, _bucket(targetWidth)).then((_) {}, onError: (_) {}));
      }
    }
  }

  Future<ui.Image> _load(int index, int width, {bool urgent = false}) {
    final key = (index, width);
    final hit = _images.remove(key);
    if (hit != null) {
      _images[key] = hit; // Move to the most recently used end.
      return Future.value(hit);
    }
    final pending = _inFlight[key];
    if (pending != null && !(urgent && _prefetching.remove(key))) return pending;
    // Asked for again as the newest request, so it goes to the front; the
    // prefetch still lands, and _decode keeps only one copy.
    if (!urgent) _prefetching.add(key);
    late final Future<ui.Image> f;
    // A block body matters here: an arrow would return the removed future,
    // and whenComplete would then wait on the very future it completes.
    f = _decode(index, width).whenComplete(() {
      if (identical(_inFlight[key], f)) {
        _inFlight.remove(key);
        _prefetching.remove(key);
      }
    });
    return _inFlight[key] = f;
  }

  Future<ui.Image> _decode(int index, int width) async {
    // Rendering sources (PDF) draw the page at this width; stored images
    // come back as they are and the codec scales them down.
    final page = await doc.page(index, targetWidth: width, targetHeight: 1 << 16);
    final buffer = await ui.ImmutableBuffer.fromUint8List(page.bytes);
    final descriptor = page.bgra
        ? ui.ImageDescriptor.raw(buffer, width: page.width!, height: page.height!, pixelFormat: ui.PixelFormat.bgra8888)
        : await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec(targetWidth: descriptor.width > width ? width : null);
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (_disposed) {
      // The book closed while this page decoded: hand out a clone and drop ours.
      final clone = image.clone();
      image.dispose();
      return clone;
    }
    // A page asked for twice (a prefetch overtaken by a page turn) is kept
    // once.
    final have = _images[(index, width)];
    if (have != null) {
      image.dispose();
      return have;
    }
    _images[(index, width)] = image;
    _bytes += _size(image);
    _evict();
    return image;
  }

  void _evict() {
    // Keep at least the newest entry, even when one page exceeds the budget.
    while (_bytes > budgetBytes && _images.length > 1) {
      final oldest = _images.keys.first;
      final image = _images.remove(oldest)!;
      _bytes -= _size(image);
      image.dispose();
    }
  }

  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _bytes = 0;
  }

  static int _size(ui.Image image) => image.width * image.height * 4;

  /// Rounds widths up to 256 px steps so small window resizes reuse pages.
  static int _bucket(int width) => ((width + 255) ~/ 256) * 256;
}
