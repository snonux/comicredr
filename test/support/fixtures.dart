import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A 1x1 PNG. Every page of a fixture book is this, plus a trailing byte
/// that PNG decoders ignore, so pages stay distinguishable.
final Uint8List png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Writes a CBZ of [pages] pages into [dir] and returns its path.
String writeBook(Directory dir, String name, int pages) {
  final a = Archive();
  for (var i = 1; i <= pages; i++) {
    a.addFile(ArchiveFile.bytes('page$i.png', [...png, i]));
  }
  final path = '${dir.path}/$name';
  File(path).writeAsBytesSync(ZipEncoder().encodeBytes(a));
  return path;
}

/// A white comic page of [width] x [height] with a bordered, textured panel
/// for each rectangle in [panels] (x, y, w, h in pixels), as greyscale PNG.
/// Classic-CV detection finds each rectangle as one frame.
Uint8List gridPage(int width, int height, List<(int, int, int, int)> panels) {
  final px = Uint8List(width * height)..fillRange(0, width * height, 255);
  for (final (x0, y0, w, h) in panels) {
    for (var y = y0; y < y0 + h; y++) {
      for (var x = x0; x < x0 + w; x++) {
        final border = x < x0 + 4 || x >= x0 + w - 4 || y < y0 + 4 || y >= y0 + h - 4;
        px[y * width + x] = border ? 0 : ((x ~/ 16 + y ~/ 16).isEven ? 150 : 110);
      }
    }
  }
  return encodeGrayPng(width, height, px);
}

/// Four panels in a 2x2 grid on a 400 x 600 page.
Uint8List grid4Page() => gridPage(400, 600, [
  (20, 20, 170, 270),
  (210, 20, 170, 270),
  (20, 310, 170, 270),
  (210, 310, 170, 270),
]);

/// A minimal 8-bit greyscale PNG encoder, so tests need no image library.
Uint8List encodeGrayPng(int width, int height, Uint8List pixels) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // Filter: none.
    raw.add(Uint8List.sublistView(pixels, y * width, (y + 1) * width));
  }
  final out = BytesBuilder()..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    out
      ..add(_u32(data.length))
      ..add(body)
      ..add(_u32(getCrc32(body)));
  }

  chunk('IHDR', [..._u32(width), ..._u32(height), 8, 0, 0, 0, 0]);
  chunk('IDAT', ZLibCodec().encode(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

/// Writes a CBZ whose pages are the given encoded images.
String writeBookOf(Directory dir, String name, List<Uint8List> pages) {
  final a = Archive();
  for (final (i, bytes) in pages.indexed) {
    a.addFile(ArchiveFile.bytes('page${i + 1}.png', bytes));
  }
  final path = '${dir.path}/$name';
  File(path).writeAsBytesSync(ZipEncoder().encodeBytes(a));
  return path;
}
