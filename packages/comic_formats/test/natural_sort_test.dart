import 'dart:math';

import 'package:comic_formats/comic_formats.dart';
import 'package:test/test.dart';

/// The comparison as it was written before it was made fast (regular
/// expressions and lists), which the fast one must agree with everywhere.
int _slowCompare(String a, String b) {
  final pa = a.toLowerCase().split('/');
  final pb = b.toLowerCase().split('/');
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final c = _slowName(pa[i], pb[i]);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

int _slowName(String a, String b) {
  List<String> tokens(String s) => [for (final m in RegExp(r'\d+|\D+').allMatches(s)) m[0]!];
  bool digits(String s) => s.codeUnitAt(0) >= 48 && s.codeUnitAt(0) <= 57;
  final ta = tokens(a), tb = tokens(b);
  for (var i = 0; i < ta.length && i < tb.length; i++) {
    final x = ta[i], y = tb[i];
    int c;
    if (digits(x) && digits(y)) {
      final sx = x.replaceFirst(RegExp(r'^0+'), ''), sy = y.replaceFirst(RegExp(r'^0+'), '');
      c = sx.length != sy.length ? sx.length.compareTo(sy.length) : sx.compareTo(sy);
      if (c == 0) c = x.length.compareTo(y.length);
    } else {
      c = x.compareTo(y);
    }
    if (c != 0) return c;
  }
  return ta.length.compareTo(tb.length);
}

void main() {
  test('orders as a person would', () {
    final names = ['b/page10.jpg', 'a/Page2.jpg', 'a/page1.jpg', 'Issue 1 Bonus/x', 'Issue 1/y', 'b/page01.jpg'];
    expect(names..sort(naturalCompare), [
      'a/page1.jpg',
      'a/Page2.jpg',
      'b/page01.jpg',
      'b/page10.jpg',
      'Issue 1/y',
      'Issue 1 Bonus/x',
    ]);
  });

  test('agrees with the slow comparison on random paths', () {
    final random = Random(7);
    const alphabet = ['a', 'B', 'z', ' ', '-', '.', '/', '0', '00', '1', '7', '10', '09', 'é', 'Ä', '_', ''];
    String path() => [for (var i = random.nextInt(9); i > 0; i--) alphabet[random.nextInt(alphabet.length)]].join();
    for (var n = 0; n < 200000; n++) {
      final a = path(), b = path();
      expect(naturalCompare(a, b).sign, _slowCompare(a, b).sign, reason: '"$a" vs "$b"');
    }
  });

  test('sorts a big library fast', () {
    final paths = [
      for (var i = 0; i < 5000; i++)
        '/home/reader/Comics/Publisher ${i % 7}/Series ${i % 40}/Issue ${i * 37 % 997}.cbz',
    ];
    final sw = Stopwatch()..start();
    paths.sort(naturalCompare);
    // Was about a second on the UI isolate with regular expressions.
    expect(sw.elapsedMilliseconds, lessThan(250));
  });
}
