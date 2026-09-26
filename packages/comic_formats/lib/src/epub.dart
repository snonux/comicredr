import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'comic_info.dart';
import 'document.dart';
import 'natural_sort.dart';
import 'stored_pages.dart';
import 'zip_entries.dart';

/// A comic EPUB: fixed-layout or image-based, one page image per spine item.
///
/// Pages follow the OPF spine. A spine item that is an image is the page.
/// An XHTML or SVG item is a page when it wraps one image and little text,
/// and a run of pages when it holds nothing but images, one after another,
/// as calibre writes a comic converted from a PDF. In a fixed-layout (`pre-paginated`) book, where every item is a page by
/// definition, the largest image it points at is the page (the art, not a
/// logo in the corner). A spine item with no image, such as a title or
/// copyright page, is skipped.
///
/// Anything else is refused rather than shown as a handful of pictures: a
/// text ebook, where fewer than half the spine items are pages, and a book
/// whose items mix text with several cut-out pictures, which is what the
/// Internet Archive makes out of scanned comics.
class EpubDocument with StoredPages implements ComicDocument {
  EpubDocument._(this._input, this._pages, this._meta);

  /// Reads the EPUB whose ZIP directory is [archive], which owns [input].
  /// Throws [FormatException] when it has no readable package or no pages,
  /// or reads as a text book; [input] is left for the caller to close then.
  factory EpubDocument.fromArchive(InputStream input, Archive archive, String path) {
    final files = {
      for (final f in archive.files)
        if (f.isFile) f.name: f,
    };
    final package = _readPackage(files, path);
    final found = _collectPages(files, package.spine, fixedLayout: package.fixedLayout);
    if (found.pages.isEmpty ||
        found.pageItems * 2 < package.spine.length ||
        found.mixed * 10 > found.pageItems + found.mixed) {
      // The status line shows the start of this, so the reason comes first.
      final what = found.cut * 2 > found.mixed ? 'text beside cut-out pictures' : 'a text ebook';
      throw FormatException(
        'Not a comic EPUB, $what rather than page images '
        '(${found.pageItems} of ${package.spine.length} parts are page images)',
      );
    }
    return EpubDocument._(input, found.pages, _readMeta(files, package, found.pages));
  }

  final InputStream _input;
  final List<ArchiveFile> _pages;
  final ComicMeta _meta;

  /// Page image paths inside the EPUB, in reading order.
  List<String> get pageNames => [for (final p in _pages) p.name];

  @override
  int get pageCount => _pages.length;

  @override
  Future<Uint8List> storedPage(int index) => readEntry(_pages[index]);

  @override
  Future<Uint8List> storedHead(int index, int n) async => entryHead(_pages[index], n);

  @override
  Future<int> storedLength(int index) async => _pages[index].size;

  @override
  Future<ComicMeta?> embeddedMetadata() async => _meta;

  @override
  Future<void> close() async => _input.close();
}

class _Item {
  const _Item(this.path, this.mediaType, this.properties);
  final String path;
  final String mediaType;
  final String properties;
}

String _text(ArchiveFile f) => utf8.decode(inflateEntry(f), allowMalformed: true);

/// What the OPF package document says: its text, its manifest by id, the
/// spine's linear items in order and whether the book is fixed-layout.
typedef _Package = ({String opf, Map<String, _Item> manifest, List<_Item> spine, String spineTag, bool fixedLayout});

/// Finds the package document through META-INF/container.xml and reads it.
/// Throws [FormatException] when there is none or its spine is empty.
_Package _readPackage(Map<String, ArchiveFile> files, String path) {
  final container = files['META-INF/container.xml'];
  if (container == null) throw FormatException('Not an EPUB, no META-INF/container.xml: $path');
  final opfPath = _attr(RegExp(r'<(?:\w+:)?rootfile\b[^>]*>').firstMatch(_text(container))?[0] ?? '', 'full-path');
  final opfFile = opfPath == null ? null : files[_decode(opfPath)];
  if (opfFile == null) throw FormatException('The EPUB names no readable package file: $path');
  final opf = _text(opfFile);
  final opfDir = _dir(opfFile.name);

  final manifest = <String, _Item>{};
  for (final m in RegExp(r'<(?:\w+:)?item\b[^>]*>').allMatches(opf)) {
    final tag = m[0]!;
    final id = _attr(tag, 'id');
    final href = _attr(tag, 'href');
    if (id == null || href == null) continue;
    manifest[id] = _Item(_resolve(opfDir, href), _attr(tag, 'media-type') ?? '', _attr(tag, 'properties') ?? '');
  }
  final spineTag = RegExp(r'<(?:\w+:)?spine\b[^>]*>').firstMatch(opf)?[0] ?? '';
  final spine = [
    for (final m in RegExp(r'<(?:\w+:)?itemref\b[^>]*>').allMatches(opf))
      if (_attr(m[0]!, 'linear') != 'no') manifest[_attr(m[0]!, 'idref')],
  ].nonNulls.toList();
  if (spine.isEmpty) throw FormatException('The EPUB has an empty spine: $path');

  final fixedLayout =
      RegExp(r'''property\s*=\s*["']rendition:layout["'][^>]*>\s*pre-paginated''').hasMatch(opf) ||
      RegExp(r'''name\s*=\s*["']fixed-layout["']\s+content\s*=\s*["']true''').hasMatch(opf);
  return (opf: opf, manifest: manifest, spine: spine, spineTag: spineTag, fixedLayout: fixedLayout);
}

