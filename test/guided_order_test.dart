import 'package:comic_analysis/comic_analysis.dart';
import 'package:comicredr/src/reader/guided.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('right to left, a two-page spread reads the whole right page first', () {
    // A 2:1 spread with a 2x2 grid on each page, in the detector's left to
    // right order.
    final frames = [
      for (final x0 in [0.0, 0.5])
        for (final y in [0.05, 0.52])
          for (final x in [0.02, 0.26]) Panel(x0 + x, y, 0.22, 0.43),
    ];
    final panels = PagePanels(frames);
    expect(panels.gate.passed, isTrue, reason: panels.gate.reasons.join('; '));
    final order = [for (final p in panels.stops(rightToLeft: true, aspect: 2)) (p.x, p.y)];
    expect(order, [
      (0.76, 0.05),
      (0.52, 0.05),
      (0.76, 0.52),
      (0.52, 0.52),
      (0.26, 0.05),
      (0.02, 0.05),
      (0.26, 0.52),
      (0.02, 0.52),
    ]);
    // A single page keeps rows across the page.
    expect(panels.stops(rightToLeft: true).first.x, 0.76);
    expect(panels.stops(rightToLeft: true)[1].x, 0.52);
    expect(panels.stops(rightToLeft: true)[2].x, 0.26);
  });
}
