import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/guided.dart';
import 'package:comicredr/src/reader/panel_detector.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'balloon_test.dart' show FakeModel;
import 'support/fixtures.dart';

/// Whole-page steps, on by default: guided view shows a page whole on
/// arrival and again after its last panel, in both directions.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('whole_page_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester, {PanelDetector? detector}) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          databaseProvider.overrideWithValue(db),
          noSidecars(db),
          detector != null ? panelDetectorProvider.overrideWith((ref) async => detector) : classicCvOnly,
        ],
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

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

  /// Page and panel as the reader shows them: 'S' and 'E' for the whole
  /// page before and after its panels, 'W' for a page that is only ever
  /// shown whole.
  (int, Object) at(ProviderContainer c) {
    final s = c.read(readerProvider);
    if (s.stopsOn(s.page).isEmpty) return (s.page, 'W');
    if (s.panelIndex >= 0) return (s.page, s.panelIndex);
    return (s.page, s.panel >= pageEnd ? 'E' : 'S');
  }

  /// Three four-panel pages and a blank one the gate refuses.
  String writeGuidedBook() =>
      writeBookOf(tmp, 'Guided 01.cbz', [grid4Page(), grid4Page(), gridPage(400, 600, const []), grid4Page()]);

  testWidgets('pages are shown whole before and after their panels, both ways', (tester) async {
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeGuidedBook()));
    await settle(tester);
    expect(c.read(readerProvider).wholePageSteps, isTrue, reason: 'on by default');
    double progress() => tester.widget<LinearProgressIndicator>(find.byKey(const Key('progress'))).value!;

    await key(tester, LogicalKeyboardKey.keyV);
    expect(at(c), (0, 'S'));
    expect(c.read(readerProvider).focus, isNull);
    expect(status(tester), contains('guided: whole page, then 4 panels'));
    expect(find.byKey(const Key('guided-dim')), findsNothing);
    expect(progress(), 0);

    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (0, 0));
    expect(c.read(readerProvider).focus, isNotNull);
    await key(tester, LogicalKeyboardKey.keyL, times: 3);
    expect(at(c), (0, 3));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (0, 'E'), reason: 'the page once more after its last panel');
    expect(status(tester), contains('guided: whole page, 4 panels read'));
    expect(progress(), closeTo(1 / 4, 1e-9));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (1, 'S'), reason: 'then the next page whole');

    // Backwards mirrors it.
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (0, 'E'));
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (0, 3));
    await key(tester, LogicalKeyboardKey.keyH, times: 3);
    expect(at(c), (0, 0));
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (0, 'S'));
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (0, 'S'), reason: 'nothing before the first page');

    // A page shown whole anyway is one step, not two; a count crosses it.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (1, 'E'));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (2, 'W'));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (3, 'S'));
    await key(tester, LogicalKeyboardKey.keyH, times: 2);
    expect(at(c), (1, 'E'));

    // Ctrl+f turns the page and lands on it whole.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(at(c), (3, 'S'));
  });

  testWidgets('w turns whole-page steps off and on, and the choice is kept', (tester) async {
    final path = writeGuidedBook();
    var c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    await key(tester, LogicalKeyboardKey.keyW);
    expect(c.read(readerProvider).wholePageSteps, isFalse);
    expect(status(tester), contains('Straight from panel to panel'));
    expect(await tester.runAsync(() => SettingsStore(db).loadBool(SettingsStore.wholePageSteps)), isFalse);

    // Off: panel to panel across the page boundary, both ways.
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (0, 0));
    await key(tester, LogicalKeyboardKey.keyL, times: 4);
    expect(at(c), (1, 0));
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (0, 3));

    // A new app on the same index keeps it off.
    await tester.runAsync(() => c.read(readerProvider.notifier).flush());
    c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    expect(c.read(readerProvider).wholePageSteps, isFalse);
    expect(at(c), (0, 3));

    // And back on: the last panel steps to the page whole.
    await key(tester, LogicalKeyboardKey.keyW);
    expect(status(tester), contains('Whole page before and after'));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (0, 'E'));
  });

  testWidgets('a restart on a whole-page step comes back to it', (tester) async {
    final path = writeGuidedBook();
    var c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    await key(tester, LogicalKeyboardKey.keyL, times: 5);
    expect(at(c), (0, 'E'));
    await tester.runAsync(() => c.read(readerProvider.notifier).flush());

    c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    expect(c.read(readerProvider).guided, isTrue);
    expect(at(c), (0, 'E'));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (1, 'S'));
    await tester.runAsync(() => c.read(readerProvider.notifier).flush());

    c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    expect(at(c), (1, 'S'));
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (0, 'E'));
  });

  testWidgets('balloon mode shows the page whole around its panels and balloons', (tester) async {
    final c = await pumpApp(tester, detector: const FakeModel());
    await tester.runAsync(
      () => c.read(readerProvider.notifier).open(writeBookOf(tmp, 'Balloons 01.cbz', [grid4Page(), grid4Page()])),
    );
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyB);
    (int, Object, int) where() {
      final s = c.read(readerProvider);
      return (at(c).$1, at(c).$2, s.balloonIndex);
    }

    expect(where(), (0, 'S', -1));
    // Panel 1 and its two balloons, panel 2, panel 3 and its balloon, panel 4.
    final forward = [(0, 0, -1), (0, 0, 0), (0, 0, 1), (0, 1, -1), (0, 2, -1), (0, 2, 0), (0, 3, -1)];
    for (final w in forward) {
      await key(tester, LogicalKeyboardKey.keyL);
      expect(where(), w);
    }
    await key(tester, LogicalKeyboardKey.keyL);
    expect(where(), (0, 'E', -1));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(where(), (1, 'S', -1));
    for (final w in [(0, 'E', -1), (0, 3, -1), (0, 2, 0), (0, 2, -1)]) {
      await key(tester, LogicalKeyboardKey.keyH);
      expect(where(), w);
    }
  });

  testWidgets('taps and swipes take the same whole-page steps', (tester) async {
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeGuidedBook()));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    await key(tester, LogicalKeyboardKey.keyL, times: 4);
    expect(at(c), (0, 3));
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
    expect(at(c), (0, 'E'));
    await swipe(-300);
    expect(at(c), (1, 'S'));
    await swipe(300);
    expect(at(c), (0, 'E'));
    await tester.tapAt(Offset(r.left + 40, r.center.dy), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect(at(c), (0, 3));
  });
}
