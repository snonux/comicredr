import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Favourites: the Favourites collection, `*` in the reader and on a
/// cover, `gf` and the header's star, taking a comic out there.
void main() {
  late Directory tmp;
  late Directory root;
  late String covers;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('favourites_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    covers = '${tmp.path}/covers';
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
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

  test('favourites are the Favourites collection', () async {
    final store = await shelf();
    var books = await store.books();
    final daredevil = named(books, 'Daredevil #181').key;
    expect(await store.isFavourite(daredevil), isFalse);
    await store.setFavourite(daredevil, true);
    await store.addToCollection(named(books, 'Preacher #1').key, favouritesCollection); // By hand, the same.
    books = await store.books();
    expect(named(books, 'Daredevil #181').favourite, isTrue);
    expect(named(books, 'Daredevil #181').collections, ['Favourites']);
    expect(named(books, 'Preacher #1').favourite, isTrue);
    expect(named(books, 'Swamp Thing #21').favourite, isFalse);
    expect(collectionGroups(books).single.books.map((b) => b.name), ['Daredevil #181', 'Preacher #1']);
    await store.setFavourite(daredevil, false);
    expect(await store.isFavourite(daredevil), isFalse);
    // The row stays with the time it was taken out, for the sidecar merge.
    final rows = await db.select(db.collectionBooks).get();
    expect(rows.where((r) => r.contentKey == daredevil).single.removedAt, isNotNull);
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

    Future<void> type(WidgetTester tester, String keys) async {
      for (final ch in keys.split('')) {
        final k = switch (ch) {
          '*' => LogicalKeyboardKey.asterisk,
          'g' => LogicalKeyboardKey.keyG,
          'f' => LogicalKeyboardKey.keyF,
          'x' => LogicalKeyboardKey.keyX,
          'l' => LogicalKeyboardKey.keyL,
          _ => throw ArgumentError(ch),
        };
        await tester.sendKeyEvent(k, character: ch, physicalKey: ch == '*' ? PhysicalKeyboardKey.digit8 : null);
        await tester.pump();
      }
      await settle(tester);
    }

    Future<List<String>> favourites(LibraryStore store) async => [
      for (final b in await store.books())
        if (b.favourite) b.name,
    ]..sort();

    testWidgets('* in the reader and on a cover, gf lists them, x takes one out and Undo puts it back', (tester) async {
      final store = (await tester.runAsync(shelf))!;
      final books = (await tester.runAsync(store.books))!;
      final c = await pumpApp(tester);
      await settle(tester);

      // In the reader.
      await tester.runAsync(() => c.read(readerProvider.notifier).open(named(books, 'Preacher #1').path));
      await settle(tester);
      await type(tester, '*');
      expect(c.read(readerProvider).message, contains('Added to Favourites'));
      expect(await tester.runAsync(() => favourites(store)), ['Preacher #1']);
      // gf from the reader closes the book and shows them.
      await type(tester, 'gf');
      expect(c.read(readerProvider).book, isNull);
      expect(find.byKey(const Key('favouriteBadge')), findsOneWidget);

      // On a cover in the library: the Books tab, the first cover.
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Books')));
      await settle(tester);
      await type(tester, 'l'); // Selects the first cover: Daredevil.
      await type(tester, '*');
      expect(await tester.runAsync(() => favourites(store)), ['Daredevil #181', 'Preacher #1']);
      expect(find.byKey(const Key('favouriteBadge')), findsNWidgets(2));

      // The header's star opens them.
      await tester.tap(find.byKey(const Key('favourites')));
      await settle(tester);
      expect(find.text('Swamp Thing #21'), findsNothing);
      expect(find.text('Daredevil #181'), findsWidgets);
      expect(find.text('Preacher #1'), findsWidgets);

      // x takes the selected one (the first) out, and it leaves at once.
      await type(tester, 'x');
      expect(await tester.runAsync(() => favourites(store)), ['Preacher #1']);
      expect(find.text('Daredevil #181'), findsNothing);
      expect(find.textContaining('taken out of Favourites'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(await tester.runAsync(() => favourites(store)), ['Daredevil #181', 'Preacher #1']);

      // The star in the details takes one out too.
      await tester.tap(find.text('Preacher #1').first);
      await settle(tester);
      await tester.tap(find.byKey(const Key('favourite')));
      await settle(tester);
      expect(await tester.runAsync(() => favourites(store)), ['Daredevil #181']);

      // Esc goes back out to the collections, where Favourites is one.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text('Favourites'), findsWidgets);
    });
  });
}
