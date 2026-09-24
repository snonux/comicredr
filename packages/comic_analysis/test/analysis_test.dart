import 'package:comic_analysis/comic_analysis.dart';
import 'package:test/test.dart';

/// A six-panel grid with margins, like a golden-age page.
List<Panel> grid6() => [
  for (var r = 0; r < 3; r++)
    for (var c = 0; c < 2; c++) Panel(0.05 + c * 0.46, 0.04 + r * 0.31, 0.44, 0.29),
];

void main() {
  group('readingOrder', () {
    test('rows top to bottom, left to right', () {
      final shuffled = grid6().reversed.toList();
      final ordered = readingOrder(shuffled);
      expect(ordered.map((p) => (p.x, p.y)), grid6().map((p) => (p.x, p.y)));
    });

    test('right to left mirrors each row', () {
      final ordered = readingOrder(grid6(), rightToLeft: true);
      expect(ordered.first.x, greaterThan(ordered[1].x));
      expect(ordered.first.y, ordered[1].y);
    });

    test('a tall panel beside two short ones reads first', () {
      const tall = Panel(0.05, 0.05, 0.4, 0.9);
      const a = Panel(0.5, 0.05, 0.45, 0.44);
      const b = Panel(0.5, 0.51, 0.45, 0.44);
      expect(readingOrder([b, a, tall]), [tall, a, b]);
    });
  });

  group('confidenceGate', () {
    test('a clean grid passes', () {
      final g = confidenceGate(grid6());
      expect(g.passed, isTrue, reason: g.reasons.join('; '));
      expect(g.coverage, closeTo(6 * 0.44 * 0.29, 0.01));
    });

    test('a splash page fails: one panel is nothing to guide through', () {
      expect(confidenceGate([const Panel(0.03, 0.03, 0.94, 0.94)]).passed, isFalse);
    });

    test('overlapping panels fail', () {
      final g = confidenceGate([
        const Panel(0, 0, 0.6, 0.6),
        const Panel(0.3, 0.3, 0.6, 0.6),
        const Panel(0, 0.7, 1, 0.3),
      ]);
      expect(g.reasons, contains('panels 1 and 2 overlap'));
    });

    test('scattered fragments fail on coverage', () {
      final g = confidenceGate([const Panel(0.1, 0.1, 0.1, 0.1), const Panel(0.5, 0.5, 0.1, 0.1)]);
      expect(g.passed, isFalse);
      expect(g.coverage, lessThan(0.6));
    });
  });
}
