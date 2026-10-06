import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/bulk_actions.dart';
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
/// And `gc` in the library, which asks through the same question: the same
/// names offered, the same typing ahead.
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

  /// The sidecars the app was last pumped with: none are written, the ones
  /// that would have been are listed.
  late _Sidecars sidecars;

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
          sidecarSyncProvider.overrideWith((ref) => sidecars = _Sidecars(db, ref.watch(progressStoreProvider))),
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
        ' ' => LogicalKeyboardKey.space,
        _ when RegExp('[a-zA-Z]').hasMatch(ch) => LogicalKeyboardKey(ch.toLowerCase().codeUnitAt(0)),
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

  /// Makes every collection row of [key] one added long ago. The table
  /// keeps whole seconds, so a row written again within the second of the
  /// test would otherwise look untouched.
  final longAgo = DateTime(2020, 5, 17, 12);
  Future<void> age(WidgetTester tester, String key) => tester.runAsync(
    () => (db.update(
      db.collectionBooks,
    )..where((r) => r.contentKey.equals(key))).write(CollectionBooksCompanion(addedAt: Value(longAgo))),
  );

  /// The row of [key] in the collection [name], live or taken out.
  Future<CollectionBook> rowOf(WidgetTester tester, String key, String name) async {
    final rows = (await tester.runAsync(() => db.select(db.collectionBooks).get()))!;
    return rows.singleWhere((r) => r.contentKey == key && r.name == name);
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
    await age(tester, key);

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

  testWidgets(
    'before the dialog is up only what a name is made of goes in: no Ctrl, Alt or Meta key, no Tab or Delete',
    (tester) async {
      final (c, _, books) = await open(tester, 'Daredevil #181');
      final key = named(books, 'Daredevil #181').key;

      // All of it with no frame in between, so the field has no focus yet
      // and every key comes through the reader's keyboard.
      await press(tester, 'gc');
      // A key with Ctrl, Alt or Meta held is no letter of the name (and as a
      // command Ctrl+A would mark, in the library).
      for (final (modifier, letter) in [
        (LogicalKeyboardKey.controlLeft, 'a'),
        (LogicalKeyboardKey.altLeft, 'b'),
        (LogicalKeyboardKey.metaLeft, 'c'),
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await press(tester, letter);
        await tester.sendKeyUpEvent(modifier);
      }
      // Tab and Delete, which come with a control character on some platforms.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab, character: '\t');
      await tester.sendKeyEvent(LogicalKeyboardKey.delete, character: '\x7f');
      // Shift and a letter is a capital; Shift alone is nothing.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'X');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await press(tester, ' ');
      // A key held down repeats, as it does in the field.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyM, character: 'm');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyM, character: 'm');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyM);
      await press(tester, ' ');
      expect(find.byKey(const Key('collectionDialog')), findsNothing);
      await tester.pump();
      await settle(tester);

      expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
      expect(typedName(tester), 'X mm ');
      // None of them was a command either: no page turned, no bookmark list (M).
      expect(c.read(readerProvider).page, 0);
      expect(find.byKey(const Key('bookmarkList')), findsNothing);
      await tester.tap(find.byKey(const Key('collectionAdd')));
      await settle(tester);
      expect(await rowsOf(tester, key), ['X mm']);
      await stop(tester);
    },
  );

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
    // Said, on the status line of the comic now open, not passed over.
    expect(c.read(readerProvider).message, 'Daredevil #181 is no longer open: not added to Wrong comic');
    // Keys are with the comic now open.
    await type(tester, 'l');
    expect(c.read(readerProvider).page, 1);

    await type(tester, 'gc');
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await settle(tester);
    expect(c.read(readerProvider).book, isNull);
    await answer(tester, 'No comic');
    expect((await tester.runAsync(() => db.select(db.collectionBooks).get()))!, isEmpty);
    // Said in the library, where the reader's status line is gone.
    expect(find.widgetWithText(SnackBar, 'Swamp Thing #21 is no longer open: not added to No comic'), findsOneWidget);
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

  /// The library up over the shelf with no comic open: the Folders tab,
  /// inside the library folder, a comic's cover selected.
  /// [app] is the store the app itself gets, when not the plain one.
  Future<(LibraryStore, List<LibraryBook>)> library(WidgetTester tester, {LibraryStore? app}) async {
    final store = (await tester.runAsync(shelf))!;
    final books = (await tester.runAsync(store.books))!;
    await pumpApp(tester, store: app);
    await settle(tester);
    await tester.tap(find.text('Folders'));
    await settle(tester);
    await type(tester, 'l');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byKey(const Key('breadcrumb')), findsOneWidget);
    return (store, books);
  }

  /// The comic the collection dialog now up is about, by its title.
  LibraryBook asked(WidgetTester tester, List<LibraryBook> books) =>
      books.singleWhere((b) => find.text('Add ${b.name} to a collection').evaluate().isNotEmpty);

  testWidgets('gc on a cover in the library: a name typed straight after it is the name, never library commands', (
    tester,
  ) async {
    final (_, books) = await library(tester);

    // No frame between the keys. As commands gd would ask to delete the
    // comic, X to reset it, and l would move the selection.
    await press(tester, 'gcgd X l');
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
    await tester.pump();
    await settle(tester);
    // The one dialog up is the collection question, with all of it typed.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
    expect(typedName(tester), 'gd X l');
    final book = asked(tester, books);

    await tester.tap(find.byKey(const Key('collectionAdd')));
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(await rowsOf(tester, book.key), ['gd X l']);
    expect(find.widgetWithText(SnackBar, '1 comic added to gd X l'), findsOneWidget);
    for (final b in books) {
      expect(File(b.path).existsSync(), isTrue, reason: '${b.name} deleted');
    }

    // Answered by Enter before the dialog was ever built, the key after it
    // is a command again: gc on the same cover, so the selection never moved.
    await press(tester, 'gcz');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(await rowsOf(tester, book.key), ['gd X l', 'z']);
    await stop(tester);
  });

  testWidgets('the library offers a collection only a comic outside the library is in, not one the cover is in', (
    tester,
  ) async {
    final (store, books) = await library(tester);
    // No file in any library folder has this content key.
    await tester.runAsync(() => store.addToCollection('a-comic-from-elsewhere', 'Loose ones'));
    // The library's own list reads again after the write: let it finish.
    await settle(tester);
    expect((await tester.runAsync(store.books))!.expand((b) => b.collections), isEmpty);

    await type(tester, 'gc');
    final book = asked(tester, books);
    expect(find.widgetWithText(ActionChip, 'Loose ones'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionChip, 'Loose ones'));
    await settle(tester);
    expect(await rowsOf(tester, book.key), ['Loose ones']);

    // Now it is in it, so it is not offered again; the button in the
    // details pane asks the same question as gc.
    await tester.tap(find.byKey(const Key('addToCollection')));
    await tester.pump();
    await settle(tester);
    expect(asked(tester, books).key, book.key);
    expect(find.widgetWithText(ActionChip, 'Loose ones'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsNothing);
    expect(await rowsOf(tester, book.key), ['Loose ones']);
    await stop(tester);
  });

  testWidgets('gc on marked comics: typed ahead too, offered what not all of them are in, marks cleared on an answer', (
    tester,
  ) async {
    final (store, books) = await library(tester);
    final [first, second] = books;
    await tester.runAsync(() async {
      await store.addToCollection(first.key, 'Both');
      await store.addToCollection(second.key, 'Both');
      await store.addToCollection(first.key, 'Only one');
    });
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('2 selected'), findsOneWidget);

    // Left with Esc before the dialog is up: nothing written, marks kept.
    await press(tester, 'gcx');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('2 selected'), findsOneWidget);
    expect(await rowsOf(tester, second.key), ['Both']);

    await press(tester, 'gcxl');
    await tester.pump();
    await settle(tester);
    expect(find.text('Add 2 comics to a collection'), findsOneWidget);
    expect(typedName(tester), 'xl');
    expect(find.widgetWithText(ActionChip, 'Only one'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Both'), findsNothing);
    await tester.tap(find.byKey(const Key('collectionAdd')));
    await settle(tester);
    expect(await rowsOf(tester, first.key), ['Both', 'Only one', 'xl']);
    expect(await rowsOf(tester, second.key), ['Both', 'xl']);
    expect(find.text('2 selected'), findsNothing);
    await stop(tester);
  });

  testWidgets('gc on a cover with a collection it is in already says so and leaves the row and the sidecar alone', (
    tester,
  ) async {
    final (store, books) = await library(tester);
    final wrote = sidecars.wrote;
    await type(tester, 'gc');
    final book = asked(tester, books);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tester.runAsync(() => store.addToCollection(book.key, 'Miller'));
    await age(tester, book.key);
    await settle(tester);

    // Not offered, typed anyway.
    await type(tester, 'gc');
    expect(find.widgetWithText(ActionChip, 'Miller'), findsNothing);
    await answer(tester, 'Miller');
    expect(find.widgetWithText(SnackBar, 'Already in Miller'), findsOneWidget);
    final row = await rowOf(tester, book.key, 'Miller');
    expect((row.addedAt, row.removedAt), (longAgo, null));
    expect(wrote, isEmpty);

    // The details' button goes the same way.
    await tester.tap(find.byKey(const Key('addToCollection')));
    await tester.pump();
    await settle(tester);
    await answer(tester, ' Miller ');
    expect(find.widgetWithText(SnackBar, 'Already in Miller'), findsOneWidget);
    expect((await rowOf(tester, book.key, 'Miller')).addedAt, longAgo);
    expect(wrote, isEmpty);

    // One it is not in is added, and that one's sidecar written.
    await tester.tap(find.byKey(const Key('addToCollection')));
    await tester.pump();
    await settle(tester);
    await answer(tester, 'New one');
    expect(find.widgetWithText(SnackBar, '1 comic added to New one'), findsOneWidget);
    expect((await rowOf(tester, book.key, 'New one')).addedAt.isAfter(longAgo), isTrue);
    expect((await rowOf(tester, book.key, 'Miller')).addedAt, longAgo);
    expect(wrote, [book.key]);
    await stop(tester);
  });

  testWidgets('gc on marked comics adds the ones not in the collection and counts only those', (tester) async {
    final (store, books) = await library(tester);
    final [first, second] = books;
    final wrote = sidecars.wrote;
    await tester.runAsync(() => store.addToCollection(first.key, 'Some'));
    await age(tester, first.key);
    await settle(tester);

    Future<void> markAll() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.text('2 selected'), findsOneWidget);
    }

    // One of the two is in it: offered still, the other one added.
    await markAll();
    await type(tester, 'gc');
    await tester.tap(find.widgetWithText(ActionChip, 'Some'));
    await settle(tester);
    expect(find.widgetWithText(SnackBar, '1 comic added to Some; 1 was already in it'), findsOneWidget);
    expect((await rowOf(tester, first.key, 'Some')).addedAt, longAgo);
    expect((await rowOf(tester, second.key, 'Some')).addedAt.isAfter(longAgo), isTrue);
    expect(wrote, [second.key]);
    expect(find.text('2 selected'), findsNothing);

    // Both in it now: said, nothing written, and the marks go all the same.
    await age(tester, second.key);
    wrote.clear();
    await markAll();
    await type(tester, 'gc');
    expect(find.widgetWithText(ActionChip, 'Some'), findsNothing);
    await answer(tester, 'Some');
    expect(find.widgetWithText(SnackBar, 'All 2 comics are already in Some'), findsOneWidget);
    for (final b in books) {
      expect((await rowOf(tester, b.key, 'Some')).addedAt, longAgo);
    }
    expect(wrote, isEmpty);
    expect(find.text('2 selected'), findsNothing);
    await stop(tester);
  });

  const why = 'the library could not be updated';

  testWidgets('the index failing part of the way: the one added stays and is said, its sidecar written, marks kept', (
    tester,
  ) async {
    writeBook(root, 'Preacher 1.cbz', 2);
    final refusing = _Refusing(db, failOn: 2);
    final (store, books) = await library(tester, app: refusing);
    expect(books, hasLength(3));
    // The order collectBooks walks the marked comics in: by path.
    final [first, second, third] = [...books]..sort((a, b) => a.path.compareTo(b.path));
    final wrote = sidecars.wrote;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('3 selected'), findsOneWidget);

    /// `gc` into [name] with the [n]th comic refused; the notice must be [said].
    Future<void> refused(int n, String name, String said) async {
      wrote.clear();
      refusing
        ..tried.clear()
        ..failOn = n;
      await type(tester, 'gc');
      await answer(tester, name);
      await tester.pump();
      expect(find.widgetWithText(SnackBar, said), findsOneWidget);
      // No exception text in front of the reader.
      expect(find.textContaining('Bad state'), findsNothing);
      expect(find.textContaining('index is locked'), findsNothing);
      expect(find.text('3 selected'), findsOneWidget);
    }

    Future<List<String>> inIt(String name) async => [
      for (final r in (await tester.runAsync(() => db.select(db.collectionBooks).get()))!)
        if (r.name == name && r.removedAt == null) r.contentKey,
    ];

    // The second of the three is refused: the third is never tried, and the
    // one added is the first of them.
    await refused(2, 'Broken', '1 comic added to Broken; 2 not added: $why');
    expect(refusing.tried, [first.key, second.key]);
    expect(await inIt('Broken'), [first.key]);
    expect(wrote, [first.key]);

    // Refused at the first: none added, said of all three, nothing written.
    await refused(1, 'Other', 'Could not add the 3 comics to Other: $why');
    expect(await inIt('Other'), isEmpty);
    expect(wrote, isEmpty);

    // The first is in it already, the second refused: one of the three is
    // in it, and that is not passed off as "could not add the 3".
    await refused(2, 'Broken', '1 was already in Broken; 2 not added: $why');
    expect(await inIt('Broken'), [first.key]);
    expect(wrote, isEmpty);

    // One added, one in it already, the third refused: all three counted.
    await tester.runAsync(() => store.addToCollection(second.key, 'Mixed'));
    await settle(tester);
    await refused(3, 'Mixed', '1 comic added to Mixed; 1 was already in it; 1 not added: $why');
    expect(refusing.tried, [first.key, second.key, third.key]);
    expect((await inIt('Mixed')).toSet(), {first.key, second.key});
    expect(wrote, [first.key]);
    await stop(tester);
  });

  testWidgets('two marked and the second refused: one added, "1 not added", not "the rest"', (tester) async {
    final refusing = _Refusing(db, failOn: 2);
    final (_, books) = await library(tester, app: refusing);
    final [first, second] = [...books]..sort((a, b) => a.path.compareTo(b.path));
    final wrote = sidecars.wrote;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);

    await type(tester, 'gc');
    await answer(tester, 'Pair');
    await tester.pump();
    expect(find.widgetWithText(SnackBar, '1 comic added to Pair; 1 not added: $why'), findsOneWidget);
    expect(find.textContaining('the rest'), findsNothing);
    expect(await rowsOf(tester, first.key), ['Pair']);
    expect(await rowsOf(tester, second.key), isEmpty);
    expect(wrote, [first.key]);
    expect(find.text('2 selected'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('the index failing for the one comic of the details: named in the notice, never "them"', (tester) async {
    final (_, books) = await library(tester, app: _Refusing(db, failOn: 1));
    final wrote = sidecars.wrote;
    await tester.tap(find.byKey(const Key('addToCollection')));
    await tester.pump();
    await settle(tester);
    final book = asked(tester, books);
    await answer(tester, 'Miller');
    await tester.pump();
    expect(find.widgetWithText(SnackBar, 'Could not add ${book.name} to Miller: $why'), findsOneWidget);
    expect(find.textContaining('them'), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(await rowsOf(tester, book.key), isEmpty);
    expect(wrote, isEmpty);
    await stop(tester);
  });

  test('notAddedNotice counts added, already in and not added, each in its own number', () {
    String said(int added, int already, int notAdded, {String? only}) =>
        notAddedNotice(added: added, already: already, notAdded: notAdded, name: 'X', only: only);
    // (added, already in, not added) to the notice, for every shape.
    final cases = {
      (0, 0, 2): 'Could not add the 2 comics to X: $why',
      (0, 0, 3): 'Could not add the 3 comics to X: $why',
      (1, 0, 1): '1 comic added to X; 1 not added: $why',
      (1, 0, 2): '1 comic added to X; 2 not added: $why',
      (2, 0, 1): '2 comics added to X; 1 not added: $why',
      (0, 1, 1): '1 was already in X; 1 not added: $why',
      (0, 1, 2): '1 was already in X; 2 not added: $why',
      (0, 2, 1): '2 were already in X; 1 not added: $why',
      (1, 1, 1): '1 comic added to X; 1 was already in it; 1 not added: $why',
      (2, 3, 4): '2 comics added to X; 3 were already in it; 4 not added: $why',
    };
    for (final MapEntry(key: (added, already, notAdded), value: text) in cases.entries) {
      expect(said(added, already, notAdded), text);
    }
    // The details' one comic is named, never counted.
    expect(said(0, 0, 1, only: 'Daredevil #181'), 'Could not add Daredevil #181 to X: $why');
  });

  testWidgets('no second question gets asked while one is on its way: neither by key nor by a second tap', (
    tester,
  ) async {
    final (_, books) = await library(tester);
    // Two taps on the details' button with no frame between them: the
    // Navigator absorbs the second, the asker itself refuses nothing.
    final button = tester.getCenter(find.byKey(const Key('addToCollection')));
    await tester.tapAt(button);
    await tester.tapAt(button);
    await tester.pump();
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);

    // gc twice: the second is the name's first two letters.
    await press(tester, 'gcgc');
    await tester.pump();
    await settle(tester);
    expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
    expect(typedName(tester), 'gc');
    final book = asked(tester, books);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(await rowsOf(tester, book.key), isEmpty);
    await stop(tester);
  });

  testWidgets('gc with a collection the cover was taken out of puts it in again', (tester) async {
    final (store, books) = await library(tester);
    await type(tester, 'gc');
    final book = asked(tester, books);
    await answer(tester, 'Back again');
    await tester.runAsync(() => store.removeFromCollection(book.key, 'Back again'));
    await age(tester, book.key);
    await settle(tester);
    expect((await rowOf(tester, book.key, 'Back again')).removedAt, isNotNull);

    await type(tester, 'gc');
    await answer(tester, 'Back again');
    expect(find.widgetWithText(SnackBar, '1 comic added to Back again'), findsOneWidget);
    final row = await rowOf(tester, book.key, 'Back again');
    expect(row.removedAt, isNull);
    expect(row.addedAt.isAfter(longAgo), isTrue);
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

/// A library whose index refuses the [failOn]th comic put in a collection
/// (counted in [tried]) and takes the ones before it.
class _Refusing extends LibraryStore {
  _Refusing(super.db, {required this.failOn});

  int failOn;

  /// The comics asked for since it was last cleared, in order, the refused
  /// one included.
  final tried = <String>[];

  @override
  Future<bool> addToCollection(String contentKey, String name) {
    tried.add(contentKey);
    if (tried.length == failOn) throw StateError('the index is locked');
    return super.addToCollection(contentKey, name);
  }
}

/// Sidecars that are never read or written; [wrote] lists the comics whose
/// sidecar the library asked to have written at once (`writeBeside`).
class _Sidecars extends SidecarSync {
  _Sidecars(super.db, ProgressStore progress) : super(progress: progress);

  final wrote = <String>[];

  @override
  Future<SidecarImport> attach(String path, String contentKey, {required bool folder, bool whole = false}) async =>
      SidecarImport.none;

  @override
  void touch(String contentKey) {}

  @override
  Future<bool> write(String contentKey) async {
    wrote.add(contentKey);
    return true;
  }

  @override
  Future<void> flush() => progress.flush();
}
