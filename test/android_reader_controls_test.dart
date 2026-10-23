import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/bookmark_list.dart';
import 'package:comicredr/src/reader/layout.dart';
import 'package:comicredr/src/reader/page_grid.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:comicredr/src/reader/status_line.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';
import 'support/waits.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('android_reader_controls');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<ProviderContainer> open(WidgetTester tester, Size size, {bool android = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final path = writeBookOf(tmp, 'Controls.cbz', List.filled(6, grid4Page()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          androidReaderControlsProvider.overrideWithValue(android),
          noSidecars(db),
          classicCvOnly,
        ],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    await whilePumping(tester, () => c.read(readerProvider.notifier).open(path));
    await eventually(tester, () => expect(find.byKey(const Key('page-image')), findsOneWidget), settle: settle);
    return c;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
  }

  Future<void> menuPick(WidgetTester tester, ReaderIntent intent) async {
    await tap(tester, 'menuButton');
    final line = find.byKey(Key('menu-${intent.name}'));
    await tester.ensureVisible(line);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(line);
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    await eventually(tester, () => expect(find.byKey(const Key('actionMenu')), findsNothing), settle: settle);
  }

  List<String> statusButtons(WidgetTester tester) => tester
      .widgetList<IconButton>(find.descendant(of: find.byType(StatusLine), matching: find.byType(IconButton)))
      .map((w) => (w.key! as ValueKey<String>).value)
      .toList();

  for (final size in const [Size(320, 640), Size(360, 740), Size(740, 360), Size(800, 1280), Size(1280, 800)]) {
    testWidgets('Android has only four reader buttons at $size, including balloons before guided view', (tester) async {
      final c = await open(tester, size);
      const expected = ['backButton', 'balloonsButton', 'guidedButton', 'menuButton'];
      expect(statusButtons(tester), expected);
      expect(
        find.descendant(of: find.byKey(const Key('menuButton')), matching: find.byIcon(Icons.menu)),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pagesButton')), findsNothing);
      expect(find.byKey(const Key('bookmarkButton')), findsNothing);
      expect(find.byKey(const Key('spreadButton')), findsNothing);
      expect(find.byKey(const Key('fitButton')), findsNothing);
      for (final key in expected) {
        final rect = tester.getRect(find.byKey(Key(key)));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.bottom, lessThanOrEqualTo(size.height));
      }
      await tap(tester, 'balloonsButton');
      expect(c.read(readerProvider).guided, isTrue);
      expect(c.read(readerProvider).balloons, isTrue);
      expect(statusButtons(tester), expected);
      await tap(tester, 'balloonsButton');
      expect(c.read(readerProvider).guided, isTrue);
      expect(c.read(readerProvider).balloons, isFalse);
      await tap(tester, 'guidedButton');
      expect(c.read(readerProvider).guided, isFalse);
      expect(tester.widget<IconButton>(find.byKey(const Key('balloonsButton'))).isSelected, isFalse);
      expect(statusButtons(tester), expected);
      await tap(tester, 'menuButton');
      for (final intent in [
        ReaderIntent.pageGrid,
        ReaderIntent.bookmark,
        ReaderIntent.bookmarkList,
        ReaderIntent.fitWidth,
        ReaderIntent.fitPage,
        ReaderIntent.toggleSpread,
        ReaderIntent.pickPart,
        ReaderIntent.showDetails,
        ReaderIntent.fullscreen,
        ReaderIntent.showTouchGuide,
        ReaderIntent.showKeymap,
      ]) {
        expect(find.byKey(Key('menu-${intent.name}')), findsOneWidget, reason: intent.name);
      }
      expect(find.byKey(const Key('menu-showTouchZones')), findsNothing);
      await tap(tester, 'menuClose');
      await tap(tester, 'guidedButton');
      await tap(tester, 'backButton');
      expect(c.read(readerProvider).guided, isFalse);
      expect(c.read(readerProvider).book, isNotNull);
      await tap(tester, 'backButton');
      expect(c.read(readerProvider).book, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android menu actions work over the reader, page grid and bookmark list', (tester) async {
    final c = await open(tester, const Size(360, 740));
    ReaderState state() => c.read(readerProvider);
    await menuPick(tester, ReaderIntent.bookmark);
    await eventually(tester, () => expect(state().bookmarksHere, hasLength(1)), settle: settle);
    await tap(tester, 'menuButton');
    expect(find.text('Remove the bookmark here (mm)'), findsOneWidget);
    await tap(tester, 'menuClose');

    await menuPick(tester, ReaderIntent.pageGrid);
    expect(find.byType(PageGrid), findsOneWidget);
    // The hamburger remains usable over the grid and runs the selected
    // action after closing it, without changing the open comic.
    await menuPick(tester, ReaderIntent.bookmarkList);
    expect(find.byType(PageGrid), findsNothing);
    expect(find.byType(BookmarkList), findsOneWidget);
    await menuPick(tester, ReaderIntent.bookmark);
    expect(find.byType(BookmarkList), findsNothing);
    await eventually(tester, () => expect(state().bookmarksHere, isEmpty), settle: settle);
    expect(state().book, isNotNull);

    await menuPick(tester, ReaderIntent.fitWidth);
    expect(c.read(viewFitProvider), Fit.width);
    await menuPick(tester, ReaderIntent.fitPage);
    expect(c.read(viewFitProvider), Fit.page);
    await menuPick(tester, ReaderIntent.toggleSpread);
    expect(state().mode, PageMode.spread);
    await menuPick(tester, ReaderIntent.pickPart);
    expect(find.byKey(const Key('partsPicker')), findsOneWidget);
    await tap(tester, 'backButton');
    expect(find.byKey(const Key('partsPicker')), findsNothing);
    expect(state().book, isNotNull);
    await menuPick(tester, ReaderIntent.showDetails);
    await eventually(tester, () => expect(find.byKey(const Key('detailsClose')), findsOneWidget), settle: settle);
    await tap(tester, 'detailsClose');
    await tester.pump(const Duration(milliseconds: 350));
    await menuPick(tester, ReaderIntent.fullscreen);
    expect(state().fullscreen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await settle(tester);
    expect(state().fullscreen, isFalse);

    // Moving buttons never takes away the separate hardware shortcuts.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP, character: 'p');
    await settle(tester);
    expect(find.byType(PageGrid), findsOneWidget);
    await tap(tester, 'backButton');
    expect(find.byType(PageGrid), findsNothing);
    expect(state().book, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Linux retains its wide status buttons and overflow menu icon', (tester) async {
    final c = await open(tester, const Size(1280, 800), android: false);
    expect(statusButtons(tester), [
      'backButton',
      'guidedButton',
      'spreadButton',
      'fitButton',
      'pagesButton',
      'partsButton',
      'detailsButton',
      'bookmarkButton',
      'bookmarksButton',
      'fullscreenButton',
      'menuButton',
    ]);
    expect(
      find.descendant(of: find.byKey(const Key('menuButton')), matching: find.byIcon(Icons.more_vert)),
      findsOneWidget,
    );
    await tap(tester, 'spreadButton');
    expect(c.read(readerProvider).mode, PageMode.spread);
    await tap(tester, 'guidedButton');
    expect(find.byKey(const Key('balloonsButton')), findsOneWidget);
    expect(find.byKey(const Key('spreadButton')), findsNothing);
    expect(find.byKey(const Key('pagesButton')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
