import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/drift.dart' show Value;
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
    tmp = Directory.systemTemp.createTempSync('reader_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  // The in-memory database is left to the garbage collector: the app may
  // still flush a debounced position into it while the tree is torn down.
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db), classicCvOnly], child: const ComicRedrApp()),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  /// Real isolates and file IO need real time, outside the fake clock.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  /// Opens a book on the real event loop: isolates and files don't run on
  /// the test's fake clock.
  Future<void> open(WidgetTester tester, ProviderContainer c, String path) async {
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
  }

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

  testWidgets('opens a CBZ from the command line and pages through it', (tester) async {
    final path = writeBook(tmp, 'Test Comic 01.cbz', 6);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    expect(c.read(readerProvider).pageCount, 6);
    expect(status(tester), contains('page 1 / 6'));
    expect(find.byType(RawImage), findsOneWidget);
    double progress() => tester.widget<LinearProgressIndicator>(find.byKey(const Key('progress'))).value!;
    expect(progress(), closeTo(1 / 6, 1e-9));

    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).page, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).page, 4);
    expect(status(tester), contains('5 / 6'));

    await key(tester, LogicalKeyboardKey.keyG);
    await key(tester, LogicalKeyboardKey.keyG);
    expect(c.read(readerProvider).page, 0);

    // 4G jumps to page 4, '' jumps back.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'G');
    await settle(tester);
    expect(c.read(readerProvider).page, 3);
    // The test harness has no key code for ', so dispatch what '' resolves to
    // (the resolver's own tests cover the key sequence).
    await tester.runAsync(() => c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.jumpBack)));
    expect(c.read(readerProvider).page, 0);

    // Spread mode keeps the cover alone, then pairs.
    await key(tester, LogicalKeyboardKey.keyD);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).unit, [1, 2]);
    expect(status(tester), contains('pages 2–3 / 6'));
    expect(progress(), closeTo(3 / 6, 1e-9));

    // Closing the book flushes the position.
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    expect(c.read(readerProvider).book, isNull);
    await tester.runAsync(() async {
      expect(await db.select(db.progress).get(), hasLength(1));
    });
  });

  testWidgets('reopening resumes where reading stopped', (tester) async {
    final path = writeBook(tmp, 'Resume.cbz', 8);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await key(tester, LogicalKeyboardKey.keyL);
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await open(tester, c, path);
    expect(c.read(readerProvider).page, 5);
    expect(status(tester), 'Resumed at page 6');
  });

  testWidgets('a RAR is refused with a way forward', (tester) async {
    final path = '${tmp.path}/real.cbr';
    File(path).writeAsBytesSync([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0, 0, 0]);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    expect(status(tester), contains('RAR archive'));
    expect(find.text('Open a comic'), findsOneWidget);
  });

  testWidgets('] opens the next book in the folder', (tester) async {
    writeBook(tmp, 'Series 01.cbz', 2);
    final second = writeBook(tmp, 'Series 02.cbz', 3);
    final c = await pumpApp(tester);
    await open(tester, c, '${tmp.path}/Series 01.cbz');
    await tester.runAsync(() => c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.nextBook)));
    await settle(tester);
    expect(c.read(readerProvider).book?.path, second);
  });

  testWidgets('? shows the keymap generated from the bindings', (tester) async {
    await pumpApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, physicalKey: PhysicalKeyboardKey.slash, character: '?');
    await tester.pump();
    expect(find.text('Guided view, there and back'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Guided view, there and back'), findsNothing);
  });

  test('the index schema opens in memory', () async {
    await db
        .into(db.books)
        .insert(BooksCompanion.insert(contentKey: 'k', title: 'Daredevil 181', pageCount: 32, format: 'zip'));
    expect(await db.select(db.books).get(), hasLength(1));
  });

  test('an M3 index upgrades to the guided-view schema', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('DROP TABLE analysed_pages');
    await old.customStatement('ALTER TABLE progress DROP COLUMN view_json');
    await dropM8(old);
    await old.customStatement('PRAGMA user_version = 1');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    expect(await upgraded.select(upgraded.analysedPages).get(), isEmpty);
    expect(await upgraded.select(upgraded.progress).get(), isEmpty);
    await upgraded.close();
  });

  test('an M5 index keeps its positions and gains the saved view', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('ALTER TABLE progress DROP COLUMN view_json');
    await old.customStatement(
      "INSERT INTO progress (content_key, page, panel, percent, finished, updated_at) VALUES ('k', 4, 2, 0.5, 0, 0)",
    );
    await dropM8(old);
    await old.customStatement('PRAGMA user_version = 2');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    final at = await ProgressStore(upgraded).load('k');
    expect((at?.page, at?.panel, at?.guided, at?.view), (4, 2, null, null));
    await upgraded.close();
  });

  test('an M6 index keeps its positions and gains the library', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('DROP TABLE roots');
    await old.customStatement('DROP TABLE books');
    await old.customStatement(
      'CREATE TABLE books (content_key TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, series_id INTEGER, '
      'number TEXT, page_count INTEGER NOT NULL, format TEXT NOT NULL, added_at INTEGER NOT NULL)',
    );
    await old.customStatement(
      "INSERT INTO progress (content_key, page, panel, percent, finished, updated_at) VALUES ('k', 4, 2, 0.5, 0, 0)",
    );
    await dropM8(old);
    await old.customStatement('PRAGMA user_version = 3');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    expect(await upgraded.select(upgraded.roots).get(), isEmpty);
    expect((await ProgressStore(upgraded).load('k'))?.page, 4);
    await upgraded
        .into(upgraded.books)
        .insert(
          BooksCompanion.insert(contentKey: 'k', title: 'X', pageCount: 3, format: 'cbz', year: const Value(1982)),
        );
    await upgraded.close();
  });

  test('an M7 index keeps its bookmarks and gains sidecar support', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await dropM8(old);
    await old.customStatement(
      "INSERT INTO bookmarks (id, content_key, page, panel, mark, created_at) VALUES ('b', 'k', 4, 2, NULL, 0)",
    );
    await old.customStatement('PRAGMA user_version = 4');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    final marks = await upgraded.select(upgraded.bookmarks).get();
    expect((marks.single.page, marks.single.deletedAt), (4, null));
    expect(await upgraded.select(upgraded.settings).get(), isEmpty);
    await upgraded.close();
  });

  test('an index with settings but no removal times gains them', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('ALTER TABLE bookmarks DROP COLUMN deleted_at');
    await old.customStatement("INSERT INTO settings (key, value) VALUES ('guided.wholePageSteps', 'false')");
    await old.customStatement('PRAGMA user_version = 5');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    expect(await upgraded.select(upgraded.bookmarks).get(), isEmpty);
    expect((await upgraded.select(upgraded.settings).get()).single.value, 'false');
    await upgraded.close();
  });
}

/// Takes an index back to before schema 5: no removal times, no settings.
Future<void> dropM8(AppDatabase old) async {
  await old.customStatement('ALTER TABLE bookmarks DROP COLUMN deleted_at');
  await old.customStatement('DROP TABLE settings');
}
