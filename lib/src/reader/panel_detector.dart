import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/foundation.dart';

import 'model_detector.dart';

/// What one detector found on one page.
class DetectedPage {
  const DetectedPage(
    this.frames,
    this.balloons, {
    required this.source,
    required this.version,
    required this.millis,
    this.trim = Trim.full,
  });

  /// Frames in left-to-right reading order.
  final List<Panel> frames;

  /// Balloons and captions, in no particular order. Classic CV finds none.
  final List<Panel> balloons;
  final PanelSource source;
  final int version;
  final int millis;

  /// The part of the page detection looked at, with the scanned margins cut
  /// off. [frames] and [balloons] are on the whole page all the same; the
  /// confidence gate judges them against this part (PagePanels).
  final Trim trim;
}

/// Finds the frames, and with the trained model the balloons, on a page,
/// off the UI isolate (design plan section 1).
///
/// With a model installed it runs the model and falls back to classic CV
/// only when the model fails on a page; without one it is classic CV, as in
/// M4. The page decodes straight to detection size through Flutter's native
/// codec, which runs on the engine's threads; the UI isolate only moves
/// bytes.
///
/// When a page has wide blank scanned margins, the model looks at it with
/// them cut off (findTrim), decoded again so the art still fills its input,
/// and the gate judges the frames against that part: before, the frames of
/// such a page covered too little of it and the page was shown whole (see
/// [detectionTrimArea] for the numbers). Classic CV keeps the whole page:
/// on trimmed pages it passed the gate with wrong frames far more often
/// than it got another page right (spike/evaluate.py).
class PanelDetector {
  const PanelDetector({this.model});

  final ModelDetector? model;

  /// Which detector's cached results this detector would reproduce.
  PanelSource get source => model != null ? PanelSource.model : PanelSource.classicCv;
  int get version => model?.version ?? classicCvVersion;

  Future<DetectedPage> detect(ComicDocument doc, int page) async {
    final model = this.model;
    if (model != null) {
      try {
        final sw = Stopwatch()..start();
        final (rgba, w, h, trim) = await trimmedPageRgba(doc, page, model.inputSize);
        final found = await model.detect(rgba, w, h);
        return DetectedPage(
          [for (final f in found.frames) trim.toPage(f)],
          [for (final b in found.balloons) trim.toPage(b)],
          source: PanelSource.model,
          version: model.version,
          millis: sw.elapsedMilliseconds,
          trim: trim,
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

/// Page [index] of [doc] as raw RGBA with the long side at most [longSide],
/// with its blank scanned margins cut off when they are wide (at most
/// [detectionTrimArea] of the page left), and the part of the page it is.
/// A trimmed page is decoded a second time, larger, so its art is as big as
/// a page without margins would be.
Future<(Uint8List, int, int, Trim)> trimmedPageRgba(ComicDocument doc, int index, int longSide) async {
  final (rgba, w, h) = await pageRgba(doc, index, longSide);
  final trim = await _measureOnWorker(TransferableTypedData.fromList([rgba]), w, h);
  if (trim.isFull || trim.width * trim.height > detectionTrimArea) return (rgba, w, h, Trim.full);
  final bigger = (longSide / math.max(trim.width, trim.height)).floor();
  final (big, bw, bh) = await pageRgba(doc, index, bigger);
  return _cropOnWorker(TransferableTypedData.fromList([big]), bw, bh, trim, longSide);
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

/// Top level, so the closures sent to the workers hold only their arguments.
Future<Trim> _measureOnWorker(TransferableTypedData rgba, int w, int h) =>
    Isolate.run(() => measureTrimRgba(rgba.materialize().asUint8List(), w, h, pad: detectionTrimPad));

/// The [trim] of a page, cut on whole pixels and kept within [longSide]:
/// a source image smaller than asked for comes back at its own size.
Future<(Uint8List, int, int, Trim)> _cropOnWorker(TransferableTypedData rgba, int w, int h, Trim trim, int longSide) =>
    Isolate.run(() {
      final (px, cw, ch, exact) = cropRgba(rgba.materialize().asUint8List(), w, h, trim);
      if (math.max(cw, ch) <= longSide) return (px, cw, ch, exact);
      // Rounding put a pixel over: drop it rather than scale.
      final (fit, fw, fh, _) = cropRgba(
        px,
        cw,
        ch,
        Trim(0, 0, math.min(cw, longSide) / cw, math.min(ch, longSide) / ch),
      );
      return (
        fit,
        fw,
        fh,
        Trim(exact.left, exact.top, exact.left + exact.width * fw / cw, exact.top + exact.height * fh / ch),
      );
    });

Future<List<Panel>> _detectOnWorker(TransferableTypedData rgba, int w, int h) =>
    Isolate.run(() => detectPanels(GrayImage.fromRgba(rgba.materialize().asUint8List(), w, h)).frames);
