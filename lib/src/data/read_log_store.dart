import 'package:drift/drift.dart';

import 'app_database.dart';

/// Reading history (M8): one row per sitting with a book. A sitting that
/// starts within [joinGap] of the last one on the same book ended, as after
/// the phone was put down for a moment, continues that row.
class ReadLogStore {
  ReadLogStore(this._db, {this.joinGap = const Duration(minutes: 2)});

  final AppDatabase _db;
  final Duration joinGap;

  Future<void> record(String contentKey, DateTime start, DateTime end, int pages) async {
    // A glance (opened and closed on one page) is not a sitting.
    if (pages <= 1 && end.difference(start) < const Duration(seconds: 3)) return;
    await _db.transaction(() async {
      final last =
          await (_db.select(_db.readLog)
                ..where((r) => r.contentKey.equals(contentKey))
                ..orderBy([(r) => OrderingTerm(expression: r.endedAt, mode: OrderingMode.desc)])
                ..limit(1))
              .getSingleOrNull();
      if (last != null && !start.isAfter(last.endedAt.add(joinGap))) {
        await (_db.update(_db.readLog)
              ..where((r) => r.contentKey.equals(contentKey) & r.startedAt.equals(last.startedAt)))
            .write(ReadLogCompanion(endedAt: Value(end), pages: Value(last.pages + pages)));
        return;
      }
      await _db
          .into(_db.readLog)
          .insert(ReadLogCompanion.insert(contentKey: contentKey, startedAt: start, endedAt: end, pages: pages));
    });
  }
}
