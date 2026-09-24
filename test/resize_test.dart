import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

/// A window resized on the laptop, or the phone turned on its side: the
/// reader keeps its page, zoom and panel and fits them to the new size.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('resize_test');
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

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
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  void resize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
  }

  ReaderViewState view(WidgetTester tester) => tester.state<ReaderViewState>(find.byType(ReaderView));
  Size page(WidgetTester tester) => tester.getSize(find.byKey(const Key('page-image')));

  testWidgets('a resized window keeps the page, zoom and the point in the middle', (tester) async {
    resize(tester, const Size(1200, 900));
    addTearDown(tester.view.reset);
    final path = writeBookOf(tmp, 'Pages.cbz', [for (var i = 0; i < 4; i++) grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyL);
    view(tester).handle(const ReaderCommand(ReaderIntent.zoomIn, count: 2));
    view(tester).handle(const ReaderCommand(ReaderIntent.panDown));
    await settle(tester);
    final before = view(tester).spot;
    final shown = page(tester);

    // Dragged a few frames, as a window edge is, then let go.
    for (final w in [1100.0, 900.0, 700.0, 500.0]) {
      resize(tester, Size(w, 900));
      await tester.pump();
    }
    await settle(tester);

    expect(c.read(readerProvider).page, 1);
    expect(page(tester).width, lessThan(shown.width), reason: 'the page fits the narrower window');
    final after = view(tester).spot;
    expect(after.zoom, closeTo(before.zoom, 1e-6));
    expect(after.cx, closeTo(before.cx, 0.01));
    expect(after.cy, closeTo(before.cy, 0.01));
  });

  testWidgets('turned on its side, guided view frames the same panel for the new screen', (tester) async {
    resize(tester, const Size(720, 1280));
    addTearDown(tester.view.reset);
    final path = writeBookOf(tmp, 'Guided.cbz', [grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyV);
    await key(tester, LogicalKeyboardKey.keyL);
    await key(tester, LogicalKeyboardKey.keyL);
    final s = c.read(readerProvider);
    expect((s.guided, s.page, s.panelIndex), (true, 0, 2));
    final portrait = view(tester).transform;

    resize(tester, const Size(1280, 720));
    await settle(tester);
    final t = c.read(readerProvider);
    expect((t.guided, t.page, t.panelIndex), (true, 0, 2));
    expect(t.focus, s.focus);
    final landscape = view(tester).transform;
    expect(landscape, isNot(portrait), reason: 'the camera re-framed the panel');

    // Re-centring by hand (zz) frames it exactly as the rotation did.
    view(tester).handle(const ReaderCommand(ReaderIntent.zoomReset));
    await settle(tester);
    final recentred = view(tester).transform;
    for (var i = 0; i < 16; i++) {
      expect(recentred.storage[i], closeTo(landscape.storage[i], 0.5));
    }

    // And back upright.
    resize(tester, const Size(720, 1280));
    await settle(tester);
    expect(c.read(readerProvider).panelIndex, 2);
    for (var i = 0; i < 16; i++) {
      expect(view(tester).transform.storage[i], closeTo(portrait.storage[i], 0.5));
    }
  });
}
