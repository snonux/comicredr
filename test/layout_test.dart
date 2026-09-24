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

  test('a page wider than tall is a spread, a square page is not', () {
    expect(isWidePage(2600, 2000), isTrue);
    expect(isWidePage(1000, 1000), isFalse);
    expect(isWidePage(1300, 2000), isFalse);
  });

  test('a wide page stands alone and pairing starts again after it', () {
    // Pages 1-2, then a double-page scan at 3, then 4-5 keep their sides.
    const wide = {3};
    List<int> at(int p) => unitAt(p, 10, PageMode.spread, wide: wide);
    expect(at(0), [0]);
    expect(at(2), [1, 2]);
    expect(at(3), [3]);
    expect(at(4), [4, 5]);
    expect(at(7), [6, 7]);
    expect(at(9), [8, 9]);
    // Landing on the wrong side: page 1 is left over and stands alone.
    List<int> at2(int p) => unitAt(p, 10, PageMode.spread, wide: {2});
    expect([for (var p = 0; p < 10; p++) at2(p).first], [0, 1, 2, 3, 3, 5, 5, 7, 7, 9]);
    expect(at2(9), [9]);
  });

  test('stepping walks the units around a wide page, both ways', () {
    const wide = {3};
    int step(int p, int n) => stepFrom(p, n, 10, PageMode.spread, wide: wide);
    expect(step(1, 1), 3);
    expect(step(3, 1), 4);
    expect(step(4, -1), 3);
    expect(step(3, -1), 1);
    expect(step(0, 3), 4);
    // Single mode ignores wide pages.
    expect(unitAt(3, 10, PageMode.single, wide: wide), [3]);
  });

  test('wide pages with the cover in the first spread, and a wide cover', () {
    expect(unitAt(0, 6, PageMode.spread, coverAlone: false, wide: {2}), [0, 1]);
    expect(unitAt(3, 6, PageMode.spread, coverAlone: false, wide: {2}), [3, 4]);
    expect(unitAt(0, 6, PageMode.spread, coverAlone: false, wide: {0}), [0]);
    expect(unitAt(1, 6, PageMode.spread, coverAlone: false, wide: {0}), [1, 2]);
    expect(unitAt(5, 6, PageMode.spread, wide: {4}), [5]);
  });
}
