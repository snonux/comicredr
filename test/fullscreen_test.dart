import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Fullscreen (`f`, F11): only the comic, the window asked to cover the
/// screen, the status line back for a moment when it has something to say.
void main() {
  const window = MethodChannel('org.snonux.comicredr/window');
  late Directory tmp;
  late AppDatabase db;
  late List<MethodCall> asked;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fullscreen_test');
    db = AppDatabase(NativeDatabase.memory());
    asked = [];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<ProviderContainer> openBook(WidgetTester tester, {String name = 'Full.cbz'}) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (call) async {
      asked.add(call);
      return null;
    });
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [databaseProvider.overrideWithValue(db), classicCvOnly],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    final path = writeBook(tmp, name, 6);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    expect(find.byKey(const Key('page-image')), findsOneWidget);
    return c;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {String? character}) async {
    await tester.sendKeyEvent(k, character: character);
    await settle(tester);
  }

  Finder status() => find.byKey(const Key('status'));
  Finder bar() => find.byKey(const Key('progress'));
  List<Object?> windowAsked() => [
    for (final c in asked)
      if (c.method == 'setFullscreen') c.arguments,
  ];

  testWidgets('f and F11: only the page, over the whole window, and back', (tester) async {
    final c = await openBook(tester);
    final screen = tester.getRect(find.byType(Scaffold));
    expect(tester.getRect(find.byType(ReaderView)).height, lessThan(screen.height));

    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    expect(c.read(readerProvider).fullscreen, isTrue);
    expect(windowAsked(), [true]);
    expect(status(), findsNothing);
    expect(bar(), findsNothing);
    expect(tester.getRect(find.byType(ReaderView)), screen);

    await key(tester, LogicalKeyboardKey.f11);
    expect(c.read(readerProvider).fullscreen, isFalse);
    expect(windowAsked(), [true, false]);
    expect(status(), findsOneWidget);
    expect(bar(), findsOneWidget);
  });

  testWidgets('Esc backs out of guided view and the book, staying fullscreen; at the top it leaves', (tester) async {
    final c = await openBook(tester);
    await key(tester, LogicalKeyboardKey.keyV, character: 'v');
    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    expect(c.read(readerProvider).guided, isTrue);

    await key(tester, LogicalKeyboardKey.escape);
    expect(c.read(readerProvider).guided, isFalse);
    expect(c.read(readerProvider).fullscreen, isTrue);

    await key(tester, LogicalKeyboardKey.escape);
    expect(c.read(readerProvider).book, isNull);
    expect(c.read(readerProvider).fullscreen, isTrue, reason: 'the library is fullscreen too');
    expect(windowAsked(), [true]);

    await key(tester, LogicalKeyboardKey.escape);
    expect(c.read(readerProvider).fullscreen, isFalse, reason: 'nothing left to back out of in the library');
    expect(windowAsked(), [true, false]);
  });

  testWidgets('f and F11 in the library', (tester) async {
    final c = await openBook(tester);
    await key(tester, LogicalKeyboardKey.escape);
    expect(c.read(readerProvider).book, isNull);

    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    expect(c.read(readerProvider).fullscreen, isTrue);
    expect(windowAsked(), [true]);
    await key(tester, LogicalKeyboardKey.f11);
    expect(c.read(readerProvider).fullscreen, isFalse);
  });

  testWidgets('a notice shows the status line for a moment', (tester) async {
    await openBook(tester);
    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    expect(status(), findsNothing);

    await key(tester, LogicalKeyboardKey.keyI, character: 'i');
    expect(tester.widget<Text>(status()).data, 'Night filter on');
    final screen = tester.getRect(find.byType(Scaffold));
    expect(tester.getRect(find.byType(ReaderView)), screen, reason: 'the status line comes over the page');

    await tester.pump(const Duration(seconds: 3));
    expect(status(), findsNothing);
  });

  testWidgets('the mouse: the pointer hides at rest, the bottom edge brings the status line', (tester) async {
    await openBook(tester);
    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    final screen = tester.getRect(find.byType(Scaffold));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    MouseCursor cursor() => RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;

    await mouse.addPointer(location: screen.center);
    await mouse.moveTo(screen.center + const Offset(5, 5));
    await tester.pump();
    expect(cursor(), isNot(SystemMouseCursors.none));
    expect(status(), findsNothing, reason: 'moving over the page shows only the pointer');
    await tester.pump(const Duration(seconds: 2));
    expect(cursor(), SystemMouseCursors.none);

    await mouse.moveTo(Offset(screen.center.dx, screen.bottom - 30));
    await tester.pump();
    expect(status(), findsOneWidget);
    expect(bar(), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(status(), findsOneWidget, reason: 'it stays while the mouse is along the bottom');

    await mouse.moveTo(screen.center);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(status(), findsNothing);
    expect(cursor(), SystemMouseCursors.none);
  });

  testWidgets('the window manager leaving fullscreen brings the status line back', (tester) async {
    final c = await openBook(tester);
    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      window.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('fullscreenChanged', false)),
      (_) {},
    );
    await settle(tester);
    expect(c.read(readerProvider).fullscreen, isFalse);
    expect(status(), findsOneWidget);
  });

  testWidgets('a launch into the library comes back fullscreen', (tester) async {
    await openBook(tester);
    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    await key(tester, LogicalKeyboardKey.escape);
    await settle(tester);

    asked.clear();
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [databaseProvider.overrideWithValue(db), classicCvOnly],
        child: const ComicRedrApp(),
      ),
    );
    await settle(tester);
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    expect(c.read(readerProvider).book, isNull);
    expect(c.read(readerProvider).fullscreen, isTrue);
    expect(windowAsked(), [true]);
  });

  testWidgets('fullscreen is remembered for the next launch', (tester) async {
    await openBook(tester);
    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    await settle(tester);

    final c = await openBook(tester, name: 'Next.cbz');
    expect(c.read(readerProvider).fullscreen, isTrue);
    expect(windowAsked().last, true);
    expect(status(), findsNothing);
  });

  testWidgets("the status line stays clear of a phone's system bars", (tester) async {
    // A phone drawing edge to edge: 24 dp status bar, 48 dp navigation bar.
    final dpr = tester.view.devicePixelRatio;
    tester.view.padding = FakeViewPadding(top: 24 * dpr, bottom: 48 * dpr);
    tester.view.viewPadding = FakeViewPadding(top: 24 * dpr, bottom: 48 * dpr);
    addTearDown(tester.view.reset);
    await openBook(tester);
    final screen = tester.getRect(find.byType(Scaffold));
    expect(tester.getRect(bar()).bottom, lessThanOrEqualTo(screen.bottom - 48));
    expect(tester.getRect(status()).bottom, lessThanOrEqualTo(screen.bottom - 48));
    expect(tester.getRect(find.byType(ReaderView)).top, greaterThanOrEqualTo(24));

    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    expect(tester.getRect(find.byType(ReaderView)), screen, reason: 'fullscreen keeps the whole screen');
    await key(tester, LogicalKeyboardKey.keyI, character: 'i');
    expect(
      tester.getRect(status()).bottom,
      lessThanOrEqualTo(screen.bottom - 48),
      reason: 'a notice while the bars are swiped in',
    );
  });

  testWidgets('Android back in a fullscreen library leaves fullscreen before the app', (tester) async {
    final popped = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') popped.add(call.method);
      return null;
    });
    final c = await openBook(tester);
    await key(tester, LogicalKeyboardKey.escape);
    await key(tester, LogicalKeyboardKey.keyF, character: 'f');
    expect(c.read(readerProvider).fullscreen, isTrue);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(c.read(readerProvider).fullscreen, isFalse);
    expect(popped, isEmpty);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(popped, ['SystemNavigator.pop']);
  });

  testWidgets('on a phone the status line has the whole width for its text', (tester) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openBook(tester);
    await key(tester, LogicalKeyboardKey.keyV, character: 'v');
    expect(find.byKey(const Key('balloonsButton')), findsOneWidget);
    // Beside six buttons it had about a hundred pixels: "page 1 / 6  ·  gu…".
    expect(tester.getSize(status()).width, greaterThan(350));
    expect(
      tester.getRect(find.byKey(const Key('fullscreenButton'))).top,
      greaterThan(tester.getRect(status()).bottom - 1),
    );
  });
}
