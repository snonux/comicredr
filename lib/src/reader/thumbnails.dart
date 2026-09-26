import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../data/book_paths.dart';
import '../library/providers.dart';
import 'decode_image.dart';
import 'reader_notifier.dart';

/// Small pictures of the open book's pages, for the page grid (`p`) and the
/// preview while dragging along the progress bar.
///
/// A thumbnail is made the first time it is asked for and kept on disk
/// beside the covers (`<cache>/covers/pages/<content key>/<page>.jpg`), so a
/// book's second look is instant. Making one reads the page through the
/// book's own document, which runs on its worker isolate (every PDF goes
/// through the one shared PDFium isolate, rendered straight at thumbnail
/// width); Flutter's decoder scales it down off the UI thread and a short
/// isolate encodes the JPEG. Nothing is decoded ahead: only pages a tile or
/// the preview shows are made, newest request first, two at a time, so a
/// fast scroll or drag does not queue the whole book in front of the page
/// being looked at.
class Thumbnails {
  Thumbnails(this.doc, {required this.dir, this.width = 256, this.parallel = 2});

  final ComicDocument doc;
  final String dir;

  /// Thumbnails are this many pixels wide unless a bigger size is asked
  /// for; tiles decode them smaller still.
  final int width;
  final int parallel;

  /// The sizes made for zoomed-in grid tiles, each kept in its own folder.
  static const sizes = [256, 512, 1024];

  /// The size for a tile [px] pixels wide: the smallest that needs
  /// enlarging by no more than a third, capped at the largest. The default
  /// grid on a phone (330 px tiles) stays on the 256 px thumbnails.
  static int sizeFor(double px) => sizes.firstWhere((w) => w * 1.3 >= px, orElse: () => sizes.last);

  /// Requests not started yet, oldest first: the newest is made next.
  final _waiting = <(int, int), Completer<String?>>{};
  final _running = <(int, int), Future<String?>>{};

  /// Pages and sizes whose thumbnail is known to be on disk.
  final _known = <(int, int)>{};
  int _busy = 0;
  bool _closed = false;

  /// The most requests kept waiting; older ones are dropped, as the tile or
  /// the preview that asked has moved on.
  static const _maxWaiting = 64;

  /// The file of page [index]'s thumbnail [size] pixels wide: the default
  /// size beside the others, bigger ones in a folder per size.
  String pathOf(int index, [int? size]) {
    final w = size ?? width;
    return w == width ? '$dir/${index + 1}.jpg' : '$dir/w$w/${index + 1}.jpg';
  }

  /// Whether page [index]'s thumbnail is on disk at [size], as far as this
  /// book has seen.
  bool has(int index, [int? size]) => _known.contains((index, size ?? width));

  /// The file of page [index]'s thumbnail, [size] pixels wide (the default
  /// size when null), made first if need be; null when the page cannot be
  /// read or nothing wants it any more.
  Future<String?> get(int index, {int? size}) {
    final key = (index, size ?? width);
    if (_known.contains(key)) return Future.value(pathOf(index, key.$2));
    if (_running[key] case final running?) return running;
    // Asked for again: it moves to the newest end.
    final c = _waiting.remove(key) ?? Completer<String?>();
    _waiting[key] = c;
    while (_waiting.length > _maxWaiting) {
      _waiting.remove(_waiting.keys.first)!.complete(null);
    }
    _pump();
    return c.future;
  }

  /// Page [index] is no longer shown (its tile scrolled away): forget it
  /// unless it is already being made.
  void cancel(int index, {int? size}) => _waiting.remove((index, size ?? width))?.complete(null);

  /// The book closed: nothing more is made.
  void close() {
    _closed = true;
    for (final c in _waiting.values) {
      c.complete(null);
    }
    _waiting.clear();
  }

  void _pump() {
    while (!_closed && _busy < parallel && _waiting.isNotEmpty) {
      final key = _waiting.keys.last;
      final c = _waiting.remove(key)!;
      _busy++;
      final made = _make(key).whenComplete(() {
        _busy--;
        _running.remove(key);
        _pump();
      });
      _running[key] = made;
      c.complete(made);
    }
  }

  Future<String?> _make((int, int) key) async {
    final (index, w) = key;
    final path = pathOf(index, w);
    try {
      if (await File(path).exists()) {
        _known.add(key);
        return path;
      }
      final jpeg = await thumbnailJpeg(doc, index, w);
      if (_closed) return null;
      await File(path).parent.create(recursive: true);
      // Written aside and renamed, so a half-written thumbnail never shows.
      final tmp = await File('$path.$pid.tmp').writeAsBytes(jpeg, flush: true);
      await tmp.rename(path);
      _known.add(key);
      return path;
    } catch (e) {
      if (!_closed) debugPrint('Could not make a thumbnail of page ${index + 1}: $e');
      return null;
    }
  }
}

/// Page [index] of [doc] at most [width] pixels wide, as JPEG.
Future<Uint8List> thumbnailJpeg(ComicDocument doc, int index, int width) async {
  // A PDF renders at this width; stored images come back as they are.
  final page = await doc.page(index, targetWidth: width, targetHeight: 1 << 16);
  final (image, _) = await decodeImage(
    page.bytes,
    raw: page.bgra ? (width: page.width!, height: page.height!) : null,
    size: (w, _) => (width: w > width ? width : null, height: null),
  );
  try {
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) throw const FormatException('The page could not be read back');
    return await _encodeJpeg(rgba, image.width, image.height);
  } finally {
    image.dispose();
  }
}

/// Encodes on a short-lived isolate; a top-level function, so the closure
/// carries only the pixels across.
Future<Uint8List> _encodeJpeg(ByteData rgba, int w, int h) => Isolate.run(
  () => img.encodeJpg(img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4), quality: 75),
);

/// The open book's thumbnails; null while no book is open.
final thumbnailsProvider = Provider<Thumbnails?>((ref) {
  final book = ref.watch(readerProvider.select((s) => s.book));
  if (book == null) return null;
  final t = Thumbnails(book.doc, dir: pageThumbDir(ref.watch(coverDirProvider), book.key));
  ref.onDispose(t.close);
  return t;
});
