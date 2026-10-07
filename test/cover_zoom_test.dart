import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/grid_zoom.dart';
import 'package:comicredr/src/library/cover_card.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// The library's cover size: `+` `-` `=`, Ctrl and the wheel and a pinch on
/// the tabs of covers, one size for all of them, kept across restarts.
void main() {
  late Directory tmp;
  late Directory root;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cover_zoom_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    db = AppDatabase(NativeDatabase.memory());
    // Enough comics for several screens of covers at any size, each with
    // its own number of pages: the same bytes twice would be one comic.
    for (var i = 1; i <= 36; i++) {
      writeBook(root, 'Book ${'$i'.padLeft(2, '0')}.cbz', i + 1);
    }
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // A key of its own each time, so a second pump is a fresh start.
        key: UniqueKey(),
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue('${tmp.path}/covers'),
          classicCvOnly,
          noSidecars(db),
        ],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {String? character}) async {
    await tester.sendKeyEvent(k, character: character);
    await settle(tester);
  }

  Future<void> plus(WidgetTester tester) => key(tester, LogicalKeyboardKey.equal, character: '+');
  Future<void> minus(WidgetTester tester) => key(tester, LogicalKeyboardKey.minus, character: '-');
  Future<void> equals(WidgetTester tester) => key(tester, LogicalKeyboardKey.equal, character: '=');

  /// The app with the library scanned, inside the library folder on the
  /// Folders tab, its first comic selected.
  Future<ProviderContainer> inFolder(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
    final c = await pumpApp(tester, size);
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(root.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    await tester.tap(
      size.width < 600
          ? find.descendant(of: find.byType(NavigationBar), matching: find.byIcon(Icons.folder))
          : find.text('Folders'),
    );
    await settle(tester);
    // A tap on a folder opens it, and its first comic is selected.
    await tester.tap(find.byType(CoverCard).first);
    await settle(tester);
    expect(find.byKey(const Key('breadcrumb')), findsOneWidget);
    return c;
  }

  double width(WidgetTester tester) => tester.getSize(find.byType(CoverCard).first).width;

  /// How many covers the first row holds.
  int columns(WidgetTester tester) {
    final tops = [for (final e in find.byType(CoverCard).evaluate()) tester.getTopLeft(find.byWidget(e.widget)).dy];
    return tops.where((t) => t == tops.first).length;
  }

  Future<String?> saved(WidgetTester tester) =>
      tester.runAsync<String?>(() => SettingsStore(db).loadString(SettingsStore.coverSize));

  testWidgets('+ and - size the covers a column at a time, between a smallest and a biggest; = puts it back', (
    tester,
  ) async {
    await inFolder(tester);
    final start = width(tester);
    final cols = columns(tester);
    expect(cols, greaterThan(3));
    expect(await saved(tester), isNull, reason: 'nothing is saved before a zoom');

    await plus(tester);
    expect(columns(tester), cols - 1);
    expect(width(tester), greaterThan(start));
    expect(double.parse((await saved(tester))!), closeTo(width(tester), 0.1), reason: 'the cover width is kept');
    await minus(tester);
    expect(columns(tester), cols);
    expect(width(tester), start);

    // Bigger until it stops: no cover wider than 480, and then nothing changes.
    for (var i = 0; i < 20; i++) {
      await plus(tester);
    }
    final biggest = width(tester);
    final fewest = columns(tester);
    expect(biggest, lessThanOrEqualTo(480));
    expect(biggest, greaterThan(start * 1.5));
    final atBiggest = await saved(tester);
    await plus(tester);
    expect((width(tester), columns(tester), await saved(tester)), (biggest, fewest, atBiggest));

    // Smaller until it stops: no cover narrower than 72.
    for (var i = 0; i < 30; i++) {
      await minus(tester);
    }
    final smallest = width(tester);
    final most = columns(tester);
    expect(smallest, greaterThanOrEqualTo(72));
    expect(smallest, lessThan(72 * 1.2), reason: 'one more column would not fit');
    expect(most, greaterThan(cols));
    final atSmallest = await saved(tester);
    await minus(tester);
    expect((width(tester), columns(tester), await saved(tester)), (smallest, most, atSmallest));

    // A count takes that many steps.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3, character: '3');
    await plus(tester);
    expect(columns(tester), most - 3);

    await equals(tester);
    expect((width(tester), columns(tester)), (start, cols));
    expect(await saved(tester), isNull, reason: 'the default is no setting');
  });

  testWidgets('the selected cover stays in view, and so does the top row with none selected', (tester) async {
    await inFolder(tester);
    final grid = tester.getRect(find.byKey(const Key('grid')));
    Finder cover(String id) => find.byWidgetPredicate((w) => w is CoverCard && w.item.id == id);
    bool shown(String id) {
      if (cover(id).evaluate().isEmpty) return false;
      final r = tester.getRect(cover(id));
      return r.top >= grid.top - 1 && r.bottom <= grid.bottom + 1;
    }

    // The last comic, selected, a few screens down.
    await key(tester, LogicalKeyboardKey.end);
    final last = tester.widget<CoverCard>(find.byWidgetPredicate((w) => w is CoverCard && w.selected)).item.id;
    expect(tester.getRect(cover(last)).top, greaterThan(grid.center.dy), reason: 'scrolled to the last row');
    expect(shown(last), isTrue);
    for (var i = 0; i < 3; i++) {
      await plus(tester);
      expect(shown(last), isTrue, reason: 'after + number ${i + 1}');
    }
    for (var i = 0; i < 12; i++) {
      await minus(tester);
    }
    expect(shown(last), isTrue, reason: 'at the smallest');
    await equals(tester);
    expect(shown(last), isTrue, reason: 'back at the usual size');

    // Nothing selected (a search clears the selection), scrolled down: the
    // cover that was first on screen is still on screen after a zoom.
    await tester.tap(find.byKey(const Key('search')));
    await tester.enterText(find.byKey(const Key('search')), 'Book');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byWidgetPredicate((w) => w is CoverCard && w.selected), findsNothing);
    await tester.drag(find.byKey(const Key('grid')), const Offset(0, -900), kind: PointerDeviceKind.touch);
    await settle(tester);
    final first = tester
        .widgetList<CoverCard>(find.byType(CoverCard))
        .firstWhere((c) => tester.getRect(find.byWidget(c)).bottom > grid.top + 1)
        .item
        .id;
    expect(tester.getRect(cover(first)).top, lessThan(grid.top + 40), reason: 'it is in the row along the top');
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: find.byKey(const Key('grid')), matching: find.byType(Scrollable)),
    );
    expect(scroll.position.pixels, greaterThan(300), reason: 'scrolled away from the top');
    await plus(tester);
    await plus(tester);
    final r = tester.getRect(cover(first));
    expect(r.bottom > grid.top && r.top < grid.bottom, isTrue, reason: 'still on screen after two +');
    for (var i = 0; i < 6; i++) {
      await minus(tester);
    }
    final small = tester.getRect(cover(first));
    expect(small.bottom > grid.top && small.top < grid.bottom, isTrue, reason: 'and after six -');
  });

  testWidgets('covers too tall for a low window show from their top', (tester) async {
    await inFolder(tester, size: const Size(1280, 560));
    final grid = tester.getRect(find.byKey(const Key('grid')));
    final selected = find.byWidgetPredicate((w) => w is CoverCard && w.selected);
    await key(tester, LogicalKeyboardKey.end);
    for (var i = 0; i < 6; i++) {
      await plus(tester);
    }
    final r = tester.getRect(selected);
    expect(r.height, greaterThan(grid.height), reason: 'a cover is taller than the room for covers');
    expect(r.top, closeTo(grid.top + 12, 1), reason: 'the selected cover starts at the top');
    // Moving on keeps to that.
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(tester.getRect(selected).top, closeTo(grid.top + 12, 1));
  });

  testWidgets('typing + or - in the search box is typing, not zoom', (tester) async {
    await inFolder(tester);
    final start = width(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const Key('search'))).focusNode!.hasFocus, isTrue);
    await plus(tester);
    await minus(tester);
    await minus(tester);
    expect(width(tester), start);
    expect(await saved(tester), isNull);
    // Out of the box the same key zooms.
    await key(tester, LogicalKeyboardKey.escape);
    await plus(tester);
    expect(width(tester), greaterThan(start));
  });

  testWidgets('one size for every tab of covers, none for the bookmark list; a restart keeps it', (tester) async {
    await inFolder(tester);
    // The Books tab at the usual size, to compare with. (It has no cover
    // selected and so no details beside it: more room than the folder.)
    await tester.tap(find.text('Books'));
    await settle(tester);
    final booksStart = columns(tester);
    await tester.tap(find.text('Folders'));
    await settle(tester);
    final start = columns(tester);
    await plus(tester);
    await plus(tester);
    expect(columns(tester), start - 2);
    final size = await saved(tester);

    // The Books tab took the size, and - there changes the Folders tab too.
    await tester.tap(find.text('Books'));
    await settle(tester);
    expect(columns(tester), lessThan(booksStart));
    expect(width(tester), greaterThanOrEqualTo(double.parse(size!) - 0.1), reason: 'covers of the kept width');
    await minus(tester);
    final middle = width(tester);
    final kept = await saved(tester);
    expect(kept, isNot(size));
    expect(double.parse(kept!), closeTo(middle, 0.1));
    await tester.tap(find.text('Folders'));
    await settle(tester);
    expect(columns(tester), start - 1);

    // The Bookmarks tab is a list: the keys do nothing there.
    await tester.tap(find.text('Bookmarks'));
    await settle(tester);
    await plus(tester);
    await minus(tester);
    await minus(tester);
    await equals(tester);
    expect(await saved(tester), kept);

    // A fresh start on the same index comes back at that size.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await pumpApp(tester, const Size(1280, 800));
    await settle(tester);
    await tester.tap(find.text('Books'));
    await settle(tester);
    expect(width(tester), middle);
  });

  testWidgets('Ctrl and the wheel zoom; the wheel alone scrolls', (tester) async {
    await inFolder(tester);
    final grid = tester.getRect(find.byKey(const Key('grid')));
    final start = width(tester);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(grid.center));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
    await settle(tester);
    final big = width(tester);
    expect(big, greaterThan(start), reason: 'wheel up: bigger');
    // A frame between the two: each step counts from the columns on screen.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    final small = width(tester);
    expect(small, lessThan(start), reason: 'wheel down twice: smaller than at first');

    final scroll = tester.state<ScrollableState>(
      find.descendant(of: find.byKey(const Key('grid')), matching: find.byType(Scrollable)),
    );
    expect(scroll.position.pixels, 0, reason: 'the grid did not scroll while Ctrl was held');
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await settle(tester);
    expect(width(tester), small, reason: 'the wheel alone does not zoom');
    expect(scroll.position.pixels, greaterThan(0), reason: 'it scrolls');
  });

  testWidgets('a pinch sizes the covers on a phone; one finger still scrolls, taps and long-presses', (tester) async {
    final c = await inFolder(tester, size: const Size(400, 800));
    final grid = tester.getRect(find.byKey(const Key('grid')));
    final start = width(tester);
    expect(columns(tester), 2);

    // Two fingers spread apart: bigger. The covers under them open nothing.
    var a = await tester.startGesture(grid.center - const Offset(40, 0), kind: PointerDeviceKind.touch);
    var b = await tester.startGesture(grid.center + const Offset(40, 0), kind: PointerDeviceKind.touch);
    await a.moveBy(const Offset(-30, 0));
    await b.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(columns(tester), 1);
    await a.up();
    await b.up();
    await settle(tester);
    expect(columns(tester), 1);
    expect(width(tester), greaterThan(start * 1.5));
    expect(double.parse((await saved(tester))!), closeTo(width(tester), 0.1));
    expect(c.read(readerProvider).book, isNull, reason: 'a pinch opens no comic');
    expect(find.byKey(const Key('detail')), findsNothing, reason: 'nor its details');

    // Pinched together: smaller, down to the most columns the phone takes.
    a = await tester.startGesture(grid.center - const Offset(150, 0), kind: PointerDeviceKind.touch);
    b = await tester.startGesture(grid.center + const Offset(150, 0), kind: PointerDeviceKind.touch);
    await a.moveBy(const Offset(125, 0));
    await b.moveBy(const Offset(-125, 0));
    await a.up();
    await b.up();
    await settle(tester);
    final most = columns(tester);
    expect(most, greaterThan(2));
    expect(width(tester), greaterThanOrEqualTo(72));
    final small = width(tester);

    // One finger rests on a cover while the other pinches, for longer than
    // a long press takes: no details open, and no comic when they lift.
    a = await tester.startGesture(grid.topLeft + const Offset(40, 60), kind: PointerDeviceKind.touch);
    b = await tester.startGesture(grid.topLeft + const Offset(140, 60), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 700));
    await b.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await a.up();
    await b.up();
    await settle(tester);
    expect(width(tester), greaterThan(small), reason: 'the pinch zoomed');
    expect(find.byKey(const Key('detail')), findsNothing, reason: 'the resting finger is no long press');
    expect(c.read(readerProvider).book, isNull, reason: 'and no tap');

    // One finger scrolls as before, and does not zoom.
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: find.byKey(const Key('grid')), matching: find.byType(Scrollable)),
    );
    final before = width(tester);
    await tester.drag(find.byKey(const Key('grid')), const Offset(0, -300), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect(scroll.position.pixels, greaterThan(100));
    expect(width(tester), before);

    // A long press still opens a cover's details, and a tap them too on a phone.
    Offset onScreen() => tester
        .widgetList<CoverCard>(find.byType(CoverCard))
        .map((c) => tester.getRect(find.byWidget(c)))
        .firstWhere((r) => r.top > grid.top && r.bottom < grid.bottom)
        .center;
    await tester.longPressAt(onScreen(), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect(find.byKey(const Key('detail')), findsOneWidget, reason: 'a long press after a pinch works');
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('detail')), findsNothing);
    await tester.tapAt(onScreen(), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect(find.byKey(const Key('detail')), findsOneWidget, reason: 'a tap after a pinch works');
  });

  test('zoom steps: columns from a width and back, within the limits', () {
    const zoom = GridZoom(gap: 12, smallest: 72, largest: 480);
    expect(zoom.most(336), 4);
    expect(zoom.fewest(336), 1);
    expect(zoom.fewest(1176), 3, reason: 'two a row would be wider than 480');
    expect(zoom.tileWidth(1176, zoom.fewest(1176)), lessThanOrEqualTo(480));
    for (final inner in [296.0, 336.0, 795.0, 1176.0]) {
      for (var n = zoom.fewest(inner); n <= zoom.most(inner); n++) {
        expect(zoom.columns(inner, zoom.tileWidth(inner, n)), n, reason: '$n columns in $inner');
        // Saved to a tenth of a pixel, as the setting is.
        final kept = double.parse(zoom.tileWidth(inner, n).toStringAsFixed(1));
        expect(zoom.columns(inner, kept), n, reason: '$n columns in $inner from the saved width');
      }
    }
    expect(zoom.columns(336, 10), zoom.most(336));
    expect(zoom.columns(336, 5000), 1);
    expect(const GridZoom(gap: 8, smallest: 56).fewest(2000), 1, reason: 'no biggest: one a row');
    expect(GridZoom.pinchSteps(1.3), 1);
    expect(GridZoom.pinchSteps(1.2), 0);
    expect(GridZoom.pinchSteps(0.6), -2);
  });
}
