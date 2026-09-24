import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('comicredr-a11y');
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db), classicCvOnly, noSidecars(db)],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> meetsAll(WidgetTester tester) async {
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  }

  testWidgets('the library meets the tap target, label and contrast guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    final c = await pumpApp(tester);
    await settle(tester);
    await meetsAll(tester);
    final root = Directory('${tmp.path}/Comics')..createSync();
    writeBookOf(root, 'Series #001.cbz', [grid4Page()]);
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(root.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    await meetsAll(tester);
    handle.dispose();
  });

  testWidgets('the reader does too, in and out of guided view', (tester) async {
    final handle = tester.ensureSemantics();
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeBookOf(tmp, 'A.cbz', [grid4Page()])));
    await settle(tester);
    await meetsAll(tester);
    expect(find.bySemanticsLabel('Page 1 of 1'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV, character: 'v');
    await settle(tester);
    await meetsAll(tester);
    handle.dispose();
  });

  testWidgets('the ? overlay does too', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, physicalKey: PhysicalKeyboardKey.slash, character: '?');
    await tester.pump();
    await meetsAll(tester);
    handle.dispose();
  });

  testWidgets('double-size text lays out without overflow in the library, reader and overlay', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = await pumpApp(tester);
    await settle(tester);
    expect(tester.takeException(), isNull);
    final root = Directory('${tmp.path}/Comics')..createSync();
    for (var i = 1; i <= 3; i++) {
      writeBookOf(root, 'A Long Series Name With Many Words #00$i (1952).cbz', [grid4Page()]);
    }
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(root.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(writeBookOf(tmp, 'B.cbz', [grid4Page()])));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV, character: 'v');
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, physicalKey: PhysicalKeyboardKey.slash, character: '?');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
