import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import 'app_database.dart';
import 'progress_store.dart';
import '../version.dart';
import 'sidecar.dart';

/// This install, as sidecar positions name it.
typedef Device = ({String id, String name});

/// What reading a book's sidecar brought in.
class SidecarImport {
  const SidecarImport({this.found = false, this.adopted, this.elsewhere});

  static const none = SidecarImport();

  /// The book had a sidecar and it was merged into the index.
  final bool found;

  /// Another device's position, taken as this one's because this device had
  /// never opened the book.
  final SidecarProgress? adopted;

  /// Another device's position, later than this device's and somewhere
  /// else. It is not taken: the reader asks (design plan section 7).
  final SidecarProgress? elsewhere;
}

/// Keeps the index and the sidecars beside the books in step (design plan
/// section 7). The index stays the working store: the reader and the
/// library read and write it as before. A book's sidecar is merged in when
/// the book is opened or scanned, and written back a moment after anything
/// about the book changes, and on pause and close.
///
/// A folder that cannot be written to (a read-only share, a locked SD card)
/// costs the sidecar and nothing else: the book's data stays in the index,
/// and [exportAll] writes sidecars elsewhere on request.
class SidecarSync {
  SidecarSync(
    this._db, {
    required this.progress,
    this.coverDir,
    this.writeAllowed,
    this.storeDir,
    this.debounce = const Duration(seconds: 2),
  });

  final AppDatabase _db;
  final ProgressStore progress;
  final String? coverDir;

  /// Whether sidecars are written beside books (a setting); always when
  /// null. Reading them, and [exportAll], do not ask.
  final Future<bool> Function()? writeAllowed;
  final Duration debounce;

  /// The one folder every sidecar is kept in (a setting), or null to keep
  /// each beside its comic, the default. See [storedSidecarPath].
  final Future<String?> Function()? storeDir;

  Device? _device;
  final _where = <String, ({String path, bool folder})>{};
  final _dirty = <String>{};
  final _readOnly = <String>{};
  Timer? _timer;

  /// Writes run one at a time, in order: two at once would share a
  /// temporary file, and [flush] on exit must wait for one under way.
  Future<void> _last = Future.value();

