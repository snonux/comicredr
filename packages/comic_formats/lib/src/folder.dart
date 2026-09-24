import 'dart:io';
import 'dart:typed_data';

import 'comic_info.dart';
import 'document.dart';
import 'image_size.dart';
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
  Future<List<(int, int)?>> pageSizes() async => [for (var i = 0; i < _pages.length; i++) await _size(i)];

  Future<(int, int)?> _size(int index) async {
    try {
      final f = await File('$root/${_pages[index]}').open();
      try {
        final head = await f.read(headBytes);
        if (imageSize(head) case final size?) return size;
        return await f.length() > headBytes ? imageSize(await _read(index)) : null;
      } finally {
        await f.close();
      }
    } on FileSystemException {
      return null;
    }
  }

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

/// Extensions of the files the library lists as books: archives, EPUBs and
/// PDFs. Loose images count too, see [singleImageExtensions].
const comicFileExtensions = {'.cbz', '.cbr', '.cbt', '.zip', '.epub', '.pdf'};

/// Extensions of an image file that is a comic of its own, one page long,
/// when it is not a page of a folder book (see [isFolderBook]).
const singleImageExtensions = {'.png', '.jpg', '.jpeg', '.webp'};

String _ext(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot).toLowerCase() : '';
}

/// Whether [name] is a comic file: a CBZ, CBR, CBT, ZIP, EPUB or PDF.
bool isComicFileName(String name) => !name.startsWith('.') && comicFileExtensions.contains(_ext(name));

/// Whether [name] is a PNG, JPEG or WebP that can be a one-page comic.
bool isSingleImageName(String name) => !name.startsWith('.') && singleImageExtensions.contains(_ext(name));

/// Whether [path] is a folder that reads as a book: one holding page images
/// directly, not only in subfolders, and no comic file anywhere under it.
/// A folder of CBZ files or of chapter folders is not itself a book, and
/// neither is one where a loose image sits beside a CBZ: that image is a
/// one-page comic of its own.
bool isFolderBook(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return false;
  try {
    final entries = dir.listSync(followLinks: false);
    return entries.any((e) => e is File && isPageEntry(e.path.split('/').last)) && !holdsComicFiles(entries);
  } on FileSystemException {
    return false;
  }
}

/// Whether [entries], or any folder among them, holds a comic file. Hidden
/// files and folders are skipped, as the library skips them.
bool holdsComicFiles(List<FileSystemEntity> entries) {
  for (final e in entries) {
    final name = e.path.split('/').last;
    if (name.startsWith('.')) continue;
    if (e is File && isComicFileName(name)) return true;
    if (e is Directory) {
      try {
        if (holdsComicFiles(e.listSync(followLinks: false))) return true;
      } on FileSystemException {
        // Unreadable: nothing in it the library could list either.
      }
    }
  }
  return false;
}
