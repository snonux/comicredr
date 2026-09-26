import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comic_formats/comic_formats.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'cbz_test.dart' show comicInfo, png;

/// One tar header block for [name], as GNU tar, bsdtar or v7 tar would
/// write it.
Uint8List tarHeader(String name, int size, {int type = 0x30, String magic = 'ustar\x0000', String prefix = ''}) {
  final h = Uint8List(512);
  void put(int at, List<int> bytes) => h.setRange(at, at + bytes.length, bytes);
  String octal(int v, int width) => '${v.toRadixString(8).padLeft(width - 1, '0')}\x00';
  put(0, utf8.encode(name).take(100).toList());
  put(100, latin1.encode(octal(0x1a4, 8)));
  put(108, latin1.encode(octal(0, 8)));
  put(116, latin1.encode(octal(0, 8)));
  put(124, latin1.encode(octal(size, 12)));
  put(136, latin1.encode(octal(0, 12)));
  h[156] = type;
  if (magic.isNotEmpty) put(257, latin1.encode(magic));
  if (prefix.isNotEmpty) put(345, utf8.encode(prefix));
  put(148, latin1.encode('        '));
  final sum = h.fold<int>(0, (a, b) => a + b);
  put(148, latin1.encode('${sum.toRadixString(8).padLeft(6, '0')}\x00 '));
  return h;
}

/// A header, the data, and the padding to the next block.
List<int> tarEntry(String name, List<int> data, {int type = 0x30, String magic = 'ustar\x0000', String prefix = ''}) =>
    [
      ...tarHeader(name, data.length, type: type, magic: magic, prefix: prefix),
      ...data,
      ...List.filled((512 - data.length % 512) % 512, 0),
    ];

List<int> tarEnd() => List.filled(1024, 0);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('cbt_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  List<int> page(int n) => [...png, n];

  test('pages come back in natural order with junk and folders skipped', () async {
    final path = write('book.cbt', [
      ...tarEntry('Book/', [], type: 0x35),
      ...tarEntry('Book/page10.jpg', page(10)),
      ...tarEntry('Book/page2.jpg', page(2)),
      ...tarEntry('Book/page1.jpg', page(1)),
      ...tarEntry('Book/._page1.jpg', [0]),
      ...tarEntry('ComicInfo.xml', comicInfo.codeUnits),
      ...tarEnd(),
    ]);
    expect(sniffFormat(readHead(path)), SourceFormat.tar);
    expect(bookKind(path), BookKind.cbt);
    final doc = CbtDocument.open(path);
    expect(doc.pageNames, ['Book/page1.jpg', 'Book/page2.jpg', 'Book/page10.jpg']);
    expect(await doc.rawPage(0), page(1));
    expect((await doc.page(2, targetWidth: 1, targetHeight: 1)).bytes, page(10));
    final meta = (await doc.embeddedMetadata())!;
    expect(meta.series, 'Daredevil');
    expect(meta.frontCoverPage, 1);
    await doc.close();
  });

  test('long names: GNU L records, pax path records and the ustar prefix', () async {
    final deep = '${'very-long-folder-name/' * 6}001.png';
    final body = ' path=${'p' * 120}/002.png\n';
    final paxRecord = '${body.length + '${body.length + 3}'.length}$body';
    final path = write('long.cbt', [
      ...tarEntry('././@LongLink', [...utf8.encode(deep), 0], type: 0x4C, magic: 'ustar  \x00'),
      ...tarEntry(deep.substring(0, 99), page(1), magic: 'ustar  \x00'),
      ...tarEntry('PaxHeaders/002.png', utf8.encode(paxRecord), type: 0x78),
      ...tarEntry('trunc/002.png', page(2)),
      ...tarEntry('003.png', page(3), prefix: 'q' * 120),
      ...tarEnd(),
    ]);
    final doc = CbtDocument.open(path);
    expect(doc.pageNames, ['${'p' * 120}/002.png', '${'q' * 120}/003.png', deep]);
    expect(await doc.rawPage(0), page(2));
    expect(await doc.rawPage(2), page(1));
    await doc.close();
  });

  test('an old v7 tar without the ustar magic is recognised by its checksum', () async {
    final path = write('old.cbt', [...tarEntry('1.png', page(1), magic: ''), ...tarEnd()]);
    expect(sniffFormat(readHead(path)), SourceFormat.tar);
    final doc = await openDocument(path);
    expect(doc.pageCount, 1);
    await doc.close();
  });

  test('a tar with no pages, a cut-short tar and garbage are refused', () {
    final empty = write('empty.cbt', [...tarEntry('readme.txt', 'no'.codeUnits), ...tarEnd()]);
    expect(() => CbtDocument.open(empty), throwsFormatException);
    final whole = tarEntry('1.png', List.filled(2000, 7));
    final cut = write('cut.cbt', whole.sublist(0, 1024));
    expect(() => CbtDocument.open(cut), throwsFormatException);
    final junk = write('junk.cbt', List.filled(2048, 0x41));
    expect(bookKind(junk), BookKind.unknown);
    expect(() => CbtDocument.open(junk), throwsFormatException);
  });

  test('opens in the background and reads for the library', () async {
    final cover = img.encodePng(img.Image(width: 8, height: 12));
    final path = write('Space War 002 (1959).cbt', [
      ...tarEntry('b.png', page(2)),
      ...tarEntry('a.png', cover),
      ...tarEnd(),
    ]);
    final doc = await BackgroundDocument.open(path);
    expect(doc.pageCount, 2);
    expect(await doc.rawPage(1), page(2));
    await doc.close();
    final info = await readBookInfoInBackground(path, coverDir: '${tmp.path}/covers');
    expect(info.kind, BookKind.cbt);
    expect(info.pageCount, 2);
    expect(info.meta.series, 'Space War');
    expect(info.meta.number, '2');
    expect(info.cover, isNotNull);
  });

  test('page sizes come from the image headers', () async {
    final wide = img.encodePng(img.Image(width: 30, height: 12));
    final path = write('sizes.cbt', [
      ...tarEntry('1.png', wide),
      ...tarEntry('2.png', [1, 2, 3]),
      ...tarEnd(),
    ]);
    final doc = CbtDocument.open(path);
    expect(await doc.pageSizes(), [(30, 12), null]);
    await doc.close();
  });
}
