import 'dart:async';
import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/data/s3_sync.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/open_book.dart';
import 'package:comicredr/src/reader/panel_detector.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reset_dialog.dart';
import 'package:drift/drift.dart' show Table, TableInfo;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Key;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'balloon_test.dart' show FakeModel;
import 'support/fixtures.dart';

/// A detector that holds its first answer until [release] completes, like a
/// slow model still busy on the old book when the next one opens.
class _HeldModel extends FakeModel {
  _HeldModel(this.release);

  final Completer<void> release;

  @override
  Future<DetectedPage> detect(ComicDocument doc, int page) async {
    await release.future;
    return super.detect(doc, page);
  }
}

class _EnteredModel extends FakeModel {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<DetectedPage> detect(ComicDocument doc, int page) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.detect(doc, page);
  }
}

class _HeldPanelStore extends PanelStore {
  _HeldPanelStore(super.db);

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> save(String contentKey, int page, DetectedPage found) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await super.save(contentKey, page, found);
  }
}

class _HeldAttachSidecars extends SidecarSync {
  _HeldAttachSidecars(super.db, {required super.progress, this.heldPath, this.realAttach = false});

  final String? heldPath;
  final bool realAttach;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<SidecarImport> attach(String path, String contentKey, {required bool folder, bool whole = false}) async {
    if (heldPath == null || path == heldPath) {
      entered.complete();
      await release.future;
    }
    return realAttach ? super.attach(path, contentKey, folder: folder, whole: whole) : SidecarImport.none;
  }

  @override
  void touch(String contentKey) {}

  @override
  Future<bool> write(String contentKey) async => true;

  @override
  Future<void> flush() => progress.flush();
}

class _HeldCloseFlushSidecars extends SidecarSync {
  _HeldCloseFlushSidecars(super.db, {required super.progress}) : super(debounce: Duration.zero);

  bool hold = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> flush() async {
    if (hold) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await super.flush();
  }
}

class _HeldLeaveUnreadStore extends LibraryStore {
  _HeldLeaveUnreadStore(super.db);

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> leaveUnread(String contentKey) async {
    entered.complete();
    await release.future;
    return super.leaveUnread(contentKey);
  }
}

class _NoPullS3Sync extends S3Sync {
  _NoPullS3Sync(super.db, {required super.sidecars, required super.settings})
    : super(storeFor: (_) => throw UnimplementedError(), coverDir: null);

  @override
  Future<bool> pullOnOpen(String contentKey, {Duration limit = const Duration(seconds: 2)}) async => false;

  @override
  Future<void> flush({Duration limit = const Duration(seconds: 5)}) async {}
}

class _ImportingS3Sync extends _NoPullS3Sync {
  _ImportingS3Sync(
    super.db, {
    required super.sidecars,
    required super.settings,
    required this.target,
    required this.downloaded,
  });

  final String target;
  final String downloaded;

  @override
  Future<bool> pullOnOpen(String contentKey, {Duration limit = const Duration(seconds: 2)}) async {
    await sidecars.replaceWith(contentKey, target, downloaded);
    return true;
  }
}

