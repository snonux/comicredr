import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'app_database.dart';

/// Zoom and scroll outside guided view: the fit, the zoom on top of it, and
/// the point at the middle of the screen as a fraction of the laid-out page,
/// so it lands on the same spot in a window of another size.
typedef ViewSpot = ({String fit, double zoom, double cx, double cy});

/// Where reading stopped, down to the view: everything a reopen needs to put
/// the reader back on the same spot. The view fields are null in a row
/// saved before they existed; the reader keeps its current mode for those.
class ReadingPosition {
  const ReadingPosition({
    required this.page,
    this.panel,
    this.balloon = -1,
    this.guided,
    this.balloons,
    this.spread,
    this.coverAlone,
    this.rightToLeft,
    this.rotation,
    this.view,
  });

  final int page;

  /// The panel guided view was on, or would return to on `v`.
  final int? panel;

  /// The balloon inside [panel], -1 for the panel as a whole.
  final int balloon;
  final bool? guided;
  final bool? balloons;
  final bool? spread;
  final bool? coverAlone;
  final bool? rightToLeft;

  /// Quarter turns clockwise the comic is shown at, 0 to 3.
  final int? rotation;
  final ViewSpot? view;

  Map<String, Object?> _viewJson() => {
    'balloon': balloon,
    'guided': guided,
    'balloons': balloons,
    'spread': spread,
    'coverAlone': coverAlone,
    'rightToLeft': rightToLeft,
    if (rotation case final r? when r != 0) 'rotation': r,
    if (view case final v?) 'view': {'fit': v.fit, 'zoom': v.zoom, 'cx': v.cx, 'cy': v.cy},
  };

  static ReadingPosition _fromRow(ProgressData row) {
    Map<String, Object?> j = const {};
    try {
      if (row.viewJson case final s?) j = (jsonDecode(s) as Map).cast<String, Object?>();
    } catch (e) {
      debugPrint('Ignoring a broken saved view: $e');
    }
    final v = j['view'];
    return ReadingPosition(
      page: row.page,
      panel: row.panel,
      balloon: (j['balloon'] as num?)?.toInt() ?? -1,
      guided: j['guided'] as bool?,
      balloons: j['balloons'] as bool?,
      spread: j['spread'] as bool?,
      coverAlone: j['coverAlone'] as bool?,
      rightToLeft: j['rightToLeft'] as bool?,
      rotation: (j['rotation'] as num?)?.toInt(),
      view: v is Map
          ? (
              fit: v['fit'] as String? ?? 'page',
              zoom: (v['zoom'] as num?)?.toDouble() ?? 1,
              cx: (v['cx'] as num?)?.toDouble() ?? 0.5,
              cy: (v['cy'] as num?)?.toDouble() ?? 0.5,
            )
          : null,
    );
  }
}

/// Reading position, keyed by content key. Writes are debounced so a burst
/// of page turns costs one write, and [flush] runs on pause and close, so a
/// killed app loses at most the last half second (design plan section 6).
///
/// This is the one seam for positions: the per-comic sidecar (M8) takes the
/// storage over behind the same [load], [save] and [flush].
class ProgressStore {
  ProgressStore(this._db, {this.debounce = const Duration(milliseconds: 500)});

  final AppDatabase _db;
  final Duration debounce;
  Timer? _timer;
  ProgressCompanion? _pendingRow;

  Future<ReadingPosition?> load(String contentKey) async {
    final row = await (_db.select(_db.progress)..where((p) => p.contentKey.equals(contentKey))).getSingleOrNull();
    return row == null ? null : ReadingPosition._fromRow(row);
  }

  /// [lastShown] is the last page on screen, past [at]'s page in two-page
  /// mode: the percent and whether the book is finished go by it.
  void save(String contentKey, ReadingPosition at, int pageCount, {int? lastShown}) {
    final last = lastShown ?? at.page;
    _pendingRow = ProgressCompanion.insert(
      contentKey: contentKey,
      page: at.page,
      panel: Value(at.panel),
      percent: pageCount <= 1 ? 1 : (last / (pageCount - 1)).clamp(0.0, 1.0),
      finished: Value(last >= pageCount - 1),
      updatedAt: DateTime.now(),
      viewJson: Value(jsonEncode(at._viewJson())),
    );
    _timer?.cancel();
    _timer = Timer(debounce, flush);
  }

  Future<void> flush() async {
    _timer?.cancel();
    final row = _pendingRow;
    _pendingRow = null;
    if (row == null) return;
    try {
      await _db.into(_db.progress).insertOnConflictUpdate(row);
    } catch (e) {
      // Losing a reading position is better than crashing the reader.
      debugPrint('Could not save reading position: $e');
    }
  }
}
