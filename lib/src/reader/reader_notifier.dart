import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import '../data/progress_store.dart';
import '../providers.dart';
import 'layout.dart';
import 'open_book.dart';

/// Everything about the open book that page navigation changes. Zoom and pan
/// are view concerns and live in the reader screen instead.
class ReaderState {
  const ReaderState({
    this.book,
    this.page = 0,
    this.mode = PageMode.single,
    this.coverAlone = true,
    this.rightToLeft = false,
    this.fullscreen = false,
    this.night = false,
    this.marks = const {},
    this.jumpedFrom,
    this.loading = false,
    this.message,
  });

  final OpenBook? book;
  final int page;
  final PageMode mode;
  final bool coverAlone;
  final bool rightToLeft;
  final bool fullscreen;
  final bool night;

  /// vi-style marks a–z for this book, page numbers. Persisted with the
  /// bookmarks work in M8; for now they last while the book is open.
  final Map<String, int> marks;

  /// Where `''` goes back to: the page before the last jump.
  final int? jumpedFrom;
  final bool loading;

  /// A short notice for the status line: an error, or why a key did nothing.
  final String? message;

  int get pageCount => book?.doc.pageCount ?? 0;

  List<int> get unit => book == null ? const [] : unitAt(page, pageCount, mode, coverAlone: coverAlone);

  ReaderState copyWith({
    OpenBook? book,
    int? page,
    PageMode? mode,
    bool? coverAlone,
    bool? rightToLeft,
    bool? fullscreen,
    bool? night,
    Map<String, int>? marks,
    int? jumpedFrom,
    bool? loading,
    String? message,
  }) => ReaderState(
    book: book ?? this.book,
    page: page ?? this.page,
    mode: mode ?? this.mode,
    coverAlone: coverAlone ?? this.coverAlone,
    rightToLeft: rightToLeft ?? this.rightToLeft,
    fullscreen: fullscreen ?? this.fullscreen,
    night: night ?? this.night,
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

class ReaderNotifier extends Notifier<ReaderState> {
  @override
  ReaderState build() => const ReaderState();

  ProgressStore get _progress => ref.read(progressStoreProvider);

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
    int? saved;
    try {
      saved = await _progress.load(book.key);
    } catch (e) {
      // A broken index must not keep a book from opening; start at the top.
      saved = null;
    }
    final page = (saved ?? 0).clamp(0, book.doc.pageCount - 1);
    state = ReaderState(
      book: book,
      page: page,
      mode: state.mode,
      coverAlone: state.coverAlone,
      rightToLeft: book.meta?.rightToLeft ?? false,
      fullscreen: state.fullscreen,
      night: state.night,
      message: saved != null && saved > 0 ? 'Resumed at page ${page + 1}' : null,
    );
  }

  Future<void> close() async {
    final book = state.book;
    if (book == null) return;
    await _progress.flush();
    state = ReaderState(mode: state.mode, fullscreen: state.fullscreen, night: state.night);
    await book.doc.close();
  }

  void _goTo(int page, {bool jump = false}) {
    final book = state.book!;
    final target = page.clamp(0, state.pageCount - 1);
    state = state.copyWith(page: target, jumpedFrom: jump ? state.page : null);
    _progress.save(book.key, target, state.pageCount);
  }

  void _step(int steps) =>
      _goTo(stepFrom(state.page, steps, state.pageCount, state.mode, coverAlone: state.coverAlone));

  void _notice(String message) => state = state.copyWith(message: message);

  /// Shows [message] on the status line until the next change.
  void notice(String message) => _notice(message);

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
    switch (c.intent) {
      case ReaderIntent.nextStep:
        _step(mirror * c.times);
      case ReaderIntent.prevStep:
        _step(-mirror * c.times);
      case ReaderIntent.nextPage:
        _step(c.times);
      case ReaderIntent.prevPage:
        _step(-c.times);
      case ReaderIntent.firstPage:
        _goTo(0, jump: true);
      case ReaderIntent.lastPage:
        _goTo(c.count != null ? c.count! - 1 : state.pageCount - 1, jump: true);
      case ReaderIntent.nextBook:
      case ReaderIntent.prevBook:
        final next = await siblingBook(state.book!.path, next: c.intent == ReaderIntent.nextBook);
        if (next == null) {
          _notice(
            c.intent == ReaderIntent.nextBook
                ? 'No next book in this folder'
                : 'No previous book in this folder',
          );
        } else {
          await open(next);
        }
      case ReaderIntent.toggleSpread:
        state = state.copyWith(mode: state.mode == PageMode.single ? PageMode.spread : PageMode.single);
      case ReaderIntent.cycleModeForward:
      case ReaderIntent.cycleModeBack:
        state = state.copyWith(mode: state.mode == PageMode.single ? PageMode.spread : PageMode.single);
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
        state = state.copyWith(
          marks: {...state.marks, c.register!: state.page},
          message: 'Mark ${c.register} set at page ${state.page + 1}',
        );
      case ReaderIntent.jumpMark:
        final target = state.marks[c.register];
        target == null ? _notice('Mark ${c.register} is not set') : _goTo(target, jump: true);
      case ReaderIntent.jumpBack:
        final back = state.jumpedFrom;
        back == null ? _notice('No jump to go back from') : _goTo(back, jump: true);
      case ReaderIntent.back:
        await close();
      case ReaderIntent.toggleGuided:
        _notice('Guided view arrives in M4');
      case ReaderIntent.toggleContinuous:
      case ReaderIntent.halfPageDown:
      case ReaderIntent.halfPageUp:
        _notice('Continuous scroll arrives in a later milestone');
      case ReaderIntent.bookmark:
        _notice('Saved bookmarks arrive with sidecars in M8; ma sets a mark meanwhile');
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
