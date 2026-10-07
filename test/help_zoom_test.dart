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

  /// How big the letters of a row of the list are drawn, in pixels: the
  /// first row's, or those of the row with the key [of].
  double letters(WidgetTester tester, {Key? of}) {
    final text = tester.renderObject<RenderParagraph>(
      of == null ? what : find.descendant(of: find.byKey(of), matching: find.byType(RichText)).first,
    );
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

  /// The system's text scale (Android's font size, GNOME's large text) for
  /// the rest of a test.
  void systemTextScale(WidgetTester tester, double scale) {
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  testWidgets('in a narrow window big text puts the keys above what they do, and nothing overflows at any size, '
      'whatever the system\'s text scale', (tester) async {
    for (final system in const [1.0, 1.5]) {
      systemTextScale(tester, system);
      for (final size in const [Size(360, 640), Size(800, 600), Size(320, 480)]) {
        await startInHelp(tester, size: size);
        await equals(tester);
        final where = '$size, system text $system';
        final keys = find.descendant(of: find.byKey(row), matching: find.text('l  Space'));
        for (var step = HelpZoom.usual; step <= HelpZoom.largest; step++) {
          expect(tester.takeException(), isNull, reason: '$where at step $step');
          // The title above the keys is tall in big letters: down to the first row.
          await tester.scrollUntilVisible(what, 100, scrollable: scrollable);
          final factor = letters(tester) / 14;
          expect(factor, closeTo(system * HelpZoom.scales[step], 0.001), reason: '$where at step $step');
          final right = tester.getTopRight(what).dx;
          expect(right, lessThanOrEqualTo(size.width - 24 + 0.01), reason: '$where at step $step: inside the window');
          // Room to read: beside the keys a description has at least 70 px
          // for letters of the usual size and as much more as its letters
          // are bigger, the system's scaling counted; below the keys it has
          // the row less its indent, which is all there is.
          final below = size.width - 48 - 24;
          final beside = tester.getTopLeft(keys).dy == tester.getTopLeft(what).dy;
          final width = tester.getSize(what).width;
          if (beside) {
            expect(width, greaterThanOrEqualTo(70 * factor - 0.01), reason: '$where at step $step: room to read');
          } else {
            expect(width, closeTo(below, 0.01), reason: '$where at step $step: the whole row');
            // And the keys went above only when beside there was no such room.
            expect(below + 24 - 200 * factor, lessThan(70 * factor), reason: '$where at step $step: not too early');
          }
          await plus(tester);
        }
        await tester.scrollUntilVisible(what, 100, scrollable: scrollable);
        // At the biggest text there is no room for two columns in any of these.
        expect(tester.getTopLeft(keys).dy, lessThan(tester.getTopLeft(what).dy), reason: '$where: keys above');
        expect(tester.getTopLeft(keys).dx, 24);
        expect(tester.getSize(find.byKey(row)).width, size.width - 48);
        expect(list(tester).maxScrollExtent, greaterThan(size.height), reason: 'the list still scrolls');
        expect(tester.takeException(), isNull);
      }
    }
    // At the usual size and the system's usual text a 360 px phone keeps its
    // two columns, as before.
    systemTextScale(tester, 1);
    await startInHelp(tester, size: const Size(360, 640));
    await equals(tester);
    final keys = find.descendant(of: find.byKey(row), matching: find.text('l  Space'));
    expect(tester.getTopLeft(keys).dy, tester.getTopLeft(what).dy);
    expect(tester.getTopLeft(what).dx, 224);
  });

  testWidgets('the help\'s size is on top of the system\'s text scale, not in its place', (tester) async {
    systemTextScale(tester, 1.5);
    await pumpApp(tester);
    await settle(tester);
    await help(tester);
    expect(letters(tester), 21, reason: 'the usual size is the system\'s');
    final title = lettersOf(tester, const Key('keymap-title'));
    await plus(tester);
    expect(letters(tester), closeTo(14 * 1.5 * 1.15, 0.001));
    expect(lettersOf(tester, const Key('keymap-title')), closeTo(title * 1.15, 0.001));
    expect(lettersOf(tester, const Key('keymap-version')), closeTo(14 * 1.5 * 1.15, 0.001));
    expect(await saved(tester), '1.15', reason: 'what is kept is the help\'s factor alone');
    await minus(tester);
    await minus(tester);
    expect(letters(tester), closeTo(14 * 1.5 * 0.85, 0.001));
    await equals(tester);
    expect(letters(tester), 21);
    // In a wide window the key column is as much wider as the letters are.
    await plus(tester);
    expect(tester.getTopLeft(what).dx, closeTo(24 + 200 * 1.5 * 1.15, 0.01));
  });

  testWidgets('the version under the list never lies over a row and is never cut off, at any size or width', (
    tester,
  ) async {
    final version = find.byKey(const Key('keymap-version'));
    final listBox = find.byKey(const Key('keymap-list'));
    // The last action of the list, which the version used to lie over.
    final last = find.byKey(ValueKey('keymap-${keymapEntries(Keymap.defaults()).last.intent.name}'));
    Future<void> toTheEnd(WidgetTester tester) async {
      // A lazy list only knows its end once it has laid out the way there.
      for (var i = 0; i < 40 && list(tester).pixels != list(tester).maxScrollExtent; i++) {
        list(tester).jumpTo(list(tester).maxScrollExtent);
        await tester.pump();
      }
      expect(list(tester).pixels, list(tester).maxScrollExtent);
    }

    for (final system in const [1.0, 1.5]) {
      systemTextScale(tester, system);
      for (final size in const [Size(1280, 800), Size(360, 640), Size(320, 480)]) {
        await startInHelp(tester, size: size);
        await equals(tester);
        for (var step = HelpZoom.usual; step <= HelpZoom.largest; step++) {
          final where = '$size, system text $system, step $step';
          // At the top, with rows under the list's whole height...
          final label = tester.getRect(version);
          final rows = tester.getRect(listBox);
          expect(label.top, greaterThanOrEqualTo(rows.bottom), reason: '$where: under the list, not over it');
          expect(label.left, greaterThanOrEqualTo(24 - 0.01), reason: '$where: cut off at the left');
          expect(label.right, lessThanOrEqualTo(size.width - 24 + 0.01), reason: '$where: cut off at the right');
          expect(label.bottom, lessThanOrEqualTo(size.height), reason: '$where: cut off at the bottom');
          expect(label.height, greaterThan(8), reason: '$where: still letters');
          // ...and at the end, against the last row itself.
          await toTheEnd(tester);
          expect(last, findsOneWidget, reason: where);
          final lastRow = tester.getRect(last);
          expect(lastRow.bottom, lessThanOrEqualTo(tester.getRect(version).top), reason: '$where: the last row');
          expect(lastRow.bottom, lessThanOrEqualTo(rows.bottom), reason: '$where: the last row is in sight');
          expect(tester.takeException(), isNull, reason: where);
          list(tester).jumpTo(0);
          await plus(tester);
        }
      }
    }
    // A window wide enough shows the version at its full size, three times the usual here.
    systemTextScale(tester, 1);
    await startInHelp(tester);
    expect(letters(tester), 42);
    expect(tester.getRect(version).height, greaterThan(40));
    expect(tester.getRect(version).right, closeTo(1280 - 24, 0.01));
  });

  testWidgets('a size change keeps the place in the list: the row along its top stays there, as far into it', (
    tester,
  ) async {
    final listBox = find.byKey(const Key('keymap-list'));
    final rows = find.descendant(
      of: listBox,
      matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> && w is Padding),
    );
    // The row the top edge of the list goes through, and the share of the
    // row's height that is above the edge.
    (Key, double) top(WidgetTester tester) {
      final edge = tester.getRect(listBox).top;
      for (final e in rows.evaluate()) {
        final rect = tester.getRect(find.byKey(e.widget.key!));
        if (rect.top <= edge && edge < rect.bottom) return (e.widget.key!, (edge - rect.top) / rect.height);
      }
      fail('no row along the top of the list');
    }

    await pumpApp(tester);
    await settle(tester);
    await help(tester);
    // Some way down, by the wheel: neither end, where any rule would do.
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(640, 400)));
    for (var i = 0; i < 12; i++) {
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 101)));
      await tester.pump();
    }
    await settle(tester);
    expect(list(tester).pixels, 1212);
    expect(list(tester).maxScrollExtent, greaterThan(2000));
    final (held, into) = top(tester);
    expect(into, inExclusiveRange(0.05, 0.95), reason: 'the edge goes through the row, not between two');

    // One step: the same row, the same share of it above the edge.
    await plus(tester);
    expect(letters(tester, of: held), closeTo(14 * 1.15, 0.001));
    expect(top(tester).$1, held);
    expect(top(tester).$2, closeTo(into, 0.02));
    // Six more at once, to three times the size, where rows with a long
    // description have wrapped and grown far more than the others.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit6, character: '6');
    await plus(tester);
    await settle(tester);
    expect(letters(tester, of: held), 42);
    expect(list(tester).pixels, greaterThan(2000), reason: 'the list went along with its rows');
    expect(top(tester).$1, held);
    expect(top(tester).$2, closeTo(into, 0.02));
    // Down to the smallest, nine steps at once, and back to the usual size.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit9, character: '9');
    await minus(tester);
    await settle(tester);
    expect(letters(tester, of: held), closeTo(9.8, 0.001));
    expect(top(tester).$1, held);
    expect(top(tester).$2, closeTo(into, 0.05), reason: 'small rows: a pixel is more of one');
    await equals(tester);
    expect(top(tester).$1, held);
    expect(top(tester).$2, closeTo(into, 0.05));

    // At the very top the list stays there, the title in sight.
    list(tester).jumpTo(0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit7, character: '7');
    await plus(tester);
    expect(list(tester).pixels, 0);
    expect(
      tester.getRect(find.byKey(const Key('keymap-title'))).top,
      greaterThanOrEqualTo(tester.getRect(listBox).top),
    );
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
    // The + key alone, with the cursor in the field: no command, so nothing
    // sized and nothing kept. (One key and not + - =, which would end at
    // the usual size also if each of them had sized the text.)
    await plus(tester);
    expect(letters(tester), 14, reason: '+ typed in the search sized the text');
    expect(await saved(tester), isNull, reason: '+ typed in the search kept a size');
    // What the key types arrives through the input method, as on a real
    // keyboard (a test's key event types nothing): it is searched for.
    tester.testTextInput.enterText('+');
    await settle(tester);
    expect(tester.widget<TextField>(field).controller!.text, '+');
    expect(letters(tester, of: const ValueKey('keymap-zoomIn')), 14);
    expect(await saved(tester), isNull);
    expect(find.byKey(const ValueKey('keymap-zoomIn')), findsOneWidget);
    expect(find.byKey(const ValueKey('keymap-scrollFaster')), findsOneWidget, reason: 'g+ has a + too');
    expect(find.byKey(row), findsNothing);
    // The same for - alone, from a size that is not the smallest.
    await minus(tester);
    expect(letters(tester, of: const ValueKey('keymap-zoomIn')), 14, reason: '- typed in the search sized the text');
    expect(await saved(tester), isNull, reason: '- typed in the search kept a size');
    tester.testTextInput.enterText('-');
    await settle(tester);
    expect(tester.widget<TextField>(field).controller!.text, '-');
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

  /// Ctrl and two wheel notches up, then two fingers spread by two steps,
  /// both in the middle of the help.
  Future<void> wheelAndPinch(WidgetTester tester) async {
    const centre = Offset(640, 400);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(centre));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
    await settle(tester);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(letters(tester), closeTo(14 * 1.3, 0.001), reason: 'the wheel sized the help');
    final a = await tester.startGesture(centre - const Offset(40, 0), kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(centre + const Offset(40, 0), kind: PointerDeviceKind.touch);
    await a.moveBy(const Offset(-30, 0));
    await b.moveBy(const Offset(30, 0));
    await settle(tester);
    await a.up();
    await b.up();
    await settle(tester);
    expect(letters(tester), closeTo(14 * 1.75, 0.001), reason: 'the pinch sized the help');
  }

  testWidgets('Ctrl and the wheel and a pinch on the help leave the covers behind it alone', (tester) async {
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
    // The covers stay built behind the help, so they can be measured under it.
    double cover() => tester.getSize(find.byType(CoverCard).first).width;
    int covers() => find.byType(CoverCard).evaluate().length;
    final usual = cover();
    final count = covers();
    await help(tester);
    await wheelAndPinch(tester);
    expect(cover(), usual, reason: 'the covers behind the help were sized');
    expect(covers(), count);
    expect(await tester.runAsync<String?>(() => SettingsStore(db).loadString(SettingsStore.coverSize)), isNull);
    expect(c.read(readerProvider).book, isNull, reason: 'a finger on the help opened a comic behind it');
    await esc(tester);
    expect(cover(), usual);
    expect(await saved(tester), '1.75');
  });

  testWidgets('nor the comic behind it', (tester) async {
    final path = writeBook(tmp, 'Behind 01.cbz', 4);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    Matrix4 view() => tester.state<ReaderViewState>(find.byType(ReaderView)).transform.clone();
    final fit = view();
    await help(tester);
    await wheelAndPinch(tester);
    expect(view(), fit, reason: 'the page behind the help was zoomed or moved');
    expect(c.read(readerProvider).page, 0, reason: 'a finger on the help turned the page');
    await esc(tester);
    expect(view(), fit);
    expect(await saved(tester), '1.75');
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
