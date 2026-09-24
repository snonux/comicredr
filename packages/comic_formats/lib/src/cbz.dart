import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'comic_info.dart';
import 'document.dart';
import 'natural_sort.dart';
import 'sniff.dart';

/// A ZIP comic: `.cbz`, or a `.cbr` that is really a ZIP.
///
/// Only the central directory is read on open. Each page is inflated on
/// demand into its own buffer and not kept, so a 300 MB book costs one page
/// of memory here; caching decoded pages is the reader's job.
class CbzDocument implements ComicDocument {
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
    final info = archive.files
        .where((f) => f.isFile && f.name.split('/').last.toLowerCase() == 'comicinfo.xml')
        .firstOrNull;
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
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight}) async =>
      PageImage(_read(_pages[index]));

  @override
  Future<Uint8List?> rawPage(int index) async => _read(_pages[index]);

  @override
  Future<ComicMeta?> embeddedMetadata() async {
    final info = _comicInfo;
    if (info == null) return null;
    return parseComicInfo(utf8.decode(_read(info), allowMalformed: true));
  }

  @override
  Future<void> close() async => _input.closeSync();

  static Uint8List _read(ArchiveFile f) {
    final out = OutputMemoryStream(size: f.size > 0 ? f.size : 1 << 16);
    f.decompress(out);
    return out.getBytes();
  }
}

/// Reads [input]'s ZIP central directory. Throws [FormatException] when it
/// is not a readable ZIP.
Archive decodeZip(InputFileStream input, String path) {
  try {
    return ZipDecoder().decodeStream(input);
  } catch (e) {
    throw FormatException('Not a readable ZIP: $path ($e)');
  }
}

/// Whether a ZIP is an EPUB: it has a container file and its `mimetype`
/// entry says so, wherever in the archive that entry sits.
bool isEpubArchive(Archive archive) {
  if (archive.findFile('META-INF/container.xml') == null) return false;
  final mimetype = archive.findFile('mimetype');
  if (mimetype == null) return true; // A container file is EPUB enough.
  return utf8.decode(mimetype.content, allowMalformed: true).trim() == 'application/epub+zip';
}

/// Reads the first bytes of a file, for [sniffFormat].
Uint8List readHead(String path, [int bytes = sniffLength]) {
  final f = File(path).openSync();
  try {
    return f.readSync(bytes);
  } finally {
    f.closeSync();
  }
}
