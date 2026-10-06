import 'dart:ui';

import 'package:reader_input/reader_input.dart';

/// How a page is cut into fixed parts to enlarge by hand (`H1`, `B2`,
/// `L3`, `Q4`...), for pages guided view shows whole or outside guided view.
enum PageSplit {
  halves(1, 2, 'H', 2, 'Halves', ['upper half', 'lower half']),
  thirds(1, 3, 'B', 3, 'Thirds', ['upper third', 'middle third', 'lower third']),
  strips(1, 4, 'L', 4, 'Strips', ['top strip', 'second strip', 'third strip', 'bottom strip']),
  quarters(2, 2, 'Q', 5, 'Quarters', [
    'top-left quarter',
    'top-right quarter',
    'bottom-left quarter',
    'bottom-right quarter',
  ]);

  const PageSplit(this.columns, this.rows, this.letter, this.digit, this.label, this.names);

  final int columns;
  final int rows;

  /// The default keys' first character: the letter (`H1`) and the digit
  /// (`21`) that pick a part of this split.
  final String letter;
  final int digit;

  /// The split's name on the page parts picker.
  final String label;

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

/// [r], in fractions of the page as the screen shows it turned [turns]
/// quarter turns clockwise, in fractions of the page itself. So `H1` is the
/// upper half of a turned comic as it is seen.
Rect unturnRect(Rect r, int turns) => switch (turns % 4) {
  1 => Rect.fromLTRB(r.top, 1 - r.right, r.bottom, 1 - r.left),
  2 => Rect.fromLTRB(1 - r.right, 1 - r.bottom, 1 - r.left, 1 - r.top),
  3 => Rect.fromLTRB(1 - r.bottom, r.left, 1 - r.top, r.right),
  _ => r,
};

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
  ReaderIntent.regionStrip1 => (split: PageSplit.strips, part: 0),
  ReaderIntent.regionStrip2 => (split: PageSplit.strips, part: 1),
  ReaderIntent.regionStrip3 => (split: PageSplit.strips, part: 2),
  ReaderIntent.regionStrip4 => (split: PageSplit.strips, part: 3),
  ReaderIntent.regionTopLeft => (split: PageSplit.quarters, part: 0),
  ReaderIntent.regionTopRight => (split: PageSplit.quarters, part: 1),
  ReaderIntent.regionBottomLeft => (split: PageSplit.quarters, part: 2),
  ReaderIntent.regionBottomRight => (split: PageSplit.quarters, part: 3),
  _ => null,
};

/// The intent that picks [part] of [split], as its keys do.
ReaderIntent regionIntent(PageSplit split, int part) => switch (split) {
  PageSplit.halves => [ReaderIntent.regionUpperHalf, ReaderIntent.regionLowerHalf][part],
  PageSplit.thirds => [
    ReaderIntent.regionUpperThird,
    ReaderIntent.regionMiddleThird,
    ReaderIntent.regionLowerThird,
  ][part],
  PageSplit.strips => [
    ReaderIntent.regionStrip1,
    ReaderIntent.regionStrip2,
    ReaderIntent.regionStrip3,
    ReaderIntent.regionStrip4,
  ][part],
  PageSplit.quarters => [
    ReaderIntent.regionTopLeft,
    ReaderIntent.regionTopRight,
    ReaderIntent.regionBottomLeft,
    ReaderIntent.regionBottomRight,
  ][part],
};

/// "upper third (1 / 3)", for the status line: the part's name and where
/// it comes in reading order.
String describeRegion(Region r, {required bool rightToLeft}) {
  final order = partOrder(r.split, rightToLeft: rightToLeft);
  return '${r.split.names[r.part]} (${order.indexOf(r.part) + 1} / ${r.split.parts})';
}
