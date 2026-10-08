import 'dart:async';
import 'dart:io';

import 'package:comic_formats/comic_formats.dart' show FolderDocument, contentKey;
import 'package:comic_sync/comic_sync.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_database.dart';
import 'book_paths.dart';
import 's3_settings.dart';
import 'sidecar.dart';
import 'sidecar_sync.dart';

/// Whether the bucket answers, as far as this device knows.
enum S3Reach {
  /// S3 sync is not set up.
  off,

  /// Set up, not asked yet.
  unknown,
  ok,

  /// The last call got no answer: the home cluster is off, or the network.
  unreachable,
}

/// S3 sync as the library and the status line show it.
@immutable
class S3Status {
  const S3Status({this.reach = S3Reach.off, this.host, this.waiting = 0, this.transfers = const {}});

  final S3Reach reach;

  /// The server, for "S3 (garage.lan) is out of reach".
  final String? host;

  /// Comics with something still to send (an upload, a sidecar, a removal).
  final int waiting;

  /// Comics going up or down right now, by content key, with the share done.
  final Map<String, double> transfers;

  bool get on => reach != S3Reach.off;

  S3Status copyWith({S3Reach? reach, String? host, int? waiting, Map<String, double>? transfers}) => S3Status(
    reach: reach ?? this.reach,
    host: host ?? this.host,
    waiting: waiting ?? this.waiting,
    transfers: transfers ?? this.transfers,
  );
}

/// What is waiting to go to the bucket for a comic (the s3_books table's
/// `pending`).
abstract final class S3Pending {
  static const upload = 'upload', sidecar = 'sidecar', remove = 'remove';
}

/// One notice of the sync. [failure] when it tells of something that did
/// not work or warns (out of reach, a refusal, a download that failed): the
/// app then keeps it up its whole time, where a routine one ("Uploaded X")
/// is replaced by the next notice.
typedef S3Notice = ({String text, bool failure});

/// S3 sync (design plan section 13): comics and their sidecars in the
/// user's own bucket, so reading goes on from the other device.
///
/// Everything is local first. The index and the sidecars stay the working
/// copies; this sends them to the bucket when asked (uploads, removals) or
/// when a sidecar changes, and brings the bucket's sidecar back when it is
/// newer. The newest `written_at` wins, whole file, never merged. What has
/// not reached the bucket waits in the s3_books table, so a bucket that is
/// off only means waiting: one notice, and a retry that backs off from 30
/// seconds to five minutes.
class S3Sync {
  S3Sync(
    this._db, {
    required this.sidecars,
    required this.settings,
    required this.storeFor,
    required this.coverDir,
    this.onDownloaded,
    this.pushDelay = const Duration(seconds: 10),
    this.refreshEvery = const Duration(minutes: 5),
  });

  final AppDatabase _db;
  final SidecarSync sidecars;
  final S3Settings settings;
  final RemoteStore Function(S3Config) storeFor;
  final String? coverDir;

  /// A comic was downloaded into a library folder: the library scans it in.
  final Future<void> Function()? onDownloaded;

  /// How long a changed sidecar waits before it goes up, so a sitting's
  /// page turns go as one.
  final Duration pushDelay;
  final Duration refreshEvery;

  final _status = StreamController<S3Status>.broadcast();
  final _notices = StreamController<S3Notice>.broadcast();
  S3Status _now = const S3Status();

  Stream<S3Status> get status => _status.stream;
  S3Status get current => _now;

  /// One-line notices for the status line: out of reach, back, uploaded.
  Stream<S3Notice> get notices => _notices.stream;

  RemoteStore? _store;
  S3Config? _config;
  String? _configId;
  Timer? _pushTimer, _retryTimer, _refreshTimer;
  Duration _backoff = const Duration(seconds: 30);
  bool _disposed = false;

  /// The bucket was out of reach since the last drain that sent anything,
  /// for "S3 is back; 3 comics caught up".
  bool _wasOut = false;

  void _set(S3Status s) {
    _now = s;
    if (!_status.isClosed) _status.add(s);
  }

  /// A routine notice: something done.
  void _say(String text) {
    if (!_notices.isClosed) _notices.add((text: text, failure: false));
  }

  /// A notice of something that did not work, or a warning.
  void _fail(String text) {
    if (!_notices.isClosed) _notices.add((text: text, failure: true));
  }

