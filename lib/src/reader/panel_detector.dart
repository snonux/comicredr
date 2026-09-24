import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/foundation.dart';

import 'model_detector.dart';

/// What one detector found on one page.
class DetectedPage {
  const DetectedPage(this.frames, this.balloons, {required this.source, required this.version, required this.millis});

  /// Frames in left-to-right reading order.
  final List<Panel> frames;

  /// Balloons and captions, in no particular order. Classic CV finds none.
  final List<Panel> balloons;
  final PanelSource source;
  final int version;
  final int millis;
}

/// Finds the frames, and with the trained model the balloons, on a page,
/// off the UI isolate (design plan section 1).
///
/// With a model installed it runs the model and falls back to classic CV
/// only when the model fails on a page; without one it is classic CV, as in
/// M4. The page decodes straight to detection size through Flutter's native
/// codec, which runs on the engine's threads; the UI isolate only moves
/// bytes.
class PanelDetector {
  const PanelDetector({this.model});

  final ModelDetector? model;

  /// Which detector's cached results this detector would reproduce.
  PanelSource get source => model != null ? PanelSource.model : PanelSource.classicCv;
  int get version => model != null ? modelDetectorVersion : classicCvVersion;

  /// Releases the trained model before the app exits; see [ModelDetector.close].
  Future<void> close() async => model?.close();

  Future<DetectedPage> detect(ComicDocument doc, int page) async {
    final model = this.model;
    if (model != null) {
      try {
        final sw = Stopwatch()..start();
        final (rgba, w, h) = await pageRgba(doc, page, model.inputSize);
        final found = await model.detect(rgba, w, h);
        return DetectedPage(
          found.frames,
          found.balloons,
          source: PanelSource.model,
          version: modelDetectorVersion,
          millis: sw.elapsedMilliseconds,
        );
      } catch (e) {
        debugPrint('Model detection failed on page ${page + 1}, using classic CV: $e');
      }
    }
    final sw = Stopwatch()..start();
    final (rgba, w, h) = await pageRgba(doc, page, detectionLongSide);
    final frames = await _detectOnWorker(TransferableTypedData.fromList([rgba]), w, h);
    return DetectedPage(
      frames,
      const [],
      source: PanelSource.classicCv,
      version: classicCvVersion,
      millis: sw.elapsedMilliseconds,
    );
  }
}

/// Page [index] of [doc] as raw RGBA with the long side at most [longSide]:
/// rendered at that size for PDF, decoded down to it otherwise.
Future<(Uint8List, int, int)> pageRgba(ComicDocument doc, int index, int longSide) async {
  final page = await doc.page(index, targetWidth: longSide, targetHeight: longSide);
  if (!page.bgra) return decodeSmall(page.bytes, longSide);
  final px = page.bytes;
  for (var i = 0; i < px.length; i += 4) {
    final b = px[i];
    px[i] = px[i + 2];
    px[i + 2] = b;
  }
  return (px, page.width!, page.height!);
}

/// Decodes [bytes] with the long side at most [longSide] and returns raw
/// RGBA.
Future<(Uint8List, int, int)> decodeSmall(Uint8List bytes, int longSide) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final scale = longSide / math.max(descriptor.width, descriptor.height);
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