  Future<T> _serial<T>(Future<T> Function() f) {
    final run = _last.then((_) => f());
    _last = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Whether the last write for [contentKey] was refused by its folder.
  bool isReadOnly(String contentKey) => _readOnly.contains(contentKey);

  /// This install's id and name, made once and kept in the index.
  Future<Device> device() async {
    if (_device case final d?) return d;
    final rows = {for (final r in await _db.select(_db.settings).get()) r.key: jsonDecode(r.value)};
    var id = rows['device.id'] as String?;
    final name = rows['device.name'] as String? ?? _deviceName();
    if (id == null) {
      final r = Random.secure();
      id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await _db.batch((b) {
        b.insertAllOnConflictUpdate(_db.settings, [
          SettingsCompanion.insert(key: 'device.id', value: jsonEncode(id)),
          SettingsCompanion.insert(key: 'device.name', value: jsonEncode(name)),
        ]);
      });
    }
    return _device = (id: id, name: name);
  }

  static String _deviceName() {
    final host = Platform.localHostname;
    if (host.isNotEmpty && host != 'localhost') return host;
    final os = Platform.operatingSystem;
    return '${os[0].toUpperCase()}${os.substring(1)}';
  }

  Future<String?> _storeDir() async {
    try {
      final dir = await storeDir?.call();
      return dir == null || dir.isEmpty ? null : dir;
    } catch (_) {
      return null;
    }
  }

  Future<List<({int id, String path})>> _roots() async => [
    for (final r in await _db.select(_db.roots).get()) (id: r.id, path: r.path),
  ];

  /// Where the sidecar of the book at [path] is written: beside it, or in
  /// the sidecar folder when Settings names one.
  Future<String> sidecarFor(String path, {required bool folder}) async => _placeIn(await _storeDir(), path, folder);

  Future<String> _placeIn(String? dir, String path, bool folder) async => dir == null
      ? sidecarPath(path, folder: folder)
      : storedSidecarPath(path, folder: folder, dir: dir, roots: await _roots());

  /// Every place a sidecar of the book at [path] may be, the one written
  /// first: with a sidecar folder, a sidecar left beside the comic is still
  /// read. Removing a book's data removes all of them.
  Future<List<String>> sidecarsOf(String path, {required bool folder}) async {
    final here = await sidecarFor(path, folder: folder);
    final beside = sidecarPath(path, folder: folder);
    return [here, if (!p.equals(here, beside)) beside];
  }

  /// The sidecar folder setting changed: a folder that refused a write
  /// before may take one now.
  void placeChanged() => _readOnly.clear();

  /// Reads the sidecar of the book at [path], re-linking one left behind by
  /// a rename, and merges it into the index. From here on the book's changes
  /// go back to it.
  Future<SidecarImport> attach(String path, String contentKey, {required bool folder}) async {
    _where[contentKey] = (path: path, folder: folder);
    final SidecarData? side;
    try {
      side = await _readAll(path, contentKey, folder, await sidecarsOf(path, folder: folder));
    } catch (e) {
      debugPrint('Could not read the sidecar of $path: $e');
      return SidecarImport.none;
    }
    if (side == null || side.contentKey != contentKey) return SidecarImport.none;
    return _import(side);
  }

  Future<SidecarImport> _import(SidecarData side) async {
    final key = side.contentKey;
    final me = await device();
    await progress.flush();
    final local = await gather(key);
    final merged = mergeSidecars(side, local);
    final mine = local.progress.where((r) => r.device == me.id).firstOrNull;
    final others = merged.progress.where((r) => r.device != me.id).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final newest = others.firstOrNull;
    final adopt = mine == null ? newest : null;

    await _db.transaction(() async {
      await (_db.delete(_db.analysedPages)..where((r) => r.contentKey.equals(key))).go();
      await (_db.delete(_db.panels)..where((r) => r.contentKey.equals(key))).go();
      await (_db.delete(_db.bookmarks)..where((r) => r.contentKey.equals(key))).go();
      await (_db.delete(_db.collectionBooks)..where((r) => r.contentKey.equals(key))).go();
      await _db.batch((b) {
        b.insertAll(_db.analysedPages, merged.analysed);
        b.insertAll(_db.panels, merged.panels, mode: InsertMode.insertOrReplace);
        b.insertAll(_db.bookmarks, merged.bookmarks);
        b.insertAll(_db.collectionBooks, [for (final c in merged.collections) c.copyWith(contentKey: key)]);
        b.insertAllOnConflictUpdate(_db.overrides, [
          for (final MapEntry(:key, :value) in merged.overrides.entries)
            OverridesCompanion.insert(contentKey: side.contentKey, field: key, value: value),
        ]);
      });
      if (adopt != null) {
        await _db
            .into(_db.progress)
            .insertOnConflictUpdate(
              ProgressCompanion.insert(
                contentKey: key,
                page: adopt.page,
                panel: Value(adopt.panel),
                percent: adopt.percent,
                finished: Value(adopt.finished),
                updatedAt: adopt.updatedAt,
                viewJson: Value(adopt.viewJson),
              ),
            );
      }
    });
    if ((coverDir, merged.cover) case (final dir?, final cover?)) {
      final f = File(p.join(dir, '$key.jpg'));
      if (!f.existsSync()) {
        try {
          await f.parent.create(recursive: true);
          await f.writeAsBytes(cover);
        } catch (_) {
          // The scanner makes covers anyway.
        }
      }
    }
    final elsewhere =
        mine != null &&
            newest != null &&
            newest.updatedAt.isAfter(mine.updatedAt) &&
            (newest.page != mine.page || newest.panel != mine.panel)
        ? newest
        : null;
    return SidecarImport(found: true, adopted: adopt, elsewhere: elsewhere);
  }

  /// Everything the index knows about [contentKey], as a sidecar would hold
  /// it, this device's position included.
  Future<SidecarData> gather(String contentKey) async {
    final me = await device();
    final analysed = await (_db.select(_db.analysedPages)..where((r) => r.contentKey.equals(contentKey))).get();
    final panels = await (_db.select(_db.panels)..where((r) => r.contentKey.equals(contentKey))).get();
    final bookmarks = await (_db.select(_db.bookmarks)..where((r) => r.contentKey.equals(contentKey))).get();
    final prog = await (_db.select(_db.progress)..where((r) => r.contentKey.equals(contentKey))).getSingleOrNull();
    final overrides = await (_db.select(_db.overrides)..where((r) => r.contentKey.equals(contentKey))).get();
    final collections = await (_db.select(_db.collectionBooks)..where((r) => r.contentKey.equals(contentKey))).get();
    final book = await _db
        .customSelect(
          'SELECT b.*, s.name AS series_name FROM books b LEFT JOIN series s ON s.id = b.series_id '
          'WHERE b.content_key = ?',
          variables: [Variable(contentKey)],
        )
        .getSingleOrNull();
    Uint8List? cover;
    if (coverDir case final dir?) {
      final f = File(p.join(dir, '$contentKey.jpg'));
      if (await f.exists()) cover = await f.readAsBytes();
    }
    return SidecarData(
      contentKey: contentKey,
      book: book == null
          ? null
          : SidecarBook(
              title: book.read<String>('title'),
              series: book.readNullable<String>('series_name'),
              number: book.readNullable<String>('number'),
              volume: book.readNullable<int>('volume'),
              year: book.readNullable<int>('year'),
              writers: book.readNullable<String>('writers'),
              artists: book.readNullable<String>('artists'),
              summary: book.readNullable<String>('summary'),
            ),
      analysed: analysed,
      panels: panels,
      bookmarks: bookmarks,
      progress: [
        if (prog != null)
          SidecarProgress(
            device: me.id,
            deviceName: me.name,
            page: prog.page,
            panel: prog.panel,
            percent: prog.percent,
            finished: prog.finished,
            updatedAt: prog.updatedAt,
            viewJson: prog.viewJson,
          ),
      ],
      overrides: {for (final o in overrides) o.field: o.value},
      collections: collections,
      cover: cover,
    );
  }

  /// Takes another device's position [at] as this device's, as of now.
  Future<void> adopt(String contentKey, SidecarProgress at) => _db
      .into(_db.progress)
      .insertOnConflictUpdate(
        ProgressCompanion.insert(
          contentKey: contentKey,
          page: at.page,
          panel: Value(at.panel),
          percent: at.percent,
          finished: Value(at.finished),
          updatedAt: DateTime.now(),
          viewJson: Value(at.viewJson),
        ),
      );

  /// Something about [contentKey] changed in the index: its sidecar is
  /// written once things go quiet. A book never attached has no known path
  /// and is skipped; so is one whose folder refused a write.
  void touch(String contentKey) {
    if (!_where.containsKey(contentKey) || _readOnly.contains(contentKey)) return;
    _dirty.add(contentKey);
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(flush()));
  }

