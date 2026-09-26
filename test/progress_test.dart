import 'dart:io';

import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/read_log_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('progress_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ProviderContainer container({Duration joinGap = const Duration(minutes: 2)}) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noSidecars(db),
        classicCvOnly,
        readLogStoreProvider.overrideWithValue(ReadLogStore(db, joinGap: joinGap)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('in two-page mode the last pair finishes the book', () async {
    final c = container();
    final reader = c.read(readerProvider.notifier);
    await reader.open(writeBook(tmp, 'Three 01.cbz', 3));
    await reader.handle(const ReaderCommand(ReaderIntent.toggleSpread));
    await reader.handle(const ReaderCommand(ReaderIntent.nextStep));
    expect(c.read(readerProvider).unit, [1, 2]);
    await reader.flush();
    final row = await db.select(db.progress).getSingle();
    expect((row.page, row.percent, row.finished), (1, 1.0, true), reason: 'page 3 of 3 is on screen');
  });

  test('time the app spends in the background is not logged as reading', () async {
    final c = container(joinGap: const Duration(seconds: 1));
    final reader = c.read(readerProvider.notifier);
    await reader.open(writeBook(tmp, 'Away 01.cbz', 4));
    await reader.handle(const ReaderCommand(ReaderIntent.nextStep));
    await reader.flush(); // The app goes to the background...
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    reader.resumeSitting(); // ...and comes back.
    await reader.handle(const ReaderCommand(ReaderIntent.nextStep));
    await reader.handle(const ReaderCommand(ReaderIntent.nextStep));
    await reader.close();
    final rows = await db.select(db.readLog).get();
    expect(rows, hasLength(2), reason: 'two sittings, the time away between them');
    for (final r in rows) {
      expect(r.endedAt.difference(r.startedAt).inMilliseconds, lessThan(2000));
    }
  });
}
