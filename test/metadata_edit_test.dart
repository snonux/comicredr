import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/meta_edits.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
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

import 'library_test.dart' show writeShelf;
import 'support/fixtures.dart';

void main() {
  late Directory tmp;
  late Directory root;
  late String covers;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('metadata_edit_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    covers = '${tmp.path}/covers';
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  final t0 = DateTime(2026, 9, 24, 10);
  final t1 = DateTime(2026, 9, 24, 11);

  group('MetaEdit', () {
    test('round-trips, and reads a bare value as an old edit', () {
      for (final e in [MetaEdit('Swamp Thing', at: t0), MetaEdit(null, at: t0), MetaEdit.undo(at: t1)]) {
        expect(MetaEdit.decode(e.encode()), e);
      }
      expect(MetaEdit.decode('1987'), MetaEdit('1987', at: DateTime.fromMillisecondsSinceEpoch(0)));
      expect(MetaEdit.decode('Batman').value, 'Batman');
    });

    test('merging keeps the later edit per fact, an undo included', () {
      final a = {'series': MetaEdit('Spirit', at: t0).encode(), 'year': MetaEdit('1940', at: t1).encode()};
      final b = {'series': MetaEdit.undo(at: t1).encode(), 'year': MetaEdit('1941', at: t0).encode()};
      for (final merged in [mergeEdits(a, b), mergeEdits(b, a)]) {
        expect(activeEdits(merged), {MetaField.year: '1940'});
      }
    });
  });

  group('store', () {
    Future<(LibraryStore, LibraryScanner)> scanned() async {
      writeShelf(root);
      final store = LibraryStore(db);
      final scanner = LibraryScanner(store, coverDir: covers, workers: 1);
      await store.addRoot(root.path);
      await scanner.scan();
      return (store, scanner);
    }

    test('edits win over the file, survive a rescan, regroup and search, and undo', () async {
      final (store, scanner) = await scanned();
      final bride = (await store.books()).firstWhere((b) => b.series == 'Barefoot Bride');
      expect(bride.fromFile, isEmpty);

      await store.editBook(bride.key, {
        MetaField.series: MetaEdit('The Spirit', at: t0),
        MetaField.number: MetaEdit('3', at: t0),
        MetaField.title: MetaEdit('The Bride', at: t0),
        MetaField.year: MetaEdit('1941', at: t0),
        MetaField.writers: MetaEdit('Will Eisner, Jules Feiffer', at: t0),
      });
      await scanner.scan(); // A rescan reads the files again.
      var books = await store.books();
      var edited = books.firstWhere((b) => b.key == bride.key);
      expect((edited.name, edited.issueTitle, edited.year), ('The Spirit #3', 'The Bride', 1941));
      expect(edited.writers, ['Will Eisner', 'Jules Feiffer']);
      expect(edited.fromFile[MetaField.series], 'Barefoot Bride');
      expect(edited.fromFile[MetaField.number], isNull);
      final spirit = LibrarySeries.group(books).firstWhere((s) => s.name == 'The Spirit');
      expect(spirit.books.map((b) => b.number), ['1', '2', '3']);
      expect(edited.matches('feiffer'), isTrue);

      // Clearing a fact empties it; undo brings the file's back.
      await store.editBook(bride.key, {
        MetaField.year: MetaEdit(null, at: t1),
        MetaField.series: MetaEdit.undo(at: t1),
        MetaField.number: MetaEdit.undo(at: t1),
      });
      books = await store.books();
      edited = books.firstWhere((b) => b.key == bride.key);
      expect((edited.name, edited.year, edited.issueTitle), ('Barefoot Bride', null, 'The Bride'));
      expect(edited.fromFile.keys.toSet(), {MetaField.year, MetaField.title, MetaField.writers});
      expect(LibrarySeries.group(books).firstWhere((s) => s.name == 'The Spirit').books, hasLength(2));
      await scanner.dispose();
    });

    test('renaming a series shows the typed name, even when only its case changes', () async {
      final (store, scanner) = await scanned();
      final spirit = (await store.books()).where((b) => b.series == 'The Spirit').toList();
      for (final b in spirit) {
        await store.editBook(b.key, {MetaField.series: MetaEdit('THE SPIRIT', at: t0)});
      }
      final groups = LibrarySeries.group(await store.books());
      expect(groups.map((s) => s.name), containsAll(['THE SPIRIT']));
      expect(groups.firstWhere((s) => s.name == 'THE SPIRIT').books, hasLength(2));
      await scanner.dispose();
    });
  });

  test('edits travel in the sidecar to another install, and the later one wins', () async {
    final path = writeBook(root, 'Swamp Thing 21.cbz', 3);
    final dbs = [db, AppDatabase(NativeDatabase.memory())];
    final installs = [
      for (final d in dbs)
        (
          store: LibraryStore(d),
          sync: SidecarSync(
            d,
            progress: ProgressStore(d, debounce: Duration.zero),
            debounce: Duration.zero,
          ),
        ),
    ];
    final (laptop, phone) = (installs[0], installs[1]);
    for (final i in installs) {
      final scanner = LibraryScanner(
        i.store,
        coverDir: covers,
        workers: 1,
        onBookRead: (p, k, {required folder}) => i.sync.attach(p, k, folder: folder),
      );
      await i.store.addRoot(root.path);
      await scanner.scan();
      await scanner.dispose();
    }
    final key = (await laptop.store.books()).single.key;

    await laptop.store.editBook(key, {MetaField.title: MetaEdit('The Anatomy Lesson', at: t0)});
    expect(await laptop.sync.writeBeside(path, key, folder: false), isTrue);
    expect(activeEdits(readSidecar(sidecarPath(path, folder: false))!.overrides), {
      MetaField.title: 'The Anatomy Lesson',
    });

    await phone.sync.attach(path, key, folder: false);
    expect((await phone.store.books()).single.issueTitle, 'The Anatomy Lesson');

    // The phone undoes it later; the laptop, writing its older edit again,
    // does not bring it back.
    await phone.store.editBook(key, {MetaField.title: MetaEdit.undo(at: t1)});
    await phone.sync.writeBeside(path, key, folder: false);
    await laptop.sync.writeBeside(path, key, folder: false);
    await laptop.sync.attach(path, key, folder: false);
    expect((await laptop.store.books()).single.issueTitle, isNull);
    await dbs[1].close();
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

    testWidgets('e edits the selected book, e on a series renames it, and the reader shows the edit', (tester) async {
      writeShelf(root);
      final c = await pumpApp(tester);
      await tester.runAsync(() async {
        await c.read(libraryStoreProvider).addRoot(root.path);
        await c.read(scannerProvider).scan();
      });
      await settle(tester);

      // Series tab: Barefoot Bride, Pepper Carrot, The Spirit.
      await key(tester, LogicalKeyboardKey.keyL);
      await key(tester, LogicalKeyboardKey.keyE, character: 'e');
      expect(find.byKey(const Key('editDialog')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('edit.series')), 'The Spirit');
      await tester.enterText(find.byKey(const Key('edit.number')), '3');
      await tester.enterText(find.byKey(const Key('edit.year')), 'soon');
      await tester.tap(find.byKey(const Key('editSave')));
      await settle(tester);
      expect(find.text('A whole number'), findsOneWidget, reason: 'the year is checked');
      await tester.enterText(find.byKey(const Key('edit.year')), '1941');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('editSave')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle(tester);
      expect(find.byKey(const Key('editDialog')), findsNothing);
      expect(find.text('3 books'), findsOneWidget, reason: 'Barefoot Bride joined The Spirit');
      expect(
        find.descendant(of: find.byKey(const Key('detail')), matching: find.text('3 books · 0 read')),
        findsOneWidget,
        reason: 'the selection followed the book into its new series',
      );
      final bride = (await tester.runAsync(() => c.read(libraryStoreProvider).books()))!
          .firstWhere((b) => b.number == '3');
      expect((bride.series, bride.year), ('The Spirit', 1941));
      final side = await tester.runAsync(() async => readSidecar(sidecarPath(bride.path, folder: false)));
      expect(activeEdits(side!.overrides)[MetaField.series], 'The Spirit', reason: 'written beside the comic');

      // e on the series cover renames every book in it.
      await key(tester, LogicalKeyboardKey.keyE, character: 'e');
      expect(find.byKey(const Key('renameSeriesDialog')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('seriesName')), 'Spirit Section');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('renameSave')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle(tester);
      expect(find.text('Spirit Section'), findsWidgets);
      expect(find.text('The Spirit'), findsNothing);

      // The reader's title follows the edit.
      await tester.runAsync(() async {
        await c.read(readerProvider.notifier).open(bride.path);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle(tester);
      expect(c.read(readerProvider).book?.title, 'Spirit Section #3');
    });
  });
}
