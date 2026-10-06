import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
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

  Future<ProviderContainer> pumpApp(WidgetTester tester, {LibraryStore? store}) async {
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
          if (store != null) libraryStoreProvider.overrideWithValue(store),
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

  /// Presses [keys] one straight after the other with no frame in between,
  /// as fast typing does: whatever the app only does on its next frame (a
  /// dialog built, its field focused) has not happened for any of them.
  Future<void> press(WidgetTester tester, String keys) async {
    for (final ch in keys.split('')) {
      final k = switch (ch) {
        '*' => LogicalKeyboardKey.asterisk,
        'M' => LogicalKeyboardKey.keyM,
        _ when RegExp('[a-z]').hasMatch(ch) => LogicalKeyboardKey(ch.codeUnitAt(0)),
        _ => throw ArgumentError(ch),
      };
      await tester.sendKeyEvent(k, character: ch, physicalKey: ch == '*' ? PhysicalKeyboardKey.digit8 : null);
    }
  }

  /// Types [keys] back to back (a sequence like `gc` must not time out in
  /// the resolver), then lets the app catch up.
  Future<void> type(WidgetTester tester, String keys) async {
    await press(tester, keys);
    await tester.pump();
    await settle(tester);
  }

  /// What the collection dialog's name field holds.
  String typedName(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(const Key('collectionName'))).controller!.text;

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

  /// The shelf scanned and the app up with [name] open. [failing] makes
  /// the app's own store one that cannot list the collections.
  Future<(ProviderContainer, LibraryStore, List<LibraryBook>)> open(
    WidgetTester tester,
    String name, {
    bool failing = false,
  }) async {
    final store = (await tester.runAsync(shelf))!;
    final books = (await tester.runAsync(store.books))!;
    final c = await pumpApp(tester, store: failing ? _NoNames(db) : null);
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
    // Added long ago: the table keeps whole seconds, so a row written again
    // within this second would look untouched.
    final longAgo = DateTime(2020, 5, 17, 12);
    await tester.runAsync(
      () => (db.update(
        db.collectionBooks,
      )..where((r) => r.contentKey.equals(key))).write(CollectionBooksCompanion(addedAt: Value(longAgo))),
    );

    await type(tester, 'gc');
    expect(find.widgetWithText(ActionChip, 'Moore'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Miller'), findsNothing);
    // Typed anyway: said, and the row keeps the time it was added.
    await answer(tester, 'Miller');
    expect(c.read(readerProvider).message, 'Already in Miller');
    final after = (await tester.runAsync(() => db.select(db.collectionBooks).get()))!;
    expect(after.where((r) => r.contentKey == key).map((r) => r.addedAt), [longAgo]);

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

  testWidgets('a comic opened from outside the library can be collected, and its collection is offered after', (
    tester,
  ) async {
    final (c, store, books) = await open(tester, 'Daredevil #181');
    final path = writeBook(tmp, 'Loose 1.cbz', 2);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    final loose = c.read(readerProvider).book!.key;

    await type(tester, 'gc');
    await answer(tester, 'Loose ones');
    expect(await rowsOf(tester, loose), ['Loose ones']);
    // One it was taken out of again is no collection any more.
    await tester.runAsync(() async {
      await store.addToCollection(loose, 'Gone');
      await store.removeFromCollection(loose, 'Gone');
    });

    // No library book is in Loose ones, so the library's list of books does
    // not know it; a library comic is offered it all the same.
    expect((await tester.runAsync(store.books))!.expand((b) => b.collections), isEmpty);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(named(books, 'Daredevil #181').path));
    await settle(tester);
    await type(tester, 'gc');
    expect(find.widgetWithText(ActionChip, 'Gone'), findsNothing);
    await tester.tap(find.widgetWithText(ActionChip, 'Loose ones'));
    await settle(tester);
    expect(await rowsOf(tester, named(books, 'Daredevil #181').key), ['Loose ones']);
    await stop(tester);
  });

  testWidgets('keys typed straight after gc, before the dialog is up, are the name and never commands', (tester) async {
    final (c, _, books) = await open(tester, 'Daredevil #181');
    final key = named(books, 'Daredevil #181').key;
    await type(tester, 'l');
    expect(c.read(readerProvider).page, 1);

    // No frame between the keys: the dialog is not built for any of them.
    // As commands h and l would turn the page, p open the grid, e and o
    // more dialogs.
    await press(tester, 'gchellop');
    // Nor is a tap on the page's right edge, which turns it: the Navigator
    // absorbs pointers from the push on, so app.dart need not.
    await tester.tapAt(const Offset(1240, 400), kind: PointerDeviceKind.touch);
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
    await tester.pump();
    await settle(tester);
    expect(c.read(readerProvider).page, 1);
    expect(find.byKey(const Key('pageGrid')), findsNothing);
    expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
    expect(typedName(tester), 'hellop');

    await tester.tap(find.byKey(const Key('collectionAdd')));
    await settle(tester);
    expect(await rowsOf(tester, key), ['hellop']);
    expect(c.read(readerProvider).message, 'Added to hellop');
    expect(c.read(readerProvider).page, 1);
    await stop(tester);
  });

  testWidgets('Backspace, Enter and Esc typed before the dialog is up do what they do in it', (tester) async {
    final (c, _, books) = await open(tester, 'Daredevil #181');
    final key = named(books, 'Daredevil #181').key;

    // Enter on an empty name is no answer; then a name, corrected, and Enter.
    await press(tester, 'gc');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await press(tester, 'lh');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    // Answered, so this one is a command again.
    await press(tester, 'l');
    await tester.pump();
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
    expect(await rowsOf(tester, key), ['l']);
    expect(c.read(readerProvider).page, 1);

    // Esc leaves it, whatever was typed.
    await press(tester, 'gcl');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await press(tester, 'l');
    await tester.pump();
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
    expect(await rowsOf(tester, key), ['l']);
    expect(c.read(readerProvider).page, 2);
    await stop(tester);
  });

  testWidgets('the comic swapped or closed while the dialog is up: nothing is added, keys go on', (tester) async {
    final (c, _, books) = await open(tester, 'Daredevil #181');
    final daredevil = named(books, 'Daredevil #181').key;
    final swamp = named(books, 'Swamp Thing #21');

    await type(tester, 'gc');
    await tester.runAsync(() => c.read(readerProvider.notifier).open(swamp.path));
    await settle(tester);
    expect(c.read(readerProvider).book!.key, swamp.key);
    await answer(tester, 'Wrong comic');
    expect(await rowsOf(tester, daredevil), isEmpty);
    expect(await rowsOf(tester, swamp.key), isEmpty);
    // Keys are with the comic now open.
    await type(tester, 'l');
    expect(c.read(readerProvider).page, 1);

    await type(tester, 'gc');
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await settle(tester);
    expect(c.read(readerProvider).book, isNull);
    await answer(tester, 'No comic');
    expect((await tester.runAsync(() => db.select(db.collectionBooks).get()))!, isEmpty);
    await stop(tester);
  });

  testWidgets('the dialog left by a click beside it gives the keys back, to the reader and to the grid', (
    tester,
  ) async {
    final (c, _, books) = await open(tester, 'Daredevil #181');

    await type(tester, 'gc');
    await tester.tapAt(const Offset(8, 8));
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
    await type(tester, 'l');
    expect(c.read(readerProvider).page, 1);

    await type(tester, 'p');
    await type(tester, 'gc');
    await tester.tapAt(const Offset(8, 8));
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
    expect(find.byKey(const Key('pageGrid')), findsOneWidget);
    await type(tester, 'l');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byKey(const Key('pageGrid')), findsNothing);
    expect(c.read(readerProvider).page, 2);
    expect(await rowsOf(tester, named(books, 'Daredevil #181').key), isEmpty);
    await stop(tester);
  });

  testWidgets('when the collections cannot be listed the dialog says so, and a typed name still works', (tester) async {
    final (c, _, books) = await open(tester, 'Daredevil #181', failing: true);
    final key = named(books, 'Daredevil #181').key;

    await type(tester, 'gc');
    expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
    expect(find.text('Could not list your collections: Bad state: the index is locked'), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);
    await answer(tester, 'Typed anyway');
    expect(await rowsOf(tester, key), ['Typed anyway']);
    expect(c.read(readerProvider).message, 'Added to Typed anyway');

    // Answered before the dialog was ever built, the failure has nobody to
    // tell: it must not surface as an unhandled error either.
    await press(tester, 'gcz');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await settle(tester);
    expect(await rowsOf(tester, key), ['Typed anyway', 'z']);
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

/// A library whose collections cannot be listed, as with a broken index.
class _NoNames extends LibraryStore {
  _NoNames(super.db);

  @override
  Future<List<String>> collectionNames() async => throw StateError('the index is locked');
}