  /// The bucket as the settings say now, or null when sync is off.
  Future<(RemoteStore, S3Config)?> _connect() async {
    final S3Config? c;
    try {
      c = await settings.config();
    } catch (e) {
      debugPrint('Could not read the S3 settings: $e');
      return null;
    }
    if (c == null) {
      _drop();
      if (_now.reach != S3Reach.off) _set(const S3Status());
      return null;
    }
    final id = [c.endpoint, c.region, c.bucket, c.prefix, c.accessKey, c.secretKey].join('\n');
    if (id != _configId) {
      _drop();
      _store = storeFor(c);
      _config = c;
      _configId = id;
      _set(_now.copyWith(reach: S3Reach.unknown, host: c.host));
    }
    return (_store!, _config!);
  }

  void _drop() {
    _store?.close();
    _store = null;
    _config = null;
    _configId = null;
  }

  /// Runs [f] against the bucket and keeps track of whether it answers:
  /// the first failure to connect says so once, and the retry starts.
  /// Rethrows every RemoteException.
  Future<T> _guard<T>(Future<T> Function() f) async {
    try {
      final r = await f();
      _answered();
      return r;
    } on RemoteException catch (e) {
      if (e.failure == RemoteFailure.unreachable) {
        _unreachable();
      } else {
        _answered();
      }
      rethrow;
    }
  }

  void _answered() {
    _backoff = const Duration(seconds: 30);
    if (_now.reach != S3Reach.ok) _set(_now.copyWith(reach: S3Reach.ok));
  }

