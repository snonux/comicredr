import 'dart:convert';

import 'app_database.dart';

/// App-wide settings, one JSON value per key in the settings table.
class SettingsStore {
  SettingsStore(this._db);

  final AppDatabase _db;

  /// Guided view shows each page whole before and after its panels.
  static const wholePageSteps = 'guided.wholePageSteps';

  Future<bool?> loadBool(String key) async {
    final row = await (_db.select(_db.settings)..where((s) => s.key.equals(key))).getSingleOrNull();
    final v = row == null ? null : jsonDecode(row.value);
    return v is bool ? v : null;
  }

  Future<void> saveBool(String key, bool value) =>
      _db.into(_db.settings).insertOnConflictUpdate(SettingRow(key: key, value: jsonEncode(value)));
}
