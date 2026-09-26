import 'dart:io';
import 'dart:typed_data';

import 'document.dart';
import 'stored_pages.dart';

/// A single PNG, JPEG or WebP file read as a one-page comic: a strip or a
/// one-pager that never went into an archive.
class ImageDocument with StoredPages implements ComicDocument {
  ImageDocument._(this.path);

  /// Checks [path] exists. Throws [FormatException] when it does not.
  factory ImageDocument.open(String path) {
    if (!File(path).existsSync()) throw FormatException('No such file: $path');
    return ImageDocument._(path);
  }

  final String path;

  @override
  int get pageCount => 1;

  @override
  Future<Uint8List> storedPage(int index) => _file(index).readAsBytes();

  @override
  Future<Uint8List> storedHead(int index, int n) => readFileHead(_file(index), n);

  @override
  Future<int> storedLength(int index) => _file(index).length();

  @override
  Future<ComicMeta?> embeddedMetadata() async => null;

  @override
  Future<void> close() async {}

  File _file(int index) {
    RangeError.checkValidIndex(index, this, 'index', 1);
    return File(path);
  }
}
