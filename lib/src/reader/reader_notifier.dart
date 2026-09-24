import 'dart:async';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import '../data/panel_store.dart';
import '../data/progress_store.dart';
import '../providers.dart';
import 'guided.dart';
import 'layout.dart';
import 'open_book.dart';
import 'panel_detector.dart';

/// Everything about the open book that page navigation changes. Zoom and pan
/// are view concerns and live in the reader screen instead.
class ReaderState {
  const ReaderState({
    this.book,
    this.page = 0,
    this.panel = 0,
    this.mode = PageMode.single,
    this.guided = false,
    this.coverAlone = true,
    this.rightToLeft = false,
    this.fullscreen = false,
    this.night = false,
    this.panels = const {},
    this.marks = const {},
    this.jumpedFrom,
    this.loading = false,
    this.message,
  });

  final OpenBook? book;
  final int page;

  /// The panel on [page] guided view is showing, in reading order. Kept
  /// while guided view is off, so `v` comes back to the same panel.
  final int panel;

  /// Single page or spread: what shows outside guided view, and what `v`
  /// returns to.
  final PageMode mode;
  final bool guided;
  final bool coverAlone;
  final bool rightToLeft;
  final bool fullscreen;
  final bool night;

  /// Detection results for this book's pages; a page not in here has not
  /// been analysed yet.
  final Map<int, PagePanels> panels;

  /// vi-style marks a–z for this book.
  final Map<String, Place> marks;

  /// Where `''` goes back to: the place before the last jump.
  final Place? jumpedFrom;
  final bool loading;

  /// A short notice for the status line: an error, or why a key did nothing.
  final String? message;

  int get pageCount => book?.doc.pageCount ?? 0;

  List<int> get unit => book == null
      ? const []
      : guided
      ? [page]
      : unitAt(page, pageCount, mode, coverAlone: coverAlone);

  /// Camera stops on [p] in reading order; empty when the page is shown
  /// whole, either because its panels are unknown or because the gate
  /// failed.
  List<Panel> stopsOn(int p) => panels[p]?.stops(rightToLeft: rightToLeft) ?? const [];

  /// The panel guided view frames right now, or null for the whole page.
  Panel? get focus {
    if (!guided) return null;
    final stops = stopsOn(page);
    return stops.isEmpty ? null : stops[panel.clamp(0, stops.length - 1)];
  }

  /// [panel] resolved against what is known: -1 for the whole page.
  int get panelIndex {
    final n = stopsOn(page).length;
    return n == 0 ? -1 : panel.clamp(0, n - 1);
  }

  ReaderState copyWith({
    OpenBook? book,
    int? page,
    int? panel,
    PageMode? mode,
    bool? guided,
    bool? coverAlone,
    bool? rightToLeft,
    bool? fullscreen,
    bool? night,
    Map<int, PagePanels>? panels,
    Map<String, Place>? marks,
    Place? jumpedFrom,
    bool? loading,
    String? message,
  }) => ReaderState(
    book: book ?? this.book,
    page: page ?? this.page,
    panel: panel ?? this.panel,
    mode: mode ?? this.mode,
    guided: guided ?? this.guided,
    coverAlone: coverAlone ?? this.coverAlone,
    rightToLeft: rightToLeft ?? this.rightToLeft,
    fullscreen: fullscreen ?? this.fullscreen,
    night: night ?? this.night,
    panels: panels ?? this.panels,
    marks: marks ?? this.marks,
    jumpedFrom: jumpedFrom ?? this.jumpedFrom,
    loading: loading ?? this.loading,
    message: message, // Notices never carry over to the next state.
  );
}

final readerProvider = NotifierProvider<ReaderNotifier, ReaderState>(ReaderNotifier.new);

final progressStoreProvider = Provider<ProgressStore>((ref) {
  final store = ProgressStore(ref.watch(databaseProvider));
  ref.onDispose(store.flush);
  return store;
});

final panelStoreProvider = Provider<PanelStore>((ref) => PanelStore(ref.watch(databaseProvider)));

final markStoreProvider = Provider<MarkStore>((ref) => MarkStore(ref.watch(databaseProvider)));

final panelDetectorProvider = Provider<PanelDetector>((ref) => const PanelDetector());

class ReaderNotifier extends Notifier<ReaderState> {
  @override
  ReaderState build() => const ReaderState();

  ProgressStore get _progress => ref.read(progressStoreProvider);

  /// Pages waiting for detection, and whether the worker loop is running.
  final _wanted = <int>{};
  bool _detecting = false;

