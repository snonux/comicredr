import 'dart:io';
import 'dart:typed_data';

import 'comic_info.dart';
import 'document.dart';
import 'natural_sort.dart';

/// A directory of page images read as one book (design plan section 3).
///
/// Pages are the image files under the directory, subfolders included, in
/// natural order of their relative paths, with the same junk skipped as in a
/// CBZ. A `ComicInfo.xml` directly inside supplies the metadata.
class FolderDocument implements ComicDocument {
  FolderDocument._(this.root, this._pages);

  /// Lists [path]. Throws [FormatException] when it holds no page images.
  factory FolderDocument.open(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) throw FormatException('No such folder: $path');
    final root = dir.absolute.path;
    final pages = [
      for (final e in Directory(root).listSync(recursive: true, followLinks: false))
        if (e is File && isPageEntry(_relative(root, e.path))) _relative(root, e.path),
    ]..sort(naturalCompare);
    if (pages.isEmpty) throw FormatException('No page images in $path');
    return FolderDocument._(root, pages);
  }

  /// The folder, as an absolute path.
  final String root;
  final List<String> _pages;

  /// Page paths relative to [root], in reading order.
  List<String> get pageNames => List.unmodifiable(_pages);

  @override
  int get pageCount => _pages.length;

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight, PageRegion? region}) async =>
      PageImage(await _read(index));

  @override
  Future<Uint8List?> rawPage(int index) => _read(index);

  @override
  Future<ComicMeta?> embeddedMetadata() async {
    final info = File('$root/ComicInfo.xml');
    if (!info.existsSync()) return null;
    return parseComicInfo(await info.readAsString().catchError((_) => ''));
  }

  @override
  Future<void> close() async {}

  Future<Uint8List> _read(int index) => File('$root/${_pages[index]}').readAsBytes();

  static String _relative(String root, String path) => path.substring(root.length + 1).replaceAll('\\', '/');
}

/// Whether [path] is a folder that reads as a book: one holding page images
/// directly, not only in subfolders. Used to find sibling books, where a
/// folder of CBZ files or of chapter folders is not itself a book.
bool isFolderBook(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return false;
  try {
    return dir.listSync(followLinks: false).any((e) => e is File && isPageEntry(e.path.split('/').last));
  } on FileSystemException {
    return false;
  }
}
