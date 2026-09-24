import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'cbz_test.dart' show comicInfo, png;

const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';

String xhtmlPage(String image) => '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Page</title>
<meta name="viewport" content="width=1200, height=1800"/></head>
<body><div class="page"><img src="$image" alt="Page"/></div></body></html>''';

String svgPage(String image) => '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1200 1800">
<image width="1200" height="1800" xlink:href="$image"/></svg></body></html>''';

String chapter(String image) => '''<html xmlns="http://www.w3.org/1999/xhtml"><body>
<h1>Chapter</h1><p>${'It was a dark and stormy night; the rain fell in torrents. ' * 12}</p>
<img src="$image"/><p>${'Except at occasional intervals, when it was checked by a violent gust. ' * 8}</p></body></html>''';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('epub_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Writes an EPUB: `mimetype` first and stored, as the spec asks, unless
  /// [strict] is false.
  String writeEpub(String name, Map<String, List<int>> entries, {bool strict = true}) {
    final a = Archive();
    final mimetype = ArchiveFile.bytes('mimetype', utf8.encode('application/epub+zip'))
      ..compression = CompressionType.none;
    if (strict) a.addFile(mimetype);
    entries.forEach((n, bytes) => a.addFile(ArchiveFile.bytes(n, bytes)));
    if (!strict) a.addFile(mimetype);
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(a));
    return path;
  }

  List<int> page(int n, {int pad = 0}) => [...png, ...List.filled(pad, 0), n];

  test('a fixed-layout EPUB 3: pages from the spine, text pages skipped, OPF metadata', () async {
    const opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>The Potion of Flight</dc:title>
    <dc:creator id="c1">David Revoy</dc:creator>
    <meta refines="#c1" property="role" scheme="marc:relators">ill</meta>
    <dc:creator id="c2">A. Writer</dc:creator>
    <meta refines="#c2" property="role" scheme="marc:relators">aut</meta>
    <dc:date>2014-05-10T00:00:00Z</dc:date>
    <dc:description>Pepper &amp; Carrot enter a contest.</dc:description>
    <meta property="rendition:layout">pre-paginated</meta>
    <meta property="belongs-to-collection" id="s">Pepper &amp; Carrot</meta>
    <meta refines="#s" property="group-position">6</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="p0" href="text/p0.xhtml" media-type="application/xhtml+xml"/>
    <item id="p1" href="text/p1.xhtml" media-type="application/xhtml+xml"/>
    <item id="p2" href="text/p2.xhtml" media-type="application/xhtml+xml"/>
    <item id="legal" href="text/legal.xhtml" media-type="application/xhtml+xml"/>
    <item id="i1" href="images/page%2010.jpg" media-type="image/jpeg"/>
    <item id="i2" href="images/p2.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="p0"/><itemref idref="p2"/><itemref idref="p1"/><itemref idref="legal"/>
    <itemref idref="nav" linear="no"/>
  </spine>
</package>''';
    final path = writeEpub('e06.epub', {
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      'OEBPS/nav.xhtml': utf8.encode('<html><body><nav><ol><li>Contents</li></ol></nav></body></html>'),
      'OEBPS/text/p0.xhtml': utf8.encode(xhtmlPage('../images/cover.jpg')),
      // Spine order, not name order: "p2" is read before "p1".
      'OEBPS/text/p2.xhtml': utf8.encode(svgPage('../images/p2.png')),
      'OEBPS/text/p1.xhtml': utf8.encode(xhtmlPage('../images/page%2010.jpg#frag')),
      'OEBPS/text/legal.xhtml': utf8.encode('<html><body><p>CC BY 4.0</p></body></html>'),
      'OEBPS/images/cover.jpg': page(0),
      'OEBPS/images/page 10.jpg': page(10),
      'OEBPS/images/p2.png': page(2),
    });
    expect(sniffFormat(readHead(path)), SourceFormat.epub);
    expect(bookKind(path), BookKind.epub);
    final doc = await openDocument(path) as EpubDocument;
    expect(doc.pageNames, ['OEBPS/images/cover.jpg', 'OEBPS/images/p2.png', 'OEBPS/images/page 10.jpg']);
    expect(await doc.rawPage(2), page(10));
    expect((await doc.page(1, targetWidth: 1, targetHeight: 1)).bytes, page(2));
    final meta = (await doc.embeddedMetadata())!;
    expect(meta.title, 'The Potion of Flight');
    expect(meta.series, 'Pepper & Carrot');
    expect(meta.number, '6');
    expect(meta.year, 2014);
    expect(meta.writers, ['A. Writer']);
    expect(meta.artists, ['David Revoy']);
    expect(meta.summary, 'Pepper & Carrot enter a contest.');
    expect(meta.frontCoverPage, 0);
    expect(meta.rightToLeft, isFalse);
    await doc.close();
  });

  test('an EPUB 2 with images straight in the spine, calibre series, mimetype out of place', () async {
    const opf = '''<?xml version="1.0"?>
<opf:package xmlns:opf="http://www.idpf.org/2007/opf" version="2.0">
  <opf:metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Space War</dc:title>
    <dc:creator opf:role="aut">Joe Gill</dc:creator>
    <dc:creator opf:role="art">Steve Ditko</dc:creator>
    <dc:date>1960</dc:date>
    <opf:meta name="calibre:series" content="Space War"/>
    <opf:meta name="calibre:series_index" content="2.0"/>
    <opf:meta name="cover" content="img2"/>
  </opf:metadata>
  <opf:manifest>
    <opf:item id="img1" href="001.jpg" media-type="image/jpeg"/>
    <opf:item id="img2" href="002.jpg" media-type="image/jpeg"/>
  </opf:manifest>
  <opf:spine page-progression-direction="rtl"><opf:itemref idref="img1"/><opf:itemref idref="img2"/></opf:spine>
</opf:package>''';
    final path = writeEpub('lax.epub', strict: false, {
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      'OEBPS/001.jpg': page(1),
      'OEBPS/002.jpg': page(2),
    });
    // Without mimetype first the bytes look like any ZIP; the inside decides.
    expect(bookKind(path), BookKind.cbz);
    final doc = await openDocument(path);
    expect(doc, isA<EpubDocument>());
    expect(doc.pageCount, 2);
    final meta = (await doc.embeddedMetadata())!;
    expect(meta.series, 'Space War');
    expect(meta.number, '2');
    expect(meta.year, 1960);
    expect(meta.writers, ['Joe Gill']);
    expect(meta.artists, ['Steve Ditko']);
    expect(meta.frontCoverPage, 1);
    expect(meta.rightToLeft, isTrue);
    await doc.close();
  });

  test('in a fixed-layout book the biggest image is the page, and ComicInfo.xml wins over the OPF', () async {
    const opf = '''<package><metadata><dc:title>Ignored</dc:title>
<meta property="rendition:layout">pre-paginated</meta></metadata>
<manifest><item id="p" href="p.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="p"/></spine></package>''';
    final path = writeEpub('two.epub', {
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      'OEBPS/p.xhtml': utf8.encode(
        '<html><body><img src="logo.png"/><div style="background-image: url(\'art.png\')"></div></body></html>',
      ),
      'OEBPS/logo.png': page(1),
      'OEBPS/art.png': page(2, pad: 500),
      'OEBPS/ComicInfo.xml': utf8.encode(comicInfo),
    });
    final doc = await openDocument(path) as EpubDocument;
    expect(doc.pageNames, ['OEBPS/art.png']);
    expect((await doc.embeddedMetadata())!.series, 'Daredevil');
    await doc.close();
  });

  test('a reflowable text EPUB is refused', () async {
    const opf = '''<package><manifest>
<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
<item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
<item id="c3" href="c3.xhtml" media-type="application/xhtml+xml"/>
</manifest><spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/></spine></package>''';
    final path = writeEpub('novel.epub', {
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      'OEBPS/c1.xhtml': utf8.encode(chapter('fig.png')),
      'OEBPS/c2.xhtml': utf8.encode(chapter('fig.png')),
      'OEBPS/c3.xhtml': utf8.encode(xhtmlPage('fig.png')),
      'OEBPS/fig.png': page(1),
    });
    expect(
      () => openDocument(path),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('not made of page images'))),
    );
    expect(() => BackgroundDocument.open(path), throwsA(isA<FormatException>()));
  });

  test('pages cut into several pictures with OCR text are refused, as the Internet Archive makes them', () async {
    final items = [for (var i = 0; i < 6; i++) '<item id="p$i" href="page_$i.html" media-type="application/xhtml+xml"/>'];
    final opf = '<package><manifest>${items.join()}</manifest><spine>'
        '${[for (var i = 0; i < 6; i++) '<itemref idref="p$i"/>'].join()}</spine></package>';
    String cut(int i) => '<html><body><b>The text on this page is estimated to be only 9.89% accurate</b>'
        '<p>IT MIGHT\'VE BEEN WORSE</p><img src="i${i}a.jpg"/><img src="i${i}b.jpg"/></body></html>';
    final path = writeEpub('derived.epub', {
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      for (var i = 0; i < 6; i++) ...{
        'OEBPS/page_$i.html': utf8.encode(i.isEven ? cut(i) : xhtmlPage('i${i}a.jpg')),
        'OEBPS/i${i}a.jpg': page(i),
        'OEBPS/i${i}b.jpg': page(i),
      },
    });
    expect(() => openDocument(path), throwsFormatException);
  });

  test('one XHTML file holding every page image in turn, as calibre writes it', () async {
    const opf = '''<package><manifest><item id="id1" href="index.html" media-type="application/xhtml+xml"/>
<item id="c" href="index-1_1.png" media-type="image/png"/></manifest><spine><itemref idref="id1"/></spine></package>''';
    final path = writeEpub('calibre.epub', {
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      'OEBPS/index.html': utf8.encode(
        '<html><head><title>index</title></head><body class="calibre">'
        '${[for (var i = 1; i <= 12; i++) '<p class="calibre1"><img src="index-${i}_1.${i == 1 ? 'png' : 'jpg'}"/></p>\n'].join()}'
        '</body></html>',
      ),
      for (var i = 1; i <= 12; i++) 'OEBPS/index-${i}_1.${i == 1 ? 'png' : 'jpg'}': page(i),
    });
    final doc = await openDocument(path) as EpubDocument;
    expect(doc.pageCount, 12);
    expect(doc.pageNames.take(3), ['OEBPS/index-1_1.png', 'OEBPS/index-2_1.jpg', 'OEBPS/index-3_1.jpg']);
    expect(await doc.rawPage(11), page(12));
    await doc.close();
  });

  test('one text page among many comic pages is skipped, not fatal', () async {
    final items = [for (var i = 0; i < 12; i++) '<item id="p$i" href="p$i.xhtml" media-type="application/xhtml+xml"/>'];
    final opf = '<package><manifest>${items.join()}</manifest><spine>'
        '${[for (var i = 0; i < 12; i++) '<itemref idref="p$i"/>'].join()}</spine></package>';
    final path = writeEpub('foreword.epub', {
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      'OEBPS/p0.xhtml': utf8.encode(chapter('author.jpg')),
      'OEBPS/author.jpg': page(99),
      for (var i = 1; i < 12; i++) ...{'OEBPS/p$i.xhtml': utf8.encode(xhtmlPage('$i.jpg')), 'OEBPS/$i.jpg': page(i)},
    });
    final doc = await openDocument(path);
    expect(doc.pageCount, 11);
    expect(await doc.rawPage(0), page(1));
    await doc.close();
  });

  test('an EPUB with no container reads as the ZIP of images it is; one with no package file is refused', () async {
    final noContainer = writeEpub('a.epub', {'OEBPS/1.jpg': page(1)});
    final doc = await openDocument(noContainer);
    expect(doc, isA<CbzDocument>());
    await doc.close();
    final noOpf = writeEpub('b.epub', {'META-INF/container.xml': utf8.encode(container), 'OEBPS/1.jpg': page(1)});
    expect(() => openDocument(noOpf), throwsFormatException);
  });

  test('the library reads an EPUB: kind, metadata and cover', () async {
    const opf = '''<package><metadata><dc:title>Episode 6</dc:title>
<meta name="calibre:series" content="Pepper&amp;Carrot"/><meta name="calibre:series_index" content="6"/></metadata>
<manifest><item id="p" href="p.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="p"/></spine></package>''';
    final path = writeEpub('whatever.epub', {
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      'OEBPS/p.xhtml': utf8.encode(xhtmlPage('p.png')),
      'OEBPS/p.png': img.encodePng(img.Image(width: 8, height: 12)),
    });
    final info = await readBookInfoInBackground(path, coverDir: '${tmp.path}/covers');
    expect(info.kind, BookKind.epub);
    expect(info.pageCount, 1);
    expect(info.fromComicInfo, isTrue);
    expect(info.meta.series, 'Pepper&Carrot');
    expect(info.meta.number, '6');
    expect(info.meta.title, 'Episode 6');
    expect(info.cover, isNotNull);
  });
}
