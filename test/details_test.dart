import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/comic_report.dart';
import 'package:comicredr/src/reader/panel_detector.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// The details view (`I`): file, pages, metadata, reading and detection.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('details_test');
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
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
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> typeI(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI, character: 'I');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
  }

  String textOf(WidgetTester tester, Key key) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(key), matching: find.byType(Text)))
      .map((t) => t.data)
      .join(' ');

  testWidgets('I shows the pages and what detection found; a page row jumps there', (tester) async {
    final path = writeBookOf(tmp, 'Details 01.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    await tester.runAsync(() async {
      final key = await contentKey(path);
      // Page 1 was read by the trained model on another device, balloons and
      // all; page 2 by classic CV, which found one panel only.
      final store = PanelStore(db);
      await store.save(
        key,
        0,
        const DetectedPage(
          [
            Panel(0.05, 0.03, 0.42, 0.45, confidence: 0.9),
            Panel(0.52, 0.03, 0.42, 0.45, confidence: 0.8),
            Panel(0.05, 0.52, 0.42, 0.45, confidence: 0.9),
            Panel(0.52, 0.52, 0.42, 0.45, confidence: 0.8),
          ],
          [Panel(0.1, 0.1, 0.1, 0.05, kind: PanelKind.balloon, confidence: 0.7)],
          source: PanelSource.model,
          version: modelDetectorVersion,
          millis: 120,
        ),
      );
      await store.save(
        key,
        1,
        const DetectedPage([Panel(0.05, 0.05, 0.9, 0.2)], [], source: PanelSource.classicCv, version: 1, millis: 40),
      );
    });
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);

    await typeI(tester);
    expect(find.byKey(const Key('comicDetails')), findsOneWidget);
    await settle(tester);
    expect(find.text('CBZ (ZIP archive)'), findsOneWidget);
    expect(find.text('400 × 600 on every page'), findsOneWidget);
    expect(textOf(tester, const Key('detailsFound')), contains('1 balloon'));
    expect(textOf(tester, const Key('detailsGuided')), matches(RegExp(r'[12] pages? steps? panel by panel')));
    expect(textOf(tester, const Key('detailsAnalysed')), matches(RegExp(r'[23] of 3 pages')));

    // Keys scroll the details; they never reach the reader under them.
    for (final k in [LogicalKeyboardKey.keyJ, LogicalKeyboardKey.pageDown, LogicalKeyboardKey.space]) {
      await tester.sendKeyEvent(k);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'G');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    expect(c.read(readerProvider).page, 0);
    expect(find.byKey(const Key('comicDetails')), findsOneWidget);

    // The page rows sit below the sections.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('detailsPage2')),
      200,
      scrollable: find.descendant(of: find.byKey(const Key('detailsList')), matching: find.byType(Scrollable)).first,
    );
    await tester.tap(find.byKey(const ValueKey('detailsPage2')));
    await settle(tester);
    expect(find.byKey(const Key('comicDetails')), findsNothing);
    expect(c.read(readerProvider).page, 2);

    // The info button opens it too, and I closes it again.
    await tester.tap(find.byKey(const Key('detailsButton')));
    await settle(tester);
    expect(find.byKey(const Key('comicDetails')), findsOneWidget);
    await typeI(tester);
    expect(find.byKey(const Key('comicDetails')), findsNothing);
    expect(c.read(readerProvider).book, isNotNull, reason: 'I closed the details, not the book');

    // Redo panels forgets them, as X does: the model's run on page 1 is gone.
    await typeI(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('detailsRedoPanels')),
      200,
      scrollable: find.descendant(of: find.byKey(const Key('detailsList')), matching: find.byType(Scrollable)).first,
    );
    await tester.tap(find.byKey(const Key('detailsRedoPanels')));
    for (var i = 0; i < 40 && !(c.read(readerProvider).message ?? '').startsWith('Panels forgotten'); i++) {
      await settle(tester);
    }
    expect(find.byKey(const Key('comicDetails')), findsNothing);
    final runs = await tester.runAsync(
      () => (db.select(db.analysedPages)..where((a) => a.source.equals(PanelSource.model.name))).get(),
    );
    expect(runs, isEmpty);
    expect(c.read(readerProvider).book, isNotNull, reason: 'the book opened again');
  });

  test('page summary and verdicts', () {
    final s = PageSummary([
      const PageFacts(format: 'jpeg', width: 1000, height: 1500, quality: 60, bytes: 300000),
      const PageFacts(format: 'jpeg', width: 1000, height: 1500, quality: 90, bytes: 400000),
      const PageFacts(format: 'png', width: 2000, height: 1500, bytes: 900000),
      PageFacts.unknown,
    ]);
    expect(s.formats, [('jpeg', 2), ('png', 1), ('unknown', 1)]);
    expect(s.wide, 1);
    expect(s.sizes!.median.width, 1000);
    expect(s.jpegQuality, (min: 60, median: 90, max: 90));
    expect(s.storedBytes, 1600000);
    expect(s.uniform, isFalse);
    expect(sharpness(3000, 1400).soft, isFalse);
    expect(sharpness(700, 1400).soft, isTrue);
    expect(wholeReason('3 panel(s): nothing to guide through'), 'fewer than 2 panels');
    expect(wholeReason('covers 40% of page (< 60%)'), 'panels cover too little of the page');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatDuration(const Duration(minutes: 65)), '1 h 5 min');
  });
}
