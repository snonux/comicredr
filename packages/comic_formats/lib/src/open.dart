import 'dart:io';

import 'package:archive/archive.dart';

import 'cbt.dart';
import 'cbz.dart';
import 'document.dart';
import 'epub.dart';
import 'folder.dart';
import 'image.dart';
import 'pdf.dart';
import 'sniff.dart';
import 'zip_entries.dart';

/// What kind of book a path holds, decided by its content: a directory is a
/// folder book, a file goes by its first bytes (design plan section 3). An
/// [image] is a PNG, JPEG or WebP file read as a one-page comic.
enum BookKind { cbz, cbt, epub, pdf, folder, image, rar, unknown }

BookKind bookKind(String path) {
  if (FileSystemEntity.isDirectorySync(path)) return BookKind.folder;
  return switch (sniffFormat(readHead(path))) {
    SourceFormat.zip => BookKind.cbz,
    SourceFormat.epub => BookKind.epub,
    SourceFormat.tar => BookKind.cbt,
    SourceFormat.pdf => BookKind.pdf,
    SourceFormat.image => BookKind.image,
    SourceFormat.rar => BookKind.rar,
    SourceFormat.unknown => BookKind.unknown,
  };
}

/// Opens [path] with the adapter its [bookKind] calls for, on the calling
/// isolate. Throws [FormatException] for a RAR, an unknown file, or a book
/// its adapter cannot read, such as a text EPUB.
Future<ComicDocument> openDocument(String path) async => switch (bookKind(path)) {
  BookKind.cbz || BookKind.epub => _openZip(path),
  BookKind.cbt => CbtDocument.open(path),
  BookKind.pdf => await PdfComicDocument.open(path),
  BookKind.folder => FolderDocument.open(path),
  BookKind.image => ImageDocument.open(path),
  BookKind.rar => throw FormatException('A RAR archive: $path'),
  BookKind.unknown => throw FormatException('Not a comic: $path'),
};

/// A ZIP is an EPUB when its insides say so, even one whose `mimetype`
/// entry is not first and so escaped [sniffFormat]; otherwise a CBZ.
ComicDocument _openZip(String path) {
  final input = InputFileStream(path);
  try {
    final archive = decodeZip(input, path);
    if (isEpubArchive(archive)) return EpubDocument.fromArchive(input, archive, path);
    return CbzDocument.fromArchive(input, archive, path);
  } catch (_) {
    input.closeSync();
    rethrow;
  }
}
