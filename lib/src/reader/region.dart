import 'dart:ui';

import 'package:reader_input/reader_input.dart';

/// How a page is cut into fixed parts to enlarge by hand (`H1`, `T2`,
/// `Q4`...), for pages guided view shows whole or outside guided view.
enum PageSplit {
  halves(1, 2, ['upper half', 'lower half']),
  thirds(1, 3, ['upper third', 'middle third', 'lower third']),
  quarters(2, 2, ['top-left quarter', 'top-right quarter', 'bottom-left quarter', 'bottom-right quarter']);

  const PageSplit(this.columns, this.rows, this.names);

  final int columns;
  final int rows;

  /// Each part's name, by [part] number.
  final List<String> names;

  int get parts => columns * rows;
}

/// A part of a page shown enlarged: [part] numbers the parts of [split]
/// top to bottom, left to right, whatever the reading direction. [page] is
/// the page of the unit it is on, the first in reading order unless the
/// steps moved on to the other page of a spread.
typedef Region = ({PageSplit split, int part, int page});

/// Where [part] of [split] lies on the page shown, as fractions of it
/// (after auto-trim).
Rect partRect(PageSplit split, int part) {
  final col = part % split.columns, row = part ~/ split.columns;
  return Rect.fromLTWH(col / split.columns, row / split.rows, 1 / split.columns, 1 / split.rows);
}

/// The parts of [split] in reading order: rows top to bottom, each row in
/// the book's direction.
List<int> partOrder(PageSplit split, {required bool rightToLeft}) => [
  for (var row = 0; row < split.rows; row++)
    for (var c = 0; c < split.columns; c++) row * split.columns + (rightToLeft ? split.columns - 1 - c : c),
];

/// The split and part a region intent asks for; null for any other intent.
({PageSplit split, int part})? regionFor(ReaderIntent intent) => switch (intent) {
  ReaderIntent.regionUpperHalf => (split: PageSplit.halves, part: 0),
  ReaderIntent.regionLowerHalf => (split: PageSplit.halves, part: 1),
  ReaderIntent.regionUpperThird => (split: PageSplit.thirds, part: 0),
  ReaderIntent.regionMiddleThird => (split: PageSplit.thirds, part: 1),
  ReaderIntent.regionLowerThird => (split: PageSplit.thirds, part: 2),
  ReaderIntent.regionTopLeft => (split: PageSplit.quarters, part: 0),
  ReaderIntent.regionTopRight => (split: PageSplit.quarters, part: 1),
  ReaderIntent.regionBottomLeft => (split: PageSplit.quarters, part: 2),
  ReaderIntent.regionBottomRight => (split: PageSplit.quarters, part: 3),
  _ => null,
};

/// "upper third (1 / 3)", for the status line: the part's name and where
/// it comes in reading order.
String describeRegion(Region r, {required bool rightToLeft}) {
  final order = partOrder(r.split, rightToLeft: rightToLeft);
  return '${r.split.names[r.part]} (${order.indexOf(r.part) + 1} / ${r.split.parts})';
}
