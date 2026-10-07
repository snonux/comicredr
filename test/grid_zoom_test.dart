import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/grid_zoom.dart';
import 'package:comicredr/src/library/cover_card.dart';
import 'package:comicredr/src/library/shuffle.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The zoom the page grid and the library's covers share: its arithmetic
/// for any number a settings file may hold, the kept size giving the same
/// columns back, and the pinch with fingers coming and going.
void main() {
  // The library's covers and the page grid: the very limits those two use.
  const covers = GridZoom.covers;
  const pages = GridZoom.pages;

  test('the limits the two grids zoom between', () {
    // Stated once, so a change of them is a change on purpose; every other
    // test here follows the real ones.
    expect((covers.gap, covers.smallest, covers.largest), (12, 72, 480));
    expect((pages.gap, pages.smallest, pages.largest), (8, 56, double.infinity));
  });

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

  test('covers sized by hand decode at four widths only, small ones small', () {
    expect(coverDecodeWidths, [128, 256, 400, 512]);
    // Two zoom steps apart, or a window dragged a little: the same pixels.
    expect(coverDecodeWidth(401), coverDecodeWidth(437));
    expect(coverDecodeWidth(260), coverDecodeWidth(399.6));
    expect({for (var px = 1.0; px < 2000; px += 0.7) coverDecodeWidth(px)}, {128, 256, 400, 512});
    for (final (px, width) in [
      (72.0, 128),
      (128.0, 128),
      (128.5, 256),
      (160.0, 256),
      (256.0, 256),
      (256.5, 400),
      (400.0, 400),
      (400.5, 512),
      (1440.0, 512), // The files have no more.
    ]) {
      expect(coverDecodeWidth(px), width, reason: 'a tile of $px device pixels');
      expect(width >= px || width == 512, isTrue, reason: 'never fewer pixels than the tile, up to the file');
    }
    // By device pixels: the same 72 px cover on screens of 1, 2 and 3
    // pixels a point, and the biggest, 480 px.
    int sized(double tile, double ratio) => coverPictureSizes(tile * ratio, zoomed: true).cover;
    expect([sized(72, 1), sized(72, 2), sized(72, 3)], [128, 256, 256]);
    expect([sized(120, 1), sized(120, 2), sized(120, 3)], [128, 256, 400]);
    expect([sized(480, 1), sized(480, 2), sized(480, 3)], [512, 512, 512]);
    // What a 1920 px window full of the smallest covers holds decoded: 23
    // columns of 72 px covers in rows 168 px apart, 9 rows with the ones
    // kept ready above and below. (At 400 px each: some 190 MB.)
    final small = sized(72, 1);
    expect(23 * 9 * small * (small * 1.5) * 4 / (1 << 20), lessThan(25), reason: 'megabytes');
  });

  test('at the usual cover size the pictures are what they were before covers could be sized, on any screen', () {
    // The usual 160 px and up (a row is filled out), at 1, 2 and 3 pixels
    // a point; a phone's two covers a row are some 490 device pixels.
    for (final px in [160.0, 245.0, 2 * 174.0, 3 * 162.0, 3 * 164.0, 3 * 240.0]) {
      expect(coverPictureSizes(px, zoomed: false), (cover: 400, shuffled: 256), reason: '$px device pixels');
    }
    expect(usualCoverDecodeWidth, 400);
    expect(ShufflePages.width, 256);
    // Sized by hand, the same tiles go by their width.
    expect(coverPictureSizes(160, zoomed: true), (cover: 256, shuffled: 256));
    expect(coverPictureSizes(3 * 162.0, zoomed: true), (cover: 512, shuffled: 512));
  });

  test('shuffled pages of covers sized by hand come in two sizes', () {
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
                return columns;
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

    testWidgets('a finger joining in the same frame as a step does not take the step back', (tester) async {
      final asked = await pumpArea(tester);
      final a = await finger(tester, 100);
      final b = await finger(tester, 200);
      await tester.pump();
      // All of this between two frames, as a touchscreen reporting faster
      // than the screen draws can: a spread over a step (100 to 140), a
      // third finger down, the second moving one more pixel.
      await b.moveBy(const Offset(40, 0));
      final c = await finger(tester, 600);
      await b.moveBy(const Offset(1, 0));
      expect(asked, [5, 5], reason: 'the step, and then the same columns again, not the 6 of before it');
      await tester.pump();
      expect(find.text('5 columns'), findsOneWidget);

      // The same at the limit, where the grid takes fewer steps than asked
      // for: 140 to 1120 apart is nine steps, the grid stops at 1 column.
      await b.moveBy(const Offset(979, 0));
      final d = await finger(tester, 700);
      await b.moveBy(const Offset(1, 0));
      expect(asked.sublist(2), [-4, 1], reason: 'the pinch goes on from the 1 column the grid took');
      await tester.pump();
      expect(find.text('1 columns'), findsOneWidget);
      for (final f in [a, b, c, d]) {
        await f.up();
      }
      await tester.pump();
    });

    testWidgets('a touchpad pinch starting in the same frame as the last one ended starts from its columns', (
      tester,
    ) async {
      final asked = await pumpArea(tester);
      final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pad.panZoomStart(const Offset(300, 300));
      await tester.pump();
      // One pinch a step wide, and a second one begun, with no frame between.
      await pad.panZoomUpdate(const Offset(300, 300), scale: 1.3);
      await pad.panZoomEnd();
      await pad.panZoomStart(const Offset(300, 300));
      await pad.panZoomUpdate(const Offset(300, 300), scale: 1.01);
      expect(asked, [5, 5], reason: 'the second pinch has not moved a step: still 5, not back to 6');
      await pad.panZoomUpdate(const Offset(300, 300), scale: 1.3);
      expect(asked.last, 4);
      await pad.panZoomEnd();
      await tester.pump();
      expect(find.text('4 columns'), findsOneWidget);
    });

    testWidgets('two wheel notches with Ctrl in one frame are two steps', (tester) async {
      final asked = await pumpArea(tester);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(300, 300)));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(asked, [7, 8]);
      await tester.pump();
      expect(find.text('8 columns'), findsOneWidget);
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
