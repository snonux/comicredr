import 'dart:math' as math;
import 'dart:ui';

import 'package:comic_analysis/comic_analysis.dart';

/// A place in the book: a page, and a panel on it in guided view.
typedef Place = ({int page, int panel});

/// Stands for "the last panel" while a page's panels are not known yet, so
/// stepping back onto a page lands on its last panel once they arrive.
const lastPanel = 1 << 20;

/// What detection found on one page: frames in left-to-right reading order
/// and the confidence gate's verdict. Guided view only moves the camera on
/// pages that pass; the rest are shown whole.
class PagePanels {
  PagePanels(this.frames) : gate = confidenceGate(frames);

  final List<Panel> frames;
  final GateResult gate;

  /// The camera stops, in reading order for the book's direction; empty
  /// when the gate failed and the page is shown whole.
  List<Panel> stops({required bool rightToLeft}) =>
      gate.passed ? (rightToLeft ? readingOrder(frames, rightToLeft: true) : frames) : const [];
}

/// Share of the viewport left free around a panel, so art is not clipped
/// to its border (design plan section 5).
const panelMargin = 0.04;

/// The camera for guided view: the scale and offset that put [panel]
/// (a rectangle in the same coordinates as the page) in the middle of
/// [viewport] with [panelMargin] to spare on the tighter axis.
({double scale, Offset offset}) cameraOn(Rect panel, Size viewport) {
  final free = 1 - 2 * panelMargin;
  final scale = math.min(viewport.width * free / panel.width, viewport.height * free / panel.height).clamp(0.5, 8.0);
  final offset = viewport.center(Offset.zero) - panel.center * scale;
  return (scale: scale.toDouble(), offset: offset);
}
