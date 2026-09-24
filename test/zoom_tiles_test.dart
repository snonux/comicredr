import 'dart:io';

import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zoom_tiles_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('a page decodes at screen size and zooming in draws a sharp tile of what is shown', (tester) async {
    // A 1600 x 2400 scan in an 800 x 600 window, one device pixel each.
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    final big = gridPage(1600, 2400, const [
      (80, 80, 680, 1080),
      (840, 80, 680, 1080),
      (80, 1240, 680, 1080),
      (840, 1240, 680, 1080),
    ]);
    final small = gridPage(400, 600, const [(20, 20, 170, 270)]);
    final path = writeBookOf(tmp, 'Zoom 01.cbz', [big, small]);
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db), classicCvOnly], child: const ComicRedrApp()),
    );
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);

    ReaderViewState view() => tester.state<ReaderViewState>(find.byType(ReaderView));
    expect(view().tiles, isEmpty, reason: 'nothing to sharpen at fit-page');

    // Zoomed in 1.25^3 (about 2x): a tile, of about the screen, at screen
    // resolution rather than the whole scan.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
    }
    await settle(tester);
    final tile = view().tiles[0];
    expect(tile, isNotNull);
    expect(tile!.region.height, lessThan(0.8), reason: 'the part on screen, and a margin');
    final fullWidth = tile.image.width / tile.region.width;
    // Shown some 730 px wide under the status line; sizes round up to 256 px steps.
    expect(fullWidth, inInclusiveRange(700, 1024), reason: 'at screen resolution, not the 1600 px scan');
    expect(tile.image.width * tile.image.height, lessThan(800 * 600 * 3), reason: 'about a screenful');

    // Zoomed back out, the tile goes.
    await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '=');
    await settle(tester);
    expect(view().tiles, isEmpty);

    // A page stored smaller than the screen shows is never tiled.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await settle(tester);
    expect(c.read(readerProvider).page, 1);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
    }
    await settle(tester);
    expect(view().tiles, isEmpty);

    // Guided view's camera zooms onto a panel of the big page: sharp there too.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV, character: 'v');
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL, character: 'l'); // Past the whole-page view.
    await settle(tester);
    final s = c.read(readerProvider);
    expect((s.guided, s.page, s.panelIndex), (true, 0, 0));
    final panel = view().tiles[0];
    expect(panel, isNotNull, reason: 'the panel is drawn from a tile');
    final f = s.focus!;
    expect(panel!.region.left, lessThanOrEqualTo(f.x));
    expect(panel.region.left + panel.region.width, greaterThanOrEqualTo(f.x + f.w));
    expect(panel.region.top, lessThanOrEqualTo(f.y));
    expect(panel.region.top + panel.region.height, greaterThanOrEqualTo(f.y + f.h));
  });
}
