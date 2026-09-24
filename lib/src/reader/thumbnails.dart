import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../library/providers.dart';
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

  /// Thumbnails are this many pixels wide; tiles decode them smaller still.
  final int width;
  final int parallel;

  /// Requests not started yet, oldest first: the newest is made next.
  final _waiting = <int, Completer<String?>>{};
  final _running = <int, Future<String?>>{};

  /// Pages whose thumbnail is known to be on disk.
  final _known = <int>{};
  int _busy = 0;
  bool _closed = false;

  /// The most requests kept waiting; older ones are dropped, as the tile or
  /// the preview that asked has moved on.
  static const _maxWaiting = 64;

  String pathOf(int index) => '$dir/${index + 1}.jpg';

  /// The file of page [index]'s thumbnail, made first if need be; null when
  /// the page cannot be read or nothing wants it any more.
  Future<String?> get(int index) {
    if (_known.contains(index)) return Future.value(pathOf(index));
    if (_running[index] case final running?) return running;
    // Asked for again: it moves to the newest end.
    final c = _waiting.remove(index) ?? Completer<String?>();
    _waiting[index] = c;
    while (_waiting.length > _maxWaiting) {
      _waiting.remove(_waiting.keys.first)!.complete(null);
    }
    _pump();
    return c.future;
  }

  /// Page [index] is no longer shown (its tile scrolled away): forget it
  /// unless it is already being made.
  void cancel(int index) => _waiting.remove(index)?.complete(null);

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
      final index = _waiting.keys.last;
      final c = _waiting.remove(index)!;
      _busy++;
      final made = _make(index).whenComplete(() {
        _busy--;
        _running.remove(index);
        _pump();
      });
      _running[index] = made;
      c.complete(made);
    }
  }

  Future<String?> _make(int index) async {
    final path = pathOf(index);
    try {
      if (await File(path).exists()) {
        _known.add(index);
        return path;
      }
      final jpeg = await thumbnailJpeg(doc, index, width);
      if (_closed) return null;
      await Directory(dir).create(recursive: true);
      // Written aside and renamed, so a half-written thumbnail never shows.
      final tmp = await File('$path.$pid.tmp').writeAsBytes(jpeg, flush: true);
      await tmp.rename(path);
      _known.add(index);
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
  final buffer = await ui.ImmutableBuffer.fromUint8List(page.bytes);
  final descriptor = page.bgra
      ? ui.ImageDescriptor.raw(buffer, width: page.width!, height: page.height!, pixelFormat: ui.PixelFormat.bgra8888)
      : await ui.ImageDescriptor.encoded(buffer);
  final codec = await descriptor.instantiateCodec(targetWidth: descriptor.width > width ? width : null);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
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
  final t = Thumbnails(book.doc, dir: p.join(ref.watch(coverDirProvider), 'pages', book.key));
  ref.onDispose(t.close);
  return t;
});