class _TrackedDoc implements ComicDocument {
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeldNeighbourStore extends LibraryStore {
  _HeldNeighbourStore(super.db, this.nextPath);

  final String nextPath;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<({String? path})?> seriesNeighbour(String contentKey, {required bool next}) async {
    entered.complete();
    await release.future;
    return (path: nextPath);
  }
}

class _HeldImportDatabase extends AppDatabase {
  _HeldImportDatabase(super.executor);

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> deleteBookRows(String contentKey, Iterable<TableInfo<Table, Object?>> tables) async {
    if (tables.any((t) => t.actualTableName == collectionBooks.actualTableName)) {
      entered.complete();
      await release.future;
    }
    await super.deleteBookRows(contentKey, tables);
  }
}

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('reader_race_test');
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a book opened while the last one was detecting gets its panels', () async {
    final release = Completer<void>();
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noSidecars(db),
        panelDetectorProvider.overrideWith((ref) async => _HeldModel(release)),
      ],
    );
    addTearDown(c.dispose);
    final a = writeBookOf(tmp, 'A 01.cbz', [grid4Page(), grid4Page()]);
    final b = writeBookOf(tmp, 'B 01.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    final reader = c.read(readerProvider.notifier);

    await reader.open(a);
    await reader.handle(const ReaderCommand(ReaderIntent.toggleGuided));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reader.detecting, isTrue, reason: 'A is waiting on the detector');

    await reader.open(b);
    expect(c.read(readerProvider).guided, isTrue);
    release.complete();
    for (var i = 0; i < 50 && c.read(readerProvider).panels.length < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final s = c.read(readerProvider);
    expect(s.book!.path, b);
    expect(s.panels.keys.toSet(), {0, 1, 2}, reason: "every page of B detected, not left without panels");
    expect(s.panels[0]!.frames, hasLength(4));
  });

  test('a detector answer after close cannot restore reset panels or sidecar rows', () async {
    final detector = _EnteredModel();
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sidecarSyncProvider.overrideWith(
          (ref) => SidecarSync(db, progress: ref.watch(progressStoreProvider), debounce: Duration.zero),
        ),
        panelDetectorProvider.overrideWith((ref) async => detector),
      ],
    );
    addTearDown(c.dispose);
    final path = writeBookOf(tmp, 'Reset 01.cbz', [grid4Page(), grid4Page()]);
    final reader = c.read(readerProvider.notifier);

    await reader.open(path);
    final key = c.read(readerProvider).book!.key;
    await detector.entered.future;
    await reader.close();
    expect(await c.read(sidecarSyncProvider).reset(key, everything: false), isTrue);
    detector.release.complete();
    for (var i = 0; i < 100 && reader.detecting; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await c.read(sidecarSyncProvider).flush();

    expect(await db.select(db.analysedPages).get(), isEmpty);
    expect(await db.select(db.panels).get(), isEmpty);
    final sidecar = readSidecar(sidecarPath(path, folder: false))!;
    expect(sidecar.analysed, isEmpty);
    expect(sidecar.panels, isEmpty);
  });

  test('close saves an in-flight panel result to the sidecar before reset', () async {
    final panels = _HeldPanelStore(db);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sidecarSyncProvider.overrideWith(
          (ref) => SidecarSync(db, progress: ref.watch(progressStoreProvider), debounce: Duration.zero),
        ),
        panelStoreProvider.overrideWithValue(panels),
        panelDetectorProvider.overrideWith((ref) async => const FakeModel()),
      ],
    );
    addTearDown(c.dispose);
    final reader = c.read(readerProvider.notifier);
    final path = writeBookOf(tmp, 'Saving 01.cbz', [grid4Page(), grid4Page()]);
    await reader.open(path);
    final key = c.read(readerProvider).book!.key;
    await panels.entered.future;

    var closed = false;
    final closing = reader.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse);
    panels.release.complete();
    await closing;
    final sidecarPathAfterClose = sidecarPath(path, folder: false);
    expect(readSidecar(sidecarPathAfterClose)!.analysed, isNotEmpty);
    expect(readSidecar(sidecarPathAfterClose)!.panels, isNotEmpty);
    await c.read(sidecarSyncProvider).reset(key, everything: false);
    expect(await db.select(db.analysedPages).get(), isEmpty);
    expect(await db.select(db.panels).get(), isEmpty);
    expect(readSidecar(sidecarPathAfterClose)!.analysed, isEmpty);
    expect(readSidecar(sidecarPathAfterClose)!.panels, isEmpty);
  });

  test('two opens at once: the later book is the one shown', () async {
    final c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db), noSidecars(db)]);
    addTearDown(c.dispose);
    final a = writeBookOf(tmp, 'A 01.cbz', [grid4Page(), grid4Page()]);
    final b = writeBookOf(tmp, 'B 01.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    final reader = c.read(readerProvider.notifier);

    await Future.wait([reader.open(a), reader.open(b)]);
    final s = c.read(readerProvider);
    expect(s.book!.path, b);
    expect(s.pageCount, 3);
    expect(s.loading, isFalse);
  });

  test('close cancels a pending first open and clears loading', () async {
    final c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db), noSidecars(db)]);
    addTearDown(c.dispose);
    final path = writeBookOf(tmp, 'Pending 01.cbz', [grid4Page()]);
    final held = Completer<OpenBook>();
    final reader = c.read(readerProvider.notifier);
    reader.openDocument = (_) => held.future;

    final opening = reader.open(path);
    expect(c.read(readerProvider).loading, isTrue);
    await reader.close();
    expect(c.read(readerProvider).book, isNull);
    expect(c.read(readerProvider).loading, isFalse);
    final canceledBook = await openBook(path);
    held.complete(canceledBook);
    await opening;
    expect(c.read(readerProvider).book, isNull);
    expect(c.read(readerProvider).loading, isFalse);
    await expectLater(canceledBook.doc.page(0, targetWidth: 100, targetHeight: 100), throwsA(isA<FormatException>()));
  });

  test('close cancels a pending replacement while a book is shown', () async {
    final c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db), noSidecars(db)]);
    addTearDown(c.dispose);
    final a = writeBookOf(tmp, 'Shown 01.cbz', [grid4Page(), grid4Page()]);
    final b = writeBookOf(tmp, 'Pending 02.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    final reader = c.read(readerProvider.notifier);
    await reader.open(a);
    final held = Completer<OpenBook>();
    reader.openDocument = (_) => held.future;

    final opening = reader.open(b);
    expect(c.read(readerProvider).book!.path, a);
    final firstClose = reader.close();
    final secondClose = reader.close();
    await Future.wait([firstClose, secondClose]);
    expect(c.read(readerProvider).book, isNull);
    expect(c.read(readerProvider).loading, isFalse);
    final canceledBook = await openBook(b);
    held.complete(canceledBook);
    await opening;
    expect(c.read(readerProvider).book, isNull);
    expect(c.read(readerProvider).loading, isFalse);
    await expectLater(canceledBook.doc.page(0, targetWidth: 100, targetHeight: 100), throwsA(isA<FormatException>()));
  });

  for (final action in ['reset', 'offer']) {
    test('$action does not reopen the old book after a newer open during close', () async {
      late _HeldCloseFlushSidecars sidecars;
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sidecarSyncProvider.overrideWith(
            (ref) => sidecars = _HeldCloseFlushSidecars(db, progress: ref.watch(progressStoreProvider)),
          ),
          panelDetectorProvider.overrideWith((ref) async => const FakeModel()),
        ],
      );
      addTearDown(c.dispose);
      sidecars = c.read(sidecarSyncProvider) as _HeldCloseFlushSidecars;
      final a = writeBookOf(tmp, 'Reopen A.cbz', [grid4Page()]);
      final b = writeBookOf(tmp, 'Reopen B.cbz', [grid4Page()]);
      final reader = c.read(readerProvider.notifier);
      await reader.open(a);
      final key = c.read(readerProvider).book!.key;
      if (action == 'reset') {
        await db.into(db.bookmarks).insert(Bookmark(id: 'keep-a', contentKey: key, page: 0, createdAt: DateTime(2020)));
        expect(await sidecars.write(key), isTrue);
        expect(readSidecar(sidecarPath(a, folder: false))!.bookmarks.map((r) => r.id), contains('keep-a'));
      }
      sidecars.hold = true;
      final reopening = action == 'reset'
          ? reader.reset(ResetScope.everything)
          : reader.acceptOffer((
              path: a,
              contentKey: key,
              at: SidecarProgress(
                device: 'other',
                deviceName: 'Other',
                page: 0,
                percent: 0,
                finished: false,
                updatedAt: DateTime(2020),
              ),
            ));
      await sidecars.entered.future;
      final newer = reader.open(b);
      sidecars.release.complete();
      await Future.wait([reopening, newer]);
      expect(c.read(readerProvider).book!.path, b);
      if (action == 'reset') {
        expect((await db.select(db.bookmarks).get()).map((r) => r.id), contains('keep-a'));
        expect(readSidecar(sidecarPath(a, folder: false))!.bookmarks.map((r) => r.id), contains('keep-a'));
      }
      await reader.close();
    });
  }

  test('close while a real sidecar attachment is held leaves Unread in the index', () async {
    late _HeldAttachSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _HeldAttachSidecars(db, progress: ref.watch(progressStoreProvider), realAttach: true),
        ),
        panelDetectorProvider.overrideWith((ref) async => const FakeModel()),
      ],
    );
    addTearDown(c.dispose);
    sidecars = c.read(sidecarSyncProvider) as _HeldAttachSidecars;
    final path = writeBookOf(tmp, 'Unread 01.cbz', [grid4Page()]);
    final key = await contentKey(path);
    final store = c.read(libraryStoreProvider);
    await store.addToCollection(key, unreadCollection);
    final reader = c.read(readerProvider.notifier);
    final opening = reader.open(path);
    await sidecars.entered.future;
    final closing = reader.close();
    sidecars.release.complete();
    await Future.wait([opening, closing]);
    expect(c.read(readerProvider).book, isNull);
    expect(await store.collectionNames(), contains(unreadCollection));
  });

  test('close waiting for an old attachment does not close a newer book', () async {
    final a = writeBookOf(tmp, 'Old 01.cbz', [grid4Page()]);
    final b = writeBookOf(tmp, 'New 01.cbz', [grid4Page()]);
    late _HeldAttachSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _HeldAttachSidecars(db, progress: ref.watch(progressStoreProvider), heldPath: a),
        ),
        panelDetectorProvider.overrideWith((ref) async => const FakeModel()),
      ],
    );
    addTearDown(c.dispose);
    sidecars = c.read(sidecarSyncProvider) as _HeldAttachSidecars;
    final reader = c.read(readerProvider.notifier);
    final oldOpening = reader.open(a);
    await sidecars.entered.future;

    var closed = false;
    final closing = reader.close().then((_) => closed = true);
    await reader.open(b);
    expect(c.read(readerProvider).book!.path, b);
    expect(closed, isFalse);
    sidecars.release.complete();
    await Future.wait([oldOpening, closing]);
    expect(c.read(readerProvider).book!.path, b);
  });

  test('close waits for a real sidecar import before reset can erase it', () async {
    final importDb = _HeldImportDatabase(NativeDatabase.memory());
    addTearDown(importDb.close);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(importDb),
        sidecarSyncProvider.overrideWith(
          (ref) => SidecarSync(importDb, progress: ref.watch(progressStoreProvider), debounce: Duration.zero),
        ),
        panelDetectorProvider.overrideWith((ref) async => const FakeModel()),
      ],
    );
    addTearDown(c.dispose);
    final sidecars = c.read(sidecarSyncProvider);
    final path = writeBookOf(tmp, 'Import 01.cbz', [grid4Page()]);
    final key = await contentKey(path);
    final sidecarFile = sidecarPath(path, folder: false);
    writeSidecar(
      sidecarFile,
      SidecarData(
        contentKey: key,
        bookmarks: [Bookmark(id: 'imported', contentKey: key, page: 0, createdAt: DateTime(2020))],
      ),
      device: 'other',
    );
    final reader = c.read(readerProvider.notifier);
    final opening = reader.open(path);
    await importDb.entered.future;

    var closed = false;
    final closing = reader.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse, reason: 'close must wait for the sidecar import');
    importDb.release.complete();
    await Future.wait([opening, closing]);
    expect((await importDb.select(importDb.bookmarks).get()).map((r) => r.id), contains('imported'));
    expect(readSidecar(sidecarFile)!.bookmarks.map((r) => r.id), contains('imported'));

    expect(await sidecars.reset(key, everything: true), isTrue);
    expect((await importDb.select(importDb.bookmarks).get()).where((r) => r.contentKey == key), isEmpty);
    expect(readSidecar(sidecarFile)!.bookmarks, isEmpty);
  });

  test('close waits for an S3 replacement import before reset can erase it', () async {
    final importDb = _HeldImportDatabase(NativeDatabase.memory());
    addTearDown(importDb.close);
    final path = writeBookOf(tmp, 'S3 01.cbz', [grid4Page()]);
    final key = await contentKey(path);
    final sidecarFile = sidecarPath(path, folder: false);
    final downloaded = '$sidecarFile.downloaded';
    writeSidecar(
      downloaded,
      SidecarData(
        contentKey: key,
        bookmarks: [Bookmark(id: 'from-s3', contentKey: key, page: 0, createdAt: DateTime(2020))],
      ),
      device: 'other',
    );
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(importDb),
        sidecarSyncProvider.overrideWith(
          (ref) => SidecarSync(importDb, progress: ref.watch(progressStoreProvider), debounce: Duration.zero),
        ),
        s3SyncProvider.overrideWith(
          (ref) => _ImportingS3Sync(
            importDb,
            sidecars: ref.watch(sidecarSyncProvider),
            settings: ref.watch(s3SettingsProvider),
            target: sidecarFile,
            downloaded: downloaded,
          ),
        ),
        panelDetectorProvider.overrideWith((ref) async => const FakeModel()),
      ],
    );
    addTearDown(c.dispose);
    final sidecars = c.read(sidecarSyncProvider);
    await sidecars.attach(path, key, folder: false);
    final reader = c.read(readerProvider.notifier);
    final opening = reader.open(path);
    await importDb.entered.future;

    var closed = false;
    final closing = reader.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse, reason: 'close must wait for the S3 replacement import');
    importDb.release.complete();
    await Future.wait([opening, closing]);
    expect((await importDb.select(importDb.bookmarks).get()).map((r) => r.id), contains('from-s3'));
    expect(readSidecar(sidecarFile)!.bookmarks.map((r) => r.id), contains('from-s3'));

    expect(await sidecars.reset(key, everything: true), isTrue);
    expect((await importDb.select(importDb.bookmarks).get()).where((r) => r.contentKey == key), isEmpty);
    expect(readSidecar(sidecarFile)!.bookmarks, isEmpty);
  });

  test('close waits for a real Unread removal and flushes it to the sidecar', () async {
    final store = _HeldLeaveUnreadStore(db);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        libraryStoreProvider.overrideWithValue(store),
        sidecarSyncProvider.overrideWith(
          (ref) => SidecarSync(db, progress: ref.watch(progressStoreProvider), debounce: Duration.zero),
        ),
        panelDetectorProvider.overrideWith((ref) async => const FakeModel()),
      ],
    );
    addTearDown(c.dispose);
    final path = writeBookOf(tmp, 'Waiting 01.cbz', [grid4Page()]);
    final key = await contentKey(path);
    await store.addToCollection(key, unreadCollection);
    // Leave a real time gap, so this test isolates the close/flush race from
    // collection merges whose two timestamps round to the same millisecond.
    await db.customStatement("UPDATE collection_books SET added_at = added_at - 60 WHERE name = 'Unread'");
    final reader = c.read(readerProvider.notifier);
    final opening = reader.open(path);
    await store.entered.future;
    expect(c.read(readerProvider).book?.key, key);
    var closed = false;
    final closing = reader.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse);
    store.release.complete();
    await Future.wait([opening, closing]);
    expect(c.read(readerProvider).book, isNull);
    final rows = await db.select(db.collectionBooks).get();
    expect(rows.singleWhere((r) => r.name == unreadCollection).removedAt, isNotNull);
    final side = readSidecar(sidecarPath(path, folder: false))!;
    expect(side.collections.singleWhere((r) => r.name == unreadCollection).removedAt, isNotNull);
  });

  test('back during a neighbour lookup does not open the next book', () async {
    final a = writeBookOf(tmp, 'First 01.cbz', [grid4Page()]);
    final b = writeBookOf(tmp, 'Second 02.cbz', [grid4Page()]);
    final store = _HeldNeighbourStore(db, b);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noSidecars(db),
        libraryStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    final reader = c.read(readerProvider.notifier);
    await reader.open(a);
    final neighbour = reader.handle(const ReaderCommand(ReaderIntent.nextBook));
    await store.entered.future;
    await reader.close();
    store.release.complete();
    await neighbour;
    expect(c.read(readerProvider).book, isNull);
  });

  for (final systemBack in [false, true]) {
    testWidgets('${systemBack ? 'system back' : 'Esc'} cancels an initial load from the library', (tester) async {
      final root = Directory('${tmp.path}/Comics')..createSync();
      final keep = Directory('${root.path}/Keep')..createSync();
      final path = writeBookOf(keep, 'Loading 01.cbz', [grid4Page()]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db), noSidecars(db), classicCvOnly],
          child: const ComicRedrApp(),
        ),
      );
      await tester.pump();
      final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
      await tester.runAsync(() async {
        await c.read(libraryStoreProvider).addRoot(root.path);
        await c.read(scannerProvider).scan();
      });
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
      await tester.tap(find.text('Folders'));
      await tester.pump();
      await tester.tap(find.text('Comics'));
      await tester.pump();
      await tester.tap(find.text('Keep').last);
      await tester.pump();
      final inKeep = find.descendant(of: find.byKey(const Key('breadcrumb')), matching: find.text('Keep'));
      expect(inKeep, findsOneWidget);
      final reader = c.read(readerProvider.notifier);
      final held = Completer<OpenBook>();
      reader.openDocument = (_) => held.future;
      final opening = reader.open(path);
      expect(c.read(readerProvider).loading, isTrue);

      if (systemBack) {
        expect(await tester.binding.handlePopRoute(), isTrue);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await tester.pump();
      expect(c.read(readerProvider).loading, isFalse);
      expect(inKeep, findsOneWidget, reason: 'Back cancels loading without navigating the hidden library');
      final doc = _TrackedDoc();
      held.complete(OpenBook(path: path, key: 'held', doc: doc));
      await opening;
      expect(c.read(readerProvider).book, isNull);
      expect(doc.closed, isTrue);
    });
  }

  testWidgets('Esc cancels a replacement after the old book has closed', (tester) async {
    final a = writeBookOf(tmp, 'Shown 01.cbz', [grid4Page()]);
    final b = writeBookOf(tmp, 'Loading 02.cbz', [grid4Page()]);
    late _HeldAttachSidecars sidecars;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sidecarSyncProvider.overrideWith(
            (ref) => sidecars = _HeldAttachSidecars(db, progress: ref.watch(progressStoreProvider), heldPath: b),
          ),
          s3SyncProvider.overrideWith(
            (ref) =>
                _NoPullS3Sync(db, sidecars: ref.watch(sidecarSyncProvider), settings: ref.watch(s3SettingsProvider)),
          ),
          panelDetectorProvider.overrideWith((ref) async => _HeldModel(Completer<void>())),
        ],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    final reader = c.read(readerProvider.notifier);
    await tester.runAsync(() => reader.open(a));
    await tester.pump();
    sidecars = c.read(sidecarSyncProvider) as _HeldAttachSidecars;
    final doc = _TrackedDoc();
    reader.openDocument = (_) async => OpenBook(path: b, key: 'replacement', doc: doc);
    late Future<void> opening;
    await tester.runAsync(() async {
      opening = reader.open(b);
      for (var i = 0; i < 100 && !sidecars.entered.isCompleted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(sidecars.entered.isCompleted, isTrue);
    expect(c.read(readerProvider).book, isNull);
    expect(c.read(readerProvider).loading, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.read(readerProvider).loading, isFalse);
    sidecars.release.complete();
    await tester.runAsync(() => opening);
    expect(c.read(readerProvider).book, isNull);
    expect(doc.closed, isTrue);
  });

  testWidgets('a page left before it decoded never replaces the one shown', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db), classicCvOnly, noSidecars(db)],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    final path = writeBookOf(tmp, 'Ten 01.cbz', [for (var i = 0; i < 10; i++) grid4Page()]);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.bySemanticsLabel('Page 1 of 10'), findsOneWidget);

    // G starts decoding page 10; gg comes back before it lands.
    await c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.lastPage));
    await tester.pump();
    await c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.firstPage));
    await tester.pump();
    expect(c.read(readerProvider).page, 0);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      expect(find.bySemanticsLabel('Page 10 of 10'), findsNothing, reason: 'page 10 flashed up after gg');
    }
    expect(find.bySemanticsLabel('Page 1 of 10'), findsOneWidget);
  });
}