  /// Opens [path], closing any open book, and resumes where it was left.
  Future<void> open(String path) async {
    state = state.copyWith(loading: true);
    final OpenBook book;
    try {
      book = await openBook(path);
    } on OpenBookException catch (e) {
      state = state.copyWith(loading: false, message: e.message);
      return;
    } catch (e) {
      state = state.copyWith(loading: false, message: 'Could not open $path: $e');
      return;
    }
    await close();
    // A broken index must not keep a book from opening: each of these falls
    // back to nothing saved.
    final saved = await _orNull(() => _progress.load(book.key));
    final cached = await _orNull(() => ref.read(panelStoreProvider).load(book.key)) ?? const {};
    final marks = await _orNull(() => ref.read(markStoreProvider).load(book.key)) ?? const {};
    final page = (saved?.page ?? 0).clamp(0, book.doc.pageCount - 1);
    state = ReaderState(
      book: book,
      page: page,
      panel: saved?.panel ?? 0,
      mode: state.mode,
      guided: state.guided,
      coverAlone: state.coverAlone,
      rightToLeft: book.meta?.rightToLeft ?? false,
      fullscreen: state.fullscreen,
      night: state.night,
      panels: {for (final MapEntry(:key, :value) in cached.entries) key: PagePanels(value)},
      marks: marks,
      message: saved != null && saved.page > 0 ? 'Resumed at page ${page + 1}' : null,
    );
    _ensurePanels();
  }

