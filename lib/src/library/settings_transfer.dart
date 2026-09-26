import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/app_database.dart';
import '../data/settings_file.dart';
import '../data/settings_store.dart';
import 'library_store.dart';

/// What an import brought in, for the notice after it.
typedef SettingsImport = ({
  int settings,
  int foldersAdded,
  List<String> foldersMissing,
  String? sidecarDirMissing,
  bool keysWritten,
  String? keysError,
  int positions,
  int bookmarks,
  int collections,
  int edits,
  int history,
  int skipped,
  Set<String> books,
});

/// The name an exported settings file is offered under.
String settingsFileName(DateTime now) => 'comicredr-settings-${now.year}-${_two(now.month)}-${_two(now.day)}.json';

String _two(int n) => n.toString().padLeft(2, '0');

/// The settings file's text for everything in [db], with `keys.toml` from
/// [keysPath] when there is one.
Future<String> exportSettings(AppDatabase db, {String? keysPath, DateTime? now}) async {
  String? keys;
  if (keysPath != null) {
    final f = File(keysPath);
    if (await f.exists()) keys = await f.readAsString();
  }
  return (await SettingsFile.gather(db, keysToml: keys, now: now)).encode();
}

/// Writes [text] as a new file in [dir], named [name], or `name-2.json` and
/// so on when that is taken, and returns its path. Nothing is overwritten.
Future<String> writeNewFile(String dir, String name, String text) async {
  final stem = p.basenameWithoutExtension(name), ext = p.extension(name);
  var path = p.join(dir, name);
  for (var n = 2; await File(path).exists(); n++) {
    path = p.join(dir, '$stem-$n$ext');
  }
  await File(path).writeAsString(text, flush: true);
  return path;
}

/// Puts [file] into this install: settings, per-comic rows, library
/// folders and `keys.toml` (to [keysPath]). Library folders are added when
/// they exist here and are not in the library yet; none is ever taken out.
/// The index changes in one transaction, so a failure there leaves it as it
/// was. `keys.toml` is written after it; when that fails the import stands
/// and [SettingsImport.keysError] says why. A `keys.toml` already here that
/// differs is kept as `keys.toml.bak`; a file without one leaves this one
/// alone.
Future<SettingsImport> importSettings(SettingsFile file, {required LibraryStore library, String? keysPath}) async {
  bool there(String dir) => Directory(dir).existsSync();
  final sidecarDir = file.settings[SettingsStore.sidecarDir] as String?;
  final sidecarDirMissing = sidecarDir != null && !there(sidecarDir) ? sidecarDir : null;
  final missing = <String>[];
  var added = 0;
  await library.db.transaction(() async {
    await file.mergeInto(library.db, keepSidecarDir: sidecarDirMissing != null);
    final roots = await library.roots();
    for (final dir in file.folders) {
      final path = p.normalize(p.absolute(dir));
      if (roots.any((r) => p.equals(r.path, path))) continue;
      if (!there(path)) {
        missing.add(dir);
        continue;
      }
      await library.addRoot(path);
      added++;
    }
  });

  var keysWritten = false;
  String? keysError;
  if ((file.keysToml, keysPath) case (final text?, final path?)) {
    try {
      final f = File(path);
      final had = await f.exists() ? await f.readAsString() : null;
      if (had != text) {
        await f.parent.create(recursive: true);
        if (had != null) await f.copy('$path.bak');
        await f.writeAsString(text, flush: true);
        keysWritten = true;
      }
    } on FileSystemException catch (e) {
      keysError = '${e.message}${e.path == null ? '' : ': ${e.path}'}';
    }
  }

  return (
    settings: file.settings.length - (sidecarDirMissing == null ? 0 : 1),
    foldersAdded: added,
    foldersMissing: missing,
    sidecarDirMissing: sidecarDirMissing,
    keysWritten: keysWritten,
    keysError: keysError,
    positions: file.positions.length,
    bookmarks: file.bookmarks.where((b) => b.deletedAt == null).length,
    collections: file.collections.where((c) => c.removedAt == null).length,
    edits: file.edits.length,
    history: file.history.length,
    skipped: file.skipped,
    books: file.books,
  );
}

/// One or two sentences on what an import did.
String importNotice(SettingsImport r) {
  String n(int count, String one, [String? many]) => '$count ${count == 1 ? one : many ?? '${one}s'}';
  final parts = [
    r.settings == 0 ? 'the default settings' : n(r.settings, 'setting'),
    if (r.foldersAdded > 0) n(r.foldersAdded, 'library folder'),
    if (r.keysWritten) 'keys.toml',
    if (r.positions > 0) n(r.positions, 'position'),
    if (r.bookmarks > 0) n(r.bookmarks, 'bookmark'),
    if (r.collections > 0) n(r.collections, 'collection entry', 'collection entries'),
    if (r.edits > 0) n(r.edits, 'edit'),
    if (r.history > 0) n(r.history, 'history entry', 'history entries'),
  ];
  final notes = [
    if (r.foldersMissing.isNotEmpty)
      '${n(r.foldersMissing.length, 'library folder')} not on this device: ${r.foldersMissing.join(', ')}.',
    if (r.sidecarDirMissing case final dir?) 'The sidecar folder $dir is not on this device; kept this one\'s.',
    if (r.keysError case final e?) 'keys.toml could not be written ($e); the rest was imported.',
    if (r.skipped > 0) '${n(r.skipped, 'entry', 'entries')} this version does not know skipped.',
  ];
  return ['Imported ${_list(parts)}.', ...notes].join(' ');
}

String _list(List<String> parts) =>
    parts.length < 2 ? parts.join() : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
