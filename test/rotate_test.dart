import 'dart:io';
import 'dart:math';

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

/// The comic turned in quarter turns (`>`, `<`, `gr`): the page is drawn
/// turned, guided view frames its panels turned, zoom, pans and parts of the
/// page follow the screen, and the turn stays with the book.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('rotate_test');
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

  Future<void> type(WidgetTester tester, String keys) async {
    for (final ch in keys.split('')) {
      final k = switch (ch) {
        '>' => LogicalKeyboardKey.period,
        '<' => LogicalKeyboardKey.comma,
        _ when ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39 => LogicalKeyboardKey(
          LogicalKeyboardKey.digit0.keyId + ch.codeUnitAt(0) - 0x30,
        ),
        _ => LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + ch.codeUnitAt(0) - 0x61),
      };
      await tester.sendKeyEvent(k, character: ch);
    }
    await settle(tester);
  }

  void resize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
  }

  ReaderViewState view(WidgetTester tester) => tester.state<ReaderViewState>(find.byType(ReaderView));

  RenderBox pageBox(WidgetTester tester) => tester.renderObject<RenderBox>(find.byKey(const Key('page-image')));

  /// Where [part] (fractions of the page) is on the screen, zoom and turn
  /// and all: the box around its four corners.
  Rect onScreen(WidgetTester tester, [Rect part = const Rect.fromLTWH(0, 0, 1, 1)]) {
    final box = pageBox(tester);
    final s = box.size;
    final corners = [
      for (final (x, y) in [
        (part.left, part.top),
        (part.right, part.top),
        (part.left, part.bottom),
        (part.right, part.bottom),
      ])
        box.localToGlobal(Offset(x * s.width, y * s.height)),
    ];
    final xs = corners.map((c) => c.dx), ys = corners.map((c) => c.dy);
    return Rect.fromLTRB(
      xs.reduce((a, b) => a < b ? a : b),
      ys.reduce((a, b) => a < b ? a : b),
      xs.reduce((a, b) => a > b ? a : b),
      ys.reduce((a, b) => a > b ? a : b),
    );
  }

  /// The point of the page (fractions of it) at [screen].
  Offset pageAt(WidgetTester tester, Offset screen) {
    final box = pageBox(tester);
    final p = box.globalToLocal(screen);
    return Offset(p.dx / box.size.width, p.dy / box.size.height);
  }

  /// The page's own top-left corner on the screen.
  Offset cornerOnScreen(WidgetTester tester) => pageBox(tester).localToGlobal(Offset.zero);

  testWidgets('> < and gr turn the page on screen, and a count turns it more', (tester) async {
    resize(tester, const Size(1200, 900));
    addTearDown(tester.view.reset);
    final path = writeBookOf(tmp, 'Turn.cbz', [for (var i = 0; i < 3; i++) grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    final upright = onScreen(tester);
    expect(upright.height, greaterThan(upright.width), reason: 'a 400 x 600 page stands tall');

    await type(tester, '>');
    expect(c.read(readerProvider).rotation, 1);
    final turned = onScreen(tester);
    expect(turned.width, greaterThan(turned.height), reason: 'turned a quarter, it lies on its side');
    expect(turned.width / turned.height, closeTo(600 / 400, 0.02));
    // Clockwise: the page's top left went to the top right.
    final corner = cornerOnScreen(tester);
    expect(corner.dx, closeTo(turned.right, 1));
    expect(corner.dy, closeTo(turned.top, 1));

    await type(tester, '<');
    expect(c.read(readerProvider).rotation, 0);
    await type(tester, '<');
    expect(c.read(readerProvider).rotation, 3);
    expect(
      cornerOnScreen(tester).dy,
      closeTo(onScreen(tester).bottom, 1),
      reason: 'the top left went to the bottom left',
    );
    await type(tester, '2>');
    expect(c.read(readerProvider).rotation, 1);
    await type(tester, '>');
    final bottomRight = onScreen(tester).bottomRight;
    expect(cornerOnScreen(tester).dx, closeTo(bottomRight.dx, 1));
    expect(cornerOnScreen(tester).dy, closeTo(bottomRight.dy, 1));
    await type(tester, 'gr');
    expect(c.read(readerProvider).rotation, 0);
    expect(onScreen(tester).size, upright.size);
  });

  testWidgets('the turn stays across page turns and a reopen, and is per book', (tester) async {
    resize(tester, const Size(1200, 900));
    addTearDown(tester.view.reset);
    final a = writeBookOf(tmp, 'A.cbz', [for (var i = 0; i < 3; i++) grid4Page()]);
    // Other pages, so another content key: the same pages would be the same comic.
    final b = writeBookOf(tmp, 'B.cbz', [
      for (var i = 0; i < 3; i++) gridPage(400, 600, [(20, 20, 360, 560)]),
    ]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(a));
    await settle(tester);
    await type(tester, '>');
    await type(tester, 'l');
    expect((c.read(readerProvider).page, c.read(readerProvider).rotation), (1, 1));
    expect(onScreen(tester).width, greaterThan(onScreen(tester).height));

    await tester.runAsync(() => c.read(readerProvider.notifier).open(b));
    await settle(tester);
    expect(c.read(readerProvider).rotation, 0, reason: 'another book opens upright');
    expect(onScreen(tester).height, greaterThan(onScreen(tester).width));

    await tester.runAsync(() => c.read(readerProvider.notifier).open(a));
    await settle(tester);
    expect((c.read(readerProvider).page, c.read(readerProvider).rotation), (1, 1));
    expect(onScreen(tester).width, greaterThan(onScreen(tester).height));
  });

  testWidgets('guided view frames each panel turned, and keeps the turn on the next page', (tester) async {
    resize(tester, const Size(1200, 900));
    addTearDown(tester.view.reset);
    final path = writeBookOf(tmp, 'Guided.cbz', [grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await type(tester, 'v');
    await type(tester, '>');
    final screen = tester.getRect(find.byType(ReaderView));
    for (var n = 0; n < 6; n++) {
      final s = c.read(readerProvider);
      expect(s.rotation, 1);
      final f = s.focus!;
      // The panel, in fractions of the page (the fixture's page is 400 x 600).
      final panel = onScreen(tester, Rect.fromLTWH(f.x, f.y, f.w, f.h));
      expect(
        screen.inflate(2).contains(panel.topLeft) && screen.inflate(2).contains(panel.bottomRight),
        isTrue,
        reason: 'page ${s.page + 1} panel ${s.panelIndex + 1} is on screen: $panel in $screen',
      );
      expect(panel.center.dx, closeTo(screen.center.dx, 2));
      expect(panel.center.dy, closeTo(screen.center.dy, 2));
      // A 170 x 270 panel turned is wider than tall, and fills the screen's height or width.
      expect(panel.width, greaterThan(panel.height));
      expect(panel.height > screen.height * 0.8 || panel.width > screen.width * 0.8, isTrue);
      await type(tester, 'l');
    }
    expect(c.read(readerProvider).page, 1, reason: 'stepped onto the second page, still turned');
  });

  testWidgets('j pans down the screen and a double-tap zooms where it lands, turned or not', (tester) async {
    resize(tester, const Size(1200, 900));
    addTearDown(tester.view.reset);
    final path = writeBookOf(tmp, 'Pan.cbz', [grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    final origin = tester.getTopLeft(find.byType(ReaderView));
    final middle = tester.getRect(find.byType(ReaderView)).center;
    for (final turns in [1, 2, 3]) {
      await type(tester, 'gr');
      for (var i = 0; i < turns; i++) {
        await type(tester, '>');
      }
      expect(c.read(readerProvider).rotation, turns);
      // A double-tap left of the middle keeps that spot of the page under the finger.
      final tap = middle + const Offset(-150, 60);
      final under = pageAt(tester, tap);
      view(tester).handle(ReaderCommand(ReaderIntent.zoomToggle, at: Point(tap.dx - origin.dx, tap.dy - origin.dy)));
      await settle(tester);
      final after = pageAt(tester, tap);
      expect(after.dx, closeTo(under.dx, 0.01), reason: 'turns $turns');
      expect(after.dy, closeTo(under.dy, 0.01), reason: 'turns $turns');

      // j: what was a little below the middle comes up to it.
      final below = pageAt(tester, middle + const Offset(0, 90));
      await type(tester, 'j');
      final now = pageAt(tester, middle);
      expect(now.dx, closeTo(below.dx, 0.02), reason: 'turns $turns');
      expect(now.dy, closeTo(below.dy, 0.02), reason: 'turns $turns');
      await type(tester, 'zz');
    }
  });

  testWidgets('fit width fits the page to the screen width and starts at its top, turned', (tester) async {
    resize(tester, const Size(900, 1200));
    addTearDown(tester.view.reset);
    final path = writeBookOf(tmp, 'Fit.cbz', [grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    final screen = tester.getRect(find.byType(ReaderView));
    for (final turns in [1, 2, 3]) {
      await type(tester, 'gr');
      for (var i = 0; i < turns; i++) {
        await type(tester, '>');
      }
      await type(tester, 'zw');
      final page = onScreen(tester);
      expect(page.width, closeTo(screen.width, 1), reason: 'turns $turns');
      expect(page.top, closeTo(screen.top, 1), reason: 'turns $turns: the top of the page as seen is at the top');
      expect(page.left, closeTo(screen.left, 1), reason: 'turns $turns');
      await type(tester, 'zz');
    }
  });

  testWidgets('H1 is the upper half of the page as it is seen', (tester) async {
    resize(tester, const Size(1200, 900));
    addTearDown(tester.view.reset);
    final path = writeBookOf(tmp, 'Half.cbz', [grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    await type(tester, '>');
    final whole = onScreen(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH, character: 'H');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1, character: '1');
    await settle(tester);
    expect(c.read(readerProvider).region, isNotNull);
    // The page's left half (its own coordinates) is the top of it as seen,
    // and fills the screen now.
    final seenTop = onScreen(tester, const Rect.fromLTWH(0, 0, 0.5, 1));
    final screen = tester.getRect(find.byType(ReaderView));
    expect(seenTop.center.dx, closeTo(screen.center.dx, 2));
    expect(seenTop.center.dy, closeTo(screen.center.dy, 2));
    expect(seenTop.width, greaterThan(whole.width * 0.9), reason: 'enlarged to the screen width');
  });
}
