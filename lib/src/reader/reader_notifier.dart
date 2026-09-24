import 'dart:async';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import '../data/panel_store.dart';
import '../data/progress_store.dart';
import '../data/read_log_store.dart';
import '../data/settings_store.dart';
import '../data/sidecar.dart';
import '../data/sidecar_sync.dart';
import '../library/providers.dart';
import '../providers.dart';
import 'guided.dart';
import 'layout.dart';
import 'model_detector.dart';
import 'open_book.dart';
import 'panel_detector.dart';

/// Everything about the open book that page navigation changes. Zoom and pan
/// are view concerns and live in the reader screen instead.
class ReaderState {
  const ReaderState({
    this.book,
    this.page = 0,
    this.panel = 0,
    this.balloon = -1,
    this.mode = PageMode.single,
    this.guided = false,
    this.balloons = false,
    this.wholePageSteps = true,
    this.coverAlone = true,
    this.rightToLeft = false,
    this.fullscreen = false,
    this.night = false,
    this.trim = false,
    this.panels = const {},
    this.marks = const {},
    this.jumpedFrom,
    this.loading = false,
    this.message,
  });

  final OpenBook? book;
  final int page;

  /// The panel on [page] guided view is showing, in reading order, or
  /// [pageStart] or [pageEnd] for the whole page before or after the
  /// panels. Kept while guided view is off, so `v` comes back to it.
  final int panel;

  /// The balloon inside [panel] balloon mode is showing, in reading order;
  /// -1 for the panel as a whole, which comes first.
  final int balloon;

  /// Single page or spread: what shows outside guided view, and what `v`
  /// returns to.
  final PageMode mode;
  final bool guided;

  /// Balloon mode: guided view also steps through the balloons inside each
  /// panel, after showing the panel whole. Off by default, and remembered
  /// while guided view is off.
  final bool balloons;

  /// Guided view shows each page whole on arrival, before its first panel,
  /// and again after its last one, before moving on. A setting, on by
  /// default; `w` toggles it.
  final bool wholePageSteps;
  final bool coverAlone;
  final bool rightToLeft;
  final bool fullscreen;
  final bool night;

  /// Auto-trim: scanned margins are cut off each page (`t`). A setting,
  /// like [night], remembered across books and restarts.
  final bool trim;

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

  /// The balloons inside stop [stop] on page [p], in reading order.
  List<Panel> balloonsOn(int p, int stop) => panels[p]?.balloonsIn(stop, rightToLeft: rightToLeft) ?? const [];

  /// The panel, or in balloon mode the balloon, guided view frames right
  /// now; null for the whole page.
  Panel? get focus {
    if (!guided) return null;
    final i = panelIndex;
    if (i < 0) return null;
    final frame = stopsOn(page)[i];
    final b = balloonIndex;
    return b < 0 ? frame : balloonFocus(frame, balloonsOn(page, i)[b]);
  }

  /// [balloon] resolved against what is known: -1 for the panel as a whole,
  /// always so outside balloon mode.
  int get balloonIndex {
    if (!guided || !balloons) return -1;
    final i = panelIndex;
    if (i < 0) return -1;
    final n = balloonsOn(page, i).length;
    return n == 0 ? -1 : balloon.clamp(-1, n - 1);
  }

  /// [panel] resolved against what is known: -1 for the whole page, which
  /// is also what [pageStart] and [pageEnd] show.
  int get panelIndex {
    final n = stopsOn(page).length;
    return n == 0 || panel < 0 || panel >= pageEnd ? -1 : panel.clamp(0, n - 1);
  }

  /// Where guided view lands on arriving at a page.
  int get entryPanel => wholePageSteps ? pageStart : 0;

