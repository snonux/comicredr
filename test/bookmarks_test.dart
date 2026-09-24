import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Bookmarks: `mm` on and off, the marker on the page and the progress
/// bar, `}` and `{`, the list (`M`) with notes, and the library's
/// Bookmarks tab.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bookmarks_test');
    db = AppDatabase(NativeDatabase.memory());
    await SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          coverDirProvider.overrideWithValue('${tmp.path}/covers'),
          classicCvOnly,
          noSidecars(db),
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
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> type(WidgetTester tester, String keys) async {
    for (final ch in keys.split('')) {
      final k = switch (ch) {
        'm' => LogicalKeyboardKey.keyM,
        'M' => LogicalKeyboardKey.keyM,
        'l' => LogicalKeyboardKey.keyL,
        'h' => LogicalKeyboardKey.keyH,
        'v' => LogicalKeyboardKey.keyV,
        'e' => LogicalKeyboardKey.keyE,
        'x' => LogicalKeyboardKey.keyX,
        'j' => LogicalKeyboardKey.keyJ,
        'a' => LogicalKeyboardKey.keyA,
        '}' => LogicalKeyboardKey.bracketRight,
        '{' => LogicalKeyboardKey.bracketLeft,
        _ => throw ArgumentError(ch),
      };
      final physical = switch (ch) {
        '}' => PhysicalKeyboardKey.bracketRight,
        '{' => PhysicalKeyboardKey.bracketLeft,
        _ => null,
      };
      await tester.sendKeyEvent(k, character: ch, physicalKey: physical);
      await tester.pump();
    }
    await settle(tester);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  Future<List<Bookmark>> rows() => db.select(db.bookmarks).get();

  Future<(ProviderContainer, String)> openBook(WidgetTester tester, {int pages = 4}) async {
    final path = writeBookOf(tmp, 'Marked 01.cbz', [for (var i = 0; i < pages; i++) grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    return (c, path);
  }

  testWidgets('mm bookmarks the page, shows the marker, and mm again takes it off', (tester) async {
    final (c, _) = await openBook(tester);
    await type(tester, 'l');
    expect(find.byKey(const Key('bookmarkRibbon')), findsNothing);

    await type(tester, 'mm');
    expect(c.read(readerProvider).bookmarksHere, hasLength(1));
    expect(find.byKey(const Key('bookmarkRibbon')), findsOneWidget);
    expect(find.byKey(const Key('bookmarkTick-1')), findsOneWidget);
    final live = (await tester.runAsync(rows))!;
    expect(live.single.page, 1);
    expect(live.single.panel, isNull);
    expect(live.single.deletedAt, isNull);

    // Not on the next page.
    await type(tester, 'l');
    expect(find.byKey(const Key('bookmarkRibbon')), findsNothing);
    await type(tester, 'h');

    await type(tester, 'mm');
    expect(c.read(readerProvider).bookmarksHere, isEmpty);
    expect(find.byKey(const Key('bookmarkRibbon')), findsNothing);
    expect(find.byKey(const Key('bookmarkTick-1')), findsNothing);
    // Kept as a removal, so an older sidecar cannot bring it back.
    final gone = (await tester.runAsync(rows))!;
    expect(gone.single.deletedAt, isNotNull);
  });

  testWidgets('guided view bookmarks the panel; } and { step through bookmarks', (tester) async {
    final (c, _) = await openBook(tester);
    await type(tester, 'mm'); // page 1, whole page
    await type(tester, 'v');
    await press(tester, LogicalKeyboardKey.pageDown);
    await press(tester, LogicalKeyboardKey.pageDown); // page 3
    for (var i = 0; i < 20 && c.read(readerProvider).stopsOn(2).isEmpty; i++) {
      await settle(tester);
    }
    await type(tester, 'll'); // panel 3
    expect(c.read(readerProvider).panelIndex, 2);
    await type(tester, 'mm');
    final marks = c.read(readerProvider).bookmarks;
    expect([for (final b in marks) (b.page, b.panel)], [(0, null), (2, 2)]);

    // Panel 2 of page 3 is not bookmarked; panel 3 is.
    await type(tester, 'h');
    expect(find.byKey(const Key('bookmarkRibbon')), findsNothing);
    await type(tester, 'l');
    expect(find.byKey(const Key('bookmarkRibbon')), findsOneWidget);

    await type(tester, '{');
    expect((c.read(readerProvider).page, c.read(readerProvider).guided), (0, true));
    expect(c.read(readerProvider).message, startsWith('Bookmark 1 of 2'));
    await type(tester, '{');
    expect(c.read(readerProvider).message, 'No bookmark before this one');
    await type(tester, '}');
    expect(c.read(readerProvider).page, 2);
    expect(c.read(readerProvider).panelIndex, 2);
    await type(tester, '}');
    expect(c.read(readerProvider).message, 'No bookmark after this one');
  });

  testWidgets('M lists the bookmarks: a note, a jump, and x removes', (tester) async {
    final (c, _) = await openBook(tester);
    await type(tester, 'mm');
    await press(tester, LogicalKeyboardKey.end);
    await type(tester, 'mm');
    await type(tester, 'ma');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await type(tester, 'M');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(find.byKey(const Key('bookmarkList')), findsOneWidget);
    // Two bookmarks and mark a, the last one at or before this page picked.
    expect(find.byKey(const Key('bookmarkRow-2')), findsOneWidget);

    await type(tester, 'h'); // up to the bookmark on the last page
    await type(tester, 'e');
    expect(find.byKey(const Key('bookmarkNoteField')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('bookmarkNoteField')), 'The big reveal');
    await tester.tap(find.byKey(const Key('bookmarkNoteSave')));
    await settle(tester);
    expect(find.text('The big reveal'), findsOneWidget);
    final all = (await tester.runAsync(rows))!;
    // The note replaced the bookmark with a new one; the old one is a removal.
    expect(all.where((r) => r.deletedAt == null && r.note == 'The big reveal'), hasLength(1));
    expect(all.where((r) => r.deletedAt != null), hasLength(1));

    // Up to the first bookmark and remove it.
    await type(tester, 'h');
    await type(tester, 'x');
    expect(c.read(readerProvider).bookmarks.where((b) => b.mark == null), hasLength(1));

    // Enter jumps to the one with the note, and the list closes.
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('bookmarkList')), findsNothing);
    await press(tester, LogicalKeyboardKey.home);
    expect(c.read(readerProvider).page, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await type(tester, 'M');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await press(tester, LogicalKeyboardKey.home);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byKey(const Key('bookmarkList')), findsNothing);
    expect(c.read(readerProvider).page, 3);
    expect(c.read(readerProvider).message, contains('The big reveal'));
  });

  testWidgets('the library lists every book\'s bookmarks and opens one', (tester) async {
    final a = writeBookOf(tmp, 'Alpha 01.cbz', [grid4Page(), grid4Page(), grid4Page()]);
    final b = writeBookOf(tmp, 'Beta 01.cbz', [grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() async {
      await c.read(libraryStoreProvider).addRoot(tmp.path);
      await c.read(scannerProvider).scan();
    });
    await settle(tester);
    for (final (path, page) in [(a, 2), (b, 1)]) {
      await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
      await settle(tester);
      c.read(readerProvider.notifier).jumpTo(page);
      await type(tester, 'mm');
      await press(tester, LogicalKeyboardKey.escape);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await type(tester, 'M');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(find.byKey(const Key('bookmarksTab')), findsOneWidget);
    expect(find.byKey(const Key('bookmarkItem-0')), findsOneWidget);
    expect(find.byKey(const Key('bookmarkItem-1')), findsOneWidget);
    expect(find.textContaining('page 3'), findsOneWidget);

    await type(tester, 'j'); // selects the first
    await type(tester, 'j'); // Beta's
    await press(tester, LogicalKeyboardKey.enter);
    for (var i = 0; i < 10 && c.read(readerProvider).book == null; i++) {
      await settle(tester);
    }
    expect(c.read(readerProvider).book!.path, b);
    expect(c.read(readerProvider).page, 1);
  });

  test('a note travels: the new bookmark wins a merge with the old copy', () async {
    final store = LibraryStore(db);
    final first = await db
        .into(db.bookmarks)
        .insertReturning(
          BookmarksCompanion.insert(
            id: 'b1',
            contentKey: 'k',
            page: 3,
            panel: const Value(1),
            createdAt: DateTime(2026),
          ),
        );
    final old = SidecarData(contentKey: 'k', bookmarks: [first]);
    final id = await store.setNote('b1', 'Look here');
    final now = SidecarData(contentKey: 'k', bookmarks: await db.select(db.bookmarks).get());
    for (final merged in [mergeSidecars(old, now), mergeSidecars(now, old)]) {
      final live = merged.bookmarks.where((m) => m.deletedAt == null).toList();
      expect(live.single.id, id);
      expect((live.single.page, live.single.panel, live.single.note), (3, 1, 'Look here'));
      expect(live.single.createdAt, DateTime(2026));
    }
  });
}
