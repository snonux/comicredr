import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'support/fixtures.dart';

/// Comics a scan finds for the first time go in the Unread collection;
/// opening one takes it out. What was there already is not new.
void main() {
  late Directory tmp;
  late Directory root;
  late AppDatabase db;
  late LibraryStore store;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('unread_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    db = AppDatabase(NativeDatabase.memory());
    store = LibraryStore(db);
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> scan() => LibraryScanner(store, coverDir: '${tmp.path}/covers', workers: 1).scan();

  Future<List<String>> unread() async => [
    for (final b in await store.books())
      if (b.collections.contains(unreadCollection)) p.basename(b.path),
  ]..sort();

  Future<String> keyOf(String name) async => (await store.books()).firstWhere((b) => p.basename(b.path) == name).key;

  test('the first scan of a folder puts nothing in Unread, a comic added later goes in', () async {
    writeBook(root, 'Saga 01.cbz', 2);
    writeBook(root, 'Saga 02.cbz', 3);
    await store.addRoot(root.path);
    await scan();
    expect(await unread(), isEmpty, reason: 'what the folder had is not new');

    writeBook(root, 'Saga 03.cbz', 4);
    await scan();
    expect(await unread(), ['Saga 03.cbz']);
    await scan();
    expect(await unread(), ['Saga 03.cbz'], reason: 'a scan that finds nothing new changes nothing');
  });

  test('a first scan cut short leaves the rest of the folder not new', () async {
    writeBook(root, 'Saga 01.cbz', 2);
    final id = await store.addRoot(root.path);
    await scan();
    // As if the app had stopped before the first scan went through.
    await (db.update(db.roots)..where((r) => r.id.equals(id))).write(const RootsCompanion(scannedAt: Value(null)));
    writeBook(root, 'Saga 02.cbz', 3);
    await scan();
    expect(await unread(), isEmpty);
  });

  test('moved, copied, deleted and put back, or changed: not new', () async {
    writeBook(root, 'Saga 01.cbz', 2);
    writeBook(root, 'Saga 02.cbz', 3);
    final changed = writeBook(root, 'Saga 03.cbz', 3);
    await store.addRoot(root.path);
    await scan();

    final sub = Directory('${root.path}/Saga')..createSync();
    File('${root.path}/Saga 01.cbz').renameSync('${sub.path}/Saga 01.cbz');
    final gone = File('${root.path}/Saga 02.cbz').readAsBytesSync();
    File('${root.path}/Saga 02.cbz').deleteSync();
    writeBook(root, 'Saga 03.cbz', 5); // Other content at a path the folder had.
    await scan();
    expect(File(changed).existsSync(), isTrue);
    expect(await unread(), isEmpty);

    File('${root.path}/Saga 02 again.cbz').writeAsBytesSync(gone);
    File('${sub.path}/Saga 01 copy.cbz').writeAsBytesSync(File('${sub.path}/Saga 01.cbz').readAsBytesSync());
    await scan();
    expect(await unread(), isEmpty);
  });

  test('a new comic already read on another device stays out of Unread', () async {
    await store.addRoot(root.path);
    await scan();
    writeBook(root, 'Saga 01.cbz', 2);
    writeBook(root, 'Saga 02.cbz', 3);
    await scan();
    final key = await keyOf('Saga 01.cbz');
    // Taken out again, then as if found anew with another device's position.
    await store.leaveUnread(key);
    await db
        .into(db.progress)
        .insert(ProgressCompanion.insert(contentKey: key, page: 1, percent: 0.5, updatedAt: DateTime.now()));
    expect(await store.putInUnread(key), isFalse);
    expect(await unread(), ['Saga 02.cbz']);
  });

  test('leaveUnread takes a comic out once, and the row stays for the sidecar', () async {
    await store.addRoot(root.path);
    await scan();
    writeBook(root, 'Saga 01.cbz', 2);
    await scan();
    final key = await keyOf('Saga 01.cbz');
    expect(await store.leaveUnread(key), isTrue);
    expect(await store.leaveUnread(key), isFalse);
    expect(await unread(), isEmpty);
    final row = await (db.select(db.collectionBooks)..where((c) => c.contentKey.equals(key))).getSingle();
    expect(row.removedAt, isNotNull);
  });

  test('upgrading takes the library as seen and its folders as scanned', () async {
    final file = File('${tmp.path}/old.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    final oldStore = LibraryStore(old);
    writeBook(root, 'Saga 01.cbz', 2);
    await oldStore.addRoot(root.path);
    await LibraryScanner(oldStore, coverDir: '${tmp.path}/covers', workers: 1).scan();
    await old.close();
    // Back to schema 11: no seen_books, no roots.scanned_at.
    final raw = sqlite.sqlite3.open(file.path);
    raw
      ..execute('DROP TABLE seen_books')
      ..execute('ALTER TABLE roots DROP COLUMN scanned_at')
      ..execute('PRAGMA user_version = 11')
      ..close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final s = LibraryStore(upgraded);
    expect(await s.markSeen((await s.books()).single.key), isFalse, reason: 'seen before the upgrade');
    expect((await s.roots()).single.scannedAt, isNotNull);
    writeBook(root, 'Saga 02.cbz', 3);
    await LibraryScanner(s, coverDir: '${tmp.path}/covers', workers: 1).scan();
    expect(
      {for (final b in await s.books()) p.basename(b.path): b.collections.contains(unreadCollection)},
      {'Saga 01.cbz': false, 'Saga 02.cbz': true},
    );
  });

  testWidgets('opening a comic takes it out of Unread', (tester) async {
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
    await tester.runAsync(() async {
      await store.addRoot(root.path);
      await scan();
      writeBook(root, 'Saga 01.cbz', 2);
      await scan();
    });
    expect(await tester.runAsync(unread), ['Saga 01.cbz']);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db), classicCvOnly, noSidecars(db)],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    await tester.runAsync(() => c.read(readerProvider.notifier).open('${root.path}/Saga 01.cbz'));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(await tester.runAsync(unread), isEmpty);
  });
}