  /// Writes every sidecar waiting to be written, now.
  Future<void> flush() async {
    _timer?.cancel();
    await progress.flush();
    final keys = [..._dirty];
    _dirty.clear();
    for (final key in keys) {
      await write(key);
    }
    await _last; // And any write already under way.
  }

  /// Writes the sidecar of the book at [path] now, for a change made where
  /// the book is not open (a bookmark removed in the library).
  Future<bool> writeBeside(String path, String contentKey, {required bool folder}) {
    _where[contentKey] = (path: path, folder: folder);
    return write(contentKey);
  }

  /// Writes the sidecar of [contentKey] beside its book now. False when the
  /// folder refused it; the index keeps everything either way.
  Future<bool> write(String contentKey) async {
    final at = _where[contentKey];
    if (at == null) return false;
    if (!await (writeAllowed?.call() ?? Future.value(true))) return true; // Nothing to do is not a failure.
    final target = await sidecarFor(at.path, folder: at.folder);
    final ok = await _writeTo(target, contentKey, makeDir: !p.equals(target, sidecarPath(at.path, folder: at.folder)));
    if (!ok && _readOnly.add(contentKey)) {
      debugPrint('Cannot write the sidecar of ${at.path} to $target; its data stays in the app database');
    }
    if (ok) _readOnly.remove(contentKey);
    return ok;
  }

