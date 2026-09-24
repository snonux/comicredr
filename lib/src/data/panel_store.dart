import 'dart:math';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:drift/drift.dart';

import 'app_database.dart';

/// Detected frames per page, cached in the index by content key, page and
/// detector version (design plan section 6). The per-comic sidecar takes
/// the same rows in M8, so detection travels with the file.
class PanelStore {
  PanelStore(this._db);

  final AppDatabase _db;

  static final _source = PanelSource.classicCv.name;

  /// Every page of the book analysed by the current classic-CV version,
  /// mapped to its frames in left-to-right reading order. A page analysed
  /// with nothing found maps to an empty list; a missing page is unknown.
  Future<Map<int, List<Panel>>> load(String contentKey) async {
    final pages =
        await (_db.select(_db.analysedPages)..where(
              (a) => a.contentKey.equals(contentKey) & a.source.equals(_source) & a.modelVer.equals(classicCvVersion),
            ))
            .get();
    if (pages.isEmpty) return {};
    final rows =
        await (_db.select(_db.panels)
              ..where(
                (p) =>
                    p.contentKey.equals(contentKey) &
                    p.source.equals(_source) &
                    p.modelVer.equals(classicCvVersion) &
                    p.kind.equals(PanelKind.frame.name),
              )
              ..orderBy([(p) => OrderingTerm(expression: p.page), (p) => OrderingTerm(expression: p.idx)]))
            .get();
    final out = {for (final a in pages) a.page: <Panel>[]};
    for (final r in rows) {
      out[r.page]?.add(Panel(r.x, r.y, r.w, r.h, confidence: r.confidence));
    }
    return out;
  }

  /// Replaces what this detector had stored for [page] with [frames].
  Future<void> save(String contentKey, int page, List<Panel> frames, {required int millis}) =>
      _db.transaction(() async {
        await (_db.delete(
          _db.panels,
        )..where((p) => p.contentKey.equals(contentKey) & p.page.equals(page) & p.source.equals(_source))).go();
        await _db.batch((b) {
          b.insertAll(_db.panels, [
            for (final (i, f) in frames.indexed)
              PanelsCompanion.insert(
                contentKey: contentKey,
                page: page,
                idx: i,
                x: f.x,
                y: f.y,
                w: f.w,
                h: f.h,
                kind: f.kind.name,
                source: _source,
                modelVer: classicCvVersion,
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
                source: _source,
                modelVer: classicCvVersion,
                millis: millis,
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

  /// A random (version 4) UUID, so two devices never collide (section 6).
  String _uuid() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
