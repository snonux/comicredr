import 'dart:typed_data';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:test/test.dart';

/// A [w] x [h] page of [paper] with a band of [ink] lines across the middle
/// (a quarter of the rows), and [flat] filling the bottom third when given.
Uint8List page(int w, int h, (int, int, int) paper, (int, int, int) ink, {(int, int, int)? flat}) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final inked = y > h ~/ 4 && y < h * 3 ~/ 4 && y % 4 == 0;
      final c = flat != null && y > h * 2 ~/ 3 ? flat : (inked ? ink : paper);
      final p = (y * w + x) * 4;
      rgba
        ..[p] = c.$1
        ..[p + 1] = c.$2
        ..[p + 2] = c.$3
        ..[p + 3] = 255;
    }
  }
  return rgba;
}

void main() {
  group('findLevels', () {
    test('turns yellowed paper white and faded ink dark, without tinting it', () {
      final levels = findLevels(page(200, 300, (236, 218, 170), (92, 84, 64)), 200, 300);
      final (pr, pg, pb) = levels.apply(236, 218, 170);
      expect([pr, pg, pb], everyElement(greaterThanOrEqualTo(253)));
      // A fifth darker at least, as far as the gain limit on blue lets it go.
      final (ir, ig, ib) = levels.apply(92, 84, 64);
      expect([ir, ig, ib], everyElement(lessThan(92 * 0.8)));
      // Ink balanced against the paper: no channel far from the others.
      expect((ir - ib).abs(), lessThan(20));
    });

    test('leaves a clean white page alone', () {
      expect(findLevels(page(200, 300, (255, 255, 255), (0, 0, 0)), 200, 300), Levels.none);
    });

    test('treats a big flat of deep yellow as art, not paper', () {
      final levels = findLevels(page(200, 300, (250, 232, 70), (20, 20, 20)), 200, 300);
      // Only a luminance stretch: the same points for every channel.
      expect(levels.black.$1, levels.black.$3);
      expect(levels.white.$1, levels.white.$3);
    });

    test('stretches a page without paper gently', () {
      // A grey, murky painting: mid greys only.
      final levels = findLevels(page(200, 300, (110, 100, 90), (70, 70, 70)), 200, 300);
      final (b, _, _) = levels.black;
      final (w, _, _) = levels.white;
      expect(w - b, greaterThanOrEqualTo(255 / 1.3 - 1), reason: 'at most 1.3 times the contrast');
    });

    test('never stretches a channel past the gain limit', () {
      // Very dark "paper": would need a big gain.
      final levels = findLevels(page(200, 300, (150, 135, 110), (60, 55, 50)), 200, 300);
      for (final (b, w) in [
        (levels.black.$1, levels.white.$1),
        (levels.black.$2, levels.white.$2),
        (levels.black.$3, levels.white.$3),
      ]) {
        expect(255 / (w - b), lessThanOrEqualTo(1.8 * 1.02));
      }
    });

    test('its colour matrix does what apply does', () {
      const levels = Levels((20, 30, 40), (240, 220, 180));
      final m = levels.matrix;
      int row(int k, int r, int g, int b) =>
          (m[k * 5] * r + m[k * 5 + 1] * g + m[k * 5 + 2] * b + m[k * 5 + 4]).round();
      final (r, g, b) = levels.apply(120, 110, 100);
      expect([row(0, 120, 110, 100), row(1, 120, 110, 100), row(2, 120, 110, 100)], [r, g, b]);
    });
  });

  group('upscaleSharpen', () {
    test('keeps a flat page flat and opaque', () {
      final src = page(20, 30, (200, 190, 150), (200, 190, 150));
      final out = upscaleSharpen(src, 20, 30, 40, 60);
      expect(out.length, 40 * 60 * 4);
      for (var p = 0; p < out.length; p += 4) {
        expect([out[p], out[p + 1], out[p + 2], out[p + 3]], [200, 190, 150, 255]);
      }
    });

    test('keeps an edge steeper than a straight blend would', () {
      // Black left half, white right half, 10 px wide.
      final src = Uint8List(10 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 10; x++) {
          final v = x < 5 ? 0 : 255;
          src.setAll((y * 10 + x) * 4, [v, v, v, 255]);
        }
      }
      final out = upscaleSharpen(src, 10, 4, 20, 8);
      final row = [for (var x = 0; x < 20; x++) out[(3 * 20 + x) * 4]];
      // Bilinear would put 64 and 191 either side of the edge at 2x.
      expect(row[9], lessThan(64));
      expect(row[10], greaterThan(191));
      expect(row.first, 0);
      expect(row.last, 255);
    });
  });
}
