import 'dart:convert';
import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart' hide Override;
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/help_zoom.dart';
import 'package:comicredr/src/keymap_overlay.dart';
import 'package:comicredr/src/library/cover_card.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

/// The `?` help's text size (task 163): `+` `-` `=`, Ctrl and the wheel and
/// a pinch in the help, kept as `help.textSize` across restarts. Every key
/// goes in as a key event, the way a keyboard sends it.
void main() {
  late Directory tmp;
  late Directory root;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('help_zoom_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  /// The app in a window of [size] logical pixels.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // A key of its own each time, so a second pump is a fresh start.
        key: UniqueKey(),
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue('${tmp.path}/covers'),
          classicCvOnly,
          noSidecars(db),
          ...overrides,
        ],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  /// Real isolates and the database need real time, outside the fake clock.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {String? character}) async {
    await tester.sendKeyEvent(k, character: character);
    await settle(tester);
  }

  Future<void> plus(WidgetTester tester) => key(tester, LogicalKeyboardKey.equal, character: '+');
  Future<void> minus(WidgetTester tester) => key(tester, LogicalKeyboardKey.minus, character: '-');
  Future<void> equals(WidgetTester tester) => key(tester, LogicalKeyboardKey.equal, character: '=');
  Future<void> help(WidgetTester tester) => key(tester, LogicalKeyboardKey.slash, character: '?');
  Future<void> esc(WidgetTester tester) => key(tester, LogicalKeyboardKey.escape);

  /// A fresh start over the same database, the help opened.
  Future<ProviderContainer> startInHelp(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    final c = await pumpApp(tester, size: size);
    await settle(tester);
    await help(tester);
    expect(find.byType(KeymapOverlay), findsOneWidget);
    return c;
  }

  // The list's first row, on screen at every text size.
  const row = ValueKey('keymap-nextStep');
  final what = find.descendant(of: find.byKey(row), matching: find.text(ReaderIntent.nextStep.description));

  /// How big the letters of a row of the list are drawn, in pixels.
  double letters(WidgetTester tester) {
    final text = tester.renderObject<RenderParagraph>(what);
    return text.textScaler.scale(text.text.style!.fontSize!);
  }

  /// The same for the title line, the notes under it and the version.
  double lettersOf(WidgetTester tester, Key k) {
    final text = tester.renderObject<RenderParagraph>(find.byKey(k));
    return text.textScaler.scale(text.text.style!.fontSize!);
  }

  Future<String?> saved(WidgetTester tester) =>
      tester.runAsync<String?>(() => SettingsStore(db).loadString(SettingsStore.helpTextSize));
  Future<void> keep(WidgetTester tester, String value) =>
      tester.runAsync(() => SettingsStore(db).saveString(SettingsStore.helpTextSize, value));

  final scrollable = find.descendant(of: find.byKey(const Key('keymap-list')), matching: find.byType(Scrollable));
  ScrollPosition list(WidgetTester tester) => tester.state<ScrollableState>(scrollable).position;

  testWidgets('+ and - in the help size its text a step at a time; = is the usual size; nothing kept at it', (
    tester,
  ) async {
    await pumpApp(tester);
    await settle(tester);
    await help(tester);
    final usual = letters(tester);
    final height = tester.getSize(what).height;
    final title = lettersOf(tester, const Key('keymap-title'));
    expect(usual, 14);
    expect(await saved(tester), isNull);
    expect(
      tester.widget<Text>(find.byKey(const Key('keymap-title'))).data,
      'Keys  ·  / searches  ·  + - = text size  ·  Esc closes',
      reason: 'the help names the keys',
    );

    await plus(tester);
    expect(letters(tester), closeTo(14 * 1.15, 0.001));
    expect(tester.getSize(what).height, greaterThan(height), reason: 'drawn bigger, not only asked for');
    expect(lettersOf(tester, const Key('keymap-title')), closeTo(title * 1.15, 0.001), reason: 'the title too');
    expect(lettersOf(tester, const Key('keymap-version')), greaterThan(14));
    expect(await saved(tester), '1.15');
    await plus(tester);
    expect(letters(tester), closeTo(14 * 1.3, 0.001));
    expect(await saved(tester), '1.3');

    await minus(tester);
    await minus(tester);
    expect(letters(tester), usual);
    expect(tester.getSize(what).height, height);
    expect(await saved(tester), isNull, reason: 'back at the usual size by steps: no setting');
    await minus(tester);
    expect(letters(tester), closeTo(14 * 0.85, 0.001));
    expect(tester.getSize(what).height, lessThan(height));
    expect(await saved(tester), '0.85');

    // A count takes that many steps.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4, character: '4');
    await plus(tester);
    expect(letters(tester), closeTo(14 * 1.5, 0.001));

    await equals(tester);
    expect(letters(tester), usual);
    expect(await saved(tester), isNull);
    expect(find.byType(KeymapOverlay), findsOneWidget, reason: 'none of the keys closed the help');
  });

  testWidgets('the text stops at three times and at 0.7 of the usual size, and the list lays out and scrolls there', (
    tester,
  ) async {
    await pumpApp(tester);
    await settle(tester);
    await help(tester);
    for (var i = 0; i < 20; i++) {
      await plus(tester);
    }
    expect(letters(tester), 42);
    expect(await saved(tester), '3.0');
    await plus(tester);
    expect(letters(tester), 42, reason: 'no bigger');
    expect(tester.takeException(), isNull, reason: 'no row overflows at the biggest text');
    // Keys and text still side by side in a wide window, and the list scrolls.
    final keys = find.descendant(of: find.byKey(row), matching: find.text('l  Space'));
    expect(tester.getTopLeft(keys).dy, tester.getTopLeft(what).dy);
    expect(tester.getTopLeft(what).dx, 24 + 600);
    expect(list(tester).maxScrollExtent, greaterThan(2000));
    await tester.drag(find.byKey(const Key('keymap-list')), const Offset(0, -300));
    await settle(tester);
    expect(list(tester).pixels, greaterThan(250));

    for (var i = 0; i < 20; i++) {
      await minus(tester);
    }
    expect(letters(tester), closeTo(9.8, 0.001));
    expect(await saved(tester), '0.7');
    await minus(tester);
    expect(letters(tester), closeTo(9.8, 0.001), reason: 'no smaller');
    expect(tester.takeException(), isNull);
  });

  testWidgets('in a narrow window big text puts the keys above what they do, and nothing overflows at any size', (
    tester,
  ) async {
    for (final size in const [Size(360, 640), Size(800, 600), Size(320, 480)]) {
      await startInHelp(tester, size: size);
      await equals(tester);
      final keys = find.descendant(of: find.byKey(row), matching: find.text('l  Space'));
      for (var step = HelpZoom.usual; step <= HelpZoom.largest; step++) {
        expect(tester.takeException(), isNull, reason: '$size at step $step');
        // The title above the keys is tall in big letters: down to the first row.
        await tester.scrollUntilVisible(what, 100, scrollable: scrollable);
        final right = tester.getTopRight(what).dx;
        expect(right, lessThanOrEqualTo(size.width - 24 + 0.01), reason: '$size at step $step: inside the window');
        expect(tester.getSize(what).width, greaterThanOrEqualTo(69), reason: '$size at step $step: room to read');
        await plus(tester);
      }
      await tester.scrollUntilVisible(what, 100, scrollable: scrollable);
      // At the biggest text there is no room for two columns in any of these.
      expect(tester.getTopLeft(keys).dy, lessThan(tester.getTopLeft(what).dy), reason: '$size: keys above');
      expect(tester.getTopLeft(keys).dx, 24);
      expect(tester.getSize(find.byKey(row)).width, size.width - 48);
      expect(list(tester).maxScrollExtent, greaterThan(size.height), reason: 'the list still scrolls');
      expect(tester.takeException(), isNull);
    }
    // At the usual size a 360 px phone keeps its two columns, as before.
    await startInHelp(tester, size: const Size(360, 640));
    await equals(tester);
    final keys = find.descendant(of: find.byKey(row), matching: find.text('l  Space'));
    expect(tester.getTopLeft(keys).dy, tester.getTopLeft(what).dy);
    expect(tester.getTopLeft(what).dx, 224);
  });

  testWidgets('the size keys in the help do not reach the comic behind it', (tester) async {
    final path = writeBook(tmp, 'Behind 01.cbz', 4);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    double zoom() => tester.state<ReaderViewState>(find.byType(ReaderView)).transform.getMaxScaleOnAxis();
    final fit = zoom();
    await help(tester);
    await plus(tester);
    await plus(tester);
    await minus(tester);
    expect(letters(tester), closeTo(14 * 1.15, 0.001));
    expect(zoom(), fit, reason: 'the page behind the help was zoomed');
    await esc(tester);
    expect(find.byType(KeymapOverlay), findsNothing);
    // The same key with the help away zooms the page, and leaves the help's size.
    await plus(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(zoom(), greaterThan(fit));
    expect(await saved(tester), '1.15');
  });

  testWidgets('nor the covers behind it', (tester) async {
    for (var i = 1; i <= 8; i++) {
      writeBook(root, 'Book 0$i.cbz', i + 1);
    }
    final c = await pumpApp(tester);
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(root.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    await tester.tap(find.text('Books'));
    await settle(tester);
    double cover() => tester.getSize(find.byType(CoverCard).first).width;
    Future<String?> coverSize() =>
        tester.runAsync<String?>(() => SettingsStore(db).loadString(SettingsStore.coverSize));
    final usual = cover();
    await help(tester);
    await plus(tester);
    await plus(tester);
    expect(letters(tester), closeTo(14 * 1.3, 0.001));
    await esc(tester);
    expect(cover(), usual, reason: 'the covers behind the help were sized');
    expect(await coverSize(), isNull);
    // With the help away the key sizes the covers and not the help.
    await plus(tester);
    expect(cover(), greaterThan(usual));
    expect(await coverSize(), isNotNull);
    expect(await saved(tester), '1.3');
  });

  testWidgets('+ and - typed into the help search are searched for; after Enter they size the text again', (
    tester,
  ) async {
    await pumpApp(tester);
    await settle(tester);
    await help(tester);
    await key(tester, LogicalKeyboardKey.slash, character: '/');
    final field = find.byKey(const Key('keymap-search'));
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    // The key itself, with the cursor in the field: no command.
    await plus(tester);
    await minus(tester);
    await equals(tester);
    expect(letters(tester), 14, reason: 'a key typed in the search sized the text');
    expect(await saved(tester), isNull);
    // What the keyboard types there searches.
    await tester.enterText(field, '+');
    await settle(tester);
    expect(find.byKey(const ValueKey('keymap-zoomIn')), findsOneWidget);
    expect(find.byKey(const ValueKey('keymap-scrollFaster')), findsOneWidget, reason: 'g+ has a + too');
    expect(find.byKey(row), findsNothing);
    await tester.enterText(field, '-');
    await settle(tester);
    expect(find.byKey(const ValueKey('keymap-zoomOut')), findsOneWidget);
    expect(find.byKey(const ValueKey('keymap-zoomIn')), findsNothing);
    expect(await saved(tester), isNull);

    // Enter keeps the filter and gives the keys back: now + is a size key.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await plus(tester);
    final found = tester.renderObject<RenderParagraph>(
      find.descendant(of: find.byKey(const ValueKey('keymap-zoomOut')), matching: find.textContaining('Zoom out;')),
    );
    expect(found.textScaler.scale(14), closeTo(14 * 1.15, 0.001));
    expect(tester.widget<TextField>(field).controller!.text, '-', reason: 'the filter stays, nothing typed into it');
    expect(await saved(tester), '1.15');
    // The search field is sized with the rest.
    final typed = tester.renderObject<RenderEditable>(
      find.descendant(of: field, matching: find.byType(EditableText)).evaluate().isEmpty
          ? field
          : find.byElementPredicate((e) => e.renderObject is RenderEditable),
    );
    expect(typed.textScaler.scale(14), closeTo(14 * 1.15, 0.001));
  });

  testWidgets('Ctrl and the wheel size the text; the wheel alone scrolls the list', (tester) async {
    await pumpApp(tester);
    await settle(tester);
    await help(tester);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(640, 400)));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
    // No frame between these two: each counts from the other.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
    await settle(tester);
    expect(letters(tester), closeTo(14 * 1.3, 0.001), reason: 'wheel up twice: two steps bigger');
    expect(list(tester).pixels, 0, reason: 'the list did not scroll while Ctrl was held');
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(letters(tester), closeTo(14 * 1.15, 0.001));
    expect(await saved(tester), '1.15');

    // (Not far, or the first row would be off the screen and not measured.)
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 30)));
    await settle(tester);
    expect(letters(tester), closeTo(14 * 1.15, 0.001), reason: 'the wheel alone does not size');
    expect(list(tester).pixels, 30, reason: 'it scrolls');
  });

  testWidgets('two fingers spread on the help make the text bigger, and stop at the biggest', (tester) async {
    await pumpApp(tester);
    await settle(tester);
    await help(tester);
    const centre = Offset(640, 400);
    final a = await tester.startGesture(centre - const Offset(40, 0), kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(centre + const Offset(40, 0), kind: PointerDeviceKind.touch);
    // From 80 to 140 px apart: two steps.
    await a.moveBy(const Offset(-30, 0));
    await b.moveBy(const Offset(30, 0));
    await settle(tester);
    expect(letters(tester), closeTo(14 * 1.3, 0.001));
    // And far apart: more steps than there are sizes.
    await a.moveBy(const Offset(-500, 0));
    await b.moveBy(const Offset(500, 0));
    await a.up();
    await b.up();
    await settle(tester);
    expect(letters(tester), 42);
    expect(await saved(tester), '3.0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the size is back after a restart, also the first time the help opens', (tester) async {
    await pumpApp(tester);
    await settle(tester);
    await help(tester);
    await plus(tester);
    await plus(tester);
    await plus(tester);
    expect(await saved(tester), '1.5');
    await startInHelp(tester);
    expect(letters(tester), 21);
    // And goes on from there.
    await minus(tester);
    expect(letters(tester), closeTo(14 * 1.3, 0.001));
    expect(await saved(tester), '1.3');
  });

  testWidgets('a stored size that is none is the usual size; one beyond the steps is the nearest step', (tester) async {
    for (final bad in ['NaN', '-12', '0', '-0.0', 'Infinity', '-Infinity', '1e999', 'big', '']) {
      await keep(tester, bad);
      await startInHelp(tester);
      expect(tester.takeException(), isNull, reason: 'kept "$bad"');
      expect(letters(tester), 14, reason: 'kept "$bad"');
      expect(find.byKey(row), findsOneWidget, reason: 'kept "$bad": the list is built');
      // And the keys work from there.
      await plus(tester);
      expect(letters(tester), closeTo(14 * 1.15, 0.001), reason: '+ after "$bad"');
      expect(await saved(tester), '1.15');
    }
    for (final (kept, size) in [('1e300', 42.0), ('1000000', 42.0), ('3.7', 42.0), ('0.0001', 9.8), ('1.2', 16.1)]) {
      await keep(tester, kept);
      await startInHelp(tester);
      expect(tester.takeException(), isNull, reason: 'kept "$kept"');
      expect(letters(tester), closeTo(size, 0.001), reason: 'kept "$kept"');
    }
    // A setting of another kind under the key (a flag) is no size either.
    await tester.runAsync(() => SettingsStore(db).saveBool(SettingsStore.helpTextSize, true));
    await startInHelp(tester);
    expect(letters(tester), 14);
  });

  testWidgets('keys of one\'s own for the zoom size the help, the title names them, and + is then no size key', (
    tester,
  ) async {
    final load = keymapFromToml('[keys]\nzoomIn = ["F2"]\nzoomOut = ["F3"]\nzoomReset = []\n');
    expect(load.warnings, isEmpty);
    await pumpApp(tester, overrides: [startKeymapProvider.overrideWithValue((load: load, path: null))]);
    await settle(tester);
    await help(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('keymap-title'))).data,
      'Keys  ·  / searches  ·  F2 F3 text size  ·  Esc closes',
    );
    await key(tester, LogicalKeyboardKey.f2);
    await key(tester, LogicalKeyboardKey.f2);
    expect(letters(tester), closeTo(14 * 1.3, 0.001));
    await key(tester, LogicalKeyboardKey.f3);
    expect(letters(tester), closeTo(14 * 1.15, 0.001));
    await plus(tester);
    await minus(tester);
    await equals(tester);
    expect(letters(tester), closeTo(14 * 1.15, 0.001), reason: 'the default keys are not these any more');
  });

  testWidgets('Import settings takes up the file\'s help size at once, and the usual size from a file without one', (
    tester,
  ) async {
    String file(String name, Map<String, Object> settings) {
      final f = File('${tmp.path}/$name')
        ..writeAsStringSync(
          jsonEncode({'app': 'org.snonux.comicredr', 'kind': 'settings', 'format': 1, 'settings': settings}),
        );
      return f.path;
    }

    // The file picker answers with whatever [picked] is.
    late String picked;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/file_selector'),
      (call) async => call.method == 'openFile' ? [picked] : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        null,
      ),
    );
    Future<void> import(String path) async {
      picked = path;
      await tester.tap(find.byKey(const Key('settings')));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('setting-importSettings')));
      await tester.tap(find.byKey(const Key('setting-importSettings')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('importSettings-go')));
      await settle(tester);
      await settle(tester);
      if (find.byKey(const Key('setting-close')).evaluate().isNotEmpty) {
        await tester.ensureVisible(find.byKey(const Key('setting-close')));
        await tester.tap(find.byKey(const Key('setting-close')));
        await settle(tester);
      }
    }

    // A library with a comic: an empty one has no Settings button.
    writeBook(root, 'Book 01.cbz', 3);
    final c = await pumpApp(tester);
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(root.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    await help(tester);
    await plus(tester);
    expect(letters(tester), closeTo(14 * 1.15, 0.001));
    await esc(tester);

    await import(file('big.json', {SettingsStore.helpTextSize: '2.0'}));
    expect(await saved(tester), '2.0');
    await help(tester);
    expect(letters(tester), 28, reason: 'the imported size, without a restart');
    await esc(tester);

    // A size that is none is left out of the file's settings: the usual size.
    await import(file('bad.json', {SettingsStore.helpTextSize: 'NaN', SettingsStore.night: true}));
    expect(await saved(tester), isNull);
    await help(tester);
    expect(letters(tester), 14);
  });

  test('a help size in a settings file must be a finite number above zero, and an export carries it', () {
    expect(SettingsStore.backedUp[SettingsStore.helpTextSize], isFalse, reason: 'exported, as a string');
    expect(SettingsStore.perInstall, isNot(contains(SettingsStore.helpTextSize)));
    expect(SettingsStore.sizes, contains(SettingsStore.helpTextSize));
    expect(HelpZoom.scales[HelpZoom.usual], 1);
    expect(HelpZoom.scales.length, HelpZoom.largest + 1);
    expect([...HelpZoom.scales]..sort(), HelpZoom.scales, reason: 'smallest first');
    for (var step = 0; step <= HelpZoom.largest; step++) {
      // What is saved for a step reads back as that step.
      expect(HelpZoom.parse(HelpZoom.text(step)), step);
    }
    expect(HelpZoom.text(HelpZoom.usual), isNull);
  });
}
