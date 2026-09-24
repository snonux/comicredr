import 'dart:math' as math;
import 'dart:typed_data';

import 'gate.dart';
import 'panel.dart';
import 'reading_order.dart';

/// Bump whenever a change here changes what the detector finds, so panels
/// cached by an older version are detected again.
const classicCvVersion = 1;

/// Pages are detected with their long side at this size, as in the M1 spike.
/// Bigger costs time without finding better gutters.
const detectionLongSide = 1200;

/// An 8-bit greyscale image, row-major.
class GrayImage {
  GrayImage(this.width, this.height, this.pixels) : assert(pixels.length == width * height);

  /// Greyscale from RGBA bytes, with the weights OpenCV uses.
  factory GrayImage.fromRgba(Uint8List rgba, int width, int height) {
    final out = Uint8List(width * height);
    for (var i = 0, j = 0; i < out.length; i++, j += 4) {
      out[i] = (rgba[j] * 4899 + rgba[j + 1] * 9617 + rgba[j + 2] * 1868 + 8192) >> 14;
    }
    return GrayImage(width, height, out);
  }

  final int width, height;
  final Uint8List pixels;

  /// Box-filtered down so the long side is at most [longSide]; returns this
  /// image when it is already small enough.
  GrayImage downscaled(int longSide) {
    final scale = longSide / math.max(width, height);
    if (scale >= 1) return this;
    final w = math.max(1, (width * scale).round()), h = math.max(1, (height * scale).round());
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final sy0 = y * height ~/ h, sy1 = math.max(sy0 + 1, (y + 1) * height ~/ h);
      for (var x = 0; x < w; x++) {
        final sx0 = x * width ~/ w, sx1 = math.max(sx0 + 1, (x + 1) * width ~/ w);
        var sum = 0;
        for (var sy = sy0; sy < sy1; sy++) {
          final row = sy * width;
          for (var sx = sx0; sx < sx1; sx++) {
            sum += pixels[row + sx];
          }
        }
        out[y * w + x] = sum ~/ ((sy1 - sy0) * (sx1 - sx0));
      }
    }
    return GrayImage(w, h, out);
  }
}

/// What [detectPanels] found on one page: frames in reading order,
/// normalised to the page, and the confidence gate's verdict on them.
class Detection {
  const Detection(this.frames, this.gate);

  final List<Panel> frames;
  final GateResult gate;
}

const _minPanelFrac = 0.012; // of page area
const _splitLineFrac = 0.93; // a row/column is a separator if this share of it is gutter or rule
const _minSplitPart = 0.12; // each side of a split must be at least this share of the box
const _bridgeFrac = 0.5; // ...or if the component covers at most this share of it
const _sliverFrac = 0.035; // of the long side: thinner boxes are text lines and rules, not panels

/// Classic computer-vision panel detection, ported from the M1 spike
/// (`spike/detect_cv.py`), which is the reference for what it should find:
///
///  1. foreground = anything that is not paper-coloured gutter, plus dilated
///     Canny edges so thin panel borders close
///  2. fill holes, then connected components give candidate boxes
///  3. recursively split big boxes along full-length gutters or rules, which
///     rescues full-bleed pages separated by thin black lines
///  4. drop slivers: boxes thinner than 3.5% of the page's long side are
///     lines of text, title strips or rules, never worth a camera stop.
///     The spike kept them, and they let ads and text pages pass the gate
///  5. reading order, then the confidence gate
///
/// Pure Dart and synchronous: callers run it on a worker isolate. [image]
/// should already be about [detectionLongSide] on its long side; a bigger
/// one is scaled down first.
Detection detectPanels(GrayImage image, {bool rightToLeft = false}) {
  final img = image.downscaled(detectionLongSide);
  final w = img.width, h = img.height;
  final (fg, paper) = _foreground(img);
  final (labels, boxes) = _components(fg, w, h);
  final minArea = _minPanelFrac * w * h;
  final found = <_Box>[];
  for (var i = 0; i < boxes.length; i++) {
    final b = boxes[i];
    if (b.area >= minArea) {
      found.addAll(_split(img, paper, labels, i + 1, b, 0));
    }
  }
  final sliver = _sliverFrac * math.max(w, h);
  final kept = _dropNested(found.where((b) => b.area >= minArea).toList())
      .where((b) => math.min(b.x1 - b.x0, b.y1 - b.y0) >= sliver)
      .toList();
  final frames = readingOrder([
    for (final b in kept) Panel(b.x0 / w, b.y0 / h, (b.x1 - b.x0) / w, (b.y1 - b.y0) / h),
  ], rightToLeft: rightToLeft, aspect: w / h);
  return Detection(frames, confidenceGate(frames));
}

