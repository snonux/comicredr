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

/// `gc` and `*` on the open comic: in the reader, over the page grid (`p`)
/// and over the bookmark list (`M`), by real keys, checked in the index.
void main() {
  late Directory tmp;
  late Directory root;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('open_comic_collections_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<LibraryStore> shelf() async {
    writeBook(root, 'Swamp Thing 21.cbz', 3);
    writeBook(root, 'Daredevil 181.cbz', 4);
    final store = LibraryStore(db);
    await store.addRoot(root.path);
    await LibraryScanner(store, coverDir: '${tmp.path}/covers', workers: 1).scan();
    return store;
  }

  LibraryBook named(List<LibraryBook> books, String name) => books.firstWhere((b) => b.name == name);

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue('${tmp.path}/covers'),
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

  /// Types [keys] back to back (a sequence like `gc` must not time out in
  /// the resolver), then lets the app catch up.
  Future<void> type(WidgetTester tester, String keys) async {
    for (final ch in keys.split('')) {
      final k = switch (ch) {
        '*' => LogicalKeyboardKey.asterisk,
        'g' => LogicalKeyboardKey.keyG,
        'c' => LogicalKeyboardKey.keyC,
        'p' => LogicalKeyboardKey.keyP,
        'l' => LogicalKeyboardKey.keyL,
        'M' => LogicalKeyboardKey.keyM,
        'm' => LogicalKeyboardKey.keyM,
        _ => throw ArgumentError(ch),
      };
      await tester.sendKeyEvent(k, character: ch, physicalKey: ch == '*' ? PhysicalKeyboardKey.digit8 : null);
    }
    await tester.pump();
    await settle(tester);
  }

  /// The live collection rows of the book [key], straight from the table.
  Future<List<String>> rowsOf(WidgetTester tester, String key) async {
    final rows = (await tester.runAsync(() => db.select(db.collectionBooks).get()))!;
    return [
      for (final r in rows)
        if (r.contentKey == key && r.removedAt == null) r.name,
    ]..sort();
  }

  /// Types [name] into the collection dialog and presses Enter.
  Future<void> answer(WidgetTester tester, String name) async {
    expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('collectionName')), name);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
  }

  /// Takes the app down so the background detector's rest timer runs out.
  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  Future<(ProviderContainer, LibraryStore, List<LibraryBook>)> open(WidgetTester tester, String name) async {
    final store = (await tester.runAsync(shelf))!;
    final books = (await tester.runAsync(store.books))!;
    final c = await pumpApp(tester);
    await settle(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(named(books, name).path));
    await settle(tester);
    return (c, store, books);
  }

  testWidgets('gc in the reader: a new collection, Esc changes nothing, keys go on after', (tester) async {
    final (c, _, books) = await open(tester, 'Daredevil #181');
    final key = named(books, 'Daredevil #181').key;

    // Esc in the dialog: nothing written, and the comic stays open.
    await type(tester, 'gc');
    expect(find.text('Add Daredevil #181 to a collection'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
    expect(await rowsOf(tester, key), isEmpty);
    expect(c.read(readerProvider).book, isNotNull);

    // Cancel: the same.
    await type(tester, 'gc');
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(await rowsOf(tester, key), isEmpty);

    // An empty name is no answer: the dialog stays, nothing is written.
    await type(tester, 'gc');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
    expect(await rowsOf(tester, key), isEmpty);

    await answer(tester, 'To read');
    expect(await rowsOf(tester, key), ['To read']);
    expect(c.read(readerProvider).message, 'Added to To read');
    // The other comic is untouched.
    expect(await rowsOf(tester, named(books, 'Swamp Thing #21').key), isEmpty);

    // Keys are back with the reader.
    expect(c.read(readerProvider).page, 0);
    await type(tester, 'l');
    expect(c.read(readerProvider).page, 1);
    await stop(tester);
  });

  testWidgets('gc offers the collections there are, but not one the comic is in; typing that one says so', (
    tester,
  ) async {
    final (c, store, books) = await open(tester, 'Daredevil #181');
    final key = named(books, 'Daredevil #181').key;
    await tester.runAsync(() => store.addToCollection(named(books, 'Swamp Thing #21').key, 'Moore'));
    await tester.runAsync(() => store.addToCollection(key, 'Miller'));
    final before = (await tester.runAsync(() => db.select(db.collectionBooks).get()))!;

    await type(tester, 'gc');
    expect(find.widgetWithText(ActionChip, 'Moore'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Miller'), findsNothing);
    // Typed anyway: said, and the row keeps the time it was added.
    await answer(tester, 'Miller');
    expect(c.read(readerProvider).message, 'Already in Miller');
    final after = (await tester.runAsync(() => db.select(db.collectionBooks).get()))!;
    expect(after.firstWhere((r) => r.contentKey == key).addedAt, before.firstWhere((r) => r.contentKey == key).addedAt);

    // A chip picks one there is.
    await type(tester, 'gc');
    await tester.tap(find.widgetWithText(ActionChip, 'Moore'));
    await settle(tester);
    expect(await rowsOf(tester, key), ['Miller', 'Moore']);
    await stop(tester);
  });

  testWidgets('gc and * over the page grid act on the open comic and leave the grid up', (tester) async {
    final (c, _, books) = await open(tester, 'Daredevil #181');
    final key = named(books, 'Daredevil #181').key;

    await type(tester, 'p');
    expect(find.byKey(const Key('pageGrid')), findsOneWidget);

    await type(tester, '*');
    expect(await rowsOf(tester, key), [favouritesCollection]);
    expect(c.read(readerProvider).message, contains('Added to Favourites'));
    expect(find.byKey(const Key('pageGrid')), findsOneWidget);
    // Twice takes it out again.
    await type(tester, '*');
    expect(await rowsOf(tester, key), isEmpty);
    expect(c.read(readerProvider).message, 'Taken out of Favourites');

    await type(tester, 'gc');
    await answer(tester, 'Grid picks');
    expect(await rowsOf(tester, key), ['Grid picks']);
    expect(find.byKey(const Key('pageGrid')), findsOneWidget);

    // Keys are back with the grid: l moves its selection, Enter goes there.
    await type(tester, 'l');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byKey(const Key('pageGrid')), findsNothing);
    expect(c.read(readerProvider).page, 1);
    await stop(tester);
  });

  testWidgets('gc and * over the bookmark list act on the open comic', (tester) async {
    final (c, _, books) = await open(tester, 'Daredevil #181');
    final key = named(books, 'Daredevil #181').key;

    await type(tester, 'M');
    expect(find.byKey(const Key('bookmarkList')), findsOneWidget);
    await type(tester, '*');
    expect(await rowsOf(tester, key), [favouritesCollection]);
    await type(tester, 'gc');
    await answer(tester, 'Marked up');
    expect(await rowsOf(tester, key), [favouritesCollection, 'Marked up']);
    expect(find.byKey(const Key('bookmarkList')), findsOneWidget);
    expect(c.read(readerProvider).book, isNotNull);
    await stop(tester);
  });

  testWidgets('a comic opened from outside the library can be collected too', (tester) async {
    final (c, _, _) = await open(tester, 'Daredevil #181');
    final path = writeBook(tmp, 'Loose 1.cbz', 2);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    final key = c.read(readerProvider).book!.key;

    await type(tester, 'gc');
    await answer(tester, 'Loose ones');
    expect(await rowsOf(tester, key), ['Loose ones']);
    await stop(tester);
  });

  testWidgets('with no comic open and no cover selected, gc and * do nothing', (tester) async {
    final store = (await tester.runAsync(shelf))!;
    await pumpApp(tester);
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('History')));
    await settle(tester);

    await type(tester, 'gc');
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
    await type(tester, '*');
    expect((await tester.runAsync(() => db.select(db.collectionBooks).get()))!, isEmpty);
    expect((await tester.runAsync(store.books))!.every((b) => b.collections.isEmpty), isTrue);
  });
}
