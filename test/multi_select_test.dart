import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/providers.dart';
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

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
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
  Future<ProviderContainer> inFolder(WidgetTester tester) async {
    final c = await pumpApp(tester);
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
}

String textOf(Finder f) => (f.evaluate().single.widget as Text).data!;
