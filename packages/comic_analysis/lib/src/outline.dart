import 'dart:math' as math;
import 'dart:typed_data';

import 'panel.dart';
import 'raster.dart';

/// Finds the real outline of frames that are not rectangles: slanted
/// panels, panels with a cut corner, trapezoids between diagonal gutters.
///
/// The detector only draws boxes, and a slanted panel's box holds corners of
/// its neighbours. This looks at the page itself: it floods the gutter from
/// the paper around and between the boxes, gives each connected piece of
/// art to the box holding most of it, and takes the convex hull of what one
/// box owns. Only straight hull edges that the art runs right up to, with
/// gutter just outside and another panel or the page edge beyond, may cut
/// the box; every other side stays the box's side. A frame whose outline is
/// its box keeps a null [Panel.shape].
///
/// [rgba] is the page as the model saw it, long side about [outlineLongSide]
/// pixels (the thresholds are in those pixels). Balloons are cut out of the
/// art first, since they often bridge a gutter, and put back afterwards.
/// Runs in tens of milliseconds, on the detector's worker isolate.
///
/// Tuned on the labelled test pages (spike/outlines.py mirrors this): of
/// 2,181 frames on 379 pages it reshapes 52, all right or harmless on
/// review. Borderless art on paper, rounded corners and thin-lined tilted
/// panels keep their boxes.
List<Panel> refineOutlines(Uint8List rgba, int w, int h, List<Panel> frames, List<Panel> balloons) {
  if (frames.isEmpty || w < 16 || h < 16) return frames;
  return _Outliner(rgba, w, h, frames, balloons).run();
}

/// The long side, in pixels, that [refineOutlines]'s thresholds assume.
const outlineLongSide = 800;

const _paperTolerance = 30; // max channel difference from the paper colour
const _erodeSize = 5; // snaps ink bridges this thin across a gutter
const _inset = 3; // px inside/outside an edge where it is sampled
const _band = 16; // depth of solid art required inside a cut edge
const _minSupport = 0.85; // share of the edge the art must reach
const _minGutter = 0.6; // share of the edge with gutter just outside
const _beyond = 0.3; // max share of walks that meet the panel's own art
const _minLen = 0.3; // cut edges at least this share of the box's short side
const _minAngle = 2.0; // degrees off the axes; less is a loose box, not a slant
const _minCut = 0.015; // a cut removes at least this share of the box
const _solid = 0.75; // art must fill this share of the outline

/// A box in page pixels, exact ([x0] to [y1]) and rounded to whole pixels.
typedef _PixelBox = ({double x0, double y0, double x1, double y1, int xi0, int yi0, int xi1, int yi1});

class _Outliner {
  _Outliner(this.rgba, this.w, this.h, this.frames, this.balloons);

  final Uint8List rgba;
  final int w, h;
  final List<Panel> frames, balloons;

  late final Uint8List gutter; // 1 where the flood reached
  late final Uint8List dist; // difference from the paper colour, 0..255
  late final Int32List comp; // eroded-ink component per pixel, 0 = none
  late final Int32List owner; // box index per component, -1 = none

  List<Panel> run() {
    final boxes = [for (final f in frames) _box(f)];
    _flood(boxes);
    _components(boxes);
    return [
      for (final (i, f) in frames.indexed)
        switch (_outline(i, boxes[i])) {
          final s? => f.withShape(s),
          null => f,
        },
    ];
  }

  _PixelBox _box(Panel p) {
    final x0 = p.x * w, y0 = p.y * h, x1 = p.right * w, y1 = p.bottom * h;
    return (
      x0: x0,
      y0: y0,
      x1: x1,
      y1: y1,
      xi0: math.max(0, x0.floor()),
      yi0: math.max(0, y0.floor()),
      xi1: math.min(w, x1.ceil()),
      yi1: math.min(h, y1.ceil()),
    );
  }

