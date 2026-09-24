import 'dart:io';
import 'dart:typed_data';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'app_database.dart';

/// The per-comic sidecar (design plan section 7): one small SQLite file
/// beside the book holding what the app knows about it, so detection,
/// bookmarks and position travel with the file. This is the file side:
/// plain data in, plain data out, and a merge. Nothing here touches the app
/// index or Flutter, so it runs on any isolate and from a shell tool.
///
/// `Daredevil 181.cbz` gets `Daredevil 181.cbz.crdb`; a folder book keeps
/// `.comicredr.crdb` inside itself.
String sidecarPath(String bookPath, {required bool folder}) =>
    folder ? p.join(bookPath, folderSidecarName) : '$bookPath$sidecarExtension';

/// Where the sidecar of the book at [bookPath] goes when the person keeps
/// every sidecar in one folder, [dir], instead of beside the comics (the
/// Settings choice). The folder is laid out like the library, as "Export
/// sidecars" lays it out: `Comics/Marvel/Daredevil 181.cbz` under the root
/// `/home/me/Comics` gets `dir/Comics/Marvel/Daredevil 181.cbz.crdb`. Each
/// root is named by its folder's name, so a laptop and a phone with their
/// comics in different places still agree; two roots with the same name
/// get their id added. A book in no root (one opened from anywhere) goes
/// under `dir/elsewhere/` by its full path.
String storedSidecarPath(
  String bookPath, {
  required bool folder,
  required String dir,
  required List<({int id, String path})> roots,
}) {
  ({int id, String path})? root;
  for (final r in roots) {
    if (!(p.equals(r.path, bookPath) || p.isWithin(r.path, bookPath))) continue;
    if (root == null || r.path.length > root.path.length) root = r;
  }
  final String at;
  if (root == null) {
    at = p.join(dir, 'elsewhere', p.relative(p.absolute(bookPath), from: p.rootPrefix(p.absolute(bookPath))));
  } else {
    final name = rootLabel(root, roots);
    final rel = p.relative(bookPath, from: root.path);
    at = rel == '.' ? p.join(dir, name) : p.join(dir, name, rel);
  }
  return sidecarPath(at, folder: folder);
}

/// The name a library root's folder has under a sidecar folder: its own
/// name, with its id when another root shares it.
String rootLabel(({int id, String path}) root, List<({int id, String path})> roots) {
  String name(String path) {
    final n = p.basename(p.normalize(path));
    return n.isEmpty || n == p.separator ? 'root' : n;
  }

  final mine = name(root.path);
  final shared = roots.where((r) => name(r.path) == mine).length > 1;
  return shared ? '$mine-${root.id}' : mine;
}

const sidecarExtension = '.crdb';
const folderSidecarName = '.comicredr.crdb';

/// The format this code writes. A sidecar from a newer app is read for the
/// tables it shares with this one and never written over. 2: collections,
/// and the nullable `panels.shape` column (frame outlines), which a
/// sidecar written before it lacks. 3: the nullable `analysed_pages.trim`
/// column (the part of the page detection looked at).
const sidecarSchemaVersion = 3;

/// Whether [path] is a sidecar or one being written, which the library
/// scanner and its folder watch ignore.
bool isSidecarFile(String path) {
  final name = p.basename(path);
  return name.endsWith(sidecarExtension) || name.contains('$sidecarExtension.');
}

/// One device's reading position. The sidecar keeps one per device, so the
/// laptop and the phone never overwrite each other's; the index keeps only
/// this device's.
class SidecarProgress {
  const SidecarProgress({
    required this.device,
    required this.deviceName,
    required this.page,
    this.panel,
    required this.percent,
    required this.finished,
    required this.updatedAt,
    this.viewJson,
  });

  /// A random id, stable per install; [deviceName] is for people.
  final String device;
  final String deviceName;
  final int page;
  final int? panel;
  final double percent;
  final bool finished;
  final DateTime updatedAt;

  /// The rest of the spot, as ReadingPosition writes it.
  final String? viewJson;
}

/// Facts about the book, for anyone reading the sidecar with sqlite3.
class SidecarBook {
  const SidecarBook({
    required this.title,
    this.series,
    this.number,
    this.volume,
    this.year,
    this.writers,
    this.artists,
    this.summary,
  });

  final String title;
  final String? series;
  final String? number;
  final int? volume;
  final int? year;
  final String? writers;
  final String? artists;
  final String? summary;
}