  Future<bool> _writeTo(String target, String contentKey, {bool makeDir = false}) => _serial(() async {
    final me = await device();
    await progress.flush();
    final data = await gather(contentKey);
    try {
      if (makeDir) await Directory(p.dirname(target)).create(recursive: true);
      await _writeOnWorker(target, data, me.id);
      return true;
    } on FileSystemException catch (e) {
      debugPrint('Sidecar write failed: $e');
    } on SqliteException catch (e) {
      debugPrint('Sidecar write failed: $e');
    }
    return false;
  });

  /// "Export sidecars" (design plan section 7): writes the sidecar of every
  /// book in the library under [dir], laid out like the library, so the
  /// export copied over the comics puts each one beside its book. Returns
  /// how many were written.
  Future<int> exportAll(String dir) async {
    await flush();
    final rows = await _db
        .customSelect(
          'SELECT f.content_key, f.rel_path, b.format FROM files f JOIN books b ON b.content_key = f.content_key '
          'GROUP BY f.content_key ORDER BY f.root_id, f.rel_path',
        )
        .get();
    var n = 0;
    for (final r in rows) {
      final rel = r.read<String>('rel_path');
      final folder = r.read<String>('format') == 'folder';
      // A root that is itself a folder book has an empty relative path.
      final at = rel.isEmpty ? p.join(dir, 'book') : p.join(dir, rel);
      final target = sidecarPath(at, folder: folder);
      try {
        await Directory(p.dirname(target)).create(recursive: true);
      } on FileSystemException {
        continue;
      }
      if (await _writeTo(target, r.read<String>('content_key'))) n++;
    }
    return n;
  }

  /// Every book in the library as a path and whether it is a folder book.
  Future<List<({String path, bool folder})>> _books() async {
    final rows = await _db
        .customSelect(
          'SELECT r.path AS root, f.rel_path, b.format FROM files f JOIN roots r ON r.id = f.root_id '
          'JOIN books b ON b.content_key = f.content_key ORDER BY f.root_id, f.rel_path',
        )
        .get();
    return [
      for (final r in rows)
        (
          path: r.read<String>('rel_path').isEmpty
              ? r.read<String>('root')
              : p.join(r.read<String>('root'), r.read<String>('rel_path')),
          folder: r.read<String>('format') == 'folder',
        ),
    ];
  }

  /// How many of the library's sidecars are kept at [dir] (null: beside the
  /// comics), to ask before moving them.
  Future<int> countIn(String? dir) async {
    var n = 0;
    for (final b in await _books()) {
      if (await File(await _placeIn(dir, b.path, b.folder)).exists()) n++;
    }
    return n;
  }

  /// Moves the library's sidecars from where [from] keeps them to where
  /// [to] does (null: beside each comic), after the sidecar folder setting
  /// changed. One meeting a sidecar of the same book at the new place is
  /// merged into it. Returns how many moved.
  Future<int> moveAll({required String? from, required String? to}) async {
    await flush();
    final roots = await _roots();
    final moves = [
      for (final b in await _books())
        (
          from: from == null
              ? sidecarPath(b.path, folder: b.folder)
              : storedSidecarPath(b.path, folder: b.folder, dir: from, roots: roots),
          to: to == null
              ? sidecarPath(b.path, folder: b.folder)
              : storedSidecarPath(b.path, folder: b.folder, dir: to, roots: roots),
        ),
    ];
    final me = await device();
    return _serial(() => _moveOnWorker(moves, me.id));
  }
}

// Top level, so the closures sent to the worker hold only their arguments.
Future<void> _writeOnWorker(String target, SidecarData data, String device) =>
    Isolate.run(() => writeSidecar(target, data, device: device, appVersion: appVersion));

Future<int> _moveOnWorker(List<({String from, String to})> moves, String device) =>
    Isolate.run(() => moves.where((m) => moveSidecar(m.from, m.to, device: device, appVersion: appVersion)).length);

/// Reads the sidecars of the book at [path] from [places], the one written
/// first, merged; that one wins where they differ.
Future<SidecarData?> _readAll(String path, String contentKey, bool folder, List<String> places) => Isolate.run(() {
  if (!folder) relinkOrphan(path, contentKey, sidecar: places.first);
  SidecarData? merged;
  for (final at in places.reversed) {
    final side = readSidecar(at);
    if (side == null || side.contentKey != contentKey) continue;
    merged = merged == null ? side : mergeSidecars(merged, side);
  }
  return merged;
});
