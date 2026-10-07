import 'dart:async';
import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/hotkeys.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/library/settings_dialog.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/scroll_speed.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hotkeys_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    db = AppDatabase(NativeDatabase.memory());
    // Each with its own number of pages: the same pages would be one comic.
    for (final n in ['Akira', 'Blacksad', 'Corto', 'Dredd']) {
      writeBook(root, '$n.cbz', n.codeUnitAt(0) - 63);
    }
    // And a series of two, for the Series tab.
    writeBook(root, 'Zot 1.cbz', 7);
    writeBook(root, 'Zot 2.cbz', 8);
  });
  tearDown(() async {
    DialogHotkeys.debugTouchFirst = null;
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester, {Keymap? keymap}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue('${tmp.path}/covers'),
          classicCvOnly,
          noSidecars(db),
          if (keymap != null) keymapProvider.overrideWithValue(keymap),
        ],
        child: const ComicRedrApp(),
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
    // The test keyboard has no key for ! and *: Shift+1 and Shift+8 type them.
    '!': LogicalKeyboardKey.digit1,
    '*': LogicalKeyboardKey.digit8,
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
  Future<ProviderContainer> inFolder(WidgetTester tester, {Keymap? keymap}) async {
    final c = await pumpApp(tester, keymap: keymap);
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(root.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Folders')));
    await settle(tester);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.enter);
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
  });

  group('for the buttons and dialogs still to come', () {
    /// The key a tooltip or label ends with in brackets, `Settings (g,)`
    /// or `Note (e on the Bookmarks tab)`, when it is a key of [keymap].
    bool namesKey(String? text, Keymap keymap) {
      final inner = RegExp(r'\(([^()]+)\)\s*$').firstMatch(text ?? '')?.group(1);
      if (inner == null) return false;
      return keymap.bindings.map(Keymap.spoken).any((k) => inner == k || inner.startsWith('$k '));
    }

    /// What a button says: its tooltip, else its label.
    String said(WidgetTester tester, Element button) {
      final w = button.widget;
      if (w is IconButton) return w.tooltip ?? '';
      if (w is ActionChip) return w.tooltip ?? '';
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

    /// Every enabled button on screen, but a segment of a segmented
    /// button, which is a choice among the buttons beside it.
    List<Element> buttons(WidgetTester tester) => [
      for (final e in find.byWidgetPredicate((w) {
        if (w is IconButton) return w.onPressed != null;
        if (w is ActionChip) return w.onPressed != null;
        return w is ButtonStyleButton && w.onPressed != null;
      }).evaluate())
        if (find
                .ancestor(of: find.byElementPredicate((x) => x == e), matching: find.byType(IconButton))
                .evaluate()
                .isEmpty &&
            find
                .ancestor(of: find.byElementPredicate((x) => x == e), matching: find.byType(SegmentedButton<Object?>))
                .evaluate()
                .isEmpty &&
            find
                .ancestor(
                  of: find.byElementPredicate((x) => x == e),
                  matching: find.byWidgetPredicate((w) => w is SegmentedButton),
                )
                .evaluate()
                .isEmpty)
          e,
    ];

    /// Buttons that name no key, each for a reason AGENTS.md lists: they
    /// are shortcuts to something the arrows and Enter reach.
    const noKey = {'readNext', 'continueInFolder'};

    void expectKeysNamed(WidgetTester tester, Keymap keymap, {required String where, int atLeast = 1}) {
      final found = buttons(tester);
      expect(found.length, greaterThanOrEqualTo(atLeast), reason: 'buttons on $where');
      for (final b in found) {
        final key = b.widget.key;
        if (key is ValueKey<String> && noKey.contains(key.value)) continue;
        final text = said(tester, b);
        expect(namesKey(text, keymap), isTrue, reason: 'On $where the button "$text" (${b.widget.key}) names no key');
      }
    }

    testWidgets('every button of the library and the reader names a live key', (tester) async {
      final keymap = Keymap.defaults();
      final c = await inFolder(tester);
      // The header, the filter line, the details pane of a comic.
      expectKeysNamed(tester, keymap, where: 'the Folders tab with a comic selected', atLeast: 12);
      // The marks bar.
      await type(tester, 'V');
      expect(find.byKey(const Key('marksBar')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the library with a comic marked', atLeast: 16);
      await press(tester, LogicalKeyboardKey.escape);
      // A filter on: its line's chips and Clear.
      await type(tester, 'F');
      await press(tester, LogicalKeyboardKey.space);
      await alt(tester, 'd');
      expect(find.byKey(const Key('filterBarClear')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the Folders tab with a filter', atLeast: 10);
      await type(tester, 'F');
      await alt(tester, 'c');
      await alt(tester, 'd');
      // A library folder selected: its details.
      await press(tester, LogicalKeyboardKey.backspace);
      expect(find.byKey(const Key('removeRoot')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the Folders tab with a library folder selected', atLeast: 8);
      // The reader and what lies over it, with a bookmark made there.
      await open(tester, c, 'Dredd');
      await type(tester, 'mm');
      expectKeysNamed(tester, keymap, where: 'the reader', atLeast: 7);
      await type(tester, 'p');
      expect(find.byKey(const Key('pageGridClose')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the page grid', atLeast: 10);
      await type(tester, 'p');
      await type(tester, 'M');
      expect(find.byKey(const Key('bookmarkList')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the bookmark list', atLeast: 10);
      await type(tester, 'M');
      await type(tester, 'gp');
      expect(find.byKey(const Key('partsClose')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the parts picker', atLeast: 8);
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.escape);
      expect(c.read(readerProvider).book, isNull);
      await type(tester, 'M');
      expect(find.byKey(const Key('bookmarksTab')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the Bookmarks tab', atLeast: 7);
      // A series selected: Rename has a key, Read is a shortcut (noKey).
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Series')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.end);
      expect(find.byKey(const Key('readNext')), findsOneWidget);
      expectKeysNamed(tester, keymap, where: 'the Series tab with a series selected', atLeast: 6);
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
      Future<void> check(String name, {required Future<void> Function() open, int close = 1}) async {
        await open();
        await expectKeyboardDialog(tester, name);
        for (var i = 0; i < close; i++) {
          await press(tester, LogicalKeyboardKey.escape);
        }
        expect(find.byType(DialogHotkeys), findsNothing, reason: 'Esc does not close $name');
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
      await check(
        'Details',
        open: () async {
          await type(tester, 'I');
          // Its rows come once the comic's report is read, and Redo
          // panels, far down the list, once End has scrolled there.
          for (var i = 0; i < 20 && find.byKey(const Key('detailsRedoPanels')).evaluate().isEmpty; i++) {
            await press(tester, LogicalKeyboardKey.end);
          }
        },
      );
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

    test('no dialog in lib/ is built without DialogHotkeys, and none labels a button with plain Text', () {
      final problems = <String>[];
      final files = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
      for (final file in files) {
        if (file.path.endsWith('.g.dart') || file.path.endsWith('hotkeys.dart')) continue;
        final code = file.readAsStringSync();
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
      }
      expect(problems, isEmpty);
    });
  });
}