  /// Paper colour from the page outside every box (or its outer band when
  /// the boxes cover nearly all of it), then a flood over paper-coloured
  /// pixels from there: the gutters.
  void _flood(List<_PixelBox> boxes) {
    final n = w * h;
    final outside = Uint8List(n)..fillRange(0, n, 1);
    for (final b in boxes) {
      for (var y = b.yi0; y < b.yi1; y++) {
        outside.fillRange(y * w + b.xi0, y * w + math.max(b.xi0, b.xi1), 0);
      }
    }
    final band = Uint8List(n);
    final k = math.max(2, h ~/ 60);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (y < k || y >= h - k || x < k || x >= w - k) band[y * w + x] = 1;
      }
    }
    var outCount = 0;
    for (final v in outside) {
      outCount += v;
    }
    final seedSrc = outCount > 0.005 * n ? outside : band;
    final hist = List.generate(3, (_) => Int32List(256));
    var total = 0;
    for (var i = 0; i < n; i++) {
      if (seedSrc[i] == 0) continue;
      total++;
      for (var c = 0; c < 3; c++) {
        hist[c][rgba[i * 4 + c]]++;
      }
    }
    final paper = [for (final hc in hist) _median(hc, total)];
    dist = Uint8List(n);
    final paperLike = Uint8List(n);
    for (var i = 0; i < n; i++) {
      var d = 0;
      for (var c = 0; c < 3; c++) {
        final v = (rgba[i * 4 + c] - paper[c]).abs();
        if (v > d) d = v;
      }
      dist[i] = d;
      if (d < _paperTolerance) paperLike[i] = 1;
    }
    gutter = Uint8List(n);
    final queue = Int32List(n);
    var head = 0, tail = 0;
    for (var i = 0; i < n; i++) {
      if ((seedSrc[i] == 1 || band[i] == 1) && paperLike[i] == 1) {
        gutter[i] = 1;
        queue[tail++] = i;
      }
    }
    while (head < tail) {
      final i = queue[head++];
      final x = i % w;
      void visit(int j) {
        if (paperLike[j] == 1 && gutter[j] == 0) {
          gutter[j] = 1;
          queue[tail++] = j;
        }
      }

      if (x > 0) visit(i - 1);
      if (x < w - 1) visit(i + 1);
      if (i >= w) visit(i - w);
      if (i < n - w) visit(i + w);
    }
  }

  static int _median(Int32List hist, int total) {
    if (total == 0) return 255;
    // numpy's median of an even count averages the two middle values.
    int at(int rank) {
      var seen = 0;
      for (var v = 0; v < 256; v++) {
        seen += hist[v];
        if (seen > rank) return v;
      }
      return 255;
    }

    return total.isOdd ? at(total ~/ 2) : ((at(total ~/ 2 - 1) + at(total ~/ 2)) / 2).round();
  }

  /// Art pieces: what the flood did not reach, balloons cut out, thin
  /// bridges eroded, split into 4-connected components, each owned by the
  /// box holding the largest share of it.
  void _components(List<_PixelBox> boxes) {
    final n = w * h;
    var ink = Uint8List(n);
    for (var i = 0; i < n; i++) {
      ink[i] = 1 - gutter[i];
    }
    for (final b in balloons) {
      final bb = _box(b);
      for (var y = bb.yi0; y < bb.yi1; y++) {
        ink.fillRange(y * w + bb.xi0, y * w + math.max(bb.xi0, bb.xi1), 0);
      }
    }
    ink = erode(ink, w, h, _erodeSize ~/ 2);
    comp = Int32List(n);
    final area = <int>[0];
    final queue = Int32List(n);
    var label = 0;
    for (var s = 0; s < n; s++) {
      if (ink[s] == 0 || comp[s] != 0) continue;
      label++;
      var head = 0, tail = 0, count = 0;
      comp[s] = label;
      queue[tail++] = s;
      while (head < tail) {
        final i = queue[head++];
        count++;
        final x = i % w;
        void visit(int j) {
          if (ink[j] == 1 && comp[j] == 0) {
            comp[j] = label;
            queue[tail++] = j;
          }
        }

        if (x > 0) visit(i - 1);
        if (x < w - 1) visit(i + 1);
        if (i >= w) visit(i - w);
        if (i < n - w) visit(i + w);
      }
      area.add(count);
    }
    owner = Int32List(label + 1)..fillRange(0, label + 1, -1);
    final best = Float64List(label + 1);
    for (final (bi, b) in boxes.indexed) {
      final cnt = _countIn(b.xi0, b.yi0, b.xi1, b.yi1, label);
      for (var l = 0; l <= label; l++) {
        final frac = cnt[l] / math.max(area[l], 1);
        if (frac > best[l]) {
          best[l] = frac;
          owner[l] = bi;
        }
      }
    }
  }

  Int32List _countIn(int x0, int y0, int x1, int y1, int labels) {
    final cnt = Int32List(labels + 1);
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        cnt[comp[y * w + x]]++;
      }
    }
    return cnt;
  }

  /// The outline of box [i] in page coordinates, or null to keep the box.
  List<double>? _outline(int i, _PixelBox b) {
    final bw = b.xi1 - b.xi0, bh = b.yi1 - b.yi0;
    if (bw < 8 || bh < 8) return null;
    final size = bw * bh;
    final cnt = _countIn(b.xi0, b.yi0, b.xi1, b.yi1, owner.length - 1);
    final sub = Int32List(size);
    var mask = Uint8List(size);
    var any = false;
    for (var y = 0; y < bh; y++) {
      for (var x = 0; x < bw; x++) {
        final l = comp[(y + b.yi0) * w + x + b.xi0];
        sub[y * bw + x] = l;
        if (l > 0 && owner[l] == i && cnt[l] > 0.002 * size) {
          mask[y * bw + x] = 1;
          any = true;
        }
      }
    }
    if (!any) return null;
    mask = dilate(mask, bw, bh, _erodeSize ~/ 2);
    // Put this panel's balloons back.
    for (final bl in balloons) {
      final bx0 = bl.x * w, by0 = bl.y * h, bx1 = bl.right * w, by1 = bl.bottom * h;
      final cx = (bx0 + bx1) / 2, cy = (by0 + by1) / 2;
      if (cx < b.x0 || cx > b.x1 || cy < b.y0 || cy > b.y1) continue;
      final l = math.max(0, bx0.toInt() - b.xi0), r = math.min(bw - 1, bx1.ceil() - b.xi0);
      final t = math.max(0, by0.toInt() - b.yi0), btm = math.min(bh - 1, by1.ceil() - b.yi0);
      for (var y = t; y <= btm; y++) {
        for (var x = l; x <= r; x++) {
          mask[y * bw + x] = 1;
        }
      }
    }
    final hull = _hull(mask, bw, bh);
    if (hull.length < 3) return null;
    final poly = _simplify(hull, 0.01 * _perimeter(hull));
    if (poly.length < 3) return null;

    final gsub = Uint8List(size);
    for (var y = 0; y < bh; y++) {
      for (var x = 0; x < bw; x++) {
        gsub[y * bw + x] = gutter[(y + b.yi0) * w + x + b.xi0];
      }
    }
    final centre = _mean(poly);
    var shape = <(double, double)>[(0, 0), (bw.toDouble(), 0), (bw.toDouble(), bh.toDouble()), (0, bh.toDouble())];
    var cuts = 0;
    for (var k = 0; k < poly.length; k++) {
      final a = poly[k], c = poly[(k + 1) % poly.length];
      final len = math.sqrt(_sq(c.$1 - a.$1) + _sq(c.$2 - a.$2));
      if (_aligned(a, c, bw, bh) || len < _minLen * math.min(bw, bh)) continue;
      final ang = math.atan2((c.$2 - a.$2).abs(), (c.$1 - a.$1).abs()) * 180 / math.pi;
      if (math.min(ang, 90 - ang) < _minAngle) continue;
      var deep = 0.0;
      for (var d = 2; d < _band; d += 2) {
        deep += _support(mask, bw, bh, a, c, centre, d.toDouble());
      }
      final inside = math.min(_support(mask, bw, bh, a, c, centre, _inset.toDouble()), deep / ((_band - 2) ~/ 2));
      if (inside < _minSupport) continue;
      if (_support(gsub, bw, bh, a, c, centre, -_inset.toDouble()) < _minGutter) continue;
      if (_past(sub, bw, bh, i, a, c, centre) > _beyond) continue;
      final cut = clipConvex(shape, _halfPlane(a, c, centre, bw, bh));
      if (polygonArea(shape) - polygonArea(cut) > _minCut * size) {
        shape = cut;
        cuts++;
      }
    }
    if (cuts == 0 || shape.length < 3 || polygonArea(shape) < 0.5 * size) return null;
    // Borderless art on paper: the hull is the drawing, not a frame.
    if (_fill(mask, bw, bh, shape) < _solid) return null;
    return [
      for (final (x, y) in shape) ...[(x + b.xi0) / w, (y + b.yi0) / h],
    ];
  }

  /// Share of points along edge a-c, [inset] px towards [centre] (away
  /// from it when negative), where [m] is set.
  static double _support(
    Uint8List m,
    int bw,
    int bh,
    (double, double) a,
    (double, double) c,
    (double, double) centre,
    double inset,
  ) {
    final dx = c.$1 - a.$1, dy = c.$2 - a.$2;
    final len = math.sqrt(dx * dx + dy * dy);
    var nx = -dy / len, ny = dx / len;
    if ((centre.$1 - a.$1) * nx + (centre.$2 - a.$2) * ny < 0) {
      nx = -nx;
      ny = -ny;
    }
    final n = math.max(8, len ~/ 3);
    var hit = 0, seen = 0;
    for (var s = 0; s < n; s++) {
      final t = 0.1 + 0.8 * s / (n - 1);
      final px = a.$1 + t * dx + inset * nx, py = a.$2 + t * dy + inset * ny;
      if (px < 0 || px > bw - 1 || py < 0 || py > bh - 1) continue;
      seen++;
      hit += m[py.round() * bw + px.round()];
    }
    return seen == 0 ? 0 : hit / seen;
  }

  /// Walks outward from edge a-c across the gutter. Behind a real frame
  /// edge lies another panel or the page margin; meeting this panel's own
  /// art (or art nobody owns) means the flood leaked into light art.
  /// Returns the share of walks that did.
  double _past(Int32List sub, int bw, int bh, int i, (double, double) a, (double, double) c, (double, double) centre) {
    final dx = c.$1 - a.$1, dy = c.$2 - a.$2;
    final len = math.sqrt(dx * dx + dy * dy);
    var nx = -dy / len, ny = dx / len;
    if ((centre.$1 - a.$1) * nx + (centre.$2 - a.$2) * ny > 0) {
      nx = -nx;
      ny = -ny;
    }
    var bad = 0;
    const walks = 15;
    for (var s = 0; s < walks; s++) {
      final t = 0.1 + 0.8 * s / (walks - 1);
      final px = a.$1 + t * dx, py = a.$2 + t * dy;
      for (var d = 2; d < 2 * math.max(bw, bh); d++) {
        final x = (px + d * nx).round(), y = (py + d * ny).round();
        if (x < 0 || x >= bw || y < 0 || y >= bh) break;
        final l = sub[y * bw + x];
        if (l > 0) {
          if (owner[l] == i || owner[l] == -1) bad++;
          break;
        }
      }
    }
    return bad / walks;
  }

  /// A big convex polygon for the side of line a-c that holds [centre], to
  /// clip the box with.
  static List<(double, double)> _halfPlane(
    (double, double) a,
    (double, double) c,
    (double, double) centre,
    int bw,
    int bh,
  ) {
    final dx = c.$1 - a.$1, dy = c.$2 - a.$2;
    final len = math.sqrt(dx * dx + dy * dy);
    final ux = dx / len, uy = dy / len;
    var nx = -uy, ny = ux;
    if ((centre.$1 - a.$1) * nx + (centre.$2 - a.$2) * ny < 0) {
      nx = -nx;
      ny = -ny;
    }
    final far = 4.0 * (bw + bh);
    final p0 = (a.$1 - ux * far, a.$2 - uy * far), p1 = (a.$1 + ux * far, a.$2 + uy * far);
    return [p0, p1, (p1.$1 + nx * far, p1.$2 + ny * far), (p0.$1 + nx * far, p0.$2 + ny * far)];
  }

  /// Share of the pixels inside [poly] that are set in [m].
  static double _fill(Uint8List m, int bw, int bh, List<(double, double)> poly) {
    var inside = 0, set = 0;
    for (var y = 0; y < bh; y++) {
      // Convex: the row crosses the outline at most twice.
      var lo = double.infinity, hi = double.negativeInfinity;
      final yc = y.toDouble();
      for (var k = 0; k < poly.length; k++) {
        final (x0, y0) = poly[k];
        final (x1, y1) = poly[(k + 1) % poly.length];
        if ((y0 <= yc && yc <= y1) || (y1 <= yc && yc <= y0)) {
          final x = y1 == y0 ? math.min(x0, x1) : x0 + (yc - y0) * (x1 - x0) / (y1 - y0);
          final x2 = y1 == y0 ? math.max(x0, x1) : x;
          lo = math.min(lo, x);
          hi = math.max(hi, x2);
        }
      }
      if (lo > hi) continue;
      for (var x = math.max(0, lo.ceil()); x <= math.min(bw - 1, hi.floor()); x++) {
        inside++;
        set += m[y * bw + x];
      }
    }
    return inside == 0 ? 0 : set / inside;
  }
}

