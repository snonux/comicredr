import 'dart:convert';

import 'package:drift/drift.dart';

import '../version.dart' as version;
import 'app_database.dart';
import 'data_dirs.dart';
import 'settings_store.dart';
import 'sidecar.dart';

/// The settings file's format. A reader takes files of this format and
/// older; a newer one is refused, since it may mean something else.
const settingsFileFormat = 1;

/// What the `kind` field of a settings file says.
const settingsFileKind = 'settings';

/// Why a file could not be imported, in words for the person.
class SettingsFileException implements Exception {
  const SettingsFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Everything about this install that is not a comic, as one JSON file
/// (Settings → Export settings), so a wiped or new install gets it back
/// with Import settings: the settings, the library folders, `keys.toml`,
/// and per comic the position, bookmarks and marks, collections, metadata
/// edits and reading history.
///
/// Comics are named by content key, as the index and the sidecars name
/// them, so positions and bookmarks follow a comic that is somewhere else
/// on the new install. Library folders and the sidecar folder are paths:
/// the ones that do not exist here are left out when importing.
///
/// Left out: the index's facts about each comic, covers, thumbnails and
/// detected panels (a rescan and the sidecars bring those back, and panels
/// run to megabytes), installed models (files of their own, tens of MB),
/// and this install's device id, which must stay its own so the sidecars
/// keep telling it from the laptop or the phone the file came from.
class SettingsFile {
  SettingsFile({
    this.settings = const {},
    this.keysToml,
    this.folders = const [],
    this.positions = const [],
    this.bookmarks = const [],
    this.collections = const [],
    this.edits = const [],
    this.history = const [],
    this.appVersion,
    this.exportedAt,
    this.skipped = 0,
  });

  /// The settings, by SettingsStore key, each a bool or a string.
  final Map<String, Object> settings;

  /// The text of `keys.toml`, or null when there was none.
  final String? keysToml;

  /// The library folders.
  final List<String> folders;
  final List<ProgressData> positions;

  /// Bookmarks and marks, removed ones included, so a removal travels.
  final List<Bookmark> bookmarks;

  /// Books in collections, and taken out of them (Favourites is one).
  final List<CollectionBook> collections;
  final List<Override> edits;
  final List<ReadLogData> history;

  /// The ComicRedr that wrote the file, and when.
  final String? appVersion;
  final DateTime? exportedAt;

  /// Entries a read file had that this version does not know or could not
  /// read: unknown settings, broken rows. They are left out.
  final int skipped;

  /// Reads what [db] holds, with [keysToml] the keys file's text.
  static Future<SettingsFile> gather(AppDatabase db, {String? keysToml, DateTime? now}) async {
    final rows = await (db.select(db.settings)..where((s) => s.key.isIn(SettingsStore.backedUp.keys))).get();
    final settings = <String, Object>{};
    for (final r in rows) {
      final v = _decode(r.value);
      if (_fits(r.key, v)) settings[r.key] = v!;
    }
    return SettingsFile(
      settings: settings,
      keysToml: keysToml,
      folders: [
        for (final r in await (db.select(db.roots)..orderBy([(r) => OrderingTerm(expression: r.id)])).get()) r.path,
      ],
      positions: await db.select(db.progress).get(),
      bookmarks: await db.select(db.bookmarks).get(),
      collections: await db.select(db.collectionBooks).get(),
      edits: await db.select(db.overrides).get(),
      history: await db.select(db.readLog).get(),
      appVersion: version.appVersion,
      exportedAt: now ?? DateTime.now(),
    );
  }

  static Object? _decode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  /// Whether [value] is what the setting [key] holds.
  static bool _fits(String key, Object? value) => switch (SettingsStore.backedUp[key]) {
    true => value is bool,
    false => value is String && (key != SettingsStore.gridZoom || double.tryParse(value) != null),
    null => false,
  };

