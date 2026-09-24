import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/layout.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:comicredr/src/reader/region.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Halves, thirds and quarters of a page enlarged by hand (`H1`, `T2`,
/// `Q3`...), in guided view on a page without panels and outside it.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('region_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('parts', () {
    test('lie where their names say, in reading order', () {
      expect(partRect(PageSplit.halves, 1), const Rect.fromLTWH(0, 0.5, 1, 0.5));
      expect(partRect(PageSplit.thirds, 1).top, closeTo(1 / 3, 1e-9));
      expect(partRect(PageSplit.quarters, 1), const Rect.fromLTWH(0.5, 0, 0.5, 0.5));
      expect(partRect(PageSplit.quarters, 2), const Rect.fromLTWH(0, 0.5, 0.5, 0.5));
      expect(partOrder(PageSplit.thirds, rightToLeft: false), [0, 1, 2]);
      expect(partOrder(PageSplit.thirds, rightToLeft: true), [0, 1, 2]);
      expect(partOrder(PageSplit.quarters, rightToLeft: false), [0, 1, 2, 3]);
      expect(partOrder(PageSplit.quarters, rightToLeft: true), [1, 0, 3, 2]);
      expect(
        describeRegion((split: PageSplit.quarters, part: 1, page: 0), rightToLeft: true),
        'top-right quarter (1 / 4)',
      );
    });
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [databaseProvider.overrideWithValue(db), noSidecars(db), classicCvOnly],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(k);
    }
    await settle(tester);
  }

  /// A split key and a part number: `H1`, `T3`, `Q4`.
  Future<void> part(WidgetTester tester, String split, int n) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(
      LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + split.codeUnitAt(0) - 65),
      character: split,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + n), character: '$n');
    await settle(tester);
  }

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

  Color? background(WidgetTester tester) => tester.widgetList<Scaffold>(find.byType(Scaffold)).first.backgroundColor;

  /// The shown page [k] (display order) on screen, zoom and all.
  Rect pageOnScreen(WidgetTester tester, [int k = 0]) => tester.getRect(find.byKey(const Key('page-image')).at(k));

  /// Where [part] of page [k] is on screen now.
  Rect partOnScreen(WidgetTester tester, PageSplit split, int part, [int k = 0]) {
    final page = pageOnScreen(tester, k);
    final r = partRect(split, part);
    return Rect.fromLTWH(
      page.left + r.left * page.width,
      page.top + r.top * page.height,
      r.width * page.width,
      r.height * page.height,
    );
  }

  /// [part] of [split] fills the reader: centred, and as large as it goes
  /// with guided view's margin.
  void expectFramed(WidgetTester tester, PageSplit split, int part, [int k = 0]) {
    final view = tester.getRect(find.byType(ReaderView));
    final r = partOnScreen(tester, split, part, k);
    expect((r.center - view.center).distance, lessThan(2), reason: '${split.names[part]} centred');
    final fill = [r.width / view.width, r.height / view.height].reduce((a, b) => a > b ? a : b);
    expect(fill, closeTo(0.92, 0.01), reason: '${split.names[part]} fills the view');
  }

  /// Blank pages the gate refuses, and one with four panels.
  String writeBook() => writeBookOf(tmp, 'Region 01.cbz', [
    gridPage(400, 600, const []),
    gridPage(400, 600, const []),
    grid4Page(),
    gridPage(400, 600, const []),
  ]);

  Future<ProviderContainer> open(WidgetTester tester) async {
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeBook()));
    await settle(tester);
    return c;
  }

  testWidgets('in guided view on a page without panels: halves, then held, then the next page', (tester) async {
    final c = await open(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    expect(c.read(readerProvider).guided, isTrue);

    await part(tester, 'H', 1);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 0, page: 0));
    expectFramed(tester, PageSplit.halves, 0);
    expect(status(tester), contains('Upper half (1 / 2)'));
    expect(find.byKey(const Key('guided-dim')), findsOneWidget, reason: 'the rest of the page dimmed');

    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).region?.part, 1);
    expectFramed(tester, PageSplit.halves, 1);

    // Past the last part: the whole page, held, and the next step turns.
    await key(tester, LogicalKeyboardKey.keyL);
    var s = c.read(readerProvider);
    expect((s.page, s.region), (0, null));
    expect(s.held, isTrue);
    expect(background(tester), heldColour);
    expect(pageOnScreen(tester).height, closeTo(tester.getRect(find.byType(ReaderView)).height, 1));
    await key(tester, LogicalKeyboardKey.keyL);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.guided), (1, null, true));

    // Back through the parts the other way.
    await part(tester, 'T', 3);
    expectFramed(tester, PageSplit.thirds, 2);
    await key(tester, LogicalKeyboardKey.keyH);
    expect(c.read(readerProvider).region?.part, 1);
    expectFramed(tester, PageSplit.thirds, 1);
    await key(tester, LogicalKeyboardKey.keyH, times: 2);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.held), (1, null, true));
    await key(tester, LogicalKeyboardKey.keyH);
    expect(c.read(readerProvider).page, 0);

    // The same keys again, or Esc, show the whole page and stay in guided view.
    await part(tester, 'Q', 2);
    expectFramed(tester, PageSplit.quarters, 1);
    await part(tester, 'Q', 2);
    expect(c.read(readerProvider).region, isNull);
    expect(pageOnScreen(tester).height, closeTo(tester.getRect(find.byType(ReaderView)).height, 1));
    await part(tester, 'Q', 4);
    expectFramed(tester, PageSplit.quarters, 3);
    await key(tester, LogicalKeyboardKey.escape);
    s = c.read(readerProvider);
    expect((s.region, s.guided, s.page), (null, true, 0));
    expect(status(tester), 'Whole page');

    // The ? help has a section for them.
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await settle(tester);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('keymap-regionUpperThird')), 200);
    expect(find.byKey(const Key('keymap-parts')), findsOneWidget);
    expect(find.textContaining('Upper third of the page'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);

    // A page with panels: the part wins over the panel while it is shown.
    await key(tester, LogicalKeyboardKey.pageDown, times: 2);
    expect(c.read(readerProvider).stopsOn(2), hasLength(4));
    await part(tester, 'T', 2);
    expectFramed(tester, PageSplit.thirds, 1);
  });

  testWidgets('outside guided view: thirds step through, then the whole page, then the next page', (tester) async {
    final c = await open(tester);
    expect(c.read(readerProvider).guided, isFalse);
    await part(tester, 'T', 1);
    expectFramed(tester, PageSplit.thirds, 0);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expectFramed(tester, PageSplit.thirds, 1);
    await key(tester, LogicalKeyboardKey.space);
    expectFramed(tester, PageSplit.thirds, 2);
    await key(tester, LogicalKeyboardKey.keyL);
    var s = c.read(readerProvider);
    expect((s.page, s.region, s.held), (0, null, false));
    expect(pageOnScreen(tester).height, closeTo(tester.getRect(find.byType(ReaderView)).height, 1));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).page, 1);

    // Quarters in reading order: across, then down.
    await part(tester, 'Q', 1);
    for (final p in [1, 2, 3]) {
      await key(tester, LogicalKeyboardKey.keyL);
      expectFramed(tester, PageSplit.quarters, p);
    }
    // A page turn ends it.
    await key(tester, LogicalKeyboardKey.pageDown);
    s = c.read(readerProvider);
    expect((s.page, s.region), (2, null));
    // So does switching into guided view.
    await part(tester, 'H', 2);
    expect(c.read(readerProvider).region, isNotNull);
    await key(tester, LogicalKeyboardKey.keyV);
    expect(c.read(readerProvider).region, isNull);
  });

  testWidgets('in two-page mode the parts go on across the other page', (tester) async {
    final c = await open(tester);
    await key(tester, LogicalKeyboardKey.keyD);
    await key(tester, LogicalKeyboardKey.keyL);
    var s = c.read(readerProvider);
    expect(s.mode, PageMode.spread);
    expect(s.unit, [1, 2]);
    await part(tester, 'H', 2);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 1, page: 1));
    expectFramed(tester, PageSplit.halves, 1, 0);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 0, page: 2));
    expectFramed(tester, PageSplit.halves, 0, 1);
    await key(tester, LogicalKeyboardKey.keyL, times: 2);
    s = c.read(readerProvider);
    expect(s.unit, [1, 2]);
    expect(s.region, isNull);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).unit, [3]);
  });
}