  Future<T?> _orNull<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      debugPrint('Index read failed: $e');
      return null;
    }
  }

  Future<void> close() async {
    final book = state.book;
    if (book == null) return;
    await _progress.flush();
    _wanted.clear();
    state = ReaderState(mode: state.mode, guided: state.guided, fullscreen: state.fullscreen, night: state.night);
    await book.doc.close();
  }

  void _goTo(int page, {int panel = 0, bool jump = false}) {
    final book = state.book!;
    final target = page.clamp(0, state.pageCount - 1);
    state = state.copyWith(
      page: target,
      panel: panel,
      jumpedFrom: jump ? (page: state.page, panel: state.panel) : null,
    );
    _saveProgress(book);
    _ensurePanels();
  }

  void _saveProgress(OpenBook book) {
    final i = state.panelIndex;
    _progress.save(book.key, state.page, state.pageCount, panel: state.guided && i >= 0 ? i : null);
  }

  void _step(int steps) =>
      _goTo(stepFrom(state.page, steps, state.pageCount, state.mode, coverAlone: state.coverAlone));

  /// Guided view's step: the next or previous panel, crossing onto the
  /// neighbouring page at either end. A page shown whole is one step.
  void _stepGuided(int steps) {
    var page = state.page;
    var panel = state.panel;
    for (var i = 0; i < steps.abs(); i++) {
      final n = state.stopsOn(page).length;
      if (n > 0) panel = panel.clamp(0, n - 1);
      if (steps > 0) {
        if (n > 0 && panel < n - 1) {
          panel++;
        } else if (page < state.pageCount - 1) {
          page++;
          panel = 0;
        } else {
          break;
        }
      } else {
        if (n > 0 && panel > 0) {
          panel--;
        } else if (page > 0) {
          page--;
          panel = lastPanel;
        } else {
          break;
        }
      }
    }
    _goTo(page, panel: panel);
  }

  void _setGuided(bool on, {PageMode? mode}) {
    state = state.copyWith(guided: on, mode: mode);
    if (on) {
      _ensurePanels();
    } else if (state.book case final book?) {
      _saveProgress(book);
    }
  }

  void _notice(String message) => state = state.copyWith(message: message);

  /// Shows [message] on the status line until the next change.
  void notice(String message) => _notice(message);

  /// Queues detection for the pages guided view needs next: this one first,
  /// then the two ahead and the one behind, one page at a time.
  void _ensurePanels() {
    final book = state.book;
    if (book == null || !state.guided) return;
    for (final p in [state.page, state.page + 1, state.page + 2, state.page - 1]) {
      if (p >= 0 && p < state.pageCount && !state.panels.containsKey(p)) _wanted.add(p);
    }
    if (!_detecting) unawaited(_drain(book));
  }

  Future<void> _drain(OpenBook book) async {
    _detecting = true;
    try {
      while (_wanted.isNotEmpty && identical(state.book, book)) {
        // Nearest to the page being read first, ahead before behind.
        final page = _wanted.reduce((a, b) {
          final da = a - state.page, db = b - state.page;
          return da.abs() != db.abs() ? (da.abs() < db.abs() ? a : b) : (da >= 0 ? a : b);
        });
        _wanted.remove(page);
        if (state.panels.containsKey(page)) continue;
        List<Panel> frames;
        try {
          final (found, millis) = await ref.read(panelDetectorProvider).detect(book.doc, page);
          frames = found;
          unawaited(
            ref
                .read(panelStoreProvider)
                .save(book.key, page, frames, millis: millis)
                .catchError((Object e) => debugPrint('Could not cache panels: $e')),
          );
        } catch (e) {
          // An undecodable page is shown whole, like one the gate rejects.
          debugPrint('Panel detection failed on page ${page + 1}: $e');
          frames = const [];
        }
        if (!identical(state.book, book)) return;
        state = state.copyWith(panels: {...state.panels, page: PagePanels(frames)}, message: state.message);
      }
    } finally {
      _detecting = false;
    }
  }

  /// Page-level intents. The reader screen handles zoom and pan itself and
  /// passes everything else here.
  Future<void> handle(ReaderCommand c) async {
    if (state.book == null) {
      if (c.intent != ReaderIntent.showKeymap && c.intent != ReaderIntent.openFile) {
        _notice('Open a comic first: press o, or drop a .cbz on the window');
      }
      return;
    }
    // Right to left mirrors the step keys (l, h, arrows), so the key pointing
    // at the next page on screen still turns to it. Page keys stay logical.
    final mirror = state.rightToLeft ? -1 : 1;
    final step = state.guided ? _stepGuided : _step;
    final pageStep = state.guided ? (int n) => _goTo(state.page + n) : _step;
    switch (c.intent) {
      case ReaderIntent.nextStep:
        step(mirror * c.times);
      case ReaderIntent.prevStep:
        step(-mirror * c.times);
      case ReaderIntent.nextPage:
        pageStep(c.times);
      case ReaderIntent.prevPage:
        pageStep(-c.times);
      case ReaderIntent.firstPage:
        _goTo(0, jump: true);
      case ReaderIntent.lastPage:
        _goTo(c.count != null ? c.count! - 1 : state.pageCount - 1, jump: true);
      case ReaderIntent.nextBook:
      case ReaderIntent.prevBook:
        final next = await siblingBook(state.book!.path, next: c.intent == ReaderIntent.nextBook);
        if (next == null) {
          _notice(
            c.intent == ReaderIntent.nextBook ? 'No next book in this folder' : 'No previous book in this folder',
          );
        } else {
          await open(next);
        }
      case ReaderIntent.toggleGuided:
        _setGuided(!state.guided);
      case ReaderIntent.toggleSpread:
        // Guided view shows one page, so d from there goes to the spread.
        state.guided
            ? _setGuided(false, mode: PageMode.spread)
            : state = state.copyWith(mode: state.mode == PageMode.single ? PageMode.spread : PageMode.single);
      case ReaderIntent.cycleModeForward:
        // single → spread → guided → single. Continuous joins in a later milestone.
        if (state.guided) {
          _setGuided(false, mode: PageMode.single);
        } else if (state.mode == PageMode.single) {
          state = state.copyWith(mode: PageMode.spread);
        } else {
          _setGuided(true);
        }
      case ReaderIntent.cycleModeBack:
        if (state.guided) {
          _setGuided(false, mode: PageMode.spread);
        } else if (state.mode == PageMode.spread) {
          state = state.copyWith(mode: PageMode.single);
        } else {
          _setGuided(true);
        }
      case ReaderIntent.shiftSpread:
        state = state.copyWith(coverAlone: !state.coverAlone);
      case ReaderIntent.toggleDirection:
        state = state.copyWith(
          rightToLeft: !state.rightToLeft,
          message: state.rightToLeft ? 'Left to right' : 'Right to left',
        );
      case ReaderIntent.fullscreen:
        state = state.copyWith(fullscreen: !state.fullscreen);
      case ReaderIntent.nightFilter:
        state = state.copyWith(night: !state.night);
      case ReaderIntent.setMark:
        final i = state.panelIndex;
        final place = (page: state.page, panel: state.guided && i >= 0 ? i : 0);
        state = state.copyWith(
          marks: {...state.marks, c.register!: place},
          message:
              'Mark ${c.register} set at page ${state.page + 1}'
              '${state.guided && i >= 0 ? ', panel ${i + 1}' : ''}',
        );
        unawaited(
          ref
              .read(markStoreProvider)
              .save(state.book!.key, c.register!, place.page, place.panel)
              .catchError((Object e) => debugPrint('Could not save mark: $e')),
        );
      case ReaderIntent.jumpMark:
        final target = state.marks[c.register];
        target == null ? _notice('Mark ${c.register} is not set') : _goTo(target.page, panel: target.panel, jump: true);
      case ReaderIntent.jumpBack:
        final back = state.jumpedFrom;
        back == null ? _notice('No jump to go back from') : _goTo(back.page, panel: back.panel, jump: true);
      case ReaderIntent.back:
        // Esc leaves guided view before it means anything else.
        state.guided ? _setGuided(false) : await close();
      case ReaderIntent.toggleContinuous:
      case ReaderIntent.halfPageDown:
      case ReaderIntent.halfPageUp:
        _notice('Continuous scroll arrives in a later milestone');
      case ReaderIntent.bookmark:
        _notice('A bookmark list arrives with the library in M7; ma sets a mark meanwhile');
      case ReaderIntent.search:
      case ReaderIntent.searchNext:
      case ReaderIntent.searchPrev:
        _notice('Search needs a text layer, which arrives with PDF in M6');
      case ReaderIntent.autoTrim:
        _notice('Auto-trim arrives in M9');
      case ReaderIntent.panDown:
      case ReaderIntent.panUp:
      case ReaderIntent.fitWidth:
      case ReaderIntent.fitHeight:
      case ReaderIntent.fitPage:
      case ReaderIntent.zoomIn:
      case ReaderIntent.zoomOut:
      case ReaderIntent.zoomReset:
      case ReaderIntent.openFile:
      case ReaderIntent.showKeymap:
        break; // Handled by the screen.
    }
  }

  Future<void> flush() => _progress.flush();
}
