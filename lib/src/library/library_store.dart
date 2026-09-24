import 'package:comic_formats/comic_formats.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../data/app_database.dart';
import '../data/meta_edits.dart';
import '../data/panel_store.dart' show newId;

/// One book as the library shows it: what it is, where it is, and how far
/// through it you are.
class LibraryBook {
  const LibraryBook({
    required this.key,
    required this.series,
    required this.seriesId,
    required this.pageCount,
    required this.format,
    required this.path,
    required this.addedAt,
    this.number,
    this.volume,
    this.year,
    this.issueTitle,
    this.writers = const [],
    this.artists = const [],
    this.summary,
    this.page,
    this.percent,
    this.finished = false,
    this.readAt,
    this.collections = const [],
    this.fromFile = const {},
  });

  final String key;
  final String series;
  final int seriesId;
  final String? number;
  final int? volume;
  final int? year;
  final String? issueTitle;
  final List<String> writers;
  final List<String> artists;
  final String? summary;
  final int pageCount;
  final String format;

  /// Where the book is on disk: the first of its files.
  final String path;
  final DateTime addedAt;

  /// The saved page, null for a book never opened.
  final int? page;
  final double? percent;
  final bool finished;
  final DateTime? readAt;

  /// The hand-made collections the book is in, by name.
  final List<String> collections;

  /// The facts edited by hand, each with what the file itself says (null
  /// where it says nothing). The edited values are the ones above.
  final Map<MetaField, String?> fromFile;

  /// The book's value of [f] as the edit dialog shows it.
  String? fact(MetaField f) => switch (f) {
    MetaField.series => series,
    MetaField.number => number,
    MetaField.title => issueTitle,
    MetaField.volume => volume?.toString(),
    MetaField.year => year?.toString(),
    MetaField.writers => writers.isEmpty ? null : writers.join(', '),
    MetaField.artists => artists.isEmpty ? null : artists.join(', '),
    MetaField.summary => summary,
  };

  /// `Daredevil #181`, or the series alone for a book without a number.
  String get name => number == null ? series : '$series #$number';

  /// A second line for the cover: the issue's own title, or its year.
  String? get subtitle => issueTitle ?? year?.toString();

  /// Opened at least once: a reading position is saved from the first open.
  bool get started => page != null;
  bool get inProgress => started && !finished;

  /// Every word of [query] appears in the name, title, creators, year or
  /// file name, ignoring case.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return true;
    final hay = [
      name,
      issueTitle,
      year,
      ...writers,
      ...artists,
      p.basename(path),
    ].whereType<Object>().join(' ').toLowerCase();
    return words.every(hay.contains);
  }

  /// Series order: volume, then issue number, then anything else by name.
  static int seriesOrder(LibraryBook a, LibraryBook b) {
    final v = (a.volume ?? 0).compareTo(b.volume ?? 0);
    if (v != 0) return v;
    final na = issueOrder(a.number), nb = issueOrder(b.number);
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
    if ((na == null) != (nb == null)) return na == null ? 1 : -1;
    return naturalCompare(p.basename(a.path), p.basename(b.path));
  }
}

/// A series as the library shows it: its books in reading order.
class LibrarySeries {
  const LibrarySeries(this.id, this.name, this.books);

  final int id;
  final String name;
  final List<LibraryBook> books;

  int get read => books.where((b) => b.finished).length;

  /// The book to go on with: the first unfinished one.
  LibraryBook get next => books.firstWhere((b) => !b.finished, orElse: () => books.first);

  bool matches(String query) => books.any((b) => b.matches(query));

  /// Groups [books] by series, series in name order, books in series order.
  static List<LibrarySeries> group(List<LibraryBook> books) {
    final by = <int, List<LibraryBook>>{};
    for (final b in books) {
      by.putIfAbsent(b.seriesId, () => []).add(b);
    }
    return [
      for (final MapEntry(key: id, value: list) in by.entries)
        LibrarySeries(id, _name(list), list..sort(LibraryBook.seriesOrder)),
    ]..sort((a, b) => naturalCompare(seriesKey(a.name), seriesKey(b.name)));
  }
}