  ReaderState copyWith({
    OpenBook? book,
    int? page,
    int? panel,
    int? balloon,
    PageMode? mode,
    bool? guided,
    bool? balloons,
    bool? wholePageSteps,
    bool? coverAlone,
    bool? rightToLeft,
    bool? fullscreen,
    bool? night,
    bool? trim,
    Map<int, PagePanels>? panels,
    Map<String, Place>? marks,
    Place? jumpedFrom,
    bool? loading,
    String? message,
  }) => ReaderState(
    book: book ?? this.book,
    page: page ?? this.page,
    panel: panel ?? this.panel,
    balloon: balloon ?? this.balloon,
    mode: mode ?? this.mode,
    guided: guided ?? this.guided,
    balloons: balloons ?? this.balloons,
    wholePageSteps: wholePageSteps ?? this.wholePageSteps,
    coverAlone: coverAlone ?? this.coverAlone,
    rightToLeft: rightToLeft ?? this.rightToLeft,
    fullscreen: fullscreen ?? this.fullscreen,
    night: night ?? this.night,
    trim: trim ?? this.trim,
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

/// The sidecars beside the books. Pending writes go out when the app is
/// disposed.
final sidecarSyncProvider = Provider<SidecarSync>((ref) {
  final settings = ref.watch(settingsStoreProvider);
  final sync = SidecarSync(
    ref.watch(databaseProvider),
    progress: ref.watch(progressStoreProvider),
    coverDir: ref.watch(coverDirProvider),
    writeAllowed: () async => await settings.loadBool(SettingsStore.writeSidecars).catchError((_) => null) ?? true,
  );
  ref.onDispose(sync.flush);
  return sync;
});

/// Another device's later position in the book just opened, which the
/// reader offers rather than jumps to (design plan section 7).
typedef PositionOffer = ({String path, String contentKey, SidecarProgress at});

final positionOfferProvider = NotifierProvider<PositionOfferNotifier, PositionOffer?>(PositionOfferNotifier.new);

class PositionOfferNotifier extends Notifier<PositionOffer?> {
  @override
  PositionOffer? build() => null;

  void set(PositionOffer? offer) => state = offer;
}

final readLogStoreProvider = Provider<ReadLogStore>((ref) => ReadLogStore(ref.watch(databaseProvider)));

final panelStoreProvider = Provider<PanelStore>((ref) => PanelStore(ref.watch(databaseProvider)));

final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore(ref.watch(databaseProvider)));

final markStoreProvider = Provider<MarkStore>((ref) => MarkStore(ref.watch(databaseProvider)));

/// The trained model when one is installed (see [findModel]), classic CV
/// otherwise.
final panelDetectorProvider = FutureProvider<PanelDetector>((ref) async {
  final path = await findModel();
  debugPrint(path == null ? 'Panel detector: classic CV (no model installed)' : 'Panel detector: model $path');
  return PanelDetector(model: path == null ? null : await ModelDetector.open(path));
});

class ReaderNotifier extends Notifier<ReaderState> {
  @override
  ReaderState build() => const ReaderState();

  ProgressStore get _progress => ref.read(progressStoreProvider);
  SidecarSync get _sidecars => ref.read(sidecarSyncProvider);

  /// Zoom and scroll as the reader screen last reported them, saved with the
  /// position; and the saved one for the screen to restore on open.
  ViewSpot? _view;
  ViewSpot? _restoreView;

  /// The sitting under way, for reading history: when the book was opened
  /// (or the app came back) and the pages shown since.
  ({String key, DateTime start, Set<int> pages})? _sitting;

  /// Ends the sitting under way and logs it.
  Future<void> _endSitting() async {
    final s = _sitting;
    _sitting = null;
    if (s == null) return;
    try {
      await ref.read(readLogStoreProvider).record(s.key, s.start, DateTime.now(), s.pages.length);
    } catch (e) {
      debugPrint('Could not log the sitting: $e');
    }
  }

  /// Pages waiting for detection, and whether the worker loop is running.
  final _wanted = <int>{};
  bool _detecting = false;

