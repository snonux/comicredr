import 'dart:io';
import 'dart:typed_data';

import 'package:comic_formats/comic_formats.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('image_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final f = File('${tmp.path}/$name')..createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f.path;
  }

  Uint8List page(int w, int h) => img.encodePng(img.Image(width: w, height: h));

  test('PNG, JPEG and WebP sniff as images whatever their name', () {
    final small = img.Image(width: 30, height: 20);
    final webp = [...'RIFF'.codeUnits, 26, 0, 0, 0, ...'WEBPVP8L'.codeUnits, ...List.filled(22, 0)];
    expect(sniffFormat(img.encodePng(small)), SourceFormat.image);
    expect(sniffFormat(img.encodeJpg(small)), SourceFormat.image);
    expect(sniffFormat(Uint8List.fromList(webp)), SourceFormat.image);
    expect(bookKind(write('strip.dat', img.encodeJpg(small))), BookKind.image);
    expect(sniffFormat(img.encodeGif(small)), SourceFormat.unknown, reason: 'GIF is a page, not a comic');
  });

  test('an image opens as a one-page comic', () async {
    final path = write('Sunday Strip.png', page(600, 200));
    final doc = await openDocument(path);
    expect(doc, isA<ImageDocument>());
    expect(doc.pageCount, 1);
    expect(await doc.rawPage(0), File(path).readAsBytesSync());
    expect((await doc.page(0, targetWidth: 100, targetHeight: 100)).bgra, isFalse);
    expect(await doc.pageSizes(), [(600, 200)]);
    expect(await doc.embeddedMetadata(), isNull);
    expect(() => doc.rawPage(1), throwsRangeError);
    await doc.close();
  });

  test('the library reads it with its own cover, keyed on content', () async {
    final path = write('Sunday Strip 3.jpg', img.encodeJpg(img.Image(width: 1024, height: 700)));
    final info = await readBookInfoInBackground(path, coverDir: '${tmp.path}/covers');
    expect((info.kind, info.pageCount, info.meta.series, info.meta.number), (BookKind.image, 1, 'Sunday Strip', '3'));
    final cover = img.decodeJpg(File(info.cover!).readAsBytesSync())!;
    expect((cover.width, cover.height), (512, 350));
    final copy = File(path).copySync('${tmp.path}/renamed.jpg').path;
    expect(await contentKey(copy), info.contentKey);
  });

  test('a folder of only images is one book; an image beside a comic file is its own', () {
    write('Book/1.png', page(10, 10));
    write('Book/extras/2.png', page(10, 10));
    write('Book/Thumbs.db', [0]);
    expect(isFolderBook('${tmp.path}/Book'), isTrue);

    write('Series/one-pager.png', page(10, 10));
    write('Series/issue 1.cbz', [0x50, 0x4B, 0x05, 0x06]);
    expect(isFolderBook('${tmp.path}/Series'), isFalse);

    write('Shelf/poster.jpg', page(10, 10));
    write('Shelf/Indie/issue 2.pdf', '%PDF'.codeUnits);
    expect(isFolderBook('${tmp.path}/Shelf'), isFalse, reason: 'a comic file anywhere under it');

    write('Collection/cover.jpg', page(10, 10));
    write('Collection/Issue 1/1.png', page(10, 10));
    write('Collection/Issue 2/1.png', page(10, 10));
    expect(isFolderBook('${tmp.path}/Collection'), isFalse, reason: 'a cover.jpg beside two image-folder comics');

    write('Hidden/p.png', page(10, 10));
    write('Hidden/.trash/old.cbz', [0]);
    expect(isFolderBook('${tmp.path}/Hidden'), isTrue, reason: 'hidden files are not books');

    expect(isSingleImageName('a.JPEG'), isTrue);
    expect(isSingleImageName('a.gif'), isFalse);
    expect(isSingleImageName('.a.png'), isFalse);
  });
}
