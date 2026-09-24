import 'panel.dart';
import 'reading_order.dart';

/// Hands each balloon to the frame it sits in and orders them for reading.
///
/// Returns one list per frame, in the frames' order, each holding that
/// frame's balloons in reading order. A balloon belongs to the frame it
/// overlaps most; a balloon over no frame at all (a caption in the gutter)
/// goes to the frame whose centre is nearest. Balloons crossing a gutter
/// are common in western comics, and the larger overlap is where the
/// reader's eye already is.
List<List<Panel>> balloonsByFrame(List<Panel> frames, Iterable<Panel> balloons, {bool rightToLeft = false}) {
  final out = [for (final _ in frames) <Panel>[]];
  if (frames.isEmpty) return out;
  for (final b in balloons) {
    var best = -1;
    var bestOverlap = 0.0;
    for (final (i, f) in frames.indexed) {
      final o = f.intersection(b);
      if (o > bestOverlap) {
        bestOverlap = o;
        best = i;
      }
    }
    if (best < 0) {
      var bestDist = double.infinity;
      for (final (i, f) in frames.indexed) {
        final dx = (f.x + f.w / 2) - (b.x + b.w / 2);
        final dy = (f.y + f.h / 2) - (b.y + b.h / 2);
        final d = dx * dx + dy * dy;
        if (d < bestDist) {
          bestDist = d;
          best = i;
        }
      }
    }
    out[best].add(b);
  }
  return [for (final list in out) readingOrder(list, rightToLeft: rightToLeft, tolerance: 0.002)];
}
