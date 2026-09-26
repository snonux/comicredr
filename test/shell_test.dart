import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/keymap_overlay.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

import 'support/fixtures.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('reader_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  // The in-memory database is left to the garbage collector: the app may
  // still flush a debounced position into it while the tree is torn down.
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db), classicCvOnly], child: const ComicRedrApp()),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  /// Real isolates and file IO need real time, outside the fake clock.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  /// Opens a book on the real event loop: isolates and files don't run on
  /// the test's fake clock.
  Future<void> open(WidgetTester tester, ProviderContainer c, String path) async {
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
  }

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

  testWidgets('opens a CBZ from the command line and pages through it', (tester) async {
    final path = writeBook(tmp, 'Test Comic 01.cbz', 6);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    expect(c.read(readerProvider).pageCount, 6);
    expect(status(tester), contains('page 1 / 6'));
    expect(find.byKey(const Key('page-image')), findsOneWidget);
    double progress() => tester.widget<LinearProgressIndicator>(find.byKey(const Key('progress'))).value!;
    expect(progress(), closeTo(1 / 6, 1e-9));

    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).page, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(c.read(readerProvider).page, 4);
    expect(status(tester), contains('5 / 6'));

    await key(tester, LogicalKeyboardKey.keyG);
    await key(tester, LogicalKeyboardKey.keyG);
    expect(c.read(readerProvider).page, 0);

    // 4G jumps to page 4, '' jumps back.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'G');
    await settle(tester);
    expect(c.read(readerProvider).page, 3);
    // The test harness has no key code for ', so dispatch what '' resolves to
    // (the resolver's own tests cover the key sequence).
    await tester.runAsync(() => c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.jumpBack)));
    expect(c.read(readerProvider).page, 0);

    // Spread mode keeps the cover alone, then pairs.
    await key(tester, LogicalKeyboardKey.keyD);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).unit, [1, 2]);
    expect(status(tester), contains('pages 2–3 / 6'));
    expect(progress(), closeTo(3 / 6, 1e-9));

    // Closing the book flushes the position.
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    expect(c.read(readerProvider).book, isNull);
    await tester.runAsync(() async {
      expect(await db.select(db.progress).get(), hasLength(1));
    });
  });

  testWidgets("Android's back leaves guided view, then the book, and never closes the app from the reader", (
    tester,
  ) async {
    final path = writeBook(tmp, 'Back.cbz', 4);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    await key(tester, LogicalKeyboardKey.keyV);
    expect(c.read(readerProvider).guided, isTrue);

    // handlePopRoute is what the engine calls for the back button or gesture;
    // true means the app handled it rather than letting Android close it.
    Future<bool> back() async {
      final handled = await tester.binding.handlePopRoute();
      await settle(tester);
      return handled;
    }

    expect(await back(), isTrue);
    expect(c.read(readerProvider).guided, isFalse);
    expect(c.read(readerProvider).book, isNotNull);
    expect(await back(), isTrue);
    expect(c.read(readerProvider).book, isNull);
  });

  testWidgets("the status line's back arrow does the same on Linux, for a touchscreen", (tester) async {
    final path = writeBook(tmp, 'Arrow.cbz', 4);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    await key(tester, LogicalKeyboardKey.keyV);
    expect(c.read(readerProvider).guided, isTrue);

    await tester.tap(find.byKey(const Key('backButton')));
    await settle(tester);
    expect(c.read(readerProvider).guided, isFalse);
    expect(c.read(readerProvider).book, isNotNull);
    await tester.tap(find.byKey(const Key('backButton')));
    await settle(tester);
    expect(c.read(readerProvider).book, isNull);
  });

  testWidgets('narrow screens put the page counter first and drop the file name', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final path = writeBook(tmp, 'A Rather Long Title For A Phone 01.cbz', 6);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    expect(status(tester), startsWith('page 1 / 6'));
    expect(find.text('A Rather Long Title For A Phone 01.cbz'), findsNothing);

    // Without a keyboard, the status line's buttons are the way into guided
    // view and balloons.
    expect(find.byKey(const Key('balloonsButton')), findsNothing);
    await tester.tap(find.byKey(const Key('guidedButton')));
    await settle(tester);
    expect(c.read(readerProvider).guided, isTrue);
    await tester.tap(find.byKey(const Key('balloonsButton')));
    await settle(tester);
    expect(c.read(readerProvider).balloons, isTrue);
    await tester.tap(find.byKey(const Key('guidedButton')));
    await settle(tester);
    expect(c.read(readerProvider).guided, isFalse);
  });

  testWidgets('reopening resumes where reading stopped', (tester) async {
    final path = writeBook(tmp, 'Resume.cbz', 8);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await key(tester, LogicalKeyboardKey.keyL);
    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await open(tester, c, path);
    expect(c.read(readerProvider).page, 5);
    expect(status(tester), 'Resumed at page 6');
  });

  testWidgets('a RAR is refused with a way forward', (tester) async {
    final path = '${tmp.path}/real.cbr';
    File(path).writeAsBytesSync([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0, 0, 0]);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    expect(status(tester), contains('RAR archive'));
    expect(find.text('Open a comic'), findsOneWidget);
  });

  testWidgets('] opens the next book in the folder', (tester) async {
    writeBook(tmp, 'Series 01.cbz', 2);
    final second = writeBook(tmp, 'Series 02.cbz', 3);
    final c = await pumpApp(tester);
    await open(tester, c, '${tmp.path}/Series 01.cbz');
    await tester.runAsync(() => c.read(readerProvider.notifier).handle(const ReaderCommand(ReaderIntent.nextBook)));
    await settle(tester);
    expect(c.read(readerProvider).book?.path, second);
  });

  testWidgets('t trims the scan margins and i dims the page, both kept for the next book', (tester) async {
    // One panel with wide white margins, widest at the bottom.
    final page = gridPage(400, 600, [(40, 60, 320, 340)]);
    final path = writeBookOf(tmp, 'Margins.cbz', [page, page]);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    Size shown() => tester.getSize(find.byKey(const Key('page-image')));
    expect(shown().width / shown().height, closeTo(400 / 600, 0.01));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyT, character: 't');
    await settle(tester);
    await settle(tester);
    expect(c.read(readerProvider).trim, isTrue);
    expect(status(tester), contains('Auto-trim'));
    // Cut to the panel plus a 1% pad: 82% of the width, 71% of the height
    // (the bottom margin is capped at 20%).
    expect(shown().width / shown().height, closeTo((0.82 * 400) / (0.71 * 600), 0.02));

    await key(tester, LogicalKeyboardKey.keyL);
    await settle(tester);
    expect(shown().width / shown().height, closeTo((0.82 * 400) / (0.71 * 600), 0.02));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyI, character: 'i');
    await settle(tester);
    expect(find.byType(ColorFiltered), findsOneWidget);

    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await open(tester, c, path);
    expect(c.read(readerProvider).trim, isTrue);
    expect(c.read(readerProvider).night, isTrue);
  });

  testWidgets('c cleans up an old scan: whiter paper, a sharper page, kept for the next book', (tester) async {
    // A faded scan: grey paper, grey ink, and fewer pixels than the screen.
    final px = Uint8List(200 * 300);
    for (var i = 0; i < px.length; i++) {
      px[i] = (i ~/ 200) % 6 == 0 ? 90 : 205;
    }
    final page = encodeGrayPng(200, 300, px);
    final path = writeBookOf(tmp, 'Faded.cbz', [page, page]);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    CustomPaint shown() => tester.widget<CustomPaint>(find.byKey(const Key('page-image')));
    expect((shown().painter! as dynamic).levels.isNone as bool, isTrue);
    expect((shown().painter! as dynamic).image.width as int, 200);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyC, character: 'c');
    await settle(tester);
    await settle(tester);
    expect(c.read(readerProvider).cleanUp, isTrue);
    expect(status(tester), contains('Clean-up on'));
    final levels = (shown().painter! as dynamic).levels as Levels;
    expect(levels.apply(205, 205, 205).$1, greaterThan(250), reason: 'the paper goes white');
    expect(levels.apply(90, 90, 90).$1, lessThan(80), reason: 'the ink darker');
    expect((shown().painter! as dynamic).image.width as int, 400, reason: 'enlarged twice over, no more');

    await tester.runAsync(() => c.read(readerProvider.notifier).close());
    await open(tester, c, path);
    expect(c.read(readerProvider).cleanUp, isTrue);
    await settle(tester);
    expect((shown().painter! as dynamic).levels.isNone as bool, isFalse);

    // Zoomed in, c changes the page and keeps the zoom.
    double zoom() => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    tester.state<ReaderViewState>(find.byType(ReaderView)).handle(const ReaderCommand(ReaderIntent.zoomIn, count: 2));
    await settle(tester);
    expect(zoom(), greaterThan(1.1));
    final zoomed = zoom();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC, character: 'c');
    await settle(tester);
    await settle(tester);
    expect(status(tester), contains('Clean-up off'));
    expect(zoom(), zoomed);
    expect((shown().painter! as dynamic).levels.isNone as bool, isTrue);
    expect((shown().painter! as dynamic).image.width as int, 200);
  });

  testWidgets('keys.toml remaps keys, and ? names the file and its problems', (tester) async {
    final load = keymapFromToml('[keys]\nnextStep = "x"\nnoSuchAction = "q"\n');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          classicCvOnly,
          keymapLoadProvider.overrideWithValue((load: load, path: '/home/me/.config/comicredr/keys.toml')),
          appDataDirProvider.overrideWithValue('/home/me/Comics/.comicredr'),
        ],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    expect(find.textContaining('keys.toml: no action called "noSuchAction"'), findsOneWidget); // The snack bar.
    await open(tester, c, writeBook(tmp, 'Remapped.cbz', 3));
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).page, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
    await settle(tester);
    expect(c.read(readerProvider).page, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, physicalKey: PhysicalKeyboardKey.slash, character: '?');
    await tester.pump();
    final file = tester.widget<Text>(find.byKey(const Key('keymap-file'))).data!;
    expect(file, contains('Keys from /home/me/.config/comicredr/keys.toml'));
    expect(file, contains('noSuchAction'));
    expect(tester.widget<Text>(find.byKey(const Key('app-data'))).data, contains('kept in /home/me/Comics/.comicredr'));
  });

  testWidgets('? shows the keymap generated from the bindings', (tester) async {
    await pumpApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, physicalKey: PhysicalKeyboardKey.slash, character: '?');
    await tester.pump();
    expect(find.text('Next page, ignoring panels'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Next page, ignoring panels'), findsNothing);
  });

  testWidgets('keys under the ? help do not reach the reader behind it', (tester) async {
    final path = writeBook(tmp, 'Behind 01.cbz', 4);
    final c = await pumpApp(tester);
    await open(tester, c, path);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, physicalKey: PhysicalKeyboardKey.slash, character: '?');
    await tester.pump();
    await key(tester, LogicalKeyboardKey.keyL);
    await key(tester, LogicalKeyboardKey.enter);
    expect(c.read(readerProvider).page, 0, reason: 'l turned the page under the help');
    expect(find.byType(KeymapOverlay), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).page, 1);
  });

  testWidgets('/ searches the keymap overlay; Esc clears the search, then closes it', (tester) async {
    await pumpApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, physicalKey: PhysicalKeyboardKey.slash, character: '?');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, physicalKey: PhysicalKeyboardKey.slash, character: '/');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('keymap-search')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('keymap-search')), 'gided bak');
    await tester.pump();
    expect(find.text('Guided view, there and back'), findsOneWidget);
    expect(find.text('Next page, ignoring panels'), findsNothing);

    await tester.enterText(find.byKey(const Key('keymap-search')), '/^z[wh]/');
    await tester.pump();
    expect(find.text('Fit width'), findsOneWidget);
    expect(find.text('Fit height'), findsOneWidget);
    expect(find.text('Zoom in'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('keymap-search')), findsNothing);
    expect(find.text('Next page, ignoring panels'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(KeymapOverlay), findsNothing);
  });

  test('the index schema opens in memory', () async {
    await db
        .into(db.books)
        .insert(BooksCompanion.insert(contentKey: 'k', title: 'Daredevil 181', pageCount: 32, format: 'zip'));
    expect(await db.select(db.books).get(), hasLength(1));
  });

  test('an M3 index upgrades to the guided-view schema', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await dropM8(old);
    await old.customStatement('DROP TABLE analysed_pages');
    await old.customStatement('ALTER TABLE progress DROP COLUMN view_json');
    await old.customStatement('PRAGMA user_version = 1');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    expect(await upgraded.select(upgraded.analysedPages).get(), isEmpty);
    expect(await upgraded.select(upgraded.progress).get(), isEmpty);
    await upgraded.close();
  });

  test('an M5 index keeps its positions and gains the saved view', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('ALTER TABLE progress DROP COLUMN view_json');
    await old.customStatement(
      "INSERT INTO progress (content_key, page, panel, percent, finished, updated_at) VALUES ('k', 4, 2, 0.5, 0, 0)",
    );
    await dropM8(old);
    await old.customStatement('PRAGMA user_version = 2');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    final at = await ProgressStore(upgraded).load('k');
    expect((at?.page, at?.panel, at?.guided, at?.view), (4, 2, null, null));
    await upgraded.close();
  });

  test('an M6 index keeps its positions and gains the library', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('DROP TABLE roots');
    await old.customStatement('DROP TABLE books');
    await old.customStatement(
      'CREATE TABLE books (content_key TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, series_id INTEGER, '
      'number TEXT, page_count INTEGER NOT NULL, format TEXT NOT NULL, added_at INTEGER NOT NULL)',
    );
    await old.customStatement(
      "INSERT INTO progress (content_key, page, panel, percent, finished, updated_at) VALUES ('k', 4, 2, 0.5, 0, 0)",
    );
    await dropM8(old);
    await old.customStatement('PRAGMA user_version = 3');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    expect(await upgraded.select(upgraded.roots).get(), isEmpty);
    expect((await ProgressStore(upgraded).load('k'))?.page, 4);
    await upgraded
        .into(upgraded.books)
        .insert(
          BooksCompanion.insert(contentKey: 'k', title: 'X', pageCount: 3, format: 'cbz', year: const Value(1982)),
        );
    await upgraded.close();
  });

  test('an M7 index keeps its bookmarks and gains sidecar support', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await dropM8(old);
    await old.customStatement(
      "INSERT INTO bookmarks (id, content_key, page, panel, mark, created_at) VALUES ('b', 'k', 4, 2, NULL, 0)",
    );
    await old.customStatement('PRAGMA user_version = 4');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    final marks = await upgraded.select(upgraded.bookmarks).get();
    expect((marks.single.page, marks.single.deletedAt), (4, null));
    expect(await upgraded.select(upgraded.settings).get(), isEmpty);
    await upgraded.close();
  });

  test('an index with settings but no removal times gains them', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('ALTER TABLE bookmarks DROP COLUMN deleted_at');
    await dropOutlines(old);
    await old.customStatement("INSERT INTO settings (key, value) VALUES ('guided.wholePageSteps', 'false')");
    await old.customStatement('PRAGMA user_version = 5');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    expect(await upgraded.select(upgraded.bookmarks).get(), isEmpty);
    expect((await upgraded.select(upgraded.settings).get()).single.value, 'false');
    await upgraded.close();
  });

  test('an M8 index keeps its panels and gains frame outlines', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await dropOutlines(old);
    await old.customStatement(
      'INSERT INTO panels (content_key, page, idx, x, y, w, h, kind, source, model_ver, confidence) '
      "VALUES ('k', 1, 0, 0.1, 0.1, 0.8, 0.4, 'frame', 'model', 200000001, 0.9)",
    );
    await old.customStatement('PRAGMA user_version = 7');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    final rows = await upgraded.select(upgraded.panels).get();
    expect((rows.single.x, rows.single.shape), (0.1, null));
    await upgraded.close();
  });

  test('an index from before trimmed detection keeps its runs and gains trims', () async {
    final file = File('${tmp.path}/index.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await dropTrims(old);
    await old.customStatement(
      'INSERT INTO analysed_pages (content_key, page, source, model_ver, millis, analysed_at) '
      "VALUES ('k', 1, 'model', 300000001, 120, 0)",
    );
    await old.customStatement('PRAGMA user_version = 8');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    final runs = await upgraded.select(upgraded.analysedPages).get();
    expect((runs.single.modelVer, runs.single.trim), (300000001, null));
    await upgraded.close();
  });
}

/// Takes an index back to before schema 5: no removal times, no settings.
Future<void> dropM8(AppDatabase old) async {
  await old.customStatement('ALTER TABLE bookmarks DROP COLUMN deleted_at');
  await old.customStatement('DROP TABLE settings');
  await dropOutlines(old);
}

/// Takes an index back to before schema 8: frames are boxes only.
Future<void> dropOutlines(AppDatabase old) async {
  await old.customStatement('ALTER TABLE panels DROP COLUMN shape');
  await dropTrims(old);
}

/// Takes an index back to before schema 9: detection saw the whole page.
Future<void> dropTrims(AppDatabase old) => old.customStatement('ALTER TABLE analysed_pages DROP COLUMN trim');
