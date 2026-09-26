import 'dart:async';
import 'dart:ui' show Color;

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
import '../library/library_store.dart';
import '../library/providers.dart';
import '../providers.dart';
import 'guided.dart';
import 'layout.dart';
import 'model_detector.dart';
import 'open_book.dart';
import 'panel_detector.dart';
import 'region.dart';
import 'reset_dialog.dart';

/// How guided view shows that it holds on a page shown whole.
enum PauseCue {
  /// The background around the page turns [heldColour] until it is left.
  colour,

  /// The page zooms out a little and back in.
  zoom,
}

/// The background of a held page: a deep wine red, dim enough for a dark
/// room yet plainly not black.
const heldColour = Color(0xFF3A0D16);

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
    this.pauseWhole = true,
    this.pauseCue = PauseCue.colour,
    this.held = false,
    this.cue = 0,
    this.coverAlone = true,
    this.wide = const {},
    this.wideAspects = const {},
    this.rightToLeft = false,
    this.rotation = 0,
    this.fullscreen = false,
    this.night = false,
    this.trim = false,
    this.cleanUp = false,
    this.panels = const {},
    this.marks = const {},
    this.bookmarks = const [],
    this.jumpedFrom,
    this.region,
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

  /// On a page guided view shows whole, the first step onward stays on the
  /// page and shows a cue ([pauseCue]); the next one turns. So a page
  /// without usable panels is not skipped before it is looked at. A
  /// setting, on by default; `W` toggles it.
  final bool pauseWhole;

  /// How a held page shows it is held: the background turns wine red
  /// until the page is left (the default), or the page zooms out and back.
  final PauseCue pauseCue;

  /// Guided view is holding on this page: the next step leaves it.
  final bool held;

  /// Counts the pauses on whole pages; the reader screen plays its cue
  /// each time it goes up.
  final int cue;
  final bool coverAlone;

  /// Pages wider than tall: scanned double-page spreads, shown alone in
  /// spread mode. Empty until the page sizes are read after opening.
  final Set<int> wide;

  /// Width over height of each page in [wide], so guided view can read a
  /// spread right to left page by page, as the detector does left to right.
  final Map<int, double> wideAspects;
  final bool rightToLeft;

  /// Quarter turns clockwise the comic is shown at, 0 to 3 (`>`, `<`,
  /// `gr`). Kept for this book with its position; guided view, page turns
  /// and zoom all happen on the turned page. Panels stay in the page's own
  /// coordinates, so turning never asks for detection again.
  final int rotation;
  final bool fullscreen;
  final bool night;

  /// Auto-trim: scanned margins are cut off each page (`t`). A setting,
  /// like [night], remembered across books and restarts.
  final bool trim;

  /// Scan clean-up (`c`): yellowed paper whitened, faded ink darkened, and
  /// pages with fewer pixels than the screen enlarged and sharpened. A
  /// setting like [trim]; detection still sees the page as scanned.
  final bool cleanUp;

  /// Detection results for this book's pages; a page not in here has not
  /// been analysed yet.
  final Map<int, PagePanels> panels;

  /// vi-style marks a–z for this book.
  final Map<String, Place> marks;

  /// This book's bookmarks and marks, in reading order, as the index has
  /// them: the list (`M`), the markers and `}` `{` read them.
  final List<BookmarkInfo> bookmarks;

  /// Where `''` goes back to: the place before the last jump.
  final Place? jumpedFrom;

  /// The part of a page shown enlarged by hand (`H1`, `B2`, `Q3`...), in
  /// guided view or out of it; null for the view as it would be. Steps go
  /// through the split's parts before moving on; leaving the page, a mode
  /// switch or Esc ends it.
  final Region? region;
  final bool loading;

  /// A short notice for the status line: an error, or why a key did nothing.
  final String? message;

  int get pageCount => book?.doc.pageCount ?? 0;

  List<int> get unit => book == null
      ? const []
      : guided
      ? [page]
      : unitAt(page, pageCount, mode, coverAlone: coverAlone, wide: wide);

  /// Camera stops on [p] in reading order; empty when the page is shown
  /// whole, either because its panels are unknown or because the gate
  /// failed.
  List<Panel> stopsOn(int p) => panels[p]?.stops(rightToLeft: rightToLeft, aspect: wideAspects[p] ?? 1) ?? const [];

  /// The balloons inside stop [stop] on page [p], in reading order.
  List<Panel> balloonsOn(int p, int stop) => panels[p]?.balloonsIn(stop, rightToLeft: rightToLeft, aspect: wideAspects[p] ?? 1) ?? const [];

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

  /// The real outline of the frame guided view is on, in page coordinates,
  /// when it is not its box (Panel.shape); null for a rectangle or the
  /// whole page. In balloon mode it is the balloon's frame.
  List<double>? get focusOutline {
    if (!guided) return null;
    final i = panelIndex;
    return i < 0 ? null : stopsOn(page)[i].shape;
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

  /// The bookmarks on what is shown, which the marker on the page stands
  /// for and `mm` takes off: in guided view on a panel, that panel's and
  /// its page's own; otherwise every bookmark on the pages shown. Marks
  /// a–z are not bookmarks here.
  List<BookmarkInfo> get bookmarksHere {
    if (book == null) return const [];
    final i = guided ? panelIndex : -1;
    final shown = unit;
    return [
      for (final b in bookmarks)
        if (b.mark == null && (i >= 0 ? b.page == page && (b.panel == null || b.panel == i) : shown.contains(b.page)))
          b,
    ];
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
    bool? pauseWhole,
    PauseCue? pauseCue,
    bool? held,
    int? cue,
    bool? coverAlone,
    Set<int>? wide,
    Map<int, double>? wideAspects,
    bool? rightToLeft,
    int? rotation,
    bool? fullscreen,
    bool? night,
    bool? trim,
    bool? cleanUp,
    Map<int, PagePanels>? panels,
    Map<String, Place>? marks,
    List<BookmarkInfo>? bookmarks,
    Place? jumpedFrom,
    Region? region,
    bool clearRegion = false,
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
    pauseWhole: pauseWhole ?? this.pauseWhole,
    pauseCue: pauseCue ?? this.pauseCue,
    held: held ?? this.held,
    cue: cue ?? this.cue,
    coverAlone: coverAlone ?? this.coverAlone,
    wide: wide ?? this.wide,
    wideAspects: wideAspects ?? this.wideAspects,
    rightToLeft: rightToLeft ?? this.rightToLeft,
    rotation: rotation ?? this.rotation,
    fullscreen: fullscreen ?? this.fullscreen,
    night: night ?? this.night,
    trim: trim ?? this.trim,
    cleanUp: cleanUp ?? this.cleanUp,
    panels: panels ?? this.panels,
    marks: marks ?? this.marks,
    bookmarks: bookmarks ?? this.bookmarks,
    jumpedFrom: jumpedFrom ?? this.jumpedFrom,
    region: clearRegion ? null : region ?? this.region,
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
    storeDir: () => settings.loadString(SettingsStore.sidecarDir),
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

/// The trained model, built in or installed by the user (see [findModel]),
/// classic CV when there is none.
final panelDetectorProvider = FutureProvider<PanelDetector>((ref) async {
  final path = await findModel();
  debugPrint(path == null ? 'Panel detector: classic CV (no model)' : 'Panel detector: model $path');
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

  /// Finding panels for the open book right now.
  bool get detecting => _detecting;

  /// Opens [path], closing any open book, and resumes where it was left, or
  /// goes to [at] when given (a bookmark picked in the library).
  Future<void> open(String path, {Place? at}) async {
    state = state.copyWith(loading: true);
    OpenBook book;
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
    // Titles edited in the library, some perhaps just now from the sidecar.
    final edits = await _orNull(() => ref.read(libraryStoreProvider).edits(book.key));
    if (edits != null) book = book.withEdits(edits);
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
    final pause =
        await _orNull(() => ref.read(settingsStoreProvider).loadBool(SettingsStore.pauseWhole)) ?? state.pauseWhole;
    final cueName = await _orNull(() => ref.read(settingsStoreProvider).loadString(SettingsStore.pauseCue));
    final pauseCue = PauseCue.values.asNameMap()[cueName] ?? state.pauseCue;
    final night = await _orNull(() => ref.read(settingsStoreProvider).loadBool(SettingsStore.night)) ?? state.night;
    final trim = await _orNull(() => ref.read(settingsStoreProvider).loadBool(SettingsStore.autoTrim)) ?? state.trim;
    final cleanUp =
        await _orNull(() => ref.read(settingsStoreProvider).loadBool(SettingsStore.cleanUp)) ?? state.cleanUp;
    final fullscreen =
        await _orNull(() => ref.read(settingsStoreProvider).loadBool(SettingsStore.fullscreen)) ?? state.fullscreen;
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
      pauseWhole: pause,
      pauseCue: pauseCue,
      cue: state.cue,
      coverAlone: saved?.coverAlone ?? state.coverAlone,
      rightToLeft: saved?.rightToLeft ?? book.meta?.rightToLeft ?? false,
      rotation: (saved?.rotation ?? 0) % 4,
      fullscreen: fullscreen,
      night: night,
      trim: trim,
      cleanUp: cleanUp,
      panels: {
        for (final MapEntry(:key, :value) in cached.entries) key: PagePanels(value.frames, value.balloons, value.trim),
      },
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
    _watchBookmarks(book);
    unawaited(_readWidePages(book));
    unawaited(_writeSidecar(book));
  }

  StreamSubscription<List<BookmarkInfo>>? _bookmarkWatch;

  /// Follows [book]'s bookmarks and marks in the index, so a change from
  /// the list, the library or a sidecar shows at once.
  void _watchBookmarks(OpenBook book) {
    unawaited(_bookmarkWatch?.cancel());
    _bookmarkWatch = ref.read(libraryStoreProvider).watchBookmarks(book.key).listen((all) {
      if (!identical(state.book, book)) return;
      state = state.copyWith(
        bookmarks: all,
        marks: {for (final b in all) ?b.mark: (page: b.page, panel: b.panel ?? 0)},
        message: state.message,
      );
    }, onError: (Object e) => debugPrint('Could not read bookmarks: $e'));
  }

  /// Goes to bookmark [b]: its panel in guided view, its page otherwise. A
  /// jump, so `''` comes back.
  void jumpToBookmark(BookmarkInfo b) {
    if (state.book == null) return;
    // Without a panel, guided view shows the page whole.
    _goTo(b.page, panel: b.panel ?? pageStart, jump: true);
    _notice(
      '${b.mark == null ? 'Bookmark' : "Mark '${b.mark}"}: ${describePlace(b)}'
      '${b.note == null ? '' : '  ·  ${b.note}'}',
    );
  }

  /// Removes bookmark [id] of the open book, from the list (`M`).
  Future<void> removeBookmark(String id) async {
    final key = state.book?.key;
    if (key == null) return;
    state = state.copyWith(bookmarks: [...state.bookmarks.where((b) => b.id != id)]);
    try {
      await ref.read(libraryStoreProvider).deleteBookmark(id);
      _sidecars.touch(key);
    } catch (e) {
      debugPrint('Could not remove the bookmark: $e');
    }
  }

  /// Gives bookmark [id] of the open book a note; empty takes it off.
  Future<void> setBookmarkNote(String id, String note) async {
    final key = state.book?.key;
    if (key == null) return;
    try {
      await ref.read(libraryStoreProvider).setNote(id, note);
      _sidecars.touch(key);
    } catch (e) {
      debugPrint('Could not save the note: $e');
    }
  }

  /// `}` and `{`: the next or previous bookmark in reading order, from the
  /// panel guided view is on, or from the pages shown.
  void _stepBookmark(int by) {
    final all = [...state.bookmarks.where((b) => b.mark == null)]..sort(BookmarkInfo.order);
    if (all.isEmpty) {
      _notice('No bookmarks in this book yet: mm adds one');
      return;
    }
    // Where we are, in the same order: page, then panel, the whole page
    // before its panels and after them once they are read.
    final i = state.panelIndex;
    final here = state.guided ? (page: state.page, panel: i >= 0 ? i : (state.panel >= pageEnd ? 1 << 30 : -1)) : null;
    int compare(BookmarkInfo b, int page, int panel) =>
        b.page != page ? b.page.compareTo(page) : (b.panel ?? -1).compareTo(panel);
    BookmarkInfo? target;
    if (by > 0) {
      final after = [
        for (final b in all)
          if (here != null ? compare(b, here.page, here.panel) > 0 : b.page > state.unit.last) b,
      ];
      if (after.isNotEmpty) target = after[(by - 1).clamp(0, after.length - 1)];
    } else {
      final before = [
        for (final b in all)
          if (here != null ? compare(b, here.page, here.panel) < 0 : b.page < state.unit.first) b,
      ];
      if (before.isNotEmpty) target = before[(before.length + by).clamp(0, before.length - 1)];
    }
    if (target == null) {
      _notice(by > 0 ? 'No bookmark after this one' : 'No bookmark before this one');
      return;
    }
    jumpToBookmark(target);
    final n = all.indexOf(target) + 1;
    _notice(
      'Bookmark $n of ${all.length}: ${describePlace(target)}'
      '${target.note == null ? '' : '  ·  ${target.note}'}',
    );
  }

  /// `mm`: bookmarks the page, or the panel in guided view; when what is
  /// shown already has one ([ReaderState.bookmarksHere]), takes it off.
  Future<void> _toggleBookmark() async {
    final book = state.book!;
    final here = state.bookmarksHere;
    final store = ref.read(libraryStoreProvider);
    if (here.isNotEmpty) {
      final ids = {for (final b in here) b.id};
      state = state.copyWith(
        bookmarks: [...state.bookmarks.where((b) => !ids.contains(b.id))],
        message: here.length == 1
            ? 'Bookmark removed from ${describePlace(here.first)}'
            : 'Removed ${here.length} bookmarks from page ${state.page + 1}',
      );
      try {
        await store.deleteBookmarks(ids);
        _sidecars.touch(book.key);
      } catch (e) {
        debugPrint('Could not remove the bookmark: $e');
      }
      return;
    }
    final i = state.panelIndex;
    final panel = state.guided && i >= 0 ? i : null;
    final page = state.page;
    _notice('Bookmarked page ${page + 1}${panel != null ? ', panel ${panel + 1}' : ''}  ·  M lists them');
    try {
      final id = await ref.read(markStoreProvider).addBookmark(book.key, page, panel);
      _sidecars.touch(book.key);
      // Shown at once; the index's own update follows.
      if (identical(state.book, book) && !state.bookmarks.any((b) => b.id == id)) {
        state = state.copyWith(
          bookmarks: [
            ...state.bookmarks,
            BookmarkInfo(id: id, contentKey: book.key, page: page, panel: panel, createdAt: DateTime.now()),
          ]..sort(BookmarkInfo.order),
          message: state.message,
        );
      }
    } catch (e) {
      debugPrint('Could not save bookmark: $e');
    }
  }

  /// `*`: puts the book in the Favourites collection, or takes it out.
  Future<void> _toggleFavourite() async {
    final book = state.book!;
    final store = ref.read(libraryStoreProvider);
    try {
      final on = !await store.isFavourite(book.key);
      await store.setFavourite(book.key, on);
      _sidecars.touch(book.key);
      if (identical(state.book, book)) {
        _notice(on ? 'Added to Favourites  ·  gf lists them' : 'Taken out of Favourites');
      }
    } catch (e) {
      _notice('Could not change the favourites: $e');
    }
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
    unawaited(_bookmarkWatch?.cancel());
    _bookmarkWatch = null;
    await _progress.flush();
    await _endSitting();
    _wanted.clear();
    _wake?.complete();
    _wake = null;
    _view = _restoreView = null;
    state = ReaderState(
      mode: state.mode,
      guided: state.guided,
      balloons: state.balloons,
      wholePageSteps: state.wholePageSteps,
      pauseWhole: state.pauseWhole,
      pauseCue: state.pauseCue,
      cue: state.cue,
      fullscreen: state.fullscreen,
      night: state.night,
      trim: state.trim,
      cleanUp: state.cleanUp,
    );
    await book.doc.close();
    // Off the way of whatever opens next; flush() on exit waits for it.
    unawaited(_sidecars.flush().catchError((Object e) => debugPrint('Sidecar write failed: $e')));
  }

  /// Resets the open book (see [SidecarSync.reset]) and opens it again:
  /// where it was, finding its panels anew, after [ResetScope.panels]; on
  /// the first page, as if never opened, after [ResetScope.everything].
  Future<void> reset(ResetScope scope) async {
    final book = state.book;
    if (book == null) return;
    await close();
    var ok = true;
    try {
      ok = await _sidecars.reset(book.key, everything: scope == ResetScope.everything);
    } catch (e) {
      debugPrint('Reset failed: $e');
      state = state.copyWith(message: 'Could not reset ${book.title}: $e');
      return;
    }
    await open(book.path);
    if (state.book?.key != book.key) return; // It could not be opened again; open() said why.
    _notice(
      !ok
          ? "Reset here, but the file beside the comic can't be changed, so the next open may bring it back"
          : scope == ResetScope.everything
          ? 'Started ${book.title} from scratch'
          : state.guided
          ? 'Finding the panels again'
          : 'Panels forgotten; guided view (v) finds them again',
    );
  }

  /// Finds the wide pages of [book], which spread mode shows alone. The
  /// sizes come from the page headers on the book's worker, after the page
  /// being opened on, so the first page is not kept waiting; until they
  /// arrive, spreads pair as if every page were narrow.
  Future<void> _readWidePages(OpenBook book) async {
    final List<(int, int)?> sizes;
    try {
      sizes = await book.doc.pageSizes();
    } catch (e) {
      debugPrint('Could not read the page sizes of ${book.path}: $e');
      return;
    }
    final aspects = {
      for (var i = 0; i < sizes.length; i++)
        if (sizes[i] case (final w, final h) when isWidePage(w, h)) i: w / h,
    };
    if (aspects.isNotEmpty && identical(state.book, book)) {
      state = state.copyWith(wide: aspects.keys.toSet(), wideAspects: aspects);
    }
  }

  /// Goes to [page], at [panel] or where guided view enters a page.
  void _goTo(int page, {int? panel, int balloon = -1, bool jump = false}) {
    final book = state.book!;
    final target = page.clamp(0, state.pageCount - 1);
    state = state.copyWith(
      page: target,
      held: target == state.page && !jump && state.held,
      panel: panel ?? state.entryPanel,
      balloon: balloon,
      jumpedFrom: jump ? (page: state.page, panel: state.panel) : null,
      clearRegion: true,
    );
    _saveProgress(book);
    _ensurePanels();
  }

  /// Goes to [page] from the page grid or the progress bar: a jump, so
  /// `''` comes back.
  void jumpTo(int page) {
    if (state.book == null || page == state.page) return;
    _goTo(page, jump: true);
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
        rotation: state.rotation,
        view: _view,
      ),
      state.pageCount,
      // The pair 2-3 of a three-page book shows its last page: finished.
      lastShown: state.unit.isEmpty ? null : state.unit.last,
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
      _goTo(stepFrom(state.page, steps, state.pageCount, state.mode, coverAlone: state.coverAlone, wide: state.wide));

  /// Guided view's step: the next or previous panel, crossing onto the
  /// neighbouring page at either end. A page shown whole is one step. In
  /// balloon mode a panel is shown whole first, then balloon by balloon;
  /// a panel without balloons is one step as before. With whole-page steps
  /// on, a page with panels is shown whole on arrival and again after its
  /// last panel, in both directions.
  void _stepGuided(int steps) {
    if (steps.abs() == 1 && _pauseOnWhole(forward: steps > 0)) return;
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

  /// `H1`, `B2`, `Q3`...: shows [part] of [split] enlarged on the page the
  /// reader is on (in a spread, the page it already shows a part of, else
  /// the first in reading order). The same keys again go back to the whole
  /// page.
  void _showRegion(PageSplit split, int part) {
    final r = state.region;
    if (r != null && r.split == split && r.part == part) {
      state = state.copyWith(clearRegion: true, message: 'Whole page');
      return;
    }
    final unit = state.unit;
    if (unit.isEmpty) return;
    final region = (split: split, part: part, page: r != null && unit.contains(r.page) ? r.page : unit.first);
    state = state.copyWith(
      region: region,
      held: false,
      message:
          '${_capitalised(describeRegion(region, rightToLeft: state.rightToLeft))}'
          '  ·  l and h step through the ${split.name}, Esc shows the whole page',
    );
  }

  static String _capitalised(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// A step while a part of the page is enlarged: the next or previous part
  /// in reading order, onto the other page of a spread, and past the last
  /// (or first) part the whole page again, where the step after it moves
  /// on. In guided view that whole page is held like a page without
  /// panels (the wine red), and the next step turns.
  void _stepRegion(int steps) {
    final r = state.region!;
    final order = partOrder(r.split, rightToLeft: state.rightToLeft);
    final unit = state.unit;
    var at = unit.indexOf(r.page);
    var i = order.indexOf(r.part);
    if (at < 0) {
      state = state.copyWith(clearRegion: true);
      return;
    }
    for (var k = 0; k < steps.abs(); k++) {
      if (steps > 0) {
        if (i < order.length - 1) {
          i++;
        } else if (at < unit.length - 1) {
          at++;
          i = 0;
        } else {
          _leaveRegion(forward: true);
          return;
        }
      } else {
        if (i > 0) {
          i--;
        } else if (at > 0) {
          at--;
          i = order.length - 1;
        } else {
          _leaveRegion(forward: false);
          return;
        }
      }
    }
    final region = (split: r.split, part: order[i], page: unit[at]);
    state = state.copyWith(
      region: region,
      message: _capitalised(describeRegion(region, rightToLeft: state.rightToLeft)),
    );
  }

  /// Past the last part going on, or the first going back: the whole page,
  /// on its far side, so the next step leaves it.
  void _leaveRegion({required bool forward}) {
    if (!state.guided) {
      state = state.copyWith(clearRegion: true, message: 'Whole page');
      return;
    }
    final hold = state.pauseWhole && state.stopsOn(state.page).isEmpty;
    state = state.copyWith(
      clearRegion: true,
      panel: forward ? pageEnd : pageStart,
      balloon: -1,
      held: hold,
      cue: hold ? state.cue + 1 : state.cue,
      message: 'Whole page: press again for the ${forward ? 'next' : 'previous'} page',
    );
  }

  /// Pauses of the step that would leave a page shown whole: the first
  /// step onward stays on the page, moved to its far side ([pageEnd] going
  /// forward, [pageStart] going back), and plays the cue; the step after it
  /// turns. It stays held, [ReaderState.held], until left. A page arrived
  /// on from the other side, or jumped to, starts on
  /// the near side. After one pause the page is left by the next step
  /// either way. Pages whose panels are not known yet are not held, nor is
  /// a count (`3l`).
  bool _pauseOnWhole({required bool forward}) {
    if (!state.pauseWhole ||
        state.held ||
        !state.panels.containsKey(state.page) ||
        state.stopsOn(state.page).isNotEmpty) {
      return false;
    }
    // Arriving from behind lands on pageStart or 0, from ahead on pageEnd
    // or lastPanel.
    final farSide = state.panel >= lastPanel;
    if (forward == farSide) return false;
    final shown = _pauseHints++ < 3 || _reduceMotion;
    state = state.copyWith(
      panel: forward ? pageEnd : pageStart,
      balloon: -1,
      held: true,
      cue: state.cue + 1,
      message: shown ? 'Whole page: press again for the ${forward ? 'next' : 'previous'} page' : state.message,
    );
    if (state.book case final book?) _saveProgress(book);
    return true;
  }

  /// Pauses on whole pages so far in this run: the status line explains
  /// the first few.
  int _pauseHints = 0;

  /// The system asks for reduced motion, so the zoom cue gives way to the
  /// colour and the status line's hint shows every time. The reader
  /// screen tells it.
  bool _reduceMotion = false;
  set reduceMotion(bool on) => _reduceMotion = on;

  void _setGuided(bool on, {PageMode? mode}) {
    state = state.copyWith(guided: on, mode: mode, clearRegion: true);
    if (on) {
      _ensurePanels();
    } else if (state.book case final book?) {
      _saveProgress(book);
    }
  }

  void _notice(String message) => state = state.copyWith(message: message);

  /// Takes up the fullscreen saved last time, at launch.
  Future<void> loadFullscreen() async {
    final on = await _orNull(() => ref.read(settingsStoreProvider).loadBool(SettingsStore.fullscreen));
    if (on != null && on != state.fullscreen) state = state.copyWith(fullscreen: on);
  }

  /// Fullscreen on or off, remembered for the next book and launch. The
  /// window follows it (HomeScreen); the window manager leaving fullscreen
  /// by itself comes back here too.
  void setFullscreen(bool on) {
    if (on == state.fullscreen) return;
    state = state.copyWith(fullscreen: on);
    _saveSetting(SettingsStore.fullscreen, on);
  }

  /// Shows [message] on the status line until the next change.
  void notice(String message) => _notice(message);

  /// Queues detection for the open book, whether guided view is on or
  /// not, so it is ready when it is turned on: this page first, then the
  /// two ahead and the one behind, then the rest of the book ahead of the
  /// reader, nearest first. Only the open book is ever analysed, and never
  /// the pages a jump leaves behind; closing it stops the work. Pages beyond the first few ahead are low priority:
  /// before each one the worker rests as long as the last page took, and
  /// a page the reader turns to goes first.
  void _ensurePanels() {
    final book = state.book;
    if (book == null) return;
    // In advance only: pages left behind by a jump are not worth the time.
    _wanted.removeWhere((p) => p < state.page - 1);
    for (var p = state.page - 1; p < state.pageCount; p++) {
      if (p >= 0 && !state.panels.containsKey(p)) _wanted.add(p);
    }
    _wake?.complete();
    _wake = null;
    if (!_detecting) unawaited(_drain(book));
  }

  /// Ends a low-priority rest early: the reader wants a page now.
  Completer<void>? _wake;

  static const _maxRest = Duration(seconds: 2);

  /// Pages around the reader that are detected at once, without a rest.
  bool _near(int page) => page >= state.page - 1 && page <= state.page + 2;

  Future<void> _drain(OpenBook book) async {
    _detecting = true;
    var last = Duration.zero;
    try {
      while (_wanted.isNotEmpty && ref.mounted && identical(state.book, book)) {
        // Nearest to the page being read first, ahead before behind.
        int next() => _wanted.reduce((a, b) {
          final da = a - state.page, db = b - state.page;
          return da.abs() != db.abs() ? (da.abs() < db.abs() ? a : b) : (da >= 0 ? a : b);
        });
        if (!_near(next()) && last > Duration.zero) {
          final wake = _wake = Completer<void>();
          await Future.any([wake.future, Future<void>.delayed(last < _maxRest ? last : _maxRest)]);
          if (identical(_wake, wake)) _wake = null;
          if (!ref.mounted) return;
          last = Duration.zero;
          continue;
        }
        final page = next();
        _wanted.remove(page);
        if (state.panels.containsKey(page)) continue;
        final sw = Stopwatch()..start();
        PagePanels found;
        try {
          final detector = await ref.read(panelDetectorProvider.future);
          final result = await detector.detect(book.doc, page);
          found = PagePanels(result.frames, result.balloons, result.trim);
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
        last = sw.elapsed;
        if (!ref.mounted || !identical(state.book, book)) return;
        state = state.copyWith(panels: {...state.panels, page: found}, message: state.message);
      }
    } finally {
      _detecting = false;
      // A book opened while this one was detecting queued its pages but
      // found a drain running; that drain was this one, so start its own.
      final now = ref.mounted ? state.book : null;
      if (now != null && !identical(now, book) && _wanted.isNotEmpty) unawaited(_drain(now));
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
    final step = state.region != null ? _stepRegion : (state.guided ? _stepGuided : _step);
    final pageStep = state.guided ? (int n) => _goTo(state.page + n) : _step;
    final shownBefore = (state.guided, state.mode);
    if (regionFor(c.intent) case final r?) {
      _showRegion(r.split, r.part);
      _saveProgress(state.book!);
      return;
    }
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
      case ReaderIntent.togglePauseWhole:
        final on = !state.pauseWhole;
        state = state.copyWith(
          pauseWhole: on,
          message: on ? 'Pages shown whole hold for one more step' : 'Pages shown whole turn at once',
        );
        _saveSetting(SettingsStore.pauseWhole, on);
      case ReaderIntent.cyclePauseCue:
        final cue = PauseCue.values[(state.pauseCue.index + 1) % PauseCue.values.length];
        state = state.copyWith(
          pauseCue: cue,
          message: switch (cue) {
            PauseCue.colour => 'Held pages: wine-red background',
            PauseCue.zoom => 'Held pages: zoom out and back',
          },
        );
        unawaited(
          ref
              .read(settingsStoreProvider)
              .saveString(SettingsStore.pauseCue, cue.name)
              .catchError((Object e) => debugPrint('Could not save a setting: $e')),
        );
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
      case ReaderIntent.rotateClockwise:
        _rotateTo(state.rotation + c.times);
      case ReaderIntent.rotateCounterClockwise:
        _rotateTo(state.rotation - c.times);
      case ReaderIntent.rotateReset:
        _rotateTo(0);
      case ReaderIntent.fullscreen:
        setFullscreen(!state.fullscreen);
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
        // Esc goes back to the whole page from a part of it, then leaves
        // guided view before it means anything else. Fullscreen stays: the
        // library is fullscreen too, and Esc at its top leaves it.
        if (state.region != null) {
          state = state.copyWith(clearRegion: true, message: 'Whole page');
        } else {
          state.guided ? _setGuided(false) : await close();
        }
      case ReaderIntent.toggleContinuous:
      case ReaderIntent.halfPageDown:
      case ReaderIntent.halfPageUp:
        _notice('Continuous scroll is not built yet');
      case ReaderIntent.bookmark:
        await _toggleBookmark();
      case ReaderIntent.toggleFavourite:
        await _toggleFavourite();
      case ReaderIntent.nextBookmark:
        _stepBookmark(c.times);
      case ReaderIntent.prevBookmark:
        _stepBookmark(-c.times);
      case ReaderIntent.search:
      case ReaderIntent.searchNext:
      case ReaderIntent.searchPrev:
        _notice('In-book search is not built yet');
      case ReaderIntent.autoTrim:
        final on = !state.trim;
        state = state.copyWith(trim: on, message: on ? 'Auto-trim: margins cut' : 'Auto-trim off: whole pages');
        _saveSetting(SettingsStore.autoTrim, on);
      case ReaderIntent.cleanUp:
        final on = !state.cleanUp;
        state = state.copyWith(
          cleanUp: on,
          message: on
              ? 'Clean-up on: paper whitened, ink darkened, small pages sharpened'
              : 'Clean-up off: pages as scanned',
        );
        _saveSetting(SettingsStore.cleanUp, on);
      case ReaderIntent.panDown:
      case ReaderIntent.panUp:
      case ReaderIntent.fitWidth:
      case ReaderIntent.fitHeight:
      case ReaderIntent.fitPage:
      case ReaderIntent.zoomIn:
      case ReaderIntent.zoomOut:
      case ReaderIntent.zoomReset:
      case ReaderIntent.zoomToggle:
      case ReaderIntent.showTouchZones:
      case ReaderIntent.showTime:
      case ReaderIntent.openFile:
      case ReaderIntent.openFolder:
      case ReaderIntent.showKeymap:
      case ReaderIntent.addRoot:
      case ReaderIntent.rescan:
      case ReaderIntent.toggleShuffle:
      case ReaderIntent.reshuffle:
      case ReaderIntent.resetBook:
      case ReaderIntent.deleteBook:
      case ReaderIntent.editBook:
      case ReaderIntent.activate:
      case ReaderIntent.up:
      case ReaderIntent.pageGrid:
      case ReaderIntent.showDetails:
      case ReaderIntent.bookmarkList:
      case ReaderIntent.remove:
      case ReaderIntent.showFavourites:
      case ReaderIntent.regionUpperHalf:
      case ReaderIntent.regionLowerHalf:
      case ReaderIntent.regionUpperThird:
      case ReaderIntent.regionMiddleThird:
      case ReaderIntent.regionLowerThird:
      case ReaderIntent.regionTopLeft:
      case ReaderIntent.regionTopRight:
      case ReaderIntent.regionBottomLeft:
      case ReaderIntent.regionBottomRight:
        break; // Handled by the screen, or only mean something in the library.
    }
    // A part of the page belongs to the view it was picked in.
    if (state.region != null && (state.guided, state.mode) != shownBefore) {
      state = state.copyWith(clearRegion: true, message: state.message);
    }
    // Mode switches (guided, balloons, spread, direction) are part of the
    // spot too. Saves are debounced, so this costs nothing per key.
    if (state.book case final book?) _saveProgress(book);
  }

  /// Shows the comic at [quarters] quarter turns clockwise (any integer).
  void _rotateTo(int quarters) {
    final r = quarters % 4;
    state = state.copyWith(
      rotation: r,
      message: switch (r) {
        0 => 'Upright',
        1 => 'Turned a quarter clockwise',
        2 => 'Upside down',
        _ => 'Turned a quarter counter-clockwise',
      },
    );
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
  /// The app came back to the front: the sitting [flush] started when it
  /// left begins now, so the time away is not logged as reading.
  void resumeSitting() {
    if (_sitting case final s? when s.pages.isEmpty) _sitting = (key: s.key, start: DateTime.now(), pages: s.pages);
  }

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

/// "page 5" or "page 5, panel 2", for notices and lists.
String describePlace(BookmarkInfo b) => 'page ${b.page + 1}${isPanel(b.panel) ? ', panel ${b.panel! + 1}' : ''}';
