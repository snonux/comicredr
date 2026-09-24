import 'dart:math' as math;
import 'dart:typed_data';

/// Scan clean-up's colour correction (`c`): per channel, [black] maps to 0
/// and [white] to 255, a straight line between. Setting white to the colour
/// of yellowed paper turns the paper white and takes the same cast out of
/// the inks; the black point stretches faded ink back to black. Applied
/// when a page is drawn, as a colour matrix, so it costs nothing to show.
class Levels {
  const Levels(this.black, this.white);

  /// Nothing to correct.
  static const none = Levels((0, 0, 0), (255, 255, 255));

  final (int, int, int) black;
  final (int, int, int) white;

  bool get isNone => this == none;

  /// A 4x5 colour matrix (the layout Flutter's ColorFilter.matrix takes,
  /// offsets in 0..255) that applies these levels.
  List<double> get matrix {
    double scale(int b, int w) => 255 / math.max(1, w - b);
    final (br, bg, bb) = black;
    final (wr, wg, wb) = white;
    final sr = scale(br, wr), sg = scale(bg, wg), sb = scale(bb, wb);
    return [
      sr, 0, 0, 0, -br * sr, //
      0, sg, 0, 0, -bg * sg, //
      0, 0, sb, 0, -bb * sb, //
      0, 0, 0, 1, 0,
    ];
  }

  /// What these levels do to one colour, for tests and tools.
  (int, int, int) apply(int r, int g, int b) {
    int one(int v, int lo, int hi) => ((v - lo) * 255 / math.max(1, hi - lo)).round().clamp(0, 255);
    return (one(r, black.$1, white.$1), one(g, black.$2, white.$2), one(b, black.$3, white.$3));
  }

  @override
  bool operator ==(Object other) => other is Levels && other.black == black && other.white == white;

  @override
  int get hashCode => Object.hash(black, white);

  @override
  String toString() => 'Levels($black, $white)';
}