  /// Opens [path], closing any open book, and resumes where it was left, or
  /// goes to [at] when given (a bookmark picked in the library).
  Future<void> open(String path, {Place? at}) async {
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
    // The sidecar first, so what it brings (panels from the laptop, a
    // position from the phone) is in the index before the reads below.
    final side = await _orNull(() => _sidecars.attach(book.path, book.key, folder: book.folder));
    // A broken index must not keep a book from opening: each of these falls
    // back to nothing saved.
    final saved = await _orNull(() => _progress.load(book.key));
    final detector = await ref.read(panelDetectorProvider.future);
    final cached =
        await _orNull(
          () => ref.read(panelStoreProvider).load(book.key, source: detector.source, version: detector.version),
        ) ??
        const {};
    final marks = await _orNull(() => ref.read(markStoreProvider).load(book.key)) ?? const {};
    final whole =
        await _orNull(() => ref.read(settingsStoreProvider).loadBool(SettingsStore.wholePageSteps)) ??
        state.wholePageSteps;
    final night = await _orNull(() => ref.read(settingsStoreProvider).loadBool(SettingsStore.night)) ?? state.night;
    final trim = await _orNull(() => ref.read(settingsStoreProvider).loadBool(SettingsStore.autoTrim)) ?? state.trim;
    final page = (at?.page ?? saved?.page ?? 0).clamp(0, book.doc.pageCount - 1);
    // The saved spot wins; a book never read, or saved before the view was,
    // keeps the mode the reader is in.
    final guided = saved?.guided ?? state.guided;
    final panel = at?.panel ?? saved?.panel ?? (whole ? pageStart : 0);
    final onPanel = guided && isPanel(panel);
    _view = _restoreView = at == null ? saved?.view : null;
    state = ReaderState(
      book: book,
      page: page,
      panel: panel,
      balloon: at == null ? saved?.balloon ?? -1 : -1,
      mode: switch (saved?.spread) {
        true => PageMode.spread,
        false => PageMode.single,
        null => state.mode,
      },
      guided: guided,
      balloons: saved?.balloons ?? state.balloons,
      wholePageSteps: whole,
      coverAlone: saved?.coverAlone ?? state.coverAlone,
      rightToLeft: saved?.rightToLeft ?? book.meta?.rightToLeft ?? false,
      fullscreen: state.fullscreen,
      night: night,
      trim: trim,
      panels: {for (final MapEntry(:key, :value) in cached.entries) key: PagePanels(value.frames, value.balloons)},
      marks: marks,
      message: at != null
          ? 'Bookmark: page ${page + 1}${onPanel ? ', panel ${panel + 1}' : ''}'
          : saved == null || (page == 0 && !guided)
          ? null
          : 'Resumed at page ${page + 1}${onPanel ? ', panel ${panel + 1}' : ''}'
                '${side?.adopted != null ? ' (read on ${side!.adopted!.deviceName})' : ''}',
    );
    ref
        .read(positionOfferProvider.notifier)
        .set(
          at == null && side?.elsewhere != null ? (path: book.path, contentKey: book.key, at: side!.elsewhere!) : null,
        );
    _sitting = (key: book.key, start: DateTime.now(), pages: <int>{});
    // Opening a book counts as reading it: the library's Reading tab lists
    // it from now on, even if it is closed on the cover.
    _saveProgress(book);
    _ensurePanels();
    unawaited(_writeSidecar(book));
  }

  /// Writes the sidecar as the book opens, so a folder that refuses it says
  /// so now rather than silently later.
  Future<void> _writeSidecar(OpenBook book) async {
    try {
      await _progress.flush();
      if (await _sidecars.write(book.key) || !identical(state.book, book)) return;
      _notice("Can't write beside this comic, so its panels and bookmarks stay in this app only");
    } catch (e) {
      debugPrint('Sidecar write failed: $e');
    }
  }

  /// Takes the offered position from another device: saves it as this
  /// device's and reopens the book there, view and all.
  Future<void> acceptOffer(PositionOffer offer) async {
    ref.read(positionOfferProvider.notifier).set(null);
    await close();
    await _sidecars.adopt(offer.contentKey, offer.at);
    await open(offer.path);
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
    await _endSitting();
    _wanted.clear();
    _view = _restoreView = null;
    state = ReaderState(
      mode: state.mode,
      guided: state.guided,
      balloons: state.balloons,
      wholePageSteps: state.wholePageSteps,
      fullscreen: state.fullscreen,
      night: state.night,
      trim: state.trim,
    );
    await book.doc.close();
    // Off the way of whatever opens next; flush() on exit waits for it.
    unawaited(_sidecars.flush().catchError((Object e) => debugPrint('Sidecar write failed: $e')));
  }

  /// Goes to [page], at [panel] or where guided view enters a page.
  void _goTo(int page, {int? panel, int balloon = -1, bool jump = false}) {
    final book = state.book!;
    final target = page.clamp(0, state.pageCount - 1);
    state = state.copyWith(
      page: target,
      panel: panel ?? state.entryPanel,
      balloon: balloon,
      jumpedFrom: jump ? (page: state.page, panel: state.panel) : null,
    );
    _saveProgress(book);
    _ensurePanels();
  }

  void _saveProgress(OpenBook book) {
    if (_sitting case final s? when s.key == book.key) s.pages.addAll(state.unit);
    // The panel and balloon as asked for, not as resolved: detection may not
    // have reached the page yet, and they resolve the same way on reopen.
    _progress.save(
      book.key,
      ReadingPosition(
        page: state.page,
        panel: state.panel,
        balloon: state.balloon,
        guided: state.guided,
        balloons: state.balloons,
        spread: state.mode == PageMode.spread,
        coverAlone: state.coverAlone,
        rightToLeft: state.rightToLeft,
        view: _view,
      ),
      state.pageCount,
    );
    _sidecars.touch(book.key);
  }

  /// The reader screen's zoom and scroll changed; saved with the position.
  void viewChanged(ViewSpot view) {
    _view = view;
    if (state.book case final book?) _saveProgress(book);
  }

