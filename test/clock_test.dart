import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_clock.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// The clock (`T`): the time in a corner of the reader, in fullscreen too,
/// remembered, and never in the way of a tap.
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

  Future<ProviderContainer> openBook(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (_) async => null);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [databaseProvider.overrideWithValue(db), classicCvOnly],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    final path = File('${tmp.path}/Clock.cbz').existsSync() ? '${tmp.path}/Clock.cbz' : writeBook(tmp, 'Clock.cbz', 6);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    expect(find.byKey(const Key('page-image')), findsOneWidget);
    return c;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {String? character, bool shift = false}) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(k, character: character);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
  }

  Finder clock() => find.byKey(const Key('clock'));

  testWidgets('T shows the clock top left, in fullscreen too, and T hides it', (tester) async {
    final c = await openBook(tester);
    expect(clock(), findsNothing);

    await key(tester, LogicalKeyboardKey.keyT, character: 'T', shift: true);
    expect(c.read(readerProvider).clock, isTrue);
    expect(clock(), findsOneWidget);
    final screen = tester.getRect(find.byType(Scaffold));
    final at = tester.getRect(clock());
    expect(at.left, lessThan(screen.width / 4));
    expect(at.top, lessThan(screen.height / 8));
    final text = tester.widget<Text>(clock());
    expect(text.data, matches(RegExp(r'^\d{1,2}:\d\d( [AP]M)?$')));
    expect(text.style!.color!.a, lessThan(1));

    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    expect(c.read(readerProvider).fullscreen, isTrue);
    expect(clock(), findsOneWidget);

    // The clock takes no taps: the page under it gets them.
    final hits = HitTestResult();
    tester.binding.hitTestInView(hits, tester.getCenter(clock()), tester.view.viewId);
    expect(hits.path.any((e) => e.target is RenderParagraph), isFalse);

    await key(tester, LogicalKeyboardKey.keyT, character: 'T', shift: true);
    expect(c.read(readerProvider).clock, isFalse);
    expect(clock(), findsNothing);
  });

  testWidgets('the clock stays on for the next launch', (tester) async {
    final c = await openBook(tester);
    await key(tester, LogicalKeyboardKey.keyT, character: 'T', shift: true);
    await tester.runAsync(() async {
      await c.read(readerProvider.notifier).close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(await tester.runAsync(() => SettingsStore(db).loadBool(SettingsStore.clock)), isTrue);

    await openBook(tester);
    expect(clock(), findsOneWidget);
  });

  testWidgets('follows the 12 or 24 hour setting and turns over on the minute', (tester) async {
    var now = DateTime(2026, 9, 24, 21, 59, 58);
    Widget app(bool h24) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(alwaysUse24HourFormat: h24),
        child: ReaderClock(now: () => now),
      ),
    );
    await tester.pumpWidget(app(true));
    expect(find.text('21:59'), findsOneWidget);
    now = DateTime(2026, 9, 24, 22, 0, 0, 100);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('22:00'), findsOneWidget);
    await tester.pumpWidget(app(false));
    expect(find.text('10:00 PM'), findsOneWidget);
  });
}
