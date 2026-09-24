import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/clock_flash.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// The time (`T`, a long press in the middle): large for two seconds, then
/// faded, in the library, the reader and fullscreen, never in a tap's way.
void main() {
  const window = MethodChannel('org.snonux.comicredr/window');
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clock_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<ProviderContainer> start(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (_) async => null);
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db), classicCvOnly], child: const ComicRedrApp()),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  Future<void> open(WidgetTester tester, ProviderContainer c) async {
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeBook(tmp, 'Clock.cbz', 6)));
    await settle(tester);
    expect(find.byKey(const Key('page-image')), findsOneWidget);
  }

  Future<void> pressT(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT, character: 'T');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  Finder clock() => find.byKey(const Key('clock'));
  double opacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.ancestor(of: clock(), matching: find.byType(AnimatedOpacity))).opacity;

  testWidgets('T in fullscreen: the time, large, for two seconds, then it fades', (tester) async {
    final c = await start(tester);
    await open(tester, c);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
    await settle(tester);
    expect(c.read(readerProvider).fullscreen, isTrue);
    expect(clock(), findsNothing);

    await pressT(tester);
    expect(clock(), findsOneWidget);
    expect(opacity(tester), 1);
    final text = tester.widget<Text>(find.descendant(of: clock(), matching: find.byType(Text)));
    expect(text.data, matches(RegExp(r'^\d{1,2}:\d\d( [AP]M)?$')));
    expect(text.style!.fontSize, greaterThan(60));
    final screen = tester.getRect(find.byType(Scaffold));
    expect((tester.getCenter(clock()) - screen.center).distance, lessThan(2));

    // It takes no taps: nothing of it is in the hit path.
    final hits = HitTestResult();
    tester.binding.hitTestInView(hits, tester.getCenter(clock()), tester.view.viewId);
    expect(hits.path.any((e) => e.target is RenderParagraph), isFalse);

    // T again restarts the two seconds.
    await tester.pump(const Duration(milliseconds: 1500));
    await pressT(tester);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 600));
    expect(opacity(tester), 0);
    await tester.pump(ClockFlash.fade);
    await tester.pump();
    expect(clock(), findsNothing);
    expect(c.read(readerProvider).fullscreen, isTrue);
  });

  testWidgets('T works in the library too', (tester) async {
    await start(tester);
    await pressT(tester);
    expect(clock(), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(ClockFlash.fade);
    await tester.pump();
    expect(clock(), findsNothing);
  });

  testWidgets('with reduced motion it just goes', (tester) async {
    Widget app() => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true, alwaysUse24HourFormat: true),
        child: ClockFlash(key: GlobalKey(), now: () => DateTime(2026, 9, 24, 21, 5)),
      ),
    );
    await tester.pumpWidget(app());
    tester.state<ClockFlashState>(find.byType(ClockFlash)).flash();
    await tester.pump();
    expect(find.text('21:05'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(clock(), findsNothing);
  });

  testWidgets('follows the 12 or 24 hour setting', (tester) async {
    Widget app(bool h24) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(alwaysUse24HourFormat: h24),
        child: ClockFlash(now: () => DateTime(2026, 9, 24, 21, 5)),
      ),
    );
    await tester.pumpWidget(app(true));
    tester.state<ClockFlashState>(find.byType(ClockFlash)).flash();
    await tester.pump();
    expect(find.text('21:05'), findsOneWidget);
    await tester.pumpWidget(app(false));
    expect(find.text('9:05 PM'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
