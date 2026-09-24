import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:path/path.dart' as p;

/// A book the reader has open: the document plus what identifies it.
class OpenBook {
  OpenBook({required this.path, required this.key, required this.doc, this.meta});

  final String path;

  /// Content key: progress follows the content, not the file name.
  final String key;
  final ComicDocument doc;
  final ComicMeta? meta;

  String get title {
    final m = meta;
    if (m?.series != null) {
      return [m!.series, if (m.number != null) '#${m.number}', if (m.title != null) '· ${m.title}'].join(' ');
    }
    return p.basenameWithoutExtension(path);
  }
}

/// Why a file could not be opened, phrased for the person reading.
class OpenBookException implements Exception {
  const OpenBookException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Opens [path] as a book. Dispatches on the file's first bytes, not its
/// extension, so a `.cbr` that is really a ZIP opens as the ZIP it is.
Future<OpenBook> openBook(String path) async {
  final file = File(path);
  if (!await file.exists()) throw OpenBookException('File not found: $path');
  final format = sniffFormat(readHead(path));
  switch (format) {
    case SourceFormat.zip:
      break;
    case SourceFormat.rar:
      throw const OpenBookException(
        'This is a RAR archive. ComicRedr reads CBZ, so convert it once with '
        'unar and zip (see "The CBR files you already have" in the README).',
      );
    case SourceFormat.pdf:
      throw const OpenBookException('PDF support arrives in M6. CBZ files open today.');
    case SourceFormat.unknown:
      throw OpenBookException('Not a comic archive: ${p.basename(path)}');
  }
  final ComicDocument doc;
  try {
    doc = await BackgroundDocument.openCbz(path);
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
  return OpenBook(path: path, key: key, doc: doc, meta: meta);
}

const _bookExtensions = {'.cbz', '.cbr', '.zip'};

/// The next or previous book beside [path] in its folder, in natural order,
/// for `]` and `[`. Null at either end.
Future<String?> siblingBook(String path, {required bool next}) async {
  final dir = Directory(p.dirname(path));
  final books = await dir
      .list(followLinks: false)
      .where((e) => e is File && _bookExtensions.contains(p.extension(e.path).toLowerCase()))
      .map((e) => e.path)
      .toList();
  books.sort((a, b) => naturalCompare(p.basename(a), p.basename(b)));
  final i = books.indexOf(path);
  final j = next ? i + 1 : i - 1;
  return i >= 0 && j >= 0 && j < books.length ? books[j] : null;
}
