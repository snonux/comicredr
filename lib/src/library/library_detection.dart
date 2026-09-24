import 'dart:async';

import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/foundation.dart';

import '../data/panel_store.dart';
import '../reader/panel_detector.dart';
import 'library_store.dart';

/// Where the library pass is, for the library status line.
class DetectionStatus {
  const DetectionStatus({this.running = false, this.paused = false, this.done = 0, this.total = 0, this.book});

  /// A pass is under way: pages are being analysed, or wait their turn.
  final bool running;

  /// Paused from the status line, until resumed or the app restarts.
  final bool paused;

  /// Pages analysed in this pass, out of [total] that had no panels for
  /// the current detector when it started.
  final int done;
  final int total;

  /// The book being analysed now.
  final String? book;
}

/// Finds the panels of every book in the library in the background, so
/// guided view is ready in any book the moment it is opened (design plan
/// section 9, the laptop's whole-library pass).
///
/// A pass starts after each library scan. It skips every page already
/// analysed by the current detector (or a better one, or read from a
/// sidecar), so it picks up where it left off after a restart, and a new
/// detector generation redoes what the old one found. It is low priority:
/// books being read come first, it waits while the reader is busy (opening
/// a book, finding its panels, turning pages) and rests between pages as
/// long as the last page took, so it uses the detector half the time at
/// most. Pages of the book open in the reader that the reader found
/// meanwhile are skipped.
class LibraryDetection {
  LibraryDetection({
    required this.library,
    required this.panels,
    required this.detector,
    required this.enabled,
    this.openDocument = BackgroundDocument.open,
    this.onBook,
    this.onSaved,
    this.busy,
    this.openKey,
    this.poll = const Duration(milliseconds: 250),
    this.rest = true,
  });

  final LibraryStore library;
  final PanelStore panels;
  final Future<PanelDetector> Function() detector;

  /// The setting: whether the pass runs at all.
  final Future<bool> Function() enabled;
  final Future<ComicDocument> Function(String path) openDocument;

  /// Called before a book's pages are looked at: reads its sidecar, which
  /// may bring panels found elsewhere.
  final Future<void> Function(LibraryBook book)? onBook;

  /// Panels for [contentKey] were saved: its sidecar is due for a write.
  final void Function(String contentKey)? onSaved;

  /// Whether the reader wants the machine now.
  final bool Function()? busy;

  /// The book open in the reader, if any, whose pages the reader may find
  /// while the pass waits.
  final String? Function()? openKey;
  final Duration poll;

  /// Rest between pages as long as the page took. Off in tests.
  final bool rest;

  static const _maxRest = Duration(seconds: 2);

  final _status = StreamController<DetectionStatus>.broadcast();
  DetectionStatus _last = const DetectionStatus();
  Future<void>? _running;
  bool _again = false;
  bool _paused = false;
  bool _stopped = false;
  bool _off = false;

  Stream<DetectionStatus> get status => _status.stream;
  DetectionStatus get last => _last;
  bool get paused => _paused;

  void _emit(DetectionStatus s) {
    _last = s;
    if (!_status.isClosed) _status.add(s);
  }

  /// Starts a pass, or another one after the one under way, which a scan
  /// that found new books asks for.
  Future<void> run() {
    if (_stopped) return Future.value();
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      try {
        await _passOnce();
      } catch (e) {
        debugPrint('Library panel detection stopped: $e');
      }
    } while (_again && !_stopped);
    _emit(DetectionStatus(paused: _paused));
  }

  void pause() {
    _paused = true;
    _emit(
      DetectionStatus(running: _last.running, paused: true, done: _last.done, total: _last.total, book: _last.book),
    );
  }

  void resume() {
    _paused = false;
    _emit(DetectionStatus(running: _last.running, done: _last.done, total: _last.total, book: _last.book));
    unawaited(run());
  }

  /// The setting changed: stops at the next page when now off, starts a
  /// pass when now on.
  Future<void> reload() async {
    _off = !await enabled();
    if (!_off) unawaited(run());
  }

  Future<void> _passOnce() async {
    _off = !await enabled();
    if (_off) return;
    final det = await detector();
    final books = await library.books();
    final done = await panels.analysed(source: det.source, version: det.version);
    List<int> missing(LibraryBook b, Set<int>? have) => [
      for (var p = 0; p < b.pageCount; p++)
        if (!(have?.contains(p) ?? false)) p,
    ];
    final todo = [
      for (final b in books)
        if (missing(b, done[b.key]).isNotEmpty) b,
    ]..sort(_order);
    if (todo.isEmpty) return;
    final total = todo.fold(0, (n, b) => n + missing(b, done[b.key]).length);
    var count = 0;
    void emit(String? book) =>
        _emit(DetectionStatus(running: true, paused: _paused, done: count, total: total, book: book));
    emit(null);
    for (final book in todo) {
      final before = missing(book, done[book.key]).length;
      if (!await _turn()) return;
      try {
        await onBook?.call(book);
      } catch (e) {
        debugPrint('Could not read the sidecar of ${book.path}: $e');
      }
      Future<Set<int>?> have() async =>
          (await panels.analysed(source: det.source, version: det.version, contentKey: book.key))[book.key];
      final pages = missing(book, await have());
      count += before - pages.length;
      if (pages.isEmpty) continue;
      emit(book.name);
      final ComicDocument doc;
      try {
        doc = await openDocument(book.path);
      } catch (e) {
        debugPrint('Library panel detection cannot open ${book.path}: $e');
        count += pages.length;
        continue;
      }
      try {
        for (final page in pages) {
          if (!await _turn()) return;
          // The reader may have found it meanwhile, in the book it has open.
          if (openKey?.call() == book.key && ((await have())?.contains(page) ?? false)) {
            count++;
            continue;
          }
          final sw = Stopwatch()..start();
          try {
            final found = await det.detect(doc, page);
            await panels.save(book.key, page, found);
            onSaved?.call(book.key);
          } catch (e) {
            // Tried again next pass; the reader shows such a page whole.
            debugPrint('Library panel detection failed on ${book.path} page ${page + 1}: $e');
          }
          count++;
          emit(book.name);
          if (rest) await Future<void>.delayed(sw.elapsed < _maxRest ? sw.elapsed : _maxRest);
        }
      } finally {
        await doc.close().catchError((Object _) {});
      }
    }
  }

  /// Waits until the pass may analyse a page: not paused, the reader not
  /// busy. False when the pass should stop instead.
  Future<bool> _turn() async {
    while (!_stopped && !_off && (_paused || (busy?.call() ?? false))) {
      if (_paused) return false; // resume() starts a new pass.
      await Future<void>.delayed(poll);
    }
    return !_stopped && !_off;
  }

  /// Books being read first, the latest first; then the rest of the shelf
  /// in order, finished books last.
  static int _order(LibraryBook a, LibraryBook b) {
    int rank(LibraryBook x) => x.inProgress ? 0 : (x.finished ? 2 : 1);
    final r = rank(a) - rank(b);
    if (r != 0) return r;
    if (a.inProgress) return (b.readAt ?? DateTime(0)).compareTo(a.readAt ?? DateTime(0));
    final s = naturalCompare(a.series, b.series);
    return s != 0 ? s : naturalCompare(a.name, b.name);
  }

  Future<void> dispose() async {
    _stopped = true;
    await _running;
    await _status.close();
  }
}
