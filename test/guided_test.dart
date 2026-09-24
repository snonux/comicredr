import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/layout.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('guided_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db)], child: const ComicRedrApp()),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  /// Detection runs on real isolates, and the camera animates: give both
  /// real time, then let the fake clock run the animation out.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {String? character}) async {
    await tester.sendKeyEvent(k, character: character);
    await settle(tester);
  }

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

  /// Three four-panel pages and a blank one the gate must refuse.
  String writeGuidedBook() =>
      writeBookOf(tmp, 'Guided 01.cbz', [grid4Page(), grid4Page(), gridPage(400, 600, const []), grid4Page()]);

  testWidgets('v steps through panels, crosses pages and comes back', (tester) async {
    final path = writeGuidedBook();
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);

    // Enter from a spread, so v can prove it returns there.
    await key(tester, LogicalKeyboardKey.keyD);
    expect(c.read(readerProvider).mode, PageMode.spread);
    await key(tester, LogicalKeyboardKey.keyV);
    var s = c.read(readerProvider);
    expect(s.guided, isTrue);
    expect(s.panels[0]!.gate.passed, isTrue, reason: s.panels[0]!.gate.reasons.join('; '));
    expect(s.panels[0]!.frames, hasLength(4));
    expect(status(tester), contains('guided: panel 1 / 4'));
    expect(find.byKey(const Key('guided-dim')), findsOneWidget);
    double progress() => tester.widget<LinearProgressIndicator>(find.byKey(const Key('progress'))).value!;
    expect(progress(), closeTo(0.25 / 4, 1e-9), reason: 'panel 1 of 4 on page 1 of 4');

    // Panels in reading order: across the top row, then the bottom.
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).focus!.x, greaterThan(0.5));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).focus!.y, greaterThan(0.5));
    await key(tester, LogicalKeyboardKey.keyL);
    await key(tester, LogicalKeyboardKey.keyL);
    s = c.read(readerProvider);
    expect((s.page, s.panelIndex), (1, 0), reason: 'the last panel steps onto the next page');

    // Back across the page boundary lands on the last panel.
    await key(tester, LogicalKeyboardKey.keyH);
    s = c.read(readerProvider);
    expect((s.page, s.panelIndex), (0, 3));

    // A count steps panels: 5l from page 1 panel 4 is page 2's panel 4... then
    // the blank page is one whole-page step.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await key(tester, LogicalKeyboardKey.keyL);
    s = c.read(readerProvider);
    expect((s.page, s.panelIndex), (2, -1));
    expect(status(tester), contains('guided: whole page'));
    expect(find.byKey(const Key('guided-dim')), findsNothing);

    // Ctrl+f skips to the next page's first panel.
    await key(tester, LogicalKeyboardKey.keyH);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    s = c.read(readerProvider);
    expect((s.page, s.panelIndex), (2, -1));

    // v goes back to the spread it came from; v again returns to the panel.
    await key(tester, LogicalKeyboardKey.keyH);
    s = c.read(readerProvider);
    expect((s.page, s.panelIndex), (1, 3));
    await key(tester, LogicalKeyboardKey.keyV);
    s = c.read(readerProvider);
    expect((s.guided, s.mode), (false, PageMode.spread));
    await key(tester, LogicalKeyboardKey.keyV);
    s = c.read(readerProvider);
    expect((s.guided, s.page, s.panelIndex), (true, 1, 3));

    // Esc leaves guided view first, and only then closes the book.
    await key(tester, LogicalKeyboardKey.escape);
    expect(c.read(readerProvider).guided, isFalse);
    expect(c.read(readerProvider).book, isNotNull);

    // Detection was cached by content key, page and version.
    await tester.runAsync(() async {
      expect(await db.select(db.analysedPages).get(), hasLength(4));
      expect(await db.select(db.panels).get(), hasLength(12));
    });
  });

  testWidgets('reopening resumes at the panel, from the cached panels', (tester) async {
    final path = writeGuidedBook();
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await key(tester, LogicalKeyboardKey.keyL);
    // ma marks the panel, and survives the reopen too.
    await tester.runAsync(
      () => c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.setMark, register: 'a')),
    );
    expect(status(tester), contains('panel 3'));
    await tester.runAsync(() => c.read(readerProvider.notifier).close());

    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await tester.pump();
    var s = c.read(readerProvider);
    expect(s.panels.keys, containsAll([0, 1, 2]), reason: 'panels come back from the index, not a new run');
    expect((s.guided, s.page, s.panelIndex), (true, 0, 2));
    await key(tester, LogicalKeyboardKey.keyG, character: 'G');
    await tester.runAsync(
      () => c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.jumpMark, register: 'a')),
    );
    s = c.read(readerProvider);
    expect((s.page, s.panelIndex), (0, 2));
  });

  testWidgets('Tab cycles single, spread, guided', (tester) async {
    final path = writeGuidedBook();
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.tab);
    expect(c.read(readerProvider).mode, PageMode.spread);
    await key(tester, LogicalKeyboardKey.tab);
    expect(c.read(readerProvider).guided, isTrue);
    await key(tester, LogicalKeyboardKey.tab);
    expect((c.read(readerProvider).guided, c.read(readerProvider).mode), (false, PageMode.single));
  });
}
