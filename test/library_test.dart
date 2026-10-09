import 'dart:io';

import 'package:archive/archive.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/library/library_screen.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

/// A CBZ with a ComicInfo.xml naming its series and number.
String writeInfoBook(Directory dir, String name, int pages, {required String series, required String number}) {
  final a = Archive();
  for (var i = 1; i <= pages; i++) {
    a.addFile(ArchiveFile.bytes('page$i.png', [...png, i, number.hashCode & 0xff]));
  }
  a.addFile(
    ArchiveFile.string(
      'ComicInfo.xml',
      '<ComicInfo><Series>$series</Series><Number>$number</Number><Writer>Will Eisner</Writer></ComicInfo>',
    ),
  );
  final path = '${dir.path}/$name';
  File(path).writeAsBytesSync(ZipEncoder().encodeBytes(a));
  return path;
}

/// A shelf with a two-book series (named by ComicInfo, files named
/// otherwise), a book in a subfolder, a folder book, a README and a RAR.
void writeShelf(Directory root) {
  writeInfoBook(root, 'spirit-a.cbz', 3, series: 'The Spirit', number: '2');
  writeInfoBook(root, 'spirit-b.cbz', 4, series: 'The Spirit', number: '1');
  Directory('${root.path}/Indie').createSync();
  writeBook(Directory('${root.path}/Indie'), 'Barefoot Bride.cbz', 5);
  final folder = Directory('${root.path}/Pepper Carrot e06')..createSync();
  for (var i = 1; i <= 2; i++) {
    File('${folder.path}/p$i.png').writeAsBytesSync([...png, i]);
  }
  File('${root.path}/README.txt').writeAsStringSync('not a comic');
  File('${root.path}/real.cbr').writeAsBytesSync([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0, 0, 0]);
}

