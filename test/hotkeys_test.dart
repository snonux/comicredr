import 'dart:async';
import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart' hide Override;
import 'package:comicredr/src/data/data_dirs.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/s3_sync.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/hotkeys.dart';
import 'package:comicredr/src/keymap_overlay.dart';
import 'package:comicredr/src/library/book_detail.dart';
import 'package:comicredr/src/library/bulk_actions.dart';
import 'package:comicredr/src/library/default_folder.dart';
import 'package:comicredr/src/library/delete_book.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/settings_dialog.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/scroll_speed.dart';
import 'package:comicredr/src/undo_notice.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

/// Every button and every dialog has a key (task 263): a screen's buttons
/// through the keymap, with tooltips that name the live key; a dialog's
/// through Alt and an underlined letter ([DialogHotkeys], [Mnemonic]),
/// with a default focus, Tab to every control, and nothing reaching what
/// is behind it. The two walks at the end are for the buttons and dialogs
/// still to come.
void main() {
  late Directory tmp;
  late Directory root;
  late AppDatabase db;
  late _Routes routes;

  setUp(() {
    routes = _Routes();
    final dir = tmp = Directory.systemTemp.createTempSync('hotkeys_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    final database = db = AppDatabase(NativeDatabase.memory());
    // Each test takes down what it made itself, not what `tmp` and `db`
    // name by then: after a test that failed with a comic open the
    // clean-up can come ten minutes late (the test times out), in the
    // middle of a later test, and it then closed that test's database and
    // deleted its comics, so one failure showed as a row of them.
    addTearDown(() async {
      DialogHotkeys.debugTouchFirst = null;
      await database.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    // Each with its own number of pages: the same pages would be one comic.
    for (final n in ['Akira', 'Blacksad', 'Corto', 'Dredd']) {
      writeBook(root, '$n.cbz', n.codeUnitAt(0) - 63);
    }
    // And a series of two, for the Series tab.
    writeBook(root, 'Zot 1.cbz', 7);
    writeBook(root, 'Zot 2.cbz', 8);
  });

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    Keymap? keymap,
    Override? sidecars,
    Override? store,
    Override? s3,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue('${tmp.path}/covers'),
          classicCvOnly,
          sidecars ?? noSidecars(db),
          if (keymap != null) keymapProvider.overrideWithValue(keymap),
          ?store,
          ?s3,
        ],
        child: ComicRedrApp(navigatorObservers: [routes]),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  const named = {
    ',': LogicalKeyboardKey.comma,
    // The test keyboard has no key for !, * and ?: Shift+1, Shift+8 and Shift+/ type them.
    '!': LogicalKeyboardKey.digit1,
    '*': LogicalKeyboardKey.digit8,
    '?': LogicalKeyboardKey.slash,
  };

  LogicalKeyboardKey keyOf(String ch) =>
      named[ch] ??
      LogicalKeyboardKey.findKeyByKeyId(LogicalKeyboardKey.keyA.keyId + ch.toLowerCase().codeUnitAt(0) - 0x61)!;

  /// Types [keys] as key presses, back to back, the way a hand does.
  Future<void> type(WidgetTester tester, String keys) async {
    for (final ch in keys.split('')) {
      await tester.sendKeyEvent(keyOf(ch), character: ch);
    }
    await settle(tester);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  /// Alt and [letter], as a dialog's underlined letters are pressed.
  Future<void> alt(WidgetTester tester, String letter) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(keyOf(letter), character: letter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await settle(tester);
  }

  /// The app with the four comics scanned, on the Folders tab inside the
  /// library folder, the first comic selected.
  ///
  /// With [remapped] the arrows and Enter are no keys of [keymap], and the
  /// way in is typed with the keys it has for them.
  Future<ProviderContainer> inFolder(
    WidgetTester tester, {
    Keymap? keymap,
    bool remapped = false,
    Override? sidecars,
    Override? store,
    Override? s3,
  }) async {
    final c = await pumpApp(tester, keymap: keymap, sidecars: sidecars, store: store, s3: s3);
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(root.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Folders')));
    await settle(tester);
    if (remapped) {
      await type(tester, keymap!.hint(ReaderIntent.nextStep)!);
      await type(tester, keymap.hint(ReaderIntent.activate)!);
    } else {
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
    }
    expect(find.byKey(const Key('breadcrumb')), findsOneWidget);
    // Entering the folder selects its first comic.
    expect(find.descendant(of: find.byKey(const Key('detail')), matching: find.text('Akira')), findsOneWidget);
    return c;
  }

  /// Opens the comic [name] in the reader.
  Future<void> open(WidgetTester tester, ProviderContainer c, String name) async {
    // Not awaited inside runAsync: opening can wait for a frame, which only
    // the pumps of settle bring.
    unawaited(c.read(readerProvider.notifier).open('${root.path}/$name.cbz'));
    for (var i = 0; i < 20 && c.read(readerProvider).pageCount == 0; i++) {
      await settle(tester);
    }
    expect(c.read(readerProvider).book, isNotNull);
    expect(c.read(readerProvider).pageCount, greaterThan(0));
  }

  /// Esc out of the open comic, so its work in the background (finding
  /// panels ahead, with a rest between pages) is stopped before the test ends.
  Future<void> closeComic(WidgetTester tester, ProviderContainer c) async {
    for (var i = 0; i < 5 && c.read(readerProvider).book != null; i++) {
      await press(tester, LogicalKeyboardKey.escape);
    }
    expect(c.read(readerProvider).book, isNull);
  }

  /// Whether the control labelled [text] has the keyboard focus.
  bool focused(WidgetTester tester, String text) => Focus.of(tester.element(find.text(text).last)).hasPrimaryFocus;

  bool underlined(WidgetTester tester, String label) {
    final text = tester.widget<Text>(find.text(label));
    var found = false;
    text.textSpan?.visitChildren((span) {
      if (span.style?.decoration == TextDecoration.underline) found = true;
      return true;
    });
    return found;
  }

  group('the keymap names its keys for buttons', () {
    test('the first key of an intent, as a person reads it', () {
      final keys = Keymap.defaults();
      expect(keys.hint(ReaderIntent.showSettings), 'g,');
      expect(keys.hint(ReaderIntent.markAll), 'Ctrl+A');
      expect(keys.hint(ReaderIntent.back), 'Esc');
      expect(keys.hint(ReaderIntent.fullscreen), 'f');
      expect(keys.tip('Favourites', ReaderIntent.showFavourites), 'Favourites (gf)');
      expect(Keymap.spoken(const Binding(['S-Delete'], ReaderIntent.deleteBook)), 'Shift+Delete');
      expect(Keymap.spoken(const Binding(['g', 'Home'], ReaderIntent.firstPage)), 'g Home');
      final none = keymapFromToml('[keys]\nshowSettings = []').keymap;
      expect(none.hint(ReaderIntent.showSettings), isNull);
      expect(none.tip('Settings', ReaderIntent.showSettings), 'Settings');
    });

    test('the keys added for buttons that had none hide no other key', () {
      final keys = Keymap.defaults();
      const added = {
        ReaderIntent.showSettings: 'g,',
        ReaderIntent.undo: 'u',
        ReaderIntent.downloadFromS3: 'gD',
        ReaderIntent.removeRoot: 'gA',
        ReaderIntent.showScanFailures: 'g!',
      };
      for (final MapEntry(key: intent, value: key) in added.entries) {
        expect(keys.hint(intent), key, reason: intent.name);
      }
      // Loading the defaults through the keys.toml checks warns of nothing.
      expect(keymapFromToml(keymapToToml(keys)).warnings, isEmpty);
      for (final a in keys.bindings) {
        for (final b in keys.bindings) {
          if (identical(a, b) || a.hasLetterSlot || b.hasLetterSlot) continue;
          expect(a.keys.join('\u0000') == b.keys.join('\u0000'), isFalse, reason: '${a.keys} is bound twice');
        }
      }
    });
  });

  group('a dialog on its own', () {
    Future<List<String>> pumpDialog(WidgetTester tester, {bool canClear = true}) async {
      final log = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DialogHotkeys(
              child: AlertDialog(
                content: const TextField(key: Key('field'), autofocus: true),
                actions: [
                  TextButton(onPressed: () => log.add('cancel'), child: const Mnemonic('Cancel')),
                  TextButton(
                    onPressed: canClear ? () => log.add('clear') : null,
                    child: const Mnemonic('Clear', letter: 'l'),
                  ),
                  FilledButton.icon(
                    onPressed: () => log.add('save'),
                    icon: const Icon(Icons.save),
                    label: const Mnemonic('Save'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return log;
    }

    testWidgets('Alt and the letter presses the button; the letter alone is text for the field', (tester) async {
      final log = await pumpDialog(tester);
      await alt(tester, 's');
      expect(log, ['save']);
      await alt(tester, 'l');
      await alt(tester, 'c');
      expect(log, ['save', 'clear', 'cancel']);
      // No button has Alt+Q, and Ctrl+Alt+S is not Alt+S.
      await alt(tester, 'q');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await alt(tester, 's');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(log, hasLength(3));
      // The plain letters go to the field, which has the focus, and press nothing.
      await type(tester, 'scl');
      expect(log, hasLength(3));
      await tester.enterText(find.byKey(const Key('field')), 'scl');
      expect(find.text('scl'), findsOneWidget);
      expect(log, hasLength(3));
    });

    testWidgets('a held key presses once, and a disabled button not at all', (tester) async {
      final log = await pumpDialog(tester, canClear: false);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS, character: 's');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyS, character: 's');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyS, character: 's');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(log, ['save']);
      await alt(tester, 'l');
      expect(log, ['save']);
    });

    testWidgets('the letters are underlined on a desktop; on a phone only while Alt is held', (tester) async {
      await pumpDialog(tester);
      expect(underlined(tester, 'Cancel'), isTrue);
      expect(underlined(tester, 'Clear'), isTrue);
      expect(underlined(tester, 'Save'), isTrue);

      DialogHotkeys.debugTouchFirst = true;
      await tester.pumpWidget(const SizedBox());
      final log = await pumpDialog(tester);
      expect(underlined(tester, 'Save'), isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(underlined(tester, 'Save'), isTrue);
      // The key works there all the same: a keyboard on a tablet.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS, character: 's');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(log, ['save']);
      expect(underlined(tester, 'Save'), isFalse);
    });

    testWidgets('the keys work with nothing focused, and a field that shows later still gets the focus', (
      tester,
    ) async {
      var pressed = 0;
      final loaded = ValueNotifier(false);
      addTearDown(loaded.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DialogHotkeys(
              child: Column(
                children: [
                  // As the S3 settings: its fields come once they are read.
                  ValueListenableBuilder(
                    valueListenable: loaded,
                    builder: (_, on, _) => on ? const TextField(key: Key('late'), autofocus: true) : const SizedBox(),
                  ),
                  TextButton(onPressed: () => pressed++, child: const Mnemonic('Go')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await alt(tester, 'g');
      expect(pressed, 1);
      loaded.value = true;
      await tester.pump();
      await tester.pump();
      expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasPrimaryFocus, isTrue);
      await alt(tester, 'g');
      expect(pressed, 2);
    });

    for (final brightness in Brightness.values) {
      testWidgets('the underline has the label\'s own colour on every kind of button, ${brightness.name}', (
        tester,
      ) async {
        // The app's own themes (app.dart): a filled button's label is not the surface's text colour.
        final theme = withFocusRing(
          ThemeData(colorSchemeSeed: const Color(0xFF0B6FB4), brightness: brightness, useMaterial3: true),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: DialogHotkeys(
                child: AlertDialog(
                  actions: [
                    TextButton(onPressed: () {}, child: const Mnemonic('Text')),
                    FilledButton(onPressed: () {}, child: const Mnemonic('Filled')),
                    FilledButton.tonal(onPressed: () {}, child: const Mnemonic('Onal')),
                    OutlinedButton(onPressed: () {}, child: const Mnemonic('Lined')),
                    const FilledButton(onPressed: null, child: Mnemonic('Disabled')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final seen = <String, Color>{};
        for (final label in ['Text', 'Filled', 'Onal', 'Lined', 'Disabled']) {
          final rich = tester.widget<RichText>(
            find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == label),
          );
          final colour = rich.text.style!.color!;
          InlineSpan? letter;
          rich.text.visitChildren((span) {
            if (span.style?.decoration == TextDecoration.underline) letter = span;
            return true;
          });
          expect(letter, isNotNull, reason: '$label has an underlined letter');
          // What is painted: the span's style over the label's.
          final painted = rich.text.style!.merge(letter!.style);
          expect(painted.decorationColor, colour, reason: '$label: the underline is drawn in the text colour');
          seen[label] = colour;
        }
        // The case that was wrong: a filled button's label is not the colour of text on the surface.
        expect(seen['Filled'], theme.colorScheme.onPrimary);
        expect(seen['Filled'], isNot(theme.colorScheme.onSurface));
        expect(seen['Text'], theme.colorScheme.primary);
      });
    }

    testWidgets('a dialog over a dialog: only the one on top has its letters', (tester) async {
      final log = <String>[];
      Widget question(BuildContext context) => DialogHotkeys(
        child: AlertDialog(
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () {
                log.add('top cancel');
                Navigator.pop(context);
              },
              child: const Mnemonic('Cancel'),
            ),
          ],
        ),
      );
      Widget lower(BuildContext context) => DialogHotkeys(
        child: AlertDialog(
          actions: [
            TextButton(
              onPressed: () {
                log.add('lower history');
                showDialog<void>(context: context, builder: question);
              },
              child: const Mnemonic('History'),
            ),
            TextButton(onPressed: () => log.add('lower close'), child: const Mnemonic('Close')),
            TextButton(onPressed: () => log.add('lower other'), child: const Mnemonic('Other')),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(context: context, builder: lower),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await alt(tester, 'h');
      await tester.pumpAndSettle();
      expect(log, ['lower history']);
      expect(find.byType(DialogHotkeys), findsNWidgets(2));
      // Letters only the lower dialog has do nothing while the question is up:
      // pressed, held (the repeats) and let go.
      await alt(tester, 'o');
      await alt(tester, 'h');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyO, character: 'o');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyO, character: 'o');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyO, character: 'o');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(log, ['lower history']);
      expect(find.byType(DialogHotkeys), findsNWidgets(2));
      // The top one's letter acts, once: its repeats and its release, which
      // come when it has gone, press nothing of the dialog below (Close has
      // the same letter).
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC, character: 'c');
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyC, character: 'c');
      await tester.pumpAndSettle();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyC, character: 'c');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(log, ['lower history', 'top cancel']);
      expect(find.byType(DialogHotkeys), findsOneWidget);
      // And then the lower dialog has its letters again.
      await alt(tester, 'c');
      expect(log, ['lower history', 'top cancel', 'lower close']);
    });

    testWidgets('outside a dialog a label is plain text and no key', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TextButton(autofocus: true, onPressed: () => pressed++, child: const Mnemonic('Go')),
        ),
      );
      await tester.pump();
      expect(underlined(tester, 'Go'), isFalse);
      await alt(tester, 'g');
      expect(pressed, 0);
    });

    testWidgets('two buttons of one dialog cannot share a letter', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DialogHotkeys(
            child: Row(
              children: [
                TextButton(onPressed: () {}, child: const Mnemonic('Cancel')),
                TextButton(onPressed: () {}, child: const Mnemonic('Clear')),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC, character: 'c');
      expect(tester.takeException(), isA<AssertionError>());
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      expect(tester.takeException(), isA<AssertionError>());
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    });
  });

  group('in the app', () {
    testWidgets('g, opens Settings; Space, the arrows and Alt+letters work it; nothing reaches the library', (
      tester,
    ) async {
      final c = await inFolder(tester);
      final settings = SettingsStore(db);
      bool? cleanUp() => tester.widget<SwitchListTile>(find.byKey(const Key('setting-cleanUp'))).value;

      await type(tester, 'g,');
      expect(find.byType(SettingsDialog), findsOneWidget);
      // Close has the focus, so Enter closes.
      expect(focused(tester, 'Close'), isTrue);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(SettingsDialog), findsNothing);

      // Typed twice it is still one dialog: the second g, is the dialog's.
      await type(tester, 'g,g,');
      expect(find.byType(SettingsDialog), findsOneWidget);

      // Tab from Close goes to the first setting; Space switches it.
      expect(cleanUp(), isFalse);
      await press(tester, LogicalKeyboardKey.tab);
      await press(tester, LogicalKeyboardKey.space);
      expect(cleanUp(), isTrue);
      expect(await tester.runAsync(() => settings.loadBool(SettingsStore.cleanUp)), isTrue);
      // The next stop is the scrolling speed: the arrows move its slider.
      final before = c.read(scrollSpeedProvider);
      await press(tester, LogicalKeyboardKey.tab);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(c.read(scrollSpeedProvider).index, before.index + 1);

      // The keys of the library do nothing behind it: l would move the
      // selection, gd ask to delete, Enter open the comic.
      Finder inPane(String name) => find.descendant(of: find.byKey(const Key('detail')), matching: find.text(name));
      expect(inPane('Akira'), findsOneWidget);
      await type(tester, 'l');
      await type(tester, 'gd');
      expect(find.byKey(const Key('deleteDialog')), findsNothing);
      expect(c.read(readerProvider).book, isNull);
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(inPane('Akira'), findsOneWidget);

      // Alt+H asks before clearing the history, Cancel focused.
      await alt(tester, 'h');
      expect(find.text('Clear reading history?'), findsOneWidget);
      expect(focused(tester, 'Cancel'), isTrue);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.text('Clear reading history?'), findsNothing);
      expect(find.text('Reading history cleared'), findsNothing);
      await alt(tester, 'h');
      await alt(tester, 'l');
      expect(find.text('Clear reading history?'), findsNothing);
      expect(find.text('Reading history cleared'), findsOneWidget);

      // Alt+C closes Settings, and the library has its keys back.
      await alt(tester, 'c');
      expect(find.byType(SettingsDialog), findsNothing);
      await type(tester, 'gd');
      expect(find.byKey(const Key('deleteDialog')), findsOneWidget);
    });

    testWidgets('gd: Cancel is the default, Alt+C cancels, Alt+D deletes; d alone does not', (tester) async {
      await inFolder(tester);
      final path = '${root.path}/Akira.cbz';
      await type(tester, 'gd');
      expect(find.text('Delete Akira?'), findsOneWidget);
      expect(focused(tester, 'Cancel'), isTrue);
      expect(underlined(tester, 'Delete for good'), isTrue);
      // The arrows move the ring to the next button and back.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(tester, 'Delete for good'), isTrue);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focused(tester, 'Cancel'), isTrue);
      // The letter without Alt, and Enter on the default, delete nothing.
      await type(tester, 'd');
      expect(find.byKey(const Key('deleteDialog')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byKey(const Key('deleteDialog')), findsNothing);
      expect(File(path).existsSync(), isTrue);

      await type(tester, 'gd');
      await alt(tester, 'c');
      expect(find.byKey(const Key('deleteDialog')), findsNothing);
      expect(File(path).existsSync(), isTrue);

      await type(tester, 'gd');
      await alt(tester, 'd');
      for (var i = 0; i < 20 && File(path).existsSync(); i++) {
        await settle(tester);
      }
      expect(File(path).existsSync(), isFalse);
      expect(File('${root.path}/Blacksad.cbz').existsSync(), isTrue);
    });

    testWidgets('X: Redo panels is the default; Alt+C leaves; gc: a typed a is a name, Alt+A adds', (tester) async {
      final c = await inFolder(tester);
      final store = c.read(libraryStoreProvider);
      await type(tester, 'X');
      expect(find.byKey(const Key('resetDialog')), findsOneWidget);
      expect(focused(tester, 'Redo panels'), isTrue);
      await alt(tester, 'c');
      expect(find.byKey(const Key('resetDialog')), findsNothing);

      await type(tester, 'gc');
      expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
      // The letters of the buttons are letters in the name field.
      await tester.enterText(find.byKey(const Key('collectionName')), 'ac');
      await type(tester, 'a');
      expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
      await alt(tester, 'a');
      expect(find.byKey(const Key('collectionDialog')), findsNothing);
      final books = (await tester.runAsync(store.books))!;
      expect(books.where((b) => b.collections.contains('ac')).map((b) => b.name), ['Akira']);

      // Tab from the name goes to the collections offered, which arrive
      // after the buttons were built, and only then to the buttons; Space
      // on the first puts the next comic in it.
      await type(tester, 'lgc');
      await press(tester, LogicalKeyboardKey.tab);
      expect(
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<ActionChip>(),
        isNotNull,
        reason: 'Tab from the name field is on ${FocusManager.instance.primaryFocus?.context?.widget}',
      );
      await press(tester, LogicalKeyboardKey.space);
      expect(find.byKey(const Key('collectionDialog')), findsNothing);
      final both = (await tester.runAsync(store.books))!;
      expect(both.where((b) => b.collections.contains('ac')).map((b) => b.name).toList()..sort(), [
        'Akira',
        'Blacksad',
      ]);

      // Alt+C cancels the question: nothing is added.
      await type(tester, 'gc');
      await tester.enterText(find.byKey(const Key('collectionName')), 'never');
      await alt(tester, 'c');
      expect(find.byKey(const Key('collectionDialog')), findsNothing);
      expect((await tester.runAsync(store.collectionNames))!, isNot(contains('never')));
    });

    testWidgets('F: Alt+C does nothing while no filter is on, clears one that is, Alt+D is Done', (tester) async {
      await inFolder(tester);
      await type(tester, 'F');
      expect(find.byKey(const Key('filterDialog')), findsOneWidget);
      await alt(tester, 'c');
      expect(find.byKey(const Key('filterDialog')), findsOneWidget);
      // The first type has the focus: Space picks it, and Clear all works.
      await press(tester, LogicalKeyboardKey.space);
      expect(find.byKey(const Key('filterBarType')), findsOneWidget);
      await alt(tester, 'c');
      expect(find.byKey(const Key('filterBarType')), findsNothing);
      expect(find.byKey(const Key('filterDialog')), findsOneWidget);
      await alt(tester, 'd');
      expect(find.byKey(const Key('filterDialog')), findsNothing);
    });

    testWidgets('u undoes what the notice offers, once; x takes a comic out of an open collection', (tester) async {
      final c = await inFolder(tester);
      final store = c.read(libraryStoreProvider);
      Future<List<String>> inCollection(String name) async => [
        for (final b in (await tester.runAsync(store.books))!)
          if (b.collections.contains(name)) b.name,
      ]..sort();
      // With nothing to undo, u does nothing.
      await type(tester, 'u');
      expect(find.byType(SnackBar), findsNothing);

      // Two comics into a collection, then into it on the Collections tab.
      await type(tester, 'gc');
      await tester.enterText(find.byKey(const Key('collectionName')), 'Noir');
      await alt(tester, 'a');
      await type(tester, 'lgc');
      await tester.enterText(find.byKey(const Key('collectionName')), 'Noir');
      await alt(tester, 'a');
      expect(await inCollection('Noir'), ['Akira', 'Blacksad']);
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Collections')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.home);

      await type(tester, 'x');
      expect(await inCollection('Noir'), ['Blacksad']);
      expect(find.text('Akira taken out of Noir'), findsOneWidget);
      // The notice's button names the key.
      expect(find.text('Undo (u)'), findsOneWidget);
      await type(tester, 'u');
      expect(await inCollection('Noir'), ['Akira', 'Blacksad']);
      // It is undone once: taken out some other way afterwards, u does
      // not put it back a second time.
      final akira = (await tester.runAsync(store.books))!.firstWhere((b) => b.name == 'Akira');
      await tester.runAsync(() => store.removeFromCollection(akira.key, 'Noir'));
      await type(tester, 'u');
      expect(await inCollection('Noir'), ['Blacksad']);
    });

    testWidgets('gA takes the selected library folder out; g! says when every comic could be read', (tester) async {
      final c = await inFolder(tester);
      final store = c.read(libraryStoreProvider);
      // On a comic gA is nothing: only a library folder can be taken out.
      await type(tester, 'gA');
      expect((await tester.runAsync(store.roots))!, hasLength(1));
      await type(tester, 'g!');
      expect(find.text('The last scan could read every comic'), findsOneWidget);
      // gD with no comic that is only on S3 does nothing.
      await type(tester, 'gD');
      expect(find.textContaining('Downloading'), findsNothing);

      await press(tester, LogicalKeyboardKey.backspace);
      expect(find.byKey(const Key('breadcrumb')), findsNothing);
      await type(tester, 'gA');
      expect((await tester.runAsync(store.roots))!, isEmpty);
      for (final n in ['Akira', 'Dredd']) {
        expect(File('${root.path}/$n.cbz').existsSync(), isTrue);
      }
    });

    testWidgets('g, works with a comic open, and the comic keeps its page', (tester) async {
      final c = await inFolder(tester);
      await open(tester, c, 'Dredd');
      await type(tester, 'l');
      final page = c.read(readerProvider).page;
      // Alt and a letter is for dialogs: on the comic it is no command.
      await alt(tester, 'l');
      expect(c.read(readerProvider).page, page);
      await type(tester, 'g,');
      expect(find.byType(SettingsDialog), findsOneWidget);
      await type(tester, 'l');
      expect(c.read(readerProvider).page, page);
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.byType(SettingsDialog), findsNothing);
      expect(c.read(readerProvider).book, isNotNull);
      await type(tester, 'l');
      expect(c.read(readerProvider).page, isNot(page));
    });

    testWidgets('tooltips name the key that is live, and none when the action has no key', (tester) async {
      final keymap = keymapFromToml('[keys]\nshowSettings = ["q"]\nshowFavourites = []').keymap;
      await inFolder(tester, keymap: keymap);
      expect(tester.widget<IconButton>(find.byKey(const Key('settings'))).tooltip, 'Settings (q)');
      expect(tester.widget<IconButton>(find.byKey(const Key('favourites'))).tooltip, 'Favourites');
      // And the key itself: q opens Settings, g, no longer does.
      await type(tester, 'g,');
      expect(find.byType(SettingsDialog), findsNothing);
      await type(tester, 'q');
      expect(find.byType(SettingsDialog), findsOneWidget);
    });

    /// The letter of Redo panels in the comic's details.
    const redoKey = 'p';

    /// `I`, and the details' rows once the comic's report is read.
    Future<void> openDetails(WidgetTester tester) async {
      await type(tester, 'I');
      for (var i = 0; i < 20 && find.byKey(const Key('detailsList')).evaluate().isEmpty; i++) {
        await settle(tester);
      }
      expect(find.byKey(const Key('detailsList')), findsOneWidget);
    }

    /// Scrolls the details to their end, where Redo panels is built.
    Future<void> toTheEnd(WidgetTester tester) async {
      for (var i = 0; i < 20 && find.byKey(const Key('detailsRedoPanels')).evaluate().isEmpty; i++) {
        await press(tester, LogicalKeyboardKey.end);
      }
      expect(find.byKey(const Key('detailsRedoPanels')), findsOneWidget);
    }

    // Alt and Redo panels' letter closes the details and nothing else,
    // whether the button, a row far down a lazy list, is built or not.
    // When the button's label and a Shortcuts of the view both took the
    // key, the second pop took the app's own route away: a dead window.
    for (final atEnd in [false, true]) {
      final where = atEnd ? 'scrolled to the button' : 'from the top of the list';
      testWidgets('Alt+$redoKey in the reader\'s details, $where: one route popped, the panels redone', (tester) async {
        // A short window: the button is below what the top of the list builds.
        final c = await inFolder(tester);
        tester.view.physicalSize = const Size(1280, 420);
        await open(tester, c, 'Dredd');
        await type(tester, 'l');
        final page = c.read(readerProvider).page;
        await openDetails(tester);
        if (atEnd) {
          await toTheEnd(tester);
        } else {
          expect(find.byKey(const Key('detailsRedoPanels')), findsNothing);
        }
        final before = routes.pops;
        await alt(tester, redoKey);
        for (var i = 0; i < 20 && c.read(readerProvider).pageCount == 0; i++) {
          await settle(tester);
        }
        expect(routes.pops - before, 1, reason: 'routes popped by one Alt+$redoKey');
        expect(find.byKey(const Key('comicDetails')), findsNothing);
        expect(find.byType(HomeScreen), findsOneWidget);
        // The panels are redone: the comic is open again where it was.
        expect(c.read(readerProvider).message, anyOf(contains('Panels forgotten'), contains('Finding the panels')));
        expect(c.read(readerProvider).page, page);
        // And the app still answers keys.
        await type(tester, 'l');
        expect(c.read(readerProvider).page, isNot(page));
        await closeComic(tester, c);
      });

      testWidgets('Alt+$redoKey in the details from the library, $where: one route popped, the panels redone', (
        tester,
      ) async {
        await inFolder(tester);
        tester.view.physicalSize = const Size(1280, 420);
        await openDetails(tester);
        if (atEnd) {
          await toTheEnd(tester);
        } else {
          expect(find.byKey(const Key('detailsRedoPanels')), findsNothing);
        }
        final before = routes.pops;
        await alt(tester, redoKey);
        await settle(tester);
        expect(routes.pops - before, 1, reason: 'routes popped by one Alt+$redoKey');
        expect(find.byKey(const Key('comicDetails')), findsNothing);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.text("Akira's panels will be found again"), findsOneWidget);
        await type(tester, 'l');
        expect(find.descendant(of: find.byKey(const Key('detail')), matching: find.text('Blacksad')), findsOneWidget);
      });
    }

    testWidgets('u presses the notice\'s Undo over an open comic too', (tester) async {
      final c = await inFolder(tester);
      final store = c.read(libraryStoreProvider);
      Future<bool> favourite() async =>
          (await tester.runAsync(store.books))!.firstWhere((b) => b.name == 'Akira').favourite;
      // In the favourites and out again: the notice offers it back.
      await type(tester, '*');
      await type(tester, '*');
      expect(await favourite(), isFalse);
      expect(find.text('Akira taken out of Favourites'), findsOneWidget);
      // The notice is still there over the comic, and names the key.
      await open(tester, c, 'Dredd');
      expect(find.text('Undo (u)'), findsOneWidget);
      await type(tester, 'u');
      expect(await favourite(), isTrue);
      expect(find.byType(SnackBar), findsNothing);
      expect(c.read(readerProvider).book, isNotNull);
      await closeComic(tester, c);
    });

    testWidgets('with no notice that offers an Undo, u does nothing and says nothing', (tester) async {
      final c = await inFolder(tester);
      final store = c.read(libraryStoreProvider);
      Future<List<String>> favourites() async => [
        for (final b in (await tester.runAsync(store.books))!)
          if (b.favourite) b.name,
      ];
      // A notice without an Undo is nothing to undo.
      await type(tester, '*');
      expect(find.text('Akira added to Favourites'), findsOneWidget);
      await type(tester, 'u');
      expect(await favourites(), ['Akira']);
      expect(find.text('Akira added to Favourites'), findsOneWidget);
      // Nor is there anything over a comic.
      await open(tester, c, 'Dredd');
      final was = c.read(readerProvider);
      await type(tester, 'u');
      expect(c.read(readerProvider).message, was.message);
      expect(c.read(readerProvider).page, was.page);
      expect(await favourites(), ['Akira']);
      await closeComic(tester, c);
    });

    testWidgets('u presses the notice\'s Undo with the ? help up, and the help stays', (tester) async {
      final c = await inFolder(tester);
      final store = c.read(libraryStoreProvider);
      Future<bool> favourite() async =>
          (await tester.runAsync(store.books))!.firstWhere((b) => b.name == 'Akira').favourite;
      await type(tester, '*');
      await type(tester, '*');
      expect(await favourite(), isFalse);
      expect(find.text('Undo (u)'), findsOneWidget);
      await type(tester, '?');
      expect(find.byType(KeymapOverlay), findsOneWidget);
      // The help keeps every other key from what is behind it, not this one.
      await type(tester, 'u');
      expect(await favourite(), isTrue);
      expect(find.byType(KeymapOverlay), findsOneWidget);
      // Another key of the library still does nothing under the help.
      await type(tester, '*');
      expect(await favourite(), isTrue);
    });

    testWidgets('the notice with an Undo goes by itself after ten seconds, and u is nothing then', (tester) async {
      final c = await inFolder(tester);
      final store = c.read(libraryStoreProvider);
      Future<bool> favourite() async =>
          (await tester.runAsync(store.books))!.firstWhere((b) => b.name == 'Akira').favourite;
      await type(tester, '*');
      await type(tester, '*');
      expect(find.text('Akira taken out of Favourites'), findsOneWidget);
      // Still there well after a plain notice's four seconds.
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Undo (u)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(find.byType(SnackBar), findsNothing);
      await type(tester, 'u');
      expect(await favourite(), isFalse);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a notice without an Undo takes the place of one with: it shows at once, and u is nothing', (
      tester,
    ) async {
      final c = await inFolder(tester);
      final store = c.read(libraryStoreProvider);
      Future<bool> favourite() async =>
          (await tester.runAsync(store.books))!.firstWhere((b) => b.name == 'Akira').favourite;
      await type(tester, '*');
      await type(tester, '*');
      expect(find.text('Akira taken out of Favourites'), findsOneWidget);
      // g! says that every comic could be read: before, that waited unseen
      // behind the Undo notice, which never went.
      await tester.sendKeyEvent(keyOf('g'), character: 'g');
      await tester.sendKeyEvent(keyOf('!'), character: '!');
      await tester.pump();
      expect(find.text('Akira taken out of Favourites'), findsNothing);
      expect(find.text('The last scan could read every comic'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      await type(tester, 'u');
      expect(await favourite(), isFalse);
      expect(find.text('The last scan could read every comic'), findsOneWidget);
    });

    /// The library folder is out, its comics still on disk, and the notice
    /// offers it back.
    Future<void> expectTakenOut(WidgetTester tester, ProviderContainer c) async {
      expect((await tester.runAsync(c.read(libraryStoreProvider).roots))!, isEmpty);
      expect(find.text('Comics taken out of the library; its comics stay on disk'), findsOneWidget);
      expect(find.text('Undo (u)'), findsOneWidget);
      for (final n in ['Akira', 'Dredd', 'Zot 2']) {
        expect(File('${root.path}/$n.cbz').existsSync(), isTrue);
      }
    }

    /// The library folder is back with every comic it had.
    Future<void> expectBack(WidgetTester tester, ProviderContainer c) async {
      final store = c.read(libraryStoreProvider);
      for (var i = 0; i < 40 && (await tester.runAsync(store.books))!.length < 6; i++) {
        await settle(tester);
      }
      expect([for (final r in (await tester.runAsync(store.roots))!) r.path], [root.path]);
      expect((await tester.runAsync(store.books))!, hasLength(6));
      expect(find.text('Comics taken out of the library; its comics stay on disk'), findsNothing);
    }

    testWidgets('gA says what it did and offers the folder back: u puts it in the library again', (tester) async {
      final c = await inFolder(tester);
      await press(tester, LogicalKeyboardKey.backspace);
      await type(tester, 'gA');
      await expectTakenOut(tester, c);
      await type(tester, 'u');
      await expectBack(tester, c);
    });

    testWidgets('the button of gA goes the same way: a notice, and its Undo', (tester) async {
      final c = await inFolder(tester);
      await press(tester, LogicalKeyboardKey.backspace);
      await tester.tap(find.byKey(const Key('removeRoot')));
      await settle(tester);
      await expectTakenOut(tester, c);
      await tester.tap(find.text('Undo (u)'));
      await settle(tester);
      await expectBack(tester, c);
    });

    testWidgets('undoing gA on ~/Comics makes it the default folder again', (tester) async {
      final comics = Directory('${appEnvironment['HOME']}/Comics')..createSync();
      addTearDown(() => comics.deleteSync(recursive: true));
      writeBook(comics, 'Solo.cbz', 3);
      final c = await pumpApp(tester);
      final store = c.read(libraryStoreProvider), settings = SettingsStore(db);
      Future<bool?> remembered() => tester.runAsync<bool?>(() => settings.loadBool(SettingsStore.defaultFolderRemoved));
      await tester.runAsync(() async {
        await store.addRoot(comics.path);
        await c.read(scannerProvider).scan();
      });
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Folders')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await type(tester, 'gA');
      expect((await tester.runAsync(store.roots))!, isEmpty);
      expect(await remembered(), isTrue);
      await type(tester, 'u');
      expect([for (final r in (await tester.runAsync(store.roots))!) r.path], [comics.path]);
      expect(await remembered(), isFalse);
      // Taken out again and left out, it stays out at the next start.
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await type(tester, 'gA');
      expect(await remembered(), isTrue);
      expect(await tester.runAsync(() => addDefaultFolder(store, settings, comics.path)), isFalse);
    });

    /// Akira, Blacksad and Corto in the collection Noir, which is open on
    /// the Collections tab with Akira selected.
    Future<Future<List<String>> Function()> inNoir(WidgetTester tester, ProviderContainer c) async {
      final store = c.read(libraryStoreProvider);
      await tester.runAsync(() async {
        for (final b in await store.books()) {
          if (const {'Akira', 'Blacksad', 'Corto'}.contains(b.name)) await store.addToCollection(b.key, 'Noir');
        }
      });
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Collections')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.home);
      return () async => [
        for (final b in (await tester.runAsync(store.books))!)
          if (b.collections.contains('Noir')) b.name,
      ]..sort();
    }

    testWidgets('x in an open collection takes out the marked comics, and u puts them all back', (tester) async {
      final c = await inFolder(tester);
      final noir = await inNoir(tester, c);
      await type(tester, 'VV');
      expect(find.text('2 selected'), findsOneWidget);
      await type(tester, 'x');
      expect(await noir(), ['Corto']);
      expect(find.text('2 comics taken out of Noir'), findsOneWidget);
      // It went ahead, so the marks are gone.
      expect(find.byKey(const Key('marksBar')), findsNothing);
      await type(tester, 'u');
      expect(await noir(), ['Akira', 'Blacksad', 'Corto']);
    });

    testWidgets('x: a sidecar that cannot be written is no failure, the comic is out all the same', (tester) async {
      final c = await inFolder(
        tester,
        sidecars: sidecarSyncProvider.overrideWith((ref) => _NoWrites(db, ref.watch(progressStoreProvider))),
      );
      final noir = await inNoir(tester, c);
      await type(tester, 'x');
      expect(await noir(), ['Blacksad', 'Corto']);
      expect(find.text('Akira taken out of Noir'), findsOneWidget);
      expect(find.textContaining('Could not'), findsNothing);
      await type(tester, 'u');
      expect(await noir(), ['Akira', 'Blacksad', 'Corto']);
    });

    testWidgets('x with marks of which none is in the open collection says so', (tester) async {
      final c = await inFolder(tester);
      // The last comic of the folder, marked there, is not in Noir.
      await press(tester, LogicalKeyboardKey.end);
      await type(tester, 'V');
      final noir = await inNoir(tester, c);
      expect(find.text('1 selected'), findsOneWidget);
      await type(tester, 'x');
      expect(await noir(), ['Akira', 'Blacksad', 'Corto']);
      expect(find.text('Zot #2 is not in Noir'), findsOneWidget);
      // Nothing went ahead, so the mark stays.
      expect(find.text('1 selected'), findsOneWidget);
      expect(
        notInCollectionNotice([...(await tester.runAsync(c.read(libraryStoreProvider).books))!], 'Noir'),
        'None of the 6 comics is in Noir',
      );
    });

    testWidgets('x: when the index fails part of the way, the comics taken out before still get their Undo', (
      tester,
    ) async {
      late _FailingOut failing;
      final c = await inFolder(tester, store: libraryStoreProvider.overrideWith((ref) => failing = _FailingOut(db)));
      final noir = await inNoir(tester, c);
      await type(tester, 'VV');
      await type(tester, 'V');
      expect(find.text('3 selected'), findsOneWidget);
      failing.failAt = 2;
      await type(tester, 'x');
      expect(await noir(), hasLength(2));
      expect(find.text('1 comic taken out of Noir; 2 not taken out: the library could not be updated'), findsNothing);
      final out = {'Akira', 'Blacksad', 'Corto'}.difference((await noir()).toSet()).single;
      expect(find.text('$out taken out of Noir; 2 not taken out: the library could not be updated'), findsOneWidget);
      expect(find.text('Undo (u)'), findsOneWidget);
      // It did not all go ahead: the marks stay for another try.
      expect(find.text('3 selected'), findsOneWidget);
      failing.failAt = 0;
      await type(tester, 'u');
      expect(await noir(), ['Akira', 'Blacksad', 'Corto']);

      // Refused at the first: nothing to undo, and it says so.
      failing.failAt = 1;
      await type(tester, 'x');
      expect(await noir(), ['Akira', 'Blacksad', 'Corto']);
      expect(find.text('Could not take 3 comics out of Noir: the library could not be updated'), findsOneWidget);
      expect(find.text('Undo (u)'), findsNothing);
    });

    testWidgets('an Undo that fails says so in a notice and throws nothing', (tester) async {
      late _FailingOut failing;
      final c = await inFolder(tester, store: libraryStoreProvider.overrideWith((ref) => failing = _FailingOut(db)));
      final noir = await inNoir(tester, c);
      await type(tester, 'x');
      expect(await noir(), ['Blacksad', 'Corto']);
      failing.failAdds = true;
      await type(tester, 'u');
      expect(await noir(), ['Blacksad', 'Corto']);
      expect(find.text('Could not put Akira back in Noir'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The same for a library folder that cannot be put back, once that
      // notice has had its time: a failure is not cut short by the next.
      await tester.pump(noticeTime);
      await settle(tester);
      failing.failAdds = false;
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Folders')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.home);
      await type(tester, 'gA');
      expect(find.text('Comics taken out of the library; its comics stay on disk'), findsOneWidget);
      failing.failRoots = true;
      await type(tester, 'u');
      expect(find.text('Could not put Comics back in the library'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Alt with an arrow is the arrow; Alt with a letter is no command', (tester) async {
      await inFolder(tester);
      Finder inPane(String name) => find.descendant(of: find.byKey(const Key('detail')), matching: find.text(name));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await settle(tester);
      expect(inPane('Blacksad'), findsOneWidget);
      await alt(tester, 'l');
      expect(inPane('Blacksad'), findsOneWidget);
      await type(tester, 'l');
      expect(inPane('Corto'), findsOneWidget);
    });

    testWidgets('Settings: Alt+M and Alt+B are the cover size buttons', (tester) async {
      await inFolder(tester);
      await type(tester, 'g,');
      int aRow() {
        final text = tester.widget<Text>(find.byKey(const Key('setting-coverSize'))).data!;
        return int.parse(RegExp(r'(\d+) a row').firstMatch(text)!.group(1)!);
      }

      final usual = aRow();
      await alt(tester, 'm');
      expect(aRow(), usual + 1);
      await alt(tester, 'b');
      expect(aRow(), usual);
      await alt(tester, 'b');
      expect(aRow(), usual - 1);
      // Their tooltips name the letters.
      expect(find.byTooltip('Smaller covers (Alt+M; - in the library)'), findsOneWidget);
      expect(find.byTooltip('Bigger covers (Alt+B; + in the library)'), findsOneWidget);
    });
  });

  group('the notice with an Undo', () {
    Future<(UndoNotice, ScaffoldMessengerState)> pumpNotice(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.expand())));
      return (UndoNotice(), tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)));
    }

    testWidgets('the key and then the button, still on its way out, undo once', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      var undone = 0;
      notice.show(messenger, 'Taken out', label: 'Undo', undo: () async => undone++);
      await tester.pumpAndSettle();
      expect(notice.press(), isTrue);
      // A frame later the notice is leaving, and its button still there.
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(undone, 1);
      expect(notice.press(), isFalse);
      expect(undone, 1);
    });

    testWidgets('the button and then the key undo once; a new notice has its own Undo', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      final undone = <String>[];
      notice.show(messenger, 'First', label: 'Undo', undo: () async => undone.add('first'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      expect(notice.press(), isFalse);
      await tester.pumpAndSettle();
      expect(undone, ['first']);
      // The one that shows is the one the key presses, not the one before.
      notice.show(messenger, 'Second', label: 'Undo', undo: () async => undone.add('second'));
      notice.show(messenger, 'Third', label: 'Undo', undo: () async => undone.add('third'));
      await tester.pumpAndSettle();
      expect(find.text('Third'), findsOneWidget);
      expect(notice.press(), isTrue);
      await tester.pumpAndSettle();
      expect(undone, ['first', 'third']);
      expect(find.byType(SnackBar), findsNothing);
      expect(notice.press(), isFalse);
    });

    testWidgets('it goes by itself after ten seconds, and the key has nothing to press then', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      var undone = 0;
      notice.show(messenger, 'Taken out', label: 'Undo', undo: () async => undone++);
      await tester.pumpAndSettle();
      await tester.pump(undoNoticeTime - const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Taken out'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(notice.press(), isFalse);
      expect(undone, 0);
    });

    testWidgets('a plain notice replaces it at once, whatever is up, and is itself replaced', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      var undone = 0;
      notice.show(messenger, 'First', label: 'Undo', undo: () async => undone++);
      await tester.pumpAndSettle();
      showNotice(messenger, 'Plain');
      // The very next frame: nothing waits for the first to slide away.
      await tester.pump();
      expect(find.text('First'), findsNothing);
      expect(find.text('Plain'), findsOneWidget);
      expect(notice.press(), isFalse);
      expect(undone, 0);
      // Three in a row: only the last is there, and nothing comes after it.
      showNotice(messenger, 'One');
      showNotice(messenger, 'Two');
      notice.show(messenger, 'Three', label: 'Undo', undo: () async => undone++);
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Three'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.pump(undoNoticeTime);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(find.byType(SnackBar), findsNothing);
      expect(undone, 0);
    });

    testWidgets('the key only presses the notice on screen: a second one shown while the first leaves', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      final undone = <String>[];
      notice.show(messenger, 'First', label: 'Undo', undo: () async => undone.add('first'));
      await tester.pumpAndSettle();
      // u: the first is undone and on its way out. A frame later the second.
      expect(notice.press(), isTrue);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('First'), findsOneWidget);
      notice.show(messenger, 'Second', label: 'Undo', undo: () async => undone.add('second'));
      await tester.pump();
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      expect(undone, ['first']);
      // The one that is there is the one undone, and then it is gone: no
      // notice is left with a button that does nothing.
      expect(notice.press(), isTrue);
      await tester.pumpAndSettle();
      expect(undone, ['first', 'second']);
      expect(find.byType(SnackBar), findsNothing);
      expect(notice.press(), isFalse);

      // A second shown over a first that is fully up: the same.
      notice.show(messenger, 'Third', label: 'Undo', undo: () async => undone.add('third'));
      await tester.pumpAndSettle();
      notice.show(messenger, 'Fourth', label: 'Undo', undo: () async => undone.add('fourth'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Third'), findsNothing);
      expect(find.text('Fourth'), findsOneWidget);
      expect(notice.press(), isTrue);
      await tester.pumpAndSettle();
      expect(undone, ['first', 'second', 'fourth']);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('an undo that throws is told in a notice, by key and by button', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      notice.show(messenger, 'Taken out', label: 'Undo', undo: () async => throw StateError('locked'));
      await tester.pumpAndSettle();
      expect(notice.press(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Could not undo that'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // A failure stays its time; the next notice comes after it.
      await tester.pump(noticeTime);
      await tester.pumpAndSettle();
      notice.show(
        messenger,
        'Taken out',
        label: 'Undo',
        failed: 'Could not put it back',
        undo: () async => throw StateError('locked'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Could not put it back'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // That notice has no Undo of its own.
      expect(notice.press(), isFalse);
    });

    test('every notice of the app goes through showNotice or UndoNotice', () {
      final direct = <String>[
        for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
          if (file.path.endsWith('.dart') && !file.path.endsWith('undo_notice.dart'))
            for (final (i, line) in file.readAsLinesSync().indexed)
              if (RegExp(r'\b(showSnackBar|hideCurrentSnackBar|removeCurrentSnackBar|clearSnackBars)\b').hasMatch(line))
                '${file.path}:${i + 1}',
      ];
      expect(direct, isEmpty, reason: 'a SnackBar shown directly can wait unseen behind another notice');
    });
  });

  group('a notice that must be read', () {
    Future<(UndoNotice, ScaffoldMessengerState)> pumpNotice(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.expand())));
      return (UndoNotice(), tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)));
    }

    /// Lets [time] pass and whatever slides in or out finish.
    Future<void> wait(WidgetTester tester, Duration time) async {
      await tester.pump(time);
      await tester.pumpAndSettle();
    }

    testWidgets('stays its time; a routine notice after it waits and then shows', (tester) async {
      final (_, messenger) = await pumpNotice(tester);
      showNotice(messenger, 'Could not download A', mustRead: true);
      await tester.pump();
      showNotice(messenger, 'Downloaded B');
      await tester.pumpAndSettle();
      expect(find.text('Could not download A'), findsOneWidget);
      expect(find.text('Downloaded B'), findsNothing);
      // Still there a moment before its time is up.
      await wait(tester, noticeTime - const Duration(milliseconds: 500));
      expect(find.text('Could not download A'), findsOneWidget);
      expect(find.text('Downloaded B'), findsNothing);
      await wait(tester, const Duration(milliseconds: 500));
      expect(find.text('Could not download A'), findsNothing);
      expect(find.text('Downloaded B'), findsOneWidget);
      // And that one goes as any routine notice does, with nothing after it.
      await wait(tester, noticeTime);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('two of them show in turn, each its whole time', (tester) async {
      final (_, messenger) = await pumpNotice(tester);
      showNotice(messenger, 'Could not download A', mustRead: true);
      showNotice(messenger, 'Could not download B', mustRead: true, duration: const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(find.text('Could not download A'), findsOneWidget);
      expect(find.text('Could not download B'), findsNothing);
      await wait(tester, noticeTime);
      expect(find.text('Could not download A'), findsNothing);
      expect(find.text('Could not download B'), findsOneWidget);
      await wait(tester, const Duration(seconds: 7));
      expect(find.text('Could not download B'), findsOneWidget);
      await wait(tester, const Duration(seconds: 1));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('takes the place of a routine notice at once, and of an Undo notice', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      showNotice(messenger, 'Downloaded A');
      await tester.pumpAndSettle();
      showNotice(messenger, 'Could not download B', mustRead: true);
      await tester.pump();
      expect(find.text('Downloaded A'), findsNothing);
      expect(find.text('Could not download B'), findsOneWidget);
      await tester.pumpAndSettle();
      await wait(tester, noticeTime);
      expect(find.byType(SnackBar), findsNothing);

      var undone = 0;
      notice.show(messenger, 'Taken out', label: 'Undo', undo: () async => undone++);
      await tester.pumpAndSettle();
      showNotice(messenger, 'Could not download C', mustRead: true);
      await tester.pump();
      expect(find.text('Taken out'), findsNothing);
      expect(find.text('Could not download C'), findsOneWidget);
      // The Undo is no longer offered, and does not come back afterwards.
      expect(notice.press(), isFalse);
      await tester.pumpAndSettle();
      await wait(tester, noticeTime);
      expect(find.byType(SnackBar), findsNothing);
      expect(notice.press(), isFalse);
      expect(undone, 0);
    });

    testWidgets('routine notices still replace one another at once', (tester) async {
      final (_, messenger) = await pumpNotice(tester);
      showNotice(messenger, 'Downloaded A');
      await tester.pumpAndSettle();
      showNotice(messenger, 'Downloaded B');
      await tester.pump();
      expect(find.text('Downloaded A'), findsNothing);
      expect(find.text('Downloaded B'), findsOneWidget);
      await tester.pumpAndSettle();
      await wait(tester, noticeTime);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('of the notices waiting behind it, a routine one gives way and the others keep their order', (
      tester,
    ) async {
      final (_, messenger) = await pumpNotice(tester);
      final seen = <String>[];
      void look() {
        final bars = tester.widgetList<SnackBar>(find.byType(SnackBar)).toList();
        expect(bars.length, lessThan(2));
        final text = bars.isEmpty ? '' : (bars.single.content as Text).data!;
        if (seen.isEmpty || seen.last != text) seen.add(text);
      }

      showNotice(messenger, 'Failed 1', mustRead: true);
      showNotice(messenger, 'Routine 1');
      showNotice(messenger, 'Routine 2');
      showNotice(messenger, 'Failed 2', mustRead: true);
      showNotice(messenger, 'Routine 3');
      showNotice(messenger, 'Routine 4');
      for (var i = 0; i < 80; i++) {
        await wait(tester, const Duration(milliseconds: 250));
        look();
      }
      expect(seen, ['Failed 1', 'Failed 2', 'Routine 4', '']);
    });

    testWidgets('an Undo notice that comes meanwhile waits, and u has nothing to press until it shows', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      final undone = <String>[];
      showNotice(messenger, 'Could not download A', mustRead: true);
      await tester.pumpAndSettle();
      notice.show(messenger, 'Taken out', label: 'Undo', undo: () async => undone.add('first'));
      await tester.pumpAndSettle();
      expect(find.text('Could not download A'), findsOneWidget);
      expect(find.text('Taken out'), findsNothing);
      expect(notice.press(), isFalse);
      expect(find.text('Could not download A'), findsOneWidget);
      await wait(tester, noticeTime);
      expect(find.text('Taken out'), findsOneWidget);
      expect(notice.press(), isTrue);
      await tester.pumpAndSettle();
      expect(undone, ['first']);
      expect(find.byType(SnackBar), findsNothing);

      // One that gave way while it waited never gets the key.
      showNotice(messenger, 'Could not download B', mustRead: true);
      notice.show(messenger, 'Gone again', label: 'Undo', undo: () async => undone.add('second'));
      showNotice(messenger, 'Downloaded C');
      await tester.pumpAndSettle();
      expect(find.text('Could not download B'), findsOneWidget);
      await wait(tester, noticeTime);
      expect(find.text('Downloaded C'), findsOneWidget);
      expect(notice.press(), isFalse);
      await wait(tester, noticeTime);
      expect(find.byType(SnackBar), findsNothing);
      expect(undone, ['first']);
    });

    testWidgets('an Undo notice that must be read keeps its place and its key', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      var undone = 0;
      notice.show(messenger, 'A taken out; B could not be', label: 'Undo', undo: () async => undone++, mustRead: true);
      await tester.pumpAndSettle();
      showNotice(messenger, 'Uploaded C to S3');
      await tester.pumpAndSettle();
      expect(find.text('A taken out; B could not be'), findsOneWidget);
      expect(notice.press(), isTrue);
      await tester.pumpAndSettle();
      expect(undone, 1);
      // Undone, it has gone, and what waited shows.
      expect(find.text('Uploaded C to S3'), findsOneWidget);
      await wait(tester, noticeTime);
      expect(find.byType(SnackBar), findsNothing);
    });

    /// What the notices say one after the other over [time], looked at
    /// every quarter second, '' while none shows.
    Future<List<String>> watch(WidgetTester tester, Duration time) async {
      final seen = <String>[];
      for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 250)) {
        await wait(tester, const Duration(milliseconds: 250));
        final bars = tester.widgetList<SnackBar>(find.byType(SnackBar)).toList();
        expect(bars.length, lessThan(2));
        final text = bars.isEmpty ? '' : (bars.single.content as Text).data!;
        if (seen.isEmpty || seen.last != text) seen.add(text);
      }
      return seen;
    }

    testWidgets('thirty that say the same hold the screen no longer than one', (tester) async {
      final (_, messenger) = await pumpNotice(tester);
      for (var i = 0; i < 30; i++) {
        showNotice(messenger, 'S3: the key was refused', mustRead: true);
      }
      await tester.pumpAndSettle();
      expect(find.text('S3: the key was refused'), findsOneWidget);
      // One notice's time and the slide out, and the screen is free.
      expect(await watch(tester, noticeTime + const Duration(seconds: 1)), ['S3: the key was refused', '']);
      // Gone, it can be said again: only a repeat of what shows or waits is left out.
      showNotice(messenger, 'S3: the key was refused', mustRead: true);
      await tester.pumpAndSettle();
      expect(find.text('S3: the key was refused'), findsOneWidget);
    });

    testWidgets('a burst of different ones: the first two as they are, then how many more', (tester) async {
      final (_, messenger) = await pumpNotice(tester);
      for (var i = 1; i <= 30; i++) {
        showNotice(messenger, 'Could not download $i', mustRead: true);
        // A repeat of one that waits is not counted.
        showNotice(messenger, 'Could not download 2', mustRead: true);
      }
      // Three notices' time, not thirty: 28 are counted in the last.
      final seen = await watch(tester, noticeTime * 3 + const Duration(seconds: 2));
      expect(seen, ['Could not download 1', 'Could not download 2', '… and 28 more notices', '']);
      // Exactly as many as fit are all shown as they are.
      for (var i = 1; i <= 3; i++) {
        showNotice(messenger, 'Could not move $i', mustRead: true);
      }
      expect(await watch(tester, noticeTime * 3 + const Duration(seconds: 2)), [
        'Could not move 1',
        'Could not move 2',
        'Could not move 3',
        '',
      ]);
    });

    testWidgets('an Undo notice behind a bounded burst still shows, and u works then', (tester) async {
      final (notice, messenger) = await pumpNotice(tester);
      var undone = 0;
      for (var i = 1; i <= 30; i++) {
        showNotice(messenger, 'Could not download $i', mustRead: true);
      }
      notice.show(messenger, 'Taken out', label: 'Undo', undo: () async => undone++);
      // More of what was said already do not take the Undo's place.
      for (var i = 0; i < 30; i++) {
        showNotice(messenger, 'Could not download 2', mustRead: true);
      }
      expect(notice.press(), isFalse);
      final seen = await watch(tester, noticeTime * 3 + const Duration(seconds: 1));
      expect(seen, ['Could not download 1', 'Could not download 2', '… and 28 more notices', 'Taken out']);
      expect(notice.press(), isTrue);
      await tester.pumpAndSettle();
      expect(undone, 1);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('in the app: a failure of the S3 sync is not cut short by what the sync says next', (tester) async {
      final said = StreamController<S3Notice>.broadcast();
      addTearDown(said.close);
      await inFolder(
        tester,
        s3: s3SyncProvider.overrideWith(
          (ref) => _SayingS3(
            said.stream,
            ref.watch(databaseProvider),
            sidecars: ref.watch(sidecarSyncProvider),
            settings: ref.watch(s3SettingsProvider),
            storeFor: ref.watch(remoteStoreFactoryProvider),
            coverDir: null,
          ),
        ),
      );
      expect(said.hasListener, isTrue);
      // The second of two downloads, a moment after the first failed.
      said.add((text: 'Could not download Akira: refused', failure: true));
      await tester.pump(const Duration(milliseconds: 300));
      said.add((text: 'Downloaded Blacksad', failure: false));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Could not download Akira: refused'), findsOneWidget);
      expect(find.text('Downloaded Blacksad'), findsNothing);
      await tester.pump(noticeTime - const Duration(seconds: 1));
      expect(find.text('Could not download Akira: refused'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Could not download Akira: refused'), findsNothing);
      expect(find.text('Downloaded Blacksad'), findsOneWidget);
      // Two routine ones: the later takes the earlier's place at once.
      said.add((text: 'Uploaded Corto to S3', failure: false));
      await tester.pump();
      await tester.pump();
      expect(find.text('Downloaded Blacksad'), findsNothing);
      expect(find.text('Uploaded Corto to S3'), findsOneWidget);
      // And a failure takes a routine one's place at once.
      said.add((text: 'S3: the keys were refused', failure: true));
      await tester.pump();
      await tester.pump();
      expect(find.text('Uploaded Corto to S3'), findsNothing);
      expect(find.text('S3: the keys were refused'), findsOneWidget);
      await tester.pump(noticeTime);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('the S3 branches and the order of Settings', () {
    /// Asks [ask] from a button of a bare app; what comes back gives the
    /// answer, null while the question is up.
    Future<DeleteChoice? Function()> asking(
      WidgetTester tester,
      Future<DeleteChoice> Function(BuildContext context) ask,
    ) async {
      DeleteChoice? answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                // Nothing is answered while the question is up.
                onPressed: () async {
                  answer = null;
                  answer = await ask(context);
                },
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      return () => answer;
    }

    /// Opens the question again after an answer closed it.
    Future<void> again(WidgetTester tester) async {
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
    }

    DeleteFacts facts({required bool onS3}) =>
        DeleteFacts(name: 'Akira', path: '/c/Akira.cbz', folder: false, bytes: 1200000, pages: 4, onS3: onS3);
    const cancel = Key('deleteCancel'), here = Key('deleteHere');
    const everywhere = Key('deleteEverywhere'), confirm = Key('deleteConfirm');

    /// Every way of answering a question about a comic on S3: three
    /// buttons, each by a tap and by its letter.
    Future<void> threeChoices(WidgetTester tester, DeleteChoice? Function() answer) async {
      expect(find.byKey(cancel), findsOneWidget);
      expect(find.byKey(here), findsOneWidget);
      expect(find.byKey(everywhere), findsOneWidget);
      expect(find.byKey(confirm), findsNothing);
      // Cancel has the focus, so Enter deletes nothing.
      expect(focused(tester, 'Cancel'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(answer(), DeleteChoice.cancel);
      for (final (key, letter, choice) in [
        (cancel, 'c', DeleteChoice.cancel),
        (here, 'o', DeleteChoice.here),
        (everywhere, 'd', DeleteChoice.everywhere),
      ]) {
        await again(tester);
        await tester.tap(find.byKey(key));
        await tester.pumpAndSettle();
        expect(answer(), choice, reason: 'a tap on $key');
        await again(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(keyOf(letter), character: letter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pumpAndSettle();
        expect(answer(), choice, reason: 'Alt+$letter');
        expect(find.byKey(const Key('deleteDialog')), findsNothing);
      }
    }

    testWidgets('deleting a comic on S3 asks three ways, each by its button and its letter', (tester) async {
      final answer = await asking(tester, (context) => askDelete(context, facts(onS3: true)));
      expect(find.text('Delete only here'), findsOneWidget);
      expect(find.text('Delete here and from S3'), findsOneWidget);
      await threeChoices(tester, answer);
    });

    testWidgets('a comic that is not on S3 is not offered "Delete only here"', (tester) async {
      final answer = await asking(tester, (context) => askDelete(context, facts(onS3: false)));
      expect(find.byKey(here), findsNothing);
      expect(find.byKey(everywhere), findsNothing);
      expect(find.text('Delete only here'), findsNothing);
      expect(focused(tester, 'Cancel'), isTrue);
      // Alt+O is no button's letter here.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO, character: 'o');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('deleteDialog')), findsOneWidget);
      await tester.tap(find.byKey(confirm));
      await tester.pumpAndSettle();
      expect(answer(), DeleteChoice.here);
    });

    testWidgets('deleting several: three ways when one is on S3, two when none is or all are only there', (
      tester,
    ) async {
      var answer = await asking(tester, (context) => askDeleteMany(context, [facts(onS3: true), facts(onS3: false)]));
      await threeChoices(tester, answer);

      answer = await asking(tester, (context) => askDeleteMany(context, [facts(onS3: false), facts(onS3: false)]));
      expect(find.byKey(here), findsNothing);
      expect(find.byKey(everywhere), findsNothing);
      await tester.tap(find.byKey(confirm));
      await tester.pumpAndSettle();
      expect(answer(), DeleteChoice.here);

      // Nothing of them is on this device: there is no "only here".
      answer = await asking(tester, (context) => askDeleteMany(context, const [], remoteOnly: 2));
      expect(find.byKey(here), findsNothing);
      expect(find.byKey(confirm), findsNothing);
      expect(focused(tester, 'Cancel'), isTrue);
      await tester.tap(find.byKey(everywhere));
      await tester.pumpAndSettle();
      expect(answer(), DeleteChoice.everywhere);
    });

    testWidgets('the details of a comic that is only on S3: Download, and no Details, Reset or Delete', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      LibraryBook book(S3Mark mark) => LibraryBook(
        key: 'k-${mark.name}',
        series: 'Akira',
        seriesId: 1,
        pageCount: 4,
        format: 'cbz',
        path: '${root.path}/Akira.cbz',
        addedAt: DateTime(2026),
        s3: S3Shelf(mark, size: 1200000),
      );
      Future<void> show(LibraryBook b) async {
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(b.key),
            overrides: [
              databaseProvider.overrideWithValue(db),
              coverDirProvider.overrideWithValue('${tmp.path}/covers'),
              noSidecars(db),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: BookDetail(book: b, onRead: (_, {at}) {}),
              ),
            ),
          ),
        );
        await settle(tester);
      }

      const last = [Key('bookDetails'), Key('resetBook'), Key('deleteBook')];
      await show(book(S3Mark.remote));
      expect(find.byKey(const Key('download')), findsOneWidget);
      expect(find.byKey(const Key('read')), findsNothing);
      expect(find.byKey(const Key('editBook')), findsNothing);
      for (final key in last) {
        expect(find.byKey(key), findsNothing, reason: '$key has nothing here to work on');
      }
      expect(find.text('Downloads to ${root.path}/Akira.cbz'), findsOneWidget);

      // Here and on S3: the comic's own buttons, and no Download.
      await show(book(S3Mark.synced));
      expect(find.byKey(const Key('download')), findsNothing);
      expect(find.byKey(const Key('read')), findsOneWidget);
      expect(find.byKey(const Key('editBook')), findsOneWidget);
      for (final key in last) {
        expect(find.byKey(key), findsOneWidget);
      }
    });

    testWidgets('Settings has its parts in this order from the top, which is the order Tab takes', (tester) async {
      await inFolder(tester);
      await type(tester, 'g,');
      const order = [
        'cleanUp',
        'scrollSpeed',
        'wholePage',
        'pauseWhole',
        'detector',
        'coverSize',
        'sidecars',
        'sidecarPlace',
        'export',
        'touch',
        'clearHistory',
        'exportSettings',
        's3',
      ];
      final tops = [for (final name in order) tester.getTopLeft(find.byKey(Key('setting-$name'))).dy];
      for (var i = 1; i < order.length; i++) {
        expect(tops[i], greaterThan(tops[i - 1]), reason: '${order[i]} comes after ${order[i - 1]}');
      }
      // And the headings, as read from the top.
      final dialog = find.byType(SettingsDialog);
      double top(String heading) =>
          tester.getTopLeft(find.descendant(of: dialog, matching: find.text(heading)).first).dy;
      const headings = [
        'Pages',
        'Guided view',
        'Library',
        'Sidecars',
        'Touch',
        'Reading history',
        'Back up',
        'S3 sync',
      ];
      for (var i = 1; i < headings.length; i++) {
        expect(top(headings[i]), greaterThan(top(headings[i - 1])), reason: '${headings[i]} after ${headings[i - 1]}');
      }
    });
  });

  group('for the buttons and dialogs still to come', () {
    /// The key a tooltip or label ends with in brackets, `Settings (g,)`
    /// or `Note (e on the Bookmarks tab)`, when it is a key of [keymap].
    bool namesKey(String? text, Keymap keymap) {
      final inner = RegExp(r'\(([^()]+)\)\s*$').firstMatch(text ?? '')?.group(1);
      if (inner == null) return false;
      return keymap.bindings.map(Keymap.spoken).any((k) => inner == k || inner.startsWith('$k '));
    }

    /// What a control says: its tooltip, else its label.
    String said(WidgetTester tester, Element button) {
      final w = button.widget;
      if (w is IconButton) return w.tooltip ?? '';
      if (w is RawChip) return w.tooltip ?? '';
      if (w is ActionChip) return w.tooltip ?? '';
      if (w is InputChip) return w.tooltip ?? '';
      if (w is FilterChip) return w.tooltip ?? '';
      if (w is ChoiceChip) return w.tooltip ?? '';
      String? tip;
      button.visitAncestorElements((e) {
        if (e.widget case Tooltip(:final message?)) tip = message;
        // A tooltip wraps its button closely; one further up is another's.
        return tip == null && e.widget is! Row && e.widget is! Wrap && e.widget is! Column;
      });
      if (tip != null && tip!.isNotEmpty) return tip!;
      final label = find.descendant(of: find.byElementPredicate((e) => e == button), matching: find.byType(Text));
      return [for (final t in tester.widgetList<Text>(label)) t.data ?? t.textSpan?.toPlainText() ?? ''].join(' ');
    }

    /// Whether [w] is something to press: a button of any kind, a chip, a
    /// row or switch that answers a tap, or a bare InkWell or
    /// GestureDetector with an `onTap`, which is how a button is made by
    /// hand.
    bool pressable(Widget w) => switch (w) {
      IconButton() => w.onPressed != null,
      ButtonStyleButton() => w.onPressed != null,
      ActionChip() => w.onPressed != null,
      InputChip() => w.onPressed != null || w.onSelected != null,
      FilterChip() => w.onSelected != null,
      ChoiceChip() => w.onSelected != null,
      ListTile() => w.onTap != null,
      SwitchListTile() => w.onChanged != null,
      Switch() => w.onChanged != null,
      Checkbox() => w.onChanged != null,
      InkResponse() => w.onTap != null,
      GestureDetector() => w.onTap != null,
      _ => false,
    };

    /// A bare tap handler, which is what the other controls are made of.
    bool bare(Widget w) => w is InkResponse || w is GestureDetector;

    /// Whether [inner], found under [outer], is part of it and no control
    /// of its own. A button, a chip or a switch is made of smaller
    /// controls (the InkWell in a button, the ListTile and Switch of a
    /// SwitchListTile); a segment of a segmented button is a choice among
    /// those beside it; and a bare tap handler under any control, or in
    /// Flutter's own navigation, text fields and scrollbars, is that
    /// widget's business. But a button in a row that answers a tap (Note
    /// and Remove on a bookmark's row) is a button.
    bool partOf(Widget outer, Widget inner) {
      if (outer is SegmentedButton) return true;
      if (pressable(outer) && !bare(outer) && outer is! ListTile) return true;
      if (!bare(inner)) return false;
      return pressable(outer) ||
          outer is NavigationRail ||
          outer is NavigationBar ||
          outer is TextField ||
          outer is Scrollbar ||
          outer is ModalBarrier;
    }

    /// The nearest key with a name at or above [e], to tell a control by.
    String keyOf(Element e) {
      String? name;
      bool look(Element x) {
        if (x.widget.key case ValueKey<String>(:final value)) name = value;
        return name == null;
      }

      if (look(e)) e.visitAncestorElements(look);
      return name ?? '';
    }

    /// Every enabled control on screen that a tap presses, each once: not
    /// what a counted control is made of.
    List<Element> buttons(WidgetTester tester) => [
      for (final e in find.byWidgetPredicate(pressable).evaluate())
        if (() {
          var inside = false;
          e.visitAncestorElements((x) {
            inside = partOf(x.widget, e.widget);
            return !inside;
          });
          return !inside;
        }())
          e,
    ];

    /// Controls that name no key, each for a reason AGENTS.md lists under
    /// "Buttons left without a key of their own": told by the name of the
    /// nearest key at or above them, whole or its start. A new control of
    /// any kind that is not here has to name a key.
    const noKey = <String, String>{
      'readNext': 'a shortcut: Enter on the series, then Enter on the comic',
      'continueInFolder': 'a shortcut: Enter on the folder, then Enter on the comic',
      'b:': 'a comic\'s cover: the arrows select it and Enter opens it',
      'f:': 'a folder\'s cover: the arrows and Enter',
      's:': 'a series\' or a collection\'s cover: the arrows and Enter',
      'bookmarkItem-': 'a row of the Bookmarks tab: the arrows and Enter',
      'detailBookmark-': 'a bookmark in a comic\'s details: the Bookmarks tab and M reach it with the arrows and Enter',
      'seriesBook-': 'a comic in a series\' details: Enter shows the books, the arrows and Enter read one',
      'history-': 'a sitting on the History tab: the arrows and Enter',
      'pageTile-': 'a page of the page grid: the arrows and Enter',
      'bookmarkRow-': 'a row of the reader\'s bookmark list: the arrows and Enter',
      'bookmarkRibbon': 'the bookmark ribbon: pointer only (M shows the list)',
      'partsPicker': 'the parts picker\'s backdrop, a tap beside the card: Esc; and the card, which only keeps taps',
    };

    String? excused(String key) {
      for (final MapEntry(key: name, value: why) in noKey.entries) {
        if (_named(name, key)) return why;
      }
      return null;
    }

    /// The exceptions met on the walk, so a name nothing has any more is
    /// taken off the list.
    final met = <String>{};

    /// The controls without a key that a walk found, all told at its end.
    final problems = <String>[];

    void expectKeysNamed(WidgetTester tester, Keymap keymap, {required String where, int atLeast = 1}) {
      final found = buttons(tester);
      expect(found.length, greaterThanOrEqualTo(atLeast), reason: 'buttons on $where');
      for (final b in found) {
        final text = said(tester, b);
        if (namesKey(text, keymap)) continue;
        final key = keyOf(b);
        if (excused(key) != null) {
          met.add(noKey.keys.firstWhere((n) => _named(n, key)));
          continue;
        }
        problems.add('On $where the ${b.widget.runtimeType} "$text" (under the key "$key") names no key of the keymap');
      }
    }

    /// A keymap with no key of the default one: every action is two
    /// letters, Za Zb … Ya …, but the ones that take a mark's letter.
    Keymap remapped() {
      const first = ['Z', 'Y', 'Q', 'W', 'K', 'J', 'U'];
      final intents = <ReaderIntent>[];
      final keys = <Binding>[];
      for (final b in Keymap.defaults().bindings) {
        if (b.hasLetterSlot) {
          keys.add(b);
        } else if (!intents.contains(b.intent)) {
          final n = intents.length;
          intents.add(b.intent);
          keys.add(Binding([first[n ~/ 26], String.fromCharCode(0x61 + n % 26)], b.intent, layer: b.layer));
        }
      }
      return Keymap(keys);
    }

    /// Walks the library and the reader and has every button name a key
    /// of [keymap]. With [remap] the keys typed on the way are that
    /// keymap's own, and a tooltip with a key written into its text, which
    /// passes under the default keys, names a key that is none.
    Future<void> walk(WidgetTester tester, {required bool remap}) async {
      final keymap = remap ? remapped() : Keymap.defaults();
      // What the walk types by default; remapped, the keymap's own keys.
      const usual = <ReaderIntent, Object>{
        ReaderIntent.markBook: 'V',
        ReaderIntent.filterFolders: 'F',
        ReaderIntent.bookmark: 'mm',
        ReaderIntent.pageGrid: 'p',
        ReaderIntent.bookmarkList: 'M',
        ReaderIntent.pickPart: 'gp',
        ReaderIntent.nextStep: 'l',
        ReaderIntent.activate: LogicalKeyboardKey.enter,
        ReaderIntent.removeRoot: 'gA',
        ReaderIntent.back: LogicalKeyboardKey.escape,
        ReaderIntent.up: LogicalKeyboardKey.backspace,
        ReaderIntent.lastPage: LogicalKeyboardKey.end,
        ReaderIntent.firstPage: LogicalKeyboardKey.home,
      };
      Future<void> key(ReaderIntent intent) async {
        final how = remap ? keymap.hint(intent)! : usual[intent]!;
        how is String ? await type(tester, how) : await press(tester, how as LogicalKeyboardKey);
      }

      final c = await inFolder(tester, keymap: remap ? keymap : null, remapped: remap);
      // The header, the filter line, the details pane of a comic.
      expectKeysNamed(tester, keymap, where: 'the Folders tab with a comic selected', atLeast: 12);
      // The marks bar.
      await key(ReaderIntent.markBook);
      expect(find.byKey(const Key('marksBar')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the library with a comic marked', atLeast: 16);
      await key(ReaderIntent.back);
      // A filter on: its line's chips and Clear. (A dialog's keys are its
      // own, whatever the keymap.)
      await key(ReaderIntent.filterFolders);
      await press(tester, LogicalKeyboardKey.space);
      await alt(tester, 'd');
      expect(find.byKey(const Key('filterBarClear')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the Folders tab with a filter', atLeast: 10);
      await key(ReaderIntent.filterFolders);
      await alt(tester, 'c');
      await alt(tester, 'd');
      // A library folder selected: its details.
      await key(ReaderIntent.up);
      expect(find.byKey(const Key('removeRoot')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the Folders tab with a library folder selected', atLeast: 8);
      // The reader and what lies over it, with a bookmark made there.
      await open(tester, c, 'Dredd');
      await key(ReaderIntent.nextStep);
      await key(ReaderIntent.bookmark);
      expectKeysNamed(tester, keymap, where: 'the reader', atLeast: 7);
      await key(ReaderIntent.pageGrid);
      expect(find.byKey(const Key('pageGridClose')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the page grid', atLeast: 10);
      await key(ReaderIntent.pageGrid);
      await key(ReaderIntent.bookmarkList);
      expect(find.byKey(const Key('bookmarkList')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the bookmark list', atLeast: 10);
      await key(ReaderIntent.bookmarkList);
      await key(ReaderIntent.pickPart);
      expect(find.byKey(const Key('partsClose')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the parts picker', atLeast: 8);
      await key(ReaderIntent.back);
      await key(ReaderIntent.back);
      expect(c.read(readerProvider).book, isNull);
      await key(ReaderIntent.bookmarkList);
      expect(find.byKey(const Key('bookmarksTab')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the Bookmarks tab', atLeast: 7);
      // The History tab: the sitting just had.
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('History')));
      await settle(tester);
      expectKeysNamed(tester, keymap, where: 'the History tab', atLeast: 4);
      // A series selected: Rename has a key, Read is a shortcut (noKey).
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Series')));
      await settle(tester);
      await key(ReaderIntent.lastPage);
      expect(find.byKey(const Key('readNext')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the Series tab with a series selected', atLeast: 6);
      // A notice with an Undo: its button names the key too.
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Folders')));
      await settle(tester);
      await key(ReaderIntent.firstPage);
      // The library folder again, now with a comic begun: Continue.
      expect(find.byKey(const Key('continueInFolder')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'a library folder with a comic begun', atLeast: 8);
      // In it, the comic with the bookmark: further down its details the
      // bookmark has a row.
      await key(ReaderIntent.activate);
      for (var i = 0; i < 3; i++) {
        await key(ReaderIntent.nextStep);
      }
      await tester.drag(find.byKey(const Key('detail')), const Offset(0, -600));
      await settle(tester);
      expectKeysNamed(tester, keymap, where: 'the details of a comic with a bookmark', atLeast: 8);
      await key(ReaderIntent.up);
      await key(ReaderIntent.removeRoot);
      expect(find.byType(SnackBarAction), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the library with a notice that offers an Undo', atLeast: 3);
      expect(problems, isEmpty, reason: problems.join('\n'));
    }

    testWidgets('every button of the library and the reader names a live key', (tester) async {
      await walk(tester, remap: false);
      // Every exception is one the walk still meets.
      expect(noKey.keys.toSet().difference(met), isEmpty, reason: 'exceptions no control needs any more');
    });

    testWidgets('and names the key of a keymap that has none of the default keys', (tester) async {
      await walk(tester, remap: true);
    });

    /// The dialog that is up: it is under [DialogHotkeys], a control of
    /// its own has the focus, every text button has a letter, and Tab
    /// reaches every enabled control.
    Future<void> expectKeyboardDialog(WidgetTester tester, String name) async {
      final dialog = find.byType(DialogHotkeys).last;
      expect(dialog, findsOneWidget, reason: '$name is not wrapped in DialogHotkeys');
      final focus = FocusManager.instance.primaryFocus;
      var inside = false;
      focus?.context?.visitAncestorElements((e) {
        inside = e.widget is DialogHotkeys;
        return !inside;
      });
      expect(inside, isTrue, reason: '$name gives no control of its own the focus: it is on ${focus?.debugLabel}');

      Finder within(Finder f) => find.descendant(of: dialog, matching: f);
      final labelled = within(find.byWidgetPredicate((w) => w is ButtonStyleButton && w.onPressed != null))
          .evaluate()
          .where((e) {
            final self = find.byElementPredicate((x) => x == e);
            return find.ancestor(of: self, matching: find.byType(IconButton)).evaluate().isEmpty &&
                find
                    .ancestor(of: self, matching: find.byWidgetPredicate((w) => w is SegmentedButton))
                    .evaluate()
                    .isEmpty;
          })
          .toList();
      expect(labelled, isNotEmpty, reason: '$name has no button');
      final letters = <String>{};
      for (final b in labelled) {
        final label = find.descendant(of: find.byElementPredicate((x) => x == b), matching: find.byType(Mnemonic));
        expect(label, findsOneWidget, reason: 'A button of $name has no Alt+letter: ${b.widget.key}');
        final m = tester.widget<Mnemonic>(label);
        final letter = (m.letter ?? m.text[0]).toLowerCase();
        expect(letters.add(letter), isTrue, reason: 'Two buttons of $name share Alt+$letter');
        expect(m.text.toLowerCase(), contains(letter));
      }

      // Tab all the way round, then every enabled control was a stop.
      final stops = <FocusNode>{};
      for (var i = 0; i < 80; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump(const Duration(milliseconds: 50));
        final at = FocusManager.instance.primaryFocus;
        if (at == null || !stops.add(at)) break;
      }
      final controls = within(
        find.byWidgetPredicate(
          (w) =>
              (w is ButtonStyleButton && w.onPressed != null) ||
              (w is SwitchListTile && w.onChanged != null) ||
              (w is Slider && w.onChanged != null) ||
              (w is RawChip && w.isEnabled) ||
              // A text to select and copy is no stop; a field is.
              (w is EditableText && !w.readOnly),
        ),
      ).evaluate();
      for (final control in controls) {
        // A control's focus node is somewhere inside it.
        final reached = stops.any((node) {
          var inside = false;
          node.context?.visitAncestorElements((e) {
            inside = e == control;
            return !inside;
          });
          return inside;
        });
        expect(reached, isTrue, reason: 'Tab does not reach ${control.widget} in $name');
      }
    }

    testWidgets('every dialog can be worked by keys alone', (tester) async {
      final c = await inFolder(tester);

      /// The letter of the button that leaves the dialog on top with
      /// nothing done, if it has one.
      String? leaveLetter() {
        final labels = tester.widgetList<Mnemonic>(
          find.descendant(of: find.byType(DialogHotkeys).last, matching: find.byType(Mnemonic)),
        );
        for (final m in labels) {
          if (const {'Cancel', 'Close', 'Done'}.contains(m.text)) return Mnemonic.letterOf(m.text, m.letter);
        }
        return null;
      }

      // Each dialog is opened twice. Esc closes it, and then the Alt+letter
      // of its Cancel, Close or Done does: one key, one route popped, the
      // dialog's own and not the one under it.
      Future<void> check(String name, {required Future<void> Function() open, int close = 1}) async {
        await open();
        await expectKeyboardDialog(tester, name);
        var before = routes.pops;
        await press(tester, LogicalKeyboardKey.escape);
        expect(routes.pops - before, 1, reason: 'routes popped by Esc in $name');
        for (var i = 1; i < close; i++) {
          await press(tester, LogicalKeyboardKey.escape);
        }
        expect(find.byType(DialogHotkeys), findsNothing, reason: 'Esc does not close $name');

        await open();
        final dialogs = find.byType(DialogHotkeys).evaluate().length;
        final letter = leaveLetter();
        expect(letter, isNotNull, reason: '$name has no Cancel, Close or Done with a letter');
        before = routes.pops;
        await alt(tester, letter!);
        expect(routes.pops - before, 1, reason: 'routes popped by Alt+$letter in $name');
        expect(find.byType(DialogHotkeys).evaluate().length, dialogs - 1, reason: 'Alt+$letter does not leave $name');
        expect(find.byType(HomeScreen), findsOneWidget);
        for (var i = 1; i < close; i++) {
          await press(tester, LogicalKeyboardKey.escape);
        }
        expect(find.byType(DialogHotkeys), findsNothing);
      }

      await check('Settings', open: () => type(tester, 'g,'));
      await check(
        'Clear reading history',
        open: () async {
          await type(tester, 'g,');
          await alt(tester, 'h');
        },
        close: 2,
      );
      await check('Delete', open: () => type(tester, 'gd'));
      await check('Reset', open: () => type(tester, 'X'));
      await check('Collection', open: () => type(tester, 'gc'));
      await check('Filter', open: () => type(tester, 'F'));
      await check('Edit', open: () => type(tester, 'e'));
      await check('Move', open: () => type(tester, 'gm'));
      await check(
        'New folder',
        open: () async {
          await type(tester, 'gm');
          await alt(tester, 'n');
        },
        close: 2,
      );
      // The reader's: the details, and a bookmark's note.
      await open(tester, c, 'Dredd');
      // The details have no Cancel: their one lettered button, Redo
      // panels, has tests of its own above.
      await type(tester, 'I');
      // Its rows come once the comic's report is read, and Redo
      // panels, far down the list, once End has scrolled there.
      for (var i = 0; i < 20 && find.byKey(const Key('detailsRedoPanels')).evaluate().isEmpty; i++) {
        await press(tester, LogicalKeyboardKey.end);
      }
      await expectKeyboardDialog(tester, 'Details');
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.byType(DialogHotkeys), findsNothing, reason: 'Esc does not close Details');
      await type(tester, 'mm');
      await type(tester, 'M');
      await check('Bookmark note', open: () => type(tester, 'e'));
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.escape);
      // A series' new name.
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Series')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.end);
      await check('Rename series', open: () => type(tester, 'e'));
      expect(find.byKey(const Key('readNext')), findsOneWidget);
    });

    /// What opens something over the screen that is no AlertDialog,
    /// SimpleDialog or Dialog: a sheet, a menu, a route made by hand.
    /// Each takes the focus, or the pointer alone, and so needs keys of
    /// its own thought through.
    final otherOverlays = RegExp(
      r'(?<![A-Za-z_])(showModalBottomSheet|showBottomSheet|showMenu|PopupMenuButton|DropdownButton|'
      r'DropdownButtonFormField|DropdownMenu|MenuAnchor|showGeneralDialog|RawDialogRoute|DialogRoute|'
      r'PageRouteBuilder|MaterialPageRoute|CupertinoPageRoute|ModalBottomSheetRoute|PopupRoute|OverlayEntry|'
      r'showDatePicker|showTimePicker|showDateRangePicker|showSearch|showAboutDialog|showLicensePage)\b',
    );

    /// The ones there are, each with the reason it is all right.
    const knownOverlays = {
      // The collection question's route, pushed in the asker's own call
      // so that keys typed at once are its; what it shows is the
      // CollectionDialog, which is wrapped and found by the scan below.
      'lib/src/library/collection_dialog.dart': {'DialogRoute'},
    };

    /// [code] without its comments, the line count kept.
    String uncommented(String code) => code.replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');

    List<String> overlayProblems(String path, String code) => [
      for (final m in otherOverlays.allMatches(uncommented(code)))
        if (!(knownOverlays[path]?.contains(m.group(1)) ?? false))
          '$path: ${m.group(1)} opens something over the screen that the scan for dialogs does not know; '
              'give it keys (DialogHotkeys) and list it in knownOverlays with the reason',
    ];

    test('the scan knows a sheet, a menu, a dropdown and a route made by hand', () {
      for (final code in [
        'showModalBottomSheet<void>(context: context, builder: (_) => x);',
        'await showMenu(context: context, items: []);',
        'PopupMenuButton<int>(itemBuilder: (_) => [])',
        'DropdownButton<int>(items: const [], onChanged: null)',
        'showGeneralDialog(context: context, pageBuilder: (_, _, _) => x);',
        'Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => x));',
        'navigator.push(DialogRoute<void>(context: context, builder: (_) => x));',
        'Overlay.of(context).insert(OverlayEntry(builder: (_) => x));',
      ]) {
        expect(overlayProblems('lib/x.dart', code), hasLength(1), reason: code);
      }
      // A comment about one is none, nor a name that only contains one.
      expect(
        overlayProblems('lib/x.dart', '  // like showMenu(…)\n  final myShowMenu = 1; _showMenuLater();'),
        isEmpty,
      );
      // The known one is excused in its own file only.
      expect(overlayProblems('lib/src/library/collection_dialog.dart', 'DialogRoute<String>('), isEmpty);
      expect(overlayProblems('lib/src/library/collection_dialog.dart', 'showMenu('), hasLength(1));
    });

    test('no dialog in lib/ is built without DialogHotkeys, and none labels a button with plain Text', () {
      final problems = <String>[];
      final files = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
      final overlaysMet = <String>{};
      for (final file in files) {
        if (file.path.endsWith('.g.dart') || file.path.endsWith('hotkeys.dart')) continue;
        final code = file.readAsStringSync();
        problems.addAll(overlayProblems(file.path, code));
        if (otherOverlays.hasMatch(uncommented(code))) overlaysMet.add(file.path);
        // Every dialog there is: AlertDialog, Dialog and Dialog.fullscreen.
        for (final m in RegExp(r'(?<![A-Za-z_.])(AlertDialog|SimpleDialog|Dialog(\.fullscreen)?)\(').allMatches(code)) {
          final line = code.substring(code.lastIndexOf('\n', m.start) + 1, m.start);
          if (line.trimLeft().startsWith('//')) continue;
          // The wrapper is the dialog's parent, or (the details view) the
          // parent of the choice between the two kinds of dialog.
          final before = code.substring(m.start > 400 ? m.start - 400 : 0, m.start);
          final wrapped =
              RegExp(r'DialogHotkeys\(\s*child:\s*(\w+\s*\?\s*)?$').hasMatch(before) ||
              RegExp(r'DialogHotkeys\(\s*child: narrow\s*\?[^;]*$').hasMatch(before);
          if (!wrapped) problems.add('${file.path}: ${m.group(1)} without DialogHotkeys');
        }
        // A dialog's actions are buttons with letters.
        for (final m in RegExp(r'\bactions: \[').allMatches(code)) {
          var depth = 1, i = m.end;
          while (depth > 0 && i < code.length) {
            if (code[i] == '[') depth++;
            if (code[i] == ']') depth--;
            i++;
          }
          final actions = code.substring(m.end, i);
          if (RegExp(r'(child|label): (const )?Text\(').hasMatch(actions)) {
            problems.add('${file.path}: a dialog button labelled with Text, not Mnemonic');
          }
        }
        // Alt and a letter is taken in one place, DialogHotkeys: a second
        // handler in a dialog acts on the same press (two routes popped).
        if (RegExp(r'alt:\s*true').hasMatch(uncommented(code))) {
          problems.add('${file.path}: a shortcut with Alt of its own; use Mnemonic or DialogKey');
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
      expect(overlaysMet, knownOverlays.keys.toSet(), reason: 'knownOverlays lists a file that has none any more');
    });
  });
}

/// Counts the routes popped: a dialog's key closes its dialog and nothing
/// under it.
class _Routes extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => pops++;
}

/// Sidecars on a shelf that cannot be written: every write throws.
class _NoWrites extends SidecarSync {
  _NoWrites(super.db, ProgressStore progress) : super(progress: progress);

  @override
  Future<SidecarImport> attach(String path, String contentKey, {required bool folder, bool whole = false}) async =>
      SidecarImport.none;

  @override
  void touch(String contentKey) {}

  @override
  Future<bool> write(String contentKey) => throw FileSystemException('Read-only file system', contentKey);

  @override
  Future<void> flush() => progress.flush();
}

/// Whether [key] is the exception [name]: the same, or, for a name that
/// ends in `:` or `-`, one that starts with it.
bool _named(String name, String key) => name.endsWith(':') || name.endsWith('-') ? key.startsWith(name) : key == name;

/// A library whose index can be told to refuse: the [failAt]th comic taken
/// out of a collection (0: none), every comic put in one, or a folder
/// added.
class _FailingOut extends LibraryStore {
  _FailingOut(super.db);

  int failAt = 0;
  bool failAdds = false;
  bool failRoots = false;
  int _taken = 0;

  @override
  Future<void> removeFromCollection(String contentKey, String name) {
    if (failAt > 0 && ++_taken == failAt) {
      _taken = 0;
      throw StateError('the index is locked');
    }
    return super.removeFromCollection(contentKey, name);
  }

  @override
  Future<bool> addToCollection(String contentKey, String name) =>
      failAdds ? throw StateError('the index is locked') : super.addToCollection(contentKey, name);

  @override
  Future<int> addRoot(String path) => failRoots ? throw StateError('the index is locked') : super.addRoot(path);
}

/// The S3 sync as far as the app's notices go: says what the test says and
/// never looks for a bucket.
class _SayingS3 extends S3Sync {
  _SayingS3(
    this._said,
    super.db, {
    required super.sidecars,
    required super.settings,
    required super.storeFor,
    required super.coverDir,
  });

  final Stream<S3Notice> _said;

  @override
  Stream<S3Notice> get notices => _said;

  @override
  Future<void> start() async {}
}
