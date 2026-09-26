import 'dart:io';
import 'dart:typed_data';

import 'package:comic_formats/comic_formats.dart';
import 'package:comic_formats/src/bytes.dart';
import 'package:comic_formats/src/epub.dart' show parseOpfMetadata;
import 'package:test/test.dart';

void main() {
  group('parseComicInfo', () {
    test('reads the fields, people split, the front cover and manga direction', () {
      final m = parseComicInfo('''<?xml version="1.0"?>
<ComicInfo>
  <Title>The &amp; Issue</Title><Series>Weird Comics</Series><Number>4</Number>
  <Volume>1</Volume><Year>1940</Year><Writer>A. Writer, B. Writer</Writer>
  <Penciller>C. Artist</Penciller><Manga>YesAndRightToLeft</Manga>
  <Pages><Page Image="0"/><Page Image="2" Type="FrontCover"/></Pages>
</ComicInfo>''');
      expect(m.title, 'The & Issue');
      expect(m.series, 'Weird Comics');
      expect(m.number, '4');
      expect(m.volume, 1);
      expect(m.year, 1940);
      expect(m.writers, ['A. Writer', 'B. Writer']);
      expect(m.artists, contains('C. Artist'));
      expect(m.frontCoverPage, 2);
      expect(m.rightToLeft, isTrue);
    });

    test('a book without ComicInfo fields reads as empty, not as an error', () {
      final m = parseComicInfo('<ComicInfo></ComicInfo>');
      expect(m.title, isNull);
      expect(m.writers, isEmpty);
      expect(m.frontCoverPage, isNull);
    });
  });

  group('parseOpfMetadata', () {
    test('a creator id with regex characters still finds its EPUB 3 role', () {
      final m = parseOpfMetadata(
        '''<package><metadata>
  <dc:title>Book</dc:title>
  <dc:creator id="c(1)+">Ann Artist</dc:creator>
  <meta refines="#c(1)+" property="role" scheme="marc:relators">ill</meta>
  <dc:creator opf:role="aut">Will Writer</dc:creator>
  <meta property="belongs-to-collection" id="s">Series</meta>
  <meta name="calibre:series_index" content="3.0"/>
  <dc:date>2019-05-01</dc:date>
</metadata><spine page-progression-direction="rtl"></spine></package>''',
        spineTag: '<spine page-progression-direction="rtl">',
      );
      expect(m.title, 'Book');
      expect(m.artists, ['Ann Artist']);
      expect(m.writers, ['Will Writer']);
      expect(m.series, 'Series');
      expect(m.number, '3');
      expect(m.year, 2019);
      expect(m.rightToLeft, isTrue);
    });
  });

  group('mergeMeta', () {
    const fromName = ComicMeta(title: 'Name title', series: 'Name series', number: '7', year: 1999);

    test('embedded fields win, the file name fills the gaps', () {
      final m = mergeMeta(const ComicMeta(title: 'Inside', writers: ['W']), fromName);
      expect(m.title, 'Inside');
      expect(m.series, 'Name series');
      expect(m.number, '7');
      expect(m.year, 1999);
      expect(m.writers, ['W']);
    });

    test("an embedded series doesn't take the file name's issue number", () {
      final m = mergeMeta(const ComicMeta(series: 'Other'), fromName);
      expect(m.series, 'Other');
      expect(m.number, isNull);
    });

    test('no embedded metadata is the file name alone', () {
      expect(mergeMeta(null, fromName), same(fromName));
    });
  });

  test('isComicInfoName matches in any folder and any case', () {
    expect(isComicInfoName('ComicInfo.xml'), isTrue);
    expect(isComicInfoName('OEBPS/comicinfo.XML'), isTrue);
    expect(isComicInfoName('ComicInfo.xml.bak'), isFalse);
  });

  group('byte helpers', () {
    test('hasBytesAt is false past the end instead of throwing', () {
      final b = Uint8List.fromList([1, 2, 3]);
      expect(hasBytesAt(b, 1, [2, 3]), isTrue);
      expect(hasBytesAt(b, 2, [3, 4]), isFalse);
      expect(hasBytesAt(b, -1, [1]), isFalse);
    });

    test('jpegSegments walks to the scan and skips fill bytes', () {
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0, length 4
        0xFF, 0xFF, // fill
        0xFF, 0xC0, 0x00, 0x05, 0x08, 0x00, 0x10, // SOF0
        0xFF, 0xDA, 0x00, 0x02, // SOS: the end
        0xFF, 0xDB, 0x00, 0x02,
      ]);
      expect([for (final s in jpegSegments(jpeg)) s.marker], [0xE0, 0xC0]);
      expect(isJpegFrameMarker(0xC0), isTrue);
      expect(isJpegFrameMarker(0xC4), isFalse);
    });
  });

  group('folders', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('meta_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('holdsOtherBooks: a comic file under it, or more page folders than loose pages', () {
      File('${tmp.path}/p1.jpg').writeAsBytesSync([0xFF, 0xD8]);
      expect(holdsOtherBooks(tmp.listSync()), isFalse);
      Directory('${tmp.path}/extras').createSync();
      File('${tmp.path}/extras/e.jpg').writeAsBytesSync([0xFF, 0xD8]);
      expect(holdsOtherBooks(tmp.listSync()), isFalse, reason: 'one extras folder beside a loose page');
      Directory('${tmp.path}/more').createSync();
      File('${tmp.path}/more/m.jpg').writeAsBytesSync([0xFF, 0xD8]);
      expect(holdsOtherBooks(tmp.listSync()), isTrue, reason: 'two page folders beside one loose page');
      File('${tmp.path}/.hidden.cbz').writeAsBytesSync([0]);
      Directory('${tmp.path}/more').deleteSync(recursive: true);
      expect(holdsOtherBooks(tmp.listSync()), isFalse, reason: 'hidden files are skipped');
      File('${tmp.path}/extras/book.cbz').writeAsBytesSync([0]);
      expect(holdsOtherBooks(tmp.listSync()), isTrue);
    });

    test('an unreadable subfolder is a FormatException, as documented', () {
      if (Platform.isWindows) return;
      File('${tmp.path}/p1.jpg').writeAsBytesSync([0xFF, 0xD8]);
      final locked = Directory('${tmp.path}/locked')..createSync();
      File('${locked.path}/p2.jpg').writeAsBytesSync([0xFF, 0xD8]);
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));
      // Root can read anything; the check means nothing then.
      if (locked.listSync().isNotEmpty) return;
      expect(() => FolderDocument.open(tmp.path), throwsFormatException);
    });
  });
}
