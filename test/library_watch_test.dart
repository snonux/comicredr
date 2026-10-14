import 'dart:async';

import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a burst of changes is answered by a few reads of the library, not one each', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final store = LibraryStore(db);
    var reads = 0;
    final sub = store.watchBooks().listen((_) => reads++);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reads, 1);
    // A scan writes several tables a comic; each write is a change.
    for (var i = 0; i < 40; i++) {
      await store.setCompleted('key$i', true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Before, every change queued a read of its own: 41.
    expect(reads, lessThan(20));
    expect(reads, greaterThan(1)); // The last change is still seen.
    // Not awaited: an async* stream ends only at its next change.
    unawaited(sub.cancel());
    await db.close();
  });
}
