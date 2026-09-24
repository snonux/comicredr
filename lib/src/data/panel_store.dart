import 'dart:math';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:drift/drift.dart';

import '../reader/panel_detector.dart';
import 'app_database.dart';

/// Detected frames and balloons per page, cached in the index by content
/// key, page, detector and detector version (design plan section 6). The
/// per-comic sidecar takes the same rows in M8, so detection travels with
/// the file.
class PanelStore {
  PanelStore(this._db);

  final AppDatabase _db;

  /// Every page of the book [source] at [version] has analysed, mapped to
  /// what it found. A page analysed with nothing found maps to empty lists;
  /// a missing page is unknown.
  Future<Map<int, DetectedPage>> load(String contentKey, {required PanelSource source, required int version}) async {
    final pages =
        await (_db.select(_db.analysedPages)..where(
              (a) => a.contentKey.equals(contentKey) & a.source.equals(source.name) & a.modelVer.equals(version),
            ))
            .get();
    if (pages.isEmpty) return {};
    final rows =
        await (_db.select(_db.panels)
              ..where(
                (p) => p.contentKey.equals(contentKey) & p.source.equals(source.name) & p.modelVer.equals(version),
              )
              ..orderBy([(p) => OrderingTerm(expression: p.page), (p) => OrderingTerm(expression: p.idx)]))
            .get();
    final frames = {for (final a in pages) a.page: <Panel>[]};
    final balloons = {for (final a in pages) a.page: <Panel>[]};
    for (final r in rows) {
      final kind = PanelKind.values.asNameMap()[r.kind] ?? PanelKind.frame;
      (kind == PanelKind.frame ? frames : balloons)[r.page]?.add(
        Panel(r.x, r.y, r.w, r.h, kind: kind, confidence: r.confidence),
      );
    }
    return {
      for (final a in pages)
        a.page: DetectedPage(frames[a.page]!, balloons[a.page]!, source: source, version: version, millis: a.millis),
    };
  }

  /// Replaces what this detector had stored for [page] with [found].
  Future<void> save(String contentKey, int page, DetectedPage found) => _db.transaction(() async {
    await (_db.delete(
      _db.panels,
    )..where((p) => p.contentKey.equals(contentKey) & p.page.equals(page) & p.source.equals(found.source.name))).go();
    await _db.batch((b) {
      b.insertAll(_db.panels, [
        for (final list in [found.frames, found.balloons])
          for (final (i, f) in list.indexed)
            PanelsCompanion.insert(
              contentKey: contentKey,
              page: page,
              idx: i,
              x: f.x,
              y: f.y,
              w: f.w,
              h: f.h,
              kind: f.kind.name,
              source: found.source.name,
              modelVer: found.version,
              confidence: f.confidence,
            ),
      ]);
    });
    await _db
        .into(_db.analysedPages)
        .insertOnConflictUpdate(
          AnalysedPagesCompanion.insert(
            contentKey: contentKey,
            page: page,
            source: found.source.name,
            modelVer: found.version,
            millis: found.millis,
            analysedAt: DateTime.now(),
          ),
        );
  });
}

/// vi marks a–z, panel-precise, kept in the bookmarks table so they
/// survive a restart. The sidecar carries them from M8.
class MarkStore {
  MarkStore(this._db);

  final AppDatabase _db;
  final _random = Random.secure();

  Future<Map<String, ({int page, int panel})>> load(String contentKey) async {
    final rows = await (_db.select(
      _db.bookmarks,
    )..where((b) => b.contentKey.equals(contentKey) & b.mark.isNotNull())).get();
    return {for (final r in rows) r.mark!: (page: r.page, panel: r.panel ?? 0)};
  }

  Future<void> save(String contentKey, String mark, int page, int panel) => _db.transaction(() async {
    await (_db.delete(_db.bookmarks)..where((b) => b.contentKey.equals(contentKey) & b.mark.equals(mark))).go();
    await _db
        .into(_db.bookmarks)
        .insert(
          BookmarksCompanion.insert(
            id: _uuid(),
            contentKey: contentKey,
            page: page,
            panel: Value(panel),
            mark: Value(mark),
            createdAt: DateTime.now(),
          ),
        );
  });

  /// An anonymous bookmark (`mm`), panel-precise in guided view.
  Future<void> addBookmark(String contentKey, int page, int? panel) => _db
      .into(_db.bookmarks)
      .insert(
        BookmarksCompanion.insert(
          id: _uuid(),
          contentKey: contentKey,
          page: page,
          panel: Value(panel),
          createdAt: DateTime.now(),
        ),
      );

  /// A random (version 4) UUID, so two devices never collide (section 6).
  String _uuid() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
