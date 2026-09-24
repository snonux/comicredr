import 'dart:typed_data';

enum SourceFormat {
  /// A ZIP, whatever its extension: `.cbz`, or a `.cbr` that is really a ZIP.
  zip,

  /// A genuine RAR. Out of scope: the reader says so and offers conversion.
  rar,
  pdf,
  unknown,
}

/// Dispatches on the first bytes rather than the file name (design plan
/// section 3), so a mislabelled `.cbr` opens as the ZIP it is.
SourceFormat sniffFormat(Uint8List head) {
  bool startsWith(List<int> magic) {
    if (head.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (head[i] != magic[i]) return false;
    }
    return true;
  }

  // PK\x03\x04 for a normal archive, PK\x05\x06 for an empty one.
  if (startsWith([0x50, 0x4B, 0x03, 0x04]) || startsWith([0x50, 0x4B, 0x05, 0x06])) {
    return SourceFormat.zip;
  }
  if (startsWith([0x52, 0x61, 0x72, 0x21])) return SourceFormat.rar; // Rar!
  if (startsWith([0x25, 0x50, 0x44, 0x46])) return SourceFormat.pdf; // %PDF
  return SourceFormat.unknown;
}
