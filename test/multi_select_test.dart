import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Marking several comics in the library (Shift+arrows, Shift+Home/End,
/// Ctrl+A, Shift+click, V) and acting on all of them at once: delete,
/// reset, favourite.
void main() {
  late Directory tmp;
  late Directory root;
  late AppDatabase db;
  late List<String> files;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('multi_select_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    db = AppDatabase(NativeDatabase.memory());
    files = [
      for (final n in ['A', 'B', 'C', 'D', 'E']) writeBook(root, '$n.cbz', n.codeUnitAt(0) - 63),
    ];
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue('${tmp.path}/covers'),
          classicCvOnly,
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

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {String? character}) async {
    await tester.sendKeyEvent(k, character: character);
    await settle(tester);
  }

  Future<void> shifted(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(k);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
  }

  /// The Folders tab, inside the library folder, with its first comic
  /// selected.
  Future<ProviderContainer> inFolder(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
    final c = await pumpApp(tester, size: size);
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(root.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    await tester.tap(find.text('Folders'));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyL);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byKey(const Key('breadcrumb')), findsOneWidget);
    return c;
  }

  String count() => textOf(find.byKey(const Key('marksCount')));

  testWidgets('Shift+arrows mark a run of comics, and Esc clears it', (tester) async {
    await inFolder(tester);
    expect(find.byKey(const Key('marksBar')), findsNothing);
    await shifted(tester, LogicalKeyboardKey.arrowRight);
    expect(count(), '2 selected');
    await shifted(tester, LogicalKeyboardKey.arrowRight);
    expect(count(), '3 selected');
    // Back the other way unmarks what the run went past.
    await shifted(tester, LogicalKeyboardKey.arrowLeft);
    expect(count(), '2 selected');
    await shifted(tester, LogicalKeyboardKey.end);
    expect(count(), '5 selected');
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('marksBar')), findsNothing);

    // A plain move ends the run; a new one adds to the marks there are.
    await shifted(tester, LogicalKeyboardKey.arrowLeft); // E and D.
    expect(count(), '2 selected');
    await key(tester, LogicalKeyboardKey.arrowLeft);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    await shifted(tester, LogicalKeyboardKey.home); // A to B, and D and E still.
    expect(count(), '4 selected');

    // Ctrl+A marks every comic shown, and again unmarks them all.
    await key(tester, LogicalKeyboardKey.escape);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(count(), '5 selected');
    await tester.tap(find.byKey(const Key('marksAll')));
    await settle(tester);
    expect(find.byKey(const Key('marksBar')), findsNothing);
  });

  testWidgets('Shift+click marks from the selected cover to the clicked one', (tester) async {
    await inFolder(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('D').first, kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    expect(count(), '4 selected');
  });

  testWidgets('Mark in the details pane turns taps into marking', (tester) async {
    await inFolder(tester);
    await tester.drag(find.byKey(const Key('detail')), const Offset(0, -1000));
    await settle(tester);
    await tester.tap(find.byKey(const Key('markBook')));
    await settle(tester);
    expect(count(), '1 selected');
    await tester.tap(find.text('C').first);
    await tester.tap(find.text('D').first);
    await settle(tester);
    expect(count(), '3 selected');
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('marksBar')), findsNothing);
    // Taps select again.
    await tester.tap(find.text('B').first);
    await settle(tester);
    expect(find.byKey(const Key('marksBar')), findsNothing);
  });

  testWidgets('Mark on the details page of a narrower window goes back to marking covers', (tester) async {
    // Below 1000 wide a tap on a cover opens its details as a page, with
    // no pane beside the covers and no Select button above 600.
    await inFolder(tester, size: const Size(800, 900));
    await tester.tap(find.text('B').first);
    await settle(tester);
    await tester.drag(find.byKey(const Key('detail')), const Offset(0, -1000));
    await settle(tester);
    await tester.tap(find.byKey(const Key('markBook')));
    await settle(tester);
    expect(count(), '1 selected');
    await tester.tap(find.text('A').first);
    await settle(tester);
    expect(count(), '2 selected');
  });

  testWidgets('Cancel keeps a single mark, for delete and reset alike', (tester) async {
    await inFolder(tester);
    await key(tester, LogicalKeyboardKey.keyV, character: 'V');
    expect(count(), '1 selected');
    await key(tester, LogicalKeyboardKey.keyG, character: 'g');
    await key(tester, LogicalKeyboardKey.keyD, character: 'd');
    expect(find.byKey(const Key('deleteDialog')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('deleteDialog')), findsNothing);
    expect(files.map((f) => File(f).existsSync()), everyElement(isTrue));
    expect(count(), '1 selected');
    await key(tester, LogicalKeyboardKey.keyX, character: 'X');
    expect(find.textContaining('Reset'), findsWidgets);
    await key(tester, LogicalKeyboardKey.escape);
    expect(count(), '1 selected');
  });

  testWidgets('gd deletes every marked comic after one question', (tester) async {
    await inFolder(tester);
    await key(tester, LogicalKeyboardKey.keyL); // B.
    await shifted(tester, LogicalKeyboardKey.arrowRight); // B and C.
    await key(tester, LogicalKeyboardKey.keyG, character: 'g');
    await key(tester, LogicalKeyboardKey.keyD, character: 'd');
    expect(find.text('Delete 2 comics?'), findsOneWidget);
    // Cancel has the focus: Enter keeps them, and the marks.
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byKey(const Key('deleteDialog')), findsNothing);
    expect(files.map((f) => File(f).existsSync()), everyElement(isTrue));
    expect(count(), '2 selected');

    await tester.tap(find.byKey(const Key('marksDelete')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('deleteConfirm')));
    for (var i = 0; i < 20 && File(files[2]).existsSync(); i++) {
      await settle(tester);
    }
    expect([for (final f in files) File(f).existsSync()], [true, false, false, true, true]);
    expect(find.byKey(const Key('marksBar')), findsNothing);
    expect(find.textContaining('2 comics deleted'), findsOneWidget);
  });

  testWidgets('X resets every marked comic, and * makes them favourites', (tester) async {
    final c = await inFolder(tester);
    final keys = [for (final f in files) await tester.runAsync(() => contentKey(f))];
    await tester.runAsync(() async {
      for (final k in keys) {
        await MarkStore(db).addBookmark(k!, 1, null);
      }
    });
    await shifted(tester, LogicalKeyboardKey.arrowRight);
    await shifted(tester, LogicalKeyboardKey.arrowRight); // A, B and C.
    await key(tester, LogicalKeyboardKey.keyX, character: 'X');
    expect(find.text('Reset 3 comics?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('resetEverything')));
    await settle(tester);
    await settle(tester);
    final store = c.read(libraryStoreProvider);
    final left = [for (final k in keys) (await tester.runAsync(() => store.watchBookmarks(k!).first))!.length];
    expect(left, [0, 0, 0, 1, 1]);
    await settle(tester);
    expect(find.byKey(const Key('marksBar')), findsNothing);

    await shifted(tester, LogicalKeyboardKey.arrowRight); // C and D.
    await tester.sendKeyEvent(LogicalKeyboardKey.asterisk, character: '*', physicalKey: PhysicalKeyboardKey.digit8);
    await settle(tester);
    final favourites = [for (final k in keys) await tester.runAsync(() => store.isFavourite(k!))];
    expect(favourites, [false, false, true, true, false]);
  });

  /// Types [text] into the move picker's search field.
  Future<void> typeKeys(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('moveFilter')), text);
    await settle(tester);
  }

  /// Enter in the text field that has the focus.
  Future<void> submit(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
  }

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 30 && !done(); i++) {
      await settle(tester);
    }
  }

  List<String> bookPaths(ProviderContainer c) => [for (final b in c.read(booksProvider).value!) b.path]..sort();

  testWidgets('gm moves the marked comics to a folder typed into the picker, sidecars and all', (tester) async {
    final done = Directory('${root.path}/Read/Done')..createSync(recursive: true);
    final c = await inFolder(tester);
    final keyA = (await tester.runAsync(() => contentKey(files[0])))!;
    // Index progress is real. The beside .crdb is planted here (SidecarSync.write
    // hangs under the test clock); move_books_test and e2e_multi_select cover
    // a SidecarSync-written sidecar surviving the move.
    await tester.runAsync(() async {
      c.read(progressStoreProvider).save(keyA, const ReadingPosition(page: 2, panel: 1, guided: true), 4);
      await MarkStore(db).addBookmark(keyA, 2, 1);
    });
    writeSidecar(
      sidecarPath(files[0], folder: false),
      SidecarData(
        contentKey: keyA,
        bookmarks: [Bookmark(id: 'b1', contentKey: keyA, page: 2, panel: 1, createdAt: DateTime.utc(2026, 1, 1))],
        progress: [
          SidecarProgress(
            device: 'planted',
            deviceName: 'planted',
            page: 2,
            panel: 1,
            percent: 0.5,
            finished: false,
            updatedAt: DateTime.utc(2026, 1, 1),
            viewJson: '{"guided":true}',
          ),
        ],
      ),
      device: 'planted',
    );
    expect(File(sidecarPath(files[0], folder: false)).existsSync(), isTrue);
    await shifted(tester, LogicalKeyboardKey.arrowRight); // A and B.
    await key(tester, LogicalKeyboardKey.keyG, character: 'g');
    await key(tester, LogicalKeyboardKey.keyM, character: 'm');
    expect(find.byKey(const Key('moveDialog')), findsOneWidget);
    // The empty folder is offered, and typing narrows the list to it.
    expect(find.byKey(const Key('moveTarget-Comics/Read/Done')), findsOneWidget);
    await typeKeys(tester, 'done');
    expect(find.byKey(const Key('moveTarget-Comics')), findsNothing);
    await submit(tester);
    await waitFor(tester, () => File('${done.path}/B.cbz').existsSync());
    expect([for (final f in files) File(f).existsSync()], [false, false, true, true, true]);
    expect(File('${done.path}/A.cbz').existsSync(), isTrue);
    // The planted sidecar was relocated whole, and the index kept its place.
    expect(File(sidecarPath(files[0], folder: false)).existsSync(), isFalse);
    final movedSide = sidecarPath('${done.path}/A.cbz', folder: false);
    expect(File(movedSide).existsSync(), isTrue);
    final side = readSidecar(movedSide)!;
    expect(side.contentKey, keyA);
    expect(side.progress, hasLength(1));
    expect((side.progress.single.page, side.progress.single.panel, side.progress.single.device), (2, 1, 'planted'));
    expect(side.progress.single.viewJson, '{"guided":true}');
    expect(side.bookmarks.where((b) => b.deletedAt == null).single.page, 2);
    await waitFor(tester, () => bookPaths(c).contains('${done.path}/B.cbz'));
    expect(bookPaths(c), containsAll(['${done.path}/A.cbz', '${done.path}/B.cbz']));
    expect(bookPaths(c), isNot(contains(files[0])));
    expect(
      (await tester.runAsync(() async {
        final at = await c.read(progressStoreProvider).load(keyA);
        return (at?.page, at?.panel, at?.guided);
      }))!,
      (2, 1, true),
    );
    expect((await tester.runAsync(() => c.read(libraryStoreProvider).watchBookmarks(keyA).first))!, hasLength(1));
    expect(find.byKey(const Key('marksBar')), findsNothing);
    expect(find.textContaining('2 comics moved to Done'), findsOneWidget);
  });

  testWidgets('a new folder from the picker, and a name taken there asks first', (tester) async {
    final other = Directory('${root.path}/Other')..createSync();
    final clash = writeBook(other, 'D.cbz', 9);
    await inFolder(tester);
    // No marks: gm moves the selected comic. Ctrl+N makes a folder in the
    // picked one, the folder shown, and moves there.
    // The folder Other comes first.
    for (var i = 0; i < 3; i++) {
      await key(tester, LogicalKeyboardKey.keyL); // A, B, C.
    }
    await key(tester, LogicalKeyboardKey.keyG, character: 'g');
    await key(tester, LogicalKeyboardKey.keyM, character: 'm');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('New folder in Comics'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('newFolderName')), 'Later');
    await submit(tester);
    await waitFor(tester, () => File('${root.path}/Later/C.cbz').existsSync());
    expect(File(files[2]).existsSync(), isFalse);
    expect(File('${root.path}/Later/C.cbz').existsSync(), isTrue);

    // D to Other, where a D.cbz is already: Cancel has the focus.
    await key(tester, LogicalKeyboardKey.end); // E.
    await key(tester, LogicalKeyboardKey.keyH); // D.
    await key(tester, LogicalKeyboardKey.keyV, character: 'V');
    await tester.tap(find.byKey(const Key('marksMove')));
    await settle(tester);
    await typeKeys(tester, 'other');
    await submit(tester);
    expect(find.byKey(const Key('moveClashDialog')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byKey(const Key('moveClashDialog')), findsNothing);
    expect(File(files[3]).existsSync(), isTrue);
    expect(File(clash).lengthSync(), isNot(File(files[3]).lengthSync()));
    expect(count(), '1 selected');

    // Replace: the one there goes, D takes its place.
    final size = File(files[3]).lengthSync();
    await tester.tap(find.byKey(const Key('marksMove')));
    await settle(tester);
    await typeKeys(tester, 'other');
    await submit(tester);
    await tester.tap(find.byKey(const Key('moveClashReplace')));
    await waitFor(tester, () => !File(files[3]).existsSync());
    expect(File(files[3]).existsSync(), isFalse);
    expect(File(clash).lengthSync(), size);
  });

  testWidgets('gc puts the marked comics in a collection', (tester) async {
    final c = await inFolder(tester);
    await shifted(tester, LogicalKeyboardKey.arrowRight); // A and B.
    await key(tester, LogicalKeyboardKey.keyG, character: 'g');
    await key(tester, LogicalKeyboardKey.keyC, character: 'c');
    expect(find.byKey(const Key('collectionDialog')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('collectionName')), 'Summer');
    await submit(tester);
    List<bool> inIt() => [
      for (final b in c.read(booksProvider).value!.toList()..sort((a, b) => a.path.compareTo(b.path)))
        b.collections.contains('Summer'),
    ];
    await waitFor(tester, () => inIt().first);
    expect(inIt(), [true, true, false, false, false]);
    await waitFor(tester, () => find.byKey(const Key('marksBar')).evaluate().isEmpty);
    expect(find.byKey(const Key('marksBar')), findsNothing);
  });
}

String textOf(Finder f) => (f.evaluate().single.widget as Text).data!;
