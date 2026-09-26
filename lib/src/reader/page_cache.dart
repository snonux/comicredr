import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/foundation.dart';

import 'decode_image.dart';

/// The most device pixels a page may decode to: it is fitted inside, never
/// enlarged. 0 leaves that side free, as fit-to-width does with the height.
typedef Box = ({int width, int height});

/// A sharp copy of part of a page, for a zoomed-in view: [image] shows
/// [region] of the page.
typedef Tile = ({ui.Image image, PageRegion region});

/// What a page or tile asked for fails with when its [PageCache] was
/// disposed before it decoded: the book is gone, so there is nothing to say.
class PageCacheClosed implements Exception {
  const PageCacheClosed();

  @override
  String toString() => 'PageCacheClosed';
}

/// Decoded pages for one open book, least recently used first out, within a
/// byte budget sized to the device ([pageBudgetBytes]).
///
/// Pages decode to fit the [Box] they are shown in, or at their own size
/// when that is smaller, using Flutter's native decoder, which runs off the
/// UI thread; PDF pages arrive already rendered at that size. A view zoomed
/// in past that asks for a [tile] of what it shows instead of a bigger
/// page. [get] and [tile] return clones the caller owns and must dispose;
/// the cache disposes its own copy on eviction, which never invalidates a
/// clone still on screen.
///
/// Asked to sharpen (scan clean-up, `c`), a page or tile with fewer pixels
/// than it is shown at is enlarged towards that, at most [maxUpscale] times
/// and to [maxSharpenedPixels], with [upscaleSharpen] in a background
/// isolate. It is cached apart from the page as decoded.
class PageCache {
  PageCache(this.doc, {required this.budgetBytes, this.maxSharpenedPixels = 16 << 20});

  final ComicDocument doc;
  final int budgetBytes;
  final int maxSharpenedPixels;

  static const maxUpscale = 2.0;

  /// Enlarging a page less than this much is not worth the time.
  static const minUpscale = 1.15;

  // Insertion-ordered: oldest first. A key's region is null for a whole page.
  final _images = <_Key, ui.Image>{};
  final _regions = <_Key, PageRegion>{};
  final _inFlight = <_Key, Future<ui.Image>>{};
  final _storedWidths = <int, int>{};

  /// In-flight pages only a prefetch asked for. The shared PDF worker
  /// serves newest first, so a prefetch sent before other requests (the
  /// next prefetches, detection) waits behind all of them; a page turned to
  /// must not inherit that wait.
  final _prefetching = <_Key>{};
  int _bytes = 0;
  bool _disposed = false;

  int get bytes => _bytes;

  /// How wide page [index] is stored, once it has been decoded; null for
  /// pages that render (PDF), which can always draw sharper, up to 300 dpi.
  /// A tile wider than this would show nothing the page does not.
  int? storedWidth(int index) => _storedWidths[index];

  Future<ui.Image> get(int index, Box box, {bool sharpen = false}) async {
    final image = await _load(_page(index, box, sharpen), urgent: true);
    return image.clone();
  }

  /// Starts decoding pages the reader is likely to want next.
  void prefetch(Iterable<int> indexes, Box box, {bool sharpen = false}) {
    for (final i in indexes) {
      if (i >= 0 && i < doc.pageCount) {
        unawaited(_load(_page(i, box, sharpen)).then((_) {}, onError: (_) {}));
      }
    }
  }

  /// [region] of page [index] at the scale the whole page would have
  /// [fullWidth] pixels across, or at the page's own size when that is
  /// smaller. A PDF renders only that part; a stored image is decoded
  /// whole at that scale, cropped, and only the crop kept. With [sharpen],
  /// a crop narrower than asked for is enlarged and sharpened.
  Future<Tile> tile(int index, int fullWidth, PageRegion region, {bool sharpen = false}) async {
    final key = (index: index, width: _bucket(fullWidth), height: 0, region: region, sharpen: sharpen);
    final image = await _load(key, urgent: true);
    return (image: image.clone(), region: _regions[key] ?? region);
  }

  /// Under memory pressure: drops every decoded page and tile but those of
  /// [keep], the pages on screen.
  void shed(Set<int> keep) {
    for (final key in _images.keys.where((k) => !keep.contains(k.index)).toList()) {
      _drop(key);
    }
  }

  static _Key _page(int index, Box box, bool sharpen) =>
      (index: index, width: _bucket(box.width), height: _bucket(box.height), region: null, sharpen: sharpen);

  Future<ui.Image> _load(_Key key, {bool urgent = false}) {
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
    f = _decode(key).whenComplete(() {
      if (identical(_inFlight[key], f)) {
        _inFlight.remove(key);
        _prefetching.remove(key);
      }
    });
    return _inFlight[key] = f;
  }

