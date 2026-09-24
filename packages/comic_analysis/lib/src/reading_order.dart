import 'panel.dart';

/// Sorts frames into reading order: rows top to bottom, and within a row
/// left to right, or right to left when [rightToLeft] is set.
///
/// Two panels share a row when their vertical extents overlap by more than
/// half of the shorter one. This is the same rule the M1 spike uses.
List<Panel> readingOrder(Iterable<Panel> panels, {bool rightToLeft = false}) {
  final sorted = panels.toList()..sort((a, b) => a.y.compareTo(b.y));
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
  rows.sort(
    (a, b) => a
        .map((p) => p.y)
        .reduce((x, y) => x < y ? x : y)
        .compareTo(b.map((p) => p.y).reduce((x, y) => x < y ? x : y)),
  );
  return [
    for (final row in rows) ...(row..sort((a, b) => rightToLeft ? b.x.compareTo(a.x) : a.x.compareTo(b.x))),
  ];
}
