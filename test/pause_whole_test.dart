import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// The pause on whole pages, on by default: in guided view the first step
/// off a page without usable panels stays on it and plays a cue; the next
/// one turns.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pause_whole_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

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

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

  /// The page, and whether guided view is on a panel.
  (int, bool) at(ProviderContainer c) {
    final s = c.read(readerProvider);
    return (s.page, s.panelIndex >= 0);
  }

  /// How far the pulse has shrunk the page right now: 1 when it is still.
  double pulseScale(WidgetTester tester) {
    final scales = [
      for (final t in tester.widgetList<Transform>(
        find.descendant(of: find.byType(ReaderView), matching: find.byType(Transform)),
      ))
        t.transform.storage[0],
    ].where((s) => s < 1);
    return scales.isEmpty ? 1 : scales.first;
  }

  /// A blank page the gate refuses, two four-panel pages, and another blank.
  String writeBook() => writeBookOf(tmp, 'Pause 01.cbz', [
    gridPage(400, 600, const []),
    grid4Page(),
    grid4Page(),
    gridPage(400, 600, const []),
  ]);

  Future<ProviderContainer> openGuided(WidgetTester tester, {bool whole = true}) async {
    await tester.runAsync(() => SettingsStore(db).saveBool(SettingsStore.wholePageSteps, whole));
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeBook()));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    return c;
  }

  testWidgets('a page shown whole holds for one step each way, with a cue', (tester) async {
    final c = await openGuided(tester, whole: false);
    expect(c.read(readerProvider).pauseWhole, isTrue, reason: 'on by default');
    expect(at(c), (0, false));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(pulseScale(tester), lessThan(0.93), reason: 'the page eases out mid-cue');
    await settle(tester);
    expect(pulseScale(tester), 1, reason: 'and back');
    expect(at(c), (0, false), reason: 'the first step stays on the page');
    expect(status(tester), contains('press again for the next page'));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (1, true), reason: 'the second turns, onto the first panel');

    // Pages with panels are never held: straight across to the last page.
    await key(tester, LogicalKeyboardKey.keyL, times: 8);
    expect(at(c), (3, false));
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (2, true), reason: 'arrived from behind, back leaves at once');

    // Arriving from ahead, back holds first; after that either way leaves.
    await key(tester, LogicalKeyboardKey.keyH, times: 8);
    expect(at(c), (0, false));
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (0, false));
    expect(status(tester), contains('press again for the previous page'));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (1, true));

    // Arriving from ahead, forward leaves at once.
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (0, false));
    final r = tester.getRect(find.byType(ReaderView));
    await tester.tapAt(Offset(r.right - 40, r.center.dy), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect(at(c), (1, true));

    // A tap in the right zone holds like a key.
    await key(tester, LogicalKeyboardKey.home);
    expect(at(c), (0, false));
    await tester.tapAt(Offset(r.right - 40, r.center.dy), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect(at(c), (0, false), reason: 'a tap holds like a key');
    await tester.tapAt(Offset(r.right - 40, r.center.dy), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect(at(c), (1, true));
  });

  testWidgets('W turns the pause off and on, and the choice is kept', (tester) async {
    var c = await openGuided(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW, character: 'W');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    expect(c.read(readerProvider).pauseWhole, isFalse);
    expect(status(tester), contains('turn at once'));
    expect(await tester.runAsync(() => SettingsStore(db).loadBool(SettingsStore.pauseWhole)), isFalse);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).page, 1, reason: 'off: the page turns at once');

    await tester.runAsync(() => c.read(readerProvider.notifier).flush());
    c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeBook()));
    await settle(tester);
    expect(c.read(readerProvider).pauseWhole, isFalse);
  });

  testWidgets('with reduced motion the cue is the hint alone, every time', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final c = await openGuided(tester, whole: false);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(pulseScale(tester), 1, reason: 'no zoom');
      await settle(tester);
      expect(at(c), (0, false));
      expect(status(tester), contains('press again for the next page'));
      await key(tester, LogicalKeyboardKey.keyL);
      expect(at(c), (1, true));
      await key(tester, LogicalKeyboardKey.home);
    }
  });
}
