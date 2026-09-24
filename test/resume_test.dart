import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/layout.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

/// Resume across a restart: the app goes away without closing the book, as
/// when the window is closed, and a new app on the same index reopens it.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('resume_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(), // A new scope each time: a fresh app, same index.
        overrides: [databaseProvider.overrideWithValue(db)],
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

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {String? character}) async {
    await tester.sendKeyEvent(k, character: character);
    await settle(tester);
  }

  /// What the app does on its way out: flush the position, and nothing else.
  Future<ProviderContainer> restart(WidgetTester tester, ProviderContainer c, String path) async {
    await tester.runAsync(() => c.read(readerProvider.notifier).flush());
    final next = await pumpApp(tester);
    expect(next.read(readerProvider).book, isNull, reason: 'a new app starts with nothing open');
    await tester.runAsync(() => next.read(readerProvider.notifier).open(path));
    await settle(tester);
    return next;
  }

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

  ReaderViewState view(WidgetTester tester) => tester.state<ReaderViewState>(find.byType(ReaderView));

  testWidgets('a restart comes back in guided view on the same panel and balloon mode', (tester) async {
    final path = writeBookOf(tmp, 'Guided 01.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    var c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    // Page 2, panel 3: four panels on page 1, then two more steps.
    for (var i = 0; i < 6; i++) {
      await key(tester, LogicalKeyboardKey.keyL);
    }
    await key(tester, LogicalKeyboardKey.keyB);
    var s = c.read(readerProvider);
    expect((s.guided, s.balloons, s.page, s.panelIndex), (true, true, 1, 2));

    c = await restart(tester, c, path);
    s = c.read(readerProvider);
    expect((s.guided, s.balloons, s.page, s.panelIndex), (true, true, 1, 2));
    expect(status(tester), startsWith('Resumed at page 2, panel 3'));
    expect(s.focus, isNotNull, reason: 'the camera frames the panel, not the page');
  });

  testWidgets('a restart restores the spread, fit, zoom and scroll', (tester) async {
    final path = writeBookOf(tmp, 'Pages.cbz', [for (var i = 0; i < 6; i++) grid4Page()]);
    var c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyD);
    await key(tester, LogicalKeyboardKey.keyL);
    view(tester).handle(const ReaderCommand(ReaderIntent.zoomIn, count: 2));
    view(tester).handle(const ReaderCommand(ReaderIntent.panDown));
    await settle(tester);
    final before = view(tester).transform;
    expect(before.getMaxScaleOnAxis(), closeTo(1.5625, 1e-6));
    expect(c.read(readerProvider).unit, [1, 2]);

    c = await restart(tester, c, path);
    final s = c.read(readerProvider);
    expect((s.guided, s.mode), (false, PageMode.spread));
    expect(s.unit, [1, 2]);
    final after = view(tester).transform;
    expect(after.getMaxScaleOnAxis(), closeTo(1.5625, 1e-6));
    expect(after.getTranslation().x, closeTo(before.getTranslation().x, 0.5));
    expect(after.getTranslation().y, closeTo(before.getTranslation().y, 0.5));

    // Turning the page resets the zoom, and that is what is kept then.
    await key(tester, LogicalKeyboardKey.keyL);
    c = await restart(tester, c, path);
    expect(view(tester).transform.getMaxScaleOnAxis(), closeTo(1, 1e-6));
    expect(c.read(readerProvider).unit, [3, 4]);
  });

  testWidgets('a book never read opens in the mode the reader is in', (tester) async {
    final read = writeBook(tmp, 'Read.cbz', 4);
    final fresh = writeBook(tmp, 'Fresh.cbz', 4);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(read));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyD);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(fresh));
    await settle(tester);
    final s = c.read(readerProvider);
    expect((s.page, s.mode), (0, PageMode.spread));
  });
}