  void _unreachable() {
    _wasOut = true;
    if (_now.reach != S3Reach.unreachable) {
      _fail('S3 (${_config?.host ?? 'the bucket'}) is out of reach; saving on this device');
      _set(_now.copyWith(reach: S3Reach.unreachable));
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(_backoff, () => unawaited(sync()));
    final next = _backoff * 2;
    _backoff = next > const Duration(minutes: 5) ? const Duration(minutes: 5) : next;
  }

  /// Checks the bucket now and every few minutes: fetches what the other
  /// device put there and sends what waits here. At start, on resume, on
  /// `R` and after the settings change.
  Future<void> start() async {
    _refreshTimer?.cancel();
    if (await _connect() == null) return;
    _refreshTimer = Timer.periodic(refreshEvery, (_) => unawaited(sync()));
    await sync();
  }

  /// The settings were saved or turned off: starts over with them.
  Future<void> settingsChanged() async {
    _drop();
    _retryTimer?.cancel();
    await start();
  }

  /// Sync was turned off: forgets what this device knew of the bucket, so
  /// no comic shows as on S3. Nothing in the bucket changes.
  Future<void> turnedOff() async {
    _drop();
    _retryTimer?.cancel();
    _refreshTimer?.cancel();
    await _db.delete(_db.s3Books).go();
    _set(const S3Status());
  }

  /// Refreshes the shelf and sends what waits.
  Future<void> sync() async {
    try {
      await refreshShelf();
    } on RemoteException {
      // Said already, or the retry comes.
    } catch (e) {
      debugPrint('S3 shelf refresh failed: $e');
    }
    await drain();
  }

  Future<void> _countWaiting() async {
    final n =
        await (_db.selectOnly(_db.s3Books)
              ..addColumns([_db.s3Books.contentKey.count()])
              ..where(_db.s3Books.pending.isNotNull()))
            .map((r) => r.read(_db.s3Books.contentKey.count()) ?? 0)
            .getSingle();
    if (n != _now.waiting) _set(_now.copyWith(waiting: n));
  }

  void _progress(String key, double? done) {
    final t = {..._now.transfers};
    if (done == null) {
      t.remove(key);
    } else {
      t[key] = done.clamp(0, 1);
    }
    _set(_now.copyWith(transfers: t));
  }

  // ---------------------------------------------------------------- shelf

  /// Lists the bucket: a comic new there gets its manifest and cover
  /// fetched (a few kilobytes; never the comic itself), one gone from
  /// there loses its row here, unless this device is still uploading it.
  Future<void> refreshShelf() async {
    final conn = await _connect();
    if (conn == null) return;
    final (store, config) = conn;
    await _guard(() async {
      final keys = await listShelf(store, config.prefix);
      final rows = await _db.select(_db.s3Books).get();
      final known = {for (final r in rows) r.contentKey};
      for (final r in rows) {
        if (keys.contains(r.contentKey) || r.pending == S3Pending.upload) continue;
        await (_db.delete(_db.s3Books)..where((t) => t.contentKey.equals(r.contentKey))).go();
      }
      for (final key in keys.difference(known)) {
        final o = BookObjects(config.prefix, key);
        final bytes = await store.get(o.manifest);
        final m = bytes == null ? null : Manifest.decode(String.fromCharCodes(bytes));
        if (m == null || m.contentKey != key) continue;
        if (coverDir case final dir?) {
          final f = File(coverFile(dir, key));
          if (!f.existsSync()) {
            final cover = await store.get(o.cover);
            if (cover != null) {
              await f.parent.create(recursive: true);
              await f.writeAsBytes(cover);
            }
          }
        }
        await _db
            .into(_db.s3Books)
            .insertOnConflictUpdate(S3BooksCompanion.insert(contentKey: key, manifest: m.encode()));
      }
    });
    await _countWaiting();
  }

  // ---------------------------------------------------------------- queue

  Future<void>? _draining;
  bool _again = false;

  /// Sends everything waiting, oldest first, until done or the bucket
  /// stops answering.
  Future<void> drain() {
    _pushTimer?.cancel();
    if (_draining != null) {
      _again = true;
      return _draining!;
    }
    return _draining = _drainLoop().whenComplete(() => _draining = null);
  }

  Future<void> _drainLoop() async {
    // What the bucket refused with in this drain, each said once, also when
    // the queue is gone through again (`_again`).
    final refused = <String>{};
    do {
      _again = false;
      final conn = await _connect();
      if (conn == null) return;
      var sent = 0;
      final failed = <String>{};
      while (!_disposed) {
        final q = _db.select(_db.s3Books)
          ..where((t) => t.pending.isNotNull() & t.contentKey.isNotIn(failed))
          ..orderBy([(t) => OrderingTerm(expression: t.pendingSince)])
          ..limit(1);
        final row = await q.getSingleOrNull();
        if (row == null) break;
        try {
          await _guard(
            () => switch (row.pending) {
              S3Pending.upload => _upload(row, conn),
              S3Pending.remove => _remove(row, conn),
              _ => _push(row, conn),
            },
          );
          sent++;
        } on RemoteException catch (e) {
          if (e.failure == RemoteFailure.unreachable) break;
          // Refused keys or a missing bucket: said once a drain, however
          // many comics wait (they are all refused alike), tried again later.
          if (refused.add(e.message)) _fail('S3: ${e.message}');
          failed.add(row.contentKey);
        } catch (e) {
          debugPrint('S3 sync of ${row.contentKey} failed: $e');
          failed.add(row.contentKey);
        }
        await _countWaiting();
      }
      if (sent > 0 && _wasOut && _now.reach == S3Reach.ok) {
        _say('S3 is back; $sent ${sent == 1 ? 'comic' : 'comics'} caught up');
        _wasOut = false;
      }
    } while (_again && !_disposed);
  }

  /// Marks [rows]' change as sent, unless another came meanwhile.
  Future<void> _done(S3Book row, {int? sidecarAt, String? manifest}) =>
      (_db.update(_db.s3Books)..where(
            (t) =>
                t.contentKey.equals(row.contentKey) &
                t.pending.equalsNullable(row.pending) &
                t.pendingSince.equalsNullable(row.pendingSince),
          ))
          .write(
            S3BooksCompanion(
              pending: const Value(null),
              pendingSince: const Value(null),
              sidecarAt: sidecarAt == null ? const Value.absent() : Value(sidecarAt),
              manifest: manifest == null ? const Value.absent() : Value(manifest),
            ),
          );

  // --------------------------------------------------------------- upload

  /// Puts the comics [keys] on S3, in the background (design plan section
  /// 13): the comic, its cover, its sidecar, then its manifest, so a comic
  /// counts as there only once all of it is. One already in the bucket is
  /// not sent again: only its sidecar is brought in step, the newest winning.
  Future<int> upload(Iterable<String> keys) async {
    if (await _connect() == null) return 0;
    var n = 0;
    final now = DateTime.now();
    for (final key in keys) {
      final row = await (_db.select(_db.s3Books)..where((t) => t.contentKey.equals(key))).getSingleOrNull();
      // One on its way already. A comic on S3 goes through an upload too:
      // it finds the comic there and only brings the sidecars in step.
      if (row?.pending == S3Pending.upload) continue;
      final at = await sidecars.placeOf(key);
      if (at == null) continue;
      final m = await _manifestFor(key, at);
      if (m == null) continue;
      await _db
          .into(_db.s3Books)
          .insertOnConflictUpdate(
            S3BooksCompanion.insert(
              contentKey: key,
              // The bucket's own manifest, when it is known, names who uploaded it.
              manifest: row == null || row.pending == S3Pending.remove ? m.encode() : row.manifest,
              pending: const Value(S3Pending.upload),
              pendingSince: Value(now.add(Duration(microseconds: n))),
            ),
          );
      n++;
    }
    await _countWaiting();
    unawaited(drain());
    return n;
  }

  Future<Manifest?> _manifestFor(String key, ({String path, bool folder}) at) async {
    final book = await _db
        .customSelect(
          'SELECT b.title, b.number, b.year, b.page_count, b.format, s.name AS series FROM books b '
          'LEFT JOIN series s ON s.id = b.series_id WHERE b.content_key = ?',
          variables: [Variable(key)],
        )
        .getSingleOrNull();
    if (book == null) return null;
    final roots = await _db.select(_db.roots).get();
    final root = roots.where((r) => p.equals(r.path, at.path) || p.isWithin(r.path, at.path)).firstOrNull;
    final rel = root == null ? p.basename(at.path) : p.relative(at.path, from: root.path);
    final folder = p.dirname(rel) == '.' ? '' : p.split(p.dirname(rel)).join('/');
    final me = await sidecars.device();
    final files = <({String path, int size})>[];
    var size = 0;
    if (at.folder) {
      final doc = FolderDocument.open(at.path);
      for (final name in doc.pageNames) {
        final n = File(p.join(doc.root, name)).lengthSync();
        files.add((path: p.split(name).join('/'), size: n));
        size += n;
      }
    } else {
      size = File(at.path).lengthSync();
    }
    final ext = p.extension(at.path).replaceFirst('.', '').toLowerCase();
    return Manifest(
      contentKey: key,
      title: book.read<String>('title'),
      series: book.readNullable<String>('series'),
      number: book.readNullable<String>('number'),
      year: book.readNullable<int>('year'),
      pageCount: book.read<int>('page_count'),
      format: book.read<String>('format'),
      fileName: p.basename(at.path),
      folder: folder,
      ext: at.folder ? null : (ext.isEmpty ? book.read<String>('format') : ext),
      size: size,
      files: files,
      uploadedBy: me.name,
      uploadedAt: DateTime.now(),
    );
  }

  static Stream<Uint8List> _read(File f) => f.openRead().map((c) => c is Uint8List ? c : Uint8List.fromList(c));

  Future<void> _upload(S3Book row, (RemoteStore, S3Config) conn) async {
    final (store, config) = conn;
    final key = row.contentKey;
    final at = await sidecars.placeOf(key);
    final m = at == null ? null : await _manifestFor(key, at);
    if (at == null || m == null) {
      // Gone from the library before it went up.
      await (_db.delete(_db.s3Books)..where((t) => t.contentKey.equals(key))).go();
      return;
    }
    final o = BookObjects(config.prefix, key);
    var before = 0;
    void sent(int n) => _progress(key, m.size == 0 ? 1 : (before + n) / m.size);
    _progress(key, 0);
    try {
      // Already in the bucket, from this device or another: the same
      // content key and the same sizes, so the comic itself stays as it is.
      final there = await _alreadyThere(store, o, m);
      if (!there) {
        if (m.isFolder) {
          for (final f in m.files) {
            final file = File(p.join(at.path, p.joinAll(f.path.split('/'))));
            await store.put(o.file(f.path), _read(file), size: f.size, onProgress: sent);
            before += f.size;
          }
        } else {
          await store.put(o.comic(m.ext!), _read(File(at.path)), size: m.size, onProgress: sent);
        }
        if (coverDir case final dir?) {
          final cover = File(coverFile(dir, key));
          if (cover.existsSync()) await store.put(o.cover, _read(cover), size: cover.lengthSync());
        }
      }
      _progress(key, 1);
      final sidecarAt = await _meetSidecar(store, o, key, at);
      if (!there) {
        final manifest = m.encode();
        await store.put(o.manifest, Stream.value(Uint8List.fromList(manifest.codeUnits)), size: manifest.length);
        await _done(row, sidecarAt: sidecarAt, manifest: manifest);
        _say('Uploaded ${m.title} to S3');
      } else {
        // The bucket's manifest stays, so it still names who uploaded it.
        final kept = Manifest.decode(row.manifest) == null ? m.encode() : row.manifest;
        await _done(row, sidecarAt: sidecarAt, manifest: kept);
        _say('${m.title} was on S3 already; its newest sidecar is on both');
      }
    } finally {
      _progress(key, null);
    }
  }

  /// Whether [m]'s comic is in the bucket already: its manifest, and the
  /// comic file (or every file of a folder book) at the same size.
  Future<bool> _alreadyThere(RemoteStore store, BookObjects o, Manifest m) async {
    if (await store.head(o.manifest) == null) return false;
    if (!m.isFolder) return (await store.head(o.comic(m.ext!)))?.size == m.size;
    final sizes = {
      await for (final r in store.list('${o.dir}files/')) r.key.substring('${o.dir}files/'.length): r.size,
    };
    return m.files.every((f) => sizes[f.path] == f.size);
  }

  /// Brings the sidecar of [key] in step with the bucket's for an upload,
  /// the newest whole file winning, and returns the written_at both now
  /// have. A comic with no sidecar either side gets one written first.
  Future<int?> _meetSidecar(RemoteStore store, BookObjects o, String key, ({String path, bool folder}) at) async {
    // Changes still waiting go into the local file first.
    await sidecars.flush();
    var side = await sidecars.sidecarFor(at.path, folder: at.folder);
    final remote = int.tryParse((await store.head(o.sidecar))?.metadata[writtenAtMeta] ?? '');
    if (remote == null && sidecarWrittenAt(side) == null) {
      // A comic never opened here has none yet.
      await sidecars.writeBeside(at.path, key, folder: at.folder);
      side = await sidecars.sidecarFor(at.path, folder: at.folder);
    }
    switch (compareSidecars(local: sidecarWrittenAt(side), remote: remote)) {
      case SidecarMove.push:
        return _putSidecar(store, o, side);
      case SidecarMove.pull:
        await _pull(store, o, key, side, remote!);
        return remote;
      case SidecarMove.none:
        return remote;
    }
  }

  /// Puts the sidecar at [side] in the bucket with its written_at, which
  /// it returns; null when there is none here.
  Future<int?> _putSidecar(RemoteStore store, BookObjects o, String side) async {
    final writtenAt = sidecarWrittenAt(side);
    if (writtenAt == null) return null;
    final me = await sidecars.device();
    // Read whole first: a write under way renames a new file over it.
    final bytes = await File(side).readAsBytes();
    await store.put(
      o.sidecar,
      Stream.value(bytes),
      size: bytes.length,
      metadata: {writtenAtMeta: '$writtenAt', deviceMeta: me.id},
    );
    return writtenAt;
  }

  // -------------------------------------------------------------- sidecar

  /// The sidecar of [contentKey] was written here: when the comic is on S3
  /// it goes up a little later, with the next ones.
  Future<void> sidecarWritten(String contentKey) async {
    final n =
        await (_db.update(_db.s3Books)..where(
              (t) => t.contentKey.equals(contentKey) & (t.pending.isNull() | t.pending.equals(S3Pending.sidecar)),
            ))
            .write(S3BooksCompanion(pending: const Value(S3Pending.sidecar), pendingSince: Value(DateTime.now())));
    if (n == 0) return;
    await _countWaiting();
    if (_pushTimer?.isActive ?? false) return;
    _pushTimer = Timer(pushDelay, () => unawaited(drain()));
  }

  /// The newest sidecar wins, whole: pushes this device's when it is newer,
  /// takes the bucket's when that is. A comic whose manifest has gone was
  /// removed from S3 elsewhere; it loses its row, and nothing is put back.
  Future<void> _push(S3Book row, (RemoteStore, S3Config) conn) async {
    final (store, config) = conn;
    final key = row.contentKey;
    final o = BookObjects(config.prefix, key);
    if (await store.head(o.manifest) == null) {
      await (_db.delete(_db.s3Books)..where((t) => t.contentKey.equals(key))).go();
      return;
    }
    final at = await sidecars.placeOf(key);
    if (at == null) return _done(row);
    final side = await sidecars.sidecarFor(at.path, folder: at.folder);
    final remote = int.tryParse((await store.head(o.sidecar))?.metadata[writtenAtMeta] ?? '');
    switch (compareSidecars(local: sidecarWrittenAt(side), remote: remote)) {
      case SidecarMove.push:
        await _done(row, sidecarAt: await _putSidecar(store, o, side));
      case SidecarMove.pull:
        await _pull(store, o, key, side, remote!);
        await _done(row, sidecarAt: remote);
      case SidecarMove.none:
        await _done(row);
    }
  }

  /// Fetches the bucket's sidecar of [key] and puts it in place of the one
  /// at [target], taking it into the index whole.
  Future<SidecarImport?> _pull(
    RemoteStore store,
    BookObjects o,
    String key,
    String target,
    int remoteAt, {
    bool Function()? stillWanted,
  }) async {
    await Directory(p.dirname(target)).create(recursive: true);
    final tmp = p.join(p.dirname(target), '.${p.basename(target)}.s3');
    final file = File(tmp);
    final sink = file.openWrite();
    bool ok;
    try {
      ok = await store.download(o.sidecar, sink);
    } finally {
      await sink.close();
    }
    if (!ok || readSidecar(tmp)?.contentKey != key || !(stillWanted?.call() ?? true)) {
      if (file.existsSync()) file.deleteSync();
      return null;
    }
    final imported = await sidecars.replaceWith(key, target, tmp);
    await (_db.update(
      _db.s3Books,
    )..where((t) => t.contentKey.equals(key))).write(S3BooksCompanion(sidecarAt: Value(remoteAt)));
    return imported;
  }

  /// Opening a comic that is on S3: when the bucket's sidecar is newer, it
  /// replaces this one before the page shows. Gives up after [limit], so
  /// a bucket that is off never keeps a book from opening. True when a
  /// newer sidecar came in.
  Future<bool> pullOnOpen(String contentKey, {Duration limit = const Duration(seconds: 2)}) async {
    final row = await (_db.select(_db.s3Books)..where((t) => t.contentKey.equals(contentKey))).getSingleOrNull();
    if (row == null || row.pending == S3Pending.upload || row.pending == S3Pending.remove) return false;
    final conn = await _connect();
    if (conn == null) return false;
    final (store, config) = conn;
    var wanted = true;
    Future<bool> check() => _guard(() async {
      final o = BookObjects(config.prefix, contentKey);
      final at = await sidecars.placeOf(contentKey);
      if (at == null) return false;
      final side = await sidecars.sidecarFor(at.path, folder: at.folder);
      final remote = int.tryParse((await store.head(o.sidecar))?.metadata[writtenAtMeta] ?? '');
      if (compareSidecars(local: sidecarWrittenAt(side), remote: remote) != SidecarMove.pull) return false;
      return await _pull(store, o, contentKey, side, remote!, stillWanted: () => wanted) != null;
    });
    try {
      return await check().timeout(limit);
    } on TimeoutException {
      wanted = false;
      return false;
    } catch (e) {
      debugPrint('S3 check on open failed: $e');
      return false;
    }
  }

  // ------------------------------------------------------------- download

  /// Downloads the comic [contentKey] from S3 into the first library
  /// folder, at the place its manifest names, with its sidecar, and scans
  /// it in. Returns where it went, or null (said in a notice) when it
  /// could not.
  Future<String?> download(String contentKey) => _download(contentKey, null);

  /// Downloads the comics [contentKeys] one after the other. What stops
  /// one of them stops them all (no library folder to put them in, the
  /// bucket out of reach), so then the rest are not tried and one notice
  /// tells of all that are left, not one a comic.
  Future<void> downloadAll(List<String> contentKeys) async {
    final batch = _Batch();
    for (var i = 0; i < contentKeys.length && !batch.stopped; i++) {
      batch.left = contentKeys.length - i;
      await _download(contentKeys[i], batch);
    }
  }

  /// [download], as one of [batch] when it is not null.
  Future<String?> _download(String contentKey, _Batch? batch) async {
    final row = await (_db.select(_db.s3Books)..where((t) => t.contentKey.equals(contentKey))).getSingleOrNull();
    final m = row == null ? null : Manifest.decode(row.manifest);
    final conn = await _connect();
    if (m == null || conn == null) return null;
    final (store, config) = conn;
    final place = await _placeFor(m, contentKey, batch);
    if (place == null) return null;
    final target = place.path;
    if (place.there) {
      await onDownloaded?.call();
      return target;
    }
    final o = BookObjects(config.prefix, contentKey);
    _progress(contentKey, 0);
    final made = <String>[];
    try {
      await _guard(() => _fetchComic(store, o, m, target, made));
      if (await _keyOf(target) != contentKey) {
        _deleteAll(made);
        _fail('The download of ${m.title} did not match what was uploaded; nothing was kept');
        return null;
      }
      await _fetchSidecar(store, o, m, target);
      await onDownloaded?.call();
      _say('Downloaded ${m.title}');
      return target;
    } on RemoteException catch (e) {
      _deleteAll(made);
      _notFetched(e, m, batch);
      return null;
    } on FileSystemException catch (e) {
      _deleteAll(made);
      _fail('Could not download ${m.title}: ${e.message}');
      return null;
    } finally {
      _progress(contentKey, null);
    }
  }

  /// Where the download of [m] goes: under the first library folder, at
  /// the place its manifest names, or beside what is there under that name
  /// already. `there` when that is this very comic, so nothing is to
  /// fetch. Null, said in a notice and the end of [batch], when the
  /// library has no folder.
  Future<({String path, bool there})?> _placeFor(Manifest m, String contentKey, _Batch? batch) async {
    final roots = await (_db.select(_db.roots)..orderBy([(r) => OrderingTerm(expression: r.id)])).get();
    if (roots.isEmpty) {
      _fail('Add a library folder first: downloads go into it');
      batch?.stopped = true;
      return null;
    }
    final target = p.joinAll([roots.first.path, ...m.relPath.split('/')]);
    if (FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound) return (path: target, there: false);
    if (await _keyOf(target) == contentKey) return (path: target, there: true);
    return (path: _free(target, folder: m.isFolder), there: false);
  }

  /// Fetches the comic of [m] to [target], file by file for a folder book,
  /// noting in [made] what it starts to write, for the caller to take away
  /// again when the download fails.
  Future<void> _fetchComic(RemoteStore store, BookObjects o, Manifest m, String target, List<String> made) async {
    var before = 0;
    void got(int n) => _progress(m.contentKey, m.size == 0 ? 1 : (before + n) / m.size);
    if (m.isFolder) {
      made.add(target);
      for (final f in m.files) {
        await _fetch(store, o.file(f.path), p.joinAll([target, ...f.path.split('/')]), got);
        before += f.size;
      }
    } else {
      await Directory(p.dirname(target)).create(recursive: true);
      made.add(target);
      await _fetch(store, o.comic(m.ext ?? m.format), target, got);
    }
  }

  /// The bucket's sidecar for the comic downloaded to [target], so it
  /// opens where the other device was.
  Future<void> _fetchSidecar(RemoteStore store, BookObjects o, Manifest m, String target) async {
    final side = await sidecars.sidecarFor(target, folder: m.isFolder);
    final head = await _guard(() => store.head(o.sidecar));
    if (head == null) return;
    final remoteAt = int.tryParse(head.metadata[writtenAtMeta] ?? '');
    await Directory(p.dirname(side)).create(recursive: true);
    await _guard(() => _fetch(store, o.sidecar, side, (_) {}));
    await (_db.update(
      _db.s3Books,
    )..where((t) => t.contentKey.equals(m.contentKey))).write(S3BooksCompanion(sidecarAt: Value(remoteAt)));
  }

  /// Says that the bucket did not give [m]. Out of reach, which is the end
  /// of [batch], it tells of all the comics left in it in one notice; a
  /// refusal is this comic's own and the batch goes on.
  void _notFetched(RemoteException e, Manifest m, _Batch? batch) {
    if (e.failure != RemoteFailure.unreachable) {
      _fail('Could not download ${m.title}: ${e.message}');
      return;
    }
    final what = batch == null || batch.left == 1 ? m.title : '${batch.left} comics';
    _fail('S3 is out of reach: $what can be downloaded when it is back');
    batch?.stopped = true;
  }

  static Future<String?> _keyOf(String path) async {
    try {
      return await contentKey(path);
    } catch (_) {
      return null;
    }
  }

  static void _deleteAll(List<String> made) {
    for (final m in made) {
      try {
        final t = FileSystemEntity.typeSync(m);
        if (t == FileSystemEntityType.directory) Directory(m).deleteSync(recursive: true);
        if (t == FileSystemEntityType.file) File(m).deleteSync();
      } catch (_) {}
    }
  }

  /// [path], or `name (2).ext` and so on when something else is there.
  static String _free(String path, {required bool folder}) {
    final dir = p.dirname(path);
    final base = folder ? p.basename(path) : p.basenameWithoutExtension(path);
    final ext = folder ? '' : p.extension(path);
    for (var i = 2; ; i++) {
      final c = p.join(dir, '$base ($i)$ext');
      if (FileSystemEntity.typeSync(c) == FileSystemEntityType.notFound) return c;
    }
  }

  /// Fetches [key] into [path] through a part file, renamed when complete.
  /// The part file goes on any failure (the bucket gone part of the way, a
  /// refusal, no such object), so nothing half fetched is left beside the
  /// comics: the caller's clean-up knows [path], not the part file.
  static Future<void> _fetch(RemoteStore store, String key, String path, void Function(int) onProgress) async {
    await Directory(p.dirname(path)).create(recursive: true);
    final part = File('$path.part');
    var fetched = false;
    try {
      final sink = part.openWrite();
      bool ok;
      try {
        ok = await store.download(key, sink, onProgress: onProgress);
      } finally {
        await sink.close();
      }
      if (!ok) throw RemoteException(RemoteFailure.other, 'the bucket has no $key');
      await part.rename(path);
      fetched = true;
    } finally {
      if (!fetched) _deleteQuietly(part);
    }
  }

  static void _deleteQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // --------------------------------------------------------------- remove

  /// Whether the comic [contentKey] is on the S3 shelf as far as this device
  /// knows (and not on its way off it).
  Future<bool> onShelf(String contentKey) async {
    final row = await (_db.select(_db.s3Books)..where((t) => t.contentKey.equals(contentKey))).getSingleOrNull();
    return row != null && row.pending != S3Pending.remove;
  }

  /// Takes the comics [keys] off S3: the manifest first, then the rest.
  /// Nothing on this device changes. Waits in the queue while the bucket
  /// is off.
  Future<void> removeFromS3(Iterable<String> keys) async {
    final now = DateTime.now();
    for (final key in keys) {
      await (_db.update(_db.s3Books)..where((t) => t.contentKey.equals(key))).write(
        S3BooksCompanion(pending: const Value(S3Pending.remove), pendingSince: Value(now)),
      );
    }
    await _countWaiting();
    unawaited(drain());
  }

  Future<void> _remove(S3Book row, (RemoteStore, S3Config) conn) async {
    final (store, config) = conn;
    await removeFromShelf(store, BookObjects(config.prefix, row.contentKey));
    await (_db.delete(_db.s3Books)..where((t) => t.contentKey.equals(row.contentKey))).go();
    final m = Manifest.decode(row.manifest);
    _say('Removed ${m?.title ?? 'the comic'} from S3');
  }

  /// Sends what waits now: on closing a book, pausing and quitting, with
  /// [limit] so nothing waits long on a bucket that is off.
  Future<void> flush({Duration limit = const Duration(seconds: 5)}) async {
    try {
      await drain().timeout(limit);
    } on TimeoutException {
      // It carries on in the background, or next time.
    } catch (e) {
      debugPrint('S3 flush failed: $e');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _pushTimer?.cancel();
    _retryTimer?.cancel();
    _refreshTimer?.cancel();
    _drop();
    await _status.close();
    await _notices.close();
  }
}

/// Where [S3Sync.downloadAll] is: how many comics are left, the one being
/// fetched included, and whether something stopped them all.
class _Batch {
  int left = 0;
  bool stopped = false;
}
