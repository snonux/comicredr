import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comic_formats/comic_formats.dart';
import 'package:test/test.dart';

/// A 1x1 PNG with a trailing byte that tells pages apart.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// A minimal PDF, one page per entry in [sizes] (points), each filled with
/// pure red, so a render can be checked pixel by pixel.
Uint8List minimalPdf(List<(int, int)> sizes) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[for (var i = 0; i < sizes.length; i++) '${3 + 2 * i} 0 R'].join(' ')}] /Count ${sizes.length} >>',
  ];
  for (var i = 0; i < sizes.length; i++) {
    final (w, h) = sizes[i];
    final content = '1 0 0 rg 0 0 $w $h re f';
    objects
      ..add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $w $h] /Contents ${4 + 2 * i} 0 R >>')
      ..add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(latin1.encode(out.toString()));
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('pdf_folder_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String writePdf(String name, List<(int, int)> sizes) {
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(minimalPdf(sizes));
    return path;
  }

  Directory writeFolder(String name, Map<String, List<int>> files) {
    final dir = Directory('${tmp.path}/$name')..createSync(recursive: true);
    files.forEach((n, bytes) => (File('${dir.path}/$n')..createSync(recursive: true)).writeAsBytesSync(bytes));
    return dir;
  }

  group('PDF', () {
    test('renders each page to fit the target, as BGRA', () async {
      final path = writePdf('book.pdf', [(600, 900), (900, 600)]);
      expect(bookKind(path), BookKind.pdf);
      final doc = await PdfComicDocument.open(path);
      expect(doc.pageCount, 2);
      final p = await doc.page(0, targetWidth: 300, targetHeight: 10000);
      expect((p.width, p.height, p.bgra), (300, 450, true));
      expect(p.bytes.length, 300 * 450 * 4);
      expect(p.bytes.sublist(0, 4), [0, 0, 255, 255]); // Red, in B G R A order.
      // A landscape page in a portrait box fits by width.
      final q = await doc.page(1, targetWidth: 300, targetHeight: 300);
      expect((q.width, q.height), (300, 200));
      expect(await doc.rawPage(0), isNull);
      expect(await doc.pageSizes(), [(600, 900), (900, 600)]);
      await doc.close();
    });

    test('never renders past 300 dpi', () async {
      final doc = await PdfComicDocument.open(writePdf('small.pdf', [(72, 144)]));
      final p = await doc.page(0, targetWidth: 5000, targetHeight: 5000);
      expect((p.width, p.height), (300, 600));
      await doc.close();
    });

    test('a broken PDF is refused with a FormatException', () async {
      final path = '${tmp.path}/broken.pdf';
      File(path).writeAsStringSync('%PDF-1.4\nnot really');
      await expectLater(PdfComicDocument.open(path), throwsFormatException);
    });

    test('renders only the region asked for, at the whole page scale', () async {
      // Zoomed in on the bottom-right quarter of a page 2000 px wide:
      // PDFium draws that quarter, 1000 px across, and nothing else.
      final doc = await BackgroundDocument.open(writePdf('zoom.pdf', [(600, 900)]));
      final p = await doc.page(
        0,
        targetWidth: 2000,
        targetHeight: 1 << 16,
        region: (left: 0.5, top: 0.5, width: 0.5, height: 0.5),
      );
      expect((p.width, p.height, p.bgra), (1000, 1500, true));
      expect(p.bytes.length, 1000 * 1500 * 4);
      expect(p.region, (left: 0.5, top: 0.5, width: 0.5, height: 0.5));
      expect(p.bytes.sublist(0, 4), [0, 0, 255, 255]);
      // No region: the whole page, and no region reported.
      expect((await doc.page(0, targetWidth: 200, targetHeight: 1 << 16)).region, isNull);
      await doc.close();
    });

    test('renders on the background isolate', () async {
      final doc = await BackgroundDocument.open(writePdf('book.pdf', [(600, 900)]));
      expect(doc.pageCount, 1);
      final p = await doc.page(0, targetWidth: 200, targetHeight: 1 << 16);
      expect((p.width, p.height, p.bgra), (200, 300, true));
      expect(await doc.rawPage(0), isNull);
      await doc.close();
    });
  });

  test('PDFs open at once and a cover read beside them do not crash PDFium', () async {
    final a = await BackgroundDocument.open(writePdf('a.pdf', [(600, 900)]));
    final b = await BackgroundDocument.open(writePdf('b.pdf', [(600, 900), (600, 900)]));
    final results = await Future.wait([
      a.page(0, targetWidth: 300, targetHeight: 900),
      b.page(1, targetWidth: 300, targetHeight: 900),
      readBookInfoInBackground(writePdf('c.pdf', [(600, 900)]), coverDir: '${tmp.path}/covers'),
    ]);
    expect((results[2] as BookInfo).pageCount, 1);
    expect(File((results[2] as BookInfo).cover!).existsSync(), isTrue);
    await a.close();
    expect((await b.page(0, targetWidth: 300, targetHeight: 900)).width, 300, reason: 'b stays open');
    await b.close();
  });

  test('the newest page request is served first, and close fails the rest', () async {
    final doc = await BackgroundDocument.open(writePdf('book.pdf', [for (var i = 0; i < 6; i++) (600, 900)]));
    final done = <int>[];
    final first = doc.page(0, targetWidth: 600, targetHeight: 900).then((_) => done.add(0));
    final rest = [
      for (var i = 1; i < 6; i++) doc.page(i, targetWidth: 600, targetHeight: 900).then((_) => done.add(i)),
    ];
    await Future.wait([first, ...rest]);
    expect(done, [0, 5, 4, 3, 2, 1]); // Page 0 was already rendering.

    final pending = [
      for (var i = 0; i < 4; i++)
        doc.page(i, targetWidth: 600, targetHeight: 900).then((_) => 'ok', onError: (_) => 'closed'),
    ];
    await doc.close();
    final outcomes = await Future.wait(pending);
    expect(outcomes, contains('closed'));
  });

  group('folder', () {
    test('pages in natural order across subfolders, junk skipped', () async {
      final dir = writeFolder('Preacher 01', {
        'page10.jpg': [..._png, 10],
        'page2.jpg': [..._png, 2],
        'page1.png': [..._png, 1],
        'extras/page11.jpg': [..._png, 11],
        '.hidden.jpg': [0],
        'Thumbs.db': [0],
        'README.txt': 'hello'.codeUnits,
      });
      expect(bookKind(dir.path), BookKind.folder);
      expect(isFolderBook(dir.path), isTrue);
      final doc = FolderDocument.open(dir.path);
      expect(doc.pageNames, ['extras/page11.jpg', 'page1.png', 'page2.jpg', 'page10.jpg']);
      expect((await doc.rawPage(3))!.last, 10);
      expect((await doc.page(1, targetWidth: 100, targetHeight: 100)).bgra, isFalse);
    });

    test('ComicInfo.xml beside the pages is read', () async {
      final dir = writeFolder('book', {
        '1.png': _png,
        'ComicInfo.xml': '<ComicInfo><Series>Preacher</Series><Number>1</Number></ComicInfo>'.codeUnits,
      });
      final meta = await FolderDocument.open(dir.path).embeddedMetadata();
      expect((meta!.series, meta.number), ('Preacher', '1'));
    });

    test('a folder with no images is refused, and is not a book', () {
      final dir = writeFolder('comics', {
        'a.cbz': [0],
        'sub/1.jpg': _png,
      });
      expect(isFolderBook(dir.path), isFalse); // Pages only in a subfolder.
      expect(
        () => FolderDocument.open(
          writeFolder('empty', {
            'x.txt': [0],
          }).path,
        ),
        throwsFormatException,
      );
    });

    test('serves pages from the background isolate', () async {
      final dir = writeFolder('book', {
        'b.png': [..._png, 2],
        'a.png': [..._png, 1],
      });
      final doc = await BackgroundDocument.open(dir.path);
      expect(doc.pageCount, 2);
      expect((await doc.rawPage(1))!.last, 2);
      expect((await doc.page(0, targetWidth: 10, targetHeight: 10)).bytes.last, 1);
      await doc.close();
    });

    test('content key survives renaming the folder, not changing a page', () async {
      final a = writeFolder('a', {
        '1.png': [..._png, 1],
        '2.png': [..._png, 2],
      });
      final keyA = await contentKey(a.path);
      final renamed = a.renameSync('${tmp.path}/renamed');
      expect(await contentKey(renamed.path), keyA);
      File('${renamed.path}/2.png').writeAsBytesSync([..._png, 3, 3]);
      expect(await contentKey(renamed.path), isNot(keyA));
    });
  });

  test('a RAR and an unknown file are told apart from comics', () {
    final rar = File('${tmp.path}/x.cbr')..writeAsBytesSync([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0]);
    final txt = File('${tmp.path}/x.txt')..writeAsStringSync('hello');
    expect(bookKind(rar.path), BookKind.rar);
    expect(bookKind(txt.path), BookKind.unknown);
    expect(openDocument(rar.path), throwsFormatException);
  });
}
