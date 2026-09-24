import 'dart:io';

import 'package:comic_formats/comic_formats.dart';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/library/providers.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/thumbnails.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// The page grid (`p`) and the scrubber preview on the progress bar.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('page_grid_test');
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

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  Future<ProviderContainer> openBook(WidgetTester tester, int pages) async {
    final path = writeBook(tmp, 'Grid 01.cbz', pages);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    return c;
  }

  Border? borderOf(WidgetTester tester, int i) {
    final box = find.descendant(of: find.byKey(Key('pageTile-$i')), matching: find.byType(Container)).first;
    return (tester.widget<Container>(box).foregroundDecoration as BoxDecoration?)?.border as Border?;
  }

  testWidgets('p opens the grid on the current page; keys move and Enter jumps', (tester) async {
    final c = await openBook(tester, 30);
    await key(tester, LogicalKeyboardKey.keyL);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).page, 2);

    await key(tester, LogicalKeyboardKey.keyP);
    expect(find.byKey(const Key('pageGrid')), findsOneWidget);
    final scheme = Theme.of(tester.element(find.byKey(const Key('pageGrid')))).colorScheme;
    expect(borderOf(tester, 2)?.top.color, Colors.amber, reason: 'selected starts on the current page');

    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(borderOf(tester, 2)?.top.color, scheme.primary, reason: 'still outlined as the current page');
    expect(c.read(readerProvider).page, 2, reason: 'moving the selection does not turn the page');

    // 800 px wide: four columns, so down is four pages on.
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byKey(const Key('pageGrid')), findsNothing);
    expect(c.read(readerProvider).page, 7);

    // A jump, so '' comes back.
    await tester.sendKeyEvent(LogicalKeyboardKey.quote, character: "'");
    await tester.sendKeyEvent(LogicalKeyboardKey.quote, character: "'");
    await settle(tester);
    expect(c.read(readerProvider).page, 2);
  });

  testWidgets('G in the grid selects the last page, and Esc closes without jumping', (tester) async {
    final c = await openBook(tester, 40);
    await key(tester, LogicalKeyboardKey.keyP);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'G');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    expect(find.byKey(const Key('pageTile-39')), findsOneWidget, reason: 'scrolled to the last page');
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('pageGrid')), findsNothing);
    expect(c.read(readerProvider).page, 0);
    expect(c.read(readerProvider).book, isNotNull, reason: 'Esc closed the grid, not the book');
  });

  testWidgets('the status-line button opens the grid, a tap jumps, bookmarks show', (tester) async {
    final c = await openBook(tester, 12);
    await key(tester, LogicalKeyboardKey.keyL);
    await key(tester, LogicalKeyboardKey.keyL);
    await key(tester, LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await settle(tester);
    await tester.tap(find.byKey(const Key('pagesButton')));
    await settle(tester);
    expect(find.byKey(const Key('pageGrid')), findsOneWidget);
    expect(find.byKey(const Key('pageBookmark-3')), findsOneWidget);
    expect(find.byKey(const Key('pageBookmark-2')), findsNothing);

    // Thumbnails are made as tiles show and kept on disk.
    for (var i = 0; i < 10 && find.byType(Image).evaluate().isEmpty; i++) {
      await settle(tester);
    }
    expect(find.byType(Image), findsWidgets);
    final key0 = c.read(readerProvider).book!.key;
    expect(File('${tmp.path}/covers/pages/$key0/1.jpg').existsSync(), isTrue);

    await tester.tap(find.byKey(const Key('pageTile-6')), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect(find.byKey(const Key('pageGrid')), findsNothing);
    expect(c.read(readerProvider).page, 6);
  });

  testWidgets('dragging along the progress bar previews the page, letting go jumps', (tester) async {
    final c = await openBook(tester, 20);
    final bar = tester.getRect(find.byKey(const Key('scrubber')));
    final gesture = await tester.startGesture(
      Offset(bar.left + bar.width * 0.1, bar.center.dy),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(40, 0));
    await settle(tester);
    // Three quarters along a 20-page book is page 16.
    await gesture.moveTo(Offset(bar.left + bar.width * 0.775, bar.center.dy));
    await settle(tester);
    expect(find.byKey(const Key('scrubPreview')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('scrubPage'))).data, '16 / 20');
    expect(c.read(readerProvider).page, 0, reason: 'nothing moves before letting go');
    for (var i = 0; i < 10 && find.byType(Image).evaluate().isEmpty; i++) {
      await settle(tester);
    }
    expect(find.descendant(of: find.byKey(const Key('scrubPreview')), matching: find.byType(Image)), findsOneWidget);
    await gesture.up();
    await settle(tester);
    expect(find.byKey(const Key('scrubPreview')), findsNothing);
    expect(c.read(readerProvider).page, 15);

    // A tap on the bar jumps straight there.
    await tester.tapAt(Offset(bar.left + bar.width * 0.025, bar.center.dy), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect(c.read(readerProvider).page, 0);
  });

  test('thumbnails: newest request first, cancelled ones dropped', () async {
    final doc = _RecordingDoc();
    final t = Thumbnails(doc, dir: '${tmp.path}/t', parallel: 1);
    final first = t.get(0); // Starts at once.
    final second = t.get(1);
    final third = t.get(2);
    final fourth = t.get(3);
    t.cancel(1);
    expect(await second, isNull);
    await Future.wait([first, third, fourth]);
    expect(doc.read, [0, 3, 2], reason: 'the newest waiting request goes next');
    t.close();
  });
}

/// A document whose pages cannot be read, recording the order they were
/// asked for.
class _RecordingDoc implements ComicDocument {
  final read = <int>[];

  @override
  int get pageCount => 4;

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight}) async {
    read.add(index);
    throw const FormatException('no pixels in this test');
  }

  @override
  Future<Uint8List?> rawPage(int index) async => null;

  @override
  Future<ComicMeta?> embeddedMetadata() async => null;

  @override
  Future<void> close() async {}
}
