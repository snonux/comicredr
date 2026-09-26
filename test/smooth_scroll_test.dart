import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

/// The arrow keys (and j k) on a zoomed page glide instead of jumping; Left
/// and Right pan across it and turn the page only from its edge.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('smooth_scroll_test');
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

  ReaderViewState view(WidgetTester tester) => tester.state<ReaderViewState>(find.byType(ReaderView));
  Offset shift(WidgetTester tester) {
    final t = view(tester).transform.getTranslation();
    return Offset(t.x, t.y);
  }

  Future<ProviderContainer> openZoomed(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final path = writeBookOf(tmp, 'Pages.cbz', [for (var i = 0; i < 3; i++) grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    view(tester).handle(const ReaderCommand(ReaderIntent.zoomIn, count: 8));
    await settle(tester);
    return c;
  }

  testWidgets('Down on a zoomed page glides a step instead of jumping', (tester) async {
    await openZoomed(tester);
    final start = shift(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final part = start.dy - shift(tester).dy;
    await settle(tester);
    final whole = start.dy - shift(tester).dy;
    expect(whole, inInclusiveRange(0.13 * 900, 0.15 * 900), reason: 'a step is 15% of the page area');
    expect(part, inExclusiveRange(1, whole - 1), reason: 'part of the way after two frames');
    expect(shift(tester).dx, start.dx);

    // j is the same step, and Up comes back.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ, character: 'j');
    await settle(tester);
    expect(start.dy - shift(tester).dy, closeTo(2 * whole, 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settle(tester);
    expect(shift(tester).dy, closeTo(start.dy, 0.5));
  });

  testWidgets('Left and Right pan a zoomed page, and turn only from its edge', (tester) async {
    final c = await openZoomed(tester);
    final start = shift(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(c.read(readerProvider).page, 0);
    expect(start.dx - shift(tester).dx, inInclusiveRange(0.13 * 1200, 0.15 * 1200));

    // Held down: the repeats glide on to the right edge and stop there.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 200; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 33));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).page, 0, reason: 'a held key stops at the edge');
    await settle(tester);
    final edge = shift(tester).dx;
    expect(edge, lessThan(start.dx - 0.3 * 1200));

    // Pressed again at the edge: the next page.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(c.read(readerProvider).page, 1);

    // Unzoomed, Left and Right step as they always did.
    view(tester).handle(const ReaderCommand(ReaderIntent.zoomReset));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(c.read(readerProvider).page, 0);
  });

  testWidgets('with reduced motion a step is a jump', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await openZoomed(tester);
    final start = shift(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(start.dy - shift(tester).dy, inInclusiveRange(0.13 * 900, 0.15 * 900));
  });
}
