import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Touch input on the reader: the same gestures a Linux touchscreen and the
/// phone deliver, as pointer events of kind touch.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('touch_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  /// The app with a six-page book open, on page 1.
  Future<ProviderContainer> openBook(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db), classicCvOnly], child: const ComicRedrApp()),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    final path = writeBook(tmp, 'Touch.cbz', 6);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    expect(find.byType(RawImage), findsOneWidget);
    return c;
  }

  Rect view(WidgetTester tester) => tester.getRect(find.byType(ReaderView));
  double scale(WidgetTester tester) =>
      tester.state<ReaderViewState>(find.byType(ReaderView)).transform.getMaxScaleOnAxis();
  double panX(WidgetTester tester) =>
      tester.state<ReaderViewState>(find.byType(ReaderView)).transform.getTranslation().x;

  Future<void> touch(WidgetTester tester, Offset at) async {
    await tester.tapAt(at, kind: PointerDeviceKind.touch);
    await settle(tester);
  }

  /// One finger from [from] by [by] over [ms] milliseconds, in ten steps.
  Future<void> swipe(WidgetTester tester, Offset from, Offset by, {int ms = 300}) async {
    final g = await tester.startGesture(from, kind: PointerDeviceKind.touch);
    var t = Duration.zero;
    for (var i = 0; i < 10; i++) {
      t += Duration(milliseconds: ms ~/ 10);
      await g.moveBy(by / 10, timeStamp: t);
      await tester.pump(Duration(milliseconds: ms ~/ 10));
    }
    await g.up(timeStamp: t);
    await settle(tester);
  }

  testWidgets('tapping the right and left edges turns pages', (tester) async {
    final c = await openBook(tester);
    final r = view(tester);
    await touch(tester, Offset(r.right - 40, r.center.dy));
    expect(c.read(readerProvider).page, 1);
    await touch(tester, Offset(r.right - 40, r.center.dy));
    expect(c.read(readerProvider).page, 2);
    await touch(tester, Offset(r.left + 40, r.center.dy));
    expect(c.read(readerProvider).page, 1);
  });

  testWidgets('swiping left and right turns pages, slow drags and quick flicks alike', (tester) async {
    final c = await openBook(tester);
    final m = view(tester).center;
    await swipe(tester, m + const Offset(200, 0), const Offset(-400, 20));
    expect(c.read(readerProvider).page, 1);
    await swipe(tester, m, const Offset(-60, 0), ms: 40);
    expect(c.read(readerProvider).page, 2);
    await swipe(tester, m - const Offset(200, 0), const Offset(400, -20));
    expect(c.read(readerProvider).page, 1);
    // Mostly vertical, or too short and slow: not a page turn.
    await swipe(tester, m, const Offset(-60, 200));
    await swipe(tester, m, const Offset(-40, 0), ms: 900);
    expect(c.read(readerProvider).page, 1);
  });

  testWidgets('right to left mirrors taps and swipes like the arrow keys', (tester) async {
    final c = await openBook(tester);
    c.read(readerProvider.notifier).state = c.read(readerProvider).copyWith(rightToLeft: true, page: 3);
    await settle(tester);
    final r = view(tester);
    await touch(tester, Offset(r.left + 40, r.center.dy));
    expect(c.read(readerProvider).page, 4);
    await swipe(tester, r.center - const Offset(200, 0), const Offset(400, 0));
    expect(c.read(readerProvider).page, 5);
  });

  testWidgets('pinching with two fingers zooms, and a drag then pans instead of turning', (tester) async {
    final c = await openBook(tester);
    final m = view(tester).center;
    final a = await tester.startGesture(m - const Offset(50, 0), kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(m + const Offset(50, 0), kind: PointerDeviceKind.touch, pointer: 7);
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-15, 0));
      await b.moveBy(const Offset(15, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await settle(tester);
    expect(scale(tester), greaterThan(2));
    expect(c.read(readerProvider).page, 0, reason: 'a pinch is not a swipe or a tap');

    final before = panX(tester);
    await swipe(tester, m, const Offset(-150, 0));
    expect(panX(tester), lessThan(before));
    expect(c.read(readerProvider).page, 0, reason: 'the drag panned the zoomed page');
  });

  testWidgets('double-tapping the middle zooms on that spot and back out', (tester) async {
    final c = await openBook(tester);
    final m = view(tester).center;
    await tester.tapAt(m, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(m, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 500));
    expect(scale(tester), closeTo(2.44, 0.01));
    expect(c.read(readerProvider).fullscreen, isFalse, reason: 'the double-tap is not also a single tap');

    await tester.tapAt(m, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(m, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 500));
    expect(scale(tester), 1);
  });

  testWidgets('a single tap in the middle hides and shows the status line', (tester) async {
    final c = await openBook(tester);
    final m = view(tester).center;
    await tester.tapAt(m, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.read(readerProvider).fullscreen, isTrue);
    expect(find.byKey(const Key('status')), findsNothing);
    await tester.tapAt(view(tester).center, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.read(readerProvider).fullscreen, isFalse);
  });

  testWidgets('a touchpad pinch zooms', (tester) async {
    await openBook(tester);
    final m = view(tester).center;
    final g = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await g.panZoomStart(m);
    await g.panZoomUpdate(m, scale: 2);
    await g.panZoomEnd();
    await tester.pump();
    expect(scale(tester), closeTo(2, 0.01));
  });

  testWidgets('mouse clicks do not turn pages', (tester) async {
    final c = await openBook(tester);
    final r = view(tester);
    await tester.tapAt(Offset(r.right - 40, r.center.dy), kind: PointerDeviceKind.mouse);
    await tester.tapAt(r.center, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.read(readerProvider).page, 0);
    expect(c.read(readerProvider).fullscreen, isFalse);
  });
}
