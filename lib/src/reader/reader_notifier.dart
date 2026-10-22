import 'dart:async';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import '../data/progress_store.dart';
import '../data/read_log_store.dart';
import '../data/settings_store.dart';
import '../data/sidecar_sync.dart';
import '../library/library_store.dart';
import '../library/providers.dart';
import '../timing.dart';
import 'guided.dart';
import 'layout.dart';
import 'open_book.dart';
import 'panel_detector.dart';
import 'reader_providers.dart';
import 'reader_state.dart';
import 'recent_books.dart';
import 'region.dart';
import 'reset_dialog.dart';

export 'reader_providers.dart';
export 'reader_state.dart';

final readerProvider = NotifierProvider<ReaderNotifier, ReaderState>(ReaderNotifier.new);

class ReaderNotifier extends Notifier<ReaderState> {
  @override
  ReaderState build() {
    ref.onDispose(() => unawaited(_bookmarkWatch?.cancel()));
    listenSelf((prev, next) {
      final same = prev != null && prev.onWholePage && prev.page == next.page && identical(prev.book, next.book);
      if (!next.onWholePage) {
        _wholeSince = null;
      } else if (!same) {
        _wholeSince = clock();
      }
    });
    return const ReaderState();
  }

  /// When the page on screen turned wine red ([ReaderState.onWholePage]):
  /// a step onward within [ReaderState.pauseWindow] of it is held.
  DateTime? _wholeSince;

  /// The time now; tests put their own clock here.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  ProgressStore get _progress => ref.read(progressStoreProvider);
  SidecarSync get _sidecars => ref.read(sidecarSyncProvider);

  /// Zoom and scroll as the reader screen last reported them, saved with the
  /// position; and the saved one for the screen to restore on open.
  ViewSpot? _view;
  ViewSpot? _restoreView;

  /// How long a comic must be open in one go before it counts as started
  /// and goes on the library's Reading tab (snonux, 2026-10-17).
  static const startedAfter = Duration(minutes: 5);

  /// When the open comic was opened, and whether its position is still
  /// saved as a peek ([ReadingPosition.peek]): it was not started before
  /// and has not been open for [startedAfter] yet.
  DateTime _openedAt = DateTime(0);
  bool _peeking = false;
  bool _readingPaused = false;
  Future<void>? _startedTail;
  int _startedRevision = 0;

  /// The sitting under way, for reading history: when the book was opened
  /// (or the app came back) and the pages shown since.
  ({String key, DateTime start, Set<int> pages})? _sitting;
  final _sittingWrites = <Future<void>>{};

  /// Ends the sitting under way and logs it. A flush starts the next sitting
  /// before waiting, so page turns during a slow history write are counted.
  Future<void> _endSitting(ReadLogStore readLog, {bool restart = false}) async {
    final s = _sitting;
    final ended = DateTime.now();
    _sitting = restart && s != null ? (key: s.key, start: ended, pages: <int>{}) : null;
    final pending = _sittingWrites.toList();
    if (s == null) {
      await Future.wait(pending);
      return;
    }
    if (s.pages.isEmpty) {
      await Future.wait(pending);
      return;
    }
    final write = () async {
      try {
        await readLog.record(s.key, s.start, ended, s.pages.length);
      } catch (e) {
        debugPrint('Could not log the sitting: $e');
      }
      await Future.wait(pending);
    }();
    _sittingWrites.add(write);
    try {
      await write;
    } finally {
      _sittingWrites.remove(write);
    }
  }

  /// Counts opens and explicit closes, so an earlier open knows to stop.
  int _opening = 0;
  Future<void>? _closing;

  /// The document opener; tests can hold it at a known point in a race.
  @visibleForTesting
  Future<OpenBook> Function(String) openDocument = openBook;

  /// Called before and after close or exit waits for completion writes.
  @visibleForTesting
  void Function(bool drained)? onCompletionBarrier;

  /// Pages waiting for detection, and whether the worker loop is running.
  final _wanted = <int>{};
  bool _detecting = false;
  int _detectionGeneration = 0;
  final _panelWrites = <Future<void>>{};
  final _unreadWrites = <Future<void>>{};
  final _completedWrites = <Future<void>>{};
  final _markWrites = <Future<void>>{};
  final _metadataWrites = <Future<void>>{};
  final _completionTails = <String, Future<void>>{};
  final _sidecarWrites = <Future<void>>{};
  final _attaches = <Future<SidecarImport?>>{};
  final _openPulls = <Future<bool?>>{};

  /// Finding panels for the open book right now.
  bool get detecting => _detecting;