/// Finds a scanned page's levels from a small RGBA copy of it (a couple of
/// hundred pixels across is plenty).
///
/// The paper is the commonest bright luminance, when enough of the page
/// has it (at least [minPaper]) and it is paper-coloured: light, with a cast
/// no stronger than yellowed newsprint. Each channel's white point is set
/// where 70% of those paper pixels reach it, so the paper, grain and all,
/// comes out white rather than blotched. Then one black point for all three
/// channels, the darkest 0.5% of the white-balanced page, so faded ink goes
/// dark again without changing its hue. A page without paper (painted art,
/// a cover in flat colour) gets a milder stretch of its luminance only,
/// which keeps its colours. No channel is stretched more than [maxGain];
/// a correction too small to see is [Levels.none].
Levels findLevels(Uint8List rgba, int width, int height, {double minPaper = 0.12, double maxGain = 1.8}) {
  final n = width * height;
  if (n < 64 || rgba.length < n * 4) return Levels.none;
  final lum = Uint8List(n);
  final lumHist = List<int>.filled(256, 0);
  for (var i = 0, p = 0; i < n; i++, p += 4) {
    final l = (rgba[p] * 299 + rgba[p + 1] * 587 + rgba[p + 2] * 114) ~/ 1000;
    lum[i] = l;
    lumHist[l]++;
  }

  // The paper's luminance: the peak of the smoothed histogram's bright half.
  const band = 12;
  var peak = -1, best = 0;
  for (var l = 128; l < 256; l++) {
    var sum = 0;
    for (var k = math.max(0, l - 3); k <= math.min(255, l + 3); k++) {
      sum += lumHist[k];
    }
    if (sum > best) {
      best = sum;
      peak = l;
    }
  }
  var near = 0;
  if (peak >= 0) {
    for (var k = math.max(0, peak - band); k <= math.min(255, peak + band); k++) {
      near += lumHist[k];
    }
  }

  if (peak >= 0 && near >= n * minPaper) {
    final hist = [for (var c = 0; c < 3; c++) List<int>.filled(256, 0)];
    for (var i = 0, p = 0; i < n; i++, p += 4) {
      if ((lum[i] - peak).abs() <= band) {
        hist[0][rgba[p]]++;
        hist[1][rgba[p + 1]]++;
        hist[2][rgba[p + 2]]++;
      }
    }
    final median = [for (final h in hist) _percentile(h, near, 0.5)];
    final hi = median.reduce(math.max), lo = median.reduce(math.min);
    final (r, _, b) = (median[0], median[1], median[2]);
    // Newsprint yellows and greys; it does not turn blue, green or deep
    // yellow. A big flat of such a colour is art, and is left alone.
    if (lo >= 120 && hi - lo <= 85 && b <= r + 8 && b >= r * 0.65) {
      final floor = (255 / maxGain).ceil();
      final white = [for (final h in hist) math.max(floor, _percentile(h, near, 0.3))];
      // One black point on the white-balanced page, in balanced units.
      final balancedHist = List<int>.filled(256, 0);
      final gr = 255 / white[0], gg = 255 / white[1], gb = 255 / white[2];
      for (var p = 0; p < n * 4; p += 4) {
        final l = (rgba[p] * gr * 0.299 + rgba[p + 1] * gg * 0.587 + rgba[p + 2] * gb * 0.114).round();
        balancedHist[l > 255 ? 255 : l]++;
      }
      // Never so far that a channel's total gain passes maxGain.
      final minWhite = white.reduce(math.min);
      final most = (255 - 255 * 255 / (maxGain * minWhite)).floor().clamp(0, 96);
      final black = math.min(_percentile(balancedHist, n, 0.005), most);
      int dark(int w) => (black * w / 255).round();
      final levels = Levels((dark(white[0]), dark(white[1]), dark(white[2])), (white[0], white[1], white[2]));
      return _worth(levels) ? levels : Levels.none;
    }
  }

  // No paper: stretch the luminance's 0.5% and 99.5% to black and white,
  // the same for every channel, and gently.
  var lo = _percentile(lumHist, n, 0.005), hi = _percentile(lumHist, n, 0.995);
  const gentle = 1.3;
  final span = (255 / gentle).ceil();
  if (hi - lo < span) {
    lo = math.max(0, lo - (span - (hi - lo)) ~/ 2);
    hi = math.min(255, lo + span);
  }
  final levels = Levels((lo, lo, lo), (hi, hi, hi));
  return _worth(levels) ? levels : Levels.none;
}

/// Smaller shifts than this are not visible.
bool _worth(Levels l) {
  final (br, bg, bb) = l.black;
  final (wr, wg, wb) = l.white;
  return [br, bg, bb].any((v) => v > 4) || [wr, wg, wb].any((v) => v < 251);
}

/// The value below which [fraction] of the [total] counts in [hist] lie.
int _percentile(List<int> hist, int total, double fraction) {
  final want = total * fraction;
  var seen = 0;
  for (var v = 0; v < hist.length; v++) {
    seen += hist[v];
    if (seen > want) return v;
  }
  return hist.length - 1;
}

/// Enlarges an RGBA page to [outWidth] x [outHeight] and sharpens it, for
/// scans with fewer pixels than the screen shows (`c`).
///
/// Catmull-Rom resampling keeps edges crisper than the bilinear filter a
/// page is drawn with, and an unsharp mask ([amount] of the difference from
/// a blur about a source pixel wide, ignoring differences under
/// [threshold] so paper grain and JPEG noise are not raised) restores the
/// line art's edge. The page comes back opaque. Pure Dart in fixed point,
/// for an isolate: some 90 ms per output megapixel on one laptop core.
Uint8List upscaleSharpen(
  Uint8List rgba,
  int width,
  int height,
  int outWidth,
  int outHeight, {
  double amount = 0.6,
  int threshold = 4,
}) {
  final wide = _resample(rgba, width, height, outWidth, horizontal: true);
  final big = _resample(wide, outWidth, height, outHeight, horizontal: false);
  final passes = outWidth >= width * 1.75 ? 2 : 1;
  var blurred = _box3(big, outWidth, outHeight);
  for (var k = 1; k < passes; k++) {
    blurred = _box3(blurred, outWidth, outHeight);
  }
  final a = (amount * 256).round();
  for (var p = 0; p < big.length; p += 4) {
    for (var c = 0; c < 3; c++) {
      final v = big[p + c];
      final d = v - blurred[p + c];
      if (d > threshold || d < -threshold) {
        final s = v + ((a * d) >> 8);
        big[p + c] = s < 0 ? 0 : (s > 255 ? 255 : s);
      }
    }
    big[p + 3] = 255;
  }
  return big;
}

