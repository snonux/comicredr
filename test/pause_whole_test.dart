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

/// The pause on whole pages, on by default: in guided view a page without
/// usable panels turns the background wine red on arrival, a step off it
/// within five seconds stays and zooms the page out and back, and the next
/// one turns. A step after five seconds turns at once.
void main() {
  late Directory tmp;
  late AppDatabase db;

  /// The reader's clock: tests move it on by hand.
  var now = DateTime(2026, 9, 26, 20);

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

  /// The reader's background: black, or wine red while a page is held.
  Color? background(WidgetTester tester) => tester.widgetList<Scaffold>(find.byType(Scaffold)).first.backgroundColor;

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
    c.read(readerProvider.notifier).clock = () => now;
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeBook()));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    return c;
  }

  testWidgets('a page shown whole is wine red on arrival and holds a quick step each way', (tester) async {
    final c = await openGuided(tester, whole: false);
    expect(c.read(readerProvider).pauseWhole, isTrue, reason: 'on by default');
    expect(at(c), (0, false));
    expect(background(tester), heldColour, reason: 'wine red as soon as the page is shown whole');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(pulseScale(tester), lessThan(0.93), reason: 'a quick step zooms the page out');
    await settle(tester);
    expect(pulseScale(tester), 1, reason: 'and back');
    expect(at(c), (0, false), reason: 'the first step stays on the page');
    expect(background(tester), heldColour, reason: 'still wine red until the page is left');
    expect(status(tester), contains('press again for the next page'));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (1, true), reason: 'the second turns, onto the first panel');
    expect(background(tester), Colors.black);

    // Pages with panels are never held: straight across to the last page.
    await key(tester, LogicalKeyboardKey.keyL, times: 8);
    expect(at(c), (3, false));
    expect(background(tester), heldColour);
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (2, true), reason: 'arrived from behind, back leaves at once');

    // Arriving from ahead, back holds first; after that either way leaves.
    await key(tester, LogicalKeyboardKey.keyH, times: 8);
    expect(at(c), (0, false));
    await key(tester, LogicalKeyboardKey.keyH);
    expect(at(c), (0, false));
    expect(background(tester), heldColour);
    expect(status(tester), contains('press again for the previous page'));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (1, true));
    expect(background(tester), Colors.black);

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
    expect(background(tester), Colors.black, reason: 'off: no wine red');
    expect(await tester.runAsync(() => SettingsStore(db).loadBool(SettingsStore.pauseWhole)), isFalse);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).page, 1, reason: 'off: the page turns at once');

    await tester.runAsync(() => c.read(readerProvider.notifier).flush());
    c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeBook()));
    await settle(tester);
    expect(c.read(readerProvider).pauseWhole, isFalse);
  });

  testWidgets('a step after five seconds turns at once; each arrival starts the time again', (tester) async {
    final c = await openGuided(tester, whole: false);
    expect(background(tester), heldColour);
    now = now.add(const Duration(seconds: 5));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(pulseScale(tester), 1, reason: 'no zoom');
    await settle(tester);
    expect(at(c), (1, true), reason: 'five seconds on, the first step turns');
    expect(background(tester), Colors.black);

    // Back on the page, the time starts again: a quick step holds.
    await key(tester, LogicalKeyboardKey.home);
    expect(at(c), (0, false));
    now = now.add(const Duration(milliseconds: 4900));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (0, false), reason: 'within five seconds of arriving');
    now = now.add(const Duration(seconds: 30));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (1, true), reason: 'held once, the next step turns');

    // Guided view on again: the page turns red and the time starts anew.
    await key(tester, LogicalKeyboardKey.home);
    await key(tester, LogicalKeyboardKey.keyV);
    expect(background(tester), Colors.black, reason: 'no red outside guided view');
    now = now.add(const Duration(minutes: 1));
    await key(tester, LogicalKeyboardKey.keyV);
    expect(background(tester), heldColour);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(at(c), (0, false));
  });

  testWidgets('with reduced motion there is no zoom, and the hint shows every time', (tester) async {
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
      expect(background(tester), heldColour);
      expect(status(tester), contains('press again for the next page'));
      await key(tester, LogicalKeyboardKey.keyL);
      expect(at(c), (1, true));
      await key(tester, LogicalKeyboardKey.home);
    }
  });
}
