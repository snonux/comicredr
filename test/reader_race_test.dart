import 'dart:async';
import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/panel_detector.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'balloon_test.dart' show FakeModel;
import 'support/fixtures.dart';

/// A detector that holds its first answer until [release] completes, like a
/// slow model still busy on the old book when the next one opens.
class _HeldModel extends FakeModel {
  _HeldModel(this.release);

  final Completer<void> release;

  @override
  Future<DetectedPage> detect(ComicDocument doc, int page) async {
    await release.future;
    return super.detect(doc, page);
  }
}

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('reader_race_test');
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a book opened while the last one was detecting gets its panels', () async {
    final release = Completer<void>();
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noSidecars(db),
        panelDetectorProvider.overrideWith((ref) async => _HeldModel(release)),
      ],
    );
    addTearDown(c.dispose);
    final a = writeBookOf(tmp, 'A 01.cbz', [grid4Page(), grid4Page()]);
    final b = writeBookOf(tmp, 'B 01.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    final reader = c.read(readerProvider.notifier);

    await reader.open(a);
    await reader.handle(const ReaderCommand(ReaderIntent.toggleGuided));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reader.detecting, isTrue, reason: 'A is waiting on the detector');

    await reader.open(b);
    expect(c.read(readerProvider).guided, isTrue);
    release.complete();
    for (var i = 0; i < 50 && c.read(readerProvider).panels.length < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final s = c.read(readerProvider);
    expect(s.book!.path, b);
    expect(s.panels.keys.toSet(), {0, 1, 2}, reason: "every page of B detected, not left without panels");
    expect(s.panels[0]!.frames, hasLength(4));
  });

  testWidgets('a page left before it decoded never replaces the one shown', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db), classicCvOnly, noSidecars(db)],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    final path = writeBookOf(tmp, 'Ten 01.cbz', [for (var i = 0; i < 10; i++) grid4Page()]);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.bySemanticsLabel('Page 1 of 10'), findsOneWidget);

    // G starts decoding page 10; gg comes back before it lands.
    await c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.lastPage));
    await tester.pump();
    await c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.firstPage));
    await tester.pump();
    expect(c.read(readerProvider).page, 0);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      expect(find.bySemanticsLabel('Page 10 of 10'), findsNothing, reason: 'page 10 flashed up after gg');
    }
    expect(find.bySemanticsLabel('Page 1 of 10'), findsOneWidget);
  });
}
