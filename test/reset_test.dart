import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// `X` resets the open comic, after asking: its panels only, or everything
/// the app knows about it. The sidecar side is in sidecar_test.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('reset_test');
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db), classicCvOnly, noSidecars(db)],
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

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {String? character}) async {
    await tester.sendKeyEvent(k, character: character);
    await settle(tester);
  }

  Future<void> pressX(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'X');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
  }

  /// The reset closes the comic and opens it again, on real isolates, and
  /// then says what it did.
  Future<void> reopened(WidgetTester tester, ProviderContainer c, String notice) async {
    for (var i = 0; i < 40 && !(c.read(readerProvider).message ?? '').startsWith(notice); i++) {
      await settle(tester);
    }
  }

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

  testWidgets('X asks first, and Cancel changes nothing', (tester) async {
    final path = writeBookOf(tmp, 'Reset 01.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyL);
    await pressX(tester);
    expect(find.byKey(const Key('resetDialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('resetCancel')));
    await settle(tester);
    expect(find.byKey(const Key('resetDialog')), findsNothing);
    expect(c.read(readerProvider).page, 1);
  });

  testWidgets('Reset everything reopens the comic on page 1 with no bookmarks or history', (tester) async {
    final path = writeBookOf(tmp, 'Reset 02.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyL);
    await key(tester, LogicalKeyboardKey.keyL);
    // Both keys at once: the sequence times out while settle() waits.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await settle(tester);
    final book = c.read(readerProvider).book!.key;
    await tester.runAsync(() async {
      await c.read(readerProvider.notifier).flush();
      expect(await db.select(db.bookmarks).get(), isNotEmpty);
    });

    await pressX(tester);
    await tester.tap(find.byKey(const Key('resetEverything')));
    await reopened(tester, c, 'Started');
    final s = c.read(readerProvider);
    expect(s.book?.key, book, reason: 'the comic is open again');
    expect(s.page, 0);
    expect(status(tester), startsWith('Started'));
    await tester.runAsync(() async {
      expect(await db.select(db.bookmarks).get(), isEmpty);
      expect(await db.select(db.readLog).get(), isEmpty);
    });
  });

  testWidgets('Redo panels keeps the place and finds the panels again', (tester) async {
    final path = writeBookOf(tmp, 'Reset 03.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    for (var i = 0; i < 5; i++) {
      await key(tester, LogicalKeyboardKey.keyL);
    }
    expect((c.read(readerProvider).page, c.read(readerProvider).panel), (1, 1));
    final before = await tester.runAsync(() => db.select(db.analysedPages).get());
    expect(before, isNotEmpty);

    await pressX(tester);
    await tester.tap(find.byKey(const Key('resetPanels')));
    await reopened(tester, c, 'Finding the panels again');
    final s = c.read(readerProvider);
    expect((s.page, s.panel, s.guided), (1, 1, true));
    expect(s.panels[1]?.frames, hasLength(4), reason: 'found again');
    final after = await tester.runAsync(() => db.select(db.analysedPages).get());
    expect(after!.map((a) => a.analysedAt).every((t) => t.isAfter(before!.first.analysedAt)), isTrue);
  });
}
