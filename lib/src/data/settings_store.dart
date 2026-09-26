import 'dart:convert';

import 'app_database.dart';

/// App-wide settings, one JSON value per key in the settings table.
class SettingsStore {
  SettingsStore(this._db);

  final AppDatabase _db;

  /// Guided view shows each page whole before and after its panels.
  static const wholePageSteps = 'guided.wholePageSteps';

  /// Guided view turns the background wine red on a page shown whole and
  /// holds a quick step there before turning.
  static const pauseWhole = 'guided.pauseWhole';

  /// The night filter (`i`) and auto-trim (`t`), kept across restarts.
  static const night = 'reader.night';
  static const autoTrim = 'reader.autoTrim';

  /// Fullscreen (`f`, F11), in the library and the reader: the next book
  /// and the next launch come back the way it was left.
  static const fullscreen = 'reader.fullscreen';

  /// Scan clean-up (`c`): levels on the paper colour, and small pages
  /// enlarged and sharpened. Off by default.
  static const cleanUp = 'reader.cleanUp';

  /// Write each comic's sidecar beside it (M8). On by default; reading
  /// sidecars that are there already never stops.
  static const writeSidecars = 'sidecars.write';

  /// Keep every sidecar in this one folder, laid out like the library,
  /// instead of beside each comic. Unset (the default): beside each comic.
  /// Per install, so the laptop and the phone each name their own folder.
  static const sidecarDir = 'sidecars.dir';

  /// How big the page grid's (`p`) thumbnails are: an index into its zoom
  /// levels, kept across openings and restarts.
  static const gridZoom = 'grid.zoom';

  /// Shuffle on the library's Folders tab (`S`): random pages instead of
  /// covers. Off by default.
  static const shuffle = 'library.shuffle';

  /// The default library folder (~/Comics) was taken out of the library,
  /// so starts no longer add it back.
  static const defaultFolderRemoved = 'library.defaultFolderRemoved';

  /// The touch preset picked in Settings (a TouchPreset name).
  static const touchPreset = 'touch.preset';

  /// The comics opened last, newest first, for `C` (RecentBooks). Paths on
  /// this device, so a settings file leaves them out.
  static const recentBooks = 'reader.recent';

  /// Every setting a settings file carries (SettingsFile), with the kind of
  /// value it holds: true for a flag, false for a string. This install's
  /// identity (`device.id`, `device.name`, see SidecarSync) is not a setting
  /// and stays out, and so does [defaultFolderRemoved]: whether this
  /// device's own Comics folder was taken out says nothing about another
  /// device's, nor does [recentBooks], which names this device's paths. A new setting goes here too, or export leaves it behind.
  static const backedUp = <String, bool>{
    wholePageSteps: true,
    pauseWhole: true,
    night: true,
    autoTrim: true,
    fullscreen: true,
    cleanUp: true,
    writeSidecars: true,
    sidecarDir: false,
    gridZoom: false,
    shuffle: true,
    touchPreset: false,
  };

  /// Settings about this device's own storage: where its sidecars go and
  /// whether its folders are written to. An import sets them when the file
  /// has them (a restore on the same device) and otherwise leaves them as
  /// they are, where the others go back to their defaults: a file from the
  /// laptop, whose sidecars sit beside its comics, must not move the
  /// phone's out of the folder it keeps them in.
  static const perInstall = {sidecarDir, writeSidecars};

  Future<bool?> loadBool(String key) async {
    final row = await (_db.select(_db.settings)..where((s) => s.key.equals(key))).getSingleOrNull();
    final v = row == null ? null : jsonDecode(row.value);
    return v is bool ? v : null;
  }

  Future<void> saveBool(String key, bool value) =>
      _db.into(_db.settings).insertOnConflictUpdate(SettingRow(key: key, value: jsonEncode(value)));

  Future<String?> loadString(String key) async {
    final row = await (_db.select(_db.settings)..where((s) => s.key.equals(key))).getSingleOrNull();
    final v = row == null ? null : jsonDecode(row.value);
    return v is String ? v : null;
  }

  /// Any JSON value under [key], null when unset.
  Future<Object?> loadJson(String key) async {
    final row = await (_db.select(_db.settings)..where((s) => s.key.equals(key))).getSingleOrNull();
    return row == null ? null : jsonDecode(row.value);
  }

  Future<void> saveJson(String key, Object value) =>
      _db.into(_db.settings).insertOnConflictUpdate(SettingRow(key: key, value: jsonEncode(value)));

  /// Saves [value] under [key]; null forgets it.
  Future<void> saveString(String key, String? value) => value == null
      ? (_db.delete(_db.settings)..where((s) => s.key.equals(key))).go()
      : _db.into(_db.settings).insertOnConflictUpdate(SettingRow(key: key, value: jsonEncode(value)));
}