/// A series' name: as typed where a book's series was edited by hand, so
/// renaming `spirit` to `The Spirit` shows, else as the first book has it.
String _name(List<LibraryBook> books) =>
    books.where((b) => b.fromFile.containsKey(MetaField.series)).firstOrNull?.series ?? books.first.series;

/// The hand-made collections among [books], as groups the library shows
/// like series: collections in name order, books in series order. Ids are
/// negative, so they never meet a series id.
List<LibrarySeries> collectionGroups(List<LibraryBook> books) {
  final by = <String, List<LibraryBook>>{};
  for (final b in books) {
    for (final c in b.collections) {
      by.putIfAbsent(c, () => []).add(b);
    }
  }
  final names = by.keys.toList()..sort(naturalCompare);
  int bySeries(LibraryBook a, LibraryBook b) {
    final s = naturalCompare(seriesKey(a.series), seriesKey(b.series));
    return s != 0 ? s : LibraryBook.seriesOrder(a, b);
  }

  return [for (final (i, n) in names.indexed) LibrarySeries(-1 - i, n, by[n]!..sort(bySeries))];
}

/// A folder in the Folders tab: a library folder or one somewhere under it,
/// with every book beneath it at any depth. A folder of page images is a
/// book, never a folder here.
class LibraryFolder {
  const LibraryFolder(this.path, this.books, {this.root});

  final String path;

  /// Every book under the folder, in file order.
  final List<LibraryBook> books;

  /// The library folder itself, for one added with `A`.
  final RootInfo? root;

  String get name => p.basename(path);

  bool matches(String query) => name.toLowerCase().contains(query.toLowerCase()) || books.any((b) => b.matches(query));

  /// What is directly in [dir]: its sub-folders that hold books, in name
  /// order, then its books, in file-name order.
  static ({List<LibraryFolder> folders, List<LibraryBook> books}) children(String dir, List<LibraryBook> all) {
    final sub = <String, List<LibraryBook>>{};
    final here = <LibraryBook>[];
    for (final b in all) {
      if (!p.isWithin(dir, b.path)) continue;
      final parts = p.split(p.relative(b.path, from: dir));
      if (parts.length == 1) {
        here.add(b);
      } else {
        sub.putIfAbsent(p.join(dir, parts.first), () => []).add(b);
      }
    }
    final names = sub.keys.toList()..sort((a, b) => naturalCompare(p.basename(a), p.basename(b)));
    return (folders: [for (final d in names) LibraryFolder(d, sub[d]!..sort(fileOrder))], books: here..sort(fileOrder));
  }

  /// The library folders, each with its books.
  static List<LibraryFolder> roots(List<RootInfo> roots, List<LibraryBook> all) => [
    for (final r in roots)
      LibraryFolder(r.path, all.where((b) => p.isWithin(r.path, b.path)).toList()..sort(fileOrder), root: r),
  ];

  /// File order: by path, numbers compared as numbers.
  static int fileOrder(LibraryBook a, LibraryBook b) => naturalCompare(a.path, b.path);
}

/// A watched folder, with how many books were found in it.
class RootInfo {
  const RootInfo(this.id, this.path, this.books);

  final int id;
  final String path;
  final int books;
}

/// A bookmark or a vi mark, for the reader's bookmark list, the book's
/// detail page and the library's Bookmarks tab.
class BookmarkInfo {
  const BookmarkInfo({
    required this.id,
    this.contentKey = '',
    required this.page,
    this.panel,
    this.mark,
    this.note,
    required this.createdAt,
  });

  factory BookmarkInfo.of(Bookmark r) => BookmarkInfo(
    id: r.id,
    contentKey: r.contentKey,
    page: r.page,
    panel: r.panel,
    mark: r.mark,
    note: r.note,
    createdAt: r.createdAt,
  );

  final String id;
  final String contentKey;
  final int page;

  /// The panel in reading order; null for the page as a whole.
  final int? panel;

  /// The vi register a–z, null for a bookmark.
  final String? mark;

  /// A short note of the reader's own, null when there is none.
  final String? note;
  final DateTime createdAt;