/// Up to this many visible characters, an XHTML item wrapping one image
/// is still that image's page (a caption, a page number).
const _pageTextLimit = 200;

/// Up to this many, an item of several images is a run of pages.
const _imagesOnlyTextLimit = 20;

/// The page images in [spine] order, with the counts that decide whether
/// the book is a comic: [pageItems] spine items that gave pages, [mixed]
/// items of text beside pictures and, of those, [cut] with several.
({List<ArchiveFile> pages, int pageItems, int mixed, int cut}) _collectPages(
  Map<String, ArchiveFile> files,
  List<_Item> spine, {
  required bool fixedLayout,
}) {
  final pages = <ArchiveFile>[];
  var pageItems = 0, mixed = 0, cut = 0;
  for (final item in spine) {
    if (item.mediaType.startsWith('image/') || isPageEntry(item.path)) {
      final f = files[item.path];
      if (f != null) {
        pages.add(f);
        pageItems++;
      }
      continue;
    }
    final doc = files[item.path];
    if (doc == null) continue;
    final body = _text(doc);
    final images = [
      for (final src in _imageRefs(body))
        if (files[_resolve(_dir(item.path), src)] case final f? when isPageEntry(f.name)) f,
    ];
    if (images.isEmpty) continue;
    final words = fixedLayout ? 0 : _visibleText(body).length;
    if (fixedLayout) {
      pages.add(images.reduce((a, b) => b.size > a.size ? b : a));
    } else if (images.length == 1 && words < _pageTextLimit) {
      pages.add(images.single);
    } else if (words < _imagesOnlyTextLimit) {
      pages.addAll(images);
    } else {
      // Paragraphs beside a picture, or a page cut into pictures.
      mixed++;
      if (images.length > 1) cut++;
      continue;
    }
    pageItems++;
  }
  return (pages: pages, pageItems: pageItems, mixed: mixed, cut: cut);
}

/// A ComicInfo.xml if the book carries one, the OPF's metadata otherwise.
ComicMeta _readMeta(Map<String, ArchiveFile> files, _Package package, List<ArchiveFile> pages) {
  final comicInfo = files.values.where((f) => isComicInfoName(f.name)).firstOrNull;
  if (comicInfo != null) return parseComicInfo(_text(comicInfo));
  final coverId = _attr(
    RegExp(r'''<(?:\w+:)?meta\b[^>]*name\s*=\s*["']cover["'][^>]*>''').firstMatch(package.opf)?[0] ?? '',
    'content',
  );
  final cover =
      package.manifest.values.where((i) => i.properties.split(' ').contains('cover-image')).firstOrNull?.path ??
      package.manifest[coverId]?.path;
  final coverPage = pages.indexWhere((p) => p.name == cover);
  return parseOpfMetadata(package.opf, coverPage: coverPage < 0 ? null : coverPage, spineTag: package.spineTag);
}

