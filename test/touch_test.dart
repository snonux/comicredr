import 'dart:async';
import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/input/touch_providers.dart';
import 'package:comicredr/src/library/library_screen.dart';
import 'package:comicredr/src/library/settings_dialog.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:comicredr/src/reader/region.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

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
  Future<ProviderContainer> openBook(WidgetTester tester, {String? keysToml}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          classicCvOnly,
          if (keysToml != null)
            keymapLoadProvider.overrideWithValue((load: keymapFromToml(keysToml), path: 'keys.toml')),
        ],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    final path = writeBook(tmp, 'Touch.cbz', 6);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    expect(find.byKey(const Key('page-image')), findsOneWidget);
    return c;
  }

  Rect view(WidgetTester tester) => tester.getRect(find.byType(ReaderView));
  double scale(WidgetTester tester) =>
      tester.state<ReaderViewState>(find.byType(ReaderView)).transform.getMaxScaleOnAxis();
  double panX(WidgetTester tester) =>
      tester.state<ReaderViewState>(find.byType(ReaderView)).transform.getTranslation().x;

  Future<void> touch(WidgetTester tester, Offset at) async {
    await tester.tapAt(at, kind: PointerDeviceKind.touch);
    await tester.pump(kDoubleTapTimeout);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
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

  testWidgets('a custom double-tap still zooms on that spot and back out', (tester) async {
    final c = await openBook(tester, keysToml: '[touch]\ndoubleTap = "zoomToggle"\n');
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

  testWidgets('double-tapping any reader zone toggles fullscreen once without turning or zooming', (tester) async {
    final c = await openBook(tester);
    c.read(readerProvider.notifier).state = c.read(readerProvider).copyWith(page: 2);
    await settle(tester);
    var toggles = 0;
    final sub = c.listen(readerProvider.select((s) => s.fullscreen), (_, _) => toggles++);
    addTearDown(sub.close);
    for (final zone in TouchZone.values) {
      for (final fullscreen in [true, false]) {
        final r = view(tester);
        final at = Offset(r.left + r.width * (zone.column + 0.5) / 3, r.top + r.height * (zone.row + 0.5) / 3);
        final before = toggles;
        await tester.tapAt(at, kind: PointerDeviceKind.touch);
        await tester.pump(const Duration(milliseconds: 100));
        expect(toggles, before, reason: 'the single tap waits for a possible double-tap');
        await tester.tapAt(at, kind: PointerDeviceKind.touch);
        await tester.pump(const Duration(milliseconds: 500));
        expect(c.read(readerProvider).fullscreen, fullscreen, reason: zone.name);
        expect(toggles, before + 1, reason: 'one toggle, with no delayed single tap in ${zone.name}');
        expect(c.read(readerProvider).page, 2, reason: zone.name);
        expect(scale(tester), 1, reason: zone.name);
      }
    }
  }, variant: const TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.android}));

  testWidgets('nearby double-taps across zone boundaries toggle once without turning', (tester) async {
    final c = await openBook(tester);
    c.read(readerProvider.notifier).state = c.read(readerProvider).copyWith(page: 2);
    await settle(tester);
    var toggles = 0;
    final sub = c.listen(readerProvider.select((s) => s.fullscreen), (_, _) => toggles++);
    addTearDown(sub.close);
    for (final (x, y, offset) in [
      (TouchZone.edge, 0.5, const Offset(2, 0)),
      (1 - TouchZone.edge, 0.5, const Offset(2, 0)),
      (0.5, 1 / 3, const Offset(0, 2)),
      (0.5, 2 / 3, const Offset(0, 2)),
    ]) {
      for (final direction in [-1, 1]) {
        for (final fullscreen in [true, false]) {
          final r = view(tester);
          final border = Offset(r.left + r.width * x, r.top + r.height * y);
          final before = toggles;
          await tester.tapAt(border + offset * direction.toDouble(), kind: PointerDeviceKind.touch);
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tapAt(border - offset * direction.toDouble(), kind: PointerDeviceKind.touch);
          await tester.pump(const Duration(milliseconds: 500));
          expect(c.read(readerProvider).fullscreen, fullscreen, reason: '$x,$y direction $direction');
          expect(toggles, before + 1, reason: 'one toggle across the boundary');
          expect(c.read(readerProvider).page, 2, reason: 'neither tap turns the page');
          expect(scale(tester), 1);
        }
      }
    }
  }, variant: const TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.android}));

  testWidgets('nearby taps across zones with different custom double-tap actions stay single taps', (tester) async {
    final c = await openBook(
      tester,
      keysToml: '''
[touch]
tap = "nextStep"
doubleTap = ["zoomToggle", "fullscreen", "zoomToggle", "zoomToggle", "fullscreen", "zoomToggle", "zoomToggle", "fullscreen", "zoomToggle"]
''',
    );
    final r = view(tester);
    final border = Offset(r.left + r.width * (1 - TouchZone.edge), r.center.dy);
    await tester.tapAt(border + const Offset(2, 0), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(border - const Offset(2, 0), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(c.read(readerProvider).page, 2, reason: 'different actions do not form one double-tap');
    expect(c.read(readerProvider).fullscreen, isFalse);
    expect(scale(tester), 1);
  });

  testWidgets('double-taps still respect distance and time limits', (tester) async {
    final c = await openBook(tester, keysToml: '[touch]\ntap = "nextStep"\n');
    final r = view(tester);
    final at = r.center;
    await tester.tapAt(at, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(at + const Offset(kDoubleTapSlop + 1, 0), kind: PointerDeviceKind.touch);
    await tester.pump(kDoubleTapTimeout);
    await settle(tester);
    expect(c.read(readerProvider).page, 2, reason: 'distant taps stay separate');
    expect(c.read(readerProvider).fullscreen, isFalse);
    await tester.tapAt(at, kind: PointerDeviceKind.touch);
    await tester.pump(kDoubleTapTimeout);
    await tester.tapAt(at, kind: PointerDeviceKind.touch);
    await tester.pump(kDoubleTapTimeout);
    await settle(tester);
    expect(c.read(readerProvider).page, 4, reason: 'late taps stay separate');
    expect(c.read(readerProvider).fullscreen, isFalse);
  });

  testWidgets('the fit button fits the width and the whole page again', (tester) async {
    final c = await openBook(tester);
    ReaderViewState v() => tester.state<ReaderViewState>(find.byType(ReaderView));
    final button = find.byKey(const Key('fitButton'));
    expect(v().spot.fit, 'page');
    expect(tester.widget<IconButton>(button).tooltip, 'Fit width (zw)');
    await tester.tap(button);
    await settle(tester);
    expect(v().spot.fit, 'width');
    expect(tester.widget<IconButton>(button).tooltip, 'Fit the whole page (zz)');
    expect(c.read(viewFitProvider), Fit.width);
    // One finger scrolls the page fitted to the width, and turns nothing.
    final before = v().transform.getTranslation().y;
    await swipe(tester, view(tester).center, const Offset(0, -150));
    expect(v().transform.getTranslation().y, lessThan(before));
    expect(c.read(readerProvider).page, 0);
    await tester.tap(button);
    await settle(tester);
    expect(v().spot.fit, 'page');
    // Guided view frames panels: no fit to pick there.
    await c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.toggleGuided));
    await settle(tester);
    expect(button, findsNothing);
  });

  testWidgets('a swipe down fits the width; there one finger scrolls up and down only', (tester) async {
    final c = await openBook(tester);
    ReaderViewState v() => tester.state<ReaderViewState>(find.byType(ReaderView));
    final r = view(tester);
    await swipe(tester, r.center - const Offset(0, 150), const Offset(0, 300));
    expect(v().spot.fit, 'width');
    expect(c.read(viewFitProvider), Fit.width);
    expect(c.read(readerProvider).page, 0);
    // A drag aslant: the page goes up, never sideways.
    final before = v().transform.getTranslation();
    await swipe(tester, r.center, const Offset(-120, -160));
    final after = v().transform.getTranslation();
    expect(after.y, lessThan(before.y));
    expect(after.x, before.x);
    expect(c.read(readerProvider).page, 0);
    // A page turned by key while the drag's inertia still runs starts at
    // its top too, and back again.
    await swipe(tester, r.center, const Offset(0, -100));
    await c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.nextStep));
    await settle(tester);
    expect(v().transform.getTranslation().y, 0, reason: 'the next page starts at its top');
    await c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.prevStep));
    await settle(tester);
    await swipe(tester, r.center, const Offset(0, -160));
    // A swipe sideways turns the page, as on a page that fits, and the
    // next page starts at its top, still fitted to the width.
    await swipe(tester, r.center + const Offset(100, 0), const Offset(-300, 0));
    expect(c.read(readerProvider).page, 1);
    expect(v().spot.fit, 'width');
    expect(v().transform.getTranslation().x, 0);
    expect(v().transform.getTranslation().y, 0, reason: 'the next page starts at its top');
    // A swipe down scrolls back up while there is page above; at the top it
    // brings the whole page back.
    await swipe(tester, r.center, const Offset(0, -200));
    await swipe(tester, r.center - const Offset(0, 150), const Offset(0, 300));
    expect(v().spot.fit, 'width', reason: 'the swipe scrolled the page back to its top');
    expect(v().transform.getTranslation().y, 0);
    await swipe(tester, r.center - const Offset(0, 150), const Offset(0, 300));
    expect(v().spot.fit, 'page');
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

  testWidgets('the left-handed preset turns the edges round', (tester) async {
    final c = await openBook(tester);
    await tester.runAsync(() => c.read(touchPresetProvider.notifier).pick(TouchPreset.leftHanded));
    final r = view(tester);
    await touch(tester, Offset(r.left + 40, r.center.dy));
    await touch(tester, Offset(r.left + 40, r.top + 40));
    expect(c.read(readerProvider).page, 2);
    await touch(tester, Offset(r.right - 40, r.bottom - 40));
    expect(c.read(readerProvider).page, 1);
    // Swipes stay as they were.
    await swipe(tester, r.center + const Offset(200, 0), const Offset(-400, 0));
    expect(c.read(readerProvider).page, 2);
    final saved = await tester.runAsync(() => c.read(settingsStoreProvider).loadString(SettingsStore.touchPreset));
    expect(saved, 'leftHanded');
  });

  testWidgets('keys.toml [touch] lines: a zone, a long press, vertical swipes and a two-finger tap', (tester) async {
    final c = await openBook(
      tester,
      keysToml: """
[touch]
tap = [
  "lastPage", "fullscreen", "nextStep",
  "prevStep", "fullscreen", "nextStep",
  "prevStep", "fullscreen", "nextStep",
]
longPress = "nightFilter"
swipeUp = "nextPage"
swipeDown = "firstPage"
twoFingerTap = "autoTrim"
""",
    );
    final r = view(tester);
    await touch(tester, Offset(r.left + 40, r.top + 40));
    expect(c.read(readerProvider).page, 5, reason: 'the top-left zone now goes to the last page');
    await swipe(tester, r.center, const Offset(10, 300));
    expect(c.read(readerProvider).page, 0);
    await swipe(tester, r.center, const Offset(-10, -300));
    expect(c.read(readerProvider).page, 1);

    // Hold without moving: the long press fires while the finger is down.
    final hold = await tester.startGesture(r.center, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 600));
    expect(c.read(readerProvider).night, isTrue);
    await hold.up();
    await settle(tester);
    expect(c.read(readerProvider).fullscreen, isFalse, reason: 'a long press is not also a tap');

    final trim = c.read(readerProvider).trim;
    final a = await tester.startGesture(r.center - const Offset(60, 0), kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(r.center + const Offset(60, 0), kind: PointerDeviceKind.touch, pointer: 9);
    await tester.pump(const Duration(milliseconds: 80));
    await a.up();
    await b.up();
    await settle(tester);
    expect(c.read(readerProvider).trim, !trim);
    expect(c.read(readerProvider).page, 1);
    expect(c.read(readerProvider).fullscreen, isFalse);
    expect(scale(tester), 1);
  });

  testWidgets('a two-finger tap picks a part of the page; taps then step part by part', (tester) async {
    final c = await openBook(tester);
    Future<void> twoFingers() async {
      final r = view(tester);
      final a = await tester.startGesture(r.center - const Offset(60, 0), kind: PointerDeviceKind.touch);
      final b = await tester.startGesture(r.center + const Offset(60, 0), kind: PointerDeviceKind.touch, pointer: 9);
      await tester.pump(const Duration(milliseconds: 80));
      await a.up();
      await b.up();
      await settle(tester);
    }

    await twoFingers();
    expect(find.byKey(const Key('partsPicker')), findsOneWidget);
    // Halves first; thirds picked, then the middle one.
    expect(find.byKey(const Key('part-22')), findsOneWidget);
    await tester.tap(find.byKey(const Key('split-thirds')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('part-32')));
    await settle(tester);
    expect(find.byKey(const Key('partsPicker')), findsNothing);
    var s = c.read(readerProvider);
    expect((s.region?.split, s.region?.part, s.parts), (PageSplit.thirds, 1, PageSplit.thirds));

    // The right edge goes on as → does: the lower third, the page whole,
    // then the next page whole and its upper third.
    final r = view(tester);
    await touch(tester, Offset(r.right - 40, r.center.dy));
    expect(c.read(readerProvider).region?.part, 2);
    await touch(tester, Offset(r.right - 40, r.center.dy));
    s = c.read(readerProvider);
    expect((s.page, s.region), (0, null));
    await touch(tester, Offset(r.right - 40, r.center.dy));
    await touch(tester, Offset(r.right - 40, r.center.dy));
    s = c.read(readerProvider);
    expect((s.page, s.region?.part), (1, 0));
    // And the left edge back, as ←.
    await touch(tester, Offset(r.left + 40, r.center.dy));
    expect((c.read(readerProvider).page, c.read(readerProvider).region), (1, null));

    // Opened again it shows the split being stepped through; Stop leaves it.
    await twoFingers();
    expect(find.byKey(const Key('part-33')), findsOneWidget);
    await tester.tap(find.byKey(const Key('partsStop')));
    await settle(tester);
    expect(c.read(readerProvider).parts, isNull);
    expect(find.byKey(const Key('partsPicker')), findsNothing);

    // A tap beside the card closes it without picking anything.
    await twoFingers();
    await tester.tapAt(view(tester).topLeft + const Offset(4, 4));
    await settle(tester);
    expect(find.byKey(const Key('partsPicker')), findsNothing);
    expect(c.read(readerProvider).parts, isNull);
    expect(c.read(readerProvider).page, 1);
  });

  testWidgets('the parts picker fits a small phone, quarters included; the status line has no button there', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await openBook(tester);
    expect(find.byKey(const Key('partsButton')), findsNothing);
    await c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.regionBottomRight));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await settle(tester);
    expect(find.byKey(const Key('partsPicker')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'nothing overflows');
    expect(find.byKey(const Key('part-54')), findsOneWidget, reason: 'opens on the split being stepped through');
    for (final k in ['split-halves', 'split-thirds', 'split-strips', 'split-quarters']) {
      expect(tester.getRect(find.byKey(Key(k))).right, lessThanOrEqualTo(360));
    }
    await tester.tap(find.byKey(const Key('part-51')));
    await settle(tester);
    expect(c.read(readerProvider).region?.part, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wider window has a status line button for the picker; Esc closes it', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await openBook(tester);
    await tester.tap(find.byKey(const Key('partsButton')));
    await settle(tester);
    expect(find.byKey(const Key('partsPicker')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const Key('partsPicker')), findsNothing);
    expect(c.read(readerProvider).book, isNotNull, reason: 'Esc only closed the picker');
  });

  testWidgets('a double-tap only waits in zones that have one', (tester) async {
    final c = await openBook(tester, keysToml: '[touch]\ndoubleTap = ["zoomToggle", "", "", "", "", "", "", "", ""]\n');
    final r = view(tester);
    // The middle has no double-tap now, so its tap acts at once.
    await tester.tapAt(r.center, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(c.read(readerProvider).fullscreen, isTrue);
    await tester.tapAt(r.center, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(c.read(readerProvider).fullscreen, isFalse);
    // The top-left zone waits: two taps zoom instead of going back twice.
    final corner = Offset(r.left + 40, r.top + 40);
    await tester.tapAt(corner, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(corner, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 500));
    expect(scale(tester), closeTo(2.44, 0.01));
    expect(c.read(readerProvider).page, 0);
  });

  testWidgets('gt shows the touch zones for a moment', (tester) async {
    final c = await openBook(tester);
    await tester.runAsync(() => c.read(touchPresetProvider.notifier).pick(TouchPreset.oneThumb));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    expect(find.byKey(const Key('touch-zones')), findsOneWidget);
    expect(find.text('Next'), findsNWidgets(5));
    expect(find.text('Back'), findsNWidgets(3));
    expect(find.text('Double-tap: Status line'), findsNWidgets(9));
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('touch-zones')), findsNothing);
  });

  testWidgets('picking a preset in Settings shows its zones on the next book opened', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db), classicCvOnly], child: const ComicRedrApp()),
    );
    await settle(tester);
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    // An empty library has no toolbar, so open the dialog straight away.
    unawaited(showSettings(tester.element(find.byType(LibraryScreen))));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('setting-touch-leftHanded')));
    await tester.tap(find.byKey(const Key('setting-touch-leftHanded')));
    await settle(tester);
    expect(c.read(touchPresetProvider), TouchPreset.leftHanded);
    expect(find.textContaining('Mirrored for the left thumb'), findsOneWidget);
    await tester.tap(find.byKey(const Key('setting-close')));
    await settle(tester);
    final path = writeBook(tmp, 'Zones.cbz', 3);
    // Opened under the fake clock, where the settings dialog already used
    // the database: under runAsync this open never finished.
    unawaited(c.read(readerProvider.notifier).open(path));
    for (var i = 0; i < 40 && find.byKey(const Key('touch-zones')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.byKey(const Key('touch-zones')), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('touch-zones')), findsNothing);
  });

  testWidgets("Settings' choices drop the tick on a phone, where it broke words", (tester) async {
    // The test font's wide glyphs wrap either way, so this checks the tick;
    // on the emulator "Colour" and "Standard" were split mid-word by it.
    Future<bool> ticks(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [databaseProvider.overrideWithValue(db), classicCvOnly],
          child: const ComicRedrApp(),
        ),
      );
      await settle(tester);
      unawaited(showSettings(tester.element(find.byType(LibraryScreen))));
      await settle(tester);
      final shown = [
        for (final key in ['setting-pauseSeconds', 'setting-sidecarPlace', 'setting-touch'])
          tester.widget<SegmentedButton<Object?>>(find.byKey(Key(key))).showSelectedIcon,
      ];
      expect(shown.toSet(), hasLength(1));
      return shown.first;
    }

    addTearDown(tester.view.reset);
    expect(await ticks(const Size(411, 914)), isFalse);
    expect(await ticks(const Size(1280, 800)), isTrue);
  });
}