  /// The saved zoom and scroll of the book just opened, once, for the reader
  /// screen to restore when its first page is laid out.
  ViewSpot? takeRestoredView() {
    final v = _restoreView;
    _restoreView = null;
    return v;
  }

  void _step(int steps) =>
      _goTo(stepFrom(state.page, steps, state.pageCount, state.mode, coverAlone: state.coverAlone));

  /// Guided view's step: the next or previous panel, crossing onto the
  /// neighbouring page at either end. A page shown whole is one step. In
  /// balloon mode a panel is shown whole first, then balloon by balloon;
  /// a panel without balloons is one step as before. With whole-page steps
  /// on, a page with panels is shown whole on arrival and again after its
  /// last panel, in both directions.
  void _stepGuided(int steps) {
    final whole = state.wholePageSteps;
    var page = state.page;
    var panel = state.panel;
    var balloon = state.balloons ? state.balloon : -1;
    for (var i = 0; i < steps.abs(); i++) {
      final n = state.stopsOn(page).length;
      // A page without panels is one step, whatever [panel] says.
      final atStart = n == 0 || panel < 0;
      final atEnd = n == 0 || panel >= pageEnd;
      if (!atStart && !atEnd) panel = panel.clamp(0, n - 1);
      final nb = state.balloons && !atStart && !atEnd ? state.balloonsOn(page, panel).length : 0;
      balloon = nb == 0 ? -1 : balloon.clamp(-1, nb - 1);
      if (steps > 0) {
        if (atEnd) {
          if (page >= state.pageCount - 1) break;
          page++;
          panel = whole ? pageStart : 0;
          balloon = -1;
        } else if (atStart) {
          panel = 0;
          balloon = -1;
        } else if (balloon < nb - 1) {
          balloon++;
        } else if (panel < n - 1) {
          panel++;
          balloon = -1;
        } else if (whole) {
          panel = pageEnd;
          balloon = -1;
        } else if (page < state.pageCount - 1) {
          page++;
          panel = 0;
          balloon = -1;
        } else {
          break;
        }
      } else {
        if (atStart) {
          if (page <= 0) break;
          page--;
          panel = whole ? pageEnd : lastPanel;
          balloon = whole ? -1 : lastBalloon;
        } else if (atEnd) {
          panel = n - 1;
          balloon = lastBalloon;
        } else if (balloon > -1) {
          balloon--;
        } else if (panel > 0) {
          panel--;
          balloon = lastBalloon;
        } else if (whole) {
          panel = pageStart;
          balloon = -1;
        } else if (page > 0) {
          page--;
          panel = lastPanel;
          balloon = lastBalloon;
        } else {
          break;
        }
      }
    }
    _goTo(page, panel: panel, balloon: state.balloons ? balloon : -1);
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
  /// then the two ahead and the one behind, one page at a time. On the
  /// laptop the rest of the book follows in the background, nearest first,
  /// so the whole book is analysed once while you read (design plan
  /// section 9); on the phone only the pages around the reader are.
  void _ensurePanels() {
    final book = state.book;
    if (book == null || !state.guided) return;
    final pages = defaultTargetPlatform == TargetPlatform.android
        ? [state.page, state.page + 1, state.page + 2, state.page - 1]
        : [for (var p = 0; p < state.pageCount; p++) p];
    for (final p in pages) {
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
        PagePanels found;
        try {
          final detector = await ref.read(panelDetectorProvider.future);
          final result = await detector.detect(book.doc, page);
          found = PagePanels(result.frames, result.balloons);
          unawaited(
            ref
                .read(panelStoreProvider)
                .save(book.key, page, result)
                .then((_) => _sidecars.touch(book.key))
                .catchError((Object e) => debugPrint('Could not cache panels: $e')),
          );
        } catch (e) {
          // An undecodable page is shown whole, like one the gate rejects.
          debugPrint('Panel detection failed on page ${page + 1}: $e');
          found = PagePanels(const []);
        }
        if (!identical(state.book, book)) return;
        state = state.copyWith(panels: {...state.panels, page: found}, message: state.message);
      }
    } finally {
      _detecting = false;
    }
  }

