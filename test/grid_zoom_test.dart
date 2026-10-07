import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/grid_zoom.dart';
import 'package:comicredr/src/library/cover_card.dart';
import 'package:comicredr/src/library/shuffle.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The zoom the page grid and the library's covers share: its arithmetic
/// for any number a settings file may hold, the kept size giving the same
/// columns back, and the pinch with fingers coming and going.
void main() {
  // The library's covers and the page grid, as those two set it up.
  const covers = GridZoom(gap: 12, smallest: 72, largest: 480);
  const pages = GridZoom(gap: 8, smallest: 56);

  test('a size that is no size never throws: the columns stay within the limits', () {
    final sizes = [double.nan, -12.0, 0.0, -0.0, double.infinity, double.negativeInfinity, 1e300, 1e-300, 5e-324];
    for (final zoom in [covers, pages, const GridZoom(gap: 0, smallest: 1)]) {
      for (final inner in [1256.0, 376.0, 0.0, -24.0, double.nan, double.infinity]) {
        for (final size in sizes) {
          final n = zoom.columns(inner, size);
          expect(n, inInclusiveRange(zoom.fewest(inner), zoom.most(inner)), reason: 'size $size in $inner');
          expect(zoom.clamp(inner, n), n);
        }
      }
    }
    // Which end: nothing and less is the smallest tiles, endless the biggest.
    expect(covers.columns(1256, double.nan), covers.most(1256));
    expect(covers.columns(1256, -12), covers.most(1256));
    expect(covers.columns(1256, 0), covers.most(1256));
    expect(covers.columns(1256, double.infinity), covers.fewest(1256));
    expect(covers.columns(1256, 1e300), covers.fewest(1256));
    expect(pages.columns(776, double.infinity), 1);
    expect(covers.most(double.nan), 2);
    expect(covers.fewest(double.nan), 1);
  });

  test('a kept size is a finite number above zero, or nothing', () {
    for (final bad in ['NaN', '-12', '0', '-0.0', 'Infinity', '-Infinity', '1e999', 'big', '', ' ', '12px']) {
      expect(SettingsStore.parseSize(bad), isNull, reason: '"$bad"');
    }
    expect(SettingsStore.parseSize(null), isNull);
    expect(SettingsStore.parseSize('240.0'), 240);
    expect(SettingsStore.parseSize('72.05263157894737'), 72.05263157894737);
    expect(SettingsStore.parseSize('1e300'), 1e300, reason: 'huge but a number: the grid keeps to its biggest');
  });

  test('the kept size gives back the columns it was kept at, whatever the width', () {
    // Every window width from the narrowest a tile still has a width in
    // up to a 4K screen, less the 12 px either side both grids leave.
    for (final (zoom, name) in [(covers, 'covers'), (pages, 'pages')]) {
      var checked = 0;
      for (var window = 120; window <= 3840; window++) {
        final inner = window - 24.0;
        for (var n = zoom.fewest(inner); n <= zoom.most(inner); n++) {
          final kept = SettingsStore.sizeText(zoom.tileWidth(inner, n));
          final back = SettingsStore.parseSize(kept);
          expect(back, isNotNull, reason: '$name: $n columns in $inner kept as "$kept"');
          if (zoom.columns(inner, back!) != n) {
            fail('$name: $n columns in $inner px, kept as "$kept", came back as ${zoom.columns(inner, back)}');
          }
          checked++;
        }
      }
      expect(checked, greaterThan(50000), reason: '$name: the sweep ran');
    }
    // The case that went wrong when a tenth of a pixel was kept.
    expect(covers.tileWidth(1585, 19).toStringAsFixed(1), '72.1');
    expect(covers.columns(1585, 72.1), 18);
    expect(covers.columns(1585, SettingsStore.parseSize(SettingsStore.sizeText(covers.tileWidth(1585, 19)))!), 19);
  });

  test('covers and shuffled pages decode at a few widths only', () {
    expect(coverDecodeWidths, [400, 512]);
    // Two zoom steps apart, or a window dragged a little: the same pixels.
    expect(coverDecodeWidth(401), coverDecodeWidth(437));
    expect(coverDecodeWidth(160), coverDecodeWidth(399.6));
    expect({for (var px = 1.0; px < 2000; px += 0.7) coverDecodeWidth(px)}, {400, 512});
    expect(coverDecodeWidth(72), 400, reason: 'the default size and smaller: what the details decode too');
    expect(coverDecodeWidth(400), 400);
    expect(coverDecodeWidth(400.5), 512);
    expect(coverDecodeWidth(1440), 512, reason: 'the files have no more');

    expect(ShufflePages.sizeFor(340), ShufflePages.sizeFor(480));
    expect({for (var px = 1.0; px < 2000; px += 0.7) ShufflePages.sizeFor(px)}, {256, 512});
    expect(ShufflePages.sizeFor(160), 256);
    expect(ShufflePages.sizeFor(332), 256);
    expect(ShufflePages.sizeFor(334), 512);
    expect(ShufflePages.sizeFor(1440), 512);
    final shuffle = ShufflePages(dir: '/cache/pages');
    expect(shuffle.pathOf('k', 4), '/cache/pages/k/5.jpg');
    expect(shuffle.pathOf('k', 4, 512), '/cache/pages/k/w512/5.jpg', reason: "the page grid's 512 px file");
    shuffle.close();
  });

  group('the pinch', () {
    /// A zoom area over a list, 6 columns at first, 1 to 12 allowed;
    /// returns every column count it asked for.
    Future<List<int>> pumpArea(WidgetTester tester) async {
      final asked = <int>[];
      var columns = 6;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => GridZoomArea(
              columns: columns,
              onColumns: (n) {
                asked.add(n);
                setState(() => columns = n.clamp(1, 12));
              },
              builder: (context, physics) =>
                  ListView(physics: physics, children: [Text('$columns columns'), const SizedBox(height: 3000)]),
            ),
          ),
        ),
      );
      return asked;
    }

    Future<TestGesture> finger(WidgetTester tester, double x) =>
        tester.startGesture(Offset(x, 300), kind: PointerDeviceKind.touch);
    ScrollPhysics? physics(WidgetTester tester) => tester.widget<ListView>(find.byType(ListView)).physics;

    testWidgets('a third finger taking over from one that lifts does not make the columns jump', (tester) async {
      await pumpArea(tester);
      final a = await finger(tester, 100);
      final b = await finger(tester, 200);
      await tester.pump();
      expect(physics(tester), isA<NeverScrollableScrollPhysics>(), reason: 'two fingers do not scroll');
      await b.moveBy(const Offset(10, 0)); // 100 to 110 apart: no step yet.
      await tester.pump();
      expect(find.text('6 columns'), findsOneWidget);

      // A third finger far off; then the first lifts. The pinch is now
      // between the second and the third, 390 apart: nothing moved, so
      // nothing zooms. (Measured against the first pair's 100 it would be
      // a spread to four times, down to one column.)
      final c = await finger(tester, 600);
      await tester.pump();
      expect(find.text('6 columns'), findsOneWidget, reason: 'a third finger down');
      await a.up();
      await tester.pump();
      await c.moveBy(const Offset(10, 0));
      await tester.pump();
      expect(find.text('6 columns'), findsOneWidget, reason: 'the first finger lifted, the third barely moved');
      expect(physics(tester), isA<NeverScrollableScrollPhysics>(), reason: 'still two fingers');

      // The new pair pinches from where it is: a third wider is one step.
      await c.moveBy(const Offset(130, 0));
      await tester.pump();
      expect(find.text('5 columns'), findsOneWidget);
      await c.moveBy(const Offset(-340, 0)); // 190 apart of the 390 it started at: three steps closer.
      await tester.pump();
      expect(find.text('9 columns'), findsOneWidget);

      await b.up();
      await tester.pump();
      expect(physics(tester), isNot(isA<NeverScrollableScrollPhysics>()), reason: 'one finger left: it scrolls again');
      await c.moveBy(const Offset(200, 0));
      await c.up();
      await tester.pump();
      expect(find.text('9 columns'), findsOneWidget, reason: 'one finger does not zoom');
    });

    testWidgets('the grid going away under a pinch is no error', (tester) async {
      final asked = await pumpArea(tester);
      final a = await finger(tester, 100);
      final b = await finger(tester, 200);
      await b.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(asked, [5], reason: 'the pinch was under way');

      // The tab changed, the book closed: the fingers are still down, and
      // go on reporting to the area that is no longer there.
      await tester.pumpWidget(const SizedBox());
      await b.moveBy(const Offset(120, 0));
      final c = await finger(tester, 400);
      await c.moveBy(const Offset(50, 0));
      await a.up();
      await b.cancel();
      await c.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(asked, [5], reason: 'nothing more was asked of a grid that is gone');
    });
  });
}
