import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'app_database.dart';

/// Reading position, keyed by content key. Writes are debounced so a burst
/// of page turns costs one write, and [flush] runs on pause and close, so a
/// killed app loses at most the last page (design plan section 6).
class ProgressStore {
  ProgressStore(this._db, {this.debounce = const Duration(milliseconds: 500)});

  final AppDatabase _db;
  final Duration debounce;
  Timer? _timer;
  ProgressCompanion? _pendingRow;

  Future<int?> load(String contentKey) async {
    final row = await (_db.select(
      _db.progress,
    )..where((p) => p.contentKey.equals(contentKey))).getSingleOrNull();
    return row?.page;
  }

  void save(String contentKey, int page, int pageCount) {
    _pendingRow = ProgressCompanion.insert(
      contentKey: contentKey,
      page: page,
      percent: pageCount <= 1 ? 1 : page / (pageCount - 1),
      finished: Value(page >= pageCount - 1),
      updatedAt: DateTime.now(),
    );
    _timer?.cancel();
    _timer = Timer(debounce, flush);
  }

  Future<void> flush() async {
    _timer?.cancel();
    final row = _pendingRow;
    _pendingRow = null;
    if (row == null) return;
    try {
      await _db.into(_db.progress).insertOnConflictUpdate(row);
    } catch (e) {
      // Losing a reading position is better than crashing the reader.
      debugPrint('Could not save reading position: $e');
    }
  }
}
