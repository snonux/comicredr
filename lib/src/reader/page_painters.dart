import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:comic_analysis/comic_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'page_cache.dart';

/// A decoded page, drawn with auto-trim's margins cut off, a sharp [tile]
/// of part of it on top when zoomed in, and scan clean-up's levels, a
/// colour matrix that costs nothing to draw.
class PagePainter extends CustomPainter {
  const PagePainter(this.image, this.trim, this.levels, [this.tile]);

  final ui.Image image;
  final Trim trim;
  final Levels levels;
  final Tile? tile;

  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width.toDouble(), h = image.height.toDouble();
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = levels.isNone ? null : ColorFilter.matrix(levels.matrix);
    canvas.drawImageRect(
      image,
      Rect.fromLTRB(trim.left * w, trim.top * h, trim.right * w, trim.bottom * h),
      Offset.zero & size,
      paint,
    );
    final tile = this.tile;
    if (tile == null) return;
    final r = tile.region;
    final sx = size.width / trim.width, sy = size.height / trim.height;
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..drawImageRect(
        tile.image,
        Rect.fromLTWH(0, 0, tile.image.width.toDouble(), tile.image.height.toDouble()),
        Rect.fromLTWH((r.left - trim.left) * sx, (r.top - trim.top) * sy, r.width * sx, r.height * sy),
        paint,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(PagePainter old) =>
      !identical(old.image, image) ||
      old.trim != trim ||
      old.levels != levels ||
      !identical(old.tile?.image, tile?.image);
}

/// A decoded page drawn 240 px wide as RGBA, which smooths away paper
/// grain: what auto-trim and scan clean-up measure.
Future<(Uint8List, int, int)> smallCopy(ui.Image image) async {
  const w = 240;
  final h = math.max(16, (image.height * w / image.width).round());
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final small = await picture.toImage(w, h);
  picture.dispose();
  final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
  small.dispose();
  if (data == null) throw StateError('page could not be read back');
  return (data.buffer.asUint8List(), w, h);
}

/// Dimmed and warmed, for reading in the dark. A colour matrix costs nothing.
const nightMatrix = <double>[
  0.55, 0.10, 0.05, 0, 0, //
  0.05, 0.45, 0.05, 0, 0, //
  0.02, 0.05, 0.30, 0, 0, //
  0, 0, 0, 1, 0,
];

/// The part of [outline] (a frame's real shape, page coordinates) inside
/// [hole], as points relative to [hole]; null when there is no outline and
/// the hole is its rectangle.
List<Offset>? holeShape(Rect hole, List<double>? outline) {
  if (outline == null || hole.isEmpty) return null;
  final clipped = clipConvex(
    [for (var i = 0; i + 1 < outline.length; i += 2) (outline[i], outline[i + 1])],
    [(hole.left, hole.top), (hole.right, hole.top), (hole.right, hole.bottom), (hole.left, hole.bottom)],
  );
  if (clipped.length < 3) return null;
  return [for (final (x, y) in clipped) Offset((x - hole.left) / hole.width, (y - hole.top) / hole.height)];
}

/// Dims the page outside [hole] (page coordinates, 0..1) to 45%, so the
/// panel stands out and the reader keeps their place on the page. With a
/// [shape] (relative to [hole]) the hole is that polygon, so the corners
/// of the neighbours around a slanted panel are dimmed too.
class DimPainter extends CustomPainter {
  const DimPainter(this.hole, [this.shape]);

  final Rect hole;
  final List<Offset>? shape;

  @override
  void paint(Canvas canvas, Size size) {
    final page = Offset.zero & size;
    final cut = Rect.fromLTRB(
      hole.left * size.width,
      hole.top * size.height,
      hole.right * size.width,
      hole.bottom * size.height,
    );
    final shape = this.shape;
    final path = shape == null
        ? (Path()..addRect(cut))
        : (Path()..addPolygon([
            for (final p in shape) Offset(cut.left + p.dx * cut.width, cut.top + p.dy * cut.height),
          ], true));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(page), path),
      Paint()..color = const Color(0x8C000000),
    );
  }

  @override
  bool shouldRepaint(DimPainter old) => old.hole != hole || !listEquals(old.shape, shape);
}
