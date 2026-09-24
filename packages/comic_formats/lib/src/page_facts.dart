import 'dart:typed_data';

import 'image_size.dart';

/// What a page is made of, read from its header alone (see [imageFacts]):
/// for the details view (`I`), which says how good the scans in a book are.
class PageFacts {
  const PageFacts({
    required this.format,
    this.width,
    this.height,
    this.bytes,
    this.quality,
    this.progressive = false,
    this.gray = false,
    this.dpi,
  });

  /// `jpeg`, `png`, `webp`, `gif` or `bmp` for a stored image, `pdf` for a
  /// PDF page, `unknown` when the header is none of those.
  final String format;

  /// Pixels for a stored image, points (72 to the inch) for a PDF page.
  final int? width;
  final int? height;

  /// How many bytes the image takes, as stored; null for a PDF page.
  final int? bytes;

  /// A JPEG's quality setting, 1 to 100, estimated from its quantisation
  /// tables the way libjpeg sets them; null for anything else.
  final int? quality;

  /// A progressive JPEG.
  final bool progressive;

  /// Stored in shades of grey: a one-channel JPEG, or a greyscale PNG.
  final bool gray;

  /// The density the file claims (JFIF or PNG pHYs), when it claims one.
  /// Scanners write it; it says nothing about the pixels themselves.
  final int? dpi;

  bool get isPdf => format == 'pdf';

  /// Megapixels, for a stored image.
  double? get megapixels => width == null || height == null || isPdf ? null : width! * height! / 1e6;

  /// The page, with [bytes] filled in when the header did not know them.
  PageFacts withBytes(int n) => PageFacts(
    format: format,
    width: width,
    height: height,
    bytes: n,
    quality: quality,
    progressive: progressive,
    gray: gray,
    dpi: dpi,
  );

  static const unknown = PageFacts(format: 'unknown');
}

/// The facts [PageFacts] holds about the encoded page image [head], read from
/// its first bytes ([headBytes] covers nearly every JPEG's tables and frame
/// header); [total] is the whole image's stored size. [PageFacts.unknown]
/// when the header is none of the formats pages come in.
PageFacts imageFacts(Uint8List head, {int? total}) {
  final size = imageSize(head);
  final format = _format(head);
  if (format == 'jpeg') return _jpeg(head, size, total);
  if (format == 'png') return _png(head, size, total);
  return PageFacts(format: format, width: size?.$1, height: size?.$2, bytes: total);
}

String _format(Uint8List h) {
  bool at(int i, List<int> magic) {
    if (h.length < i + magic.length) return false;
    for (var k = 0; k < magic.length; k++) {
      if (h[i + k] != magic[k]) return false;
    }
    return true;
  }

  if (at(0, [0xFF, 0xD8])) return 'jpeg';
  if (at(0, [0x89, 0x50, 0x4E, 0x47])) return 'png';
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'webp';
  if (at(0, 'GIF'.codeUnits)) return 'gif';
  if (at(0, 'BM'.codeUnits)) return 'bmp';
  return 'unknown';
}

/// Walks a JPEG's markers up to the start of the scan: DQT for the quality,
/// SOF for the size, the channels and whether it is progressive, APP0 for
/// the density.
PageFacts _jpeg(Uint8List h, (int, int)? size, int? total) {
  final b = ByteData.sublistView(h);
  List<int>? luma;
  var progressive = false;
  var gray = false;
  int? dpi;
  var i = 2;
  while (i + 4 <= h.length) {
    if (h[i] != 0xFF) break;
    final marker = h[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) break; // The scan: the header is over.
    final len = b.getUint16(i + 2);
    final end = i + 2 + len;
    final body = i + 4;
    if (marker == 0xDB) {
      // One or more tables: precision and id, then 64 values in zigzag order.
      var t = body;
      while (t < end && t < h.length) {
        final wide = h[t] >> 4 == 1;
        final id = h[t] & 0x0F;
        final n = wide ? 128 : 64;
        if (t + 1 + n > h.length) break;
        final values = [for (var k = 0; k < 64; k++) wide ? b.getUint16(t + 1 + 2 * k) : h[t + 1 + k]];
        if (id == 0) luma ??= values;
        t += 1 + n;
      }
    } else if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
      progressive = marker == 0xC2 || marker == 0xC6 || marker == 0xCA || marker == 0xCE;
      if (body + 5 < h.length) gray = h[body + 5] == 1;
    } else if (marker == 0xE0 && body + 12 <= h.length && String.fromCharCodes(h, body, body + 4) == 'JFIF') {
      final units = h[body + 7];
      final x = b.getUint16(body + 8);
      // 1: dots per inch, 2: per centimetre. 0 is only an aspect ratio.
      if (units == 1 && x > 1) dpi = x;
      if (units == 2 && x > 1) dpi = (x * 2.54).round();
    }
    i = end;
  }
  return PageFacts(
    format: 'jpeg',
    width: size?.$1,
    height: size?.$2,
    bytes: total,
    quality: luma == null ? null : jpegQuality(luma),
    progressive: progressive,
    gray: gray,
    dpi: dpi,
  );
}

/// The PNG header's colour type, and the density from a pHYs chunk when
/// one comes before the image data.
PageFacts _png(Uint8List h, (int, int)? size, int? total) {
  final b = ByteData.sublistView(h);
  final gray = h.length > 25 && (h[25] == 0 || h[25] == 4);
  int? dpi;
  var i = 8;
  while (i + 12 <= h.length) {
    final len = b.getUint32(i);
    final type = String.fromCharCodes(h, i + 4, i + 8);
    if (type == 'IDAT' || type == 'IEND') break;
    if (type == 'pHYs' && i + 17 <= h.length && h[i + 16] == 1) {
      dpi = (b.getUint32(i + 8) * 0.0254).round(); // Pixels per metre.
      if (dpi <= 1) dpi = null;
    }
    i += 12 + len;
  }
  return PageFacts(format: 'png', width: size?.$1, height: size?.$2, bytes: total, gray: gray, dpi: dpi);
}

/// The luminance table of the JPEG standard (Annex K), in zigzag order as
/// DQT stores it, which libjpeg scales for every quality setting.
const _standardLuma = [
  16, 11, 12, 14, 12, 10, 16, 14, 13, 14, 18, 17, 16, 19, 24, 40, //
  26, 24, 22, 22, 24, 49, 35, 37, 29, 40, 58, 51, 61, 60, 57, 51,
  56, 55, 64, 72, 92, 78, 64, 68, 87, 69, 55, 56, 80, 109, 81, 87,
  95, 98, 103, 104, 103, 62, 77, 113, 121, 112, 100, 120, 92, 101, 103, 99,
];

/// The libjpeg quality (1 to 100) whose scaling of the standard luminance
/// table comes closest to [zigzag], a JPEG's own table. Encoders that use
/// other tables (some cameras, some Photoshop exports) come out near what
/// libjpeg would need for the same coarseness, which is what matters here.
int jpegQuality(List<int> zigzag) {
  var sum = 0.0;
  for (var k = 0; k < 64; k++) {
    sum += zigzag[k] * 100 / _standardLuma[k];
  }
  final scale = sum / 64;
  if (scale <= 0) return 100;
  final q = scale <= 100 ? (200 - scale) / 2 : 5000 / scale;
  return q.round().clamp(1, 100);
}
