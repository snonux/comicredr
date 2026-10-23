import 'dart:io';

import 'package:comicredr/src/action_menu.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/input/touch_providers.dart';
import 'package:comicredr/src/library/library_items.dart';
import 'package:comicredr/src/library/library_screen.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/layout.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/touch_guide.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';
import 'support/waits.dart';

/// Every action without a keyboard (snonux, 2026-10-11): the menu (⋮, F10,
/// a swipe up on the page), and the touch tutorial (gT, Settings, the
/// first start on Android).
void main() {
  /// Every intent the reader's menu offers, in any state it can be in.
  Set<ReaderIntent> readerMenuIntents() {
    final bookmark = BookmarkInfo(id: 'b', page: 1, createdAt: DateTime(2026));
    final states = [
      const ReaderState(),
      const ReaderState(guided: true),
      const ReaderState(mode: PageMode.spread, rotation: 1),
      ReaderState(bookmarks: [bookmark], jumpedFrom: (page: 0, panel: 0)),
    ];
    return {
      for (final s in states)
        for (final s3 in [false, true])
          for (final g in readerMenu(s, s3: s3))
            for (final e in g.entries) e.intent,
    };
  }

  /// The library's menu offers these on the Folders tab with shuffle on and
  /// comics marked, S3 on (the widget test below holds it to that).
  const libraryMenu = {
    ReaderIntent.continueReading,
    ReaderIntent.openFile,
    ReaderIntent.openFolder,
    ReaderIntent.addRoot,
    ReaderIntent.rescan,
    ReaderIntent.showScanFailures,
    ReaderIntent.showFavourites,
    ReaderIntent.clearReading,
    ReaderIntent.filterFolders,
    ReaderIntent.filterCompleted,
    ReaderIntent.sortFolders,
    ReaderIntent.nextSortOrder,
    ReaderIntent.reverseSort,
    ReaderIntent.toggleShuffle,
    ReaderIntent.reshuffle,
    ReaderIntent.zoomIn,
    ReaderIntent.zoomOut,
    ReaderIntent.zoomReset,
    ReaderIntent.markAll,
  };

  /// Buttons on the screens, by the widget key they have.
  const buttons = {
    ReaderIntent.toggleGuided: 'guidedButton on the status line',
    ReaderIntent.toggleBalloons: 'balloonsButton on the status line in guided view',
    ReaderIntent.pageGrid: 'pagesButton on the status line',
    ReaderIntent.bookmark: 'bookmarkButton on the status line',
    ReaderIntent.bookmarkList: 'bookmarksButton on the status line; the Bookmarks tab in the library',
    ReaderIntent.openMenu: 'menuButton on the status line and in the library header',
    ReaderIntent.back: "Android's back gesture; backButton on Linux; the library's back and up buttons",
    ReaderIntent.search: "the library header's search field",
    ReaderIntent.markBook: 'Select in a phone-wide header, Mark in the details pane or page',
    ReaderIntent.editBook: "the pencil in a comic's details; Note on a bookmark",
    ReaderIntent.moveBooks: 'Move in the details and the marks bar',
    ReaderIntent.removeRoot: "Take out of the library in a library folder's details",
    ReaderIntent.downloadFromS3: 'Download on the page of a comic only on S3',
    ReaderIntent.remove: 'Remove on a bookmark row; the x of a collection chip',
    ReaderIntent.undo: "the notice's Undo button",
    ReaderIntent.activate: 'a tap on a cover or a row',
    ReaderIntent.up: 'the breadcrumb and the up arrow on the Folders tab',
  };

  /// Gestures of the standard preset, and what has no gesture by nature.
  const gestures = {
    ReaderIntent.nextStep: 'tap the right edge, swipe left',
    ReaderIntent.prevStep: 'tap the left edge, swipe right',
    ReaderIntent.zoomToggle: 'custom [touch] binding; pinch zoom works in every layout',
    ReaderIntent.showTime: 'hold the middle',
    ReaderIntent.pickPart: 'two-finger tap',
    ReaderIntent.toggleFitWidth: 'swipe down; the Fit width button',
    ReaderIntent.nextPage: 'swipe outside guided view; the page grid',
    ReaderIntent.prevPage: 'swipe outside guided view; the page grid',
    ReaderIntent.panDown: 'one finger moves a zoomed page',
    ReaderIntent.panUp: 'one finger moves a zoomed page',
    ReaderIntent.scrollLeft: 'one finger moves a zoomed page',
    ReaderIntent.scrollRight: 'one finger moves a zoomed page',
    ReaderIntent.halfPageDown: 'a finger scrolls the page grid',
    ReaderIntent.halfPageUp: 'a finger scrolls the page grid',
    ReaderIntent.cycleModeForward: 'the guided view and two-page buttons; the library tabs',
    ReaderIntent.cycleModeBack: 'the guided view and two-page buttons; the library tabs',
    ReaderIntent.scrollFaster: 'Settings → Pages (scroll speed)',
    ReaderIntent.scrollSlower: 'Settings → Pages (scroll speed)',
    ReaderIntent.scrollSmoother: 'Settings → Pages (smoothness)',
    ReaderIntent.scrollCrisper: 'Settings → Pages (smoothness)',
    ReaderIntent.regionWhole: 'Whole page on the parts picker',
    ReaderIntent.regionPrevious: 'Stop parts on the parts picker',
    ReaderIntent.regionUpperHalf: 'the parts picker',
    ReaderIntent.regionLowerHalf: 'the parts picker',
    ReaderIntent.regionUpperThird: 'the parts picker',
    ReaderIntent.regionMiddleThird: 'the parts picker',
    ReaderIntent.regionLowerThird: 'the parts picker',
    ReaderIntent.regionStrip1: 'the parts picker',
    ReaderIntent.regionStrip2: 'the parts picker',
    ReaderIntent.regionStrip3: 'the parts picker',
    ReaderIntent.regionStrip4: 'the parts picker',
    ReaderIntent.regionTopLeft: 'the parts picker',
    ReaderIntent.regionTopRight: 'the parts picker',
    ReaderIntent.regionBottomLeft: 'the parts picker',
    ReaderIntent.regionBottomRight: 'the parts picker',
    ReaderIntent.markLeft: 'Select, then taps on the covers',
    ReaderIntent.markRight: 'Select, then taps on the covers',
    ReaderIntent.markUp: 'Select, then taps on the covers',
    ReaderIntent.markDown: 'Select, then taps on the covers',
    ReaderIntent.markToFirst: 'Select, then taps on the covers',
    ReaderIntent.markToLast: 'Select, then taps on the covers',
    ReaderIntent.setMark: "vi's marks; by touch a bookmark is the mark",
    ReaderIntent.jumpMark: "vi's marks; by touch the bookmark list jumps",
    ReaderIntent.toggleContinuous: 'not built',
    ReaderIntent.searchNext: 'not built',
    ReaderIntent.searchPrev: 'not built',
  };

  test('every action has a way without a keyboard', () {
    final reached = {...readerMenuIntents(), ...libraryMenu, ...buttons.keys, ...gestures.keys};
    final missing = ReaderIntent.values.where((i) => !reached.contains(i)).map((i) => i.name).toList();
    expect(missing, isEmpty, reason: 'give these a menu line, a button or a gesture: $missing');
    // The keys that only spelled a touch way out above are really gestures.
    final standard = TouchMap.preset(TouchPreset.standard);
    expect(standard.action(TouchGesture.swipeUp), ReaderIntent.openMenu);
    expect(standard.action(TouchGesture.swipeDown), ReaderIntent.toggleFitWidth);
    expect(standard.action(TouchGesture.twoFingerTap), ReaderIntent.pickPart);
    expect(standard.action(TouchGesture.longPress, TouchZone.middle), ReaderIntent.showTime);
    expect(standard.action(TouchGesture.doubleTap, TouchZone.middle), ReaderIntent.fullscreen);
  });

  test('the reader menu has what the keys alone reached before', () {
    final menu = readerMenuIntents();
    for (final i in [
      ReaderIntent.toggleFavourite,
      ReaderIntent.toggleCompleted,
      ReaderIntent.toggleStarted,
      ReaderIntent.addToCollection,
      ReaderIntent.nextBook,
      ReaderIntent.prevBook,
      ReaderIntent.firstPage,
      ReaderIntent.lastPage,
      ReaderIntent.nextBookmark,
      ReaderIntent.prevBookmark,
      ReaderIntent.jumpBack,
      ReaderIntent.toggleDirection,
      ReaderIntent.rotateClockwise,
      ReaderIntent.rotateCounterClockwise,
      ReaderIntent.rotateReset,
      ReaderIntent.toggleSpread,
      ReaderIntent.shiftSpread,
      ReaderIntent.fitHeight,
      ReaderIntent.toggleWholePage,
      ReaderIntent.togglePauseWhole,
      ReaderIntent.autoTrim,
      ReaderIntent.nightFilter,
      ReaderIntent.cleanUp,
      ReaderIntent.resetBook,
      ReaderIntent.deleteBook,
      ReaderIntent.uploadToS3,
      ReaderIntent.removeFromS3,
      ReaderIntent.showDetails,
      ReaderIntent.showTouchZones,
      ReaderIntent.showTouchGuide,
      ReaderIntent.showKeymap,
      ReaderIntent.showSettings,
    ]) {
      expect(menu, contains(i), reason: i.name);
    }
    // S3 only when it is set up; the spread's pairing only in two-page mode.
    final plain = {for (final g in readerMenu(const ReaderState(), s3: false)) ...g.entries.map((e) => e.intent)};
    expect(plain, isNot(contains(ReaderIntent.uploadToS3)));
    expect(plain, isNot(contains(ReaderIntent.shiftSpread)));
    expect(plain, isNot(contains(ReaderIntent.toggleBalloons)));
  });

  test('the tutorial is written from the touch map', () {
    String all(List<GuideStep> steps) => steps.map((s) => '${s.title}: ${s.text}').join('\n');
    final standard = all(guideSteps(TouchMap.preset(TouchPreset.standard), android: true));
    expect(standard, contains('Tap the left edge: back.'));
    expect(standard, contains('Tap the right edge: next.'));
    expect(standard, contains('Tap the middle: status line.'));
    expect(standard, contains('Swipe up: menu.'));
    expect(standard, contains('Swipe down: fit width.'));
    expect(standard, contains('Swipe down on the page fits it to the width'));
    expect(standard, contains('Double-tap anywhere to turn fullscreen on or off.'));
    expect(standard, isNot(contains('Double-tap the middle to zoom in')));
    final customZoom = TouchMap.preset(TouchPreset.standard)
        .withOverrides({TouchGesture.doubleTap: List.filled(9, ReaderIntent.zoomToggle)});
    expect(all(guideSteps(customZoom, android: true)), contains('Double-tap anywhere to zoom in'));
    expect(standard, contains('Hold a finger on the middle: time.'));
    expect(standard, contains('Tap with two fingers to pick a half'));
    expect(standard, contains("Android's back gesture"));
    final left = all(guideSteps(TouchMap.preset(TouchPreset.leftHanded), android: false));
    expect(left, contains('Tap the left edge: next.'));
    expect(left, contains('The arrow at the start of the status line'));
    // keys.toml took the swipe up and the two-finger tap away.
    final bare = TouchMap.preset(TouchPreset.standard).withOverrides({
      TouchGesture.swipeUp: [null],
      TouchGesture.twoFingerTap: [null],
      TouchGesture.swipeDown: [null],
    });
    final steps = guideSteps(bare, android: true);
    expect(steps.map((s) => s.title), isNot(contains('Two fingers')));
    expect(all(steps), isNot(contains('fits it to the width')));
    expect(all(steps), contains('Tap ⋮ for the menu.'));
    expect(zonesOf(bare, TouchGesture.tap, ReaderIntent.openMenu), isNull);
  });

  group('screen', () {
    late Directory tmp;
    late Directory root;
    late String covers;
    late AppDatabase db;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('touch_menu_test');
      root = Directory('${tmp.path}/Comics')..createSync();
      covers = '${tmp.path}/covers';
      db = AppDatabase(NativeDatabase.memory());
      await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<LibraryStore> shelf() async {
      writeBook(root, 'Swamp Thing 21.cbz', 3);
      writeBook(root, 'Daredevil 181.cbz', 4);
      final store = LibraryStore(db);
      await store.addRoot(root.path);
      await LibraryScanner(store, coverDir: covers, workers: 1).scan();
      return store;
    }

    Future<ProviderContainer> pumpApp(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            coverDirProvider.overrideWithValue(covers),
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

    Future<void> pick(WidgetTester tester, ReaderIntent intent) async {
      final line = find.byKey(Key('menu-${intent.name}'));
      await tester.scrollUntilVisible(line, 80, scrollable: find.byType(Scrollable).last);
      await tester.ensureVisible(line);
      await tester.pump();
      await tester.tap(line);
      await settle(tester);
    }

    testWidgets('on a phone: ⋮ and a swipe up open the menu, its lines do what their keys do', (tester) async {
      final store = (await tester.runAsync(shelf))!;
      final books = (await tester.runAsync(store.books))!;
      final c = await pumpApp(tester, const Size(360, 740));
      await settle(tester);
      final daredevil = books.firstWhere((b) => b.name == 'Daredevil #181');
      await tester.runAsync(() => c.read(readerProvider.notifier).open(daredevil.path));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'the status line fits 360 dp');
      // The menu took the fullscreen button's place: a tap in the middle does that.
      expect(find.byKey(const Key('fullscreenButton')), findsNothing);
      expect(find.byKey(const Key('bookmarkButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('menuButton')));
      await settle(tester);
      expect(find.byKey(const Key('actionMenu')), findsOneWidget);
      final turn = find.byKey(const Key('menu-rotateClockwise'));
      await tester.scrollUntilVisible(turn, 80, scrollable: find.byType(Scrollable).last);
      expect(find.descendant(of: turn, matching: find.text('Turn clockwise (>)')), findsOneWidget);
      await pick(tester, ReaderIntent.rotateClockwise);
      expect(find.byKey(const Key('actionMenu')), findsNothing);
      expect(c.read(readerProvider).rotation, 1);

      // A swipe up on the page opens it too; favourite from there.
      await tester.fling(find.byKey(const Key('page-image')), const Offset(0, -300), 1500);
      await settle(tester);
      expect(find.byKey(const Key('actionMenu')), findsOneWidget);
      await pick(tester, ReaderIntent.toggleFavourite);
      expect(await tester.runAsync(() => store.isFavourite(daredevil.key)), isTrue);

      // Close leaves it with nothing done; the comic is still open.
      await tester.tap(find.byKey(const Key('menuButton')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('menuClose')));
      await settle(tester);
      expect(find.byKey(const Key('actionMenu')), findsNothing);
      expect(c.read(readerProvider).book, isNotNull);

      // F10 opens it, Esc leaves it.
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await settle(tester);
      expect(find.byKey(const Key('actionMenu')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byKey(const Key('actionMenu')), findsNothing);

      // Back to the library from the menu.
      await tester.tap(find.byKey(const Key('menuButton')));
      await settle(tester);
      await pick(tester, ReaderIntent.back);
      expect(c.read(readerProvider).book, isNull);
    });

    testWidgets('a never-opened comic marked started has details with no saved page', (tester) async {
      final store = (await tester.runAsync(shelf))!;
      final book = (await tester.runAsync(store.books))!.first;
      await tester.runAsync(() => store.setStarted(book.key, true));
      await pumpApp(tester, const Size(360, 740));
      await settle(tester);
      await tester.tap(find.byKey(ValueKey(BookItem(book).id)));
      await settle(tester);
      expect(find.text('Started · ${book.pageCount} pages'), findsOneWidget);
      await whilePumping(tester, () => store.setCompleted(book.key, true));
      await settle(tester);
      expect(find.text('Completed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('started marks on a phone: reader menu, library key and menu, Undo, and the details button', (
      tester,
    ) async {
      final store = (await tester.runAsync(shelf))!;
      final book = (await tester.runAsync(store.books))!.first;
      final c = await pumpApp(tester, const Size(360, 740));
      await settle(tester);
      final reader = c.read(readerProvider.notifier);
      await whilePumping(tester, () => reader.open(book.path));
      await settle(tester);
      await tester.tap(find.byKey(const Key('menuButton')));
      await settle(tester);
      await pick(tester, ReaderIntent.toggleStarted);
      await eventuallyAsync(tester, () => store.startedMarkOf(book.key), (on) => expect(on, isTrue), settle: settle);
      await tester.tap(find.byKey(const Key('menuButton')));
      await settle(tester);
      await pick(tester, ReaderIntent.toggleStarted);
      await eventuallyAsync(tester, () => store.startedMarkOf(book.key), (on) => expect(on, isFalse), settle: settle);
      await whilePumping(tester, reader.close);
      await settle(tester);
      // Select a cover on Books, then gb adds it to Reading without opening.
      await tester.tap(find.byType(NavigationDestination).at(LibraryTab.books.index));
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await settle(tester);
      // Use the reader's key through the app's real keyboard dispatch, on a cover.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'g');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b');
      await eventuallyAsync(
        tester,
        store.books,
        (books) => expect(books.where((b) => b.started), hasLength(1)),
        settle: settle,
      );
      // The library menu uses the same selected book and removes it again.
      await tester.tap(find.byKey(const Key('menuButton')));
      await settle(tester);
      await pick(tester, ReaderIntent.toggleStarted);
      await eventuallyAsync(
        tester,
        store.books,
        (books) => expect(books.where((b) => b.started), isEmpty),
        settle: settle,
      );
      await eventually(
        tester,
        () => expect(find.text('${book.name} marked as not started'), findsOneWidget),
        settle: settle,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU, character: 'u');
      await eventuallyAsync(
        tester,
        store.books,
        (books) => expect(books.where((b) => b.started), hasLength(1)),
        settle: settle,
      );
      // The selected cover's details page also offers a touch button.
      await tester.tap(find.byKey(ValueKey(BookItem(book).id)));
      await settle(tester);
      final button = find.byKey(const Key('started'));
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await eventuallyAsync(
        tester,
        store.books,
        (books) => expect(books.where((b) => b.started), isEmpty),
        settle: settle,
      );
      // Select both covers by touch, then start them together and undo.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(find.byKey(const Key('select')));
      await settle(tester);
      for (final b in (await whilePumping(tester, store.books))) {
        await tester.tap(find.byKey(ValueKey(BookItem(b).id)));
        await settle(tester);
      }
      await tester.tap(find.byKey(const Key('marksStarted')));
      await eventuallyAsync(
        tester,
        store.books,
        (books) => expect(books.where((b) => b.started), hasLength(2)),
        settle: settle,
      );
      await eventually(tester, () => expect(find.text('2 comics marked as started'), findsOneWidget), settle: settle);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU, character: 'u');
      await eventuallyAsync(
        tester,
        store.books,
        (books) => expect(books.where((b) => b.started), isEmpty),
        settle: settle,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the library menu: what the header has no room for, and the Folders tab', (tester) async {
      await tester.runAsync(shelf);
      await pumpApp(tester, const Size(1280, 800));
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Folders')));
      await settle(tester);
      final library = tester.state<LibraryScreenState>(find.byType(LibraryScreen));
      library.setShuffle(true);
      await settle(tester);
      final offered = {
        for (final g in library.menuGroups())
          for (final e in g.entries) e.intent,
      };
      // Continue only once a comic was read; marking all only where comics
      // are shown, and the top of the Folders tab shows the library folder.
      expect(libraryMenu.difference(offered), {ReaderIntent.continueReading, ReaderIntent.markAll});
      await tester.tap(find.text('Comics'));
      await settle(tester);
      expect(library.menuGroups().expand((g) => g.entries).map((e) => e.intent), contains(ReaderIntent.markAll));
      expect(offered, containsAll([ReaderIntent.reshuffle, ReaderIntent.showTouchGuide, ReaderIntent.showSettings]));

      await tester.tap(find.byKey(const Key('menuButton')));
      await settle(tester);
      await pick(tester, ReaderIntent.sortFolders);
      expect(find.byKey(const Key('sortDialog')), findsOneWidget);
    });

    testWidgets('the tutorial: gT and Settings open it, Next goes through, Done closes', (tester) async {
      await tester.runAsync(shelf);
      final c = await pumpApp(tester, const Size(1280, 800));
      await settle(tester);
      final store = c.read(settingsStoreProvider);
      expect(await tester.runAsync(() => store.loadBool(SettingsStore.touchGuideSeen)), isNull);
      // Not on Linux at the first start: only Android shows it unasked.
      expect(find.byKey(const Key('touchGuide')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'g');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT, character: 'T');
      await settle(tester);
      expect(find.byKey(const Key('touchGuide')), findsOneWidget);
      final steps = guideSteps(c.read(touchMapProvider), android: false).length;
      expect(find.text('1 / $steps'), findsOneWidget);
      for (var i = 1; i < steps; i++) {
        await tester.tap(find.byKey(const Key('touchGuideNext')));
        await settle(tester);
      }
      expect(find.text('$steps / $steps'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      await tester.tap(find.byKey(const Key('touchGuideNext')));
      await settle(tester);
      expect(find.byKey(const Key('touchGuide')), findsNothing);
      expect(await tester.runAsync(() => store.loadBool(SettingsStore.touchGuideSeen)), isTrue);

      // From Settings → Touch, over the settings.
      await tester.tap(find.byKey(const Key('settings')));
      await settle(tester);
      final button = find.byKey(const Key('setting-touchGuide'));
      await tester.scrollUntilVisible(button, 100, scrollable: find.byType(Scrollable).last);
      await tester.tap(button);
      await settle(tester);
      expect(find.byKey(const Key('touchGuide')), findsOneWidget);
      // A swipe turns its pages too.
      await tester.fling(find.byKey(const Key('touchGuidePages')), const Offset(-300, 0), 1500);
      await settle(tester);
      expect(find.text('2 / $steps'), findsOneWidget);
      await tester.tap(find.byKey(const Key('touchGuideClose')));
      await settle(tester);
      expect(find.byKey(const Key('touchGuide')), findsNothing);
      expect(find.byKey(const Key('setting-touchGuide')), findsOneWidget, reason: 'Settings stay under it');
    });
  });
}
