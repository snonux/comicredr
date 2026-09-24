import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:test/test.dart';

/// A tiny 1x1 PNG, enough for an entry to count as a page.
final png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0,
  0,
  0,
  13,
  0x49,
  0x48,
  0x44,
  0x52,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1, //
  8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 13, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0, 1, 0, 0, //
  5, 0, 1, 0x0D, 0x0A, 0x2D, 0xB4, 0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

const comicInfo = '''<?xml version="1.0"?>
<ComicInfo>
  <Title>The Last Hand</Title>
  <Series>Daredevil</Series>
  <Number>181</Number>
  <Year>1982</Year>
  <Writer>Frank Miller</Writer>
  <Penciller>Frank Miller</Penciller>
  <Inker>Klaus Janson</Inker>
  <Summary>Bullseye &amp; Elektra.</Summary>
  <Pages><Page Image="0" Type="Story"/><Page Image="1" Type="FrontCover" /></Pages>
</ComicInfo>''';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('cbz_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Writes a ZIP whose entries each hold a distinct payload, so tests can
  /// tell which entry came back.
  String writeZip(String name, Map<String, List<int>> entries) {
    final a = Archive();
    entries.forEach((n, bytes) => a.addFile(ArchiveFile.bytes(n, bytes)));
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(a));
    return path;
  }

  List<int> pageBytes(int n) => [...png, n];

  test('pages come back in natural order with junk skipped', () async {
    final path = writeZip('book.cbz', {
      'Book/page10.jpg': pageBytes(10),
      'Book/page2.jpg': pageBytes(2),
      'Book/page1.jpg': pageBytes(1),
      '__MACOSX/Book/._page1.jpg': [0],
      'Book/.DS_Store': [0],
      'Thumbs.db': [0],
      'ComicInfo.xml': comicInfo.codeUnits,
      'notes.txt': 'hello'.codeUnits,
    });
    final doc = CbzDocument.open(path);
    expect(doc.pageNames, ['Book/page1.jpg', 'Book/page2.jpg', 'Book/page10.jpg']);
    expect((await doc.rawPage(2))!.last, 10);
    expect((await doc.rawPage(0))!.last, 1);
    await doc.close();
  });

  test('ComicInfo.xml is parsed, including the front cover', () async {
    final path = writeZip('book.cbz', {
      '1.png': pageBytes(1),
      '2.png': pageBytes(2),
      'ComicInfo.xml': comicInfo.codeUnits,
    });
    final meta = (await CbzDocument.open(path).embeddedMetadata())!;
    expect(meta.series, 'Daredevil');
    expect(meta.number, '181');
    expect(meta.year, 1982);
    expect(meta.artists, ['Frank Miller', 'Klaus Janson']);
    expect(meta.summary, 'Bullseye & Elektra.');
    expect(meta.frontCoverPage, 1);
    expect(meta.rightToLeft, isFalse);
  });

  test('a .cbr that is really a ZIP sniffs as ZIP and opens', () {
    final path = writeZip('mislabelled.cbr', {'001.jpg': pageBytes(1)});
    expect(sniffFormat(readHead(path)), SourceFormat.zip);
    expect(CbzDocument.open(path).pageCount, 1);
  });

  test('an archive with no pages is refused', () {
    final path = writeZip('empty.cbz', {'readme.txt': 'no pages'.codeUnits});
    expect(() => CbzDocument.open(path), throwsFormatException);
  });

  test('garbage is refused with a FormatException', () {
    final path = '${tmp.path}/junk.cbz';
    File(path).writeAsStringSync('definitely not a zip');
    expect(() => CbzDocument.open(path), throwsFormatException);
  });

  test('the background document serves pages from its own isolate', () async {
    final path = writeZip('book.cbz', {'b.png': pageBytes(2), 'a.png': pageBytes(1)});
    final doc = await BackgroundDocument.open(path);
    expect(doc.pageCount, 2);
    expect((await doc.rawPage(1))!.last, 2);
    expect(await doc.embeddedMetadata(), isNull);
    await doc.close();
  });

  test('opening a missing file in the background fails cleanly', () {
    expect(BackgroundDocument.open('${tmp.path}/nope.cbz'), throwsFormatException);
  });

  test('content key follows content, not name', () async {
    final a = writeZip('a.cbz', {'1.png': pageBytes(1)});
    final b = '${tmp.path}/renamed.cbz';
    File(a).copySync(b);
    final c = writeZip('c.cbz', {'1.png': pageBytes(9)});
    expect(await contentKey(a), await contentKey(b));
    expect(await contentKey(a), isNot(await contentKey(c)));
  });
}