  /// Writes the file's settings and per-comic rows into [db], in one
  /// transaction. The settings become the file's: one it does not have
  /// goes back to its default, except the [SettingsStore.perInstall] ones,
  /// which stay as they are. With [keepSidecarDir] the sidecar folder stays
  /// this install's (the file's is not on this device). Per comic,
  /// the rows merge with what is here by the sidecar rules
  /// ([mergeSidecars]): bookmarks are a union with removals winning, the
  /// later edit per field and the later change per collection win. The
  /// later of two positions wins; reading history already here is not
  /// added twice. Library folders and `keys.toml` are the caller's.
  Future<void> mergeInto(AppDatabase db, {bool keepSidecarDir = false}) => db.transaction(() async {
    for (final key in SettingsStore.backedUp.keys) {
      if (key == SettingsStore.sidecarDir && keepSidecarDir) continue;
      final v = settings[key];
      if (v == null && SettingsStore.perInstall.contains(key)) continue;
      if (v == null) {
        await (db.delete(db.settings)..where((s) => s.key.equals(key))).go();
      } else {
        await db.into(db.settings).insertOnConflictUpdate(SettingRow(key: key, value: jsonEncode(v)));
      }
    }

    for (final r in positions) {
      final have = await (db.select(db.progress)..where((x) => x.contentKey.equals(r.contentKey))).getSingleOrNull();
      if (have == null || r.updatedAt.isAfter(have.updatedAt)) await db.into(db.progress).insertOnConflictUpdate(r);
    }

    final logged = {for (final r in await db.select(db.readLog).get()) (r.contentKey, r.startedAt)};
    await db.batch((b) {
      b.insertAll(db.readLog, [
        for (final r in history)
          if (logged.add((r.contentKey, r.startedAt))) r,
      ]);
    });

    final keys = {
      for (final b in bookmarks) b.contentKey,
      for (final c in collections) c.contentKey,
      for (final o in edits) o.contentKey,
    };
    for (final key in keys) {
      final local = SidecarData(
        contentKey: key,
        bookmarks: await (db.select(db.bookmarks)..where((r) => r.contentKey.equals(key))).get(),
        collections: await (db.select(db.collectionBooks)..where((r) => r.contentKey.equals(key))).get(),
        overrides: {
          for (final o in await (db.select(db.overrides)..where((r) => r.contentKey.equals(key))).get())
            o.field: o.value,
        },
      );
      final theirs = SidecarData(
        contentKey: key,
        bookmarks: [
          for (final b in bookmarks)
            if (b.contentKey == key) b,
        ],
        collections: [
          for (final c in collections)
            if (c.contentKey == key) c,
        ],
        overrides: {
          for (final o in edits)
            if (o.contentKey == key) o.field: o.value,
        },
      );
      final merged = mergeSidecars(local, theirs);
      await db.deleteBookRows(key, [db.bookmarks, db.collectionBooks]);
      await db.batch((b) {
        b.insertAll(db.bookmarks, merged.bookmarks);
        b.insertAll(db.collectionBooks, merged.collections);
        b.insertAllOnConflictUpdate(db.overrides, [
          for (final MapEntry(:key, :value) in merged.overrides.entries)
            Override(contentKey: theirs.contentKey, field: key, value: value),
        ]);
      });
    }
  });

  /// Every comic the file has something about.
  Set<String> get books => {
    for (final r in positions) r.contentKey,
    for (final b in bookmarks) b.contentKey,
    for (final c in collections) c.contentKey,
    for (final o in edits) o.contentKey,
    for (final r in history) r.contentKey,
  };

  static String _time(DateTime t) => t.toUtc().toIso8601String();

  Map<String, Object?> toJson() => {
    'app': appId,
    'kind': settingsFileKind,
    'format': settingsFileFormat,
    'appVersion': ?appVersion,
    if (exportedAt case final t?) 'exportedAt': _time(t),
    'settings': settings,
    'keysToml': ?keysToml,
    'libraryFolders': folders,
    'positions': [
      for (final r in positions)
        {
          'contentKey': r.contentKey,
          'page': r.page,
          'panel': ?r.panel,
          'percent': r.percent,
          'finished': r.finished,
          'updatedAt': _time(r.updatedAt),
          'view': ?r.viewJson,
        },
    ],
    'bookmarks': [
      for (final b in bookmarks)
        {
          'id': b.id,
          'contentKey': b.contentKey,
          'page': b.page,
          'panel': ?b.panel,
          'mark': ?b.mark,
          'note': ?b.note,
          'createdAt': _time(b.createdAt),
          if (b.deletedAt case final t?) 'deletedAt': _time(t),
        },
    ],
    'collections': [
      for (final c in collections)
        {
          'name': c.name,
          'contentKey': c.contentKey,
          'addedAt': _time(c.addedAt),
          if (c.removedAt case final t?) 'removedAt': _time(t),
        },
    ],
    'metadataEdits': [
      for (final o in edits) {'contentKey': o.contentKey, 'field': o.field, 'edit': o.value},
    ],
    'readingHistory': [
      for (final r in history)
        {'contentKey': r.contentKey, 'startedAt': _time(r.startedAt), 'endedAt': _time(r.endedAt), 'pages': r.pages},
    ],
  };

