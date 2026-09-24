import 'dart:typed_data';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:test/test.dart';

/// A white page with a bordered, textured panel per rectangle (pixels).
GrayImage page(int width, int height, List<(int, int, int, int)> panels) {
  final px = Uint8List(width * height)..fillRange(0, width * height, 255);
  for (final (x0, y0, w, h) in panels) {
    for (var y = y0; y < y0 + h; y++) {
      for (var x = x0; x < x0 + w; x++) {
        final border = x < x0 + 4 || x >= x0 + w - 4 || y < y0 + 4 || y >= y0 + h - 4;
        px[y * width + x] = border ? 0 : ((x ~/ 16 + y ~/ 16).isEven ? 150 : 110);
      }
    }
  }
  return GrayImage(width, height, px);
}

void main() {
  test('finds a six-panel grid in reading order and passes the gate', () {
    final d = detectPanels(
      page(800, 1200, [
        for (var r = 0; r < 3; r++)
          for (var c = 0; c < 2; c++) (40 + c * 370, 40 + r * 380, 350, 360),
      ]),
    );
    expect(d.frames, hasLength(6));
    expect(d.gate.passed, isTrue, reason: d.gate.reasons.join('; '));
    expect(d.frames.first.x, closeTo(40 / 800, 0.01));
    expect(d.frames[1].x, greaterThan(0.5), reason: 'second panel is top right');
    expect(d.frames[2].y, greaterThan(0.3), reason: 'third panel starts the second row');
  });

  test('splits panels that touch across a black rule', () {
    // Full-bleed: two panels meet at a 6px black rule, no white gutter.
    final img = page(600, 900, [(0, 0, 600, 447), (0, 453, 600, 447)]);
    for (var y = 447; y < 453; y++) {
      img.pixels.fillRange(y * 600, (y + 1) * 600, 0);
    }
    final d = detectPanels(img);
    expect(d.frames, hasLength(2));
    expect(d.gate.passed, isTrue, reason: d.gate.reasons.join('; '));
  });

  test('a blank page has nothing to guide through', () {
    final d = detectPanels(page(400, 600, const []));
    expect(d.frames, isEmpty);
    expect(d.gate.passed, isFalse);
  });

  test('slivers are text lines, not panels', () {
    final d = detectPanels(page(800, 1200, [(40, 40, 720, 540), (40, 600, 720, 20), (40, 640, 720, 520)]));
    expect(d.frames, hasLength(2));
  });

  test('large pages are scaled down to the detection size first', () {
    final big = page(2400, 3600, [(60, 60, 1110, 3480), (1230, 60, 1110, 3480)]);
    expect(big.downscaled(detectionLongSide).height, detectionLongSide);
    expect(detectPanels(big).frames, hasLength(2));
  });

  test('greyscale uses the OpenCV weights', () {
    final g = GrayImage.fromRgba(Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255]), 3, 1);
    expect(g.pixels, [76, 150, 29]);
  });
}
