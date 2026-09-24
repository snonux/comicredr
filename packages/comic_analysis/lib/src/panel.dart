/// What a detected region is. Frames drive the guided-view camera; balloons
/// and captions matter later for search and text-to-speech.
enum PanelKind { frame, balloon, caption }

/// Where a set of panels came from, so a better detector only invalidates
/// its own rows.
enum PanelSource { classicCv, model, manual }

/// A rectangle normalised to the page (0..1 on both axes), so it stays valid
/// at any render size and on any screen.
class Panel {
  const Panel(this.x, this.y, this.w, this.h, {this.kind = PanelKind.frame, this.confidence = 1.0});

  final double x, y, w, h;
  final PanelKind kind;
  final double confidence;

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
    return inter / (area + o.area - inter);
  }

  @override
  String toString() =>
      'Panel(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, '
      '${w.toStringAsFixed(3)}, ${h.toStringAsFixed(3)}, ${kind.name})';
}
