import 'dart:io';
import 'dart:typed_data';

import 'document.dart';
import 'image_size.dart';

/// A single PNG, JPEG or WebP file read as a one-page comic: a strip or a
/// one-pager that never went into an archive.
class ImageDocument implements ComicDocument {
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
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight, PageRegion? region}) async =>
      PageImage(await _read(index));

  @override
  Future<Uint8List?> rawPage(int index) => _read(index);

  @override
  Future<List<(int, int)?>> pageSizes() async {
    try {
      final f = await File(path).open();
      try {
        final head = await f.read(headBytes);
        if (imageSize(head) case final size?) return [size];
        return [await f.length() > headBytes ? imageSize(await _read(0)) : null];
      } finally {
        await f.close();
      }
    } on FileSystemException {
      return [null];
    }
  }

  @override
  Future<ComicMeta?> embeddedMetadata() async => null;

  @override
  Future<void> close() async {}

  Future<Uint8List> _read(int index) {
    RangeError.checkValidIndex(index, this, 'index', 1);
    return File(path).readAsBytes();
  }
}
