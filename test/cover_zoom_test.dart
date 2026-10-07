import 'dart:async';
import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart' hide Override;
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/grid_zoom.dart';
import 'package:comicredr/src/library/cover_card.dart';
import 'package:comicredr/src/library/library_screen.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/shuffle.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
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

  /// The app in a window of [size] logical pixels, [ratio] device pixels
  /// each.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    Size size, {
    double ratio = 1,
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = size * ratio;
    tester.view.devicePixelRatio = ratio;
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
          ...overrides,
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
  Future<ProviderContainer> inFolder(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    double ratio = 1,
    List<Override> overrides = const [],
  }) async {
    final c = await pumpApp(tester, size, ratio: ratio, overrides: overrides);
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

  /// The pictures of the covers on screen, by the comic they are of, as
  /// the image cache keys them: the same file at the same decode width is
  /// the same decoded picture.
  Map<String, ResizeImage> coverPictures(WidgetTester tester) => {
    for (final card in find.byType(CoverCard).evaluate())
      for (final image in find.descendant(of: find.byWidget(card.widget), matching: find.byType(Image)).evaluate())
        if ((image.widget as Image).key == null)
          (card.widget as CoverCard).item.id: (image.widget as Image).image as ResizeImage,
  };
  Set<int?> widthsOf(Iterable<ResizeImage> pictures) => {for (final p in pictures) p.width};

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

  /// Whether the covers are sized by hand: what Settings' Usual size
  /// button goes by.
  bool sized(WidgetTester tester) => tester.state<LibraryScreenState>(find.byType(LibraryScreen)).coversZoomed;

  testWidgets('steps with no frame between them count from each other: two wheel notches, a notch and a pinch', (
    tester,
  ) async {
    // What the cover grid itself answers a step with. Everything below
    // comes between two frames, as input faster than the screen does.
    await inFolder(tester, size: const Size(2000, 1000));
    final grid = tester.getRect(find.byKey(const Key('grid')));
    final cols = columns(tester);
    expect(cols, greaterThan(7), reason: 'room for four steps either way');
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(grid.center));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
    await settle(tester);
    expect(columns(tester), cols - 2, reason: 'two notches, two steps');
    expect(SettingsStore.parseSize(await saved(tester)), closeTo(width(tester), 0.001));

    // A notch back, then two fingers down and spread from 80 to 140 px
    // apart, which is two steps: one column more, then two fewer. Counted
    // from the columns on screen, it would end a column short of that.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    final a = await tester.startGesture(grid.center - const Offset(40, 0), kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(grid.center + const Offset(40, 0), kind: PointerDeviceKind.touch);
    await a.moveBy(const Offset(-30, 0));
    await b.moveBy(const Offset(30, 0));
    await a.up();
    await b.up();
    await settle(tester);
    expect(columns(tester), cols - 3);
    expect(SettingsStore.parseSize(await saved(tester)), closeTo(width(tester), 0.001));
    expect(sized(tester), isTrue);
  });

  testWidgets('a key during a pinch keeps its step, and a window resized under the fingers keeps its columns', (
    tester,
  ) async {
    await inFolder(tester, size: const Size(2000, 1000));
    final grid = tester.getRect(find.byKey(const Key('grid')));
    final cols = columns(tester);
    final a = await tester.startGesture(grid.center - const Offset(50, 0), kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(grid.center + const Offset(50, 0), kind: PointerDeviceKind.touch);
    await tester.pump();

    // `+` with both fingers down, and one of them moving a pixel before
    // the next frame and another after it.
    await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
    await b.moveBy(const Offset(1, 0));
    await settle(tester);
    expect(columns(tester), cols - 1, reason: "the key's step stays");
    await b.moveBy(const Offset(1, 0));
    await settle(tester);
    expect(columns(tester), cols - 1, reason: 'also a frame later');
    expect(SettingsStore.parseSize(await saved(tester)), closeTo(width(tester), 0.001));

    // The pinch goes on from there: 102 px apart to 132 is one step.
    await a.moveBy(const Offset(-15, 0));
    await b.moveBy(const Offset(15, 0));
    await settle(tester);
    expect(columns(tester), cols - 2);
    final kept = await saved(tester);

    // The window made narrower with the fingers still down: fewer covers
    // of the same size fit, and a finger moving a pixel changes nothing.
    tester.view.physicalSize = const Size(1500, 1000);
    await settle(tester);
    final narrow = columns(tester);
    expect(narrow, lessThan(cols - 2));
    final wide = width(tester);
    await b.moveBy(const Offset(1, 0));
    await settle(tester);
    expect((columns(tester), width(tester)), (narrow, wide), reason: 'the resize is not taken for a pinch');
    expect(await saved(tester), kept, reason: 'and the size kept is the one the pinch asked for');
    await a.up();
    await b.up();
    await settle(tester);
    expect(columns(tester), narrow);
  });

  testWidgets('+ and then - is the usual size again: nothing kept, the pictures of before, nothing to put back', (
    tester,
  ) async {
    // On a dense phone, where it shows most: two covers a row some 490
    // device pixels wide decode at 400 at the usual size and would at 512
    // sized by hand, and in shuffle a 512 px page would be made for each.
    final pages = _HandMadePages('${tmp.path}/covers/pages');
    await inFolder(
      tester,
      size: const Size(360, 800),
      ratio: 3,
      overrides: [shufflePagesProvider.overrideWithValue(pages)],
    );
    await key(tester, LogicalKeyboardKey.keyS, character: 'S');
    final usual = (columns(tester), width(tester));
    expect(usual.$1, 2);
    expect((sized(tester), await saved(tester)), (false, null));
    expect(pages.sizesAsked, {256});

    await plus(tester);
    expect(columns(tester), 1);
    expect(sized(tester), isTrue);
    expect(pages.sizesAsked, {512});
    await minus(tester);
    expect((columns(tester), width(tester)), usual);
    expect((sized(tester), await saved(tester)), (false, null), reason: 'as before the +');
    expect(pages.sizesAsked, {256}, reason: 'the 512 px pages asked for are let go');
    await pages.makeAll(tester);
    expect(_shuffledWidths(tester), {256});
    expect(pages.made.where((f) => f.contains('/w512/')), isEmpty, reason: 'no 512 px page was made');
    await key(tester, LogicalKeyboardKey.keyS, character: 'S');
    expect(widthsOf(coverPictures(tester).values), {400});

    // The other way round, and by a pinch: smaller, then spread back.
    await minus(tester);
    expect((columns(tester), sized(tester)), (3, true));
    expect(widthsOf(coverPictures(tester).values), {400}, reason: 'a third of the phone is 320 device pixels');
    final grid = tester.getRect(find.byKey(const Key('grid')));
    final a = await tester.startGesture(grid.center - const Offset(40, 0), kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(grid.center + const Offset(40, 0), kind: PointerDeviceKind.touch);
    await b.moveBy(const Offset(25, 0));
    await a.up();
    await b.up();
    await settle(tester);
    expect((columns(tester), width(tester)), usual);
    expect((sized(tester), await saved(tester)), (false, null));
    expect(widthsOf(coverPictures(tester).values), {400});
  });

  testWidgets('a kept size of the usual 160 px is the usual size; one that only gives its columns here is not', (
    tester,
  ) async {
    await inFolder(tester);
    await tester.tap(find.text('Books'));
    await settle(tester);
    final usual = (columns(tester), width(tester));
    expect(width(tester), inExclusiveRange(165, 256), reason: 'a row filled out: wider than the 160 aimed for');
    expect(widthsOf(coverPictures(tester).values), {400});

    Future<void> restartWith(String kept) async {
      await tester.runAsync(() => SettingsStore(db).saveString(SettingsStore.coverSize, kept));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await pumpApp(tester, const Size(1280, 800));
      await settle(tester);
      await tester.tap(find.text('Books'));
      await settle(tester);
    }

    // 160 from a settings file written by hand (the app keeps the usual
    // size as no setting): the usual size, pictures and all. The setting
    // is left as it is until a step changes it.
    for (final kept in ['160', '160.0']) {
      await restartWith(kept);
      expect((columns(tester), width(tester)), usual, reason: 'kept "$kept"');
      expect((sized(tester), await saved(tester)), (false, kept));
      expect(widthsOf(coverPictures(tester).values), {400}, reason: 'kept "$kept"');
      await plus(tester);
      expect(sized(tester), isTrue);
      await minus(tester);
      expect((columns(tester), sized(tester), await saved(tester)), (usual.$1, false, null), reason: 'kept "$kept"');
    }

    // Any other width is a size set by hand, also when it shows as many
    // covers a row as the usual size does in this window: it is kept, the
    // pictures go by the covers' width, and Usual size has something to do.
    await restartWith('165');
    expect((columns(tester), width(tester)), usual);
    expect((sized(tester), await saved(tester)), (true, '165'));
    expect(widthsOf(coverPictures(tester).values), {256});
    await equals(tester);
    expect((columns(tester), sized(tester), await saved(tester)), (usual.$1, false, null));
    expect(widthsOf(coverPictures(tester).values), {400});
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

  testWidgets('a finger resting on a cover while another pinches opens nothing when it lifts', (tester) async {
    final c = await inFolder(tester, size: const Size(400, 800));
    final grid = tester.getRect(find.byKey(const Key('grid')));
    expect(columns(tester), 2);
    // The first finger on the first cover, still, and up again well inside
    // the half second a long press takes: on its own that is a tap, which
    // on a phone opens the cover's details. The second, on the cover
    // beside it, spreads away from it.
    final rest = await tester.startGesture(grid.topLeft + const Offset(100, 120), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 40));
    final move = await tester.startGesture(grid.topLeft + const Offset(250, 120), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 40));
    await move.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 40));
    expect(columns(tester), 1, reason: 'the pinch zoomed');
    await rest.up();
    await tester.pump(const Duration(milliseconds: 40));
    await move.up();
    await settle(tester);
    expect(columns(tester), 1);
    expect(find.byKey(const Key('detail')), findsNothing, reason: 'the resting finger was no tap');
    expect(c.read(readerProvider).book, isNull, reason: 'and opened no comic');

    // The same finger alone, as long: a tap, and the details open.
    final alone = await tester.startGesture(grid.topLeft + const Offset(100, 120), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 120));
    await alone.up();
    await settle(tester);
    expect(find.byKey(const Key('detail')), findsOneWidget, reason: 'alone it is a tap');
  });

  testWidgets('+ - = do nothing while the covers are not on screen: a phone with the details page up', (tester) async {
    await inFolder(tester, size: const Size(400, 800));
    expect(columns(tester), 2);
    await tester.tap(find.byType(CoverCard).first);
    await settle(tester);
    expect(find.byKey(const Key('detail')), findsOneWidget);
    expect(find.byKey(const Key('grid')), findsNothing, reason: 'the details page took the covers place');
    await plus(tester);
    await minus(tester);
    await minus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3, character: '3');
    await plus(tester);
    expect(await saved(tester), isNull, reason: 'nothing to size, nothing kept');
    expect(find.byKey(const Key('detail')), findsOneWidget);

    // Back at the covers: as they were, and now the keys size them.
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('grid')), findsOneWidget);
    expect(columns(tester), 2);
    await plus(tester);
    expect(columns(tester), 1);
    expect(await saved(tester), isNotNull);
    // Kept, with the details up again, = does not forget it either.
    await tester.tap(find.byType(CoverCard).first);
    await settle(tester);
    expect(find.byKey(const Key('detail')), findsOneWidget);
    final kept = await saved(tester);
    await equals(tester);
    expect(await saved(tester), kept);
  });

  testWidgets('a kept size that is no size is left alone at start-up: the covers show at the usual size', (
    tester,
  ) async {
    await inFolder(tester);
    await tester.tap(find.text('Books'));
    await settle(tester);
    final usual = (columns(tester), width(tester));
    expect(usual.$1, greaterThan(3));

    Future<void> restartWith(String kept) async {
      await tester.runAsync(() => SettingsStore(db).saveString(SettingsStore.coverSize, kept));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await pumpApp(tester, const Size(1280, 800));
      await settle(tester);
      await tester.tap(find.text('Books'));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'kept "$kept"');
      expect(find.byType(CoverCard), findsWidgets, reason: 'kept "$kept": the grid is built');
    }

    for (final bad in ['NaN', '-12', '0', 'Infinity', '-Infinity', '1e999', 'big', '']) {
      await restartWith(bad);
      expect((columns(tester), width(tester)), usual, reason: 'kept "$bad"');
      // And the keys work from there.
      await plus(tester);
      expect(columns(tester), usual.$1 - 1, reason: '+ after "$bad"');
      expect(SettingsStore.parseSize(await saved(tester)), closeTo(width(tester), 0.001));
    }
    // Numbers beyond the limits are the limits.
    await restartWith('1e300');
    expect(width(tester), inInclusiveRange(usual.$2 * 1.5, 480), reason: 'huge: the biggest covers');
    final fewest = columns(tester);
    await plus(tester);
    expect(columns(tester), fewest);
    await restartWith('0.001');
    expect(width(tester), inInclusiveRange(72, 72 * 1.2), reason: 'tiny: the smallest covers');
  });

  testWidgets('covers decode 400 px wide at the usual size, by their width once sized, and a step often reuses them', (
    tester,
  ) async {
    await inFolder(tester, size: const Size(2000, 1000));
    await tester.tap(find.text('Books'));
    await settle(tester);
    expect(coverPictures(tester), isNotEmpty, reason: 'the scan made covers');
    expect(width(tester), lessThan(256));
    expect(widthsOf(coverPictures(tester).values), {400}, reason: 'the usual size: as before covers could be sized');
    final usual = columns(tester);

    // Every size from the biggest to the smallest: the decode width is the
    // tile's bucket (400 on the way through the usual size, which a step
    // to its columns is), and a step that stays in the bucket shows the
    // very pictures the image cache holds.
    int decoded() => columns(tester) == usual ? usualCoverDecodeWidth : coverDecodeWidth(width(tester));
    for (var i = 0; i < 8; i++) {
      await plus(tester);
    }
    final buckets = <int>{};
    var reused = 0;
    for (var last = 0; columns(tester) != last;) {
      last = columns(tester);
      final bucket = decoded();
      final before = coverPictures(tester);
      expect(widthsOf(before.values), {bucket}, reason: '$last a row, ${width(tester)} px');
      buckets.add(bucket);
      await minus(tester);
      if (columns(tester) == last || decoded() != bucket) continue;
      final after = coverPictures(tester);
      for (final id in before.keys.where(after.containsKey)) {
        expect(after[id], before[id], reason: '$id, from $last a row to ${columns(tester)}');
        reused++;
      }
    }
    expect(buckets, {128, 256, 400, 512}, reason: 'small covers decode small');
    expect(reused, greaterThan(20), reason: 'steps within a bucket were looked at');

    // The usual size again: 400 whatever the width.
    await equals(tester);
    expect(widthsOf(coverPictures(tester).values), {400});
  });

  testWidgets('a dense phone at the usual size: covers 400 px and shuffled pages 256 px, as before; more once sized', (
    tester,
  ) async {
    final pages = _HandMadePages('${tmp.path}/covers/pages');
    await inFolder(
      tester,
      size: const Size(360, 800),
      ratio: 3,
      overrides: [shufflePagesProvider.overrideWithValue(pages)],
    );
    expect(columns(tester), 2);
    expect(width(tester) * 3, greaterThan(480), reason: 'a tile is some 490 device pixels wide');
    expect(widthsOf(coverPictures(tester).values), {400});
    await key(tester, LogicalKeyboardKey.keyS, character: 'S');
    expect(pages.sizesAsked, {256}, reason: 'no 512 px page is made for whoever never sizes the covers');
    await pages.makeAll(tester);
    expect(_shuffledWidths(tester), {256});

    // One cover a row: 1008 device pixels, so all the files have.
    await plus(tester);
    expect(columns(tester), 1);
    expect(pages.sizesAsked, {512});
    await pages.makeAll(tester);
    expect(_shuffledWidths(tester), {512});
    await key(tester, LogicalKeyboardKey.keyS, character: 'S');
    expect(widthsOf(coverPictures(tester).values), {512});
  });

  testWidgets('shuffled pages: 256 px at the usual size, 512 px files for big covers, small tiles decode small', (
    tester,
  ) async {
    // The pages are made by hand here (the files written when the test
    // says so), so nothing waits on a worker: test/shuffle_pages_test.dart
    // has the real making. A wide window, on the Books tab: room for a
    // step between the biggest covers and ones still over 333 pixels wide.
    final pages = _HandMadePages('${tmp.path}/covers/pages');
    await inFolder(tester, size: const Size(2000, 1000), overrides: [shufflePagesProvider.overrideWithValue(pages)]);
    await tester.tap(find.text('Books'));
    await settle(tester);

    await key(tester, LogicalKeyboardKey.keyS, character: 'S');
    expect(pages.sizesAsked, {256}, reason: 'covers of the usual size need no more');
    expect(_shuffledWidths(tester), isEmpty, reason: 'the covers show until the pages are made');
    await pages.makeAll(tester);
    expect(_shuffledWidths(tester), {256});

    // As big as they go: over 400 pixels wide, so the 512 px pages. The
    // 256 px ones stay up until those are made.
    for (var i = 0; i < 8; i++) {
      await plus(tester);
    }
    expect(width(tester), greaterThan(400));
    expect(pages.sizesAsked, {512});
    expect(_shuffledWidths(tester), {256});
    await pages.makeAll(tester);
    expect(_shuffledWidths(tester), {512});
    expect(pages.made.where((f) => f.contains('/w512/')), isNotEmpty, reason: "beside the page grid's 512 px files");

    // A step smaller, between 334 and 400: still the 512 px file, decoded
    // 400 wide as the covers are.
    await minus(tester);
    expect(width(tester), inExclusiveRange(333, 400));
    await pages.makeAll(tester);
    expect(_shuffledWidths(tester), {400});
    expect(pages.sizesAsked, isEmpty);

    // The smallest: the 256 px file again, already made for the pages that
    // showed at first, decoded 128 wide.
    for (var i = 0; i < 30; i++) {
      await minus(tester);
    }
    expect(width(tester), lessThan(128));
    expect(pages.sizesAsked.difference({256}), isEmpty);
    await pages.makeAll(tester);
    expect(_shuffledWidths(tester), {128});
  });

  /// Whether the button with [k] can be pressed.
  bool pressable(WidgetTester tester, Key k) => switch (tester.widget(find.byKey(k))) {
    IconButton(:final onPressed) => onPressed != null,
    ButtonStyleButton(:final enabled) => enabled,
    final other => throw StateError('$other is no button'),
  };

  String line(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('setting-coverSize'))).data!;
  String helpText(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('setting-coverSize-help'))).data!;

  /// Whether the keyboard focus is on the widget with [k], or inside it.
  bool focusIn(Key k) {
    var found = false;
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
      found = e.widget.key == k;
      return !found;
    });
    return found;
  }

  testWidgets("Settings' Cover size buttons size the covers behind it, by tap and by key, within the same limits", (
    tester,
  ) async {
    await inFolder(tester, size: const Size(400, 800));
    expect(columns(tester), 2);
    const bigger = Key('setting-coverSize-bigger'), smaller = Key('setting-coverSize-smaller');
    const usual = Key('setting-coverSize-usual');
    bool enabled(Key k) => pressable(tester, k);
    String line() => tester.widget<Text>(find.byKey(const Key('setting-coverSize'))).data!;
    Future<void> press(Key k) async {
      await tester.ensureVisible(find.byKey(k));
      await tester.pump();
      await tester.tap(find.byKey(k));
      await settle(tester);
    }

    await tester.tap(find.byKey(const Key('settings')));
    await settle(tester);
    await tester.ensureVisible(find.byKey(bigger));
    await tester.pump();
    expect(line(), 'Cover size: 2 a row');
    expect((enabled(bigger), enabled(smaller), enabled(usual)), (true, true, false));

    await press(bigger);
    expect(line(), 'Cover size: 1 a row');
    expect(columns(tester), 1, reason: 'the covers behind the window changed at once');
    expect(SettingsStore.parseSize(await saved(tester)), closeTo(width(tester), 0.001), reason: 'the same setting');
    expect((enabled(bigger), enabled(smaller), enabled(usual)), (false, true, true), reason: 'at the biggest');

    // Smaller until it stops, at the smallest the keys stop at too.
    var presses = 0;
    while (enabled(smaller) && presses < 12) {
      await press(smaller);
      presses++;
    }
    final most = columns(tester);
    expect(presses, most - 1);
    expect(most, greaterThan(2));
    expect(line(), 'Cover size: $most a row');
    expect(width(tester), inInclusiveRange(72, 72 * 1.2));
    expect((enabled(bigger), enabled(smaller)), (true, false));

    await press(usual);
    expect(line(), 'Cover size: 2 a row');
    expect(columns(tester), 2);
    expect(await saved(tester), isNull, reason: 'the usual size is no setting');
    expect(enabled(usual), isFalse);

    // By keyboard: Tab to the button, Enter presses it.
    for (var i = 0; i < 60 && !focusIn(bigger); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focusIn(bigger), isTrue, reason: 'Tab reaches the button');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(line(), 'Cover size: 1 a row');
    expect(columns(tester), 1);

    // Closed, the covers are as the dialog left them, and - goes on from there.
    await tester.tap(find.byKey(const Key('setting-close')));
    await settle(tester);
    expect(columns(tester), 1);
    await minus(tester);
    expect(columns(tester), 2);
  });

  testWidgets("Settings' Cover size buttons are off where there are no covers to size", (tester) async {
    await inFolder(tester);
    // The rail's, not the heading in the selected comic's details.
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Bookmarks')));
    await settle(tester);
    expect(find.byKey(const Key('grid')), findsNothing);
    await tester.tap(find.byKey(const Key('settings')));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('setting-coverSize')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('setting-coverSize'))).data, 'Cover size');
    for (final k in ['bigger', 'smaller', 'usual']) {
      expect(pressable(tester, Key('setting-coverSize-$k')), isFalse, reason: k);
    }
    expect(helpText(tester), contains('No covers show behind Settings now'));
    expect(await saved(tester), isNull);
  });

  testWidgets('with nothing found by a search, Settings does not send you to a tab with covers', (tester) async {
    await inFolder(tester);
    await tester.tap(find.byKey(const Key('search')));
    await tester.enterText(find.byKey(const Key('search')), 'no such comic');
    await settle(tester);
    expect(find.byKey(const Key('grid')), findsNothing);
    await tester.tap(find.byKey(const Key('settings')));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('setting-coverSize')));
    await tester.pump();
    expect(line(tester), 'Cover size');
    expect(helpText(tester), contains('a search that found nothing'));
    expect(helpText(tester), isNot(contains('Open Settings')), reason: 'this is a tab of covers');
    expect(pressable(tester, const Key('setting-coverSize-bigger')), isFalse);
  });

  testWidgets("Settings' Cover size line follows the window and the first comics while it is open", (tester) async {
    // An empty library: nothing to size.
    final c = await pumpApp(tester, const Size(1280, 800));
    await settle(tester);
    await tester.tap(find.byKey(const Key('settingsEmpty')));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('setting-coverSize')));
    await tester.pump();
    expect(line(tester), 'Cover size');
    expect(pressable(tester, const Key('setting-coverSize-bigger')), isFalse);

    // The first comics come in behind the dialog.
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(root.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    expect(find.byType(CoverCard), findsWidgets);
    // The covers a row, from how wide a cover is in the grid (the Series
    // tab here has one cover only, so there is no row to count).
    int perRow() {
      final inner = tester.getSize(find.byKey(const Key('grid'))).width - 24;
      return ((inner + GridZoom.coversGap) / (width(tester) + GridZoom.coversGap)).round();
    }

    final wide = perRow();
    expect(wide, greaterThan(4));
    expect(line(tester), 'Cover size: $wide a row');
    expect(pressable(tester, const Key('setting-coverSize-bigger')), isTrue);
    expect(helpText(tester), contains('One size for every tab of covers'));

    // The window made narrower: fewer covers a row, and the line says so.
    tester.view.physicalSize = const Size(700, 800);
    await settle(tester);
    final narrow = perRow();
    expect(narrow, inExclusiveRange(1, wide));
    expect(line(tester), 'Cover size: $narrow a row');

    // A step by the button there, and on to the smallest covers this
    // window takes, where the smaller button goes off.
    await tester.tap(find.byKey(const Key('setting-coverSize-bigger')));
    await settle(tester);
    expect(perRow(), narrow - 1);
    expect(line(tester), 'Cover size: ${narrow - 1} a row');
    for (var i = 0; i < 20 && pressable(tester, const Key('setting-coverSize-smaller')); i++) {
      await tester.tap(find.byKey(const Key('setting-coverSize-smaller')));
      await settle(tester);
    }
    final most = perRow();
    expect(most, greaterThan(narrow));
    expect(pressable(tester, const Key('setting-coverSize-smaller')), isFalse);

    // The window wide again: covers of the kept width, more of them a
    // row, and room for a smaller size still. The line and the button
    // follow with no press.
    tester.view.physicalSize = const Size(1280, 800);
    await settle(tester);
    expect(perRow(), greaterThan(most));
    expect(line(tester), 'Cover size: ${perRow()} a row');
    expect(pressable(tester, const Key('setting-coverSize-smaller')), isTrue, reason: 'a column more fits here');
  });

  for (final (size, scale) in [
    (const Size(320, 640), 1.0),
    (const Size(360, 800), 1.0),
    (const Size(400, 800), 1.0),
    (const Size(320, 640), 1.5),
    (const Size(360, 800), 1.5),
  ]) {
    testWidgets("Settings' Cover size fits a ${size.width.round()} px wide phone at ${scale}x letters", (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      // On the Series tab, where a phone starts: one series of all the
      // comics, a cover.
      final c = await pumpApp(tester, size);
      await tester.runAsync(() async {
        await c.read(libraryStoreProvider).addRoot(root.path);
        await c.read(scannerProvider).scan();
      });
      await settle(tester);
      expect(find.byType(CoverCard), findsWidgets);
      await tester.tap(find.byKey(const Key('settings')));
      await settle(tester);
      const label = Key('setting-coverSize');
      await tester.ensureVisible(find.byKey(const Key('setting-coverSize-help')));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      final words = line(tester);
      expect(words, startsWith('Cover size: '));
      expect(words, endsWith(' a row'));

      // The line has the whole width of the section, as the text under it
      // has, and breaks only when its words need more than that. (The
      // test font's letters are squares as wide as the font size, about
      // twice a real font's: a phone shows the line on one.)
      final paragraph = tester.renderObject<RenderParagraph>(find.byKey(label));
      final room = tester.getSize(find.byKey(const Key('setting-coverSize-help'))).width;
      expect(room, greaterThanOrEqualTo(190));
      expect(paragraph.constraints.maxWidth, room);
      final letter = paragraph.text.style!.fontSize! * scale;
      final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: words.length));
      // One more than the letters need at most, for breaking between words.
      final needed = (words.length * letter / room).ceil();
      expect({for (final b in boxes) b.top}.length, inInclusiveRange(needed, needed + 1), reason: 'lines of text');
      expect(paragraph.didExceedMaxLines, isFalse);
      final dialog = tester.getRect(find.byType(AlertDialog));
      // The three buttons are all there to press, inside the dialog, none
      // over another.
      final buttons = [
        for (final k in ['smaller', 'bigger', 'usual']) tester.getRect(find.byKey(Key('setting-coverSize-$k'))),
      ];
      for (final (i, b) in buttons.indexed) {
        expect(b.left >= dialog.left && b.right <= dialog.right, isTrue, reason: 'button $i at $b in $dialog');
        expect(b.width, greaterThanOrEqualTo(40));
        for (final other in buttons.skip(i + 1)) {
          expect(b.overlaps(other), isFalse, reason: '$b and $other');
        }
      }
      expect(
        tester.getRect(find.byKey(label)).bottom,
        lessThanOrEqualTo(buttons.first.top + 0.5),
        reason: 'above them',
      );
      // And they work at this size.
      await tester.ensureVisible(find.byKey(const Key('setting-coverSize-bigger')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('setting-coverSize-bigger')));
      await settle(tester);
      expect(line(tester), isNot(words));
      expect(tester.takeException(), isNull);
    });
  }

  test('zoom steps: columns from a width and back, within the limits', () {
    const zoom = GridZoom(gap: 12, smallest: 72, largest: 480);
    expect(zoom.most(336), 4);
    expect(zoom.fewest(336), 1);
    expect(zoom.fewest(1176), 3, reason: 'two a row would be wider than 480');
    expect(zoom.tileWidth(1176, zoom.fewest(1176)), lessThanOrEqualTo(480));
    for (final inner in [296.0, 336.0, 795.0, 1176.0]) {
      for (var n = zoom.fewest(inner); n <= zoom.most(inner); n++) {
        expect(zoom.columns(inner, zoom.tileWidth(inner, n)), n, reason: '$n columns in $inner');
        // As the setting keeps it (test/grid_zoom_test.dart sweeps every width).
        final kept = SettingsStore.parseSize(SettingsStore.sizeText(zoom.tileWidth(inner, n)))!;
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

/// The decode widths of the shuffled pages on screen.
Set<int?> _shuffledWidths(WidgetTester tester) => {
  for (final w in tester.widgetList<Image>(
    find.byWidgetPredicate(
      (w) => w is Image && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('shuffled-'),
    ),
  ))
    (w.image as ResizeImage).width,
};

/// Shuffle's pages made when the test says so instead of by a worker in
/// its own time: a page asked for waits until [makeAll] writes its file.
/// The paths and what counts as made are the real [ShufflePages]'.
class _HandMadePages extends ShufflePages {
  _HandMadePages(String dir) : super(dir: dir);

  final _asked = <(String, int, int), Completer<String?>>{};

  /// Every file made so far.
  final made = <String>[];

  /// The sizes of the pages asked for and not made yet.
  Set<int> get sizesAsked => {for (final (_, _, size) in _asked.keys) size};

  @override
  Future<String?> get(LibraryBook book, int index, {int size = ShufflePages.width}) {
    final path = pathOf(book.key, index, size);
    if (File(path).existsSync()) return Future.value(path);
    return (_asked[(book.key, index, size)] ??= Completer()).future;
  }

  @override
  void cancel(String bookKey, int index, {int size = ShufflePages.width}) =>
      _asked.remove((bookKey, index, size))?.complete(null);

  /// Writes the file of every page asked for and answers the tiles, which
  /// show it a frame later.
  Future<void> makeAll(WidgetTester tester) async {
    for (final MapEntry(key: (book, index, size), value: asked) in _asked.entries.toList()) {
      final path = pathOf(book, index, size);
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png);
      made.add(path);
      asked.complete(path);
    }
    _asked.clear();
    await tester.pump();
    await tester.pump();
  }
}
