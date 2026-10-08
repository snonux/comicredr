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
import 'package:comicredr/src/library/bulk_actions.dart';
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
import 'package:reader_input/reader_input.dart';

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

/// A library index that refuses the [failAt]th completed mark asked of it,
/// once.
class _FailingMarks extends LibraryStore {
  _FailingMarks(super.db);

  int failAt = 0;
  int _asked = 0;

  @override
  Future<void> setCompleted(String contentKey, bool? on, {DateTime? at}) {
    if (failAt > 0 && ++_asked == failAt) {
      failAt = _asked = 0;
      throw StateError('the index is locked');
    }
    return super.setCompleted(contentKey, on, at: at);
  }
}

extension on LibraryBook {
  /// This comic as the library lists it once it has the completed mark [on].
  LibraryBook marked(bool on) => LibraryBook(
    key: key,
    series: series,
    seriesId: seriesId,
    pageCount: pageCount,
    format: format,
    path: path,
    addedAt: addedAt,
    completedMark: on,
  );
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
      expect(named(books, 'Daredevil #181').completed, isFalse);

      // Begun and part-way: in progress, until it is marked completed there,
      // which takes it out of Continue and takes its progress line away.
      final progress = ProgressStore(db, debounce: Duration.zero);
      progress.save(daredevil, const ReadingPosition(page: 1), 4);
      await progress.flush();
      expect(named(await store.books(), 'Daredevil #181').inProgress, isTrue);
      await store.setCompleted(daredevil, true);
      expect(await store.completedMarkOf(daredevil), isTrue);
      expect(await completed(store), ['Daredevil #181']);
      books = await store.books();
      expect(named(books, 'Daredevil #181').started, isTrue);
      expect(named(books, 'Daredevil #181').finished, isFalse);
      expect(named(books, 'Daredevil #181').inProgress, isFalse);

      await store.setCompleted(daredevil, false);
      expect(await store.completedMarkOf(daredevil), isFalse);
      expect(await completed(store), isEmpty);
      // One row, rewritten: not one per change.
      expect((await db.select(db.overrides).get()).where((o) => o.contentKey == daredevil), hasLength(1));

      // Left on the last page before there was a mark: completed.
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
      // Marked not completed wins over the last page.
      expect(named(books, 'Daredevil #181').finished, isTrue);
      expect(named(books, 'Daredevil #181').completed, isFalse);
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

