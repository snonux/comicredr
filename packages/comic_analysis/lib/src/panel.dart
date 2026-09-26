/// What a detected region is. Frames drive the guided-view camera; balloons
/// and captions matter later for search and text-to-speech.
enum PanelKind { frame, balloon, caption }

/// Where a set of panels came from, so a better detector only invalidates
/// its own rows.
enum PanelSource { classicCv, model, manual }

/// A rectangle normalised to the page (0..1 on both axes), so it stays valid
/// at any render size and on any screen.
class Panel {
  const Panel(this.x, this.y, this.w, this.h, {this.kind = PanelKind.frame, this.confidence = 1.0, this.shape});

  final double x, y, w, h;
  final PanelKind kind;
  final double confidence;

  /// The frame's real outline when it is not its box (a slanted or cut
  /// panel): a convex polygon as x, y pairs in page coordinates, inside the
  /// box. Null for a plain rectangle. See [refineOutlines].
  final List<double>? shape;

  /// This panel with [shape] as its outline.
  Panel withShape(List<double>? shape) => Panel(x, y, w, h, kind: kind, confidence: confidence, shape: shape);

  /// The outline as a closed polygon: [shape], or the box's four corners.
  List<(double, double)> get outline => shape == null
      ? [(x, y), (right, y), (right, bottom), (x, bottom)]
      : [for (var i = 0; i + 1 < shape!.length; i += 2) (shape![i], shape![i + 1])];

  /// Area shared with [o], by their outlines: two slanted panels whose
  /// boxes overlap need not overlap at all.
  double overlap(Panel o) {
    if (shape == null && o.shape == null) return intersection(o);
    if (intersection(o) == 0) return 0;
    return polygonArea(clipConvex(outline, o.outline));
  }

  double get right => x + w;
  double get bottom => y + h;
  double get area => w * h;

  double intersection(Panel o) {
    final ix = (right < o.right ? right : o.right) - (x > o.x ? x : o.x);
    final iy = (bottom < o.bottom ? bottom : o.bottom) - (y > o.y ? y : o.y);
    return ix > 0 && iy > 0 ? ix * iy : 0;
  }

  double iou(Panel o) {
    final inter = intersection(o);
    final union = area + o.area - inter;
    return union > 0 ? inter / union : 0;
  }

  @override
  String toString() =>
      'Panel(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, '
      '${w.toStringAsFixed(3)}, ${h.toStringAsFixed(3)}, ${kind.name})';
}

/// Area of a simple polygon (shoelace formula).
double polygonArea(List<(double, double)> p) {
  var sum = 0.0;
  for (var i = 0; i < p.length; i++) {
    final (x0, y0) = p[i];
    final (x1, y1) = p[(i + 1) % p.length];
    sum += x0 * y1 - x1 * y0;
  }
  return sum.abs() / 2;
}

/// [subject] clipped to the convex polygon [clip] (Sutherland-Hodgman).
List<(double, double)> clipConvex(List<(double, double)> subject, List<(double, double)> clip) {
  var out = subject;
  // Orientation of the clip polygon, so "inside" is the same side for any
  // winding.
  var turn = 0.0;
  for (var i = 0; i < clip.length; i++) {
    final (x0, y0) = clip[i];
    final (x1, y1) = clip[(i + 1) % clip.length];
    turn += x0 * y1 - x1 * y0;
  }
  final sign = turn < 0 ? -1.0 : 1.0;
  for (var i = 0; i < clip.length && out.isNotEmpty; i++) {
    final (ax, ay) = clip[i];
    final (bx, by) = clip[(i + 1) % clip.length];
    double side((double, double) p) => sign * ((bx - ax) * (p.$2 - ay) - (by - ay) * (p.$1 - ax));
    final input = out;
    out = [];
    for (var j = 0; j < input.length; j++) {
      final p = input[j], q = input[(j + 1) % input.length];
      final sp = side(p), sq = side(q);
      if (sp >= 0) out.add(p);
      if ((sp >= 0) != (sq >= 0)) {
        final t = sp / (sp - sq);
        out.add((p.$1 + (q.$1 - p.$1) * t, p.$2 + (q.$2 - p.$2) * t));
      }
    }
  }
  return out;
}

/// [Panel.shape] as stored in the index and the sidecar: "x,y,x,y,...".
String? encodeShape(List<double>? shape) => shape?.map((v) => v.toStringAsFixed(5)).join(',');

/// The inverse of [encodeShape]; null for null, empty or damaged text.
List<double>? decodeShape(String? text) {
  if (text == null || text.isEmpty) return null;
  final values = [for (final v in text.split(',')) double.tryParse(v)];
  if (values.length < 6 || values.length.isOdd || values.contains(null)) return null;
  return values.cast<double>();
}
