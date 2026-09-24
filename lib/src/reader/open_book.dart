import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:path/path.dart' as p;

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

/// Opens [path] as a book: a CBZ, a CBT, a comic EPUB, a PDF or a folder
/// of page images.
/// Dispatches on the file's first bytes, not its extension, so a `.cbr`
/// that is really a ZIP opens as the ZIP it is.
Future<OpenBook> openBook(String path) async {
  path = p.normalize(path);
  final isDir = await FileSystemEntity.isDirectory(path);
  if (!isDir && !await File(path).exists()) throw OpenBookException('File not found: $path');
  switch (bookKind(path)) {
    case BookKind.cbz || BookKind.cbt || BookKind.epub || BookKind.pdf || BookKind.folder:
      break;
    case BookKind.rar:
      throw const OpenBookException(
        'This is a RAR archive. ComicRedr reads CBZ, so convert it once with '
        'unar and zip (see "The CBR files you already have" in the README).',
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

const _bookExtensions = {'.cbz', '.cbr', '.cbt', '.zip', '.epub', '.pdf'};

/// The next or previous book beside [path] in its folder, in natural order,
/// for `]` and `[`. Books are comic files and folders of page images, so a
/// folder of scans sits in line with the CBZs, EPUBs and PDFs around it. Null at
/// either end.
Future<String?> siblingBook(String path, {required bool next}) async {
  path = p.normalize(path);
  final dir = Directory(p.dirname(path));
  final books = <String>[];
  await for (final e in dir.list(followLinks: false)) {
    if (p.basename(e.path).startsWith('.')) continue;
    if (e is File && _bookExtensions.contains(p.extension(e.path).toLowerCase())) books.add(p.normalize(e.path));
    if (e is Directory && isFolderBook(e.path)) books.add(p.normalize(e.path));
  }
  books.sort((a, b) => naturalCompare(p.basename(a), p.basename(b)));
  final i = books.indexOf(path);
  final j = next ? i + 1 : i - 1;
  return i >= 0 && j >= 0 && j < books.length ? books[j] : null;
}
