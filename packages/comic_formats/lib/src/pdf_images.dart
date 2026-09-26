import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'bytes.dart';
import 'image_size.dart';
import 'page_facts.dart';

/// One image a PDF holds: a scanned page, usually, in a comic.
class PdfImage {
  const PdfImage({
    required this.width,
    required this.height,
    required this.filter,
    this.bits,
    this.gray = false,
    this.quality,
  });

  final int width;
  final int height;

  /// How it is compressed: `jpeg` (DCTDecode), `jpeg2000` (JPXDecode),
  /// `flate`, `ccitt`, `jbig2`, or `raw`.
  final String filter;
  final int? bits;
  final bool gray;

  /// A JPEG's estimated quality setting (see [jpegQuality]).
  final int? quality;
}

/// The image XObjects in the PDF at [path], found by reading the file
/// rather than through PDFium, so it can run on any isolate: an image is
/// always a stream object of its own, never packed in an object stream, so
/// its dictionary is there in the file as written. An image whose size is
/// an indirect reference is skipped.
///
/// Reads the whole file once, in chunks; a few hundred megabytes take a
/// second or two. PDFium has no call that lists a page's images.
List<PdfImage> pdfImages(String path) {
  final file = File(path).openSync();
  try {
    final length = file.lengthSync();
    const chunk = 4 << 20, overlap = 2048;
    final found = <int, PdfImage>{};
    final needle = ascii.encode('/Image');
    for (var base = 0; base < length; base += chunk) {
      file.setPositionSync(math.max(0, base - overlap));
      final start = math.max(0, base - overlap);
      final data = file.readSync(math.min(chunk + overlap, length - start));
      for (var i = 0; i + needle.length <= data.length; i++) {
        if (data[i] != 0x2F || !hasBytesAt(data, i, needle)) continue;
        final after = i + needle.length < data.length ? data[i + needle.length] : 0x20;
        if (_nameChar(after)) continue; // /ImageB, /ImageMask and the like.
        final at = start + i;
        if (found.containsKey(at)) continue;
        final image = _image(file, data, i, start);
        if (image != null) found[at] = image;
      }
    }
    return found.values.toList();
  } finally {
    file.closeSync();
  }
}

/// Whether [c] continues a PDF name: anything but white space and
/// delimiters.
bool _nameChar(int c) => !(c <= 0x20 || '()<>[]{}/%'.codeUnits.contains(c));

final _subtype = RegExp(r'/Subtype\s*/Image$');
// `(?!\d)` keeps the digits whole, so `/Width 1200 0 R` (a reference) can't
// match as `120` followed by `0 0 R`.
final _width = RegExp(r'/Width\s+(\d+)(?!\d)(?!\s+\d+\s+R)');
final _height = RegExp(r'/Height\s+(\d+)(?!\d)(?!\s+\d+\s+R)');
final _bits = RegExp(r'/BitsPerComponent\s+(\d+)');

/// The image whose `/Subtype /Image` ends at [i] in [data] (read from file
/// offset [start]), or null when this `/Image` is something else.
PdfImage? _image(RandomAccessFile file, Uint8List data, int i, int start) {
  final from = math.max(0, i - 2048);
  final before = latin1.decode(data.sublist(from, i + 6));
  if (!_subtype.hasMatch(before)) return null;
  // The dictionary runs from its object header to the stream keyword.
  final objAt = before.lastIndexOf(RegExp(r'\d+\s+\d+\s+obj'));
  final head = objAt < 0 ? before : before.substring(objAt);
  final to = math.min(data.length, i + 4096);
  final rest = latin1.decode(data.sublist(i + 6, to));
  final streamAt = rest.indexOf('stream');
  if (streamAt < 0) return null;
  final dict = head + rest.substring(0, streamAt);
  final w = int.tryParse(_width.firstMatch(dict)?[1] ?? '');
  final h = int.tryParse(_height.firstMatch(dict)?[1] ?? '');
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  final filter = dict.contains('/DCTDecode')
      ? 'jpeg'
      : dict.contains('/JPXDecode')
      ? 'jpeg2000'
      : dict.contains('/JBIG2Decode')
      ? 'jbig2'
      : dict.contains('/CCITTFaxDecode')
      ? 'ccitt'
      : dict.contains('/FlateDecode')
      ? 'flate'
      : 'raw';
  int? quality;
  var gray = dict.contains('/DeviceGray') || filter == 'ccitt' || filter == 'jbig2';
  if (filter == 'jpeg') {
    // The stream data starts after the keyword and its end of line.
    var off = start + i + 6 + streamAt + 'stream'.length;
    file.setPositionSync(off);
    final eol = file.readSync(2);
    off += eol.isNotEmpty && eol[0] == 0x0D ? (eol.length > 1 && eol[1] == 0x0A ? 2 : 1) : 1;
    file.setPositionSync(off);
    final facts = imageFacts(file.readSync(headBytes));
    quality = facts.quality;
    gray = gray || facts.gray;
  }
  return PdfImage(
    width: w,
    height: h,
    filter: filter,
    bits: int.tryParse(_bits.firstMatch(dict)?[1] ?? ''),
    gray: gray,
    quality: quality,
  );
}
