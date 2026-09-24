import 'package:comic_formats/comic_formats.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../data/app_database.dart';

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
        LibrarySeries(id, list.first.series, list..sort(LibraryBook.seriesOrder)),
    ]..sort((a, b) => naturalCompare(seriesKey(a.name), seriesKey(b.name)));
  }
}

/// A watched folder, with how many books were found in it.
class RootInfo {
  const RootInfo(this.id, this.path, this.books);

  final int id;
  final String path;
  final int books;
}

/// A bookmark or a vi mark, for the book's detail page.
class BookmarkInfo {
  const BookmarkInfo({required this.id, required this.page, this.panel, this.mark, required this.createdAt});

  final String id;
  final int page;
  final int? panel;
  final String? mark;
  final DateTime createdAt;
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
    final existing = await (db.select(db.seriesTable)..where((s) => s.sortName.equals(key))).getSingleOrNull();
    if (existing != null) return existing.id;
    return db.into(db.seriesTable).insert(SeriesTableCompanion.insert(name: name, sortName: key));
  }

  static const _booksSql = '''
SELECT b.content_key, b.number, b.page_count, b.format, b.added_at, b.issue_title, b.volume, b.year,
       b.writers, b.artists, b.summary, b.series_id, s.name AS series_name,
       (SELECT r.path || '/' || f.rel_path FROM files f JOIN roots r ON r.id = f.root_id
         WHERE f.content_key = b.content_key ORDER BY r.id, f.rel_path LIMIT 1) AS path,
       pr.page AS p_page, pr.percent AS p_percent, pr.finished AS p_finished, pr.updated_at AS p_updated
FROM books b
JOIN series s ON s.id = b.series_id
LEFT JOIN progress pr ON pr.content_key = b.content_key
WHERE EXISTS (SELECT 1 FROM files f WHERE f.content_key = b.content_key)
''';

  /// Every book in the library, live: a scan adding a book or a page turn
  /// saving progress updates whoever watches.
  Stream<List<LibraryBook>> watchBooks() => _live({db.books, db.seriesTable, db.files, db.roots, db.progress}, books);

  Future<List<LibraryBook>> books() => db.customSelect(_booksSql).get().then((rows) => rows.map(_book).toList());

  LibraryBook _book(QueryRow r) {
    List<String> list(String col) => r.readNullable<String>(col)?.split(', ') ?? const [];
    DateTime? time(String col) {
      final v = r.readNullable<int>(col);
      return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v * 1000);
    }

    return LibraryBook(
      key: r.read<String>('content_key'),
      series: r.read<String>('series_name'),
      seriesId: r.read<int>('series_id'),
      number: r.readNullable<String>('number'),
      volume: r.readNullable<int>('volume'),
      year: r.readNullable<int>('year'),
      issueTitle: r.readNullable<String>('issue_title'),
      writers: list('writers'),
      artists: list('artists'),
      summary: r.readNullable<String>('summary'),
      pageCount: r.read<int>('page_count'),
      format: r.read<String>('format'),
      path: p.normalize(r.read<String>('path')),
      addedAt: time('added_at') ?? DateTime(2000),
      page: r.readNullable<int>('p_page'),
      percent: r.readNullable<double>('p_percent'),
      finished: (r.readNullable<int>('p_finished') ?? 0) != 0,
      readAt: time('p_updated'),
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

  Stream<List<BookmarkInfo>> watchBookmarks(String contentKey) => _live(
    {db.bookmarks},
    () =>
        (db.select(db.bookmarks)
              ..where((b) => b.contentKey.equals(contentKey) & b.deletedAt.isNull())
              ..orderBy([(b) => OrderingTerm(expression: b.page), (b) => OrderingTerm(expression: b.panel)]))
            .get()
            .then(
              (rows) => [
                for (final r in rows)
                  BookmarkInfo(id: r.id, page: r.page, panel: r.panel, mark: r.mark, createdAt: r.createdAt),
              ],
            ),
  );

  /// Removes a bookmark. The row stays with a removal time, so the sidecar
  /// can tell other copies it is gone.
  Future<void> deleteBookmark(String id) => (db.update(
    db.bookmarks,
  )..where((b) => b.id.equals(id))).write(BookmarksCompanion(deletedAt: Value(DateTime.now())));
}