class _Box {
  _Box(this.x0, this.y0, this.x1, this.y1);

  final int x0, y0, x1, y1; // End-exclusive.

  int get area => (x1 - x0) * (y1 - y0);
}

/// The value at percentile [q] of the [n] samples counted in [hist], with
/// numpy's default linear interpolation.
double _percentileHist(List<int> hist, int n, double q) {
  final pos = q / 100 * (n - 1);
  final lo = pos.floor(), hi = pos.ceil();
  int valueAt(int k) {
    var seen = 0;
    for (var v = 0; v < hist.length; v++) {
      seen += hist[v];
      if (seen > k) return v;
    }
    return hist.length - 1;
  }

  final a = valueAt(lo);
  return lo == hi ? a.toDouble() : a + (pos - lo) * (valueAt(hi) - a);
}

double _percentileList(List<double> values, double q) {
  final s = [...values]..sort();
  final pos = q / 100 * (s.length - 1);
  final lo = pos.floor(), hi = pos.ceil();
  return s[lo] + (pos - lo) * (s[hi] - s[lo]);
}

/// Foreground mask (1 = inside some panel) and the estimated paper level.
(Uint8List, double) _foreground(GrayImage img) {
  final w = img.width, h = img.height, g = img.pixels;
  final border = List<int>.filled(256, 0);
  var n = 0;
  final band = math.min(8, math.min(w, h));
  for (var y = 0; y < band; y++) {
    for (var x = 0; x < w; x++) {
      border[g[y * w + x]]++;
      border[g[(h - 1 - y) * w + x]]++;
      n += 2;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < band; x++) {
      border[g[y * w + x]]++;
      border[g[y * w + w - 1 - x]]++;
      n += 2;
    }
  }
  var paper = _percentileHist(border, n, 90);
  if (paper > 200 && _percentileHist(border, n, 10) > 170) {
    // Old scans: the scanner margin is often whiter than the yellowed
    // gutters. The gutters are the page's cleanest rows and columns, so take
    // paper from those. Full-bleed art keeps the border estimate.
    final clean = <double>[];
    final hist = List<int>.filled(256, 0);
    for (var y = 0; y < h; y++) {
      hist.fillRange(0, 256, 0);
      for (var x = 0; x < w; x++) {
        hist[g[y * w + x]]++;
      }
      clean.add(_percentileHist(hist, w, 20));
    }
    for (var x = 0; x < w; x++) {
      hist.fillRange(0, 256, 0);
      for (var y = 0; y < h; y++) {
        hist[g[y * w + x]]++;
      }
      clean.add(_percentileHist(hist, h, 20));
    }
    final gutter = _percentileList(clean, 97);
    if (gutter > 200) paper = math.min(paper, gutter);
  }
  // Only bright borders are paper; a dark border means full-bleed art.
  final thresh = paper > 200 ? paper - 28 : 250.0;
  final edges = _dilate(_canny(_blur5(img), 60, 160), w, h, 2);
  final fg = Uint8List(w * h);
  for (var i = 0; i < fg.length; i++) {
    fg[i] = g[i] < thresh || edges[i] != 0 ? 1 : 0;
  }
  final closed = _erode(_dilate(fg, w, h, 2), w, h, 2);
  // Fill holes: flood the background from the corners; whatever the flood
  // cannot reach is inside a panel.
  final outside = Uint8List(w * h);
  final stack = Int32List(w * h);
  var top = 0;
  void visit(int j) {
    if (closed[j] == 0 && outside[j] == 0) {
      outside[j] = 1;
      stack[top++] = j;
    }
  }

  for (final c in [0, w - 1, (h - 1) * w, h * w - 1]) {
    visit(c);
  }
  while (top > 0) {
    final i = stack[--top];
    final x = i % w;
    if (x > 0) visit(i - 1);
    if (x < w - 1) visit(i + 1);
    if (i >= w) visit(i - w);
    if (i + w < w * h) visit(i + w);
  }
  for (var i = 0; i < closed.length; i++) {
    closed[i] = outside[i] == 0 ? 1 : 0;
  }
  return (closed, paper);
}

int _reflect(int i, int n) => i < 0 ? -i : (i >= n ? 2 * n - 2 - i : i);