/// Everything a sidecar holds for the book with [contentKey]. The index's
/// own row types carry panels and bookmarks, so a merge result goes back
/// into the index as it is.
class SidecarData {
  const SidecarData({
    required this.contentKey,
    this.schemaVersion = sidecarSchemaVersion,
    this.book,
    this.analysed = const [],
    this.panels = const [],
    this.bookmarks = const [],
    this.progress = const [],
    this.overrides = const {},
    this.collections = const [],
    this.cover,
  });

  final String contentKey;
  final int schemaVersion;
  final SidecarBook? book;
  final List<AnalysedPage> analysed;
  final List<PanelRow> panels;

  /// Removed bookmarks stay as rows with deletedAt set, so a copy that
  /// still has one cannot bring it back.
  final List<Bookmark> bookmarks;
  final List<SidecarProgress> progress;
  final Map<String, String> overrides;

  /// The collections the book is in, and was taken out of (removedAt set).
  final List<CollectionBook> collections;
  final Uint8List? cover;

  bool get isEmpty =>
      analysed.isEmpty && bookmarks.isEmpty && progress.isEmpty && overrides.isEmpty && collections.isEmpty;
}

const _schema = [
  'CREATE TABLE meta (schema_version INTEGER NOT NULL, app_version TEXT, written_at INTEGER NOT NULL, '
      'content_key TEXT NOT NULL, device TEXT)',
  'CREATE TABLE book (title TEXT NOT NULL, series TEXT, number TEXT, volume INTEGER, year INTEGER, '
      'writers TEXT, artists TEXT, summary TEXT)',
  'CREATE TABLE analysed_pages (page INTEGER NOT NULL, source TEXT NOT NULL, model_ver INTEGER NOT NULL, '
      'millis INTEGER NOT NULL, analysed_at INTEGER NOT NULL, trim TEXT, PRIMARY KEY (page, source))',
  'CREATE TABLE panels (page INTEGER NOT NULL, idx INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL, '
      'w REAL NOT NULL, h REAL NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL, model_ver INTEGER NOT NULL, '
      'confidence REAL NOT NULL, shape TEXT, PRIMARY KEY (page, kind, idx, source))',
  'CREATE TABLE bookmarks (id TEXT PRIMARY KEY, page INTEGER NOT NULL, panel INTEGER, mark TEXT, note TEXT, '
      'created_at INTEGER NOT NULL, deleted_at INTEGER)',
  'CREATE TABLE progress (device TEXT PRIMARY KEY, device_name TEXT NOT NULL, page INTEGER NOT NULL, '
      'panel INTEGER, percent REAL NOT NULL, finished INTEGER NOT NULL, updated_at INTEGER NOT NULL, view_json TEXT)',
  'CREATE TABLE overrides (field TEXT PRIMARY KEY, value TEXT NOT NULL)',
  'CREATE TABLE cover (image BLOB NOT NULL)',
  'CREATE TABLE collections (name TEXT PRIMARY KEY, added_at INTEGER NOT NULL, removed_at INTEGER)',
];

DateTime _time(Object? ms) => DateTime.fromMillisecondsSinceEpoch((ms as int?) ?? 0);