void main() {
  test("the phone's bottom tabs have labels short enough not to break", () {
    // Seven tabs share a 411 dp phone: "Collections" wrapped as "Collectio ns".
    for (final t in LibraryTab.values) {
      expect(t.short.length, lessThanOrEqualTo(7), reason: t.label);
    }
  });

  late Directory tmp;
  late Directory root;
  late String covers;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('library_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    covers = '${tmp.path}/covers';
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('scanner', () {
    test('finds books, groups series, writes covers and skips what it cannot read', () async {
      writeShelf(root);
      final store = LibraryStore(db);
      final scanner = LibraryScanner(store, coverDir: covers, workers: 2);
      await store.addRoot(root.path);
      await scanner.scan();

      final books = await store.books();
      expect(books.map((b) => b.name).toSet(), {
        'The Spirit #1',
        'The Spirit #2',
        'Barefoot Bride',
        'Pepper Carrot #6',
      });
      final spirit = LibrarySeries.group(books).firstWhere((s) => s.name == 'The Spirit');
      expect(spirit.books.map((b) => b.number), ['1', '2'], reason: 'series order, not file order');
      expect(spirit.books.first.writers, ['Will Eisner']);
      expect(books.firstWhere((b) => b.name == 'Pepper Carrot #6').format, 'folder');
      for (final b in books) {
        expect(File('$covers/${b.key}.jpg').existsSync(), isTrue, reason: 'cover for ${b.name}');
      }
      expect(scanner.last.failed.map((f) => f.$1.split('/').last), ['real.cbr']);
      expect(scanner.last.failed.single.$2, contains('RAR'));

      // Phase one finds nothing new: no book is opened again.
      await scanner.scan();
      expect(scanner.last.total, 1, reason: 'only the RAR, which is retried');
      await scanner.dispose();
    });

    test('a renamed book keeps its key and progress; a deleted one leaves the library', () async {
      final store = LibraryStore(db);
      final scanner = LibraryScanner(store, coverDir: covers, workers: 1);
      final path = writeBook(root, 'Daredevil 181.cbz', 4);
      writeBook(root, 'Swamp Thing 21.cbz', 3);
      await store.addRoot(root.path);
      await scanner.scan();
      final key = (await store.books()).firstWhere((b) => b.series == 'Daredevil').key;
      await db
          .into(db.progress)
          .insert(ProgressCompanion.insert(contentKey: key, page: 2, percent: 0.6, updatedAt: DateTime.now()));

      File(path).renameSync('${root.path}/Daredevil 181 (1982).cbz');
      await scanner.scan();
      final moved = (await store.books()).firstWhere((b) => b.series == 'Daredevil');
      expect((moved.key, moved.path.endsWith('(1982).cbz'), moved.page, moved.inProgress), (key, true, 2, true));

      File('${root.path}/Swamp Thing 21.cbz').deleteSync();
      await scanner.scan();
      expect((await store.books()).map((b) => b.series), ['Daredevil']);
      await scanner.dispose();
    });

    test('a loose image beside comics is a one-page comic; a folder of only images stays one book', () async {
      final store = LibraryStore(db);
      final scanner = LibraryScanner(store, coverDir: covers, workers: 1);
      writeBook(root, 'Daredevil 181.cbz', 4);
      File('${root.path}/Sunday Strip 7.png').writeAsBytesSync([...png, 7]);
      File('${root.path}/cat.gif').writeAsBytesSync([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // Not a comic.
      final folder = Directory('${root.path}/Pepper Carrot e06')..createSync();
      for (var i = 1; i <= 3; i++) {
        File('${folder.path}/p$i.png').writeAsBytesSync([...png, i]);
      }
      await store.addRoot(root.path);
      await scanner.scan();

      final books = {for (final b in await store.books()) b.name: b};
      expect(books.keys.toSet(), {'Daredevil #181', 'Sunday Strip #7', 'Pepper Carrot #6'});
      expect((books['Sunday Strip #7']!.format, books['Sunday Strip #7']!.pageCount), ('image', 1));
      expect((books['Pepper Carrot #6']!.format, books['Pepper Carrot #6']!.pageCount), ('folder', 3));
      expect(File('$covers/${books['Sunday Strip #7']!.key}.jpg').existsSync(), isTrue);
      expect(scanner.last.failed, isEmpty);
      await scanner.dispose();
    });

    test('removing a folder forgets its books', () async {
      final store = LibraryStore(db);
      final scanner = LibraryScanner(store, coverDir: covers, workers: 1);
      writeBook(root, 'Solo.cbz', 2);
      final id = await store.addRoot(root.path);
      await scanner.scan();
      expect(await store.books(), hasLength(1));
      await store.removeRoot(id);
      expect(await store.books(), isEmpty);
      await scanner.dispose();
    });
  });

  group('screen', () {
    Future<ProviderContainer> pumpApp(
      WidgetTester tester, {
      Size size = const Size(1280, 800),
      String? initialPath,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            coverDirProvider.overrideWithValue(covers),
            classicCvOnly,
          ],
          child: ComicRedrApp(initialPath: initialPath),
        ),
      );
      await tester.pump();
      return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }

    Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {String? character}) async {
      await tester.sendKeyEvent(k, character: character);
      await settle(tester);
    }

    Future<void> scan(WidgetTester tester, ProviderContainer c) async {
      await tester.runAsync(() async {
        await c.read(libraryStoreProvider).addRoot(root.path);
        await c.read(scannerProvider).scan();
      });
      await settle(tester);
    }

    /// A key or tap that opens a book: the book opens on isolates and real
    /// files, which only finish on the real event loop.
    Future<void> opening(WidgetTester tester, Future<void> Function() action) async {
      await tester.runAsync(() async {
        await action();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await settle(tester);
    }

    String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

    testWidgets('an empty library offers to add a folder', (tester) async {
      await pumpApp(tester);
      await settle(tester);
      expect(find.byKey(const Key('addRootEmpty')), findsOneWidget);
      expect(find.text('Open a comic'), findsOneWidget);
    });

    testWidgets('keys move through series and books, open one, and Esc comes back', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester);
      await scan(tester, c);
      expect(status(tester), '4 books in 3 series  ·  1 could not be read');
      // Series tab: Barefoot Bride, Pepper Carrot, The Spirit (a series of
      // two shows as one cover; a series of one as its book).
      expect(find.text('The Spirit'), findsWidgets);
      expect(find.text('2 books'), findsOneWidget);

      await key(tester, LogicalKeyboardKey.keyL); // Selects the first cover.
      await key(tester, LogicalKeyboardKey.keyL);
      await key(tester, LogicalKeyboardKey.keyL);
      // The wide layout shows the selection in the detail pane.
      expect(
        find.descendant(of: find.byKey(const Key('detail')), matching: find.text('2 books · 0 read')),
        findsOneWidget,
      );
      await key(tester, LogicalKeyboardKey.enter); // Into the series.
      expect(find.text('The Spirit #1'), findsWidgets);
      expect(find.text('The Spirit #2'), findsOneWidget);
      await opening(tester, () => tester.sendKeyEvent(LogicalKeyboardKey.enter)); // Opens #1.
      expect(c.read(readerProvider).book?.title, 'The Spirit #1');

      // ] follows the series (#1 → #2), though the files sort the other way.
      await tester.runAsync(() => c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.nextBook)));
      await settle(tester);
      expect(c.read(readerProvider).book?.title, 'The Spirit #2');
      await tester.runAsync(() => c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.nextBook)));
      await settle(tester);
      expect(status(tester), 'This is the last book in the series');

      // mm bookmarks the page; Esc goes back to the library, into the series
      // where we were, and the book shows its bookmark.
      await key(tester, LogicalKeyboardKey.keyL);
      await tester.runAsync(() => c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.bookmark)));
      await settle(tester);
      await key(tester, LogicalKeyboardKey.escape);
      expect(c.read(readerProvider).book, isNull);
      expect(find.text('The Spirit #2'), findsWidgets);
      await tester.tap(find.text('The Spirit #2').first);
      await settle(tester);
      expect(find.text('Page 2'), findsOneWidget);
      expect(find.text('On page 2 of 3'), findsOneWidget);

      // Esc leaves the series; Tab round to the Reading tab, which has it.
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.text('2 books'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.tab, character: '\t');
      await key(tester, LogicalKeyboardKey.tab, character: '\t');
      await key(tester, LogicalKeyboardKey.tab, character: '\t');
      expect(find.text('The Spirit #2'), findsOneWidget);
      expect(find.text('Barefoot Bride'), findsNothing, reason: 'never opened');
    });

    testWidgets('/ searches, Enter returns to the covers, Esc clears', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester);
      await scan(tester, c);
      await key(tester, LogicalKeyboardKey.tab, character: '\t'); // Books tab.
      expect(find.text('The Spirit #1'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.slash, character: '/');
      await tester.enterText(find.byKey(const Key('search')), 'eisner');
      await settle(tester);
      expect(find.text('The Spirit #1'), findsOneWidget);
      expect(find.text('Barefoot Bride'), findsNothing);
      // l typed into the field is text, not a key command.
      expect(c.read(readerProvider).book, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      await opening(tester, () => tester.sendKeyEvent(LogicalKeyboardKey.enter)); // Opens the first result.
      expect(c.read(readerProvider).book?.title, 'The Spirit #1');
      await key(tester, LogicalKeyboardKey.escape);
      await key(tester, LogicalKeyboardKey.escape); // Clears the search.
      expect(find.text('Barefoot Bride'), findsOneWidget);
    });

    testWidgets('/ still reaches the search after a folder opens while it is typed in', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester);
      await scan(tester, c);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      await key(tester, LogicalKeyboardKey.slash, character: '/');
      await tester.enterText(find.byKey(const Key('search')), 'spirit');
      await settle(tester);
      // A click on the folder while the cursor is in the search box.
      await tester.tap(find.text('Comics'), kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(find.byKey(const Key('breadcrumb')), findsOneWidget);
      expect(find.text('Barefoot Bride'), findsNothing);

      bool searching() => tester.widget<TextField>(find.byKey(const Key('search'))).focusNode!.hasFocus;
      // The click took the cursor out of the box, and the keys still work.
      expect(searching(), isFalse);
      await key(tester, LogicalKeyboardKey.slash, character: '/');
      expect(searching(), isTrue);
      // The last search is selected, so typing replaces it.
      final text = tester.widget<TextField>(find.byKey(const Key('search'))).controller!;
      expect(text.selection, const TextSelection(baseOffset: 0, extentOffset: 6));
      // Enter goes to the first result; the keys work again.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(searching(), isFalse);
      await opening(tester, () => tester.sendKeyEvent(LogicalKeyboardKey.enter));
      expect(c.read(readerProvider).book?.title, startsWith('The Spirit'));
    });

    testWidgets('an empty library folder shows a plain tile and its details', (tester) async {
      writeShelf(root);
      final empty = Directory('${tmp.path}/Empty')..createSync();
      final c = await pumpApp(tester);
      await scan(tester, c);
      await tester.runAsync(() => c.read(libraryStoreProvider).addRoot(empty.path));
      await settle(tester);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Empty'), findsOneWidget);
      await tester.tap(find.text('Empty'));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Folders tab walks into sub-folders and back out', (tester) async {
      writeShelf(root);
      final old = Directory('${root.path}/Indie/Old')..createSync();
      writeBook(old, 'Old One.cbz', 2);
      final c = await pumpApp(tester);
      await scan(tester, c);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      // The top: the library folder, with every book under it.
      expect(find.text('Comics'), findsOneWidget);
      expect(find.text('5 books'), findsOneWidget);

      await key(tester, LogicalKeyboardKey.keyL); // Selects it.
      await key(tester, LogicalKeyboardKey.enter); // Into Comics.
      // Sub-folders first, then the books; a folder of pages is a book.
      expect(find.byKey(const Key('breadcrumb')), findsOneWidget);
      expect(find.text('Indie'), findsWidgets);
      expect(find.text('2 books'), findsWidgets);
      expect(find.text('Pepper Carrot #6'), findsWidgets);
      expect(find.text('The Spirit #1'), findsWidgets);
      expect(find.text('Barefoot Bride'), findsNothing, reason: 'it is inside Indie');

      await key(tester, LogicalKeyboardKey.enter); // Indie is selected first.
      expect(find.text('Barefoot Bride'), findsWidgets);
      expect(find.text('Old'), findsWidgets);
      await tester.tap(find.text('Old').first); // A tap goes straight in.
      await settle(tester);
      expect(find.text('Old One'), findsWidgets);

      // The breadcrumb goes back to any folder above.
      await tester.tap(find.descendant(of: find.byKey(const Key('breadcrumb')), matching: find.text('Comics')));
      await settle(tester);
      expect(find.text('Indie'), findsWidgets);
      expect(find.text('Old One'), findsNothing);

      // Esc goes up a folder, with the folder you left selected.
      await key(tester, LogicalKeyboardKey.enter);
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.descendant(of: find.byKey(const Key('detail')), matching: find.text('Indie')), findsOneWidget);
      // Backspace goes up a folder too, and does nothing at the top.
      await key(tester, LogicalKeyboardKey.backspace);
      expect(find.byKey(const Key('breadcrumb')), findsNothing);
      expect(find.text('5 books'), findsWidgets);
      await key(tester, LogicalKeyboardKey.backspace);
      expect(find.text('5 books'), findsWidgets);

      // A book opens from inside a folder.
      await key(tester, LogicalKeyboardKey.enter);
      await key(tester, LogicalKeyboardKey.enter);
      await key(tester, LogicalKeyboardKey.keyL); // Barefoot Bride, after Old.
      await key(tester, LogicalKeyboardKey.keyL);
      await opening(tester, () => tester.sendKeyEvent(LogicalKeyboardKey.enter));
      expect(c.read(readerProvider).book?.title, 'Barefoot Bride');
      // Esc from the reader comes back to the same folder.
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.text('Old'), findsWidgets);
      // Backspace in the search field edits the text; it does not go up.
      await key(tester, LogicalKeyboardKey.slash, character: '/');
      await tester.enterText(find.byKey(const Key('search')), 'ol');
      await key(tester, LogicalKeyboardKey.backspace);
      expect(find.byKey(const Key('breadcrumb')), findsOneWidget);
      expect(find.text('Old'), findsWidgets);
      await tester.enterText(find.byKey(const Key('search')), '');
      await settle(tester);

      // Indie emptied on disk while shown: the view goes up to Comics.
      await tester.runAsync(() async {
        Directory('${root.path}/Indie').deleteSync(recursive: true);
        await c.read(scannerProvider).scan();
      });
      await settle(tester);
      expect(find.text('Old'), findsNothing);
      expect(find.text('The Spirit #1'), findsWidgets);
      expect(find.text('No books in this folder any more.'), findsNothing);
    });

    testWidgets('a comic with copies in two folders shows in both, and opens the copy you are on', (tester) async {
      final xman = Directory('${root.path}/xman')..createSync();
      final unread = Directory('${root.path}/Unread/xman')..createSync(recursive: true);
      final copy = writeBook(xman, 'Nancy.cbz', 3);
      File(copy).copySync('${unread.path}/Nancy.cbz');
      final c = await pumpApp(tester);
      await scan(tester, c);
      final books = await tester.runAsync(() => c.read(libraryStoreProvider).books());
      expect(books, hasLength(1), reason: 'one comic, two files');
      expect(books!.single.copies.map((f) => f.path), [p.normalize(copy)]);

      await tester.tap(find.text('Folders'));
      await settle(tester);
      expect(find.text('2 books'), findsWidgets, reason: 'a file in each folder');
      await key(tester, LogicalKeyboardKey.keyL);
      await key(tester, LogicalKeyboardKey.enter); // Into Comics.
      // "Unread" sorts first and held the only cover; xman has its own now.
      await tester.tap(find.text('xman').first);
      await settle(tester);
      expect(find.text('Nancy'), findsWidgets);
      await opening(tester, () => tester.sendKeyEvent(LogicalKeyboardKey.enter));
      expect(c.read(readerProvider).book?.path, p.normalize(copy));
      await key(tester, LogicalKeyboardKey.escape);

      await tester.tap(find.descendant(of: find.byKey(const Key('breadcrumb')), matching: find.text('Comics')));
      await settle(tester);
      await tester.tap(find.text('Unread').first);
      await settle(tester);
      await tester.tap(find.text('xman').first);
      await settle(tester);
      expect(find.text('Nancy'), findsWidgets);
    });

    testWidgets('shuffle shows a random page of each book in a folder, remembered across starts', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester);
      await scan(tester, c);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      await key(tester, LogicalKeyboardKey.keyL);
      await key(tester, LogicalKeyboardKey.enter); // Into Comics.
      Finder shuffled() => find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('shuffled-'),
      );
      expect(shuffled(), findsNothing);

      // S turns it on: every book tile makes a page other than its cover,
      // and a folder's tile a page of a comic in it.
      await key(tester, LogicalKeyboardKey.keyS, character: 'S');
      for (var i = 0; i < 50 && shuffled().evaluate().length < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
      }
      final keys = {for (final e in shuffled().evaluate()) (e.widget.key! as ValueKey<String>).value};
      expect(keys, hasLength(4), reason: 'Pepper Carrot, both Spirit books, and Indie with Barefoot Bride');
      final barefoot = (await tester.runAsync(() => c.read(libraryStoreProvider).books()))!
          .firstWhere((b) => b.name == 'Barefoot Bride');
      expect(keys.where((k) => k.startsWith('shuffled-${barefoot.key}-')), hasLength(1), reason: 'the Indie folder');
      final pages = Directory('$covers/pages')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => p.basename(f.path));
      expect(pages, isNot(contains('1.jpg')), reason: 'the cover is never the pick');
      expect(find.byKey(const Key('reshuffle')), findsOneWidget);
      final saved = await tester.runAsync(() => SettingsStore(db).loadBool(SettingsStore.shuffle));
      expect(saved, isTrue);

      // gs picks again; the grid scrolling or rebuilding does not.
      await tester.pump();
      expect({for (final e in shuffled().evaluate()) (e.widget.key! as ValueKey<String>).value}, keys);
      var changed = false;
      for (var round = 0; round < 8 && !changed; round++) {
        await key(tester, LogicalKeyboardKey.keyG, character: 'g');
        await key(tester, LogicalKeyboardKey.keyS, character: 's');
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pump();
        }
        changed = !{for (final e in shuffled().evaluate()) (e.widget.key! as ValueKey<String>).value}.containsAll(keys);
      }
      expect(changed, isTrue, reason: 'Spirit #2 has four pages to pick from');

      // A book still opens where it was.
      await key(tester, LogicalKeyboardKey.keyL);
      await key(tester, LogicalKeyboardKey.keyL);
      await opening(tester, () => tester.sendKeyEvent(LogicalKeyboardKey.enter));
      expect(c.read(readerProvider).book, isNotNull);
      expect(c.read(readerProvider).page, 0);
      await key(tester, LogicalKeyboardKey.escape);

      // A new start keeps shuffle on; S turns it off. (In the library: the
      // comic just read would open at start otherwise.)
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => SettingsStore(db).saveBool(SettingsStore.continueAtStart, false));
      final c2 = await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      await key(tester, LogicalKeyboardKey.keyL);
      await key(tester, LogicalKeyboardKey.enter);
      for (var i = 0; i < 50 && shuffled().evaluate().length < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
      }
      expect(shuffled(), findsNWidgets(4));
      await key(tester, LogicalKeyboardKey.keyS, character: 'S');
      expect(shuffled(), findsNothing);
      expect(find.byKey(const Key('reshuffle')), findsNothing);
      expect(c2.read(readerProvider).book, isNull);
    });

    testWidgets('S shuffles the Series and Books tabs too, a series with a page of one of its comics', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester);
      await scan(tester, c);
      Finder shuffled() => find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('shuffled-'),
      );
      Future<void> waitFor(int n) async {
        for (var i = 0; i < 50 && shuffled().evaluate().length < n; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
          await tester.pump();
        }
      }

      await tester.tap(find.text('Series').first);
      await settle(tester);
      expect(shuffled(), findsNothing);
      await key(tester, LogicalKeyboardKey.keyS, character: 'S');
      await waitFor(3);
      final books = (await tester.runAsync(() => c.read(libraryStoreProvider).books()))!;
      final spirit = {for (final b in books.where((b) => b.series == 'The Spirit')) b.key};
      final keys = {for (final e in shuffled().evaluate()) (e.widget.key! as ValueKey<String>).value};
      expect(keys, hasLength(3), reason: 'The Spirit, Barefoot Bride and Pepper Carrot');
      expect(keys.where((k) => spirit.any((s) => k.startsWith('shuffled-$s-'))), hasLength(1), reason: 'the series');
      expect(find.byKey(const Key('shuffle')), findsOneWidget);

      await tester.tap(find.text('Books').first);
      await settle(tester);
      await waitFor(4);
      expect(shuffled(), findsNWidgets(4), reason: 'every book, shuffle stays on across tabs');
      await key(tester, LogicalKeyboardKey.keyS, character: 'S');
      expect(shuffled(), findsNothing);
    });

    testWidgets('F filters the Folders tab by type, length and date, the bar clears it, and it is kept', (
      tester,
    ) async {
      writeShelf(root);
      File('${root.path}/Sunday Strip 7.png').writeAsBytesSync([...png, 7]);
      writeBook(root, 'Long Saga.cbz', 30);
      // Spirit #2 last changed two years ago; the rest just now.
      File('${root.path}/spirit-a.cbz').setLastModifiedSync(DateTime.now().subtract(const Duration(days: 730)));
      final c = await pumpApp(tester);
      await scan(tester, c);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      expect(find.text('6 books'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.keyL);
      await key(tester, LogicalKeyboardKey.enter); // Into Comics.
      expect(find.byKey(const Key('filterBarClear')), findsNothing);

      // F opens the filter; only the types the library has are offered.
      await key(tester, LogicalKeyboardKey.keyF, character: 'F');
      expect(find.byKey(const Key('filterDialog')), findsOneWidget);
      expect(find.byKey(const Key('filterType-cbz')), findsOneWidget);
      expect(find.byKey(const Key('filterType-pdf')), findsNothing);
      await tester.tap(find.byKey(const Key('filterType-image')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('filterDone')));
      await settle(tester);
      expect(find.text('Sunday Strip #7'), findsWidgets);
      expect(find.text('The Spirit #1'), findsNothing);
      expect(find.text('Pepper Carrot #6'), findsNothing);
      expect(find.text('Indie'), findsNothing, reason: 'nothing in it passes');
      expect(
        find.descendant(of: find.byKey(const Key('filterBarType')), matching: find.text('Single image')),
        findsOne,
      );
      // It combines with the search.
      await key(tester, LogicalKeyboardKey.slash, character: '/');
      await tester.enterText(find.byKey(const Key('search')), 'spirit');
      await settle(tester);
      expect(find.text('Nothing matches "spirit" with this filter.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('search')), '');
      await settle(tester);

      // Its x takes the type off; the bar goes with the last part.
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('filterBarType')),
          matching: find.byTooltip('Take this off the filter'),
        ),
      );
      await settle(tester);
      expect(find.byKey(const Key('filterBarClear')), findsNothing);
      expect(find.text('The Spirit #1'), findsWidgets);

      // By length: of these only the comic of 30 pages is 24 to 64 pages
      // long. (The cursor is still in the search box, so by the button.)
      await tester.tap(find.byKey(const Key('filter')));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('filterPages-to64')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('filterPages-to64')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('filterDone')));
      await settle(tester);
      expect(find.text('Long Saga'), findsWidgets);
      expect(find.text('The Spirit #1'), findsNothing);
      expect(find.text('Sunday Strip #7'), findsNothing);
      expect(
        find.descendant(of: find.byKey(const Key('filterBarPages')), matching: find.text('24 to 64 pages')),
        findsOne,
      );
      expect(
        await tester.runAsync(() => SettingsStore(db).loadString(SettingsStore.folderFilter)),
        contains('"pages":"to64"'),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('filterBarPages')),
          matching: find.byTooltip('Take this off the filter'),
        ),
      );
      await settle(tester);
      expect(find.byKey(const Key('filterBarClear')), findsNothing);

      // By date: only the book changed over a year ago; the header button
      // opens it too.
      await tester.tap(find.byKey(const Key('filter')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('filterDate-older')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('filterDone')));
      await settle(tester);
      expect(find.text('The Spirit #2'), findsWidgets);
      expect(find.text('The Spirit #1'), findsNothing);
      expect(find.text('Sunday Strip #7'), findsNothing);
      final saved = await tester.runAsync(() => SettingsStore(db).loadString(SettingsStore.folderFilter));
      expect(saved, contains('older'));

      // A new start keeps it; up at the top the count is what passes.
      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      expect(find.byKey(const Key('filterBarClear')), findsOneWidget);
      expect(find.text('1 book'), findsOneWidget);

      // Too big for anything here: said so, and Clear filter brings all back.
      await key(tester, LogicalKeyboardKey.keyF, character: 'F');
      await tester.tap(find.byKey(const Key('filterSize-over200')));
      await settle(tester);
      await key(tester, LogicalKeyboardKey.escape); // Closes the dialog.
      expect(find.byKey(const Key('filterDialog')), findsNothing);
      expect(find.text('No comics match the filter.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('filterBarClear')));
      await settle(tester);
      expect(find.text('6 books'), findsOneWidget);
      expect(await tester.runAsync(() => SettingsStore(db).loadString(SettingsStore.folderFilter)), isNull);
    });

    testWidgets('gS, go and gO sort the Folders tab, by key and by the button, and the order is kept', (tester) async {
      // Page counts tell them apart: Alpha 3, Beta 9, Gamma 5.
      writeBook(root, 'Alpha.cbz', 3);
      writeBook(root, 'Beta.cbz', 9);
      writeBook(root, 'Gamma.cbz', 5);
      final c = await pumpApp(tester);
      await scan(tester, c);
      final books = (await tester.runAsync(() => c.read(libraryStoreProvider).books()))!;
      final seriesOf = {for (final b in books) b.key: b.series};
      // The covers in reading order, by where they are on screen.
      List<String> shown() {
        final covers = find
            .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('b:'))
            .evaluate()
            .toList();
        final at = {for (final e in covers) e: tester.getTopLeft(find.byWidget(e.widget))};
        covers.sort((a, b) => at[a]!.dy != at[b]!.dy ? at[a]!.dy.compareTo(at[b]!.dy) : at[a]!.dx.compareTo(at[b]!.dx));
        return [for (final e in covers) seriesOf[(e.widget.key! as ValueKey<String>).value.split(':')[1]]!];
      }

      Future<void> alt(String letter) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(
          LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + letter.codeUnitAt(0) - 0x61),
          character: letter,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await settle(tester);
      }

      Future<String?> saved() =>
          tester.runAsync(() => SettingsStore(db).loadString(SettingsStore.folderSort)).then((v) => v);

      await tester.tap(find.text('Folders'));
      await settle(tester);
      await key(tester, LogicalKeyboardKey.keyL);
      await key(tester, LogicalKeyboardKey.enter); // Into Comics.
      expect(shown(), ['Alpha', 'Beta', 'Gamma']);
      expect(find.text('Sort: Name, A to Z'), findsOneWidget);

      // gS opens the window; Alt+P sorts by pages, most first, at once.
      await key(tester, LogicalKeyboardKey.keyG, character: 'g');
      await key(tester, LogicalKeyboardKey.keyS, character: 'S');
      expect(find.byKey(const Key('sortDialog')), findsOneWidget);
      await alt('p');
      expect(shown(), ['Beta', 'Gamma', 'Alpha']);
      expect(await saved(), 'pages');
      // Alt+R turns it round; Alt+D closes the window.
      await alt('r');
      expect(shown(), ['Alpha', 'Gamma', 'Beta']);
      expect(await saved(), 'pages:reversed');
      await alt('d');
      expect(find.byKey(const Key('sortDialog')), findsNothing);
      expect(find.text('Sort: Pages, fewest first'), findsOneWidget);

      // go: the next order (series), still reversed, and a notice says so.
      await key(tester, LogicalKeyboardKey.keyG, character: 'g');
      await key(tester, LogicalKeyboardKey.keyO, character: 'o');
      expect(shown(), ['Gamma', 'Beta', 'Alpha']);
      expect(find.text('Sorted by series, z to a'), findsOneWidget);
      // gO: the other way round.
      await key(tester, LogicalKeyboardKey.keyG, character: 'g');
      await key(tester, LogicalKeyboardKey.keyO, character: 'O');
      expect(shown(), ['Alpha', 'Beta', 'Gamma']);
      expect(await saved(), 'series');

      // A new start keeps it; the button opens the window, a chip picks.
      await tester.runAsync(() => SettingsStore(db).saveString(SettingsStore.folderSort, 'pages'));
      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      await key(tester, LogicalKeyboardKey.keyL);
      await key(tester, LogicalKeyboardKey.enter);
      expect(shown(), ['Beta', 'Gamma', 'Alpha']);
      await tester.tap(find.byKey(const Key('sort')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('sort-name')));
      await settle(tester);
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byKey(const Key('sortDialog')), findsNothing);
      expect(shown(), ['Alpha', 'Beta', 'Gamma']);
      expect(await saved(), isNull, reason: 'the usual order is no setting');
    });

    /// The app's own start: first frame, the start-up scan, the books.
    Future<void> starting(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump();
      }
    }

    testWidgets('a folder of comics given at start opens on the Folders tab there', (tester) async {
      writeShelf(root);
      Directory('${root.path}/Indie/Old').createSync();
      writeBook(Directory('${root.path}/Indie/Old'), 'Old One.cbz', 2);
      await LibraryStore(db).addRoot(root.path);
      final c = await pumpApp(tester, initialPath: '${root.path}/Indie');
      await starting(tester);
      // Inside the library folder Comics: walked to Indie, not added again.
      expect(c.read(readerProvider).book, isNull);
      expect(find.byKey(const Key('breadcrumb')), findsOneWidget);
      expect(find.text('Barefoot Bride'), findsWidgets);
      expect(find.text('Old'), findsWidgets);
      expect((await LibraryStore(db).roots()).length, 1);
      await key(tester, LogicalKeyboardKey.backspace); // Up to Comics.
      expect(find.text('Indie'), findsWidgets);
      expect(find.text('The Spirit #1'), findsWidgets);
    });

    testWidgets('a folder outside the library given at start is added and shown', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester, initialPath: '${root.path}/Indie');
      await starting(tester);
      expect(c.read(readerProvider).book, isNull);
      expect((await LibraryStore(db).roots()).map((r) => r.path), ['${root.path}/Indie']);
      expect(find.byKey(const Key('breadcrumb')), findsOneWidget);
      expect(find.text('Barefoot Bride'), findsWidgets);
    });

    testWidgets('a folder of page images given at start opens as a book', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester, initialPath: '${root.path}/Pepper Carrot e06');
      await starting(tester);
      expect(c.read(readerProvider).book?.title, isNotNull);
      expect(await LibraryStore(db).roots(), isEmpty);
    });

    testWidgets('on a phone-sized screen a tap goes into a folder, and back comes out', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester, size: const Size(400, 800));
      await scan(tester, c);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      await tester.tap(find.text('Comics'));
      await settle(tester);
      await tester.tap(find.text('Indie'));
      await settle(tester);
      expect(find.text('Barefoot Bride'), findsOneWidget);
      // Android's back gesture goes up a folder at a time.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Indie'), findsOneWidget);
      await tester.tap(find.byKey(const Key('folderUp')));
      await settle(tester);
      expect(find.byKey(const Key('breadcrumb')), findsNothing);
    });

    testWidgets('on a phone-sized screen a tap shows the book, and Read opens it', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester, size: const Size(400, 800));
      await scan(tester, c);
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.tap(find.text('Barefoot Bride'));
      await settle(tester);
      expect(find.text('Not started · 5 pages'), findsOneWidget);
      await opening(tester, () => tester.tap(find.byKey(const Key('read'))));
      expect(c.read(readerProvider).book?.title, 'Barefoot Bride');
    });
  });
}