/// 5x5 Gaussian with OpenCV's fixed kernel for sigma 0: 1 4 6 4 1.
GrayImage _blur5(GrayImage img) {
  final w = img.width, h = img.height, g = img.pixels;
  final tmp = Int32List(w * h);
  for (var y = 0; y < h; y++) {
    final r = y * w;
    for (var x = 0; x < w; x++) {
      final xm2 = _reflect(x - 2, w), xm1 = _reflect(x - 1, w), xp1 = _reflect(x + 1, w), xp2 = _reflect(x + 2, w);
      tmp[r + x] = g[r + xm2] + 4 * g[r + xm1] + 6 * g[r + x] + 4 * g[r + xp1] + g[r + xp2];
    }
  }
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final a = _reflect(y - 2, h) * w, b = _reflect(y - 1, h) * w, c = y * w;
    final d = _reflect(y + 1, h) * w, e = _reflect(y + 2, h) * w;
    for (var x = 0; x < w; x++) {
      out[c + x] = (tmp[a + x] + 4 * tmp[b + x] + 6 * tmp[c + x] + 4 * tmp[d + x] + tmp[e + x] + 128) >> 8;
    }
  }
  return GrayImage(w, h, out);
}

/// Canny edges (1 = edge) with an L1 gradient and 3x3 Sobel, as cv2.Canny.
Uint8List _canny(GrayImage img, int low, int high) {
  final w = img.width, h = img.height, g = img.pixels;
  final dx = Int32List(w * h), dy = Int32List(w * h), mag = Int32List(w * h);
  for (var y = 0; y < h; y++) {
    final up = _reflect(y - 1, h) * w, mid = y * w, down = _reflect(y + 1, h) * w;
    for (var x = 0; x < w; x++) {
      final l = _reflect(x - 1, w), r = _reflect(x + 1, w);
      final gx = (g[up + r] + 2 * g[mid + r] + g[down + r]) - (g[up + l] + 2 * g[mid + l] + g[down + l]);
      final gy = (g[down + l] + 2 * g[down + x] + g[down + r]) - (g[up + l] + 2 * g[up + x] + g[up + r]);
      final i = mid + x;
      dx[i] = gx;
      dy[i] = gy;
      mag[i] = gx.abs() + gy.abs();
    }
  }
  int m(int x, int y) => x < 0 || y < 0 || x >= w || y >= h ? 0 : mag[y * w + x];
  // 0 = not an edge, 1 = weak candidate, 2 = strong.
  final state = Uint8List(w * h);
  final stack = <int>[];
  const tg22 = 13573; // tan(22.5°) << 15
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final v = mag[i];
      if (v <= low) continue;
      final ax = dx[i].abs(), ay = dy[i].abs() << 15;
      final tg22x = ax * tg22;
      final bool max;
      if (ay < tg22x) {
        max = v > m(x - 1, y) && v >= m(x + 1, y);
      } else if (ay > tg22x + (ax << 16)) {
        max = v > m(x, y - 1) && v >= m(x, y + 1);
      } else {
        final s = (dx[i] ^ dy[i]) < 0 ? -1 : 1;
        max = v > m(x - s, y - 1) && v > m(x + s, y + 1);
      }
      if (!max) continue;
      if (v > high) {
        state[i] = 2;
        stack.add(i);
      } else {
        state[i] = 1;
      }
    }
  }
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    final x = i % w, y = i ~/ w;
    for (var yy = y - 1; yy <= y + 1; yy++) {
      if (yy < 0 || yy >= h) continue;
      for (var xx = x - 1; xx <= x + 1; xx++) {
        if (xx < 0 || xx >= w) continue;
        final j = yy * w + xx;
        if (state[j] == 1) {
          state[j] = 2;
          stack.add(j);
        }
      }
    }
  }
  final out = Uint8List(w * h);
  for (var i = 0; i < out.length; i++) {
    out[i] = state[i] == 2 ? 1 : 0;
  }
  return out;
}

/// Square max filter of radius [r]; pixels outside the image never count.
Uint8List _dilate(Uint8List src, int w, int h, int r) => _morph(src, w, h, r, true);

/// Square min filter of radius [r]; pixels outside the image never erode.
Uint8List _erode(Uint8List src, int w, int h, int r) => _morph(src, w, h, r, false);

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

