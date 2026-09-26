import 'dart:ui' show Color;

import 'package:comic_analysis/comic_analysis.dart';

import '../library/library_store.dart';
import 'guided.dart';
import 'layout.dart';
import 'open_book.dart';
import 'region.dart';

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
  List<Panel> balloonsOn(int p, int stop) =>
      panels[p]?.balloonsIn(stop, rightToLeft: rightToLeft, aspect: wideAspects[p] ?? 1) ?? const [];

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
