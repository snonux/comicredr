import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/foundation.dart';

/// Decoded pages for one open book, least recently used first out, within a
/// byte budget (design plan section 5: about 512 MB on the laptop, 80 MB on
/// the phone).
///
/// Pages decode at [targetWidth] or their own width, whichever is smaller,
/// using Flutter's native decoder, which runs off the UI thread; PDF pages
/// arrive already rendered at that width. [get]
/// returns a clone the caller owns and must dispose; the cache disposes its
/// own copy on eviction, which never invalidates a clone still on screen.
///
/// Asked to [sharpen] (scan clean-up, `c`), a page with fewer pixels than
/// [targetWidth] is enlarged towards it, at most [maxUpscale] times and to
/// [maxSharpenedPixels], with [upscaleSharpen] in a background isolate. It
/// is cached apart from the page as decoded.
class PageCache {
  PageCache(this.doc, {required this.budgetBytes, this.maxSharpenedPixels = 16 << 20});

  final ComicDocument doc;
  final int budgetBytes;
  final int maxSharpenedPixels;

  static const maxUpscale = 2.0;

  /// Enlarging a page less than this much is not worth the time.
  static const minUpscale = 1.15;

  final _images = <(int, int, bool), ui.Image>{}; // Insertion-ordered: oldest first.
  final _inFlight = <(int, int, bool), Future<ui.Image>>{};

  /// In-flight pages only a prefetch asked for. The shared PDF worker
  /// serves newest first, so a prefetch sent before other requests (the
  /// next prefetches, detection) waits behind all of them; a page turned to
  /// must not inherit that wait.
  final _prefetching = <(int, int, bool)>{};
  int _bytes = 0;
  bool _disposed = false;

  int get bytes => _bytes;

  Future<ui.Image> get(int index, int targetWidth, {bool sharpen = false}) async {
    final image = await _load(index, _bucket(targetWidth), sharpen, urgent: true);
    return image.clone();
  }

  /// Starts decoding pages the reader is likely to want next.
  void prefetch(Iterable<int> indexes, int targetWidth, {bool sharpen = false}) {
    for (final i in indexes) {
      if (i >= 0 && i < doc.pageCount) {
        unawaited(_load(i, _bucket(targetWidth), sharpen).then((_) {}, onError: (_) {}));
      }
    }
  }

  Future<ui.Image> _load(int index, int width, bool sharpen, {bool urgent = false}) {
    final key = (index, width, sharpen);
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
    f = _decode(index, width, sharpen).whenComplete(() {
      if (identical(_inFlight[key], f)) {
        _inFlight.remove(key);
        _prefetching.remove(key);
      }
    });
    return _inFlight[key] = f;
  }

  Future<ui.Image> _decode(int index, int width, bool sharpen) async {
    // Rendering sources (PDF) draw the page at this width; stored images
    // come back as they are and the codec scales them down.
    final page = await doc.page(index, targetWidth: width, targetHeight: 1 << 16);
    final buffer = await ui.ImmutableBuffer.fromUint8List(page.bytes);
    final descriptor = page.bgra
        ? ui.ImageDescriptor.raw(buffer, width: page.width!, height: page.height!, pixelFormat: ui.PixelFormat.bgra8888)
        : await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec(targetWidth: descriptor.width > width ? width : null);
    var image = (await codec.getNextFrame()).image;
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (sharpen) {
      final bigger = await enlarge(image, width, maxPixels: maxSharpenedPixels);
      if (bigger != null) {
        image.dispose();
        image = bigger;
      }
    }
    if (_disposed) {
      // The book closed while this page decoded: hand out a clone and drop ours.
      final clone = image.clone();
      image.dispose();
      return clone;
    }
    // A page asked for twice (a prefetch overtaken by a page turn) is kept
    // once.
    final have = _images[(index, width, sharpen)];
    if (have != null) {
      image.dispose();
      return have;
    }
    _images[(index, width, sharpen)] = image;
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

  /// [image] enlarged towards [width] and sharpened, or null when it is
  /// wide enough already (see [minUpscale]).
  static Future<ui.Image?> enlarge(ui.Image image, int width, {int maxPixels = 16 << 20}) async {
    final w = image.width, h = image.height;
    final scale = math.min(math.min(width / w, maxUpscale), math.sqrt(maxPixels / (w * h)));
    if (scale < minUpscale) return null;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final ow = (w * scale).round(), oh = (h * scale).round();
    final pixels = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final sw = Stopwatch()..start();
    final big = await Isolate.run(() => upscaleSharpen(pixels, w, h, ow, oh), debugName: 'sharpen');
    debugPrint('Clean-up: page ${w}x$h enlarged to ${ow}x$oh in ${sw.elapsedMilliseconds} ms');
    final buffer = await ui.ImmutableBuffer.fromUint8List(big);
    final descriptor = ui.ImageDescriptor.raw(buffer, width: ow, height: oh, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final out = (await codec.getNextFrame()).image;
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return out;
  }

  static int _size(ui.Image image) => image.width * image.height * 4;

  /// Rounds widths up to 256 px steps so small window resizes reuse pages.
  static int _bucket(int width) => ((width + 255) ~/ 256) * 256;
}
