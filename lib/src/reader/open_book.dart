import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:path/path.dart' as p;

import '../data/meta_edits.dart';

/// A book the reader has open: the document plus what identifies it.
class OpenBook {
  OpenBook({required this.path, required this.key, required this.doc, this.meta, this.folder = false});

  final String path;

  /// Content key: progress follows the content, not the file name.
  final String key;
  final ComicDocument doc;
  final ComicMeta? meta;

  /// A folder of page images rather than a file.
  final bool folder;

  /// The same book with the facts edited by hand in the library on top of
  /// what the file and its name say.
  OpenBook withEdits(Map<MetaField, String?> edits) {
    if (edits.isEmpty) return this;
    final m = mergeMeta(meta, parseFileName(p.basename(path)));
    String? v(MetaField f) {
      if (!edits.containsKey(f)) return null;
      final s = edits[f]?.trim();
      return s == null || s.isEmpty ? null : s;
    }

    T? pick<T>(MetaField f, T? file, T? Function(String?) parse) => edits.containsKey(f) ? parse(v(f)) : file;
    return OpenBook(
      path: path,
      key: key,
      doc: doc,
      folder: folder,
      meta: ComicMeta(
        series: v(MetaField.series) ?? m.series ?? (folder ? p.basename(path) : p.basenameWithoutExtension(path)),
        number: pick(MetaField.number, m.number, (s) => s),
        title: pick(MetaField.title, m.title, (s) => s),
        volume: pick(MetaField.volume, m.volume, (s) => int.tryParse(s ?? '')),
        year: pick(MetaField.year, m.year, (s) => int.tryParse(s ?? '')),
        writers: pick(MetaField.writers, m.writers, splitPeople) ?? const [],
        artists: pick(MetaField.artists, m.artists, splitPeople) ?? const [],
        summary: pick(MetaField.summary, m.summary, (s) => s),
        frontCoverPage: m.frontCoverPage,
        rightToLeft: m.rightToLeft,
      ),
    );
  }

  String get title {
    final m = meta;
    if (m?.series != null) {
      return [m!.series, if (m.number != null) '#${m.number}', if (m.title != null) '· ${m.title}'].join(' ');
    }
    return folder ? p.basename(path) : p.basenameWithoutExtension(path);
  }
}

/// Why a file could not be opened, phrased for the person reading.
class OpenBookException implements Exception {
  const OpenBookException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Opens [path] as a book: a CBZ, a CBT, a comic EPUB, a PDF, a folder
/// of page images, or one PNG, JPEG or WebP image as a one-page comic.
/// Dispatches on the file's first bytes, not its extension, so a `.cbr`
/// that is really a ZIP opens as the ZIP it is.
Future<OpenBook> openBook(String path) async {
  path = p.normalize(path);
  final isDir = await FileSystemEntity.isDirectory(path);
  if (!isDir && !await File(path).exists()) throw OpenBookException('File not found: $path');
  switch (bookKind(path)) {
    case BookKind.cbz || BookKind.cbt || BookKind.epub || BookKind.pdf || BookKind.folder || BookKind.image:
      break;
    case BookKind.rar:
      throw const OpenBookException(
        'This is a RAR archive. ComicRedr reads CBZ, so convert it once with '
        'unar and zip (see "The CBR files you already have" in the guide).',
      );
    case BookKind.unknown:
      throw OpenBookException('Not a comic book: ${p.basename(path)}');
  }
  final ComicDocument doc;
  try {
    doc = await BackgroundDocument.open(path);
  } on FormatException catch (e) {
    throw OpenBookException('Could not read ${p.basename(path)}: ${e.message}');
  }
  final key = await contentKey(path);
  ComicMeta? meta;
  try {
    meta = await doc.embeddedMetadata();
  } on FormatException {
    meta = null; // A broken ComicInfo.xml costs the metadata, not the book.
  }
  return OpenBook(path: path, key: key, doc: doc, meta: meta, folder: isDir);
}

/// The next or previous book beside [path] in its folder, in natural order,
/// for `]` and `[`. Books are comic files and folders of page images, so a
/// folder of scans sits in line with the CBZs, EPUBs and PDFs around it, and
/// loose PNG, JPEG and WebP one-pagers, unless the folder is a folder book
/// whose pages they are. Null at either end.
Future<String?> siblingBook(String path, {required bool next}) async {
  path = p.normalize(path);
  final dir = Directory(p.dirname(path));
  final images = isSingleImageName(p.basename(path)) || !isFolderBook(dir.path);
  final books = <String>[];
  await for (final e in dir.list(followLinks: false)) {
    final name = p.basename(e.path);
    if (name.startsWith('.')) continue;
    if (e is File && (isComicFileName(name) || (images && isSingleImageName(name)))) books.add(p.normalize(e.path));
    if (e is Directory && isFolderBook(e.path)) books.add(p.normalize(e.path));
  }
  books.sort((a, b) => naturalCompare(p.basename(a), p.basename(b)));
  final i = books.indexOf(path);
  final j = next ? i + 1 : i - 1;
  return i >= 0 && j >= 0 && j < books.length ? books[j] : null;
}
