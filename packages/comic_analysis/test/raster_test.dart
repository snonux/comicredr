import 'dart:math' as math;
import 'dart:typed_data';

import 'package:comic_analysis/src/raster.dart';
import 'package:test/test.dart';

/// The square filter written out plainly: the window clipped to the image.
Uint8List naive(Uint8List src, int w, int h, int r, {required bool max}) {
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var any = false;
      for (var yy = math.max(0, y - r); yy <= math.min(h - 1, y + r) && !any; yy++) {
        for (var xx = math.max(0, x - r); xx <= math.min(w - 1, x + r); xx++) {
          if (src[yy * w + xx] == (max ? 1 : 0)) {
            any = true;
            break;
          }
        }
      }
      out[y * w + x] = max ? (any ? 1 : 0) : (any ? 0 : 1);
    }
  }
  return out;
}

void main() {
  test('dilate and erode match the plain square filter, edges included', () {
    final rnd = math.Random(7);
    for (final (w, h, r) in [(1, 1, 2), (3, 17, 1), (40, 25, 2), (9, 9, 5), (60, 3, 3)]) {
      final src = Uint8List.fromList([for (var i = 0; i < w * h; i++) rnd.nextInt(10) < 3 ? 1 : 0]);
      expect(dilate(src, w, h, r), naive(src, w, h, r, max: true), reason: 'dilate $w x $h r $r');
      final dense = Uint8List.fromList([for (var i = 0; i < w * h; i++) rnd.nextInt(10) < 8 ? 1 : 0]);
      expect(erode(dense, w, h, r), naive(dense, w, h, r, max: false), reason: 'erode $w x $h r $r');
    }
  });
}
