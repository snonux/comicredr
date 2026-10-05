import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/guided.dart';
import 'package:comicredr/src/reader/layout.dart';
import 'package:comicredr/src/reader/page_painters.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:comicredr/src/reader/region.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Halves, thirds and quarters of a page enlarged by hand (`H1`, `B2`,
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

  /// A split key and a part number: `H1`, `B3`, `Q4`.
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

  testWidgets('in guided view: parts page by page, each page whole first, guided view again on panels', (tester) async {
    final c = await open(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    expect(c.read(readerProvider).guided, isTrue);

    await part(tester, 'H', 1);
    var s = c.read(readerProvider);
    expect((s.region, s.parts), ((split: PageSplit.halves, part: 0, page: 0), PageSplit.halves));
    expectFramed(tester, PageSplit.halves, 0);
    expect(status(tester), contains('Upper half (1 / 2)'));
    expect(find.byKey(const Key('guided-dim')), findsOneWidget, reason: 'the rest of the page dimmed');

    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).region?.part, 1);
    expectFramed(tester, PageSplit.halves, 1);

    // Past the last part: this page whole, then the next page, whole, and
    // still in halves.
    await key(tester, LogicalKeyboardKey.arrowRight);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts), (0, null, PageSplit.halves));
    expect(background(tester), heldColour);
    expect(pageOnScreen(tester).height, closeTo(tester.getRect(find.byType(ReaderView)).height, 1));
    await key(tester, LogicalKeyboardKey.arrowRight);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts, s.held), (1, null, PageSplit.halves, false));
    expect(background(tester), heldColour);
    expect(pageOnScreen(tester).height, closeTo(tester.getRect(find.byType(ReaderView)).height, 1));
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 0, page: 1));
    expectFramed(tester, PageSplit.halves, 0);

    // Back: this page whole, the page before whole, then its last part,
    // then on again.
    await key(tester, LogicalKeyboardKey.arrowLeft);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts), (1, null, PageSplit.halves));
    await key(tester, LogicalKeyboardKey.arrowLeft);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts), (0, null, PageSplit.halves));
    expect(pageOnScreen(tester).height, closeTo(tester.getRect(find.byType(ReaderView)).height, 1));
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 1, page: 0));
    await key(tester, LogicalKeyboardKey.keyL);
    s = c.read(readerProvider);
    expect((s.page, s.region), (0, null));
    await key(tester, LogicalKeyboardKey.keyL);
    s = c.read(readerProvider);
    expect((s.page, s.region), (1, null));
    await key(tester, LogicalKeyboardKey.keyL, times: 2);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 1, page: 1));

    // Page 3 has panels: it shows whole, and guided view goes on over them.
    await key(tester, LogicalKeyboardKey.arrowRight, times: 2);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts, s.guided), (2, null, null, true));
    expect(s.panel, pageStart);
    expect(status(tester), contains('guided view goes on'));
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).panelIndex, 0);

    // The same keys again, or Esc, show the whole page and stay in guided view.
    await key(tester, LogicalKeyboardKey.home);
    await part(tester, 'Q', 2);
    expectFramed(tester, PageSplit.quarters, 1);
    await part(tester, 'Q', 2);
    s = c.read(readerProvider);
    expect((s.region, s.parts), (null, null));
    expect(pageOnScreen(tester).height, closeTo(tester.getRect(find.byType(ReaderView)).height, 1));
    await part(tester, 'Q', 4);
    expectFramed(tester, PageSplit.quarters, 3);
    await key(tester, LogicalKeyboardKey.escape);
    s = c.read(readerProvider);
    expect((s.region, s.parts, s.guided, s.page), (null, null, true, 0));
    expect(status(tester), 'Whole page');

    // The ? help has a section for them.
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await settle(tester);
    await tester.scrollUntilVisible(find.byKey(const Key('keymap-parts')), 200);
    expect(find.byKey(const Key('keymap-parts')), findsOneWidget);
    expect(find.textContaining('11 whole page'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('keymap-regionUpperThird')), 200);
    expect(find.textContaining('Upper third of the page'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);

    // A page with panels: the part wins over the panel while it is shown,
    // and a page without panels after it stays in parts.
    await key(tester, LogicalKeyboardKey.pageDown, times: 2);
    expect(c.read(readerProvider).stopsOn(2), hasLength(4));
    await part(tester, 'B', 2);
    expectFramed(tester, PageSplit.thirds, 1);
    await key(tester, LogicalKeyboardKey.arrowRight, times: 2);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts), (2, null, PageSplit.thirds), reason: 'the panel page whole');
    await key(tester, LogicalKeyboardKey.arrowRight);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts), (3, null, PageSplit.thirds));
    await key(tester, LogicalKeyboardKey.arrowRight, times: 3);
    expect(c.read(readerProvider).region, (split: PageSplit.thirds, part: 2, page: 3));
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).region, isNull);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(status(tester), contains('last part of the last page'));
  });

  testWidgets('outside guided view: thirds page by page, until a jump or a mode switch', (tester) async {
    final c = await open(tester);
    expect(c.read(readerProvider).guided, isFalse);
    await part(tester, 'B', 1);
    expectFramed(tester, PageSplit.thirds, 0);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expectFramed(tester, PageSplit.thirds, 1);
    await key(tester, LogicalKeyboardKey.space);
    expectFramed(tester, PageSplit.thirds, 2);
    await key(tester, LogicalKeyboardKey.keyL);
    var s = c.read(readerProvider);
    expect((s.page, s.region, s.parts), (0, null, PageSplit.thirds));
    expect(pageOnScreen(tester).height, closeTo(tester.getRect(find.byType(ReaderView)).height, 1));
    await key(tester, LogicalKeyboardKey.keyL);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts, s.held), (1, null, PageSplit.thirds, false));
    expect(pageOnScreen(tester).height, closeTo(tester.getRect(find.byType(ReaderView)).height, 1));
    await key(tester, LogicalKeyboardKey.arrowRight);
    expectFramed(tester, PageSplit.thirds, 0);
    // A panel page is read in thirds too outside guided view.
    await key(tester, LogicalKeyboardKey.arrowRight, times: 4);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts), (2, null, PageSplit.thirds));

    // Quarters in reading order: across, then down.
    await part(tester, 'Q', 1);
    for (final p in [1, 2, 3]) {
      await key(tester, LogicalKeyboardKey.arrowRight);
      expectFramed(tester, PageSplit.quarters, p);
    }
    // A page key ends it.
    await key(tester, LogicalKeyboardKey.pageUp);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts), (1, null, null));
    // So does switching into guided view.
    await part(tester, 'H', 2);
    expect(c.read(readerProvider).parts, PageSplit.halves);
    await key(tester, LogicalKeyboardKey.keyV);
    s = c.read(readerProvider);
    expect((s.region, s.parts), (null, null));
    // And the first part of the first page goes back no further.
    await key(tester, LogicalKeyboardKey.home);
    await part(tester, 'H', 1);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(c.read(readerProvider).region, isNull, reason: 'the first page whole');
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(c.read(readerProvider).page, 0);
    expect(status(tester), contains('first part of the first page'));
  });

  testWidgets('two quick digits pick a part, and a count still works', (tester) async {
    final c = await open(tester);
    Future<void> digits(String keys) async {
      for (final d in keys.split('')) {
        await tester.sendKeyEvent(LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(d)), character: d);
      }
    }

    await digits('33');
    expect(c.read(readerProvider).region?.part, 2, reason: 'at once, nothing to wait for');
    await settle(tester);
    var s = c.read(readerProvider);
    expect((s.region, s.parts), ((split: PageSplit.thirds, part: 2, page: 0), PageSplit.thirds));
    expectFramed(tester, PageSplit.thirds, 2);

    await digits('42');
    await settle(tester);
    expect(c.read(readerProvider).region, (split: PageSplit.strips, part: 1, page: 0));
    expectFramed(tester, PageSplit.strips, 1);
    await digits('51');
    await settle(tester);
    expect(c.read(readerProvider).region, (split: PageSplit.quarters, part: 0, page: 0));
    expectFramed(tester, PageSplit.quarters, 0);
    await digits('11');
    await settle(tester);
    s = c.read(readerProvider);
    expect((s.region, s.parts), (null, PageSplit.quarters), reason: '11 shows the whole page, still in quarters');
    await digits('00');
    await settle(tester);
    expect(c.read(readerProvider).region, isNull);
    expect(c.read(readerProvider).parts, isNull, reason: '00 leaves the split');

    // G4 goes to page 4 and leaves the parts; 3h is still a count.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'G');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await digits('4');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    s = c.read(readerProvider);
    expect((s.page, s.region), (3, null));
    await digits('3');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH, character: 'h');
    await settle(tester);
    s = c.read(readerProvider);
    expect((s.page, s.region, s.parts), (0, null, null));
  });

  testWidgets('in two-page mode the parts go on across the other page, then the next spread', (tester) async {
    final c = await open(tester);
    await key(tester, LogicalKeyboardKey.keyD);
    await key(tester, LogicalKeyboardKey.keyL);
    var s = c.read(readerProvider);
    expect(s.mode, PageMode.spread);
    expect(s.unit, [1, 2]);
    await part(tester, 'H', 2);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 1, page: 1));
    expectFramed(tester, PageSplit.halves, 1, 0);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 0, page: 2));
    expectFramed(tester, PageSplit.halves, 0, 1);
    await key(tester, LogicalKeyboardKey.arrowRight, times: 2);
    s = c.read(readerProvider);
    expect(s.unit, [1, 2], reason: 'the spread whole before it turns');
    expect(s.region, isNull);
    await key(tester, LogicalKeyboardKey.arrowRight);
    s = c.read(readerProvider);
    expect(s.unit, [3]);
    expect((s.region, s.parts), (null, PageSplit.halves));
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 0, page: 3));
    expectFramed(tester, PageSplit.halves, 0);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    s = c.read(readerProvider);
    expect(s.unit, [3]);
    expect(s.region, isNull);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    s = c.read(readerProvider);
    expect(s.unit, [1, 2]);
    expect(s.region, isNull);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(c.read(readerProvider).region, (split: PageSplit.halves, part: 1, page: 2));
  });

  /// The dimming hole where it is on screen now, or null when nothing is dimmed.
  Rect? holeOnScreen(WidgetTester tester) {
    final dim = find.byKey(const Key('guided-dim'));
    if (dim.evaluate().isEmpty) return null;
    final hole = (tester.widget<CustomPaint>(dim).painter! as DimPainter).hole;
    final box = tester.getRect(dim);
    return Rect.fromLTRB(
      box.left + hole.left * box.width,
      box.top + hole.top * box.height,
      box.left + hole.right * box.width,
      box.top + hole.bottom * box.height,
    );
  }

  /// Whether some of the page on screen lies outside the hole, dimmed.
  bool dimOnScreen(WidgetTester tester) {
    final hole = holeOnScreen(tester);
    if (hole == null) return false;
    final seen = tester.getRect(find.byType(ReaderView)).intersect(pageOnScreen(tester));
    return !hole.inflate(1).contains(seen.topLeft) || !hole.inflate(1).contains(seen.bottomRight);
  }

  testWidgets('a key pan in a part or on a panel lights what it brings on screen', (tester) async {
    final c = await open(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    await part(tester, 'H', 1);
    expect(dimOnScreen(tester), isTrue, reason: 'the lower half shows dimmed below the part');
    await key(tester, LogicalKeyboardKey.arrowDown, times: 2);
    expect(dimOnScreen(tester), isFalse, reason: 'what Down brought on screen is lit');
    expect(holeOnScreen(tester), isNotNull, reason: 'the page off screen stays dim');
    // The next step frames the next part, dimmed around it again.
    await key(tester, LogicalKeyboardKey.arrowRight);
    expectFramed(tester, PageSplit.halves, 1);
    final hole = holeOnScreen(tester)!;
    final lower = partOnScreen(tester, PageSplit.halves, 1);
    expect((hole.topLeft - lower.topLeft).distance + (hole.bottomRight - lower.bottomRight).distance, lessThan(2));
    expect(dimOnScreen(tester), isTrue);
    await key(tester, LogicalKeyboardKey.keyK);
    expect(dimOnScreen(tester), isFalse, reason: 'k too');

    // Guided view on a panel: j lights what it brings in, the next panel dims again.
    await key(tester, LogicalKeyboardKey.escape);
    await key(tester, LogicalKeyboardKey.pageDown, times: 2);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).panelIndex, 0);
    expect(dimOnScreen(tester), isTrue);
    await key(tester, LogicalKeyboardKey.keyJ, times: 2);
    expect(dimOnScreen(tester), isFalse);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).panelIndex, 1);
    expect(dimOnScreen(tester), isTrue);
  });

  testWidgets('outside guided view a drag in a part lights what it brings on screen', (tester) async {
    await open(tester);
    await part(tester, 'Q', 1);
    expect(dimOnScreen(tester), isTrue);
    final view = tester.getRect(find.byType(ReaderView));
    await tester.dragFrom(view.center, const Offset(-150, -150));
    await settle(tester);
    expect(dimOnScreen(tester), isFalse);
  });
}
