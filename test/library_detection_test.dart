import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/library/library_detection.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/reader/panel_detector.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Finds one panel per page and counts what it was asked, with no image
/// decoding (the codec needs the engine).
class _CountingDetector extends PanelDetector {
  _CountingDetector({this.ver = 7});

  final int ver;
  final seen = <(int, int)>[];
  final _docs = <ComicDocument, int>{};

  @override
  PanelSource get source => PanelSource.model;

  @override
  int get version => ver;

  @override
  Future<DetectedPage> detect(ComicDocument doc, int page) async {
    seen.add((_docs.putIfAbsent(doc, () => _docs.length), page));
    return DetectedPage(
      [const Panel(0, 0, 0.5, 0.5, confidence: 0.9)],
      const [],
      source: PanelSource.model,
      version: ver,
      millis: 1,
    );
  }
}

void main() {
  late Directory tmp;
  late Directory root;
  late AppDatabase db;
  late LibraryStore store;
  late PanelStore panels;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('library_detection_test');
    root = Directory('${tmp.path}/Comics')..createSync();
    db = AppDatabase(NativeDatabase.memory());
    store = LibraryStore(db);
    panels = PanelStore(db);
    writeBook(root, 'Alpha 1.cbz', 3);
    writeBook(root, 'Beta 1.cbz', 4);
    await store.addRoot(root.path);
    final scanner = LibraryScanner(store, coverDir: '${tmp.path}/covers', workers: 1);
    await scanner.scan();
    await scanner.dispose();
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  LibraryDetection pass(
    PanelDetector detector, {
    bool on = true,
    bool Function()? busy,
    void Function(String)? onSaved,
  }) => LibraryDetection(
    library: store,
    panels: panels,
    detector: () async => detector,
    enabled: () async => on,
    busy: busy,
    onSaved: onSaved,
    poll: const Duration(milliseconds: 5),
    rest: false,
  );

  test('finds the panels of every page of every book, and saves them', () async {
    final detector = _CountingDetector();
    final saved = <String>{};
    final d = pass(detector, onSaved: saved.add);
    final statuses = <DetectionStatus>[];
    d.status.listen(statuses.add);
    await d.run();

    expect(detector.seen, hasLength(7));
    final books = await store.books();
    for (final b in books) {
      final found = await panels.load(b.key, source: PanelSource.model, version: 7);
      expect(found.keys.toSet(), {for (var p = 0; p < b.pageCount; p++) p}, reason: b.name);
    }
    expect(saved, books.map((b) => b.key).toSet());
    expect(statuses.where((s) => s.running).last.done, 7);
    expect(statuses.last.running, isFalse);
    await d.dispose();
  });

  test('skips what is done, so a restart goes on where it stopped', () async {
    final first = _CountingDetector();
    final books = await store.books();
    final alpha = books.firstWhere((b) => b.series == 'Alpha');
    for (var p = 0; p < alpha.pageCount; p++) {
      await panels.save(alpha.key, p, await first.detect(_NoDoc(), p));
    }
    await panels.save(books.firstWhere((b) => b.series == 'Beta').key, 0, await first.detect(_NoDoc(), 0));

    final detector = _CountingDetector();
    final d = pass(detector);
    await d.run();
    expect(detector.seen.map((s) => s.$2), [1, 2, 3], reason: 'only Beta pages 2 to 4');
    await d.dispose();
  });

  test('a new detector generation redoes the library', () async {
    final old = _CountingDetector(ver: 1 * 100000000 + 5);
    await pass(old).run();
    expect(old.seen, hasLength(7));
    final newer = _CountingDetector(ver: 2 * 100000000 + 5);
    await pass(newer).run();
    expect(newer.seen, hasLength(7));
  });

  test('switched off, it does nothing; paused, it stops until resumed', () async {
    final detector = _CountingDetector();
    await pass(detector, on: false).run();
    expect(detector.seen, isEmpty);

    final d = pass(detector)..pause();
    await d.run();
    expect(detector.seen, isEmpty);
    expect(d.last.paused, isTrue);
    d.resume();
    await d.run();
    expect(detector.seen, hasLength(7));
    await d.dispose();
  });

  test('waits while the reader is busy', () async {
    final detector = _CountingDetector();
    var busy = true;
    final d = pass(detector, busy: () => busy);
    final done = d.run();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(detector.seen, isEmpty);
    busy = false;
    await done;
    expect(detector.seen, hasLength(7));
    await d.dispose();
  });
}

class _NoDoc implements ComicDocument {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