  /// Reading order in the book: by page, a whole-page bookmark first.
  static int order(BookmarkInfo a, BookmarkInfo b) =>
      a.page != b.page ? a.page.compareTo(b.page) : (a.panel ?? -1).compareTo(b.panel ?? -1);

  @override
  bool operator ==(Object other) =>
      other is BookmarkInfo &&
      other.id == id &&
      other.page == page &&
      other.panel == panel &&
      other.mark == mark &&
      other.note == note;

  @override
  int get hashCode => Object.hash(id, page, panel, mark, note);
}

/// The library's side of the app index: roots, books, series, and the
/// queries the library screens watch. The index is a cache; everything here
/// can be rebuilt by a rescan.
class LibraryStore {
  LibraryStore(this.db);

  final AppDatabase db;

  Future<int> addRoot(String path) async {
    path = p.normalize(p.absolute(path));
    final existing = await (db.select(db.roots)..where((r) => r.path.equals(path))).getSingleOrNull();
    if (existing != null) return existing.id;
    return db.into(db.roots).insert(RootsCompanion.insert(path: path));
  }

  /// Forgets [id] and the books found only under it. Reading positions and
  /// bookmarks stay, keyed on content, for when the books come back.
  Future<void> removeRoot(int id) => db.transaction(() async {
    await (db.delete(db.files)..where((f) => f.rootId.equals(id))).go();
    await (db.delete(db.roots)..where((r) => r.id.equals(id))).go();
    await removeOrphans();
  });

  Future<List<LibraryRoot>> roots() => db.select(db.roots).get();

  Stream<List<RootInfo>> watchRoots() => _live(
    {db.roots, db.files},
    () => db
        .customSelect(
          'SELECT r.id, r.path, (SELECT COUNT(DISTINCT content_key) FROM files f WHERE f.root_id = r.id) AS n '
          'FROM roots r ORDER BY r.path',
        )
        .get()
        .then((rows) => [for (final r in rows) RootInfo(r.read<int>('id'), r.read<String>('path'), r.read<int>('n'))]),
  );

  /// [query] now and again whenever one of [tables] changes. Drift's own
  /// watch() does the same, but leaves a timer behind when it is cancelled,
  /// which widget tests refuse.
  Stream<T> _live<T>(Set<TableInfo> tables, Future<T> Function() query) async* {
    yield await query();
    await for (final _ in db.tableUpdates(TableUpdateQuery.onAllTables(tables))) {
      yield await query();
    }
  }

  /// What the index knows about each file under [rootId]: size and mtime,
  /// keyed on the path relative to the root.
  Future<Map<String, BookFile>> filesUnder(int rootId) async {
    final rows = await (db.select(db.files)..where((f) => f.rootId.equals(rootId))).get();
    return {for (final r in rows) r.relPath: r};
  }

  Future<void> forgetFiles(int rootId, Iterable<String> relPaths) async {
    final list = relPaths.toList();
    if (list.isEmpty) return;
    await (db.delete(db.files)..where((f) => f.rootId.equals(rootId) & f.relPath.isIn(list))).go();
  }

  /// The book at [path] was deleted from disk: forgets that file, and when
  /// no other copy of [contentKey] is left, everything kept about the book
  /// (position, bookmarks, panels, edits, collections, reading history).
  /// True when that was the last copy.
  Future<bool> forgetDeleted(String path, String contentKey) => db.transaction(() async {
    final rows = await db
        .customSelect(
          'SELECT f.root_id, f.rel_path, r.path AS root FROM files f JOIN roots r ON r.id = f.root_id '
          'WHERE f.content_key = ?',
          variables: [Variable(contentKey)],
        )
        .get();
    var left = 0;
    for (final r in rows) {
      final rel = r.read<String>('rel_path');
      final at = rel.isEmpty ? r.read<String>('root') : p.join(r.read<String>('root'), rel);
      if (p.equals(at, path)) {
        await forgetFiles(r.read<int>('root_id'), [rel]);
      } else {
        left++;
      }
    }
    if (left > 0) return false;
    final key = contentKey;
    await (db.delete(db.analysedPages)..where((r) => r.contentKey.equals(key))).go();
    await (db.delete(db.panels)..where((r) => r.contentKey.equals(key))).go();
    await (db.delete(db.bookmarks)..where((r) => r.contentKey.equals(key))).go();
    await (db.delete(db.progress)..where((r) => r.contentKey.equals(key))).go();
    await (db.delete(db.readLog)..where((r) => r.contentKey.equals(key))).go();
    await (db.delete(db.overrides)..where((r) => r.contentKey.equals(key))).go();
    await (db.delete(db.collectionBooks)..where((r) => r.contentKey.equals(key))).go();
    await removeOrphans();
    return true;
  });

