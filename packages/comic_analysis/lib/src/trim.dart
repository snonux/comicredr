import 'dart:math' as math;
import 'dart:typed_data';

import 'panel.dart';

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

/// The width [measureTrimRgba] shrinks a page to before [findTrim] reads
/// it, as the reader does for `t`: wide enough for the margins, narrow
/// enough to smooth away paper grain.
const trimMeasureWidth = 240;

/// The margin [findTrim] leaves around the art when a page is trimmed for
/// panel detection: wider than on screen, since the model was trained on
/// scans with some paper around the frames. On the labelled eval pages a
/// 1% cut changed the model's answer on 18 pages, 3% on 11.
const detectionTrimPad = 0.03;

/// A page is only trimmed for panel detection when what is left is at most
/// this share of its area. The model was trained on scans with ordinary
/// margins and changes its answer on a few pages when those are cut, for
/// no gain; wide margins are what hide the layout. With this, the labelled
/// eval and modern pages score as before, and with an 8% or 12% blank
/// margin added to every page, guided view gets 67 and 68 of the 100 eval
/// pages right instead of 44 and 28, and 47 and 46 of the 66 modern pages
/// instead of 36 and 16 (spike/evaluate.py --trim --add-margin).
const detectionTrimArea = 0.8;

/// [findTrim] on an RGBA page of any size, leaving [pad]: shrunk to
/// [trimMeasureWidth] across first by averaging, so a page decoded at
/// 800 px is measured the way the reader measures it on screen.
Trim measureTrimRgba(Uint8List rgba, int w, int h, {double pad = 0.01}) {
  if (w <= trimMeasureWidth) return findTrim(rgba, w, h, pad: pad);
  const sw = trimMeasureWidth;
  final sh = math.max(16, (h * sw / w).round());
  final sums = Uint32List(sw * sh * 4);
  final counts = Uint32List(sw * sh);
  for (var y = 0; y < h; y++) {
    final sy = y * sh ~/ h;
    for (var x = 0; x < w; x++) {
      final d = sy * sw + x * sw ~/ w;
      final s = (y * w + x) * 4;
      sums[d * 4] += rgba[s];
      sums[d * 4 + 1] += rgba[s + 1];
      sums[d * 4 + 2] += rgba[s + 2];
      counts[d]++;
    }
  }
  final small = Uint8List(sw * sh * 4);
  for (var i = 0; i < counts.length; i++) {
    final n = math.max(1, counts[i]);
    small[i * 4] = sums[i * 4] ~/ n;
    small[i * 4 + 1] = sums[i * 4 + 1] ~/ n;
    small[i * 4 + 2] = sums[i * 4 + 2] ~/ n;
    small[i * 4 + 3] = 255;
  }
  return findTrim(small, sw, sh, pad: pad);
}

/// The part of an RGBA page of [w] x [h] inside [trim], cut on whole pixels,
/// with the trim those pixels really are, which is what panels found on the
/// crop map back through.
(Uint8List, int, int, Trim) cropRgba(Uint8List rgba, int w, int h, Trim trim) {
  if (trim.isFull) return (rgba, w, h, Trim.full);
  final x0 = (trim.left * w).round().clamp(0, w - 1), x1 = (trim.right * w).round().clamp(x0 + 1, w);
  final y0 = (trim.top * h).round().clamp(0, h - 1), y1 = (trim.bottom * h).round().clamp(y0 + 1, h);
  final cw = x1 - x0, ch = y1 - y0;
  final out = Uint8List(cw * ch * 4);
  for (var y = 0; y < ch; y++) {
    final s = ((y0 + y) * w + x0) * 4;
    out.setRange(y * cw * 4, (y + 1) * cw * 4, rgba, s);
  }
  return (out, cw, ch, Trim(x0 / w, y0 / h, x1 / w, y1 / h));
}

/// Moves regions between the whole page and a trimmed part of it. Panels
/// are found on the trimmed page, so wide scanner margins don't hide the
/// layout, and stored on the whole page, as the reader draws them.
extension TrimPanels on Trim {
  /// [p], normalised to this trimmed part, normalised to the whole page.
  Panel toPage(Panel p) => isFull
      ? p
      : Panel(
          left + p.x * width,
          top + p.y * height,
          p.w * width,
          p.h * height,
          kind: p.kind,
          confidence: p.confidence,
          shape: p.shape == null
              ? null
              : [for (final (i, v) in p.shape!.indexed) i.isEven ? left + v * width : top + v * height],
        );

  /// [p], normalised to the whole page, normalised to this trimmed part.
  Panel toTrim(Panel p) => isFull
      ? p
      : Panel(
          (p.x - left) / width,
          (p.y - top) / height,
          p.w / width,
          p.h / height,
          kind: p.kind,
          confidence: p.confidence,
          shape: p.shape == null
              ? null
              : [for (final (i, v) in p.shape!.indexed) i.isEven ? (v - left) / width : (v - top) / height],
        );
}

/// A trim as stored beside a detection run: "left,top,right,bottom", or
/// null for the whole page.
String? encodeTrim(Trim trim) =>
    trim.isFull ? null : [trim.left, trim.top, trim.right, trim.bottom].map((v) => v.toStringAsFixed(5)).join(',');

/// The trim [encodeTrim] wrote; the whole page for null or anything
/// unreadable.
Trim decodeTrim(String? text) {
  final v = text?.split(',').map(double.tryParse).toList();
  if (v == null || v.length != 4 || v.contains(null)) return Trim.full;
  return Trim(v[0]!, v[1]!, v[2]!, v[3]!);
}
