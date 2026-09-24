import 'dart:io';

import 'cbz.dart';
import 'document.dart';
import 'folder.dart';
import 'pdf.dart';
import 'sniff.dart';

/// What kind of book a path holds, decided by its content: a directory is a
/// folder book, a file goes by its first bytes (design plan section 3).
enum BookKind { cbz, pdf, folder, rar, unknown }

BookKind bookKind(String path) {
  if (FileSystemEntity.isDirectorySync(path)) return BookKind.folder;
  return switch (sniffFormat(readHead(path))) {
    SourceFormat.zip => BookKind.cbz,
    SourceFormat.pdf => BookKind.pdf,
    SourceFormat.rar => BookKind.rar,
    SourceFormat.unknown => BookKind.unknown,
  };
}

/// Opens [path] with the adapter its [bookKind] calls for, on the calling
/// isolate. Throws [FormatException] for a RAR, an unknown file, or a book
/// its adapter cannot read.
Future<ComicDocument> openDocument(String path) async => switch (bookKind(path)) {
  BookKind.cbz => CbzDocument.open(path),
  BookKind.pdf => await PdfComicDocument.open(path),
  BookKind.folder => FolderDocument.open(path),
  BookKind.rar => throw FormatException('A RAR archive: $path'),
  BookKind.unknown => throw FormatException('Not a comic: $path'),
};
