import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

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

/// ZIP entry [f], inflated whole into a buffer of its own.
Uint8List inflateEntry(ArchiveFile f) {
  final out = OutputMemoryStream(size: f.size > 0 ? f.size : 1 << 16);
  f.decompress(out);
  return out.getBytes();
}

/// The first [n] bytes of ZIP entry [f], inflating only as much as they
/// need: a page's size is in its header, and inflating every page of a book
/// whole would take seconds. Empty when the entry cannot be read, which
/// the archive reader reports in more ways than exceptions alone.
Uint8List entryHead(ArchiveFile f, int n) {
  try {
    final zip = f.rawContent;
    if (zip is! ZipFile) return inflateEntry(f);
    final raw = zip.getStream(decompress: false);
    final start = raw.position;
    try {
      switch (zip.compressionMethod) {
        case CompressionType.none:
          return raw.peekBytes(math.min(n, raw.length)).toUint8List();
        case CompressionType.deflate:
          final inflate = RawZLibFilter.inflateFilter(raw: true);
          final out = BytesBuilder(copy: false);
          while (out.length < n && !raw.isEOS) {
            final chunk = raw.readBytes(math.min(16 << 10, raw.length)).toUint8List();
            if (chunk.isEmpty) break;
            inflate.process(chunk, 0, chunk.length);
            for (List<int>? o; (o = inflate.processed(flush: false)) != null;) {
              out.add(o!);
            }
          }
          return out.takeBytes();
        default:
          return inflateEntry(f);
      }
    } finally {
      raw.setPosition(start);
    }
  } catch (_) {
    return Uint8List(0);
  }
}

/// [StoredPages] reads for pages that are ZIP entries (CBZ and EPUB). A
/// damaged entry reads as a [FormatException], whatever the archive reader
/// threw, so it costs that page only.
Future<Uint8List> readEntry(ArchiveFile f) async {
  try {
    return inflateEntry(f);
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('Cannot inflate ${f.name}: $e');
  }
}