/// The book's metadata from the OPF package document: Dublin Core title,
/// creators, date and description, and the series from EPUB 3's
/// `belongs-to-collection` or calibre's `calibre:series`.
ComicMeta parseOpfMetadata(String opf, {int? coverPage, String spineTag = ''}) {
  String? dc(String name) {
    final m = RegExp('<dc:$name\\b[^>]*>(.*?)</dc:$name>', dotAll: true).firstMatch(opf);
    final v = m == null ? null : _unescape(m[1]!.replaceAll(RegExp(r'<[^>]*>'), '').trim());
    return v == null || v.isEmpty ? null : v;
  }

  String? metaProperty(String property) {
    final m = RegExp(
      '<(?:\\w+:)?meta\\b[^>]*property\\s*=\\s*["\']$property["\'][^>]*>(.*?)</(?:\\w+:)?meta>',
      dotAll: true,
    ).firstMatch(opf);
    final v = m == null ? null : _unescape(m[1]!.trim());
    return v == null || v.isEmpty ? null : v;
  }

  String? metaName(String name) {
    for (final m in RegExp(r'<(?:\w+:)?meta\b[^>]*>').allMatches(opf)) {
      if (_attr(m[0]!, 'name') == name) return _attr(m[0]!, 'content');
    }
    return null;
  }

  // Creators: EPUB 2 puts the role on the element (opf:role), EPUB 3 in a
  // refining <meta property="role">. Illustrators and artists are artists,
  // everyone else a writer.
  final writers = <String>[], artists = <String>[];
  for (final m in RegExp(r'<dc:creator\b([^>]*)>(.*?)</dc:creator>', dotAll: true).allMatches(opf)) {
    final name = _unescape(m[2]!.trim());
    if (name.isEmpty || name == 'Unknown') continue; // calibre's placeholder.
    var role = _attr(m[1]!, 'opf:role') ?? _attr(m[1]!, 'role');
    final id = _attr(m[1]!, 'id');
    if (role == null && id != null) {
      role = RegExp(
        '<(?:\\w+:)?meta\\b[^>]*refines\\s*=\\s*["\']#${RegExp.escape(id)}["\'][^>]*property\\s*=\\s*["\']role["\'][^>]*>(.*?)<',
        dotAll: true,
      ).firstMatch(opf)?[1]?.trim();
    }
    (const {'ill', 'art', 'pnc', 'ink', 'clr', 'cov'}.contains(role) ? artists : writers).add(name);
  }

  final series = metaProperty('belongs-to-collection') ?? metaName('calibre:series');
  var number = metaProperty('group-position') ?? metaName('calibre:series_index');
  // calibre writes 3.0 for issue 3.
  if (number != null && RegExp(r'^\d+\.0+$').hasMatch(number)) number = number.split('.').first;
  final year = RegExp(r'\b(\d{4})\b').firstMatch(dc('date') ?? '')?[1];
  return ComicMeta(
    title: dc('title'),
    series: series,
    number: series == null ? null : number,
    year: year == null ? null : int.parse(year),
    writers: writers,
    artists: artists,
    summary: dc('description')?.replaceAll(RegExp(r'<[^>]*>'), ''),
    frontCoverPage: coverPage,
    rightToLeft: _attr(spineTag, 'page-progression-direction') == 'rtl',
  );
}

/// Where an XHTML or SVG page points at images: `<img src>`, SVG's
/// `<image href>` or `xlink:href`, and a CSS `url()` background.
Iterable<String> _imageRefs(String body) sync* {
  for (final m in RegExp(r'<(?:\w+:)?(?:img|image)\b[^>]*>').allMatches(body)) {
    final ref = _attr(m[0]!, 'src') ?? _attr(m[0]!, 'xlink:href') ?? _attr(m[0]!, 'href');
    if (ref != null) yield ref;
  }
  for (final m in RegExp(r'''url\(\s*["']?([^"')]+)["']?\s*\)''').allMatches(body)) {
    yield m[1]!;
  }
}

/// The text a reader would see in an XHTML page's body.
String _visibleText(String xhtml) {
  final body = RegExp(r'<body\b.*', dotAll: true).firstMatch(xhtml)?[0] ?? xhtml;
  return _unescape(
    body.replaceAll(RegExp(r'<(script|style)\b.*?</\1>', dotAll: true), '').replaceAll(RegExp(r'<[^>]*>'), ' '),
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// One pattern per attribute name, since [_attr] runs for every tag.
final _attrPatterns = <String, RegExp>{};

String? _attr(String tag, String name) {
  final pattern = _attrPatterns[name] ??= RegExp('(?:^|\\s)${RegExp.escape(name)}\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')');
  final m = pattern.firstMatch(tag);
  final v = m == null ? null : (m[1] ?? m[2]);
  return v == null ? null : _unescape(v);
}

String _dir(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

/// [href] as a path inside the ZIP: relative to [dir], percent-decoded,
/// with `.` and `..` folded and any `#fragment` or `?query` dropped.
String _resolve(String dir, String href) {
  href = href.split('#').first.split('?').first;
  final parts = <String>[];
  for (final s in [if (!href.startsWith('/')) ...dir.split('/'), ..._decode(href).split('/')]) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(s);
    }
  }
  return parts.join('/');
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } on ArgumentError {
    return s;
  }
}

String _unescape(String s) => s.contains('&') ? unescapeXml(s) : s;