  /// Books no file points at any more.
  Future<void> removeOrphans() =>
      db.customStatement('DELETE FROM books WHERE content_key NOT IN (SELECT content_key FROM files)');

  /// Records [info] as the book at [relPath] under [rootId].
  Future<void> putBook(int rootId, String relPath, int size, DateTime mtime, BookInfo info) => db.transaction(() async {
    final meta = info.meta;
    final seriesName = meta.series ?? p.basenameWithoutExtension(relPath);
    final seriesId = await _seriesId(seriesName);
    await db
        .into(db.books)
        .insertOnConflictUpdate(
          BooksCompanion.insert(
            contentKey: info.contentKey,
            title: meta.number == null ? seriesName : '$seriesName #${meta.number}',
            seriesId: Value(seriesId),
            number: Value(meta.number),
            pageCount: info.pageCount,
            format: info.kind.name,
            issueTitle: Value(meta.title),
            volume: Value(meta.volume),
            year: Value(meta.year),
            writers: Value(meta.writers.isEmpty ? null : meta.writers.join(', ')),
            artists: Value(meta.artists.isEmpty ? null : meta.artists.join(', ')),
            summary: Value(meta.summary),
          ),
        );
    await db
        .into(db.files)
        .insertOnConflictUpdate(
          FilesCompanion.insert(
            contentKey: info.contentKey,
            rootId: rootId,
            relPath: relPath,
            size: size,
            mtime: mtime,
          ),
        );
  });

