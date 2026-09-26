import 'dart:async';
import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/panel_detector.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'balloon_test.dart' show FakeModel;
import 'support/fixtures.dart';

/// Notes every page it is asked for, in order, with its book's page count.
class _CountingModel extends FakeModel {
  _CountingModel(this.asked);

  final List<(int, int)> asked;

  @override
  Future<DetectedPage> detect(ComicDocument doc, int page) async {
    asked.add((doc.pageCount, page));
    return super.detect(doc, page);
  }
}

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('reader_ahead_test');
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle(ProviderContainer c, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('the open book is analysed ahead of the reader, guided view off, and only it', () async {
    final asked = <(int, int)>[];
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noSidecars(db),
        panelDetectorProvider.overrideWith((ref) async => _CountingModel(asked)),
      ],
    );
    addTearDown(c.dispose);
    final a = writeBookOf(tmp, 'A 01.cbz', [for (var i = 0; i < 8; i++) grid4Page()]);
    writeBookOf(tmp, 'B 01.cbz', [grid4Page(), grid4Page()]);
    final reader = c.read(readerProvider.notifier);

    await reader.open(a, at: (page: 4, panel: 0));
    expect(c.read(readerProvider).guided, isFalse);
    await settle(c, () => c.read(readerProvider).panels.length >= 5);
    final s = c.read(readerProvider);
    expect(s.panels.keys.toSet(), {3, 4, 5, 6, 7}, reason: 'the page, the one behind and every page ahead');
    expect(asked.first.$2, 4, reason: 'the page being read first');
    expect(asked.map((e) => e.$1).toSet(), {8}, reason: 'no other book');
  });

  test('closing the book stops the work', () async {
    final asked = <(int, int)>[];
    final gate = Completer<void>();
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noSidecars(db),
        panelDetectorProvider.overrideWith((ref) async => _GatedModel(asked, gate)),
      ],
    );
    addTearDown(c.dispose);
    final a = writeBookOf(tmp, 'A 01.cbz', [for (var i = 0; i < 8; i++) grid4Page()]);
    final reader = c.read(readerProvider.notifier);

    await reader.open(a);
    await settle(c, () => asked.isNotEmpty);
    await reader.close();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(asked, hasLength(1), reason: 'only the page under way when it closed');
    expect(reader.detecting, isFalse);
  });
}

/// Holds every answer until [gate] completes.
class _GatedModel extends _CountingModel {
  _GatedModel(super.asked, this.gate);

  final Completer<void> gate;

  @override
  Future<DetectedPage> detect(ComicDocument doc, int page) async {
    final found = super.detect(doc, page);
    await gate.future;
    return found;
  }
}
