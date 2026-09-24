import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_clock.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// The clock (`T`): the time on the reader's status line, remembered.
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

  testWidgets('T puts the time on the status line and takes it off', (tester) async {
    final c = await openBook(tester);
    expect(clock(), findsNothing);

    await key(tester, LogicalKeyboardKey.keyT, character: 'T', shift: true);
    expect(c.read(readerProvider).clock, isTrue);
    expect(clock(), findsOneWidget);
    expect(find.descendant(of: find.byType(Row), matching: clock()), findsOneWidget);
    final line = tester.getRect(find.byKey(const Key('status')));
    expect(tester.getRect(clock()).center.dy, closeTo(line.center.dy, 2));
    expect(tester.widget<Text>(clock()).data, matches(RegExp(r'^\d{1,2}:\d\d( [AP]M)?$')));

    // Fullscreen at rest has no status line, so no clock either.
    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.pump(const Duration(seconds: 3));
    expect(c.read(readerProvider).fullscreen, isTrue);
    expect(clock(), findsNothing);
    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    expect(clock(), findsOneWidget);

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