  /// Books group by [seriesKey], so `The Spirit` and `spirit` are one series
  /// under the first name seen.
  Future<int> _seriesId(String name) async {
    final key = seriesKey(name);
    // The first: two edits racing can each have made one.
    final existing =
        await (db.select(db.seriesTable)
              ..where((s) => s.sortName.equals(key))
              ..orderBy([(s) => OrderingTerm(expression: s.id)])
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return existing.id;
    return db.into(db.seriesTable).insert(SeriesTableCompanion.insert(name: name, sortName: key));
  }

  static const _booksSql = '''
SELECT b.content_key, b.number, b.page_count, b.format, b.added_at, b.issue_title, b.volume, b.year,
       b.writers, b.artists, b.summary, b.series_id, s.name AS series_name,
       (SELECT r.path || '/' || f.rel_path FROM files f JOIN roots r ON r.id = f.root_id
         WHERE f.content_key = b.content_key ORDER BY r.id, f.rel_path LIMIT 1) AS path,
       pr.page AS p_page, pr.percent AS p_percent, pr.finished AS p_finished, pr.updated_at AS p_updated,
       (SELECT group_concat(c.name, char(31)) FROM collection_books c
         WHERE c.content_key = b.content_key AND c.removed_at IS NULL) AS collections
FROM books b
JOIN series s ON s.id = b.series_id
LEFT JOIN progress pr ON pr.content_key = b.content_key
WHERE EXISTS (SELECT 1 FROM files f WHERE f.content_key = b.content_key)
''';

  /// Every book in the library, live: a scan adding a book or a page turn
  /// saving progress updates whoever watches.
  Stream<List<LibraryBook>> watchBooks() =>
      _live({db.books, db.seriesTable, db.files, db.roots, db.progress, db.collectionBooks, db.overrides}, books);

  Future<List<LibraryBook>> books() async {
    final rows = await db.customSelect(_booksSql).get();
    final edits = <String, Map<MetaField, String?>>{};
    for (final o in await db.select(db.overrides).get()) {
      final active = activeEdits({o.field: o.value});
      if (active.isNotEmpty) edits.putIfAbsent(o.contentKey, () => {}).addAll(active);
    }
    // An edited series groups with the series of that name, made here when
    // the edit came in from another device's sidecar.
    final names = {
      for (final e in edits.values)
        if (e[MetaField.series]?.trim() case final s? when s.isNotEmpty) seriesKey(s): s,
    };
    final ids = <String, int>{};
    for (final MapEntry(:key, :value) in names.entries) {
      ids[key] = await _seriesId(value);
    }
    return [for (final r in rows) _book(r, edits[r.read<String>('content_key')] ?? const {}, ids)];
  }

  /// Saves hand edits to the book [contentKey]'s facts. They stay in the
  /// index and the book's sidecar, never in the comic file, and win over
  /// what the file says until undone (MetaEdit.undo).
  Future<void> editBook(String contentKey, Map<MetaField, MetaEdit> edits) => db.transaction(() async {
    for (final MapEntry(key: f, value: e) in edits.entries) {
      if (f == MetaField.series && !e.fromFile && e.value != null) await _seriesId(e.value!.trim());
      await db
          .into(db.overrides)
          .insertOnConflictUpdate(OverridesCompanion.insert(contentKey: contentKey, field: f.name, value: e.encode()));
    }
  });

  /// The hand edits in effect for [contentKey], for the reader's title.
  Future<Map<MetaField, String?>> edits(String contentKey) async => activeEdits({
    for (final o in await (db.select(db.overrides)..where((o) => o.contentKey.equals(contentKey))).get())
      o.field: o.value,
  });

  LibraryBook _book(QueryRow r, Map<MetaField, String?> edits, Map<String, int> seriesIds) {
    List<String> list(String col) => r.readNullable<String>(col)?.split(', ') ?? const [];
    DateTime? time(String col) {
      final v = r.readNullable<int>(col);
      return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v * 1000);
    }

    final file = {
      MetaField.series: r.read<String>('series_name'),
      MetaField.number: r.readNullable<String>('number'),
      MetaField.title: r.readNullable<String>('issue_title'),
      MetaField.volume: r.readNullable<int>('volume')?.toString(),
      MetaField.year: r.readNullable<int>('year')?.toString(),
      MetaField.writers: r.readNullable<String>('writers'),
      MetaField.artists: r.readNullable<String>('artists'),
      MetaField.summary: r.readNullable<String>('summary'),
    };
    String? get(MetaField f) {
      if (!edits.containsKey(f)) return file[f];
      final v = edits[f]?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    // A series cannot be blank: clearing it shows the file's again.
    final series = get(MetaField.series) ?? file[MetaField.series]!;
    return LibraryBook(
      key: r.read<String>('content_key'),
      series: series,
      seriesId: seriesIds[seriesKey(series)] ?? r.read<int>('series_id'),
      number: get(MetaField.number),
      volume: int.tryParse(get(MetaField.volume) ?? ''),
      year: int.tryParse(get(MetaField.year) ?? ''),
      issueTitle: get(MetaField.title),
      writers: edits.containsKey(MetaField.writers) ? splitPeople(get(MetaField.writers)) : list('writers'),
      artists: edits.containsKey(MetaField.artists) ? splitPeople(get(MetaField.artists)) : list('artists'),
      summary: get(MetaField.summary),
      fromFile: {for (final f in edits.keys) f: file[f]},
      pageCount: r.read<int>('page_count'),
      format: r.read<String>('format'),
      path: p.normalize(r.read<String>('path')),
      addedAt: time('added_at') ?? DateTime(2000),
      page: r.readNullable<int>('p_page'),
      percent: r.readNullable<double>('p_percent'),
      finished: (r.readNullable<int>('p_finished') ?? 0) != 0,
      readAt: time('p_updated'),
      collections: (r.readNullable<String>('collections')?.split('\x1f') ?? <String>[])..sort(naturalCompare),
    );
  }

  /// The book before or after [contentKey] in its series, for `]` and `[`.
  /// Null when the book is not in the library or is alone in its series;
  /// otherwise a record whose path is null at either end of the series.
  Future<({String? path})?> seriesNeighbour(String contentKey, {required bool next}) async {
    final all = await books();
    final me = all.where((b) => b.key == contentKey).firstOrNull;
    if (me == null) return null;
    final series = all.where((b) => b.seriesId == me.seriesId).toList()..sort(LibraryBook.seriesOrder);
    if (series.length < 2) return null;
    final i = series.indexWhere((b) => b.key == contentKey) + (next ? 1 : -1);
    return (path: i >= 0 && i < series.length ? series[i].path : null);
  }

  Stream<List<BookmarkInfo>> watchBookmarks(String contentKey) =>
      _live({db.bookmarks}, () => _bookmarks((b) => b.contentKey.equals(contentKey)));

  /// Every book's bookmarks and marks, for the library's Bookmarks tab.
  Stream<List<BookmarkInfo>> watchAllBookmarks() => _live({db.bookmarks}, () => _bookmarks(null));

  Future<List<BookmarkInfo>> _bookmarks(Expression<bool> Function($BookmarksTable)? where) async {
    final rows = await (db.select(
      db.bookmarks,
    )..where((b) => b.deletedAt.isNull() & (where?.call(b) ?? const Constant(true)))).get();
    return [for (final r in rows) BookmarkInfo.of(r)]..sort(BookmarkInfo.order);
  }

  /// Removes a bookmark. The row stays with a removal time, so the sidecar
  /// can tell other copies it is gone.
  Future<void> deleteBookmark(String id) => deleteBookmarks([id]);

  Future<void> deleteBookmarks(Iterable<String> ids) => (db.update(
    db.bookmarks,
  )..where((b) => b.id.isIn(ids) & b.deletedAt.isNull())).write(BookmarksCompanion(deletedAt: Value(DateTime.now())));

  /// Gives bookmark [id] the note [note]; empty takes the note off. The
  /// bookmark is replaced by a new one with the same place and time, and
  /// the old one removed, so the sidecar merge, a union by id where a
  /// removal wins, carries the change to every copy with no edit times.
  /// Returns the new id.
  Future<String?> setNote(String id, String note) => db.transaction(() async {
    final old = await (db.select(db.bookmarks)..where((b) => b.id.equals(id))).getSingleOrNull();
    if (old == null || old.deletedAt != null) return null;
    final text = note.trim();
    final fresh = old.copyWith(id: newId(), note: Value(text.isEmpty ? null : text));
    await deleteBookmark(id);
    await db.into(db.bookmarks).insert(fresh);
    return fresh.id;
  });

  /// Puts the book [contentKey] in the collection [name], making the
  /// collection if it is new.
  Future<void> addToCollection(String contentKey, String name) => db
      .into(db.collectionBooks)
      .insertOnConflictUpdate(
        CollectionBooksCompanion.insert(
          name: name.trim(),
          contentKey: contentKey,
          addedAt: DateTime.now(),
          removedAt: const Value(null),
        ),
      );

  /// Takes the book out of [name]. The row stays with the time, for the
  /// sidecar; a collection with no books left is gone from the library.
  Future<void> removeFromCollection(String contentKey, String name) =>
      (db.update(db.collectionBooks)..where((c) => c.contentKey.equals(contentKey) & c.name.equals(name))).write(
        CollectionBooksCompanion(removedAt: Value(DateTime.now())),
      );

  /// Sittings with books, newest first, for the History tab.
  Stream<List<HistoryEntry>> watchHistory({int limit = 300}) => _live(
    {db.readLog},
    () =>
        (db.select(db.readLog)
              ..orderBy([(r) => OrderingTerm(expression: r.startedAt, mode: OrderingMode.desc)])
              ..limit(limit))
            .get()
            .then(
              (rows) => [
                for (final r in rows)
                  HistoryEntry(key: r.contentKey, startedAt: r.startedAt, endedAt: r.endedAt, pages: r.pages),
              ],
            ),
  );
}

/// One sitting with a book, for the History tab.
class HistoryEntry {
  const HistoryEntry({required this.key, required this.startedAt, required this.endedAt, required this.pages});

  final String key;
  final DateTime startedAt;
  final DateTime endedAt;

  /// Pages shown, each counted once.
  final int pages;

  Duration get duration => endedAt.difference(startedAt);
}
