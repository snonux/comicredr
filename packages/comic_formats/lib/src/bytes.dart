import 'dart:typed_data';

/// Whether [bytes] hold [magic] at offset [at]; false when they are too
/// short to.
bool hasBytesAt(Uint8List bytes, int at, List<int> magic) {
  if (at < 0 || bytes.length < at + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[at + i] != magic[i]) return false;
  }
  return true;
}

/// A JPEG marker segment: its [marker] byte, where it starts (at the 0xFF
/// before the marker) and where the next one starts.
typedef JpegSegment = ({int marker, int start, int end});

/// The marker segments of a JPEG's header [h], in order, up to the start of
/// the scan (SOS) or wherever [h] runs out. Stray bytes, fill bytes and the
/// markers that carry no length (SOI, TEM, RST0-7) are stepped over.
Iterable<JpegSegment> jpegSegments(Uint8List h) sync* {
  final b = ByteData.sublistView(h);
  var i = 2;
  while (i + 4 <= h.length) {
    if (h[i] != 0xFF) {
      i++; // Stray bytes between segments: libjpeg skips them, so do we.
      continue;
    }
    final marker = h[i + 1];
    if (marker == 0xFF) {
      i++; // Fill byte.
      continue;
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2; // Markers without a length.
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return; // The scan: the header is over.
    final end = i + 2 + b.getUint16(i + 2);
    yield (marker: marker, start: i, end: end);
    i = end;
  }
}

/// Whether [marker] starts a JPEG frame (SOF0 to SOF15), which holds the
/// image's size: C0 to CF except DHT (C4), JPG (C8) and DAC (CC).
bool isJpegFrameMarker(int marker) =>
    marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
