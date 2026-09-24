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

  group('detection on a trimmed page', () {
    test('measureTrimRgba reads a big page like its 240 px copy', () {
      final big = page(800, 1200, art: (160, 180, 640, 1020));
      final t = measureTrimRgba(big, 800, 1200, pad: detectionTrimPad);
      expect(t.left, closeTo(0.17, 0.01));
      expect(t.top, closeTo(0.12, 0.01));
      expect(t.right, closeTo(0.83, 0.01));
      expect(t.bottom, closeTo(0.88, 0.01));
      expect(t.width * t.height, lessThan(detectionTrimArea));
    });

    test('cropRgba cuts whole pixels and reports the trim they are', () {
      final px = page(10, 10, art: (0, 0, 0, 0));
      px[(3 * 10 + 2) * 4] = 7; // the crop's top-left pixel
      final (out, w, h, exact) = cropRgba(px, 10, 10, const Trim(0.21, 0.29, 0.79, 0.81));
      expect((w, h), (6, 5));
      expect(exact, const Trim(0.2, 0.3, 0.8, 0.8));
      expect(out[0], 7);
      expect(out.length, 6 * 5 * 4);
    });

    test('panels move between the trimmed part and the page and back', () {
      const t = Trim(0.1, 0.2, 0.9, 0.7);
      const p = Panel(0.5, 0.5, 0.25, 0.5, kind: PanelKind.balloon, confidence: 0.6, shape: [0.5, 0.5, 0.75, 1]);
      final onPage = t.toPage(p);
      expect(onPage.x, closeTo(0.5, 1e-9));
      expect(onPage.y, closeTo(0.45, 1e-9));
      expect(onPage.w, closeTo(0.2, 1e-9));
      expect(onPage.h, closeTo(0.25, 1e-9));
      expect(onPage.shape![1], closeTo(0.45, 1e-9));
      expect((onPage.kind, onPage.confidence), (PanelKind.balloon, 0.6));
      final back = t.toTrim(onPage);
      expect(back.x, closeTo(p.x, 1e-9));
      expect(back.h, closeTo(p.h, 1e-9));
      expect(back.shape![2], closeTo(0.75, 1e-9));
      expect(identical(Trim.full.toPage(p), p), isTrue);
    });

    test('a trim is stored as text, the whole page as null', () {
      expect(encodeTrim(Trim.full), isNull);
      expect(decodeTrim(null), Trim.full);
      expect(decodeTrim('junk'), Trim.full);
      expect(decodeTrim(encodeTrim(const Trim(0.1, 0.2, 0.9, 0.8))), const Trim(0.1, 0.2, 0.9, 0.8));
    });
  });
}
