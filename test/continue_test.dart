import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/recent_books.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/fixtures.dart';

/// `C` and the library's Continue button: the comic read last, where it
/// was left, across a restart; from inside a comic the one before it; a
/// moved comic found by its content, a deleted one a notice.
void main() {
  late Directory tmp;
  late Directory root;
  late String covers;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('continue_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    covers = '${tmp.path}/covers';
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  // Different page counts, so the two have different content keys.
  Future<(String, String)> shelf() async {
    final a = writeBook(root, 'Swamp Thing 21.cbz', 5);
    final b = writeBook(root, 'Daredevil 181.cbz', 3);
    final store = LibraryStore(db);
    await store.addRoot(root.path);
    await LibraryScanner(store, coverDir: covers, workers: 1).scan();
    return (a, b);
  }

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // A new scope each time is a restart over the same index.
        key: UniqueKey(),
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue(covers),
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
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {String? character}) async {
    if (character != null && character.toUpperCase() == character && character.toLowerCase() != character) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key, character: character);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    } else {
      await tester.sendKeyEvent(key, character: character);
    }
    await tester.pump();
    await settle(tester);
  }

  // Opening a book from a key runs its file work in the test's fake time:
  // give it the time it takes.
  Future<void> continueKey(WidgetTester tester) async {
    await press(tester, LogicalKeyboardKey.keyC, character: 'C');
    await settle(tester);
    await settle(tester);
  }

  testWidgets('C reopens the last comic at its page, goes between two, and survives a restart', (tester) async {
    final (swamp, daredevil) = (await tester.runAsync(shelf))!;
    var c = await pumpApp(tester);
    await settle(tester);

    // Nothing read yet: a notice and no button.
    await continueKey(tester);
    expect(c.read(readerProvider).book, isNull);
    expect(c.read(readerProvider).message, 'No comic read yet to continue');
    expect(find.byKey(const Key('continue')), findsNothing);

    // Swamp Thing to page 4, closed.
    await tester.runAsync(() => c.read(readerProvider.notifier).open(swamp));
    await settle(tester);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.pageDown);
    }
    expect(c.read(readerProvider).page, 3);
    await press(tester, LogicalKeyboardKey.escape);
    expect(c.read(readerProvider).book, isNull);
    expect(find.byTooltip('Continue Swamp Thing 21 (C)'), findsOneWidget);

    // C in the library: back on page 4.
    await continueKey(tester);
    expect(c.read(readerProvider).book?.path, swamp);
    expect(c.read(readerProvider).page, 3);

    // Daredevil, page 2; then C in it goes to Swamp Thing, and C again back.
    await tester.runAsync(() => c.read(readerProvider.notifier).open(daredevil));
    await settle(tester);
    await press(tester, LogicalKeyboardKey.pageDown);
    await continueKey(tester);
    expect(c.read(readerProvider).book?.path, swamp);
    expect(c.read(readerProvider).page, 3);
    await continueKey(tester);
    expect(c.read(readerProvider).book?.path, daredevil);
    expect(c.read(readerProvider).page, 1);

    // A restart: the button and C bring back Daredevil at page 2.
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    c = await pumpApp(tester);
    await settle(tester);
    expect(c.read(readerProvider).book, isNull);
    await tester.tap(find.byKey(const Key('continue')));
    for (var i = 0; i < 3; i++) {
      await settle(tester);
    }
    expect(c.read(readerProvider).book?.path, daredevil);
    expect(c.read(readerProvider).page, 1);
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await settle(tester);
  });

  testWidgets('a comic moved in the library is found; a deleted one gets a notice and C goes on', (tester) async {
    final (swamp, daredevil) = (await tester.runAsync(shelf))!;
    var c = await pumpApp(tester);
    await settle(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(swamp));
    await settle(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(daredevil));
    await settle(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await settle(tester);

    // Daredevil moves into a sub-folder and the library sees it there.
    final moved = p.join(root.path, 'Marvel', 'Daredevil 181.cbz');
    await tester.runAsync(() async {
      Directory(p.dirname(moved)).createSync();
      File(daredevil).renameSync(moved);
      await LibraryScanner(LibraryStore(db), coverDir: covers, workers: 1).scan();
    });
    await continueKey(tester);
    expect(c.read(readerProvider).message, isNull);
    expect(c.read(readerProvider).book?.path, moved);

    // Deleted outside the app: a notice, then C opens the one before.
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await tester.runAsync(() async => File(moved).deleteSync());
    c = await pumpApp(tester);
    await settle(tester);
    await continueKey(tester);
    expect(c.read(readerProvider).book, isNull);
    expect(c.read(readerProvider).message, contains('Daredevil 181 is gone from'));
    expect(c.read(recentBooksProvider).map((b) => b.title), ['Swamp Thing 21']);
    await continueKey(tester);
    expect(c.read(readerProvider).book?.path, swamp);
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await settle(tester);
  });
}