  Future<ui.Image> _decode(_Key key) async {
    final region = key.region;
    // Rendering sources (PDF) draw the page inside this box; stored images
    // come back as they are and the codec scales them down.
    final boxW = key.width == 0 ? 1 << 16 : key.width;
    final boxH = key.height == 0 ? 1 << 16 : key.height;
    final page = await doc.page(key.index, targetWidth: boxW, targetHeight: boxH, region: region);
    var (image, sourceWidth) = await decodeImage(
      page.bytes,
      raw: page.bgra ? (width: page.width!, height: page.height!) : null,
      size: (w, h) {
        // A region the source already drew is decoded as it is.
        final scale = page.region != null ? 1.0 : math.min(1.0, math.min(boxW / w, boxH / h));
        return scale < 1
            ? (width: math.max(1, (w * scale).round()), height: math.max(1, (h * scale).round()))
            : (width: null, height: null);
      },
    );
    if (!page.bgra) _storedWidths[key.index] = sourceWidth;
    var drawn = page.region;
    if (region != null && drawn == null) {
      final (crop, cut) = await _crop(image, region);
      image.dispose();
      image = crop;
      drawn = cut;
    }
    if (key.sharpen) {
      // What it is shown at: the box for a page, the crop's share of the
      // asked-for width for a tile.
      final want = drawn == null ? math.min(boxW / image.width, boxH / image.height) : boxW * drawn.width / image.width;
      final bigger = await enlarge(image, want, maxPixels: maxSharpenedPixels);
      if (bigger != null) {
        image.dispose();
        image = bigger;
      }
    }
    if (_disposed) {
      // The book closed while this page decoded: nobody is left to show it.
      image.dispose();
      throw const PageCacheClosed();
    }
    // A page asked for twice (a prefetch overtaken by a page turn) is kept
    // once.
    final have = _images[key];
    if (have != null) {
      image.dispose();
      return have;
    }
    _images[key] = image;
    if (drawn != null) _regions[key] = drawn;
    _bytes += _size(image);
    _evict();
    return image;
  }

  /// The whole pixels of [image] covering [region], as a new image.
  static Future<(ui.Image, PageRegion)> _crop(ui.Image image, PageRegion region) async {
    final w = image.width, h = image.height;
    final x = (region.left * w).floor().clamp(0, w - 1);
    final y = (region.top * h).floor().clamp(0, h - 1);
    final cw = ((region.left + region.width) * w).ceil().clamp(x + 1, w) - x;
    final ch = ((region.top + region.height) * h).ceil().clamp(y + 1, h) - y;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), cw.toDouble(), ch.toDouble()),
      ui.Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
      ui.Paint(),
    );
    final picture = recorder.endRecording();
    final crop = await picture.toImage(cw, ch);
    picture.dispose();
    return (crop, (left: x / w, top: y / h, width: cw / w, height: ch / h));
  }

  void _evict() {
    // Keep at least the newest entry, even when one page exceeds the budget.
    while (_bytes > budgetBytes && _images.length > 1) {
      _drop(_images.keys.first);
    }
  }

  void _drop(_Key key) {
    final image = _images.remove(key)!;
    _regions.remove(key);
    _bytes -= _size(image);
    image.dispose();
  }

  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _regions.clear();
    _bytes = 0;
  }

  /// [image] enlarged [scale] times, at most [maxUpscale] and to
  /// [maxPixels], and sharpened; null when that is too little to be worth it
  /// (see [minUpscale]).
  static Future<ui.Image?> enlarge(ui.Image image, double scale, {int maxPixels = 16 << 20}) async {
    final w = image.width, h = image.height;
    final s = math.min(math.min(scale, maxUpscale), math.sqrt(maxPixels / (w * h)));
    if (s < minUpscale) return null;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final ow = (w * s).round(), oh = (h * s).round();
    final pixels = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final sw = Stopwatch()..start();
    final big = await Isolate.run(() => upscaleSharpen(pixels, w, h, ow, oh), debugName: 'sharpen');
    debugPrint('Clean-up: ${w}x$h enlarged to ${ow}x$oh in ${sw.elapsedMilliseconds} ms');
    final (out, _) = await decodeImage(big, raw: (width: ow, height: oh), format: ui.PixelFormat.rgba8888);
    return out;
  }

  static int _size(ui.Image image) => image.width * image.height * 4;

  /// Rounds sizes up to 64 px steps so small window resizes reuse pages,
  /// while a page decodes at most some 6% larger than it is shown.
  static int _bucket(int size) => ((size + 63) ~/ 64) * 64;
}

typedef _Key = ({int index, int width, int height, PageRegion? region, bool sharpen});

/// Decoded-page budget for a device with [memTotal] bytes of RAM (null when
/// unknown): a slice of it, generous on the laptop and tight on the phone,
/// where the whole app should stay well clear of what Android kills for.
/// A phone page decoded at screen size is some 8 MB, so even the floor
/// holds the page on screen, the two after it, the one before and a tile.
///
/// A tablet's screen holds two to three times a phone's pixels, so a page
/// fitted to it is some 16 MB and the phone's floor held two of them.
/// Given the screen's size in device pixels ([screenPixels]), the floor on
/// Android is four screenfuls, still at most a thirty-second of the RAM.
int pageBudgetBytes({required bool phone, int? memTotal, int? screenPixels}) {
  const mb = 1 << 20;
  if (phone) {
    final base = memTotal == null ? 48 * mb : (memTotal ~/ 128).clamp(40 * mb, 80 * mb);
    if (screenPixels == null) return base;
    final screens = screenPixels * 4 * 4;
    final cap = memTotal == null ? 128 * mb : memTotal ~/ 32;
    return math.max(base, math.min(screens, cap));
  }
  return memTotal == null ? 256 * mb : (memTotal ~/ 64).clamp(128 * mb, 512 * mb);
}

/// The device's RAM from /proc/meminfo, which Linux and Android both have;
/// null when it cannot be read.
int? readMemTotal() {
  try {
    final line = File('/proc/meminfo').readAsLinesSync().firstWhere((l) => l.startsWith('MemTotal:'));
    final kb = int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!);
    return kb * 1024;
  } catch (_) {
    return null;
  }
}
