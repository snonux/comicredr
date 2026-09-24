import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfrx_engine/pdfrx_engine.dart' as pdfrx;

import 'document.dart';

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
  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight}) async {
    final p = _doc.pages[index];
    // Page sizes are in points, 72 to the inch.
    final scale = math.min(math.min(targetWidth / p.width, targetHeight / p.height), maxDpi / 72);
    final w = math.max(1, (p.width * scale).round());
    final h = math.max(1, (p.height * scale).round());
    final image = await p.render(fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: 0xffffffff);
    if (image == null) throw FormatException('PDFium could not render page ${index + 1}');
    try {
      return PageImage(Uint8List.fromList(image.pixels), width: image.width, height: image.height, bgra: true);
    } finally {
      image.dispose();
    }
  }

  /// PDF pages have no stored image to hand back.
  @override
  Future<Uint8List?> rawPage(int index) async => null;

  /// PDFs carry no ComicInfo; the title comes from the file name.
  @override
  Future<ComicMeta?> embeddedMetadata() async => null;

  @override
  Future<void> close() => _doc.dispose();
}
