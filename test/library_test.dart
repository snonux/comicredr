import 'dart:io';

import 'package:archive/archive.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
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
    Future<ProviderContainer> pumpApp(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
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
          child: const ComicRedrApp(),
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
