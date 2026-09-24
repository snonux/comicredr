import 'dart:typed_data';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:test/test.dart';

/// A [w]x[h] RGBA page of [paper] grey with an [ink] rectangle on it.
Uint8List page(int w, int h, {int paper = 240, int ink = 30, required (int, int, int, int) art}) {
  final px = Uint8List(w * h * 4);
  final (l, t, r, b) = art;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = x >= l && x < r && y >= t && y < b ? ink : paper;
      final i = (y * w + x) * 4;
      px[i] = px[i + 1] = px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
  return px;
}

void main() {
  group('findTrim', () {
    test('cuts white scan margins, leaving a 1% pad', () {
      final t = findTrim(page(200, 300, art: (20, 30, 180, 270)), 200, 300);
      expect(t.left, closeTo(0.09, 0.001));
      expect(t.top, closeTo(0.09, 0.001));
      expect(t.right, closeTo(0.91, 0.001));
      expect(t.bottom, closeTo(0.91, 0.001));
    });

    test('a black scanner bed is margin too', () {
      final t = findTrim(page(200, 300, paper: 5, ink: 220, art: (30, 30, 170, 270)), 200, 300);
      expect(t.left, closeTo(0.14, 0.001));
      expect(t.top, closeTo(0.09, 0.001));
    });

    test('full-bleed art stays whole', () {
      final t = findTrim(page(200, 300, art: (0, 0, 200, 300)), 200, 300);
      expect(t.isFull, isTrue);
    });

    test('a blank page stays whole', () {
      expect(findTrim(page(200, 300, art: (0, 0, 0, 0)), 200, 300), Trim.full);
    });

    test('no side loses more than 20%', () {
      final t = findTrim(page(200, 300, art: (100, 150, 190, 290)), 200, 300);
      expect(t.left, 0.2);
      expect(t.top, 0.2);
    });

    test('dust and a thin scanner line are cut with the margin', () {
      final px = page(200, 300, art: (20, 30, 180, 270));
      // A one-pixel dark line down the left edge, and a speck in the top margin.
      for (var y = 0; y < 300; y++) {
        px[(y * 200) * 4] = px[(y * 200) * 4 + 1] = px[(y * 200) * 4 + 2] = 0;
      }
      final speck = (10 * 200 + 100) * 4;
      px[speck] = px[speck + 1] = px[speck + 2] = 0;
      final t = findTrim(px, 200, 300);
      expect(t.left, closeTo(0.09, 0.001));
      expect(t.top, closeTo(0.09, 0.001));
    });

    test('a trim under 1% is not worth it', () {
      final t = findTrim(page(200, 300, art: (3, 4, 197, 296)), 200, 300);
      expect(t, Trim.full);
    });
  });
}
