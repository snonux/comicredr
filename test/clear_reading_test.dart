import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/meta_edits.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
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

class _RefusedStart extends LibraryStore {
  _RefusedStart(super.db);
  bool refuse = true;

  @override
  Future<void> setStarted(String contentKey, bool? on, {DateTime? at}) {
    if (refuse) throw StateError('index locked');
    return super.setStarted(contentKey, on, at: at);
  }
}

/// The Reading list (snonux, 2026-10-17): a comic counts as started only
/// once it was open for five minutes in one go, and `gR` clears the list, every
/// comic's place and completed mark, on every device its sidecar reaches.
void main() {
  late Directory tmp;
  late Directory root;
  late String covers;
  late AppDatabase db;
  final t0 = DateTime(2026, 10, 17, 21);
  DateTime at(int minute) => t0.add(Duration(minutes: minute));

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('clear_reading_test');
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

  Future<List<String>> started(LibraryStore store) async => [
    for (final b in await store.books())
      if (b.started) b.name,
  ]..sort();

  group('five minutes before a comic counts as started', () {
    test('a peek keeps the place but not the start; an older position without the flag counts', () async {
      final store = await shelf();
      final books = await store.books();
      final progress = ProgressStore(db, debounce: Duration.zero);
      progress.save(named(books, 'Daredevil #181').key, const ReadingPosition(page: 2, peek: true), 4);
      await progress.flush();
      progress.save(named(books, 'Preacher #1').key, const ReadingPosition(page: 0), 2);
      await progress.flush();
      final daredevil = named(await store.books(), 'Daredevil #181');
      expect(daredevil.page, 2, reason: 'the place is kept for the next open');
      expect(daredevil.peek, isTrue);
      expect(daredevil.started, isFalse);
      expect(daredevil.inProgress, isFalse);
      expect(await started(store), ['Preacher #1']);
      expect((await progress.load(daredevil.key))!.peek, isTrue);
    });

    test('the reader saves a peek until the comic was open five minutes, then a start', () async {
      final store = await shelf();
      final path = named(await store.books(), 'Daredevil #181').path;
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue(covers),
          noSidecars(db),
          classicCvOnly,
        ],
      );
      addTearDown(c.dispose);
      var now = t0;
      final reader = c.read(readerProvider.notifier)..clock = () => now;

      // Opened and closed again within five minutes, a page turned: a peek.
      await reader.open(path);
      now = at(0).add(const Duration(seconds: 30));
      reader.jumpTo(1);
      await reader.close();
      expect(await started(store), isEmpty);
      expect(named(await store.books(), 'Daredevil #181').page, 1);

      // A new open counts from its own start: 4 minutes 59 seconds is not enough.
      now = at(10);
      await reader.open(path);
      expect(c.read(readerProvider).page, 1, reason: 'the peek kept the place');
      now = at(10).add(const Duration(minutes: 4, seconds: 59));
      await reader.close();
      expect(await started(store), isEmpty);

      // Left on one page for over five minutes: started on close, no page turn needed.
      now = at(20);
      await reader.open(path);
      now = at(25);
      await reader.close();
      expect(await started(store), ['Daredevil #181']);

      // Started stays started, however short the next look.
      now = at(30);
      await reader.open(path);
      await reader.close();
      expect(await started(store), ['Daredevil #181']);
    });

    test('a turn after five minutes saves the start at once, and pause saves it too', () async {
      final store = await shelf();
      final books = await store.books();
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue(covers),
          noSidecars(db),
          classicCvOnly,
        ],
      );
      addTearDown(c.dispose);
      var now = t0;
      final reader = c.read(readerProvider.notifier)..clock = () => now;
      await reader.open(named(books, 'Daredevil #181').path);
      now = at(5);
      reader.jumpTo(2);
      await c.read(progressStoreProvider).flush();
      expect(await started(store), ['Daredevil #181']);

      await reader.open(named(books, 'Preacher #1').path);
      now = at(10);
      await reader.flush();
      expect(await started(store), ['Daredevil #181', 'Preacher #1']);
    });
  });

  group('manual started marks', () {
    test('mark a never-opened comic; unmark keeps the place; clearing includes marks without a place', () async {
      final store = await shelf();
      final books = await store.books();
      final key = named(books, 'Daredevil #181').key;
      await store.setStarted(key, true);
      expect(await started(store), ['Daredevil #181']);
      expect(named(await store.books(), 'Daredevil #181').page, isNull);
      final progress = ProgressStore(db, debounce: Duration.zero);
      progress.save(key, const ReadingPosition(page: 2), 4);
      await progress.flush();
      await store.setStarted(key, false);
      expect(await started(store), isEmpty);
      expect((await progress.load(key))!.page, 2);
      await store.setStarted(key, null);
      expect(await started(store), ['Daredevil #181'], reason: 'Undo restores the automatic start');
      final neverOpened = named(books, 'Preacher #1').key;
      await store.setStarted(neverOpened, true);
      expect(await store.clearReading(), {key, neverOpened});
      expect(await started(store), isEmpty);
      expect(await store.startedMarkOf(neverOpened), isNull);
    });

    test("a manual removal travels without dropping either device's place", () async {
      final laptop = Device(), phone = Device();
      addTearDown(laptop.db.close);
      addTearDown(phone.db.close);
      final path = writeBook(root, 'Shared.cbz', 4);
      final key = await contentKey(path);
      for (final d in [laptop, phone]) {
        await d.sync.attach(path, key, folder: false);
        d.progress.save(key, const ReadingPosition(page: 2), 4);
        await d.progress.flush();
      }
      await laptop.library.setStarted(key, true, at: at(1));
      await laptop.sync.write(key);
      await phone.sync.attach(path, key, folder: false);
      expect(await phone.library.startedMarkOf(key), isTrue);
      await phone.library.setStarted(key, false, at: at(2));
      await phone.sync.write(key);
      await laptop.sync.attach(path, key, folder: false);
      expect(await laptop.library.startedMarkOf(key), isFalse);
      expect((await laptop.progress.load(key))!.page, 2);
      expect((await phone.progress.load(key))!.page, 2);
      await laptop.library.setStarted(key, true, at: at(3));
      await laptop.sync.write(key);
      await phone.sync.attach(path, key, folder: false);
      expect(await phone.library.startedMarkOf(key), isTrue);
    });

    test('a refused manual removal preserves an automatic start and reports the error', () async {
      final store = await shelf();
      final book = named(await store.books(), 'Daredevil #181');
      final progress = ProgressStore(db, debounce: Duration.zero);
      progress.save(book.key, const ReadingPosition(page: 1), 4);
      await progress.flush();
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue(covers),
          libraryStoreProvider.overrideWithValue(_RefusedStart(db)),
          noSidecars(db),
          classicCvOnly,
        ],
      );
      addTearDown(c.dispose);
      final reader = c.read(readerProvider.notifier);
      await reader.open(book.path);
      await reader.handle(const ReaderCommand(ReaderIntent.toggleStarted));
      expect(c.read(readerProvider).message, contains('Could not change the started mark'));
      await reader.close();
      expect(named(await store.books(), book.name).started, isTrue);
      expect((await progress.load(book.key))!.page, 1);
    });

    test('gb removes a start until a fresh five-minute sitting, even after reopen; pause time is excluded', () async {
      final store = await shelf();
      final book = named(await store.books(), 'Daredevil #181');
      await store.setStarted(book.key, true);
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue(covers),
          noSidecars(db),
          classicCvOnly,
        ],
      );
      addTearDown(c.dispose);
      var now = t0;
      final reader = c.read(readerProvider.notifier)..clock = () => now;
      await reader.open(book.path);
      reader.jumpTo(1);
      now = at(6);
      await reader.handle(const ReaderCommand(ReaderIntent.toggleStarted));
      await reader.close();
      expect(await started(store), isEmpty, reason: 'close must not undo the manual removal');
      expect(named(await store.books(), book.name).page, 1);
      now = at(10);
      await reader.open(book.path);
      now = at(14);
      await reader.pauseSitting();
      now = at(29);
      reader.jumpTo(2);
      await reader.flush();
      expect(await started(store), isEmpty, reason: 'saving while hidden must not start it');
      now = at(30);
      reader.resumeSitting();
      reader.jumpTo(2);
      await reader.flush();
      expect(await started(store), isEmpty, reason: 'time away is not reading');
      now = at(35);
      await reader.flush();
      expect(await started(store), [book.name]);
      // Two back-to-back toggles must persist in command order.
      final off = reader.handle(const ReaderCommand(ReaderIntent.toggleStarted));
      final on = reader.handle(const ReaderCommand(ReaderIntent.toggleStarted));
      await Future.wait([off, on]);
      await reader.close();
      expect(await started(store), [book.name]);
    });
  });

  group('clearing the Reading list', () {
    test('forgets every place and completed mark, keeps bookmarks, and says when', () async {
      final store = await shelf();
      final books = await store.books();
      final daredevil = named(books, 'Daredevil #181').key;
      final preacher = named(books, 'Preacher #1').key;
      final swamp = named(books, 'Swamp Thing #21').key;
      final progress = ProgressStore(db, debounce: Duration.zero);
      progress.save(daredevil, const ReadingPosition(page: 1), 4);
      await progress.flush();
      progress.save(preacher, const ReadingPosition(page: 1), 2);
      await progress.flush();
      await store.setCompleted(preacher, true, at: at(0));
      await store.setCompleted(swamp, false, at: at(0)); // Marked, never opened.
      await db
          .into(db.bookmarks)
          .insert(BookmarksCompanion.insert(id: 'b1', contentKey: daredevil, page: 2, createdAt: at(0)));
      expect(await store.withReadingStatus(), {daredevil, preacher, swamp});

      expect(await store.clearReading(at: at(5)), {daredevil, preacher, swamp});
      final after = await store.books();
      expect(after.where((b) => b.started || b.completed || b.page != null), isEmpty);
      expect(await store.completedMarkOf(preacher), isNull);
      expect(await store.completedMarkOf(swamp), isNull);
      expect(await db.select(db.bookmarks).get(), hasLength(1));
      final rows = await (db.select(db.overrides)..where((o) => o.field.equals(readingClearedField))).get();
      expect(
        {for (final r in rows) r.contentKey: readingClearedAt(r.value)},
        {daredevil: at(5), preacher: at(5), swamp: at(5)},
      );
      expect(activeEdits({for (final r in rows) r.field: r.value}), isEmpty, reason: 'no metadata edit');
      expect(await store.withReadingStatus(), isEmpty);
      expect(await store.clearReading(), isEmpty);
    });

    test('travels in the sidecar: older places on every device stop counting, newer ones count', () async {
      final laptop = Device(), phone = Device();
      addTearDown(laptop.db.close);
      addTearDown(phone.db.close);
      final path = writeBook(Directory('${tmp.path}/shared')..createSync(), 'Daredevil 181.cbz', 4);
      final key = await contentKey(path);

      // Read on both; the phone's place reaches the laptop's sidecar.
      for (final d in [phone, laptop]) {
        await d.sync.attach(path, key, folder: false);
        d.progress.save(key, const ReadingPosition(page: 2), 4);
        await d.progress.flush();
        await d.sync.write(key);
      }
      expect(readSidecar(sidecarPath(path, folder: false))!.progress, hasLength(2));

      // The laptop clears its list; on the next open the phone's place is not taken back.
      await laptop.library.clearReading();
      await laptop.sync.write(key);
      await laptop.sync.attach(path, key, folder: false);
      expect(await laptop.progress.load(key), isNull);

      // The phone reads the sidecar: its own place goes too.
      final import = await phone.sync.attach(path, key, folder: false);
      expect(import.elsewhere, isNull);
      expect(await phone.progress.load(key), isNull);

      // Read again on the phone after the clearing: that place counts, and the laptop takes it up.
      // Positions are kept to the second: this one is in the next.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      phone.progress.save(key, const ReadingPosition(page: 3), 4);
      await phone.progress.flush();
      await phone.sync.write(key);
      final back = await laptop.sync.attach(path, key, folder: false);
      expect(back.adopted?.page, 3);
      expect((await laptop.progress.load(key))?.page, 3);
    });

    testWidgets('gR asks, Enter cancels, Alt+L clears; with nothing to clear it only says so', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = (await tester.runAsync(shelf))!;
      final key = named((await tester.runAsync(store.books))!, 'Daredevil #181').key;
      await tester.runAsync(() async {
        final progress = ProgressStore(db, debounce: Duration.zero);
        progress.save(key, const ReadingPosition(page: 1), 4);
        await progress.flush();
      });
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
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> gR() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'g');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR, character: 'R');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await settle();
      }

      await settle();
      await gR();
      expect(find.text('Clear the Reading list?'), findsOneWidget);
      expect(find.textContaining('Forgets where you are in 1 comic'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle();
      expect(find.text('Clear the Reading list?'), findsNothing);
      expect(await tester.runAsync(() => ProgressStore(db).load(key)), isNotNull, reason: 'Cancel had the focus');

      await gR();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await settle();
      expect(find.text('Clear the Reading list?'), findsNothing);
      expect(await tester.runAsync(() => ProgressStore(db).load(key)), isNull);
      expect(find.text('Reading list cleared: 1 comic starts unread again'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await settle();
      await gR();
      expect(find.text('Clear the Reading list?'), findsNothing);
      expect(find.text('The Reading list is empty already'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
