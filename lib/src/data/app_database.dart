import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// The app's index (design plan section 6). It is a cache: what a comic
/// knows about itself lives in its sidecar (section 7, M8), and deleting
/// this database loses nothing that a rescan cannot rebuild.
///
/// Books are keyed by content key (SHA-1 of the first 64 KiB plus the file
/// size), so progress follows a file that is renamed or copied.
class Books extends Table {
  TextColumn get contentKey => text()();
  TextColumn get title => text()();
  IntColumn get seriesId => integer().nullable().references(SeriesTable, #id)();
  TextColumn get number => text().nullable()();
  IntColumn get pageCount => integer()();
  TextColumn get format => text()(); // zip, pdf, folder
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {contentKey};
}

/// The same book can live at many paths, across roots.
@DataClassName('BookFile')
class Files extends Table {
  TextColumn get contentKey => text().references(Books, #contentKey)();
  IntColumn get rootId => integer()();
  TextColumn get relPath => text()();
  IntColumn get size => integer()();
  DateTimeColumn get mtime => dateTime()();

  @override
  Set<Column> get primaryKey => {rootId, relPath};
}

@DataClassName('Series')
class SeriesTable extends Table {
  @override
  String get tableName => 'series';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get sortName => text()();
  BoolColumn get rtl => boolean().withDefault(const Constant(false))();
}

class Progress extends Table {
  TextColumn get contentKey => text()();
  IntColumn get page => integer()();
  IntColumn get panel => integer().nullable()();
  RealColumn get percent => real()();
  BoolColumn get finished => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {contentKey};
}

/// UUID ids, so two devices that never talk cannot collide.
class Bookmarks extends Table {
  TextColumn get id => text()();
  TextColumn get contentKey => text()();
  IntColumn get page => integer()();
  IntColumn get panel => integer().nullable()();
  TextColumn get mark => text().nullable()(); // vi register a-z, null for anonymous
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Detected regions, normalised to the page. `source` and `modelVer` let a
/// better detector replace only its own rows. `idx` is the reading order,
/// left to right; right-to-left books reorder when they load.
@DataClassName('PanelRow')
class Panels extends Table {
  TextColumn get contentKey => text()();
  IntColumn get page => integer()();
  IntColumn get idx => integer()();
  RealColumn get x => real()();
  RealColumn get y => real()();
  RealColumn get w => real()();
  RealColumn get h => real()();
  TextColumn get kind => text()(); // frame, balloon, caption
  TextColumn get source => text()(); // classicCv, model, manual
  IntColumn get modelVer => integer()();
  RealColumn get confidence => real()();

  @override
  Set<Column> get primaryKey => {contentKey, page, kind, idx, source};
}

/// Which pages a detector has looked at, and at which version, so a page
/// where it found nothing is not analysed again on every visit.
class AnalysedPages extends Table {
  TextColumn get contentKey => text()();
  IntColumn get page => integer()();
  TextColumn get source => text()(); // classicCv, model
  IntColumn get modelVer => integer()();
  IntColumn get millis => integer()(); // detection time, for tuning
  DateTimeColumn get analysedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {contentKey, page, source};
}

/// Hand edits to metadata, kept apart so a rescan never clobbers them.
class Overrides extends Table {
  TextColumn get contentKey => text()();
  TextColumn get field => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {contentKey, field};
}

class ReadLog extends Table {
  TextColumn get contentKey => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime()();
  IntColumn get pages => integer()();
}

@DriftDatabase(tables: [Books, Files, SeriesTable, Progress, Bookmarks, Panels, AnalysedPages, Overrides, ReadLog])
class AppDatabase extends _$AppDatabase {
  /// Lives in the app support directory (`~/.local/share/org.snonux.comicredr`
  /// on Linux), not in Documents, which may not exist.
  AppDatabase([QueryExecutor? executor])
    : super(
        executor ??
            driftDatabase(
              name: 'comicredr',
              native: const DriftNativeOptions(databaseDirectory: getApplicationSupportDirectory),
            ),
      );

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(analysedPages); // M4: guided view
    },
  );
}
