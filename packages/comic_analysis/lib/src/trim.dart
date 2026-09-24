import 'dart:typed_data';

/// The part of a page worth showing once the scanner's margins are cut
/// away, as fractions of the page (0..1). [full] means nothing to trim.
class Trim {
  const Trim(this.left, this.top, this.right, this.bottom);

  static const full = Trim(0, 0, 1, 1);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  bool get isFull => this == full;

  @override
  bool operator ==(Object other) =>
      other is Trim && other.left == left && other.top == top && other.right == right && other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'Trim($left, $top, $right, $bottom)';
}

/// Finds a scanned page's blank margins from its luminance profile (design
/// plan section 5), for `t`. Works on a small RGBA copy of the page; a
/// couple of hundred pixels across is plenty.
///
/// The paper colour is the commonest grey around the page's edge, so a
/// yellowed page or a black scanner bed both count as margin. A row or
/// column is content when more than [ink] of it differs from the paper by
/// more than [tolerance]; the content starts at the first run of such lines
/// at least 1% of the page long, so dust and a thin scanner edge are cut
/// with the margin. No side loses more than [maxTrim], a [pad] of margin is
/// left around the art, and trims under 1% are not worth a jump: [Trim.full].
Trim findTrim(
  Uint8List rgba,
  int width,
  int height, {
  int tolerance = 40,
  double ink = 0.015,
  double maxTrim = 0.2,
  double pad = 0.01,
}) {
  if (width < 16 || height < 16 || rgba.length < width * height * 4) return Trim.full;
  final lum = Uint8List(width * height);
  for (var i = 0, p = 0; i < lum.length; i++, p += 4) {
    lum[i] = (rgba[p] * 299 + rgba[p + 1] * 587 + rgba[p + 2] * 114) ~/ 1000;
  }
  final paper = _edgeMode(lum, width, height);
  final rowInk = List<int>.filled(height, 0);
  final colInk = List<int>.filled(width, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if ((lum[y * width + x] - paper).abs() > tolerance) {
        rowInk[y]++;
        colInk[x]++;
      }
    }
  }
  final rows = [for (final n in rowInk) n > width * ink];
  final cols = [for (final n in colInk) n > height * ink];
  final top = _firstRun(rows, forward: true);
  final bottom = _firstRun(rows, forward: false);
  final left = _firstRun(cols, forward: true);
  final right = _firstRun(cols, forward: false);
  // A blank page, or one with nothing but specks, stays whole.
  if (top == null || bottom == null || left == null || right == null) return Trim.full;

  double cut(int edge, int size) => (edge / size - pad).clamp(0.0, maxTrim);
  final t = Trim(
    cut(left, width),
    cut(top, height),
    1 - cut(width - 1 - right, width),
    1 - cut(height - 1 - bottom, height),
  );
  final worth = t.left >= 0.01 || t.top >= 0.01 || 1 - t.right >= 0.01 || 1 - t.bottom >= 0.01;
  return worth && t.width > 0.3 && t.height > 0.3 ? t : Trim.full;
}

/// Index of the first line, from the start or the end, that begins a run
/// of content lines at least 1% of [lines] long (and at least two).
int? _firstRun(List<bool> lines, {required bool forward}) {
  final need = (lines.length * 0.01).ceil().clamp(2, 1 << 30);
  var run = 0;
  for (var k = 0; k < lines.length; k++) {
    final i = forward ? k : lines.length - 1 - k;
    if (lines[i]) {
      if (++run >= need) return forward ? i - run + 1 : i + run - 1;
    } else {
      run = 0;
    }
  }
  return null;
}

/// The commonest luminance around the page's edge, in 8-level buckets,
/// returned as the bucket's middle. Four rings, from the very edge to 3% in,
/// so a thin dark scanner edge does not pass for the paper.
int _edgeMode(Uint8List lum, int w, int h) {
  final hist = List<int>.filled(32, 0);
  void add(int x, int y) => hist[lum[y * w + x] >> 3]++;
  final step = (w < h ? w : h) * 0.01;
  for (var r = 0; r < 4; r++) {
    final k = (r * step).floor();
    for (var x = k; x < w - k; x++) {
      add(x, k);
      add(x, h - 1 - k);
    }
    for (var y = k + 1; y < h - 1 - k; y++) {
      add(k, y);
      add(w - 1 - k, y);
    }
  }
  var best = 0;
  for (var i = 1; i < hist.length; i++) {
    if (hist[i] > hist[best]) best = i;
  }
  return best * 8 + 4;
}