/// Convex hull of the set pixels (monotone chain over each row's ends),
/// counter-clockwise in image coordinates.
List<(double, double)> _hull(Uint8List m, int w, int h) {
  final pts = <(double, double)>[];
  for (var y = 0; y < h; y++) {
    var lo = -1, hi = -1;
    for (var x = 0; x < w; x++) {
      if (m[y * w + x] == 1) {
        if (lo < 0) lo = x;
        hi = x;
      }
    }
    if (lo < 0) continue;
    pts.add((lo.toDouble(), y.toDouble()));
    if (hi != lo) pts.add((hi.toDouble(), y.toDouble()));
  }
  if (pts.length < 3) return pts;
  pts.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  double cross((double, double) o, (double, double) a, (double, double) b) =>
      (a.$1 - o.$1) * (b.$2 - o.$2) - (a.$2 - o.$2) * (b.$1 - o.$1);
  final lower = <(double, double)>[], upper = <(double, double)>[];
  for (final p in pts) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  for (final p in pts.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  return [...lower.sublist(0, lower.length - 1), ...upper.sublist(0, upper.length - 1)];
}

double _perimeter(List<(double, double)> p) {
  var sum = 0.0;
  for (var i = 0; i < p.length; i++) {
    final a = p[i], b = p[(i + 1) % p.length];
    sum += math.sqrt(_sq(b.$1 - a.$1) + _sq(b.$2 - a.$2));
  }
  return sum;
}

/// Douglas-Peucker on a closed polygon: split at the vertex farthest from
/// the first, simplify both halves.
List<(double, double)> _simplify(List<(double, double)> p, double eps) {
  var far = 0, farD = -1.0;
  for (var i = 1; i < p.length; i++) {
    final d = _sq(p[i].$1 - p[0].$1) + _sq(p[i].$2 - p[0].$2);
    if (d > farD) {
      farD = d;
      far = i;
    }
  }
  final a = _dp([...p.sublist(0, far + 1)], eps);
  final b = _dp([...p.sublist(far), p[0]], eps);
  return [...a.sublist(0, a.length - 1), ...b.sublist(0, b.length - 1)];
}

List<(double, double)> _dp(List<(double, double)> p, double eps) {
  if (p.length < 3) return p;
  final a = p.first, b = p.last;
  final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
  final len = math.sqrt(dx * dx + dy * dy);
  var worst = 0, worstD = -1.0;
  for (var i = 1; i < p.length - 1; i++) {
    final d = len == 0
        ? math.sqrt(_sq(p[i].$1 - a.$1) + _sq(p[i].$2 - a.$2))
        : ((p[i].$1 - a.$1) * dy - (p[i].$2 - a.$2) * dx).abs() / len;
    if (d > worstD) {
      worstD = d;
      worst = i;
    }
  }
  if (worstD <= eps) return [a, b];
  final l = _dp(p.sublist(0, worst + 1), eps), r = _dp(p.sublist(worst), eps);
  return [...l.sublist(0, l.length - 1), ...r];
}

(double, double) _mean(List<(double, double)> p) {
  var x = 0.0, y = 0.0;
  for (final q in p) {
    x += q.$1;
    y += q.$2;
  }
  return (x / p.length, y / p.length);
}

bool _aligned((double, double) a, (double, double) b, int w, int h, {double tol = 0.02}) {
  final tx = tol * w + 1, ty = tol * h + 1;
  return ((a.$1).abs() < tx && (b.$1).abs() < tx) ||
      ((a.$1 - w).abs() < tx && (b.$1 - w).abs() < tx) ||
      ((a.$2).abs() < ty && (b.$2).abs() < ty) ||
      ((a.$2 - h).abs() < ty && (b.$2 - h).abs() < ty);
}

double _sq(double v) => v * v;