  test("a series' next comic goes by completed, not by the page it was left on", () {
    LibraryBook issue(int n, {bool? mark, bool finished = false, int? page}) => LibraryBook(
      key: 'k$n',
      series: 'Saga',
      seriesId: 1,
      number: '$n',
      pageCount: 3,
      format: 'cbz',
      path: '/c/Saga $n.cbz',
      addedAt: DateTime(2020),
      page: page,
      finished: finished,
      completedMark: mark,
    );
    // #1 marked completed part-way, #2 marked not completed on its last page, #3 untouched.
    final saga = LibrarySeries.group([
      issue(1, mark: true, page: 1),
      issue(2, mark: false, finished: true, page: 2),
      issue(3),
    ]).single;
    expect(saga.read, 1);
    expect(saga.next.number, '2', reason: '#1 is completed though not on its last page; #2 is not, though on it');
    // All completed: back to the first.
    expect(LibrarySeries.group([issue(1, mark: true), issue(2, finished: true, page: 2)]).single.next.number, '1');
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

    test('an import counts completed marks apart from edits, and leaves out what it has none of', () async {
      await laptop.library.setCompleted('a', true, at: at(0));
      await laptop.library.setCompleted('b', false, at: at(0));
      await laptop.library.setCompleted('c', true, at: at(0));
      var file = SettingsFile.decode(await exportSettings(laptop.db));
      expect((file.metaEditCount, file.completedMarkCount), (0, 3));
      var done = await importSettings(file, library: phone.library);
      expect((done.edits, done.completed), (0, 3));
      expect(importNotice(done), 'Imported the default settings and 3 completed marks.');

      // With an edit of a title beside them: each under its own name.
      await laptop.db
          .into(laptop.db.overrides)
          .insert(
            OverridesCompanion.insert(
              contentKey: 'a',
              field: MetaField.title.name,
              value: MetaEdit('Anatomy Lesson', at: at(1)).encode(),
            ),
          );
      await (laptop.db.delete(laptop.db.overrides)..where((o) => o.contentKey.isIn(['b', 'c']))).go();
      file = SettingsFile.decode(await exportSettings(laptop.db));
      expect((file.metaEditCount, file.completedMarkCount), (1, 1));
      done = await importSettings(file, library: phone.library);
      expect(importNotice(done), 'Imported the default settings, 1 edit and 1 completed mark.');
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
          'd' => LogicalKeyboardKey.keyD,
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

    /// The mark's row as stored, time and all.
    Future<String?> rowOf(WidgetTester tester, String key) => tester.runAsync<String?>(
      () async => (await (db.select(
        db.overrides,
      )..where((o) => o.contentKey.equals(key) & o.field.equals(completedField))).getSingleOrNull())?.value,
    );

    /// An intent sent as the page grid, the progress bar or a touch sends it.
    Future<void> send(WidgetTester tester, ProviderContainer c, ReaderIntent intent) async {
      await tester.runAsync(() => c.read(readerProvider.notifier).handle(ReaderCommand(intent)));
      await settle(tester);
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);
    }

    /// A notice that must be read stays its time and whatever comes waits
    /// behind it: lets it run out, so the next one shows.
    Future<void> noticeOver(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 11));
      await settle(tester);
    }

    /// The comic the library's details pane shows, which is the selected
    /// cover's; null with none selected.
    String? selected(WidgetTester tester) {
      final pane = find.byKey(const Key('detail'));
      if (pane.evaluate().isEmpty) return null;
      for (final name in const ['Akira #1', 'Daredevil #181', 'Preacher #1', 'Swamp Thing #21', 'Zot #2']) {
        if (find.descendant(of: pane, matching: find.text(name)).evaluate().isNotEmpty) return name;
      }
      return fail('the details pane shows a comic the test does not know');
    }

    /// Five comics in one folder, the Folders tab inside it, filtered by
    /// completed as [filter] says.
    Future<(ProviderContainer, LibraryStore, List<LibraryBook>)> filtered(
      WidgetTester tester,
      CompletedFilter filter, {
      List<String> completedFirst = const [],
    }) async {
      writeBook(root, 'Akira 1.cbz', 5);
      writeBook(root, 'Zot 2.cbz', 6);
      final store = (await tester.runAsync(shelf))!;
      final books = (await tester.runAsync(store.books))!;
      await tester.runAsync(() async {
        for (final name in completedFirst) {
          await store.setCompleted(named(books, name).key, true);
        }
        await SettingsStore(db).saveString(SettingsStore.folderFilter, FolderFilter(completed: filter).encode()!);
      });
      final c = await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.text('Folders'));
      await settle(tester);
      await type(tester, 'l');
      await press(tester, LogicalKeyboardKey.enter); // Into Comics.
      return (c, store, books);
    }

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
      final row = await rowOf(tester, book.key);

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
      // Marked already: the row is left as it is, time included, so arriving
      // again is no newer change for a sidecar merge to go by.
      expect(await rowOf(tester, book.key), row);
      await type(tester, 'gC');
      expect(await markOf(tester, store, book.key), isFalse);
      await tester.runAsync(reader.close);
      await settle(tester);
      await tester.runAsync(() => reader.open(book.path));
      await settle(tester);
      expect(c.read(readerProvider).page, 2, reason: 'resumed on the last page');
      expect(await markOf(tester, store, book.key), isFalse, reason: 'opening there is no arrival');
      expect(await tester.runAsync(() => completed(store)), isEmpty);
      // A step on that goes nowhere is no arrival either.
      await type(tester, 'l');
      expect(await markOf(tester, store, book.key), isFalse);
      // Away and back is one, also after "not completed" was said: read to
      // the end again, it is completed again.
      await type(tester, 'h');
      expect(await markOf(tester, store, book.key), isFalse);
      await type(tester, 'l');
      expect(await markOf(tester, store, book.key), isTrue);
    });

    testWidgets(
      'a jump to the last page marks nothing: G, the page grid, a bookmark, a mark, another device\'s place',
      (tester) async {
        final store = (await tester.runAsync(shelf))!;
        final book = named((await tester.runAsync(store.books))!, 'Daredevil #181'); // Four pages.
        final c = await pumpApp(tester);
        await settle(tester);
        final reader = c.read(readerProvider.notifier);
        await tester.runAsync(() => reader.open(book.path));
        await settle(tester);
        Future<void> stillUnmarked(String why) async {
          expect(c.read(readerProvider).page, 3, reason: '$why goes to the last page');
          expect(await markOf(tester, store, book.key), isNull, reason: '$why is no reading to the end');
          expect(c.read(readerProvider).message, isNot('Last page: marked as completed'));
        }

        await type(tester, 'G');
        await stillUnmarked('G');
        // A bookmark and the mark a there, for later.
        await send(tester, c, ReaderIntent.bookmark);
        await tester.runAsync(() => reader.handle(const ReaderCommand(ReaderIntent.setMark, register: 'a')));
        await settle(tester);

        await send(tester, c, ReaderIntent.firstPage);
        reader.jumpTo(3); // The page grid's and the progress bar's way.
        await settle(tester);
        await stillUnmarked('the page grid');

        await send(tester, c, ReaderIntent.firstPage);
        await send(tester, c, ReaderIntent.nextBookmark);
        await stillUnmarked('the next bookmark');

        await send(tester, c, ReaderIntent.firstPage);
        await tester.runAsync(() => reader.handle(const ReaderCommand(ReaderIntent.jumpMark, register: 'a')));
        await settle(tester);
        await stillUnmarked('a mark');

        await send(tester, c, ReaderIntent.firstPage);
        await send(tester, c, ReaderIntent.jumpBack);
        await stillUnmarked('the jump back');

        // The place another device left it at, taken up here.
        await send(tester, c, ReaderIntent.firstPage);
        await tester.runAsync(
          () => reader.acceptOffer((
            path: book.path,
            contentKey: book.key,
            at: SidecarProgress(
              device: 'phone',
              deviceName: 'Phone',
              page: 3,
              percent: 1,
              finished: true,
              updatedAt: DateTime.now(),
            ),
          )),
        );
        await settle(tester);
        await stillUnmarked('the offered place');

        // Unmarked on its last page it counts as completed all the same, so
        // the first gC there says not completed.
        await type(tester, 'gC');
        expect(c.read(readerProvider).message, 'Marked as not completed');
        expect(await markOf(tester, store, book.key), isFalse);

        // Read on to it, it is marked.
        await type(tester, 'h');
        await type(tester, 'l');
        expect(await markOf(tester, store, book.key), isTrue);
      },
    );

    testWidgets('two-page mode: the step onto the last pair marks, though the page it is saved on is not the last', (
      tester,
    ) async {
      final store = (await tester.runAsync(shelf))!;
      final book = named((await tester.runAsync(store.books))!, 'Swamp Thing #21'); // Three pages: 1, then 2-3.
      final c = await pumpApp(tester);
      await settle(tester);
      await tester.runAsync(() => c.read(readerProvider.notifier).open(book.path));
      await settle(tester);
      await type(tester, 'd');
      expect(c.read(readerProvider).unit, [0]);
      expect(await markOf(tester, store, book.key), isNull);
      await type(tester, 'l');
      expect(c.read(readerProvider).unit, [1, 2]);
      expect(c.read(readerProvider).page, 1);
      expect(await markOf(tester, store, book.key), isTrue);
    });

    testWidgets('guided view and right to left: the step that turns onto the last page marks', (tester) async {
      await tester.runAsync(() => SettingsStore(db).saveBool(SettingsStore.pauseWhole, false));
      final store = (await tester.runAsync(shelf))!;
      final books = (await tester.runAsync(store.books))!;
      final swamp = named(books, 'Swamp Thing #21'), preacher = named(books, 'Preacher #1');
      final c = await pumpApp(tester);
      await settle(tester);
      final reader = c.read(readerProvider.notifier);
      await tester.runAsync(() => reader.open(swamp.path));
      await settle(tester);
      await type(tester, 'v');
      expect(c.read(readerProvider).guided, isTrue);
      // G in guided view is a jump there too.
      await type(tester, 'G');
      expect(c.read(readerProvider).page, 2);
      expect(await markOf(tester, store, swamp.key), isNull);
      await send(tester, c, ReaderIntent.firstPage);
      await type(tester, 'l');
      expect(c.read(readerProvider).page, 1);
      expect(await markOf(tester, store, swamp.key), isNull);
      await type(tester, 'l');
      expect(c.read(readerProvider).page, 2);
      expect(await markOf(tester, store, swamp.key), isTrue);
      await type(tester, 'v');
      await tester.runAsync(reader.close);
      await settle(tester);

      // Right to left, h is the key that reads on, and l goes back.
      await tester.runAsync(() => reader.open(preacher.path)); // Two pages.
      await settle(tester);
      await send(tester, c, ReaderIntent.toggleDirection);
      expect(c.read(readerProvider).rightToLeft, isTrue);
      await type(tester, 'l');
      expect(c.read(readerProvider).page, 0);
      expect(await markOf(tester, store, preacher.key), isNull);
      await type(tester, 'h');
      expect(c.read(readerProvider).page, 1);
      expect(await markOf(tester, store, preacher.key), isTrue);
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

    testWidgets('under Not completed a comic marked completed leaves and the cover next to it is selected', (
      tester,
    ) async {
      final (c, store, books) = await filtered(tester, CompletedFilter.hide);
      Finder cover(String name) => find.descendant(of: find.byKey(const Key('grid')), matching: find.text(name));
      // The first cover, selected on walking into the folder: the one after it.
      expect(selected(tester), 'Akira #1');
      await type(tester, 'gC');
      expect(cover('Akira #1'), findsNothing);
      expect(selected(tester), 'Daredevil #181');
      // Undo brings it back and leaves the selection, as for a favourite.
      await type(tester, 'u');
      expect(cover('Akira #1'), findsOneWidget);
      expect(selected(tester), 'Daredevil #181');

      // One in the middle, by the tick in its details: the one after it.
      await type(tester, 'l');
      expect(selected(tester), 'Preacher #1');
      await tester.tap(find.byKey(const Key('completed')));
      await settle(tester);
      expect(cover('Preacher #1'), findsNothing);
      expect(selected(tester), 'Swamp Thing #21');

      // The last: the one before it, and Enter opens that one.
      await press(tester, LogicalKeyboardKey.end);
      expect(selected(tester), 'Zot #2');
      await type(tester, 'gC');
      expect(cover('Zot #2'), findsNothing);
      expect(selected(tester), 'Swamp Thing #21');
      // The comic opens on isolates and real files, which need the real event loop.
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await settle(tester);
      expect(c.read(readerProvider).book?.key, named(books, 'Swamp Thing #21').key);
      // Read to its last page there, it leaves too: back in the library the
      // cover before it is selected (none comes after).
      await type(tester, 'l');
      await type(tester, 'l');
      expect(await markOf(tester, store, named(books, 'Swamp Thing #21').key), isTrue);
      await tester.runAsync(c.read(readerProvider.notifier).close);
      await settle(tester);
      expect(cover('Swamp Thing #21'), findsNothing);
      expect(selected(tester), 'Daredevil #181');

      // With comics marked (a run of two, the cursor on the second), by the
      // marks bar: both leave, and nothing is left to select.
      await press(tester, LogicalKeyboardKey.home);
      await press(tester, LogicalKeyboardKey.arrowRight, shift: true);
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.byKey(const Key('marksCompleted')));
      await settle(tester);
      expect(find.text('2 comics marked as completed'), findsOneWidget);
      expect(await tester.runAsync(() => completed(store)), hasLength(5));
      expect(find.byKey(const Key('grid')), findsNothing);
      expect(selected(tester), isNull);
    });

    testWidgets('with comics marked, the cover after the last of them is selected; a changed filter selects nothing', (
      tester,
    ) async {
      final all = ['Akira #1', 'Daredevil #181', 'Preacher #1', 'Swamp Thing #21', 'Zot #2'];
      final (_, store, _) = await filtered(tester, CompletedFilter.only, completedFirst: all);
      Finder cover(String name) => find.descendant(of: find.byKey(const Key('grid')), matching: find.text(name));
      // Daredevil to Preacher marked, the cursor on Preacher: marked not
      // completed under Completed only, they leave and Swamp Thing has it.
      await type(tester, 'l');
      expect(selected(tester), 'Daredevil #181');
      await press(tester, LogicalKeyboardKey.arrowRight, shift: true);
      await type(tester, 'gC');
      expect(find.text('2 comics marked as not completed'), findsOneWidget);
      expect(cover('Daredevil #181'), findsNothing);
      expect(cover('Preacher #1'), findsNothing);
      expect(selected(tester), 'Swamp Thing #21');
      expect(await tester.runAsync(() => completed(store)), ['Akira #1', 'Swamp Thing #21', 'Zot #2']);

      // A change of the filter is nothing done to a comic: it drops the
      // selection, as for any other part of the filter, also when the new
      // filter hides the comic that was selected and keeps covers beside it.
      Future<void> pick(String chip) async {
        await type(tester, 'F');
        await tester.ensureVisible(find.byKey(Key(chip)));
        await settle(tester);
        await tester.tap(find.byKey(Key(chip)));
        await settle(tester);
        await tester.tap(find.byKey(const Key('filterDone')));
        await settle(tester);
      }

      await pick('filterCompleted-any');
      expect(cover('Daredevil #181'), findsOneWidget);
      expect(selected(tester), isNull);
      await press(tester, LogicalKeyboardKey.end);
      await type(tester, 'h');
      expect(selected(tester), 'Swamp Thing #21');
      await pick('filterCompleted-hide');
      expect(cover('Swamp Thing #21'), findsNothing);
      expect(cover('Daredevil #181'), findsOneWidget);
      expect(selected(tester), isNull);
    });

    testWidgets('the Reading tab puts a comic marked completed part-way after the ones still being read', (
      tester,
    ) async {
      final store = (await tester.runAsync(shelf))!;
      final books = (await tester.runAsync(store.books))!;
      final daredevil = named(books, 'Daredevil #181').key, swamp = named(books, 'Swamp Thing #21').key;
      await tester.runAsync(() async {
        // Both part-way; Swamp Thing read last, and marked completed there.
        for (final (key, page, pages, minute) in [(daredevil, 1, 4, 0), (swamp, 1, 3, 30)]) {
          final progress = ProgressStore(db, debounce: Duration.zero)..save(key, ReadingPosition(page: page), pages);
          await progress.flush();
          await (db.update(
            db.progress,
          )..where((r) => r.contentKey.equals(key))).write(ProgressCompanion(updatedAt: Value(at(minute))));
        }
        await store.setCompleted(swamp, true);
      });
      await pumpApp(tester);
      await settle(tester);
      Finder cover(String name) => find.descendant(of: find.byKey(const Key('grid')), matching: find.text(name));
      expect(cover('Preacher #1'), findsNothing, reason: 'the Reading tab: only comics begun');
      // By the page alone neither is finished and the later read would be first.
      expect(tester.getTopLeft(cover('Daredevil #181')).dx, lessThan(tester.getTopLeft(cover('Swamp Thing #21')).dx));
      expect(tester.getTopLeft(cover('Daredevil #181')).dy, tester.getTopLeft(cover('Swamp Thing #21')).dy);
    });

    testWidgets('comics only on S3 are left out and the notice says so; a failing index names what was marked', (
      tester,
    ) async {
      LibraryBook book(String name, {bool remote = false}) => LibraryBook(
        key: name,
        series: name,
        seriesId: 1,
        pageCount: 4,
        format: 'cbz',
        path: '${root.path}/$name.cbz',
        addedAt: DateTime(2026),
        s3: remote ? const S3Shelf(S3Mark.remote, size: 1000) : null,
      );
      final failing = _FailingMarks(db);
      var books = <LibraryBook>[];
      bool? went;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            coverDirProvider.overrideWithValue(covers),
            libraryStoreProvider.overrideWithValue(failing),
            noSidecars(db),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () async => went = await toggleCompleted(context, ref, books),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> go(List<LibraryBook> on) async {
        books = on;
        went = null;
        await tester.tap(find.text('go'));
        await settle(tester);
      }

      final akira = book('Akira'), blacksad = book('Blacksad'), corto = book('Corto');
      final cloud = book('Cloud', remote: true), mist = book('Mist', remote: true);

      // Only on S3: nothing is marked, and it says why.
      await go([cloud]);
      expect(went, isFalse);
      expect(find.text('Only on S3: download it first'), findsOneWidget);
      expect(await markOf(tester, failing, 'Cloud'), isNull);
      await go([cloud, mist]);
      expect(find.text('All 2 comics are only on S3: download them first'), findsOneWidget);
      expect(await tester.runAsync(() => db.select(db.overrides).get()), isEmpty);

      // Some of them: the others are marked, and the notice counts those left out.
      await go([akira, cloud, mist]);
      expect(went, isTrue);
      expect(find.text('Akira marked as completed; 2 are only on S3'), findsOneWidget);
      expect(await markOf(tester, failing, 'Akira'), isTrue);
      expect(await markOf(tester, failing, 'Cloud'), isNull);
      expect(await markOf(tester, failing, 'Mist'), isNull);
      await tester.runAsync(() => failing.setCompleted('Akira', null));
      await go([akira, blacksad, cloud]);
      expect(find.text('2 comics marked as completed; 1 is only on S3'), findsOneWidget);
      await tester.runAsync(() async {
        await failing.setCompleted('Akira', null);
        await failing.setCompleted('Blacksad', null);
      });

      // The index refuses the second of three: the first keeps its mark and
      // is the one named; the two after it are counted, not named as marked.
      failing.failAt = 2;
      await go([akira, blacksad, corto]);
      expect(went, isFalse, reason: 'not all of it went ahead, so marks would stay');
      expect(find.text('Akira marked as completed; 2 not marked: the library could not be updated'), findsOneWidget);
      expect(await markOf(tester, failing, 'Akira'), isTrue);
      expect(await markOf(tester, failing, 'Blacksad'), isNull);
      expect(await markOf(tester, failing, 'Corto'), isNull);

      // Refused at the first, with one of the three marked already: the two
      // that were to be marked are named, not all three.
      await noticeOver(tester);
      failing.failAt = 1;
      await go([book('Akira').marked(true), blacksad, corto]);
      expect(went, isFalse);
      expect(find.text('Could not mark 2 comics as completed: the library could not be updated'), findsOneWidget);
      expect(find.text('Could not mark 3 comics as completed: the library could not be updated'), findsNothing);
      expect(await markOf(tester, failing, 'Blacksad'), isNull);
      // And one alone by its name.
      await noticeOver(tester);
      failing.failAt = 1;
      await go([book('Akira').marked(true), blacksad]);
      expect(find.text('Could not mark Blacksad as completed: the library could not be updated'), findsOneWidget);

      expect(completedNotice([akira], [akira], on: false), 'Akira marked as not completed');
      expect(
        completedNotice([], [akira, corto], on: false, onlyOnS3: 1),
        'Could not mark 2 comics as not completed: the library could not be updated; 1 is only on S3',
      );
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
