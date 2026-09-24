import 'dart:typed_data';

import 'panel.dart';
import 'reading_order.dart';

/// Bumped whenever the shipped model, its input size or its thresholds
/// change, so pages cached from an older model are detected again.
const modelDetectorVersion = 1;

/// What the trained detector found on a page, normalised to the page.
class ModelDetection {
  const ModelDetection(this.frames, this.balloons);

  /// Frames in reading order.
  final List<Panel> frames;

  /// Speech, thought and caption balloons, in no particular order;
  /// [balloonsByFrame] sorts them per frame.
  final List<Panel> balloons;
}

/// The model's input: an RGBA image of [w] x [h] (the page, already scaled
/// so its long side is at most [size]) placed top-left on a [size] x [size]
/// grey (114) canvas, as float32 planes R, G, B in 0..1. This is the
/// letterbox the model was trained and exported with (spike/export_onnx.py).
Float32List letterboxTensor(Uint8List rgba, int w, int h, int size) {
  final plane = size * size;
  final out = Float32List(3 * plane)..fillRange(0, 3 * plane, 114 / 255);
  const inv = 1 / 255;
  for (var y = 0; y < h && y < size; y++) {
    final row = y * w * 4;
    final dst = y * size;
    for (var x = 0; x < w && x < size; x++) {
      final s = row + x * 4;
      out[dst + x] = rgba[s] * inv;
      out[plane + dst + x] = rgba[s + 1] * inv;
      out[2 * plane + dst + x] = rgba[s + 2] * inv;
    }
  }
  return out;
}

/// Turns the model's output rows into frames and balloons.
///
/// [rows] is the flat [N, 6] output of the NMS-free YOLO26 head: x0, y0,
/// x1, y1 in input pixels, score, class. [w] and [h] are the size of the
/// page inside the letterbox, in the same pixels. Boxes are clipped to the
/// page, thresholded per class, and near-duplicates (IoU above 0.7) folded
/// into the higher-scoring one.
ModelDetection decodeDetections(
  List<double> rows,
  int w,
  int h, {
  int frameClass = 0,
  int balloonClass = 2,
  double frameConf = 0.5,
  double balloonConf = 0.4,
  bool rightToLeft = false,
}) {
  final frames = <Panel>[];
  final balloons = <Panel>[];
  for (var i = 0; i + 5 < rows.length; i += 6) {
    final score = rows[i + 4];
    final cls = rows[i + 5].round();
    final kind = cls == frameClass
        ? PanelKind.frame
        : cls == balloonClass
        ? PanelKind.balloon
        : null;
    if (kind == null || score < (kind == PanelKind.frame ? frameConf : balloonConf)) continue;
    final x0 = (rows[i] / w).clamp(0.0, 1.0);
    final y0 = (rows[i + 1] / h).clamp(0.0, 1.0);
    final x1 = (rows[i + 2] / w).clamp(0.0, 1.0);
    final y1 = (rows[i + 3] / h).clamp(0.0, 1.0);
    if (x1 <= x0 || y1 <= y0) continue;
    (kind == PanelKind.frame ? frames : balloons).add(Panel(x0, y0, x1 - x0, y1 - y0, kind: kind, confidence: score));
  }
  return ModelDetection(readingOrder(_dedupe(frames), rightToLeft: rightToLeft), _dedupe(balloons));
}

List<Panel> _dedupe(List<Panel> boxes) {
  final sorted = [...boxes]..sort((a, b) => b.confidence.compareTo(a.confidence));
  final kept = <Panel>[];
  for (final b in sorted) {
    if (kept.every((k) => k.iou(b) <= 0.7)) kept.add(b);
  }
  return kept;
}
