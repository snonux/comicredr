import 'dart:typed_data';

/// How much of a page [imageSize] is given to read.
const headBytes = 64 << 10;

/// The pixel size of an encoded page image, read from its header alone:
/// JPEG, PNG, WebP, GIF or BMP. Null when [head] is too short to reach the
/// size or is none of those.
///
/// A JPEG's size sits in its frame header, after any EXIF and ICC blocks,
/// so a head of 64 KiB covers nearly every page; PNG, GIF, WebP and BMP
/// need their first 30 bytes.
(int, int)? imageSize(Uint8List head) {
  final b = ByteData.sublistView(head);
  int u8(int i) => head[i];
  if (head.length >= 24 && u8(0) == 0x89 && u8(1) == 0x50 && u8(2) == 0x4E && u8(3) == 0x47) {
    return (b.getUint32(16), b.getUint32(20));
  }
  if (head.length >= 10 && u8(0) == 0x47 && u8(1) == 0x49 && u8(2) == 0x46) {
    return (b.getUint16(6, Endian.little), b.getUint16(8, Endian.little));
  }
  if (head.length >= 26 && u8(0) == 0x42 && u8(1) == 0x4D) {
    return (b.getInt32(18, Endian.little).abs(), b.getInt32(22, Endian.little).abs());
  }
  if (head.length >= 30 && _ascii(head, 0, 'RIFF') && _ascii(head, 8, 'WEBP')) {
    if (_ascii(head, 12, 'VP8X')) {
      int u24(int i) => u8(i) | u8(i + 1) << 8 | u8(i + 2) << 16;
      return (u24(24) + 1, u24(27) + 1);
    }
    if (_ascii(head, 12, 'VP8L')) {
      final bits = b.getUint32(21, Endian.little);
      return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    }
    if (_ascii(head, 12, 'VP8 ')) {
      return (b.getUint16(26, Endian.little) & 0x3FFF, b.getUint16(28, Endian.little) & 0x3FFF);
    }
    return null;
  }
  if (head.length >= 4 && u8(0) == 0xFF && u8(1) == 0xD8) {
    var i = 2;
    while (i + 9 < head.length) {
      if (u8(i) != 0xFF) return null;
      final marker = u8(i + 1);
      if (marker == 0xFF) {
        i++; // Fill byte.
        continue;
      }
      // Start-of-frame markers, all but DHT (C4), JPG (C8) and DAC (CC).
      if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
        return (b.getUint16(i + 7), b.getUint16(i + 5));
      }
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2; // Markers without a length.
        continue;
      }
      i += 2 + b.getUint16(i + 2);
    }
  }
  return null;
}

bool _ascii(Uint8List b, int at, String s) {
  for (var k = 0; k < s.length; k++) {
    if (b[at + k] != s.codeUnitAt(k)) return false;
  }
  return true;
}
