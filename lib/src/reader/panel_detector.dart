import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';

/// Finds the frames on a page, off the UI isolate (design plan section 1).
///
/// The page decodes straight to detection size through Flutter's native
/// codec, which runs on the engine's threads; the classic-CV pass then runs
/// on a short-lived worker isolate. The UI isolate only moves bytes.
class PanelDetector {
  const PanelDetector();

  /// Frames in left-to-right reading order, and how long detection took.
  Future<(List<Panel>, int)> detect(ComicDocument doc, int page) async {
    final bytes = await doc.rawPage(page) ?? (await doc.page(page, targetWidth: 1200, targetHeight: 1200)).encoded;
    final sw = Stopwatch()..start();
    final (rgba, w, h) = await _decodeSmall(bytes);
    final frames = await _detectOnWorker(TransferableTypedData.fromList([rgba]), w, h);
    return (frames, sw.elapsedMilliseconds);
  }
}

/// Decodes [bytes] with the long side at [detectionLongSide] and returns
/// raw RGBA.
Future<(Uint8List, int, int)> _decodeSmall(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final scale = detectionLongSide / math.max(descriptor.width, descriptor.height);
  final codec = await descriptor.instantiateCodec(
    targetWidth: scale < 1 ? (descriptor.width * scale).round() : null,
    targetHeight: scale < 1 ? (descriptor.height * scale).round() : null,
  );
  final image = (await codec.getNextFrame()).image;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return (data!.buffer.asUint8List(), image.width, image.height);
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

/// Top level, so the closure sent to the worker holds only these three.
Future<List<Panel>> _detectOnWorker(TransferableTypedData rgba, int w, int h) =>
    Isolate.run(() => detectPanels(GrayImage.fromRgba(rgba.materialize().asUint8List(), w, h)).frames);