  /// Page-level intents. The reader screen handles zoom and pan itself and
  /// passes everything else here.
  Future<void> handle(ReaderCommand c) async {
    if (state.book == null) {
      if (c.intent != ReaderIntent.showKeymap &&
          c.intent != ReaderIntent.openFile &&
          c.intent != ReaderIntent.openFolder) {
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
        await _neighbour(next: c.intent == ReaderIntent.nextBook);
      case ReaderIntent.toggleGuided:
        _setGuided(!state.guided);
      case ReaderIntent.toggleBalloons:
        // b from outside guided view goes straight into it, balloons on.
        final on = !state.guided || !state.balloons;
        state = state.copyWith(balloons: on, balloon: -1, message: on ? 'Balloons on' : 'Balloons off');
        if (!state.guided) _setGuided(true);
      case ReaderIntent.toggleWholePage:
        final on = !state.wholePageSteps;
        state = state.copyWith(
          wholePageSteps: on,
          message: on ? 'Whole page before and after the panels' : 'Straight from panel to panel across pages',
        );
        _saveSetting(SettingsStore.wholePageSteps, on);
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
        final on = !state.night;
        state = state.copyWith(night: on, message: on ? 'Night filter on' : 'Night filter off');
        _saveSetting(SettingsStore.night, on);
      case ReaderIntent.setMark:
        final key = state.book!.key;
        final i = state.panelIndex;
        // A whole-page step is a place too, so the mark keeps it.
        final place = (page: state.page, panel: state.guided ? (i >= 0 ? i : state.panel) : 0);
        state = state.copyWith(
          marks: {...state.marks, c.register!: place},
          message:
              'Mark ${c.register} set at page ${state.page + 1}'
              '${state.guided && i >= 0 ? ', panel ${i + 1}' : ''}',
        );
        unawaited(
          ref
              .read(markStoreProvider)
              .save(key, c.register!, place.page, place.panel)
              .then((_) => _sidecars.touch(key))
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
        final key = state.book!.key;
        final i = state.panelIndex;
        final panel = state.guided && i >= 0 ? i : null;
        _notice('Bookmarked page ${state.page + 1}${panel != null ? ', panel ${panel + 1}' : ''}');
        unawaited(
          ref
              .read(markStoreProvider)
              .addBookmark(key, state.page, panel)
              .then((_) => _sidecars.touch(key))
              .catchError((Object e) => debugPrint('Could not save bookmark: $e')),
        );
      case ReaderIntent.search:
      case ReaderIntent.searchNext:
      case ReaderIntent.searchPrev:
        _notice('In-book search is not built yet');
      case ReaderIntent.autoTrim:
        final on = !state.trim;
        state = state.copyWith(trim: on, message: on ? 'Auto-trim: margins cut' : 'Auto-trim off: whole pages');
        _saveSetting(SettingsStore.autoTrim, on);
      case ReaderIntent.panDown:
      case ReaderIntent.panUp:
      case ReaderIntent.fitWidth:
      case ReaderIntent.fitHeight:
      case ReaderIntent.fitPage:
      case ReaderIntent.zoomIn:
      case ReaderIntent.zoomOut:
      case ReaderIntent.zoomReset:
      case ReaderIntent.openFile:
      case ReaderIntent.openFolder:
      case ReaderIntent.showKeymap:
      case ReaderIntent.addRoot:
      case ReaderIntent.rescan:
      case ReaderIntent.activate:
        break; // Handled by the screen, or only mean something in the library.
    }
    // Mode switches (guided, balloons, spread, direction) are part of the
    // spot too. Saves are debounced, so this costs nothing per key.
    if (state.book case final book?) _saveProgress(book);
  }

  void _saveSetting(String key, bool on) => unawaited(
    ref
        .read(settingsStoreProvider)
        .saveBool(key, on)
        .catchError((Object e) => debugPrint('Could not save setting: $e')),
  );

  /// `]` and `[`: the next or previous book in the series when the book is
  /// in the library with others in its series, the next or previous book in
  /// its folder otherwise.
  Future<void> _neighbour({required bool next}) async {
    final book = state.book!;
    final inSeries = await _orNull(() => ref.read(libraryStoreProvider).seriesNeighbour(book.key, next: next));
    if (inSeries != null) {
      final path = inSeries.path;
      if (path == null) {
        _notice(next ? 'This is the last book in the series' : 'This is the first book in the series');
      } else {
        await open(path);
      }
      return;
    }
    final path = await siblingBook(book.path, next: next);
    if (path == null) {
      _notice(next ? 'No next book in this folder' : 'No previous book in this folder');
    } else {
      await open(path);
    }
  }

  /// Saves the position and writes pending sidecars: on pause and exit.
  Future<void> flush() async {
    await _progress.flush();
    // The app may not come back: log the sitting, and start a new one that
    // a quick return joins back onto.
    if (_sitting case final s?) {
      await _endSitting();
      if (state.book?.key == s.key) _sitting = (key: s.key, start: DateTime.now(), pages: <int>{});
    }
    await _sidecars.flush();
  }
}
