import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/meta_edits.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/settings_file.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/folder_filter.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/library/settings_transfer.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// One install of the app: its own index and its own sidecar sync.
class Device {
  Device() : db = AppDatabase(NativeDatabase.memory()) {
    progress = ProgressStore(db, debounce: Duration.zero);
    sync = SidecarSync(db, progress: progress, debounce: Duration.zero, storeDir: () async => null);
  }

  final AppDatabase db;
  late final ProgressStore progress;
  late final SidecarSync sync;
  LibraryStore get library => LibraryStore(db);
}

/// Completed comics (task 273): the mark (`gC`, the tick in the details,
/// the last page reached in the reader), where it is kept and how it
/// travels, the sign on the cover, and the Folders tab's filter by it.
void main() {
  late Directory tmp;
  late Directory root;
  late String covers;
  late AppDatabase db;

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('completed_test');
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

  Future<List<String>> completed(LibraryStore store) async => [
    for (final b in await store.books())
      if (b.completed) b.name,
  ]..sort();

  final t0 = DateTime(2026, 10, 1, 12);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

  group('the mark', () {
    test('is a dated overrides row that is no metadata edit', () {
      expect(completedMark(null), isNull);
      expect(completedMark(completedEdit(true, at: t0).encode()), isTrue);
      expect(completedMark(completedEdit(false, at: t0).encode()), isFalse);
      expect(completedMark(completedEdit(null, at: t0).encode()), isNull, reason: 'undone: no say');
      expect(MetaEdit.decode(completedEdit(true, at: t0).encode()).at, t0);
      expect(activeEdits({completedField: completedEdit(true, at: t0).encode()}), isEmpty);
      expect(MetaField.byName(completedField), isNull);
    });

    test('on, off and undone; without one the last page decides', () async {
      final store = await shelf();
      var books = await store.books();
      final daredevil = named(books, 'Daredevil #181').key, preacher = named(books, 'Preacher #1').key;
      expect(await completed(store), isEmpty);
      expect(await store.completedMarkOf(daredevil), isNull);
      expect(await store.isCompleted(daredevil), isFalse);

      await store.setCompleted(daredevil, true);
      expect(await store.completedMarkOf(daredevil), isTrue);
      expect(await completed(store), ['Daredevil #181']);
      expect(named(await store.books(), 'Daredevil #181').inProgress, isFalse);

      await store.setCompleted(daredevil, false);
      expect(await store.completedMarkOf(daredevil), isFalse);
      expect(await completed(store), isEmpty);
      // One row, rewritten: not one per change.
      expect((await db.select(db.overrides).get()).where((o) => o.contentKey == daredevil), hasLength(1));

      // Left on the last page before there was a mark: completed.
      final progress = ProgressStore(db, debounce: Duration.zero);
      progress.save(preacher, const ReadingPosition(page: 1), 2);
      progress.save(daredevil, const ReadingPosition(page: 3), 4);
      await progress.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await progress.flush();
      // save() keeps only the last row waiting, so each is saved in turn.
      progress.save(preacher, const ReadingPosition(page: 1), 2);
      await progress.flush();
      books = await store.books();
      expect(named(books, 'Preacher #1').finished, isTrue);
      expect(named(books, 'Preacher #1').completedMark, isNull);
      expect(named(books, 'Preacher #1').completed, isTrue);
      expect(await store.isCompleted(preacher), isTrue);
      // Marked not completed wins over the last page.
      expect(named(books, 'Daredevil #181').finished, isTrue);
      expect(named(books, 'Daredevil #181').completed, isFalse);
      expect(await store.isCompleted(daredevil), isFalse);
      // Undone, the mark has no say and the last page decides again.
      await store.setCompleted(daredevil, null);
      expect(named(await store.books(), 'Daredevil #181').completed, isTrue);

      // Read again from the start: the unmarked one is not completed any
      // more, a marked one stays.
      await store.setCompleted(daredevil, true);
      progress.save(preacher, const ReadingPosition(page: 0), 2);
      await progress.flush();
      progress.save(daredevil, const ReadingPosition(page: 0), 4);
      await progress.flush();
      expect(await completed(store), ['Daredevil #181']);
      final series = LibrarySeries.group(await store.books());
      expect(series.firstWhere((s) => s.name == 'Daredevil').read, 1);
      expect(series.firstWhere((s) => s.name == 'Preacher').read, 0);
    });
  });

  group('sidecars', () {
    late Device laptop, phone;

    setUp(() {
      laptop = Device();
      phone = Device();
    });
    tearDown(() async {
      await laptop.db.close();
      await phone.db.close();
    });

    test('the later change wins when two sidecars meet, taking the mark off included', () {
      SidecarData side(bool? on, int minute) => SidecarData(
        contentKey: 'k',
        overrides: {completedField: completedEdit(on, at: at(minute)).encode()},
      );
      bool? merged(SidecarData a, SidecarData b) => completedMark(mergeSidecars(a, b).overrides[completedField]);
      // Marked, then unmarked later on the other device: unmarked, whichever is merged into which.
      expect(merged(side(true, 0), side(false, 5)), isFalse);
      expect(merged(side(false, 5), side(true, 0)), isFalse);
      // Unmarked, then marked later.
      expect(merged(side(false, 0), side(true, 5)), isTrue);
      expect(merged(side(true, 5), side(false, 0)), isTrue);
      // An undo is a change like any other.
      expect(merged(side(true, 0), side(null, 5)), isNull);
      // One side never said: the other's stands.
      expect(merged(const SidecarData(contentKey: 'k'), side(true, 0)), isTrue);
      expect(merged(side(false, 0), const SidecarData(contentKey: 'k')), isFalse);
    });

    test('the mark travels in the sidecar both ways, and so does taking it off', () async {
      final path = writeBook(Directory('${tmp.path}/shared')..createSync(), 'Daredevil 181.cbz', 4);
      final key = await contentKey(path);
      await laptop.sync.attach(path, key, folder: false);
      await laptop.library.setCompleted(key, true, at: at(0));
      await laptop.sync.write(key);
      expect(completedMark(readSidecar(sidecarPath(path, folder: false))!.overrides[completedField]), isTrue);

      // The phone opens the same comic: completed there too.
      expect(await phone.library.completedMarkOf(key), isNull);
      await phone.sync.attach(path, key, folder: false);
      expect(await phone.library.completedMarkOf(key), isTrue);

      // The phone takes the mark off later; the laptop hears of it.
      await phone.library.setCompleted(key, false, at: at(10));
      await phone.sync.write(key);
      await laptop.sync.attach(path, key, folder: false);
      expect(await laptop.library.completedMarkOf(key), isFalse);

      // An older mark in a sidecar does not undo a newer change here.
      await laptop.library.setCompleted(key, true, at: at(20));
      await phone.library.setCompleted(key, false, at: at(15));
      await phone.sync.write(key);
      await laptop.sync.attach(path, key, folder: false);
      expect(await laptop.library.completedMarkOf(key), isTrue);
    });

    test('Reset everything forgets the mark, Redo panels keeps it', () async {
      final path = writeBook(Directory('${tmp.path}/reset')..createSync(), 'Daredevil 181.cbz', 4);
      final key = await contentKey(path);
      await laptop.sync.attach(path, key, folder: false);
      await laptop.library.setCompleted(key, true, at: at(0));
      await laptop.sync.write(key);

      expect(await laptop.sync.reset(key, everything: false), isTrue);
      expect(await laptop.library.completedMarkOf(key), isTrue);
      expect(readSidecar(sidecarPath(path, folder: false))!.overrides, contains(completedField));

      expect(await laptop.sync.reset(key, everything: true), isTrue);
      expect(await laptop.library.completedMarkOf(key), isNull);
      expect(readSidecar(sidecarPath(path, folder: false))?.overrides ?? const {}, isNot(contains(completedField)));
      // And nothing brings it back on the next open.
      await laptop.sync.attach(path, key, folder: false);
      expect(await laptop.library.completedMarkOf(key), isNull);
    });

    test('the mark is in a settings export and an import merges it, the later change winning', () async {
      await laptop.library.setCompleted('a', true, at: at(0));
      await laptop.library.setCompleted('b', false, at: at(0));
      await laptop.library.setCompleted('c', true, at: at(0));
      final text = await exportSettings(laptop.db);
      expect(text, contains('"completed"'));

      await phone.library.setCompleted('b', true, at: at(-5)); // Older than the file's: loses.
      await phone.library.setCompleted('c', false, at: at(5)); // Newer than the file's: stays.
      await importSettings(SettingsFile.decode(text), library: phone.library);
      expect(await phone.library.completedMarkOf('a'), isTrue);
      expect(await phone.library.completedMarkOf('b'), isFalse);
      expect(await phone.library.completedMarkOf('c'), isFalse);
      expect(await phone.library.completedMarkOf('d'), isNull);
    });
  });

  group('the filter', () {
    LibraryBook book({bool? mark, bool finished = false}) => LibraryBook(
      key: 'k',
      series: 'S',
      seriesId: 1,
      pageCount: 3,
      format: 'cbz',
      path: '/c/k.cbz',
      addedAt: DateTime(2020),
      finished: finished,
      completedMark: mark,
    );

    test('three ways: all, completed only, not completed', () {
      final now = DateTime(2026);
      const only = FolderFilter(completed: CompletedFilter.only), hide = FolderFilter(completed: CompletedFilter.hide);
      expect(FolderFilter.none.completed, CompletedFilter.any);
      expect(only.isActive, isTrue);
      expect(hide.isActive, isTrue);
      for (final b in [book(), book(mark: true), book(mark: false), book(finished: true)]) {
        expect(FolderFilter.none.accepts(b, now), isTrue);
        expect(only.accepts(b, now), b.completed);
        expect(hide.accepts(b, now), !b.completed);
      }
      expect(only.accepts(book(mark: true), now), isTrue);
      expect(only.accepts(book(), now), isFalse);
      expect(only.accepts(book(finished: true), now), isTrue, reason: 'left on the last page');
      expect(only.accepts(book(mark: false, finished: true), now), isFalse, reason: 'marked not completed');
      expect(hide.accepts(book(mark: true), now), isFalse);
      expect(hide.accepts(book(), now), isTrue);
      // It combines with the other parts.
      const pdfs = FolderFilter(formats: {'pdf'}, completed: CompletedFilter.only);
      expect(pdfs.accepts(book(mark: true), now), isFalse);
    });

    test('saved and read back; a filter saved before there was one still reads', () {
      const only = FolderFilter(completed: CompletedFilter.only);
      expect(only.encode(), contains('"completed":"only"'));
      expect(FolderFilter.decode(only.encode()), only);
      expect(only == FolderFilter.none, isFalse);
      expect(only.copyWith(completed: CompletedFilter.any), FolderFilter.none);
      const hide = FolderFilter(formats: {'cbz'}, size: SizeRange.to50, completed: CompletedFilter.hide);
      expect(FolderFilter.decode(hide.encode()), hide);
      expect(hide == hide.copyWith(completed: CompletedFilter.only), isFalse);
      // As task 263's version wrote it: no `completed` at all.
      const old = '{"formats":["cbz","pdf"],"size":"over200","date":"older"}';
      const was = FolderFilter(formats: {'pdf', 'cbz'}, size: SizeRange.over200, date: DateRange.older);
      expect(FolderFilter.decode(old), was);
      expect(FolderFilter.decode(old).completed, CompletedFilter.any);
      expect(was.encode(), old, reason: 'and a filter without it is still written that way');
      // Junk in it is no filter on completed.
      expect(FolderFilter.decode('{"completed":"sometimes"}'), FolderFilter.none);
      expect(FolderFilter.decode('{"completed":7,"date":"week"}'), const FolderFilter(date: DateRange.week));
    });
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

    /// Keys as typed, with no pause inside a sequence; a capital with Shift.
    Future<void> type(WidgetTester tester, String keys) async {
      for (final ch in keys.split('')) {
        final k = switch (ch.toLowerCase()) {
          'g' => LogicalKeyboardKey.keyG,
          'c' => LogicalKeyboardKey.keyC,
          'l' => LogicalKeyboardKey.keyL,
          'h' => LogicalKeyboardKey.keyH,
          'u' => LogicalKeyboardKey.keyU,
          'v' => LogicalKeyboardKey.keyV,
          'p' => LogicalKeyboardKey.keyP,
          'f' => LogicalKeyboardKey.keyF,
          _ => throw ArgumentError(ch),
        };
        final shift = ch != ch.toLowerCase();
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(k, character: ch);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
      }
      await settle(tester);
    }

    Future<bool?> markOf(WidgetTester tester, LibraryStore store, String key) =>
        tester.runAsync<bool?>(() => store.completedMarkOf(key));

    testWidgets('gC in the reader marks the open comic and takes the mark off, over the page grid too', (tester) async {
      final store = (await tester.runAsync(shelf))!;
      final book = named((await tester.runAsync(store.books))!, 'Daredevil #181');
      final c = await pumpApp(tester);
      await settle(tester);
      await tester.runAsync(() => c.read(readerProvider.notifier).open(book.path));
      await settle(tester);
      expect(c.read(readerProvider).page, 0);
      expect(await markOf(tester, store, book.key), isNull);

      await type(tester, 'gC');
      expect(c.read(readerProvider).message, 'Marked as completed');
      expect(await markOf(tester, store, book.key), isTrue);
      expect(c.read(readerProvider).book, isNotNull, reason: 'the comic stays open');
      expect(c.read(readerProvider).page, 0);

      await type(tester, 'gC');
      expect(c.read(readerProvider).message, 'Marked as not completed');
      expect(await markOf(tester, store, book.key), isFalse);

      // gc is another key: it asks for a collection and marks nothing.
      await type(tester, 'gc');
      expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(await markOf(tester, store, book.key), isFalse);

      // Over the page grid it is still about the comic, and the grid stays.
      await type(tester, 'p');
      expect(find.byKey(const Key('pageGrid')), findsOneWidget);
      await type(tester, 'gC');
      expect(await markOf(tester, store, book.key), isTrue);
      expect(find.byKey(const Key('pageGrid')), findsOneWidget);
    });

    testWidgets('reaching the last page marks the comic; opening it there, or leaving and unmarking, does not', (
      tester,
    ) async {
      final store = (await tester.runAsync(shelf))!;
      final book = named((await tester.runAsync(store.books))!, 'Swamp Thing #21'); // Three pages.
      final c = await pumpApp(tester);
      await settle(tester);
      final reader = c.read(readerProvider.notifier);
      await tester.runAsync(() => reader.open(book.path));
      await settle(tester);

      await type(tester, 'l');
      expect(c.read(readerProvider).page, 1);
      expect(await markOf(tester, store, book.key), isNull, reason: 'not on the way there');
      await type(tester, 'l');
      expect(c.read(readerProvider).page, 2);
      expect(await markOf(tester, store, book.key), isTrue);
      expect(c.read(readerProvider).message, 'Last page: marked as completed');

      // Back to the start: still completed, which the last page alone would not be.
      await type(tester, 'h');
      await type(tester, 'h');
      expect(c.read(readerProvider).page, 0);
      await tester.runAsync(reader.flush);
      expect(await tester.runAsync(() => completed(store)), ['Swamp Thing #21']);

      // On the last page again and the mark taken off there: it stays off
      // while the page does, and when the comic is opened there again.
      await type(tester, 'l');
      await type(tester, 'l');
      expect(await markOf(tester, store, book.key), isTrue);
      await type(tester, 'gC');
      expect(await markOf(tester, store, book.key), isFalse);
      await tester.runAsync(reader.close);
      await settle(tester);
      await tester.runAsync(() => reader.open(book.path));
      await settle(tester);
      expect(c.read(readerProvider).page, 2, reason: 'resumed on the last page');
      expect(await markOf(tester, store, book.key), isFalse, reason: 'opening there is no arrival');
      expect(await tester.runAsync(() => completed(store)), isEmpty);
      // Away and back is one.
      await type(tester, 'h');
      expect(await markOf(tester, store, book.key), isFalse);
      await type(tester, 'l');
      expect(await markOf(tester, store, book.key), isTrue);
    });

    testWidgets('a one-page comic is not marked by being opened', (tester) async {
      writeBook(root, 'Sunday Strip 7.cbz', 1);
      final store = (await tester.runAsync(shelf))!;
      final book = named((await tester.runAsync(store.books))!, 'Sunday Strip #7');
      final c = await pumpApp(tester);
      await settle(tester);
      await tester.runAsync(() => c.read(readerProvider.notifier).open(book.path));
      await settle(tester);
      await type(tester, 'l');
      await type(tester, 'h');
      expect(await markOf(tester, store, book.key), isNull);
    });

    testWidgets('gC on a cover marks it with a sign on the cover, u undoes; with comics marked, all of them', (
      tester,
    ) async {
      final store = (await tester.runAsync(shelf))!;
      final books = (await tester.runAsync(store.books))!;
      final daredevil = named(books, 'Daredevil #181').key;
      await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Books')));
      await settle(tester);
      expect(find.byKey(const Key('completedBadge')), findsNothing);

      await type(tester, 'l'); // Selects the first cover: Daredevil.
      await type(tester, 'gC');
      expect(await markOf(tester, store, daredevil), isTrue);
      expect(find.byKey(const Key('completedBadge')), findsOneWidget);
      expect(find.text('Daredevil #181 marked as completed'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget, reason: 'the details pane says so');

      // u is the notice's Undo: no mark again, not "not completed".
      await type(tester, 'u');
      expect(await markOf(tester, store, daredevil), isNull);
      expect(find.byKey(const Key('completedBadge')), findsNothing);

      // On, then off by the key: marked not completed, and Undo puts it on again.
      await type(tester, 'gC');
      await type(tester, 'gC');
      expect(await markOf(tester, store, daredevil), isFalse);
      expect(find.text('Daredevil #181 marked as not completed'), findsOneWidget);
      await type(tester, 'u');
      expect(await markOf(tester, store, daredevil), isTrue);

      // Two marked (V V): Daredevil is completed, Preacher not, so both are
      // completed after; again, and both are not.
      await type(tester, 'VV');
      expect(find.byKey(const Key('marksCompleted')), findsOneWidget);
      await type(tester, 'gC');
      expect(await tester.runAsync(() => completed(store)), ['Daredevil #181', 'Preacher #1']);
      expect(find.text('1 comic marked as completed'), findsNothing);
      expect(find.text('Preacher #1 marked as completed'), findsOneWidget, reason: 'only the one that changed');
      expect(find.byKey(const Key('marksBar')), findsNothing, reason: 'the marks go once it is done');
      expect(await markOf(tester, store, named(books, 'Swamp Thing #21').key), isNull, reason: 'not marked');

      await type(tester, 'hh');
      await type(tester, 'VV');
      await tester.tap(find.byKey(const Key('marksCompleted')));
      await settle(tester);
      expect(await tester.runAsync(() => completed(store)), isEmpty);
      expect(find.text('2 comics marked as not completed'), findsOneWidget);
      await type(tester, 'u');
      expect(await tester.runAsync(() => completed(store)), ['Daredevil #181', 'Preacher #1']);
    });

    testWidgets('the tick in the details marks the comic and names the key', (tester) async {
      final store = (await tester.runAsync(shelf))!;
      final daredevil = named((await tester.runAsync(store.books))!, 'Daredevil #181').key;
      await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Books')));
      await settle(tester);
      await type(tester, 'l');
      final tick = find.byKey(const Key('completed'));
      expect(tick, findsOneWidget);
      expect(tester.widget<IconButton>(tick).tooltip, 'Mark as completed (gC)');
      expect(find.text('Not started · 4 pages'), findsOneWidget);

      await tester.tap(tick);
      await settle(tester);
      expect(await markOf(tester, store, daredevil), isTrue);
      expect(tester.widget<IconButton>(tick).tooltip, 'Mark as not completed (gC)');
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Not started · 4 pages'), findsNothing);
      expect(find.text('Read again'), findsOneWidget);

      await tester.tap(tick);
      await settle(tester);
      expect(await markOf(tester, store, daredevil), isFalse);
      expect(find.text('Completed'), findsNothing);
      expect(find.byKey(const Key('completedBadge')), findsNothing);
    });

    testWidgets('F filters the Folders tab by completed: only them, without them, all; kept across a start', (
      tester,
    ) async {
      final store = (await tester.runAsync(shelf))!;
      final books = (await tester.runAsync(store.books))!;
      await tester.runAsync(() => store.setCompleted(named(books, 'Daredevil #181').key, true));
      await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      expect(find.text('3 books · 1 read'), findsOneWidget);
      await type(tester, 'l');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // Into Comics.
      await settle(tester);
      Finder cover(String name) => find.descendant(of: find.byKey(const Key('grid')), matching: find.text(name));
      expect(cover('Daredevil #181'), findsOneWidget);
      expect(cover('Preacher #1'), findsOneWidget);

      // Completed only.
      await type(tester, 'F');
      expect(find.byKey(const Key('filterDialog')), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('filterCompleted-any'))).selected, isTrue);
      await tester.tap(find.byKey(const Key('filterCompleted-only')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('filterDone')));
      await settle(tester);
      expect(cover('Daredevil #181'), findsOneWidget);
      expect(cover('Preacher #1'), findsNothing);
      expect(cover('Swamp Thing #21'), findsNothing);
      expect(
        find.descendant(of: find.byKey(const Key('filterBarCompleted')), matching: find.text('Completed only')),
        findsOne,
      );
      expect(
        await tester.runAsync(() => SettingsStore(db).loadString(SettingsStore.folderFilter)),
        contains('"completed":"only"'),
      );

      // Not completed.
      await type(tester, 'F');
      // The test font is wide: the last line of chips is below the dialog's fold.
      await tester.ensureVisible(find.byKey(const Key('filterCompleted-hide')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('filterCompleted-hide')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('filterDone')));
      await settle(tester);
      expect(cover('Daredevil #181'), findsNothing);
      expect(cover('Preacher #1'), findsOneWidget);
      expect(cover('Swamp Thing #21'), findsOneWidget);

      // A new start keeps it, and the folder's count is of what passes.
      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      expect(find.byKey(const Key('filterBarCompleted')), findsOneWidget);
      expect(find.text('2 books'), findsOneWidget);
      expect(find.text('3 books · 1 read'), findsNothing);

      // The part's x takes it off: all three again.
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('filterBarCompleted')),
          matching: find.byTooltip('Take this off the filter'),
        ),
      );
      await settle(tester);
      expect(find.byKey(const Key('filterBarCompleted')), findsNothing);
      expect(find.text('3 books · 1 read'), findsOneWidget);
      expect(await tester.runAsync(() => SettingsStore(db).loadString(SettingsStore.folderFilter)), isNull);
    });
  });
}
