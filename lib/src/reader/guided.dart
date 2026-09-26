import 'dart:math' as math;
import 'dart:ui';

import 'package:comic_analysis/comic_analysis.dart';

/// A place in the book: a page, and a panel on it in guided view.
typedef Place = ({int page, int panel});

/// Stands for "the last panel" while a page's panels are not known yet, so
/// stepping back onto a page lands on its last panel once they arrive.
const lastPanel = 1 << 20;

/// Guided view's panel on arrival at a page when whole-page steps are on:
/// the whole page, shown before its first panel.
const pageStart = -1;

/// The whole page once more after its last panel, before the next page,
/// when whole-page steps are on. Above [lastPanel], so it never clamps to a
/// panel.
const pageEnd = 1 << 21;

/// Whether a saved [panel] names a panel rather than the whole page.
bool isPanel(int? panel) => panel != null && panel >= 0 && panel < pageEnd;

/// Stands for "the last balloon" in a panel whose balloons are not known
/// yet, like [lastPanel].
const lastBalloon = 1 << 20;

/// What detection found on one page: frames in reading order, balloons, and
/// the confidence gate's verdict. Guided view only moves the camera on
/// pages that pass; the rest are shown whole.
class PagePanels {
  /// [frames] come in reading order, as the detector sorted them: it saw
  /// the page, so it knew a two-page spread from a single page. [trim] is
  /// the part of the page the detector looked at; the gate judges the
  /// frames against it, so a wide blank margin does not count as page the
  /// frames fail to cover.
  PagePanels(this.frames, [this.balloons = const [], Trim trim = Trim.full])
    : gate = confidenceGate([for (final f in frames) trim.toTrim(f)]);

  final List<Panel> frames;

  /// Speech, thought and caption balloons on the page; the trained detector
  /// finds them, classic CV does not.
  final List<Panel> balloons;
  final GateResult gate;

  final _byFrame = <(bool, double), List<List<Panel>>>{};

  /// The camera stops, in reading order for the book's direction; empty
  /// when the gate failed and the page is shown whole. [aspect] is the
  /// page's width over its height, so a two-page spread read right to left
  /// takes the whole right page first.
  List<Panel> stops({required bool rightToLeft, double aspect = 1}) => gate.passed
      ? (rightToLeft ? readingOrder(frames, rightToLeft: true, aspect: aspect) : frames)
      : const [];

  /// The balloons inside stop [stop], in reading order.
  List<Panel> balloonsIn(int stop, {required bool rightToLeft, double aspect = 1}) {
    final groups = _byFrame[(rightToLeft, aspect)] ??= balloonsByFrame(
      stops(rightToLeft: rightToLeft, aspect: aspect),
      balloons,
      rightToLeft: rightToLeft,
    );
    return stop >= 0 && stop < groups.length ? groups[stop] : const [];
  }
}

/// What the camera frames for [balloon] in [frame]: the balloon with half
/// its size again of the art around it on every side, kept inside the
/// frame, so the reader sees who is speaking without losing the words.
Panel balloonFocus(Panel frame, Panel balloon) {
  final pad = 0.5 * (balloon.w > balloon.h ? balloon.w : balloon.h);
  double lo(double v, double min) => v < min ? min : v;
  double hi(double v, double max) => v > max ? max : v;
  final x0 = lo(balloon.x - pad, frame.x);
  final y0 = lo(balloon.y - pad, frame.y);
  final x1 = hi(balloon.right + pad, frame.right);
  final y1 = hi(balloon.bottom + pad, frame.bottom);
  // A balloon hanging over the frame's edge stays wholly in view.
  final l = x0 < balloon.x ? x0 : balloon.x, t = y0 < balloon.y ? y0 : balloon.y;
  final r = x1 > balloon.right ? x1 : balloon.right, b = y1 > balloon.bottom ? y1 : balloon.bottom;
  return Panel(l, t, r - l, b - t, kind: PanelKind.balloon, confidence: balloon.confidence);
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
