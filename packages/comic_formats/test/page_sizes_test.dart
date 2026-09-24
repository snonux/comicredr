import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// A JPEG of [w] x [h] with an APP segment of [pad] random bytes before the
/// frame header, the way a big EXIF or ICC block pushes it back.
Uint8List jpegWithPad(int w, int h, int pad) {
  final jpeg = img.encodeJpg(img.Image(width: w, height: h));
  final random = Random(1);
  final out = BytesBuilder()..add(jpeg.sublist(0, 2));
  var left = pad;
  while (left > 0) {
    final n = min(left, 65533);
    out
      ..add([0xFF, 0xE2, (n + 2) >> 8, (n + 2) & 0xFF])
      ..add([for (var i = 0; i < n; i++) random.nextInt(256)]);
    left -= n;
  }
  return (out..add(jpeg.sublist(2))).takeBytes();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('page_sizes_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('reads the size from the header of every page format', () {
    final image = img.Image(width: 300, height: 200);
    expect(imageSize(img.encodeJpg(image)), (300, 200));
    expect(imageSize(img.encodePng(image)), (300, 200));
    expect(imageSize(img.encodeGif(image)), (300, 200));
    expect(imageSize(img.encodeBmp(image)), (300, 200));
    expect(imageSize(jpegWithPad(40, 60, 10000)), (40, 60));
    // Lossless and extended WebP headers, as libwebp writes them.
    expect(imageSize(_webp('VP8L', [0x2F, 0x2B, 0xC1, 0x31, 0x00])), (300, 200));
    expect(imageSize(_webp('VP8X', [0, 0, 0, 0, 0x2B, 0x01, 0x00, 0xC7, 0x00, 0x00])), (300, 200));
    expect(imageSize(Uint8List.fromList('not an image'.codeUnits)), isNull);
    expect(imageSize(img.encodeJpg(image).sublist(0, 20)), isNull);
  });

  test('a CBZ reads each size without inflating whole pages', () async {
    final archive = Archive()
      ..add(ArchiveFile.bytes('01.jpg', img.encodeJpg(img.Image(width: 60, height: 90))))
      ..add(
        ArchiveFile.bytes('02.png', img.encodePng(img.Image(width: 180, height: 90)))
          ..compression = CompressionType.none,
      )
      // Past the first 64 KiB: read whole as a fallback.
      ..add(ArchiveFile.bytes('03.jpg', jpegWithPad(120, 90, 100000)))
      ..add(ArchiveFile.bytes('04.jpg', Uint8List.fromList('broken'.codeUnits)));
    final path = '${tmp.path}/book.cbz';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    final doc = CbzDocument.open(path);
    expect(await doc.pageSizes(), [(60, 90), (180, 90), (120, 90), null]);
    // Reading sizes leaves the pages readable.
    expect(imageSize((await doc.rawPage(1))!), (180, 90));
    await doc.close();

    final bg = await BackgroundDocument.open(path);
    expect(await bg.pageSizes(), [(60, 90), (180, 90), (120, 90), null]);
    await bg.close();
  });

  test('a folder reads each size from the file head', () async {
    final dir = Directory('${tmp.path}/book')..createSync();
    File('${dir.path}/1.jpg').writeAsBytesSync(img.encodeJpg(img.Image(width: 60, height: 90)));
    File('${dir.path}/2.jpg').writeAsBytesSync(jpegWithPad(200, 90, 100000));
    final doc = FolderDocument.open(dir.path);
    expect(await doc.pageSizes(), [(60, 90), (200, 90)]);
  });
}

/// A WebP file of one [chunk] whose payload starts with [payload].
Uint8List _webp(String chunk, List<int> payload) => Uint8List.fromList([
  ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits, ...chunk.codeUnits, 0, 0, 0, 0, //
  ...payload, ...List.filled(16, 0),
]);
