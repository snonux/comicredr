import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/layout.dart';
import 'package:comicredr/src/reader/page_painters.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('guided_test');
    db = AppDatabase(NativeDatabase.memory());
    // These tests step panel to panel; whole_page_test covers the default.
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db), classicCvOnly], child: const ComicRedrApp()),
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

  testWidgets('taps and swipes step through panels in guided view', (tester) async {
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeGuidedBook()));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    ReaderState s() => c.read(readerProvider);
    expect((s().page, s().panelIndex), (0, 0));
    final r = tester.getRect(find.byType(ReaderView));

    Future<void> swipe(double dx) async {
      final g = await tester.startGesture(r.center - Offset(dx / 2, 0), kind: PointerDeviceKind.touch);
      for (var i = 1; i <= 10; i++) {
        await g.moveBy(Offset(dx / 10, 0), timeStamp: Duration(milliseconds: 30 * i));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await g.up(timeStamp: const Duration(milliseconds: 300));
      await settle(tester);
    }

    await tester.tapAt(Offset(r.right - 40, r.center.dy), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect((s().page, s().panelIndex), (0, 1));
    // The camera is zoomed on the panel, but a swipe steps rather than pans.
    await swipe(-300);
    expect((s().page, s().panelIndex), (0, 2));
    await swipe(300);
    expect((s().page, s().panelIndex), (0, 1));
    await tester.tapAt(Offset(r.left + 40, r.center.dy), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect((s().page, s().panelIndex), (0, 0));
    expect(s().guided, isTrue);
  });

  test('a slanted frame dims along its outline, relative to the hole', () {
    const hole = Rect.fromLTWH(0.1, 0.1, 0.8, 0.4);
    expect(holeShape(hole, null), isNull);
    final shape = holeShape(hole, [0.1, 0.1, 0.9, 0.1, 0.9, 0.3, 0.1, 0.5])!;
    final want = [const Offset(0, 0), const Offset(1, 0), const Offset(1, 0.5), const Offset(0, 1)];
    expect(shape.length, want.length);
    for (final (i, p) in shape.indexed) {
      expect((p - want[i]).distance, lessThan(1e-9), reason: 'point $i: $p');
    }
    // In balloon mode the hole is the balloon's framing: the outline is cut
    // to it.
    final part = holeShape(const Rect.fromLTWH(0.5, 0.2, 0.4, 0.3), [0.1, 0.1, 0.9, 0.1, 0.9, 0.3, 0.1, 0.5])!;
    expect(part.every((p) => p.dx >= -1e-9 && p.dx <= 1 + 1e-9 && p.dy >= -1e-9 && p.dy <= 1 + 1e-9), isTrue);
    expect(part.length, greaterThanOrEqualTo(4));
  });
}
