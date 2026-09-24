import 'panel.dart';

/// The verdict of [confidenceGate]: guided view only runs on pages that pass.
class GateResult {
  const GateResult(this.reasons, this.coverage);

  /// Why the page failed; empty when it passed.
  final List<String> reasons;

  /// Share of the page the frames cover, 0..1.
  final double coverage;

  bool get passed => reasons.isEmpty;
}

/// A wrong camera move is worse than no camera move (design plan section 5),
/// so a page only gets guided view when its frames look like a real layout:
/// between [minPanels] and [maxPanels] of them, none overlapping another by
/// more than [maxOverlap] of the smaller one, none filling the whole page,
/// together covering at least [minCoverage] of it, and no more than
/// [maxScraps] of them smaller than [scrapArea] of the page. Otherwise the
/// reader just pages. The thresholds match the M1 spike, except the scrap
/// rule: on the real-comic run, ads and catalogue pages came out as a
/// handful of real-looking boxes plus a crowd of tiny ones, while story
/// pages had at most four tiny boxes.
GateResult confidenceGate(
  List<Panel> frames, {
  int minPanels = 2,
  int maxPanels = 20,
  double maxOverlap = 0.15,
  double minCoverage = 0.6,
  double wholePage = 0.92,
  int maxScraps = 4,
  double scrapArea = 0.02,
  int grid = 200,
}) {
  final reasons = <String>[];
  final n = frames.length;
  if (n < minPanels) reasons.add('$n panel(s): nothing to guide through');
  if (n > maxPanels) reasons.add('$n panels: implausibly many');
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final smaller = frames[i].area < frames[j].area ? frames[i].area : frames[j].area;
      if (frames[i].intersection(frames[j]) > maxOverlap * smaller) {
        reasons.add('panels ${i + 1} and ${j + 1} overlap');
      }
    }
    if (n > 1 && frames[i].area > wholePage) {
      reasons.add('panel ${i + 1} is the whole page');
    }
  }
  final scraps = frames.where((p) => p.area < scrapArea).length;
  if (scraps > maxScraps) reasons.add('$scraps scraps: looks like an ad or a text page');
  final coverage = _coverage(frames, grid);
  if (coverage < minCoverage) {
    reasons.add('covers ${(coverage * 100).round()}% of page (< ${(minCoverage * 100).round()}%)');
  }
  return GateResult(reasons, coverage);
}

/// Union area of the frames, rasterised on a [grid] x [grid] lattice.
double _coverage(List<Panel> frames, int grid) {
  if (frames.isEmpty) return 0;
  var hits = 0;
  for (var gy = 0; gy < grid; gy++) {
    final y = (gy + 0.5) / grid;
    for (var gx = 0; gx < grid; gx++) {
      final x = (gx + 0.5) / grid;
      for (final p in frames) {
        if (x >= p.x && x < p.right && y >= p.y && y < p.bottom) {
          hits++;
          break;
        }
      }
    }
  }
  return hits / (grid * grid);
}
