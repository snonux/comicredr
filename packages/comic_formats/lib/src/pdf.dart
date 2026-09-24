import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfrx_engine/pdfrx_engine.dart' as pdfrx;

import 'document.dart';
import 'page_facts.dart';

/// A PDF comic, rendered through PDFium (`pdfrx_engine`).
///
/// Pages render straight to the size they are shown at (design plan section
/// 3), so a 600 dpi scan never becomes a full-resolution bitmap, and never
/// above [maxDpi], past which a scan has no more detail to give.
class PdfComicDocument implements ComicDocument {
  PdfComicDocument._(this._doc);

  /// Opens [path]. Throws [FormatException] when PDFium cannot read it, or
  /// it has no pages.
  static Future<PdfComicDocument> open(String path) async {
    await pdfrx.pdfrxInitialize();
    final pdfrx.PdfDocument doc;
    try {
      doc = await pdfrx.PdfDocument.openFile(path);
    } catch (e) {
      throw FormatException('Not a readable PDF: $path ($e)');
    }
    if (doc.pages.isEmpty) {
      await doc.dispose();
      throw FormatException('No pages in $path');
    }
    return PdfComicDocument._(doc);
  }

  /// Renders stop here: 300 dpi is past what any comic scan carries.
  static const maxDpi = 300.0;

  final pdfrx.PdfDocument _doc;

  @override
  int get pageCount => _doc.pages.length;

  /// The page fitted inside [targetWidth] x [targetHeight], as raw BGRA.
  /// With a [region], only that part, at the scale the whole page has in
  /// the box: a page zoomed into is never rendered whole at that scale.
  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight, PageRegion? region}) async {
    final p = _doc.pages[index];
    // Page sizes are in points, 72 to the inch.
    final scale = math.min(math.min(targetWidth / p.width, targetHeight / p.height), maxDpi / 72);
    final w = math.max(1, (p.width * scale).round());
    final h = math.max(1, (p.height * scale).round());
    var (x, y, rw, rh) = (0, 0, w, h);
    if (region != null) {
      x = (region.left * w).floor().clamp(0, w - 1);
      y = (region.top * h).floor().clamp(0, h - 1);
      rw = ((region.left + region.width) * w).ceil().clamp(x + 1, w) - x;
      rh = ((region.top + region.height) * h).ceil().clamp(y + 1, h) - y;
    }
    final image = await p.render(
      x: x,
      y: y,
      width: rw,
      height: rh,
      fullWidth: w.toDouble(),
      fullHeight: h.toDouble(),
      backgroundColor: 0xffffffff,
    );
    if (image == null) throw FormatException('PDFium could not render page ${index + 1}');
    try {
      return PageImage(
        Uint8List.fromList(image.pixels),
        width: image.width,
        height: image.height,
        bgra: true,
        // The pixels actually drawn, which rounding may have moved a little.
        region: region == null ? null : (left: x / w, top: y / h, width: rw / w, height: rh / h),
      );
    } finally {
      image.dispose();
    }
  }

  /// PDF pages have no stored image to hand back.
  @override
  Future<Uint8List?> rawPage(int index) async => null;

  @override
  Future<List<(int, int)?>> pageSizes() async => [for (final p in _doc.pages) (p.width.round(), p.height.round())];

  @override
  Future<List<PageFacts>> pageFacts() async => [
    for (final p in _doc.pages) PageFacts(format: 'pdf', width: p.width.round(), height: p.height.round()),
  ];

  /// PDFs carry no ComicInfo; the title comes from the file name.
  @override
  Future<ComicMeta?> embeddedMetadata() async => null;

  @override
  Future<void> close() => _doc.dispose();
}