/// One separable pass of Catmull-Rom resampling, along x or along y, in
/// 12-bit fixed point.
Uint8List _resample(Uint8List src, int w, int h, int size, {required bool horizontal}) {
  final from = horizontal ? w : h;
  final outW = horizontal ? size : w, outH = horizontal ? h : size;
  final out = Uint8List(outW * outH * 4);
  // Source offsets (in bytes, along the pass) and weights per output line,
  // shared by every row (or column).
  final stride = horizontal ? 4 : w * 4;
  final taps = Int32List(size * 4);
  final weights = Int32List(size * 4);
  final ratio = from / size;
  for (var o = 0; o < size; o++) {
    final x = (o + 0.5) * ratio - 0.5;
    final x0 = x.floor();
    final t = x - x0, t2 = t * t, t3 = t2 * t;
    final wts = [-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2];
    for (var k = 0; k < 4; k++) {
      taps[o * 4 + k] = (x0 - 1 + k).clamp(0, from - 1) * stride;
      weights[o * 4 + k] = (wts[k] * 4096).round();
    }
  }
  final lines = horizontal ? h : w;
  final lineStep = horizontal ? w * 4 : 4;
  final outLineStep = horizontal ? outW * 4 : 4;
  final outStep = horizontal ? 4 : outW * 4;
  for (var line = 0; line < lines; line++) {
    final base = line * lineStep;
    var dst = line * outLineStep;
    for (var o = 0, q = 0; o < size; o++, q += 4, dst += outStep) {
      final s0 = base + taps[q], s1 = base + taps[q + 1], s2 = base + taps[q + 2], s3 = base + taps[q + 3];
      final w0 = weights[q], w1 = weights[q + 1], w2 = weights[q + 2], w3 = weights[q + 3];
      for (var c = 0; c < 3; c++) {
        final v = (src[s0 + c] * w0 + src[s1 + c] * w1 + src[s2 + c] * w2 + src[s3 + c] * w3 + 2048) >> 12;
        out[dst + c] = v < 0 ? 0 : (v > 255 ? 255 : v);
      }
    }
  }
  return out;
}

/// A 3x3 box blur of the colour channels, edges repeated; twice over is
/// close to a Gaussian.
Uint8List _box3(Uint8List src, int w, int h) {
  final rows = Uint16List(src.length);
  for (var y = 0; y < h; y++) {
    final row = y * w * 4;
    for (var x = 0; x < w; x++) {
      final p = row + x * 4;
      final l = x > 0 ? p - 4 : p, r = x < w - 1 ? p + 4 : p;
      for (var c = 0; c < 3; c++) {
        rows[p + c] = src[l + c] + src[p + c] + src[r + c];
      }
    }
  }
  final out = Uint8List(src.length);
  final line = w * 4;
  for (var y = 0; y < h; y++) {
    final up = y > 0 ? -line : 0, down = y < h - 1 ? line : 0;
    for (var p = y * line, end = p + line; p < end; p += 4) {
      for (var c = 0; c < 3; c++) {
        out[p + c] = (rows[p + up + c] + rows[p + c] + rows[p + down + c] + 4) ~/ 9;
      }
    }
  }
  return out;
}