  /// Opens [path], closing any open book, and resumes where it was left, or
  /// goes to [at] when given (a bookmark picked in the library).
  Future<void> open(String path, {Place? at}) async {
    // A later open (`]` twice, a drop while a book opens) wins: this one then
    // closes what it opened and stops, rather than leaving it open unseen.
    final opening = ++_opening;
    bool superseded() => !ref.mounted || opening != _opening;
    state = state.copyWith(loading: true);
    final clock = Stopwatch()..start(); // COMICREDR_TIMING=1 prints the steps, counted from here.
    OpenBook book;
    try {
      book = await openDocument(path);
    } on OpenBookException catch (e) {
      if (!superseded()) state = state.copyWith(loading: false, message: e.message);
      return;
    } catch (e) {
      if (!superseded()) state = state.copyWith(loading: false, message: 'Could not open $path: $e');
      return;
    }
    if (superseded()) return book.doc.close();
    timing('open: document', clock);
    await _closeCurrent();
    if (superseded()) return book.doc.close();
    timing('open: previous comic closed', clock);
    // Closing the old book reset ReaderState; the replacement is still loading.
    state = state.copyWith(loading: true);
    // A newer sidecar from the other device, when the comic is on S3 and
    // the bucket answers within two seconds.
    final pulling = _orNull(() => ref.read(s3SyncProvider).pullOnOpen(book.key));
    _openPulls.add(pulling);
    try {
      await pulling;
    } finally {
      _openPulls.remove(pulling);
    }
    if (superseded()) return book.doc.close();
    // The sidecar first, so what it brings (panels from the laptop, a
    // position from the phone) is in the index before the reads below.
    final attaching = _orNull(() => _sidecars.attach(book.path, book.key, folder: book.folder));
    _attaches.add(attaching);
    SidecarImport? side;
    try {
      side = await attaching;
    } finally {
      _attaches.remove(attaching);
    }
    if (superseded()) return book.doc.close();
    timing('open: sidecar', clock);
    // Titles edited in the library, some perhaps just now from the sidecar.
    final edits = await _orNull(() => ref.read(libraryStoreProvider).edits(book.key));
    if (superseded()) return book.doc.close();
    if (edits != null) book = book.withEdits(edits);
    // A broken index must not keep a book from opening: each of these falls
    // back to nothing saved.
    final saved = await _orNull(() => _progress.load(book.key));
    if (superseded()) return book.doc.close();
    final started = await _orNull(() => ref.read(libraryStoreProvider).startedMarkOf(book.key));
    if (superseded()) return book.doc.close();
    // A detector that failed to load leaves the cached panels unread; the
    // drain falls back to classic CV and finds them again.
    timing('open: position', clock);
    final detector = await _orNull(() => ref.read(panelDetectorProvider.future));
    if (superseded()) return book.doc.close();
    timing('open: detector', clock);
    final cached = detector == null
        ? const <int, DetectedPage>{}
        : await _orNull(
                () => ref.read(panelStoreProvider).load(book.key, source: detector.source, version: detector.version),
              ) ??
              const <int, DetectedPage>{};
    if (superseded()) return book.doc.close();
    final marks = await _orNull(() => ref.read(markStoreProvider).load(book.key)) ?? const {};
    if (superseded()) return book.doc.close();
    final (:whole, :pause, :seconds, :night, :trim, :cleanUp, :fullscreen) = await _loadSettings(state);
    if (superseded()) return book.doc.close();
    timing('open: panels, marks and settings', clock);
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
      pauseSeconds: seconds,
      cue: state.cue,
      coverAlone: saved?.coverAlone ?? state.coverAlone,
      rightToLeft: saved?.rightToLeft ?? book.meta?.rightToLeft ?? false,
      rotation: (saved?.rotation ?? 0) % 4,
      fullscreen: fullscreen,
      night: night,
      trim: trim,
      cleanUp: cleanUp,
      panels: {
        for (final MapEntry(:key, :value) in cached.entries)
          key: PagePanels(value.frames, value.balloons, value.trim, value.source == PanelSource.manual),
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
    // For `C`: this is now the comic read last.
    unawaited(ref.read(recentBooksProvider.notifier).opened(book));
    // The place is saved from the first moment, but a comic not started
    // before counts as started (the library's Reading tab) only once it has
    // been open for five minutes: until then it is saved as a peek.
    _openedAt = this.clock();
    _peeking = !(started ?? (saved != null && !saved.peek));
    _saveProgress(book);
    _ensurePanels();
    _watchBookmarks(book);
    unawaited(_readWidePages(book));
    final sidecarWrite = _writeSidecar(book);
    _sidecarWrites.add(sidecarWrite);
    unawaited(sidecarWrite.whenComplete(() => _sidecarWrites.remove(sidecarWrite)));
    // It has reached the screen: only now does opening take it out of Unread.
    // Close waits for this write before flushing the sidecar.
    final unread = _leaveUnread(book);
    _unreadWrites.add(unread);
    try {
      await unread;
    } finally {
      _unreadWrites.remove(unread);
    }
  }

  Future<void> _leaveUnread(OpenBook book) async {
    final sidecars = _sidecars;
    final removed = await _orNull(() => ref.read(libraryStoreProvider).leaveUnread(book.key)) ?? false;
    if (removed) sidecars.touch(book.key);
  }

  StreamSubscription<List<BookmarkInfo>>? _bookmarkWatch;

  /// Follows [book]'s bookmarks and marks in the index, so a change from
  /// the list, the library or a sidecar shows at once.
  void _watchBookmarks(OpenBook book) {
    unawaited(_bookmarkWatch?.cancel());
    _bookmarkWatch = ref.read(libraryStoreProvider).watchBookmarks(book.key).listen((all) {
      if (!ref.mounted || !identical(state.book, book)) return;
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
  Future<void> removeBookmark(String id) => _trackMetadataWrite(_removeBookmark(id));

  Future<void> _removeBookmark(String id) async {
    final key = state.book?.key;
    if (key == null) return;
    final sidecars = _sidecars;
    state = state.copyWith(bookmarks: [...state.bookmarks.where((b) => b.id != id)]);
    try {
      await ref.read(libraryStoreProvider).deleteBookmark(id);
      sidecars.touch(key);
    } catch (e) {
      debugPrint('Could not remove the bookmark: $e');
    }
  }

  /// Gives bookmark [id] of the open book a note; empty takes it off.
  Future<void> setBookmarkNote(String id, String note) => _trackMetadataWrite(_setBookmarkNote(id, note));

  Future<void> _setBookmarkNote(String id, String note) async {
    final key = state.book?.key;
    if (key == null) return;
    final sidecars = _sidecars;
    try {
      await ref.read(libraryStoreProvider).setNote(id, note);
      sidecars.touch(key);
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
  Future<void> _toggleBookmark() => _trackMetadataWrite(_toggleBookmarkWrite());

  Future<void> _toggleBookmarkWrite() async {
    final book = state.book!;
    final sidecars = _sidecars;
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
        sidecars.touch(book.key);
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
      sidecars.touch(book.key);
      // Shown at once; the index's own update follows.
      if (ref.mounted && identical(state.book, book) && !state.bookmarks.any((b) => b.id == id)) {
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
  Future<void> _toggleFavourite() => _trackMetadataWrite(_toggleFavouriteWrite());

  Future<void> _toggleFavouriteWrite() async {
    final book = state.book!;
    final store = ref.read(libraryStoreProvider);
    final sidecars = _sidecars;
    try {
      final on = !await store.isFavourite(book.key);
      await store.setFavourite(book.key, on);
      sidecars.touch(book.key);
      if (ref.mounted && identical(state.book, book)) {
        _notice(on ? 'Added to Favourites  ·  gf lists them' : 'Taken out of Favourites');
      }
    } catch (e) {
      if (ref.mounted) _notice('Could not change the favourites: $e');
    }
  }

  /// Changes from keys and the five-minute threshold share one queue, so
  /// a slow automatic write cannot overtake a later manual removal.
  Future<void> _changeStarted(OpenBook book, bool on) {
    final revision = ++_startedRevision;
    final wasPeeking = _peeking;
    _peeking = !on;
    if (!on) _openedAt = clock();
    final store = ref.read(libraryStoreProvider), sidecars = _sidecars;
    final previous = _startedTail;
    final write = () async {
      if (previous != null) await previous;
      try {
        await store.setStarted(book.key, on);
        sidecars.touch(book.key);
      } catch (e) {
        if (ref.mounted && identical(state.book, book) && revision == _startedRevision) {
          _peeking = wasPeeking;
          _saveProgress(book, checkStarted: false);
          await _progress.flush();
          _notice('Could not change the started mark: $e');
        }
      }
    }();
    _startedTail = write;
    return _trackMetadataWrite(write);
  }

  Future<void> _toggleStarted() async {
    final book = state.book!;
    _startedNow(book);
    final on = _peeking;
    final write = _changeStarted(book, on);
    final revision = _startedRevision;
    await write;
    if (ref.mounted && identical(state.book, book) && revision == _startedRevision && _peeking == !on) {
      _notice(on ? 'Marked as started' : 'Marked as not started: place kept');
    }
  }

  /// The last page of the book is on screen (the pair 2-3 of a three-page
  /// book shows it), which is what the saved position calls finished.
  bool get _onLastPage => (state.unit.isEmpty ? state.page : state.unit.last) >= state.pageCount - 1;

  /// `gC`: marks the book completed, or not completed when it counts as
  /// completed (marked so, or unmarked and on its last page). Dated, so the
  /// later of two devices' changes wins when their sidecars meet. The page
  /// on screen stands in for the saved one ([LibraryBook.completed] goes by
  /// the progress row): saves are debounced, so the row may still say the
  /// page before.
  Future<void> _toggleCompleted() {
    final book = state.book!;
    final onLastPage = _onLastPage;
    final store = ref.read(libraryStoreProvider);
    final sidecars = _sidecars;
    return _queueCompleted(book.key, () => _changeCompleted(book, onLastPage, store, sidecars));
  }

  Future<void> _trackMetadataWrite(Future<void> write) {
    _metadataWrites.add(write);
    return write.whenComplete(() => _metadataWrites.remove(write));
  }

  /// Completion changes to one book follow the order of the commands, so a
  /// later gC reads the mark left by an earlier gC or last-page arrival.
  Future<void> _queueCompleted(String key, Future<void> Function() change) {
    final previous = _completionTails[key];
    final write = previous == null ? change() : previous.then((_) => change());
    _completionTails[key] = write;
    _completedWrites.add(write);
    return write.whenComplete(() {
      _completedWrites.remove(write);
      if (identical(_completionTails[key], write)) _completionTails.remove(key);
    });
  }

  Future<void> _changeCompleted(OpenBook book, bool onLastPage, LibraryStore store, SidecarSync sidecars) async {
    try {
      final on = !(await store.completedMarkOf(book.key) ?? onLastPage);
      await store.setCompleted(book.key, on);
      sidecars.touch(book.key);
      if (ref.mounted && identical(state.book, book)) _notice(on ? 'Marked as completed' : 'Marked as not completed');
    } catch (e) {
      if (ref.mounted && identical(state.book, book)) {
        _notice('Could not change the completed mark: $e');
      } else {
        debugPrint('Could not change the completed mark for ${book.path}: $e');
      }
    }
  }

  /// Marks [book] completed because reading on just arrived on its last
  /// page ([handle]), unless it is marked so already, which leaves the row
  /// and its time alone (a rewritten time would win a sidecar merge over
  /// another device's later "not completed"). A comic marked not completed
  /// is marked again: read to the end once more, it is completed once more.
  /// Why a mark at all: without it the comic would stop counting as
  /// completed when it is read again from the start, and another device
  /// would never hear of it (positions are per device, the mark is not).
  /// Says so only when nothing else is on the status line.
  Future<void> _completeAtEnd(OpenBook book) {
    final store = ref.read(libraryStoreProvider);
    final sidecars = _sidecars;
    return _queueCompleted(book.key, () => _markCompletedAtEnd(book, store, sidecars));
  }

  Future<void> _markCompletedAtEnd(OpenBook book, LibraryStore store, SidecarSync sidecars) async {
    try {
      if (await store.completedMarkOf(book.key) == true) return;
      await store.setCompleted(book.key, true);
      sidecars.touch(book.key);
      if (ref.mounted && identical(state.book, book) && state.message == null) {
        _notice('Last page: marked as completed');
      }
    } catch (e) {
      debugPrint('Could not mark ${book.path} as completed: $e');
    }
  }

  /// `gc`: puts the open book in the collection [name] (picked or typed in
  /// the dialog app.dart shows) and marks its sidecar to be written, as `*`
  /// does. A collection it is in already is said so and left alone, row
  /// and sidecar: [LibraryStore.addToCollection] decides that, for the
  /// library's `gc` as for this one.
  Future<void> addToCollection(String name) => _trackMetadataWrite(_addToCollection(name));

  Future<void> _addToCollection(String name) async {
    final book = state.book;
    if (book == null) return;
    final sidecars = _sidecars;
    try {
      final added = await ref.read(libraryStoreProvider).addToCollection(book.key, name);
      if (added) sidecars.touch(book.key);
      if (ref.mounted && identical(state.book, book)) _notice(added ? 'Added to $name' : 'Already in $name');
    } catch (e) {
      if (ref.mounted) _notice('Could not add it to $name: $e');
    }
  }

  /// Writes the sidecar as the book opens, so a folder that refuses it says
  /// so now rather than silently later.
  Future<void> _writeSidecar(OpenBook book) async {
    final sidecars = _sidecars;
    final progress = _progress;
    try {
      await progress.flush();
      final written = await sidecars.write(book.key);
      if (!ref.mounted || written || !identical(state.book, book)) return;
      _notice("Can't write beside this comic, so its panels and bookmarks stay in this app only");
    } catch (e) {
      debugPrint('Sidecar write failed: $e');
    }
  }

  /// Takes the offered position from another device: saves it as this
  /// device's and reopens the book there, view and all.
  Future<void> acceptOffer(PositionOffer offer) async {
    ref.read(positionOfferProvider.notifier).set(null);
    final closing = close();
    final reserved = _opening;
    await closing;
    if (!ref.mounted || _opening != reserved) return;
    await _sidecars.adopt(offer.contentKey, offer.at);
    if (!ref.mounted || _opening != reserved) return;
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
    // Even with no book on screen, an open may still be loading one.
    _opening++;
    state = state.copyWith(loading: false);
    final attaching = _attaches.toList();
    final pulling = _openPulls.toList();
    await _closeCurrent();
    // An attachment can still be importing rows even when no book has
    // reached the screen. Reset and Delete must not overtake that import.
    await Future.wait(attaching);
    await Future.wait(pulling);
  }

  Future<void> _closeCurrent() async {
    if (_closing case final pending?) return pending;
    final book = state.book;
    if (book == null) return;
    final closing = _closeBook(book);
    _closing = closing;
    try {
      await closing;
    } finally {
      if (identical(_closing, closing)) _closing = null;
    }
  }

  Future<void> _closeBook(OpenBook book) async {
    // A model inference cannot be cancelled. Its answer must not reach the
    // index after this book closes, especially when Reset follows.
    _detectionGeneration++;
    final sidecars = _sidecars;
    final readLog = ref.read(readLogStoreProvider);
    unawaited(_bookmarkWatch?.cancel());
    _bookmarkWatch = null;
    _startedNow(book);
    await _progress.flush();
    await _endSitting(readLog);
    _wanted.clear();
    _wake?.complete();
    _wake = null;
    _view = _restoreView = null;
    if (ref.mounted) {
      state = ReaderState(
        mode: state.mode,
        guided: state.guided,
        balloons: state.balloons,
        wholePageSteps: state.wholePageSteps,
        pauseWhole: state.pauseWhole,
        pauseSeconds: state.pauseSeconds,
        cue: state.cue,
        fullscreen: state.fullscreen,
        night: state.night,
        trim: state.trim,
        cleanUp: state.cleanUp,
        loading: state.loading,
      );
    }
    await book.doc.close();
    // A save that began before close must finish before Reset deletes its
    // rows. Inference itself is allowed to finish later and is discarded.
    await Future.wait(_panelWrites.toList());
    // The book was already displayed, so its Unread removal belongs in the
    // sidecar even when Back was pressed before that index write completed.
    await Future.wait(_unreadWrites.toList());
    // A completion started before close may still be reading the old mark.
    // Its write must reach the index before the final sidecar flush.
    onCompletionBarrier?.call(false);
    await Future.wait(_completedWrites.toList());
    onCompletionBarrier?.call(true);
    await Future.wait(_markWrites.toList());
    await Future.wait(_metadataWrites.toList());
    await Future.wait(_sidecarWrites.toList());
    // Wait for the sidecar too: Reset must not overtake a close-time write.
    try {
      await sidecars.flush();
      if (ref.mounted) {
        unawaited(ref.read(s3SyncProvider).flush().catchError((Object e) => debugPrint('S3 flush failed: $e')));
      }
    } catch (e) {
      debugPrint('Sidecar write failed: $e');
    }
  }

  /// Resets the open book (see [SidecarSync.reset]) and opens it again:
  /// where it was, finding its panels anew, after [ResetScope.panels]; on
  /// the first page, as if never opened, after [ResetScope.everything].
  Future<void> reset(ResetScope scope) async {
    final book = state.book;
    if (book == null) return;
    final closing = close();
    final reserved = _opening;
    await closing;
    if (!ref.mounted || _opening != reserved) return;
    var ok = true;
    try {
      ok = await _sidecars.reset(book.key, everything: scope == ResetScope.everything);
    } catch (e) {
      debugPrint('Reset failed: $e');
      if (ref.mounted && _opening == reserved) state = state.copyWith(message: 'Could not reset ${book.title}: $e');
      return;
    }
    if (!ref.mounted || _opening != reserved) return;
    await open(book.path);
    if (!ref.mounted || _opening != reserved + 1 || state.book?.key != book.key) return;
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
    if (aspects.isNotEmpty && ref.mounted && identical(state.book, book)) {
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
      clearParts: true,
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

  void _saveProgress(OpenBook book, {bool checkStarted = true}) {
    if (_sitting case final s? when s.key == book.key) s.pages.addAll(state.unit);
    if (checkStarted && !_readingPaused && _peeking && clock().difference(_openedAt) >= startedAfter) {
      unawaited(_changeStarted(book, true));
    }
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
        peek: _peeking,
      ),
      state.pageCount,
      // The pair 2-3 of a three-page book shows its last page: finished.
      lastShown: state.unit.isEmpty ? null : state.unit.last,
    );
    _sidecars.touch(book.key);
  }

  /// Saves the position once more when the open comic, saved as a peek so
  /// far, has now been open for [startedAfter] without a page turn: on
  /// close and pause, so five minutes count even on one page.
  void _startedNow(OpenBook book) {
    if (_peeking && identical(state.book, book) && clock().difference(_openedAt) >= startedAfter) {
      _saveProgress(book);
    }
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
  /// the first in reading order), and steps go on through [split] page by
  /// page ([ReaderState.parts]). The same keys again go back to the whole
  /// page and the usual steps.
  void _showRegion(PageSplit split, int part) {
    final r = state.region;
    if (r != null && r.split == split && r.part == part) {
      state = state.copyWith(clearParts: true, message: 'Whole page');
      return;
    }
    final unit = state.unit;
    if (unit.isEmpty) return;
    final region = (split: split, part: part, page: r != null && unit.contains(r.page) ? r.page : unit.first);
    state = state.copyWith(
      region: region,
      parts: split,
      held: false,
      message:
          '${_capitalised(describeRegion(region, rightToLeft: state.rightToLeft))}'
          '  ·  → and ← step through the ${split.name} page by page, Esc or 00 shows the whole page',
    );
  }

  /// `11`: the page whole. Keeps stepping through the current split when
  /// there is one (`parts`); Esc / `00` leave the split entirely.
  void _regionWhole() {
    if (state.region == null && state.parts == null) {
      _notice('Already the whole page');
      return;
    }
    if (state.region == null) {
      state = state.copyWith(message: 'Whole page, in ${state.parts!.name}');
      return;
    }
    state = state.copyWith(
      clearRegion: true,
      message: state.parts == null ? 'Whole page' : 'Whole page, in ${state.parts!.name}',
    );
  }

  /// `00`: leave parts of the page and go back to guided view or plain paging.
  void _regionPrevious() {
    if (state.parts == null && state.region == null) {
      _notice('Not in a part of the page');
      return;
    }
    state = state.copyWith(clearParts: true, message: 'Whole page');
  }

  static String _capitalised(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// A step while the reader goes through a page in parts
  /// ([ReaderState.parts]). Each page shows whole first, then its parts in
  /// reading order (onto the other page of a spread), then whole again
  /// before the next page (or spread) shows whole. Going back mirrors it:
  /// from the first part the page shows whole, then the previous page
  /// whole, then its last part. In guided view a page
  /// with panels leaves the parts and guided view goes on over its panels.
  void _stepParts(int steps) {
    for (var k = 0; k < steps.abs(); k++) {
      final split = state.parts;
      if (split == null) {
        (state.guided ? _stepGuided : _step)(steps.sign * (steps.abs() - k));
        return;
      }
      final forward = steps > 0;
      final order = partOrder(split, rightToLeft: state.rightToLeft);
      final unit = state.unit;
      final r = state.region;
      if (r == null) {
        // The whole page. Arrived going on, it is on its near side: on into
        // its parts, back to the page before. Arrived going back, or shown
        // whole after its last part, the other way round.
        final nearSide = state.panel < lastPanel;
        if (forward == nearSide) {
          // Its panels may have come since it turned: guided view goes on.
          if (state.guided && state.stopsOn(state.page).isNotEmpty) {
            state = state.copyWith(clearParts: true);
            _stepGuided(steps.sign * (steps.abs() - k));
            return;
          }
          state = state.copyWith(
            region: (split: split, part: forward ? order.first : order.last, page: forward ? unit.first : unit.last),
          );
        } else if (!_turnInParts(split, forward: forward)) {
          return;
        }
        continue;
      }
      var at = unit.indexOf(r.page);
      if (at < 0) at = 0;
      var i = order.indexOf(r.part);
      if (forward ? i < order.length - 1 : i > 0) {
        i += forward ? 1 : -1;
      } else if (forward ? at < unit.length - 1 : at > 0) {
        at += forward ? 1 : -1;
        i = forward ? 0 : order.length - 1;
      } else {
        // Past the last part (or before the first): the page (or spread)
        // whole on that side, so the next step turns.
        state = state.copyWith(clearRegion: true, panel: forward ? pageEnd : pageStart, balloon: -1);
        continue;
      }
      state = state.copyWith(region: (split: split, part: order[i], page: unit[at]));
    }
    final region = state.region;
    state = state.copyWith(
      message: region == null
          ? state.parts == null
                ? 'Panels on this page: guided view goes on'
                : 'Whole page, in ${state.parts!.name}'
          : '${_capitalised(describeRegion(region, rightToLeft: state.rightToLeft))}'
                '${state.unit.length > 1 ? ', page ${region.page + 1}' : ''}',
    );
  }

  /// Turns to the next or previous page (or spread) keeping [split], shown
  /// whole on the side it was arrived at. In guided view, a page with
  /// panels leaves the parts. False at either end of the comic.
  bool _turnInParts(PageSplit split, {required bool forward}) {
    final page = state.guided
        ? state.page + (forward ? 1 : -1)
        : stepFrom(
            state.page,
            forward ? 1 : -1,
            state.pageCount,
            state.mode,
            coverAlone: state.coverAlone,
            wide: state.wide,
          );
    if (page < 0 || page >= state.pageCount || state.unit.contains(page)) {
      _notice(forward ? 'This is the last part of the last page' : 'This is the first part of the first page');
      return false;
    }
    _goTo(page, panel: forward ? pageStart : pageEnd, balloon: -1);
    if (!state.guided || state.stopsOn(state.page).isEmpty) state = state.copyWith(parts: split);
    return true;
  }

  /// Pauses of the step that would leave a page shown whole
  /// ([ReaderState.onWholePage], wine red since it appeared) when it comes
  /// within [ReaderState.pauseWindow] of that: the step stays on the page, moved to its
  /// far side ([pageEnd] going forward, [pageStart] going back), and plays
  /// the zoom cue; the step after it turns. It stays held,
  /// [ReaderState.held], until left. A step after the window turns at once.
  /// A page arrived on from the other side, or jumped to, starts on the
  /// near side. After one pause the page is left by the next step either
  /// way. Pages whose panels are not known yet are not held, nor is a count
  /// (`3l`); their window starts when detection finds no panels.
  bool _pauseOnWhole({required bool forward}) {
    final since = _wholeSince;
    if (!state.onWholePage || state.held || since == null || clock().difference(since) >= state.pauseWindow) {
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
    state = state.copyWith(guided: on, mode: mode, clearParts: true);
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
    if (!ref.mounted) return;
    if (on != null && on != state.fullscreen) state = state.copyWith(fullscreen: on);
  }

  /// Takes up every saved setting the reader keeps, after an import changed
  /// them: one that is not saved goes back to its default. The open book
  /// stays where it is.
  Future<void> reloadSettings() async {
    final (:whole, :pause, :seconds, :night, :trim, :cleanUp, :fullscreen) = await _loadSettings(const ReaderState());
    if (!ref.mounted) return;
    state = state.copyWith(
      wholePageSteps: whole,
      pauseWhole: pause,
      pauseSeconds: seconds,
      night: night,
      trim: trim,
      cleanUp: cleanUp,
      fullscreen: fullscreen,
      message: state.message,
    );
  }

  /// The saved settings a comic is read with, [defaults]' where one is not
  /// saved or cannot be read. Asked for all at once: one after another,
  /// they took some 50 ms of opening a comic.
  Future<({bool whole, bool pause, double seconds, bool night, bool trim, bool cleanUp, bool fullscreen})>
  _loadSettings(ReaderState defaults) async {
    final settings = ref.read(settingsStoreProvider);
    Future<bool> flag(String key, bool fallback) async => await _orNull(() => settings.loadBool(key)) ?? fallback;
    final (whole, pause, seconds, night, trim, cleanUp, fullscreen) = await (
      flag(SettingsStore.wholePageSteps, defaults.wholePageSteps),
      flag(SettingsStore.pauseWhole, defaults.pauseWhole),
      _orNull<String?>(() => settings.loadString(SettingsStore.pauseSeconds)),
      flag(SettingsStore.night, defaults.night),
      flag(SettingsStore.autoTrim, defaults.trim),
      flag(SettingsStore.cleanUp, defaults.cleanUp),
      flag(SettingsStore.fullscreen, defaults.fullscreen),
    ).wait;
    return (
      whole: whole,
      pause: pause,
      seconds: SettingsStore.parseSeconds(seconds) ?? defaults.pauseSeconds,
      night: night,
      trim: trim,
      cleanUp: cleanUp,
      fullscreen: fullscreen,
    );
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
    final generation = _detectionGeneration;
    var last = Duration.zero;
    try {
      while (_wanted.isNotEmpty && ref.mounted && identical(state.book, book) && generation == _detectionGeneration) {
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
          timing('detect: page ${page + 1}', sw);
          if (!ref.mounted || !identical(state.book, book) || generation != _detectionGeneration) return;
          found = PagePanels(result.frames, result.balloons, result.trim);
          final write = _savePanels(book.key, page, result);
          _panelWrites.add(write);
          unawaited(write.whenComplete(() => _panelWrites.remove(write)));
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

  Future<void> _savePanels(String key, int page, DetectedPage result) async {
    final sidecars = _sidecars;
    try {
      await ref.read(panelStoreProvider).save(key, page, result);
      // Close waits for this save before flushing the sidecar. A save that
      // started before close still belongs in the sidecar unless Reset follows.
      sidecars.touch(key);
    } catch (e) {
      debugPrint('Could not cache panels: $e');
    }
  }

  /// `c`: scan clean-up on or off, said in the status line and kept.
  void _toggleCleanUp() {
    final on = !state.cleanUp;
    state = state.copyWith(
      cleanUp: on,
      message: on
          ? 'Clean-up on: paper whitened, ink darkened, small pages sharpened'
          : 'Clean-up off: pages as scanned',
    );
    _saveSetting(SettingsStore.cleanUp, on);
  }

  /// Page-level intents. The reader screen handles zoom and pan itself and
  /// passes everything else here.
  ///
  /// A step onward that brings the last page on screen marks the comic
  /// completed ([_completeAtEnd]): reading arrived there. Only such a step
  /// does (a key, a tap, a swipe; in guided view or page parts the step
  /// that turns onto the last page; in two-page mode the one onto the last
  /// pair), also with a count: `3l` is that step three times over and
  /// marks when it lands there. A jump does not (`G`, `G12`, the page grid,
  /// the progress bar, a bookmark, a mark, another device's position taken
  /// up), nor does opening the comic there: a look at the end is no
  /// reading to it. Nor does a change of mode that brings the last page on
  /// screen (two pages, switched on at the page before it): no step onward
  /// was taken. A one-page comic is on its last page from the start, so no
  /// step ever arrives there.
  Future<void> handle(ReaderCommand c) async {
    final book = state.book;
    final arrives = book != null && _readsOn(c) && !_onLastPage;
    await _dispatch(c);
    if (!ref.mounted) return;
    if (arrives && identical(state.book, book) && _onLastPage) unawaited(_completeAtEnd(book));
  }

  /// Whether [c] is a step onward through the comic: the next step or page,
  /// which right to left is the key (or tap) pointing the other way. The
  /// page keys are not mirrored ([_dispatch]), so `nextPage` always is one.
  bool _readsOn(ReaderCommand c) => switch (c.intent) {
    ReaderIntent.nextStep || ReaderIntent.scrollRight => !state.rightToLeft,
    ReaderIntent.prevStep || ReaderIntent.scrollLeft => state.rightToLeft,
    ReaderIntent.nextPage => true,
    _ => false,
  };

  /// Does what [intent] asks when it is about a part of the page (a part's
  /// own key, the page whole within the split, the part shown before) and
  /// says whether it was. [_dispatch] then only saves the place: these do
  /// not change the view a part belongs to, so it has nothing to clear.
  bool _pagePart(ReaderIntent intent) {
    if (regionFor(intent) case final r?) {
      _showRegion(r.split, r.part);
    } else if (intent == ReaderIntent.regionWhole) {
      _regionWhole();
    } else if (intent == ReaderIntent.regionPrevious) {
      _regionPrevious();
    } else {
      return false;
    }
    return true;
  }

  /// What [handle] does with [c], last-page mark aside.
  Future<void> _dispatch(ReaderCommand c) async {
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
    final step = state.parts != null ? _stepParts : (state.guided ? _stepGuided : _step);
    final pageStep = state.guided ? (int n) => _goTo(state.page + n) : _step;
    final shownBefore = (state.guided, state.mode);
    if (_pagePart(c.intent)) {
      _saveProgress(state.book!);
      return;
    }
    switch (c.intent) {
      // Left and Right reach here when the view had no zoomed page to pan.
      case ReaderIntent.nextStep:
      case ReaderIntent.scrollRight:
        step(mirror * c.times);
      case ReaderIntent.prevStep:
      case ReaderIntent.scrollLeft:
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
          message: on ? 'Pages shown whole turn wine red and hold a quick step' : 'Pages shown whole turn at once',
        );
        _saveSetting(SettingsStore.pauseWhole, on);
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
        final sidecars = _sidecars;
        final write = ref
            .read(markStoreProvider)
            .save(key, c.register!, place.page, place.panel)
            .then((_) => sidecars.touch(key))
            .catchError((Object e) => debugPrint('Could not save mark: $e'));
        _markWrites.add(write);
        unawaited(write.whenComplete(() => _markWrites.remove(write)));
      case ReaderIntent.jumpMark:
        final target = state.marks[c.register];
        target == null ? _notice('Mark ${c.register} is not set') : _goTo(target.page, panel: target.panel, jump: true);
      case ReaderIntent.jumpBack:
        final back = state.jumpedFrom;
        back == null ? _notice('No jump to go back from') : _goTo(back.page, panel: back.panel, jump: true);
      case ReaderIntent.back:
        // Esc goes back to the whole page from a part of it, and out of
        // stepping through parts, then leaves guided view before it means
        // anything else. Fullscreen stays: the library is fullscreen too,
        // and Esc at its top leaves it.
        if (state.parts != null || state.region != null) {
          state = state.copyWith(clearParts: true, message: 'Whole page');
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
      case ReaderIntent.toggleCompleted:
        await _toggleCompleted();
      case ReaderIntent.toggleStarted:
        await _toggleStarted();
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
        _toggleCleanUp();
      case ReaderIntent.panDown:
      case ReaderIntent.panUp:
      case ReaderIntent.scrollFaster:
      case ReaderIntent.scrollSlower:
      case ReaderIntent.scrollSmoother:
      case ReaderIntent.scrollCrisper:
      case ReaderIntent.fitWidth:
      case ReaderIntent.toggleFitWidth:
      case ReaderIntent.fitHeight:
      case ReaderIntent.fitPage:
      case ReaderIntent.zoomIn:
      case ReaderIntent.zoomOut:
      case ReaderIntent.zoomReset:
      case ReaderIntent.zoomToggle:
      case ReaderIntent.showTouchZones:
      case ReaderIntent.showTouchGuide:
      case ReaderIntent.openMenu:
      case ReaderIntent.showTime:
      case ReaderIntent.openFile:
      case ReaderIntent.openFolder:
      case ReaderIntent.continueReading:
      case ReaderIntent.showKeymap:
      case ReaderIntent.addRoot:
      case ReaderIntent.rescan:
      case ReaderIntent.toggleShuffle:
      case ReaderIntent.reshuffle:
      case ReaderIntent.filterFolders:
      case ReaderIntent.filterCompleted:
      case ReaderIntent.sortFolders:
      case ReaderIntent.nextSortOrder:
      case ReaderIntent.reverseSort:
      case ReaderIntent.clearReading:
      case ReaderIntent.resetBook:
      case ReaderIntent.deleteBook:
      case ReaderIntent.uploadToS3:
      case ReaderIntent.removeFromS3:
      // The library's own, with nothing to do on an open comic (undo and
      // showSettings never get here: HomeScreen takes them on every screen).
      case ReaderIntent.downloadFromS3:
      case ReaderIntent.removeRoot:
      case ReaderIntent.showScanFailures:
      case ReaderIntent.showSettings:
      case ReaderIntent.undo:
      case ReaderIntent.moveBooks:
      case ReaderIntent.addToCollection:
      case ReaderIntent.markBook:
      case ReaderIntent.markLeft:
      case ReaderIntent.markRight:
      case ReaderIntent.markUp:
      case ReaderIntent.markDown:
      case ReaderIntent.markToFirst:
      case ReaderIntent.markToLast:
      case ReaderIntent.markAll:
      case ReaderIntent.editBook:
      case ReaderIntent.activate:
      case ReaderIntent.up:
      case ReaderIntent.pageGrid:
      case ReaderIntent.showDetails:
      case ReaderIntent.bookmarkList:
      case ReaderIntent.remove:
      case ReaderIntent.showFavourites:
      case ReaderIntent.regionWhole:
      case ReaderIntent.regionPrevious:
      case ReaderIntent.regionUpperHalf:
      case ReaderIntent.regionLowerHalf:
      case ReaderIntent.regionUpperThird:
      case ReaderIntent.regionMiddleThird:
      case ReaderIntent.regionLowerThird:
      case ReaderIntent.regionStrip1:
      case ReaderIntent.regionStrip2:
      case ReaderIntent.regionStrip3:
      case ReaderIntent.regionStrip4:
      case ReaderIntent.regionTopLeft:
      case ReaderIntent.regionTopRight:
      case ReaderIntent.regionBottomLeft:
      case ReaderIntent.regionBottomRight:
      case ReaderIntent.pickPart:
        break; // Handled by the screen, or only mean something in the library.
    }
    // A part of the page belongs to the view it was picked in.
    if (!ref.mounted) return;
    if ((state.parts != null || state.region != null) && (state.guided, state.mode) != shownBefore) {
      state = state.copyWith(clearParts: true, message: state.message);
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
    final opening = _opening;
    bool superseded() => !ref.mounted || opening != _opening || !identical(state.book, book);
    final inSeries = await _orNull(() => ref.read(libraryStoreProvider).seriesNeighbour(book.key, next: next));
    if (superseded()) return;
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
    if (superseded()) return;
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
    _readingPaused = false;
    if (_peeking) _openedAt = clock();
    if (_sitting case final s? when s.pages.isEmpty) _sitting = (key: s.key, start: DateTime.now(), pages: s.pages);
  }

  /// Backgrounding ends this attempt at a five-minute sitting. Later
  /// asynchronous saves and closing while hidden must not count time away.
  Future<void> pauseSitting() {
    if (state.book case final book?) _startedNow(book);
    _readingPaused = true;
    return flush();
  }

  Future<void> flush() async {
    final sidecars = _sidecars;
    final readLog = ref.read(readLogStoreProvider);
    final opening = _opening;
    if (state.book case final book?) _startedNow(book);
    await _progress.flush();
    // The app may not come back: log the sitting, and start a new one that
    // a quick return joins back onto. It must be live while the write waits.
    if (_opening == opening) {
      await _endSitting(readLog, restart: ref.mounted && state.book != null);
    } else {
      await Future.wait(_sittingWrites.toList());
    }
    await Future.wait(_panelWrites.toList());
    await Future.wait(_unreadWrites.toList());
    onCompletionBarrier?.call(false);
    await Future.wait(_completedWrites.toList());
    onCompletionBarrier?.call(true);
    await Future.wait(_markWrites.toList());
    await Future.wait(_metadataWrites.toList());
    await Future.wait(_sidecarWrites.toList());
    await sidecars.flush();
    if (ref.mounted) await ref.read(s3SyncProvider).flush(limit: const Duration(seconds: 3));
  }
}

/// "page 5" or "page 5, panel 2", for notices and lists.
String describePlace(BookmarkInfo b) => 'page ${b.page + 1}${isPanel(b.panel) ? ', panel ${b.panel! + 1}' : ''}';
