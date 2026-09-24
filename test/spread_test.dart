import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/layout.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Spread mode with a scanned double-page spread in the book: the wide page
/// stands alone and the pages after it keep their sides, across a restart.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('spread_test');
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [databaseProvider.overrideWithValue(db), classicCvOnly, noSidecars(db)],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  /// Two four-panel pages side by side on one 800 x 600 image.
  final spread = gridPage(800, 600, [
    for (final x in [20, 210, 420, 610])
      for (final y in [20, 310]) (x, y, 170, 270),
  ]);

  /// Eight pages; the fourth is a double-page scan.
  String writeSpreadBook() =>
      writeBookOf(tmp, 'Spread 01.cbz', [for (var i = 0; i < 8; i++) i == 3 ? spread : grid4Page()]);

  testWidgets('a wide page stands alone and the pages after it keep their sides', (tester) async {
    final path = writeSpreadBook();
    var c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    expect(c.read(readerProvider).wide, {3});

    await key(tester, LogicalKeyboardKey.keyD);
    expect(c.read(readerProvider).mode, PageMode.spread);
    final units = [c.read(readerProvider).unit];
    for (var i = 0; i < 4; i++) {
      await key(tester, LogicalKeyboardKey.keyL);
      units.add(c.read(readerProvider).unit);
    }
    expect(units, [
      [0],
      [1, 2],
      [3],
      [4, 5],
      [6, 7],
    ]);
    // And back again.
    await key(tester, LogicalKeyboardKey.keyH);
    await key(tester, LogicalKeyboardKey.keyH);
    expect(c.read(readerProvider).unit, [3]);

    // A restart on the page after the spread comes back to the same pair.
    await key(tester, LogicalKeyboardKey.keyL);
    await tester.runAsync(() => c.read(readerProvider.notifier).flush());
    c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    final s = c.read(readerProvider);
    expect((s.mode, s.page), (PageMode.spread, 4));
    expect(s.unit, [4, 5]);
  });

  testWidgets('guided view reads the left page of a spread before the right', (tester) async {
    final path = writeSpreadBook();
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path, at: (page: 3, panel: 0)));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    final s = c.read(readerProvider);
    expect(s.guided, isTrue);
    final stops = s.stopsOn(3);
    expect(stops, hasLength(8), reason: s.panels[3]?.gate.reasons.join('; '));
    // Every panel of the left page comes before any of the right page.
    expect([for (final Panel p in stops) p.x + p.w / 2 < 0.5], [true, true, true, true, false, false, false, false]);
  });
}
