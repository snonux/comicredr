import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'comic_info.dart';
import 'document.dart';
import 'natural_sort.dart';
import 'stored_pages.dart';
import 'zip_entries.dart';

/// A ZIP comic: `.cbz`, or a `.cbr` that is really a ZIP.
///
/// Only the central directory is read on open. Each page is inflated on
/// demand into its own buffer and not kept, so a 300 MB book costs one page
/// of memory here; caching decoded pages is the reader's job.
class CbzDocument with StoredPages implements ComicDocument {
  CbzDocument._(this._input, this._pages, this._comicInfo);

  /// Opens [path]. Throws [FormatException] when it is not a readable ZIP
  /// or holds no pages.
  factory CbzDocument.open(String path) {
    final input = InputFileStream(path);
    try {
      return CbzDocument.fromArchive(input, decodeZip(input, path), path);
    } catch (_) {
      input.closeSync();
      rethrow;
    }
  }

  /// The comic whose ZIP directory is [archive], read from [input], which it
  /// then owns. Throws [FormatException] when it holds no pages; [input] is
  /// left for the caller to close then.
  factory CbzDocument.fromArchive(InputFileStream input, Archive archive, String path) {
    final pages = archive.files.where((f) => f.isFile && isPageEntry(f.name)).toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    if (pages.isEmpty) {
      throw FormatException('No page images in $path');
    }
    final info = archive.files.where((f) => f.isFile && isComicInfoName(f.name)).firstOrNull;
    return CbzDocument._(input, pages, info);
  }

  final InputFileStream _input;
  final List<ArchiveFile> _pages;
  final ArchiveFile? _comicInfo;

  /// Entry names in reading order, for diagnostics and tests.
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
  Future<ComicMeta?> embeddedMetadata() async {
    final info = _comicInfo;
    if (info == null) return null;
    return parseComicInfo(utf8.decode(inflateEntry(info), allowMalformed: true));
  }

  @override
  Future<void> close() async => _input.closeSync();
}
