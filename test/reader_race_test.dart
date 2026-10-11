import 'dart:async';
import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/read_log_store.dart';
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

class _HeldProgressStore extends ProgressStore {
  _HeldProgressStore(super.db);

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

class _HeldReadLogStore extends ReadLogStore {
  _HeldReadLogStore(super.db);

  final entered = Completer<void>();
  final secondEntered = Completer<void>();
  final release = Completer<void>();
  int calls = 0;

  @override
  Future<void> record(String contentKey, DateTime start, DateTime end, int pages) {
    calls++;
    final write = super.record(contentKey, start, end, pages);
    if (calls == 1) {
      entered.complete();
      return () async {
        await release.future;
        await write;
      }();
    }
    if (calls == 2) secondEntered.complete();
    return write;
  }
}

class _HeldMarkStore extends MarkStore {
  _HeldMarkStore(super.db);

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> save(String contentKey, String mark, int page, int panel) async {
    entered.complete();
    await release.future;
    await super.save(contentKey, mark, page, panel);
  }
}

class _TrackingSidecars extends SidecarSync {
  _TrackingSidecars(super.db, {required super.progress});

  final touches = <String>[];
  Completer<void>? nextTouch;
  Completer<void>? nextWrite;

  @override
  void touch(String contentKey) {
    touches.add(contentKey);
    nextTouch?.complete();
    nextTouch = null;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<bool> write(String contentKey) async {
    nextWrite?.complete();
    nextWrite = null;
    return true;
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

class _HeldOpeningWriteSidecars extends SidecarSync {
  _HeldOpeningWriteSidecars(super.db, {required super.progress}) : super(debounce: Duration.zero);

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  void touch(String contentKey) {}

  @override
  Future<bool> write(String contentKey) async {
    entered.complete();
    await release.future;
    return super.write(contentKey);
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

class _HeldCollectionStore extends LibraryStore {
  _HeldCollectionStore(super.db);

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> addToCollection(String contentKey, String name) async {
    entered.complete();
    await release.future;
    return super.addToCollection(contentKey, name);
  }
}

class _HeldFlagStore extends LibraryStore {
  _HeldFlagStore(super.db);

  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> _hold() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  @override
  Future<void> setFavourite(String contentKey, bool on) async {
    await _hold();
    await super.setFavourite(contentKey, on);
  }

  @override
  Future<void> setCompleted(String contentKey, bool? on, {DateTime? at}) async {
    await _hold();
    await super.setCompleted(contentKey, on, at: at);
  }
}

class _HeldBookmarkStore extends LibraryStore {
  _HeldBookmarkStore(super.db);

  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> _hold() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  @override
  Future<void> deleteBookmark(String id) async {
    await _hold();
    await super.deleteBookmark(id);
  }

  @override
  Future<String?> setNote(String id, String note) async {
    await _hold();
    return super.setNote(id, note);
  }
}

class _HeldSettingsStore extends SettingsStore {
  _HeldSettingsStore(super.db);

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool?> loadBool(String key) async {
    entered.complete();
    await release.future;
    return true;
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

ProviderContainer readerScope(ProviderContainer parent) =>
    ProviderContainer(parent: parent, overrides: [readerProvider.overrideWith(ReaderNotifier.new)]);

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

  test('flush waits for a panel save before writing the real sidecar', () async {
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
    final path = writeBookOf(tmp, 'Flushing panels 01.cbz', [grid4Page()]);
    final reader = c.read(readerProvider.notifier);
    await reader.open(path);
    await panels.entered.future;

    var drained = false;
    final flushing = reader.flush().then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(drained, isFalse);
    panels.release.complete();
    await flushing;
    final side = readSidecar(sidecarPath(path, folder: false))!;
    expect(side.analysed, isNotEmpty);
    expect(side.panels, isNotEmpty);
  });

  test('flush waits for an opening write before it enters the sidecar queue', () async {
    late _HeldOpeningWriteSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _HeldOpeningWriteSidecars(db, progress: ref.watch(progressStoreProvider)),
        ),
      ],
    );
    addTearDown(c.dispose);
    final path = writeBookOf(tmp, 'Opening write 01.cbz', [grid4Page()]);
    final reader = c.read(readerProvider.notifier);
    await reader.open(path);
    await sidecars.entered.future;

    var drained = false;
    final flushing = reader.flush().then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(drained, isFalse);
    sidecars.release.complete();
    await flushing;

    expect(readSidecar(sidecarPath(path, folder: false))!.progress, hasLength(1));
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

  test('a pending first open closes its document after provider disposal', () async {
    final c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db), noSidecars(db)]);
    final path = writeBookOf(tmp, 'Disposed 01.cbz', [grid4Page()]);
    final held = Completer<OpenBook>();
    final reader = c.read(readerProvider.notifier);
    reader.openDocument = (_) => held.future;

    final opening = reader.open(path);
    c.dispose();
    final canceledBook = await openBook(path);
    held.complete(canceledBook);
    await opening;
    await expectLater(canceledBook.doc.page(0, targetWidth: 100, targetHeight: 100), throwsA(isA<FormatException>()));
  });

  test('a pending Unread removal can finish after provider disposal', () async {
    final store = _HeldLeaveUnreadStore(db);
    final detectorRelease = Completer<void>();
    late _TrackingSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _TrackingSidecars(db, progress: ref.watch(progressStoreProvider)),
        ),
        panelDetectorProvider.overrideWith((ref) async => _HeldModel(detectorRelease)),
        libraryStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(() => detectorRelease.complete());
    final scope = readerScope(c);
    final path = writeBookOf(tmp, 'Unread 01.cbz', [grid4Page()]);
    final key = await contentKey(path);
    await store.addToCollection(key, unreadCollection);
    final reader = scope.read(readerProvider.notifier);
    final opening = reader.open(path);
    await store.entered.future;
    final touched = sidecars.nextTouch = Completer<void>();
    scope.dispose();
    store.release.complete();
    await opening;
    await touched.future;
    final rows = await db.select(db.collectionBooks).get();
    expect(rows.singleWhere((r) => r.contentKey == key && r.name == unreadCollection).removedAt, isNotNull);
  });

  for (final note in [false, true]) {
    test('${note ? 'note' : 'bookmark removal'} can finish after provider disposal', () async {
      final store = _HeldBookmarkStore(db);
      final detectorRelease = Completer<void>();
      late _TrackingSidecars sidecars;
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sidecarSyncProvider.overrideWith(
            (ref) => sidecars = _TrackingSidecars(db, progress: ref.watch(progressStoreProvider)),
          ),
          panelDetectorProvider.overrideWith((ref) async => _HeldModel(detectorRelease)),
          libraryStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      addTearDown(() => detectorRelease.complete());
      final scope = readerScope(c);
      final path = writeBookOf(tmp, 'Bookmark 01.cbz', [grid4Page()]);
      final reader = scope.read(readerProvider.notifier);
      await reader.open(path);
      final key = scope.read(readerProvider).book!.key;
      final id = await c.read(markStoreProvider).addBookmark(key, 0, null);

      final write = note ? reader.setBookmarkNote(id, 'note') : reader.removeBookmark(id);
      await store.entered.future;
      final touched = sidecars.nextTouch = Completer<void>();
      scope.dispose();
      store.release.complete();
      await write;
      await touched.future;
      final rows = await db.select(db.bookmarks).get();
      expect(rows.singleWhere((row) => row.id == id).deletedAt, isNotNull);
      if (note) expect(rows.where((row) => row.contentKey == key && row.note == 'note'), hasLength(1));
    });
  }

  test('fullscreen load can finish after provider disposal', () async {
    final settings = _HeldSettingsStore(db);
    final c = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db), settingsStoreProvider.overrideWithValue(settings)],
    );
    final reader = c.read(readerProvider.notifier);
    final loading = reader.loadFullscreen();
    await settings.entered.future;
    c.dispose();
    settings.release.complete();
    await loading;
  });

  test('a pending collection add can finish after provider disposal', () async {
    final store = _HeldCollectionStore(db);
    final detectorRelease = Completer<void>();
    late _TrackingSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _TrackingSidecars(db, progress: ref.watch(progressStoreProvider)),
        ),
        panelDetectorProvider.overrideWith((ref) async => _HeldModel(detectorRelease)),
        libraryStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(() => detectorRelease.complete());
    final scope = readerScope(c);
    final path = writeBookOf(tmp, 'Collected 01.cbz', [grid4Page()]);
    final reader = scope.read(readerProvider.notifier);
    await reader.open(path);

    final adding = reader.addToCollection('Saved');
    await store.entered.future;
    final touched = sidecars.nextTouch = Completer<void>();
    scope.dispose();
    store.release.complete();
    await adding;
    await touched.future;
    final key = await contentKey(path);
    final rows = await db.select(db.collectionBooks).get();
    expect(rows.where((row) => row.contentKey == key && row.name == 'Saved' && row.removedAt == null), hasLength(1));
  });

  for (final close in [false, true]) {
    test('${close ? 'close' : 'flush'} waits for a collection add before flushing its real sidecar', () async {
      final store = _HeldCollectionStore(db);
      Future<void>? databaseClose;
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(() => databaseClose = db.close());
            return db;
          }),
          libraryStoreProvider.overrideWithValue(store),
          s3SyncProvider.overrideWith(
            (ref) =>
                _NoPullS3Sync(db, sidecars: ref.watch(sidecarSyncProvider), settings: ref.watch(s3SettingsProvider)),
          ),
        ],
      );
      var disposed = false;
      Future<void> disposeContainer() async {
        if (!store.release.isCompleted) store.release.complete();
        if (disposed) return;
        disposed = true;
        c.dispose();
        await (databaseClose ?? db.close());
      }

      addTearDown(disposeContainer);
      final path = writeBookOf(tmp, 'Closing collection 01.cbz', [grid4Page()]);
      final reader = c.read(readerProvider.notifier);
      await reader.open(path);

      final adding = reader.addToCollection('Saved');
      await store.entered.future;
      var drained = false;
      final draining = (close ? reader.close() : reader.flush()).then((_) => drained = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(drained, isFalse);
      store.release.complete();
      await Future.wait([adding, draining]);
      await disposeContainer();
      expect(databaseClose, isNotNull);

      final side = readSidecar(sidecarPath(path, folder: false))!;
      expect(side.collections.where((row) => row.name == 'Saved' && row.removedAt == null), hasLength(1));
    });
  }

  for (final completed in [false, true]) {
    test('${completed ? 'completed mark' : 'favourite'} touches its sidecar after provider disposal', () async {
      final store = _HeldFlagStore(db);
      final detectorRelease = Completer<void>();
      late _TrackingSidecars sidecars;
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          libraryStoreProvider.overrideWithValue(store),
          sidecarSyncProvider.overrideWith(
            (ref) => sidecars = _TrackingSidecars(db, progress: ref.watch(progressStoreProvider)),
          ),
          panelDetectorProvider.overrideWith((ref) async => _HeldModel(detectorRelease)),
        ],
      );
      addTearDown(c.dispose);
      addTearDown(() => detectorRelease.complete());
      final scope = readerScope(c);
      final path = writeBookOf(tmp, 'Flag 01.cbz', [grid4Page(), grid4Page()]);
      final reader = scope.read(readerProvider.notifier);
      await reader.open(path);
      final key = scope.read(readerProvider).book!.key;

      final changing = reader.handle(
        ReaderCommand(completed ? ReaderIntent.toggleCompleted : ReaderIntent.toggleFavourite),
      );
      await store.entered.future;
      final touched = sidecars.nextTouch = Completer<void>();
      scope.dispose();
      store.release.complete();
      await changing;
      await touched.future;

      expect(completed ? await store.completedMarkOf(key) : await store.isFavourite(key), isTrue);
    });
  }

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

  for (final close in [false, true]) {
    test('${close ? 'close' : 'flush'} waits for a real Unread removal and flushes it to the sidecar', () async {
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
      final closing = (close ? reader.close() : reader.flush()).then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed, isFalse);
      store.release.complete();
      await Future.wait([opening, closing]);
      expect(c.read(readerProvider).book == null, close);
      final rows = await db.select(db.collectionBooks).get();
      expect(rows.singleWhere((r) => r.name == unreadCollection).removedAt, isNotNull);
      final side = readSidecar(sidecarPath(path, folder: false))!;
      expect(side.collections.singleWhere((r) => r.name == unreadCollection).removedAt, isNotNull);
    });
  }

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

  test('back can finish closing after its provider is disposed', () async {
    late _HeldCloseFlushSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _HeldCloseFlushSidecars(db, progress: ref.watch(progressStoreProvider)),
        ),
      ],
    );
    final reader = c.read(readerProvider.notifier);
    final path = writeBookOf(tmp, 'Closing 01.cbz', [grid4Page()]);
    await reader.open(path);

    sidecars.hold = true;
    final back = reader.handle(const ReaderCommand(ReaderIntent.back));
    await sidecars.entered.future;
    c.dispose();
    sidecars.release.complete();
    await back;
  });

  test('a neighbour command can finish after its provider is disposed', () async {
    final path = writeBookOf(tmp, 'Turning 01.cbz', [grid4Page(), grid4Page()]);
    final store = _HeldNeighbourStore(db, path);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noSidecars(db),
        libraryStoreProvider.overrideWithValue(store),
      ],
    );
    final reader = c.read(readerProvider.notifier);
    await reader.open(path);

    final neighbour = reader.handle(const ReaderCommand(ReaderIntent.nextBook));
    await store.entered.future;
    c.dispose();
    store.release.complete();
    await neighbour;
  });

  test('flush can finish after its provider is disposed', () async {
    late _HeldCloseFlushSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _HeldCloseFlushSidecars(db, progress: ref.watch(progressStoreProvider)),
        ),
      ],
    );
    final path = writeBookOf(tmp, 'Flushing 01.cbz', [grid4Page()]);
    final reader = c.read(readerProvider.notifier);
    await reader.open(path);

    sidecars.hold = true;
    final flushing = reader.flush();
    await sidecars.entered.future;
    c.dispose();
    sidecars.release.complete();
    await flushing;
  });

  test('close logs a sitting after disposal during progress flush', () async {
    final progress = _HeldProgressStore(db);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        progressStoreProvider.overrideWithValue(progress),
        noSidecars(db),
      ],
    );
    addTearDown(c.dispose);
    final scope = readerScope(c);
    final path = writeBookOf(tmp, 'Read 01.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    final reader = scope.read(readerProvider.notifier);
    await reader.open(path);
    await reader.handle(const ReaderCommand(ReaderIntent.nextPage));

    progress.hold = true;
    final closing = reader.close();
    await progress.entered.future;
    scope.dispose();
    progress.release.complete();
    await closing;

    final key = await contentKey(path);
    final rows = await db.select(db.readLog).get();
    expect(rows.where((row) => row.contentKey == key && row.pages >= 2), hasLength(1));
  });

  test('flush does not restart a sitting after close begins', () async {
    final progress = _HeldProgressStore(db);
    final readLog = _HeldReadLogStore(db);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        progressStoreProvider.overrideWithValue(progress),
        readLogStoreProvider.overrideWithValue(readLog),
        noSidecars(db),
      ],
    );
    addTearDown(c.dispose);
    final path = writeBookOf(tmp, 'Sitting 01.cbz', [grid4Page(), grid4Page()]);
    final reader = c.read(readerProvider.notifier);
    await reader.open(path);
    await reader.handle(const ReaderCommand(ReaderIntent.nextPage));

    final flushing = reader.flush();
    await readLog.entered.future;
    progress.hold = true;
    final closing = reader.close();
    await progress.entered.future;
    readLog.release.complete();
    await Future<void>.delayed(Duration.zero);
    progress.release.complete();
    await Future.wait([flushing, closing]);
    await reader.flush();

    expect(readLog.calls, 1);
    final rows = await db.select(db.readLog).get();
    expect(rows.single.pages, greaterThanOrEqualTo(2));
  });

  test('close waits for a sitting record started by flush', () async {
    final readLog = _HeldReadLogStore(db);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        readLogStoreProvider.overrideWithValue(readLog),
        noSidecars(db),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(() {
      if (!readLog.release.isCompleted) readLog.release.complete();
    });
    final path = writeBookOf(tmp, 'History 01.cbz', [grid4Page(), grid4Page()]);
    final reader = c.read(readerProvider.notifier);
    await reader.open(path);
    await reader.handle(const ReaderCommand(ReaderIntent.nextPage));

    final flushing = reader.flush();
    await readLog.entered.future;
    var closed = false;
    final closing = reader.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse, reason: 'close must wait for the sitting already taken by flush');
    readLog.release.complete();
    await Future.wait([flushing, closing]);

    expect(readLog.calls, 1);
    final rows = await db.select(db.readLog).get();
    expect(rows.single.pages, greaterThanOrEqualTo(2));
  });

  test('a second flush waits for a sitting record started by the first', () async {
    final readLog = _HeldReadLogStore(db);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        readLogStoreProvider.overrideWithValue(readLog),
        noSidecars(db),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(() {
      if (!readLog.release.isCompleted) readLog.release.complete();
    });
    final path = writeBookOf(tmp, 'Two flushes 01.cbz', [grid4Page(), grid4Page()]);
    final reader = c.read(readerProvider.notifier);
    await reader.open(path);
    await reader.handle(const ReaderCommand(ReaderIntent.nextPage));

    final first = reader.flush();
    await readLog.entered.future;
    var secondDone = false;
    final second = reader.flush().then((_) => secondDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(secondDone, isFalse, reason: 'the second flush must wait for the first history write');
    readLog.release.complete();
    await Future.wait([first, second]);

    expect(readLog.calls, 1);
    final rows = await db.select(db.readLog).get();
    expect(rows.single.pages, greaterThanOrEqualTo(2));
  });

  test('a page turn during a held history write is logged by the next flush', () async {
    final readLog = _HeldReadLogStore(db);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        readLogStoreProvider.overrideWithValue(readLog),
        noSidecars(db),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(() {
      if (!readLog.release.isCompleted) readLog.release.complete();
    });
    final path = writeBookOf(tmp, 'Turning while logging.cbz', List.generate(5, (_) => grid4Page()));
    final reader = c.read(readerProvider.notifier);
    await reader.open(path);
    reader.jumpTo(1);
    reader.jumpTo(2);

    final first = reader.flush();
    await readLog.entered.future;
    reader.jumpTo(3);
    var secondDone = false;
    final second = reader.flush().then((_) => secondDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(secondDone, isFalse, reason: 'the later sitting must wait for the earlier history write');
    readLog.release.complete();
    await Future.wait([first, second]);

    expect(readLog.calls, 2);
    final rows = await db.select(db.readLog).get();
    expect(rows, hasLength(1));
    expect(rows.single.pages, 4);
  });

  test('clearing history waits for a second sitting queued behind a held first', () async {
    final readLog = _HeldReadLogStore(db);
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        readLogStoreProvider.overrideWithValue(readLog),
        noSidecars(db),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(() {
      if (!readLog.release.isCompleted) readLog.release.complete();
    });
    final path = writeBookOf(tmp, 'Clear while logging.cbz', List.generate(4, (_) => grid4Page()));
    final reader = c.read(readerProvider.notifier);
    await reader.open(path);
    reader.jumpTo(1);
    reader.jumpTo(2);

    final first = reader.flush();
    await readLog.entered.future;
    reader.jumpTo(3);
    final second = reader.flush();
    await readLog.secondEntered.future.timeout(const Duration(seconds: 2));
    await readLog.clear();
    readLog.release.complete();
    await Future.wait([first, second]);

    expect(readLog.calls, 2);
    expect(await db.select(db.readLog).get(), isEmpty);
  });

  test('a mark save touches its sidecar after provider disposal', () async {
    final marks = _HeldMarkStore(db);
    final detectorRelease = Completer<void>();
    late _TrackingSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        markStoreProvider.overrideWithValue(marks),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _TrackingSidecars(db, progress: ref.watch(progressStoreProvider)),
        ),
        panelDetectorProvider.overrideWith((ref) async => _HeldModel(detectorRelease)),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(() => detectorRelease.complete());
    final scope = readerScope(c);
    final path = writeBookOf(tmp, 'Marked 01.cbz', [grid4Page()]);
    final reader = scope.read(readerProvider.notifier);
    await reader.open(path);
    final key = scope.read(readerProvider).book!.key;

    await reader.handle(const ReaderCommand(ReaderIntent.setMark, register: 'a'));
    await marks.entered.future;
    final touched = sidecars.nextTouch = Completer<void>();
    scope.dispose();
    marks.release.complete();
    await touched.future;

    final rows = await db.select(db.bookmarks).get();
    expect(rows.where((row) => row.contentKey == key && row.mark == 'a' && row.deletedAt == null), hasLength(1));
  });

  test('an opening sidecar write finishes after provider disposal', () async {
    final progress = _HeldProgressStore(db)..hold = true;
    late _TrackingSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        progressStoreProvider.overrideWithValue(progress),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _TrackingSidecars(db, progress: ref.watch(progressStoreProvider)),
        ),
      ],
    );
    addTearDown(c.dispose);
    final scope = readerScope(c);
    final path = writeBookOf(tmp, 'Writing 01.cbz', [grid4Page()]);
    final reader = scope.read(readerProvider.notifier);
    await reader.open(path);
    await progress.entered.future;
    final written = sidecars.nextWrite = Completer<void>();

    scope.dispose();
    progress.release.complete();
    await written.future;
  });

  test('a saved panel touches its sidecar after provider disposal', () async {
    final panels = _HeldPanelStore(db);
    late _TrackingSidecars sidecars;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        panelStoreProvider.overrideWithValue(panels),
        panelDetectorProvider.overrideWith((ref) async => const FakeModel()),
        sidecarSyncProvider.overrideWith(
          (ref) => sidecars = _TrackingSidecars(db, progress: ref.watch(progressStoreProvider)),
        ),
      ],
    );
    addTearDown(c.dispose);
    final scope = readerScope(c);
    final path = writeBookOf(tmp, 'Panels 01.cbz', [grid4Page()]);
    final reader = scope.read(readerProvider.notifier);
    await reader.open(path);
    await panels.entered.future;
    final touched = sidecars.nextTouch = Completer<void>();

    scope.dispose();
    panels.release.complete();
    await touched.future;
    expect(await db.select(db.analysedPages).get(), isNotEmpty);
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
    opening = reader.open(b);
    for (var i = 0; i < 100 && !sidecars.entered.isCompleted; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
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
