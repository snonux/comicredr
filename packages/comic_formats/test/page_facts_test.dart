import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// A one-page PDF whose page is the JPEG [jpeg] of [w] x [h], written by
/// hand the way scanners write them.
Uint8List pdfWithJpeg(Uint8List jpeg, int w, int h, {String colour = '/DeviceRGB'}) {
  final out = BytesBuilder();
  final offsets = <int>[];
  void obj(String s, [Uint8List? stream]) {
    offsets.add(out.length);
    out.add(latin1.encode('${offsets.length} 0 obj\n$s'));
    if (stream != null) {
      out
        ..add(latin1.encode('\nstream\r\n'))
        ..add(stream)
        ..add(latin1.encode('\nendstream'));
    }
    out.add(latin1.encode('\nendobj\n'));
  }

  out.add(latin1.encode('%PDF-1.4\n'));
  obj('<< /Type /Catalog /Pages 2 0 R >>');
  obj('<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  obj(
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /ProcSet [/PDF /ImageC] /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>',
  );
  obj(
    '<< /Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace $colour '
    '/BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>',
    jpeg,
  );
  final content = latin1.encode('q 612 0 0 792 0 0 cm /Im0 Do Q');
  obj('<< /Length ${content.length} >>', content);
  final xref = out.length;
  out.add(latin1.encode('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n'));
  for (final o in offsets) {
    out.add(latin1.encode('${o.toString().padLeft(10, '0')} 00000 n \n'));
  }
  out.add(latin1.encode('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n'));
  return out.takeBytes();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('page_facts_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('reads format, size and JPEG quality from the header', () {
    final image = img.Image(width: 300, height: 200);
    for (final q in [30, 50, 75, 90, 95]) {
      final f = imageFacts(img.encodeJpg(image, quality: q));
      expect(f.format, 'jpeg');
      expect((f.width, f.height), (300, 200));
      expect(f.quality, inInclusiveRange(q - 1, q + 1), reason: 'quality $q');
      expect(f.progressive, isFalse);
    }
    final png = imageFacts(img.encodePng(image), total: 1234);
    expect((png.format, png.width, png.height, png.bytes, png.quality), ('png', 300, 200, 1234, null));
    expect(imageFacts(img.encodeGif(image)).format, 'gif');
    expect(imageFacts(img.encodeBmp(image)).format, 'bmp');
    expect(imageFacts(Uint8List.fromList('nope'.codeUnits)).format, 'unknown');
  });

  test('a greyscale PNG and a JFIF density are noticed', () {
    final gray = img.Image(width: 10, height: 10, numChannels: 1);
    expect(imageFacts(img.encodePng(gray)).gray, isTrue);
    // JFIF APP0 with 300 dots per inch.
    final jpeg = img.encodeJpg(img.Image(width: 10, height: 10));
    final app0 = [
      0xFF, 0xE0, 0, 16, ...'JFIF'.codeUnits, 0, 1, 1, 1, 0x01, 0x2C, 0x01, 0x2C, 0, 0, //
    ];
    final withDpi = Uint8List.fromList([...jpeg.sublist(0, 2), ...app0, ...jpeg.sublist(2)]);
    expect(imageFacts(withDpi).dpi, 300);
  });

  test('a CBZ and a folder report every page, the background document too', () async {
    final jpeg = img.encodeJpg(img.Image(width: 60, height: 90), quality: 80);
    final png = img.encodePng(img.Image(width: 180, height: 90));
    final archive = Archive()
      ..add(ArchiveFile.bytes('01.jpg', jpeg))
      ..add(ArchiveFile.bytes('02.png', png))
      ..add(ArchiveFile.bytes('03.jpg', Uint8List.fromList('broken'.codeUnits)));
    final path = '${tmp.path}/book.cbz';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    void check(List<PageFacts> facts) {
      expect([for (final f in facts) f.format], ['jpeg', 'png', 'unknown']);
      expect([for (final f in facts) f.width], [60, 180, null]);
      expect(facts[0].bytes, jpeg.length);
      expect(facts[0].quality, inInclusiveRange(79, 81));
    }

    final doc = CbzDocument.open(path);
    check(await doc.pageFacts());
    await doc.close();
    final bg = await BackgroundDocument.open(path);
    check(await bg.pageFacts());
    await bg.close();

    final dir = Directory('${tmp.path}/folder')..createSync();
    File('${dir.path}/01.jpg').writeAsBytesSync(jpeg);
    File('${dir.path}/02.png').writeAsBytesSync(png);
    final folder = FolderDocument.open(dir.path);
    final ff = await folder.pageFacts();
    expect([for (final f in ff) (f.format, f.width, f.height)], [('jpeg', 60, 90), ('png', 180, 90)]);
  });

  test('finds the scanned images in a PDF, with their JPEG quality', () {
    final jpeg = img.encodeJpg(img.Image(width: 120, height: 160), quality: 60);
    final path = '${tmp.path}/scan.pdf';
    File(path).writeAsBytesSync(pdfWithJpeg(jpeg, 120, 160, colour: '/DeviceGray'));
    final images = pdfImages(path);
    expect(images, hasLength(1));
    final i = images.single;
    expect((i.width, i.height, i.filter, i.bits, i.gray), (120, 160, 'jpeg', 8, true));
    expect(i.quality, inInclusiveRange(59, 61));
  });

  test('skips an image whose width is a reference, however many digits', () {
    final path = '${tmp.path}/ref.pdf';
    File(path).writeAsStringSync(
      '%PDF-1.4\n1 0 obj\n<< /Type /XObject /Subtype /Image /Width 1200 0 R /Height 1800 '
      '/BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /DCTDecode /Length 4 >>\nstream\nabcd\nendstream\nendobj\n%%EOF\n',
    );
    expect(pdfImages(path), isEmpty);
  });
}
