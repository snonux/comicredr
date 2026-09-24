import 'package:comicredr/src/reader/layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('single mode shows one page', () {
    expect(unitAt(4, 10, PageMode.single), [4]);
    expect(stepFrom(4, 3, 10, PageMode.single), 7);
    expect(stepFrom(8, 5, 10, PageMode.single), 9);
    expect(stepFrom(1, -5, 10, PageMode.single), 0);
  });

  test('spreads keep the cover alone and pair the rest', () {
    expect(unitAt(0, 10, PageMode.spread), [0]);
    expect(unitAt(1, 10, PageMode.spread), [1, 2]);
    expect(unitAt(2, 10, PageMode.spread), [1, 2]);
    expect(unitAt(9, 10, PageMode.spread), [9]);
    expect(stepFrom(0, 1, 10, PageMode.spread), 1);
    expect(stepFrom(1, 1, 10, PageMode.spread), 3);
    expect(stepFrom(3, -2, 10, PageMode.spread), 0);
  });

  test('shifting the pairing puts the cover in the first spread', () {
    expect(unitAt(0, 10, PageMode.spread, coverAlone: false), [0, 1]);
    expect(unitAt(3, 10, PageMode.spread, coverAlone: false), [2, 3]);
    expect(unitAt(9, 9, PageMode.spread, coverAlone: false), [8]);
  });
}