  /// The file's text: indented JSON, readable and diffable.
  String encode() => '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  /// Reads a settings file. Throws [SettingsFileException] for a file that
  /// is not one of ComicRedr's, or is from a newer version. Anything it
  /// does not know inside one (a setting added later, a field too many) is
  /// skipped, and so is a row it cannot read.
  static SettingsFile decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const SettingsFileException('This is not a ComicRedr settings file: it is not JSON.');
    }
    if (json is! Map<String, Object?>) {
      throw const SettingsFileException('This is not a ComicRedr settings file.');
    }
    final Map<String, Object?> doc = json;
    final app = doc['app'];
    if (app != appId) {
      throw SettingsFileException(
        app is String
            ? 'This file is from another app ($app), not ComicRedr.'
            : 'This is not a ComicRedr settings file.',
      );
    }
    if (doc['kind'] != settingsFileKind) {
      throw const SettingsFileException('This ComicRedr file is not a settings file.');
    }
    final format = doc['format'];
    if (format is! int || format < 1) {
      throw SettingsFileException('This settings file has an unknown format ($format).');
    }
    if (format > settingsFileFormat) {
      throw SettingsFileException(
        'This settings file is from a newer ComicRedr (format $format; this one reads $settingsFileFormat). '
        'Update ComicRedr first.',
      );
    }

    var skipped = 0;
    List<T> rows<T>(String name, T Function(Map<String, Object?> m) read) {
      final list = doc[name];
      if (list == null) return const [];
      if (list is! List) {
        skipped++;
        return const [];
      }
      final out = <T>[];
      for (final m in list) {
        try {
          out.add(read((m as Map).cast<String, Object?>()));
        } catch (_) {
          skipped++; // A broken row costs that row only.
        }
      }
      return out;
    }

    final settings = <String, Object>{};
    if (doc['settings'] case final Map<String, Object?> s) {
      for (final MapEntry(:key, :value) in s.entries) {
        if (_fits(key, value)) {
          settings[key] = value!;
        } else {
          skipped++;
        }
      }
    } else if (doc['settings'] != null) {
      skipped++;
    }
    final folders = <String>[];
    switch (doc['libraryFolders']) {
      case final List<Object?> list:
        for (final f in list) {
          if (f is String && f.isNotEmpty) {
            folders.add(f);
          } else {
            skipped++;
          }
        }
      case null:
        break;
      default:
        skipped++;
    }
    final keys = doc['keysToml'];
    if (keys != null && keys is! String) skipped++;

    DateTime time(Object? v) => DateTime.parse(v! as String).toLocal();
    DateTime? maybeTime(Object? v) => v == null ? null : time(v);
    String str(Object? v) => v! as String;
    int whole(Object? v) => (v! as num).toInt();
    int? maybeInt(Object? v) => (v as num?)?.toInt();

    return SettingsFile(
      settings: settings,
      keysToml: keys is String ? keys : null,
      folders: folders,
      positions: rows(
        'positions',
        (m) => ProgressData(
          contentKey: str(m['contentKey']),
          page: whole(m['page']),
          panel: maybeInt(m['panel']),
          percent: (m['percent']! as num).toDouble(),
          finished: m['finished'] as bool? ?? false,
          updatedAt: time(m['updatedAt']),
          viewJson: m['view'] as String?,
        ),
      ),
      bookmarks: rows(
        'bookmarks',
        (m) => Bookmark(
          id: str(m['id']),
          contentKey: str(m['contentKey']),
          page: whole(m['page']),
          panel: maybeInt(m['panel']),
          mark: m['mark'] as String?,
          note: m['note'] as String?,
          createdAt: time(m['createdAt']),
          deletedAt: maybeTime(m['deletedAt']),
        ),
      ),
      collections: rows(
        'collections',
        (m) => CollectionBook(
          name: str(m['name']),
          contentKey: str(m['contentKey']),
          addedAt: time(m['addedAt']),
          removedAt: maybeTime(m['removedAt']),
        ),
      ),
      edits: rows(
        'metadataEdits',
        (m) => Override(contentKey: str(m['contentKey']), field: str(m['field']), value: str(m['edit'])),
      ),
      history: rows(
        'readingHistory',
        (m) => ReadLogData(
          contentKey: str(m['contentKey']),
          startedAt: time(m['startedAt']),
          endedAt: time(m['endedAt']),
          pages: whole(m['pages']),
        ),
      ),
      appVersion: doc['appVersion'] is String ? doc['appVersion']! as String : null,
      exportedAt: doc['exportedAt'] is String ? DateTime.tryParse(doc['exportedAt']! as String)?.toLocal() : null,
      skipped: skipped,
    );
  }
}
