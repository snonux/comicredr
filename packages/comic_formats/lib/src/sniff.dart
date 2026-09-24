import 'dart:convert';
import 'dart:typed_data';

enum SourceFormat {
  /// A ZIP, whatever its extension: `.cbz`, or a `.cbr` that is really a ZIP.
  zip,

  /// An EPUB: a ZIP whose first entry is the `mimetype` file naming it.
  epub,

  /// A tar archive: `.cbt`.
  tar,

  /// A genuine RAR. Out of scope: the reader says so and offers conversion.
  rar,
  pdf,
  unknown,
}

/// How many bytes [sniffFormat] wants: a tar header is 512.
const sniffLength = 512;

/// Dispatches on the first bytes rather than the file name (design plan
/// section 3), so a mislabelled `.cbr` opens as the ZIP it is.
SourceFormat sniffFormat(Uint8List head) {
  bool startsWith(List<int> magic, [int at = 0]) {
    if (head.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (head[at + i] != magic[i]) return false;
    }
    return true;
  }

  // PK\x03\x04 for a normal archive, PK\x05\x06 for an empty one.
  if (startsWith([0x50, 0x4B, 0x03, 0x04])) {
    return _isEpub(head) ? SourceFormat.epub : SourceFormat.zip;
  }
  if (startsWith([0x50, 0x4B, 0x05, 0x06])) return SourceFormat.zip;
  if (startsWith([0x52, 0x61, 0x72, 0x21])) return SourceFormat.rar; // Rar!
  if (startsWith([0x25, 0x50, 0x44, 0x46])) return SourceFormat.pdf; // %PDF
  if (isTarHeader(head)) return SourceFormat.tar;
  return SourceFormat.unknown;
}

/// The EPUB rule (OCF 3.0 section 4.3): the first local entry is named
/// `mimetype`, stored, and holds `application/epub+zip`. An EPUB that breaks
/// the rule still opens as one, since [openDocument] looks inside the ZIP;
/// this only lets the library tell it apart without inflating anything.
bool _isEpub(Uint8List head) {
  if (head.length < 30) return false;
  final data = ByteData.sublistView(head);
  final nameLength = data.getUint16(26, Endian.little);
  final extraLength = data.getUint16(28, Endian.little);
  final nameEnd = 30 + nameLength;
  if (nameLength != 8 || head.length < nameEnd) return false;
  if (latin1.decode(head.sublist(30, nameEnd)) != 'mimetype') return false;
  const type = 'application/epub+zip';
  final start = nameEnd + extraLength;
  if (head.length < start + type.length) return false;
  return latin1.decode(head.sublist(start, start + type.length)) == type;
}

/// Whether [block] starts with a tar header: `ustar` at offset 257 (POSIX and
/// GNU tar), or, for an old v7 archive without it, a header checksum that
/// adds up.
bool isTarHeader(Uint8List block) {
  if (block.length < 512) return false;
  if (latin1.decode(block.sublist(257, 262)) == 'ustar') return true;
  final stored = int.tryParse(latin1.decode(block.sublist(148, 156)).replaceAll('\x00', '').trim(), radix: 8);
  if (stored == null || block[0] == 0) return false;
  var sum = 0;
  for (var i = 0; i < 512; i++) {
    sum += (i >= 148 && i < 156) ? 0x20 : block[i];
  }
  return sum == stored;
}
