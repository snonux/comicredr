import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/read_log_store.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// M8's library pieces: collections, reading history and the settings.
void main() {
  late Directory tmp;
  late Directory root;
  late String covers;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('m8_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    covers = '${tmp.path}/covers';
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<LibraryStore> shelf() async {
    writeBook(root, 'Swamp Thing 21.cbz', 3);
    writeBook(root, 'Daredevil 181.cbz', 4);
    writeBook(root, 'Preacher 1.cbz', 2);
    final store = LibraryStore(db);
    await store.addRoot(root.path);
    await LibraryScanner(store, coverDir: covers, workers: 1).scan();
    return store;
  }

  LibraryBook named(List<LibraryBook> books, String name) => books.firstWhere((b) => b.name == name);

  test('collections gather books, and taking the last one out ends the collection', () async {
    final store = await shelf();
    var books = await store.books();
    await store.addToCollection(named(books, 'Swamp Thing #21').key, 'Moore');
    await store.addToCollection(named(books, 'Daredevil #181').key, 'Classics');
    await store.addToCollection(named(books, 'Swamp Thing #21').key, 'Classics');
    books = await store.books();
    expect(named(books, 'Swamp Thing #21').collections, ['Classics', 'Moore']);
    expect(
      {for (final g in collectionGroups(books)) g.name: g.books.map((b) => b.name).toList()},
      {
        'Classics': ['Daredevil #181', 'Swamp Thing #21'],
        'Moore': ['Swamp Thing #21'],
      },
    );
    await store.removeFromCollection(named(books, 'Swamp Thing #21').key, 'Moore');
    books = await store.books();
    expect(collectionGroups(books).map((g) => g.name), ['Classics']);
  });

  test('a collection travels in the sidecar, and taking a book out wins over an older copy', () {
    CollectionBook c(String name, DateTime added, [DateTime? removed]) =>
        CollectionBook(name: name, contentKey: 'k', addedAt: added, removedAt: removed);
    final laptop = SidecarData(
      contentKey: 'k',
      collections: [c('Moore', DateTime(2026, 1, 1), DateTime(2026, 1, 3)), c('Classics', DateTime(2026, 1, 1))],
    );
    final phone = SidecarData(
      contentKey: 'k',
      collections: [c('Moore', DateTime(2026, 1, 2)), c('Horror', DateTime(2026, 1, 2))],
    );
    for (final m in [mergeSidecars(laptop, phone), mergeSidecars(phone, laptop)]) {
      expect(
        {for (final x in m.collections) x.name: x.removedAt != null},
        {'Moore': true, 'Classics': false, 'Horror': false},
      );
    }
    final path = '${tmp.path}/x.crdb';
    writeSidecar(path, laptop, device: 'd');
    expect(readSidecar(path)!.collections.map((x) => x.name).toSet(), {'Moore', 'Classics'});
  });

  test('a name with spaces around it is the collection without them: the book in it is left as it is', () async {
    final store = await shelf();
    final key = named(await store.books(), 'Swamp Thing #21').key;
    expect(await store.addToCollection(key, 'Miller'), isTrue);
    // Whole seconds are kept, so the row is aged to tell a rewrite apart.
    final longAgo = DateTime(2020, 5, 17, 12);
    await db.update(db.collectionBooks).write(CollectionBooksCompanion(addedAt: Value(longAgo)));

    expect(await store.addToCollection(key, ' Miller '), isFalse);
    final rows = await db.select(db.collectionBooks).get();
    expect(rows.map((r) => (r.name, r.addedAt, r.removedAt)), [('Miller', longAgo, null)]);
  });

  // Since t563 adding a book that is in the collection already no longer
  // moves added_at, so that second add does not outvote a removal made in
  // between on another device. This holds the outcome, whichever way round
  // the sidecars meet.
  test('adding a book again does not outvote a removal made elsewhere after the first add', () async {
    final store = await shelf();
    final key = named(await store.books(), 'Swamp Thing #21').key;
    await store.addToCollection(key, 'Moore');
    await db.update(db.collectionBooks).write(CollectionBooksCompanion(addedAt: Value(DateTime(2026, 1, 1))));
    // The phone takes it out on the 3rd; here it is "added" again later,
    // before the phone's sidecar arrives.
    expect(await store.addToCollection(key, 'Moore'), isFalse);
    final here = SidecarData(contentKey: key, collections: await db.select(db.collectionBooks).get());
    expect(here.collections.single.addedAt, DateTime(2026, 1, 1));
    final phone = SidecarData(
      contentKey: key,
      collections: [
        CollectionBook(name: 'Moore', contentKey: key, addedAt: DateTime(2026, 1, 1), removedAt: DateTime(2026, 1, 3)),
      ],
    );
    for (final m in [mergeSidecars(here, phone), mergeSidecars(phone, here)]) {
      expect(m.collections.single.removedAt, DateTime(2026, 1, 3));
    }

    // Taken out here and added again is a new row time, and that one wins.
    await store.removeFromCollection(key, 'Moore');
    expect(await store.addToCollection(key, 'Moore'), isTrue);
    final again = SidecarData(contentKey: key, collections: await db.select(db.collectionBooks).get());
    expect(again.collections.single.addedAt.isAfter(DateTime(2026, 1, 3)), isTrue);
    for (final m in [mergeSidecars(again, phone), mergeSidecars(phone, again)]) {
      expect(m.collections.single.removedAt, isNull);
    }
  });

  test('reading history: sittings, a glance left out, a quick return joined on', () async {
    final log = ReadLogStore(db);
    final t = DateTime(2026, 9, 24, 20);
    await log.record('a', t, t.add(const Duration(minutes: 20)), 12);
    await log.record('a', t.add(const Duration(minutes: 21)), t.add(const Duration(minutes: 30)), 5); // Joined.
    await log.record('b', t.add(const Duration(hours: 2)), t.add(const Duration(hours: 2, seconds: 1)), 1); // A glance.
    await log.record('a', t.add(const Duration(hours: 3)), t.add(const Duration(hours: 3, minutes: 5)), 3);
    final history = await LibraryStore(db).watchHistory().first;
    expect([for (final h in history) (h.key, h.pages, h.duration.inMinutes)], [('a', 3, 5), ('a', 17, 30)]);
  });

  group('screen', () {
    Future<ProviderContainer> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
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
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> tab(WidgetTester tester, String label) async {
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text(label)));
      await settle(tester);
    }

    testWidgets('add a book to a new collection from its details, see it on the Collections tab', (tester) async {
      await tester.runAsync(shelf);
      await pumpApp(tester);
      await settle(tester);
      await tab(tester, 'Books');
      await tester.tap(find.text('Daredevil #181').first);
      await settle(tester);
      await tester.tap(find.byKey(const Key('addToCollection')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('collectionName')), 'Frank Miller');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(find.widgetWithText(InputChip, 'Frank Miller'), findsOneWidget);

      await tab(tester, 'Collections');
      expect(find.text('Frank Miller'), findsWidgets);
      await tester.tap(find.text('Frank Miller').first); // Selects.
      await settle(tester);
      await tester.tap(find.text('Frank Miller').first); // Opens.
      await settle(tester);
      expect(find.text('Daredevil #181'), findsWidgets);
      expect(find.text('Swamp Thing #21'), findsNothing);
    });

    testWidgets('the History tab lists what was read, newest first', (tester) async {
      final store = (await tester.runAsync(shelf))!;
      final books = (await tester.runAsync(store.books))!;
      // Both sittings today whatever the time: an hour ago is yesterday for
      // the first hour after midnight, and the test then found no "Today".
      final now = DateTime.now();
      final t = DateTime(now.year, now.month, now.day);
      await tester.runAsync(() async {
        await ReadLogStore(db).record(named(books, 'Preacher #1').key, t, t.add(const Duration(minutes: 7)), 2);
        await ReadLogStore(db).record(
          named(books, 'Daredevil #181').key,
          t.add(const Duration(minutes: 30)),
          t.add(const Duration(minutes: 42)),
          4,
        );
      });
      await pumpApp(tester);
      await settle(tester);
      await tab(tester, 'History');
      expect(find.text('Today'), findsOneWidget);
      final daredevil = tester.getTopLeft(find.text('Daredevil #181')).dy;
      final preacher = tester.getTopLeft(find.text('Preacher #1')).dy;
      expect(daredevil, lessThan(preacher));
      expect(find.textContaining('12 min · 4 pages'), findsOneWidget);
    });

    testWidgets('settings turn whole-page steps, sidecar writing and the library pass on and off, and it is kept', (
      tester,
    ) async {
      await tester.runAsync(shelf);
      final c = await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.byKey(const Key('settings')));
      await settle(tester);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.textContaining('Classic computer vision'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('setting-wholePage')));
      await tester.tap(find.byKey(const Key('setting-wholePage')));
      await settle(tester);
      // The time a quick step on a page without panels holds: 5 s.
      await tester.ensureVisible(find.byKey(const Key('setting-pauseSeconds')));
      await tester.tap(find.descendant(of: find.byKey(const Key('setting-pauseSeconds')), matching: find.text('5 s')));
      await settle(tester);
      expect(await tester.runAsync(() => c.read(settingsStoreProvider).loadString(SettingsStore.pauseSeconds)), '5');
      // The wine red and the hold on pages without panels: off.
      await tester.ensureVisible(find.byKey(const Key('setting-pauseWhole')));
      await tester.tap(find.byKey(const Key('setting-pauseWhole')));
      await settle(tester);
      expect(await tester.runAsync(() => c.read(settingsStoreProvider).loadBool(SettingsStore.pauseWhole)), isFalse);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('setting-cleanUp'))).value, isFalse);
      await tester.ensureVisible(find.byKey(const Key('setting-cleanUp')));
      await tester.tap(find.byKey(const Key('setting-cleanUp')));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('setting-sidecars')));
      await tester.tap(find.byKey(const Key('setting-sidecars')));
      await settle(tester);
      final settings = c.read(settingsStoreProvider);
      expect(await tester.runAsync(() => settings.loadBool(SettingsStore.wholePageSteps)), isFalse);
      expect(await tester.runAsync(() => settings.loadBool(SettingsStore.cleanUp)), isTrue);
      expect(await tester.runAsync(() => settings.loadBool(SettingsStore.writeSidecars)), isFalse);
      // Back up: everything but the comics to one file and back.
      await tester.ensureVisible(find.byKey(const Key('setting-importSettings')));
      expect(find.text('Export settings…'), findsOneWidget);
      expect(find.text('Import settings…'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('setting-close')));
      await tester.tap(find.byKey(const Key('setting-close')));
      await settle(tester);
      expect(find.text('Settings'), findsNothing);
    });
  });
}