/// Reads the sidecar at [path]. Null when there is none or it is not one;
/// a damaged file reads as no sidecar rather than as an error, since the
/// book opens fine without it.
SidecarData? readSidecar(String path) {
  if (!File(path).existsSync()) return null;
  Database? db;
  try {
    db = sqlite3.open(path, mode: OpenMode.readOnly);
    final meta = db.select('SELECT schema_version, content_key FROM meta LIMIT 1');
    if (meta.isEmpty) return null;
    final key = meta.first['content_key'] as String;
    final tables = {for (final r in db.select("SELECT name FROM sqlite_master WHERE type = 'table'")) r['name']};
    List<Row> rows(String table, String sql) => tables.contains(table) ? db!.select(sql) : const [];

    final book = rows('book', 'SELECT * FROM book LIMIT 1').firstOrNull;
    final cover = rows('cover', 'SELECT image FROM cover LIMIT 1').firstOrNull;
    return SidecarData(
      contentKey: key,
      schemaVersion: meta.first['schema_version'] as int,
      book: book == null
          ? null
          : SidecarBook(
              title: book['title'] as String,
              series: book['series'] as String?,
              number: book['number'] as String?,
              volume: book['volume'] as int?,
              year: book['year'] as int?,
              writers: book['writers'] as String?,
              artists: book['artists'] as String?,
              summary: book['summary'] as String?,
            ),
      analysed: [
        for (final r in rows('analysed_pages', 'SELECT * FROM analysed_pages'))
          AnalysedPage(
            contentKey: key,
            page: r['page'] as int,
            source: r['source'] as String,
            modelVer: r['model_ver'] as int,
            millis: r['millis'] as int,
            analysedAt: _time(r['analysed_at']),
            trim: r.containsKey('trim') ? r['trim'] as String? : null,
          ),
      ],
      panels: [
        for (final r in rows('panels', 'SELECT * FROM panels ORDER BY page, idx'))
          PanelRow(
            contentKey: key,
            page: r['page'] as int,
            idx: r['idx'] as int,
            x: (r['x'] as num).toDouble(),
            y: (r['y'] as num).toDouble(),
            w: (r['w'] as num).toDouble(),
            h: (r['h'] as num).toDouble(),
            kind: r['kind'] as String,
            source: r['source'] as String,
            modelVer: r['model_ver'] as int,
            confidence: (r['confidence'] as num).toDouble(),
            // Sidecars from before frame outlines have no such column.
            shape: r.containsKey('shape') ? r['shape'] as String? : null,
          ),
      ],
      bookmarks: [
        for (final r in rows('bookmarks', 'SELECT * FROM bookmarks'))
          Bookmark(
            id: r['id'] as String,
            contentKey: key,
            page: r['page'] as int,
            panel: r['panel'] as int?,
            mark: r['mark'] as String?,
            note: r['note'] as String?,
            createdAt: _time(r['created_at']),
            deletedAt: r['deleted_at'] == null ? null : _time(r['deleted_at']),
          ),
      ],
      progress: [
        for (final r in rows('progress', 'SELECT * FROM progress'))
          SidecarProgress(
            device: r['device'] as String,
            deviceName: r['device_name'] as String,
            page: r['page'] as int,
            panel: r['panel'] as int?,
            percent: (r['percent'] as num).toDouble(),
            finished: (r['finished'] as int) != 0,
            updatedAt: _time(r['updated_at']),
            viewJson: r['view_json'] as String?,
          ),
      ],
      overrides: {
        for (final r in rows('overrides', 'SELECT * FROM overrides')) r['field'] as String: r['value'] as String,
      },
      collections: [
        for (final r in rows('collections', 'SELECT * FROM collections'))
          CollectionBook(
            name: r['name'] as String,
            contentKey: key,
            addedAt: _time(r['added_at']),
            removedAt: r['removed_at'] == null ? null : _time(r['removed_at']),
          ),
      ],
      cover: cover?['image'] as Uint8List?,
    );
  } on SqliteException {
    return null;
  } finally {
    db?.close();
  }
}