/// 8-connected components of [fg]: a label per pixel (0 = background,
/// component i is label i + 1) and each component's bounding box.
(Int32List, List<_Box>) _components(Uint8List fg, int w, int h) {
  final labels = Int32List(w * h);
  final boxes = <_Box>[];
  final stack = Int32List(w * h);
  for (var start = 0; start < fg.length; start++) {
    if (fg[start] == 0 || labels[start] != 0) continue;
    final id = boxes.length + 1;
    var x0 = w, y0 = h, x1 = 0, y1 = 0;
    labels[start] = id;
    var top = 0;
    stack[top++] = start;
    while (top > 0) {
      final i = stack[--top];
      final x = i % w, y = i ~/ w;
      if (x < x0) x0 = x;
      if (x >= x1) x1 = x + 1;
      if (y < y0) y0 = y;
      if (y >= y1) y1 = y + 1;
      for (var yy = y - 1; yy <= y + 1; yy++) {
        if (yy < 0 || yy >= h) continue;
        for (var xx = x - 1; xx <= x + 1; xx++) {
          if (xx < 0 || xx >= w) continue;
          final j = yy * w + xx;
          if (fg[j] != 0 && labels[j] == 0) {
            labels[j] = id;
            stack[top++] = j;
          }
        }
      }
    }
    boxes.add(_Box(x0, y0, x1, y1));
  }
  return (labels, boxes);
}

/// Recursively cuts a box along gutters, black rules, or narrow bridges.
///
/// A row (or column) is a separator when nearly all of it is paper-white or
/// rule-black, or when the component itself barely spans it: the signature
/// of two panels glued together by a balloon crossing the gutter.
List<_Box> _split(GrayImage img, double paper, Int32List labels, int id, _Box box, int depth) {
  final w = img.width, g = img.pixels;
  if (depth > 6 || box.x1 - box.x0 < 60 || box.y1 - box.y0 < 60) return [box];
  bool isLine(int v) => v < 55 || (paper > 200 ? v > paper - 14 : v > 248);
  for (final horizontal in [true, false]) {
    // Profile along y for a horizontal cut, along x for a vertical one.
    final n = horizontal ? box.y1 - box.y0 : box.x1 - box.x0;
    final span = horizontal ? box.x1 - box.x0 : box.y1 - box.y0;
    final prof = List<bool>.filled(n, false);
    for (var k = 0; k < n; k++) {
      var lines = 0, comp = 0;
      for (var t = 0; t < span; t++) {
        final i = horizontal ? (box.y0 + k) * w + box.x0 + t : (box.y0 + t) * w + box.x0 + k;
        if (isLine(g[i])) lines++;
        if (labels[i] == id) comp++;
      }
      prof[k] = lines >= _splitLineFrac * span || comp <= _bridgeFrac * span;
    }
    final lo = (n * _minSplitPart).toInt(), hi = (n * (1 - _minSplitPart)).toInt();
    int? bestA, bestB;
    int? start;
    for (var k = lo; k <= hi; k++) {
      final on = k < hi && prof[k];
      if (on && start == null) {
        start = k;
      } else if (!on && start != null) {
        if (bestA == null || k - start > bestB! - bestA) {
          bestA = start;
          bestB = k;
        }
        start = null;
      }
    }
    if (bestA == null) continue;
    final a = bestA, b = bestB!;
    final parts = horizontal
        ? [_Box(box.x0, box.y0, box.x1, box.y0 + a), _Box(box.x0, box.y0 + b, box.x1, box.y1)]
        : [_Box(box.x0, box.y0, box.x0 + a, box.y1), _Box(box.x0 + b, box.y0, box.x1, box.y1)];
    return [
      for (final p in parts)
        if (_tighten(labels, w, id, p) case final t?) ..._split(img, paper, labels, id, t, depth + 1),
    ];
  }
  return [box];
}

/// Shrinks [box] to the component pixels it actually contains.
_Box? _tighten(Int32List labels, int w, int id, _Box box) {
  var x0 = box.x1, y0 = box.y1, x1 = box.x0 - 1, y1 = box.y0 - 1;
  for (var y = box.y0; y < box.y1; y++) {
    for (var x = box.x0; x < box.x1; x++) {
      if (labels[y * w + x] == id) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  return x1 < x0 ? null : _Box(x0, y0, x1 + 1, y1 + 1);
}

/// Removes boxes that sit almost entirely inside a bigger one.
List<_Box> _dropNested(List<_Box> boxes) => [
  for (final a in boxes)
    if (!boxes.any((b) {
      if (identical(a, b) || b.area <= a.area) return false;
      final ix = math.max(0, math.min(a.x1, b.x1) - math.max(a.x0, b.x0));
      final iy = math.max(0, math.min(a.y1, b.y1) - math.max(a.y0, b.y0));
      return ix * iy > 0.8 * a.area;
    }))
      a,
];
