import 'dart:async';

import 'package:drift/drift.dart';

import 'app_database.dart';

/// Reading history (M8): one row per sitting with a book. A sitting that
/// starts within [joinGap] of the last one on the same book ended, as after
/// the phone was put down for a moment, continues that row.
class ReadLogStore {
  ReadLogStore(this._db, {this.joinGap = const Duration(minutes: 2)});

  final AppDatabase _db;
  final Duration joinGap;
  final _glances = <String, ({DateTime start, DateTime end, int pages})>{};
  Future<void>? _writing;

  Future<void> _queue(Future<void> Function() write) async {
    final previous = _writing;
    final done = Completer<void>();
    _writing = done.future;
    try {
      if (previous != null) await previous;
      await write();
    } finally {
      if (identical(_writing, done.future)) _writing = null;
      done.complete();
    }
  }

  Future<void> clear() => _queue(() async {
    await _db.delete(_db.readLog).go();
    _glances.clear();
  });

  Future<void> record(String contentKey, DateTime start, DateTime end, int pages) =>
      _queue(() => _record(contentKey, start, end, pages));

  Future<void> _record(String contentKey, DateTime start, DateTime end, int pages) async {
    final glance = _glances[contentKey];
    final continuesGlance = glance != null && !start.isAfter(glance.end.add(joinGap));
    final first = continuesGlance ? glance.start : start;
    final totalPages = pages + (continuesGlance ? glance.pages : 0);
    var keepGlance = false;
    await _db.transaction(() async {
      final last =
          await (_db.select(_db.readLog)
                ..where((r) => r.contentKey.equals(contentKey))
                ..orderBy([(r) => OrderingTerm(expression: r.endedAt, mode: OrderingMode.desc)])
                ..limit(1))
              .getSingleOrNull();
      if (last != null && !first.isAfter(last.endedAt.add(joinGap))) {
        await (_db.update(_db.readLog)
              ..where((r) => r.contentKey.equals(contentKey) & r.startedAt.equals(last.startedAt)))
            .write(ReadLogCompanion(endedAt: Value(end), pages: Value(last.pages + totalPages)));
        return;
      }
      // A glance is left out only when it cannot continue a logged sitting.
      if (totalPages <= 1 && end.difference(first) < const Duration(seconds: 3)) {
        keepGlance = true;
        return;
      }
      await _db
          .into(_db.readLog)
          .insert(ReadLogCompanion.insert(contentKey: contentKey, startedAt: first, endedAt: end, pages: totalPages));
    });
    _glances.removeWhere((_, candidate) => start.isAfter(candidate.end.add(joinGap)));
    _glances.remove(contentKey);
    if (keepGlance) _glances[contentKey] = (start: first, end: end, pages: totalPages);
  }
}
