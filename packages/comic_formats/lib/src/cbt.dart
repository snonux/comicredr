import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'comic_info.dart';
import 'document.dart';
import 'image_size.dart';
import 'natural_sort.dart';
import 'sniff.dart';

/// A tar comic: `.cbt`.
///
/// Tar has no index, so opening walks the headers once, seeking past each
/// entry's data, and remembers where every page starts. A page is then one
/// seek and one read, and nothing stays in memory but that list.
class CbtDocument implements ComicDocument {
  CbtDocument._(this._file, this._pages, this._comicInfo);

  /// Opens [path]. Throws [FormatException] when it is not a readable tar
  /// or holds no pages.
  factory CbtDocument.open(String path) {
    final file = File(path).openSync();
    try {
      final entries = _index(file, path);
      final pages = entries.where((e) => isPageEntry(e.name)).toList()..sort((a, b) => naturalCompare(a.name, b.name));
      if (pages.isEmpty) throw FormatException('No page images in $path');
      final info = entries.where((e) => e.name.split('/').last.toLowerCase() == 'comicinfo.xml').firstOrNull;
      return CbtDocument._(file, pages, info);
    } catch (e) {
      file.closeSync();
      if (e is FormatException) rethrow;
      throw FormatException('Not a readable tar: $path ($e)');
    }
  }

  final RandomAccessFile _file;
  final List<_Entry> _pages;
  final _Entry? _comicInfo;

  /// Entry names in reading order, for diagnostics and tests.
  List<String> get pageNames => [for (final p in _pages) p.name];

  @override
  int get pageCount => _pages.length;

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight, PageRegion? region}) async =>
      PageImage(_read(_pages[index]));

  @override
  Future<Uint8List?> rawPage(int index) async => _read(_pages[index]);

  @override
  Future<List<(int, int)?>> pageSizes() async => [
    for (final p in _pages) imageSize(_read(p, headBytes)) ?? (p.size > headBytes ? imageSize(_read(p)) : null),
  ];

  @override
  Future<ComicMeta?> embeddedMetadata() async {
    final info = _comicInfo;
    if (info == null) return null;
    return parseComicInfo(utf8.decode(_read(info), allowMalformed: true));
  }

  @override
  Future<void> close() async => _file.closeSync();

  // Synchronous, so two page requests on one document can never interleave
  // their seek and read.
  // [limit] reads only the start of the entry, for a page's size.
  Uint8List _read(_Entry e, [int? limit]) {
    final n = limit == null ? e.size : math.min(limit, e.size);
    _file.setPositionSync(e.offset);
    final out = Uint8List(n);
    final got = _file.readIntoSync(out);
    if (got != n) throw const FormatException('The tar ends inside a page');
    return out;
  }
}

class _Entry {
  const _Entry(this.name, this.offset, this.size);
  final String name;
  final int offset;
  final int size;
}

/// Every regular file in the tar, with where its data starts. Understands
/// the POSIX `prefix` field, GNU long names (`L`) and pax `path` and `size`
/// records (`x`), which is what GNU tar, bsdtar and Python's tarfile write.
List<_Entry> _index(RandomAccessFile file, String path) {
  final length = file.lengthSync();
  final header = Uint8List(512);
  final out = <_Entry>[];
  String? longName;
  Map<String, String> pax = const {};
  var pos = 0;
  var first = true;
  while (pos + 512 <= length) {
    file.setPositionSync(pos);
    if (file.readIntoSync(header) < 512) break;
    if (header.every((b) => b == 0)) break; // End of archive.
    if (!isTarHeader(header)) {
      if (first) throw FormatException('Not a tar: $path');
      throw FormatException('A damaged tar header at byte $pos in $path');
    }
    first = false;
    final type = header[156];
    final regular = type == 0x30 || type == 0x00 || type == 0x37; // File, old-style file, contiguous.
    // A pax size, for a file too big for the header, belongs to the file.
    final size = regular && pax['size'] != null ? int.parse(pax['size']!) : _size(header);
    final data = pos + 512;
    if (data + size > length) throw FormatException('The tar is cut short: $path');
    if (type == 0x4C) {
      // 'L': the next entry's long name.
      file.setPositionSync(data);
      longName = _cString(file.readSync(size));
    } else if (type == 0x78) {
      // 'x': pax records for the next entry.
      file.setPositionSync(data);
      pax = _pax(file.readSync(size));
    } else if (type != 0x67) {
      // 'g' is global pax records, which nothing here needs. Anything else
      // ends the long name and pax records: a file is kept, while
      // directories, links and devices are not pages.
      if (regular) out.add(_Entry(pax['path'] ?? longName ?? _name(header), data, size));
      longName = null;
      pax = const {};
    }
    pos = data + (size + 511) ~/ 512 * 512;
  }
  if (first) throw FormatException('Not a tar: $path');
  return out;
}

int _size(Uint8List h) {
  // Past 8 GiB GNU tar writes the size as big-endian binary, flagged by the
  // top bit of the first byte.
  if (h[124] & 0x80 != 0) {
    var v = h[124] & 0x7F;
    for (var i = 125; i < 136; i++) {
      v = v * 256 + h[i];
    }
    return v;
  }
  final s = latin1.decode(h.sublist(124, 136)).replaceAll('\x00', '').trim();
  return s.isEmpty ? 0 : int.parse(s, radix: 8);
}

String _name(Uint8List h) {
  final name = _cString(h.sublist(0, 100));
  // Only POSIX ustar ("ustar\0") has a prefix; GNU tar keeps times there.
  final posix = h[262] == 0 && latin1.decode(h.sublist(257, 262)) == 'ustar';
  final prefix = posix ? _cString(h.sublist(345, 500)) : '';
  return prefix.isEmpty ? name : '$prefix/$name';
}

String _cString(List<int> bytes) {
  final end = bytes.indexOf(0);
  return utf8.decode(end < 0 ? bytes : bytes.sublist(0, end), allowMalformed: true);
}

/// Pax records: `<length> <key>=<value>\n`, one after another.
Map<String, String> _pax(Uint8List bytes) {
  final out = <String, String>{};
  var i = 0;
  while (i < bytes.length) {
    final space = bytes.indexOf(0x20, i);
    if (space < 0) break;
    final n = int.tryParse(latin1.decode(bytes.sublist(i, space)));
    if (n == null || n <= 0 || i + n > bytes.length) break;
    final record = utf8.decode(bytes.sublist(space + 1, i + n - 1), allowMalformed: true);
    final eq = record.indexOf('=');
    if (eq > 0) out[record.substring(0, eq)] = record.substring(eq + 1);
    i += n;
  }
  return out;
}
