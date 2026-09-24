import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/panel_detector.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:comicredr/src/reader/reader_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Stands in for the trained model: a 2x2 grid where the first panel has
/// two balloons, the second none, and the third one that hangs over its
/// edge.
class FakeModel extends PanelDetector {
  const FakeModel();

  static const frames = [
    Panel(0.05, 0.05, 0.43, 0.43),
    Panel(0.52, 0.05, 0.43, 0.43),
    Panel(0.05, 0.52, 0.43, 0.43),
    Panel(0.52, 0.52, 0.43, 0.43),
  ];
  static const balloons = [
    Panel(0.30, 0.25, 0.12, 0.06, kind: PanelKind.balloon), // panel 1, second
    Panel(0.08, 0.08, 0.15, 0.08, kind: PanelKind.balloon), // panel 1, first
    Panel(0.40, 0.55, 0.12, 0.05, kind: PanelKind.balloon), // panel 3, over the gutter
  ];

  @override
  PanelSource get source => PanelSource.model;
  @override
  int get version => modelDetectorVersion;

  @override
  Future<DetectedPage> detect(ComicDocument doc, int page) async =>
      const DetectedPage(frames, balloons, source: PanelSource.model, version: modelDetectorVersion, millis: 1);
}

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('balloon_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          panelDetectorProvider.overrideWith((ref) async => const FakeModel()),
        ],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('status'))).data!;

  testWidgets('the camera zooms in on a balloon and settles there', (tester) async {
    final path = writeBookOf(tmp, 'Balloons 01.cbz', [grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    ReaderViewState view() => tester.state<ReaderViewState>(find.byType(ReaderView));

    await key(tester, LogicalKeyboardKey.keyB);
    final onPanel = view().transform.getMaxScaleOnAxis();
    await key(tester, LogicalKeyboardKey.keyL);
    expect(c.read(readerProvider).balloonIndex, 0);
    final onBalloon = view().transform;
    expect(onBalloon.getMaxScaleOnAxis(), greaterThan(onPanel * 1.3), reason: 'the balloon is framed, not the panel');
    // The glide has finished: more frames move nothing.
    await tester.pump(const Duration(seconds: 1));
    expect(view().transform, onBalloon);
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'no camera animation left running');
  });

  testWidgets('b steps through the balloons inside each panel', (tester) async {
    final path = writeBookOf(tmp, 'Balloons 01.cbz', [grid4Page(), grid4Page()]);
    final c = await pumpApp(tester);
    await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
    await settle(tester);
    ReaderState s() => c.read(readerProvider);

    // b from single page goes into guided view with balloons on.
    await key(tester, LogicalKeyboardKey.keyB);
    expect((s().guided, s().balloons), (true, true));
    expect((s().panelIndex, s().balloonIndex), (0, -1), reason: 'the panel whole comes first');
    expect(s().focus, FakeModel.frames[0]);
    expect(status(tester), contains('balloon – / 2'));

    await key(tester, LogicalKeyboardKey.keyL);
    expect((s().panelIndex, s().balloonIndex), (0, 0));
    final focus = s().focus!;
    expect(focus.x, lessThanOrEqualTo(0.08));
    expect(focus.right, lessThan(0.4), reason: 'framed around the first balloon, not the panel');
    expect(focus.x, greaterThanOrEqualTo(FakeModel.frames[0].x), reason: 'kept inside the panel');
    expect(status(tester), contains('balloon 1 / 2'));

    await key(tester, LogicalKeyboardKey.keyL);
    expect((s().panelIndex, s().balloonIndex), (0, 1));
    // Panel 2 has no balloons: one step, the panel whole.
    await key(tester, LogicalKeyboardKey.keyL);
    expect((s().panelIndex, s().balloonIndex), (1, -1));
    expect(status(tester), contains('no balloons'));
    await key(tester, LogicalKeyboardKey.keyL);
    expect((s().panelIndex, s().balloonIndex), (2, -1));
    await key(tester, LogicalKeyboardKey.keyL);
    expect((s().panelIndex, s().balloonIndex), (2, 0));
    final over = s().focus!;
    expect(over.right, greaterThanOrEqualTo(0.52), reason: 'a balloon over the edge stays wholly in view');

    // Back from panel 2 lands on panel 1's last balloon.
    await key(tester, LogicalKeyboardKey.keyH);
    await key(tester, LogicalKeyboardKey.keyH);
    await key(tester, LogicalKeyboardKey.keyH);
    expect((s().panelIndex, s().balloonIndex), (0, 1));

    // A tap on the right edge steps too.
    final r = tester.getRect(find.byType(ReaderView));
    await tester.tapAt(Offset(r.right - 40, r.center.dy), kind: PointerDeviceKind.touch);
    await settle(tester);
    expect((s().panelIndex, s().balloonIndex), (1, -1));

    // b again: panels only, from the same panel.
    await key(tester, LogicalKeyboardKey.keyB);
    expect((s().guided, s().balloons, s().panelIndex, s().balloonIndex), (true, false, 1, -1));
    await key(tester, LogicalKeyboardKey.keyL);
    expect((s().panelIndex, s().balloonIndex), (2, -1));
    await key(tester, LogicalKeyboardKey.keyL);
    expect((s().panelIndex, s().balloonIndex), (3, -1), reason: 'balloons are skipped with b off');

    // Balloons are cached with the frames.
    await tester.runAsync(() async {
      final kinds = (await db.select(db.panels).get()).map((p) => p.kind).toList();
      expect(kinds.where((k) => k == 'balloon'), hasLength(6));
    });
  });
}
