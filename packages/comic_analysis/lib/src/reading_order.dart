import 'panel.dart';

/// Sorts panels into reading order by recursive XY-cut.
///
/// The set is cut along a horizontal gutter that no panel crosses, giving
/// rows read top to bottom. When there is none, the leading column (the
/// leftmost, or the rightmost when [rightToLeft]) is peeled off along a
/// vertical gutter and read before the rest. Each part is sorted the same
/// way. So a tall panel beside a grid reads first and the grid then reads
/// row by row, which the M4 row rule got wrong. Panels may overlap a cut by
/// [tolerance] of the page, since detected boxes are never pixel-exact.
///
/// When nothing can be cut (overlapping balloons, a jumbled layout), the M4
/// rule decides: two panels share a row when their vertical extents overlap
/// by more than half of the shorter one.
///
/// A page wider than [spreadAspect] ([aspect] is its width over its
/// height) is a two-page spread: when no panel crosses the spine, the whole
/// leading page reads before the other, instead of rows running across
/// both pages.
///
/// The same order is used for balloons inside a panel. spike/evaluate.py
/// carries a Python copy that the eval set is scored with.
List<Panel> readingOrder(
  Iterable<Panel> panels, {
  bool rightToLeft = false,
  double tolerance = 0.01,
  double aspect = 1,
}) {
  List<Panel> rec(List<Panel> items) {
    if (items.length <= 1) return items;
    final rows = _cut(items, (p) => p.y, (p) => p.bottom, tolerance);
    if (rows.length > 1) return [for (final r in rows) ...rec(r)];
    final cols = rightToLeft
        ? _cut(items, (p) => -p.right, (p) => -p.x, tolerance)
        : _cut(items, (p) => p.x, (p) => p.right, tolerance);
    if (cols.length > 1) {
      return [
        ...rec(cols.first),
        ...rec([for (final c in cols.skip(1)) ...c]),
      ];
    }
    return _byRows(items, rightToLeft);
  }

  final items = panels.toList();
  if (aspect > spreadAspect && items.isNotEmpty) {
    final left = [
      for (final p in items)
        if (p.right <= 0.5 + tolerance) p,
    ];
    final right = [
      for (final p in items)
        if (p.x >= 0.5 - tolerance) p,
    ];
    if (left.isNotEmpty && right.isNotEmpty && left.length + right.length == items.length) {
      return rightToLeft ? [...rec(right), ...rec(left)] : [...rec(left), ...rec(right)];
    }
  }
  return rec(items);
}

/// Pages wider than this, width over height, are two-page spreads.
const spreadAspect = 1.2;

/// Splits [items] into runs along one axis wherever a gap no item spans
/// opens up, in increasing [start] order.
List<List<Panel>> _cut(List<Panel> items, double Function(Panel) start, double Function(Panel) end, double tol) {
  final sorted = [...items]..sort((a, b) => start(a).compareTo(start(b)));
  final groups = <List<Panel>>[
    [sorted.first],
  ];
  var reach = end(sorted.first);
  for (final p in sorted.skip(1)) {
    if (start(p) >= reach - tol) {
      groups.add([p]);
    } else {
      groups.last.add(p);
    }
    if (end(p) > reach) reach = end(p);
  }
  return groups;
}

/// The M4 rule, kept as the fallback for sets no gutter separates.
List<Panel> _byRows(List<Panel> panels, bool rightToLeft) {
  final sorted = [...panels]..sort((a, b) => a.y.compareTo(b.y));
  final rows = <List<Panel>>[];
  for (final p in sorted) {
    List<Panel>? home;
    for (final row in rows) {
      final top = row.map((r) => r.y).reduce((a, b) => a < b ? a : b);
      final bottom = row.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
      final overlap = (bottom < p.bottom ? bottom : p.bottom) - (top > p.y ? top : p.y);
      final shorter = p.h < bottom - top ? p.h : bottom - top;
      if (overlap > 0.5 * shorter) {
        home = row;
        break;
      }
    }
    (home ?? (rows..add(<Panel>[])).last).add(p);
  }
  double top(List<Panel> row) => row.map((p) => p.y).reduce((x, y) => x < y ? x : y);
  rows.sort((a, b) => top(a).compareTo(top(b)));
  return [for (final row in rows) ...(row..sort((a, b) => rightToLeft ? b.x.compareTo(a.x) : a.x.compareTo(b.x)))];
}
