import 'dart:typed_data';

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

    test('a tall panel beside a 2x2 grid reads first, then the grid by rows', () {
      // The M4 row rule put all five in one row and read the grid by columns.
      const tall = Panel(0.05, 0.10, 0.37, 0.87);
      const tl = Panel(0.44, 0.10, 0.24, 0.41);
      const tr = Panel(0.70, 0.10, 0.25, 0.42);
      const bl = Panel(0.44, 0.52, 0.24, 0.45);
      const br = Panel(0.69, 0.53, 0.25, 0.45);
      expect(readingOrder([br, bl, tr, tl, tall]), [tall, tl, tr, bl, br]);
    });

    test('two columns without an aligned gutter read column by column', () {
      const a = Panel(0.05, 0.05, 0.4, 0.3);
      const b = Panel(0.05, 0.37, 0.4, 0.58);
      const c = Panel(0.5, 0.05, 0.45, 0.5);
      const d = Panel(0.5, 0.57, 0.45, 0.38);
      expect(readingOrder([d, c, b, a]), [a, b, c, d]);
    });

    test('a two-page spread reads the whole left page first', () {
      // Two 2x2 grids side by side: on a single page the rows would run
      // across the spine.
      final spread = [
        for (final page in [0.0, 0.5])
          for (var r = 0; r < 2; r++)
            for (var c = 0; c < 2; c++) Panel(page + 0.03 + c * 0.22, 0.05 + r * 0.46, 0.2, 0.43),
      ];
      expect(readingOrder(spread.reversed, aspect: 1.5), spread);
      expect(readingOrder(spread.reversed).take(4).map((p) => p.y), everyElement(0.05));
    });

    test('a spread with a panel across the spine reads by rows', () {
      const wide = Panel(0.03, 0.05, 0.94, 0.4);
      const l = Panel(0.03, 0.5, 0.44, 0.45);
      const r = Panel(0.53, 0.5, 0.44, 0.45);
      expect(readingOrder([r, l, wide], aspect: 1.5), [wide, l, r]);
    });

    test('boxes overlapping a gutter by a hair still cut', () {
      const a = Panel(0.05, 0.05, 0.9, 0.305);
      const b = Panel(0.05, 0.35, 0.44, 0.6);
      const c = Panel(0.51, 0.35, 0.44, 0.6);
      expect(readingOrder([c, b, a]), [a, b, c]);
    });
  });

  group('dropContainers', () {
    test('a box around a whole row goes, the row panels stay', () {
      const row = Panel(0.05, 0.05, 0.9, 0.3);
      const l = Panel(0.05, 0.05, 0.44, 0.3);
      const r = Panel(0.51, 0.05, 0.44, 0.3);
      const below = Panel(0.05, 0.4, 0.9, 0.5);
      expect(dropContainers([row, l, r, below]), [l, r, below]);
    });

    test('an inset stays, and so does the panel it sits on', () {
      const big = Panel(0.05, 0.05, 0.9, 0.6);
      const inset = Panel(0.6, 0.1, 0.3, 0.2);
      expect(dropContainers([big, inset]), [big, inset]);
    });
  });

  group('modelVersion', () {
    test('tells model files apart and carries the code version', () {
      final a = modelVersion([1, 2, 3]);
      expect(a ~/ 100000000, modelDetectorVersion);
      expect(modelVersion([1, 2, 3]), a);
      expect(modelVersion([1, 2, 4]), isNot(a));
    });
  });

  group('balloonsByFrame', () {
    test('balloons go to the frame they overlap most, in reading order', () {
      const left = Panel(0.05, 0.05, 0.44, 0.4);
      const right = Panel(0.51, 0.05, 0.44, 0.4);
      const b1 = Panel(0.10, 0.08, 0.15, 0.06, kind: PanelKind.balloon);
      const b2 = Panel(0.30, 0.20, 0.15, 0.06, kind: PanelKind.balloon);
      const crossing = Panel(0.45, 0.10, 0.2, 0.05, kind: PanelKind.balloon); // mostly over right
      const gutter = Panel(0.2, 0.46, 0.1, 0.03, kind: PanelKind.balloon); // over no frame
      final got = balloonsByFrame([left, right], [b2, crossing, gutter, b1]);
      expect(got[0], [b1, b2, gutter]);
      expect(got[1], [crossing]);
    });

    test('no frames, no groups', () {
      expect(balloonsByFrame(const [], const [Panel(0.1, 0.1, 0.1, 0.1)]), isEmpty);
    });
  });

  group('model input and output', () {
    test('letterbox puts the page top-left on grey, as RGB planes', () {
      // 2x1 page: a red and a blue pixel, in a 3x3 input.
      final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]);
      final t = letterboxTensor(rgba, 2, 1, 3);
      expect(t.length, 27);
      expect(t[0], 1.0); // R plane, pixel (0,0)
      expect(t[9 + 0], 0.0); // G plane
      expect(t[18 + 1], 1.0); // B plane, pixel (1,0)
      expect(t[4], closeTo(114 / 255, 1e-6)); // padding
    });

    test('decode thresholds per class, clips, folds duplicates and orders frames', () {
      // Page is 400x600 inside an 800x800 input.
      final rows = <double>[
        210, 10, 390, 290, 0.9, 0, // right frame
        10, 10, 190, 290, 0.8, 0, // left frame
        12, 12, 188, 288, 0.6, 0, // duplicate of the left frame
        10, 310, 420, 590, 0.7, 0, // bottom frame, spills past the page
        20, 20, 80, 60, 0.9, 2, // balloon
        30, 30, 60, 50, 0.3, 2, // balloon below threshold
        50, 50, 90, 90, 0.9, 1, // text class: ignored
      ];
      final d = decodeDetections(rows, 400, 600);
      expect(d.frames.length, 3);
      expect(d.frames[0].x, closeTo(10 / 400, 1e-9));
      expect(d.frames[0].confidence, 0.8);
      expect(d.frames[1].x, closeTo(210 / 400, 1e-9));
      expect(d.frames[2].right, 1.0);
      expect(d.balloons.single.kind, PanelKind.balloon);
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
