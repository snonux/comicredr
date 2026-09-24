import 'dart:convert';

import 'app_database.dart';

/// App-wide settings, one JSON value per key in the settings table.
class SettingsStore {
  SettingsStore(this._db);

  final AppDatabase _db;

  /// Guided view shows each page whole before and after its panels.
  static const wholePageSteps = 'guided.wholePageSteps';

  /// Guided view holds on a page shown whole for one step before turning.
  static const pauseWhole = 'guided.pauseWhole';

  /// How a held page shows it: a PauseCue name, `colour` by default.
  static const pauseCue = 'guided.pauseCue';

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

  /// Find the panels of the whole library in the background
  /// (LibraryDetection). On by default on the laptop, off on the phone.
  static const detectLibrary = 'detect.library';

  /// How big the page grid's (`p`) thumbnails are: an index into its zoom
  /// levels, kept across openings and restarts.
  static const gridZoom = 'grid.zoom';

  /// The touch preset picked in Settings (a TouchPreset name).
  static const touchPreset = 'touch.preset';

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

  /// Saves [value] under [key]; null forgets it.
  Future<void> saveString(String key, String? value) => value == null
      ? (_db.delete(_db.settings)..where((s) => s.key.equals(key))).go()
      : _db.into(_db.settings).insertOnConflictUpdate(SettingRow(key: key, value: jsonEncode(value)));
}