/// Writes [data] to [path], merged with what is already there, so rows
/// another device put in the file since this one last read it survive
/// (see [mergeSidecars]). The new file is written beside the old one and
/// renamed over it: a reader, a copy, or a flat battery sees either the old
/// sidecar or the new one, never half of each. A sidecar with another
/// book's content key is replaced; one from a newer app is left alone.
///
/// Throws a [FileSystemException] or [SqliteException] when the folder
/// cannot be written, which callers treat as a read-only library.
void writeSidecar(String path, SidecarData data, {required String device, String? appVersion}) {
  final old = readSidecar(path);
  if (old != null && old.schemaVersion > sidecarSchemaVersion) return;
  final merged = old != null && old.contentKey == data.contentKey ? mergeSidecars(old, data) : data;

  final tmp = p.join(p.dirname(path), '.${p.basename(path)}.tmp');
  final tmpFile = File(tmp);
  if (tmpFile.existsSync()) tmpFile.deleteSync();
  final db = sqlite3.open(tmp);
  try {
    // The rename is the transaction, so no journal file beside the comics.
    db.execute('PRAGMA journal_mode = OFF');
    db.execute('PRAGMA synchronous = FULL');
    db.execute('BEGIN');
    for (final s in _schema) {
      db.execute(s);
    }
    db.execute('INSERT INTO meta VALUES (?, ?, ?, ?, ?)', [
      sidecarSchemaVersion,
      appVersion,
      DateTime.now().millisecondsSinceEpoch,
      merged.contentKey,
      device,
    ]);
    if (merged.book case final b?) {
      db.execute('INSERT INTO book VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
        b.title,
        b.series,
        b.number,
        b.volume,
        b.year,
        b.writers,
        b.artists,
        b.summary,
      ]);
    }
    final analysed = db.prepare('INSERT INTO analysed_pages VALUES (?, ?, ?, ?, ?, ?)');
    for (final a in merged.analysed) {
      analysed.execute([a.page, a.source, a.modelVer, a.millis, a.analysedAt.millisecondsSinceEpoch, a.trim]);
    }
    analysed.close();
    final panels = db.prepare('INSERT OR REPLACE INTO panels VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
    for (final r in merged.panels) {
      panels.execute([r.page, r.idx, r.x, r.y, r.w, r.h, r.kind, r.source, r.modelVer, r.confidence, r.shape]);
    }
    panels.close();
    final marks = db.prepare('INSERT INTO bookmarks VALUES (?, ?, ?, ?, ?, ?, ?)');
    for (final b in merged.bookmarks) {
      marks.execute([
        b.id,
        b.page,
        b.panel,
        b.mark,
        b.note,
        b.createdAt.millisecondsSinceEpoch,
        b.deletedAt?.millisecondsSinceEpoch,
      ]);
    }
    marks.close();
    final progress = db.prepare('INSERT INTO progress VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
    for (final r in merged.progress) {
      progress.execute([
        r.device,
        r.deviceName,
        r.page,
        r.panel,
        r.percent,
        r.finished ? 1 : 0,
        r.updatedAt.millisecondsSinceEpoch,
        r.viewJson,
      ]);
    }
    progress.close();
    for (final MapEntry(:key, :value) in merged.overrides.entries) {
      db.execute('INSERT INTO overrides VALUES (?, ?)', [key, value]);
    }
    for (final c in merged.collections) {
      db.execute('INSERT INTO collections VALUES (?, ?, ?)', [
        c.name,
        c.addedAt.millisecondsSinceEpoch,
        c.removedAt?.millisecondsSinceEpoch,
      ]);
    }
    if (merged.cover case final c?) db.execute('INSERT INTO cover VALUES (?)', [c]);
    db.execute('COMMIT');
  } catch (_) {
    db.close();
    if (tmpFile.existsSync()) tmpFile.deleteSync();
    rethrow;
  }
  db.close();
  try {
    tmpFile.renameSync(path);
  } on FileSystemException {
    tmpFile.deleteSync();
    rethrow;
  }
}

/// Combines two sidecars for the same book. The rules (design plan
/// section 7), the same whichever side is [a]:
///
/// * Newer detection wins: per page and detector, the later code generation
///   ([detectorGeneration]) keeps its rows, and the later run breaks a tie,
///   so two model files of one generation go by which ran last.
/// * Bookmarks are a union by id, and a removal wins over the bookmark. A
///   vi mark a–z points at one place: the latest one set.
/// * Each device's position is its own; the later one wins per device.
/// * Per collection, the later of adding and taking out wins.
/// * Book facts, overrides and the cover come from [b] when it has them.
SidecarData mergeSidecars(SidecarData a, SidecarData b) {
  final analysed = <(int, String), AnalysedPage>{};
  for (final r in [...a.analysed, ...b.analysed]) {
    final k = (r.page, r.source);
    final have = analysed[k];
    final gr = detectorGeneration(r.modelVer), gh = have == null ? 0 : detectorGeneration(have.modelVer);
    if (have == null || gr > gh || (gr == gh && r.analysedAt.isAfter(have.analysedAt))) {
      analysed[k] = r;
    }
  }
  // A page's rows come from the same side as the run that wins it.
  final panels = <PanelRow>[];
  for (final side in [a, b]) {
    final won = {
      for (final r in side.analysed)
        if (identical(analysed[(r.page, r.source)], r)) (r.page, r.source),
    };
    panels.addAll(side.panels.where((r) => won.contains((r.page, r.source))));
  }

  final bookmarks = <String, Bookmark>{};
  for (final m in [...a.bookmarks, ...b.bookmarks]) {
    final have = bookmarks[m.id];
    bookmarks[m.id] = have == null || (have.deletedAt == null && m.deletedAt != null) ? m : have;
  }
  final latestMark = <String, Bookmark>{};
  for (final m in bookmarks.values) {
    final mark = m.mark;
    if (mark == null || m.deletedAt != null) continue;
    final have = latestMark[mark];
    if (have == null || m.createdAt.isAfter(have.createdAt)) latestMark[mark] = m;
  }
  bookmarks.removeWhere((_, m) => m.mark != null && m.deletedAt == null && !identical(latestMark[m.mark], m));

  final progress = <String, SidecarProgress>{};
  for (final r in [...a.progress, ...b.progress]) {
    final have = progress[r.device];
    if (have == null || !r.updatedAt.isBefore(have.updatedAt)) progress[r.device] = r;
  }

  final collections = <String, CollectionBook>{};
  DateTime changed(CollectionBook c) => c.removedAt ?? c.addedAt;
  for (final c in [...a.collections, ...b.collections]) {
    final have = collections[c.name];
    if (have == null || changed(c).isAfter(changed(have))) collections[c.name] = c;
  }

  return SidecarData(
    contentKey: b.contentKey,
    book: b.book ?? a.book,
    analysed: analysed.values.toList(),
    panels: panels,
    bookmarks: bookmarks.values.toList(),
    progress: progress.values.toList(),
    overrides: {...a.overrides, ...b.overrides},
    collections: collections.values.toList(),
    cover: b.cover ?? a.cover,
  );
}

/// Finds the sidecar of the book at [bookPath] when the book was renamed
/// without it: a `.crdb` in the same folder whose own book is gone and
/// whose content key is [contentKey]. Renames it to go with the book and
/// returns true. The comic is never touched.
///
/// With [sidecar], the book's sidecar lives there instead of beside it (a
/// sidecar folder laid out like the library), and the orphan is looked for
/// beside that: a sidecar there belongs to the book of the same name in
/// [bookPath]'s folder.
bool relinkOrphan(String bookPath, String contentKey, {String? sidecar}) {
  final want = sidecar ?? sidecarPath(bookPath, folder: false);
  if (File(want).existsSync()) return false;
  final List<FileSystemEntity> entries;
  try {
    entries = Directory(p.dirname(want)).listSync(followLinks: false);
  } on FileSystemException {
    return false;
  }
  for (final e in entries) {
    final name = p.basename(e.path);
    if (e is! File || !name.endsWith(sidecarExtension) || name == folderSidecarName) continue;
    final book = p.join(p.dirname(bookPath), name.substring(0, name.length - sidecarExtension.length));
    if (FileSystemEntity.typeSync(book) != FileSystemEntityType.notFound) continue; // Not an orphan.
    if (readSidecar(e.path)?.contentKey != contentKey) continue;
    try {
      e.renameSync(want);
      return true;
    } on FileSystemException {
      return false;
    }
  }
  return false;
}

/// Moves the sidecar at [from] to [to], making [to]'s folder. A rename when
/// both are on one disk, a copy and a delete otherwise. When [to] holds the
/// same book's sidecar already, the two are merged into [to] (written as
/// [device]). Leaves [from] alone when [to] cannot be written, belongs to
/// another book or comes from a newer app; returns whether it moved.
bool moveSidecar(String from, String to, {required String device, String? appVersion}) {
  final src = File(from);
  if (!src.existsSync() || p.equals(from, to)) return false;
  try {
    if (File(to).existsSync()) {
      final there = readSidecar(to);
      final here = readSidecar(from);
      if (here == null || there == null || here.contentKey != there.contentKey) return false;
      if (here.schemaVersion > sidecarSchemaVersion || there.schemaVersion > sidecarSchemaVersion) return false;
      writeSidecar(to, here, device: device, appVersion: appVersion);
      _deleteQuietly(src);
      return true;
    }
    Directory(p.dirname(to)).createSync(recursive: true);
    try {
      src.renameSync(to);
    } on FileSystemException {
      final tmp = p.join(p.dirname(to), '.${p.basename(to)}.tmp');
      src.copySync(tmp);
      File(tmp).renameSync(to);
      _deleteQuietly(src);
    }
    return true;
  } on FileSystemException {
    return false;
  } on SqliteException {
    return false;
  }
}

void _deleteQuietly(File f) {
  try {
    f.deleteSync();
  } on FileSystemException {
    // A read-only folder: the copy is the one read first from now on.
  }
}
