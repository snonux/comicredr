import 'dart:math' as math;
import 'dart:typed_data';

// Image operations the detectors share. Not exported: the package's API is
// panels, not pixels.

/// Square max filter of radius [r] over a 0/1 image [src] of [w] x [h];
/// pixels outside the image never count.
Uint8List dilate(Uint8List src, int w, int h, int r) => _morph(src, w, h, r, true);

/// Square min filter of radius [r] over a 0/1 image; pixels outside the
/// image never erode.
Uint8List erode(Uint8List src, int w, int h, int r) => _morph(src, w, h, r, false);

Uint8List _morph(Uint8List src, int w, int h, int r, bool max) {
  // A running count of `target` pixels in the window: a max filter asks
  // whether any pixel is set, a min filter whether any is clear.
  final target = max ? 1 : 0;
  final tmp = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var count = 0;
    for (var t = 0; t < math.min(r, w); t++) {
      if (src[row + t] == target) count++;
    }
    for (var x = 0; x < w; x++) {
      if (x + r < w && src[row + x + r] == target) count++;
      if (x - r - 1 >= 0 && src[row + x - r - 1] == target) count--;
      tmp[row + x] = count > 0 ? target : 1 - target;
    }
  }
  final out = Uint8List(w * h);
  final counts = Int32List(w);
  for (var t = 0; t < math.min(r, h); t++) {
    for (var x = 0; x < w; x++) {
      if (tmp[t * w + x] == target) counts[x]++;
    }
  }
  for (var y = 0; y < h; y++) {
    final add = y + r < h ? (y + r) * w : -1, drop = y - r - 1 >= 0 ? (y - r - 1) * w : -1;
    for (var x = 0; x < w; x++) {
      if (add >= 0 && tmp[add + x] == target) counts[x]++;
      if (drop >= 0 && tmp[drop + x] == target) counts[x]--;
      out[y * w + x] = counts[x] > 0 ? target : 1 - target;
    }
  }
  return out;
}
