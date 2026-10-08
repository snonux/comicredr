import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// The notices along the bottom (SnackBars). One rule for all of them, kept
// in [_post]. A notice is either routine (something done, a hint, an Undo
// offer) or one that must be read (`mustRead`: a failure, or a warning
// about what was done).
//
//  - A routine notice is replaced at once by whatever comes next, so
//    routine notices never queue. (Before task 263 a notice shown while an
//    Undo notice was up waited behind it unseen.)
//  - A notice that must be read takes the place of a routine one at once
//    and then stays its whole time: a notice that comes meanwhile waits
//    its turn behind it. Else "Downloaded B" took away "Could not download
//    A" a moment after it came up.
//  - Among the waiting ones the same holds: those that must be read all
//    show, in the order they came, and a routine one waiting gives way to
//    whatever comes after it.
//
// Every notice of the app is shown through [showNotice] or
// [UndoNotice.show]; test/hotkeys_test.dart fails on a `showSnackBar`
// anywhere else in lib/.

/// How long a notice without a button shows unless its caller says.
const noticeTime = Duration(seconds: 4);

/// How long a notice with an Undo shows before it goes by itself, and the
/// `undo` key with it. Longer than a plain notice: it has to be read and
/// then answered.
const undoNoticeTime = Duration(seconds: 10);

/// A notice on its way to the screen.
class _Notice {
  _Notice(this.bar, {required this.mustRead, this.onShown});

  final SnackBar bar;

  /// Not to be cut short by a later notice.
  final bool mustRead;

  /// Called when the notice comes up, with the future that completes when
  /// it has gone. Never called for a notice that gave way while waiting.
  final void Function(Future<SnackBarClosedReason> closed)? onShown;
}

/// What one messenger's notices are at: the must-read notice on screen,
/// if any, and the ones waiting behind it.
class _Line {
  _Notice? holding;
  final waiting = <_Notice>[];
}

/// Per messenger, so the rule needs no object of its own handed around
/// (and a test's fresh app starts with a fresh line).
final _lines = Expando<_Line>();

/// Shows [notice] on [messenger] by the rule at the top of this file.
void _post(ScaffoldMessengerState messenger, _Notice notice) {
  final line = _lines[messenger] ??= _Line();
  if (line.holding == null) {
    _put(messenger, line, notice);
    return;
  }
  // Behind the one that must be read. A routine notice is only ever the
  // last of the waiting ones, and gives way to this one.
  line.waiting
    ..removeWhere((w) => !w.mustRead)
    ..add(notice);
}

/// Puts [notice] on screen in place of whatever is there, without the
/// slide out of the old one: the new one is then the one on screen, not
/// one queued by the messenger behind a notice on its way out. When it
/// must be read, the next waiting notice follows once it has gone.
void _put(ScaffoldMessengerState messenger, _Line line, _Notice notice) {
  messenger
    ..clearSnackBars()
    ..removeCurrentSnackBar();
  final closed = messenger.showSnackBar(notice.bar).closed;
  notice.onShown?.call(closed);
  if (!notice.mustRead) return;
  line.holding = notice;
  unawaited(
    closed.then((_) {
      if (!identical(line.holding, notice)) return;
      line.holding = null;
      if (messenger.mounted && line.waiting.isNotEmpty) _put(messenger, line, line.waiting.removeAt(0));
    }),
  );
}

/// Shows [text] along the bottom. A routine notice (the default) takes
/// the place of a routine or Undo notice that is up (its undo is then no
/// longer offered, by button or key) and is itself replaced by the next
/// notice. With [mustRead], for a failure or a warning, it stays its
/// [duration] whatever comes after it, which waits. Either kind waits
/// while a notice that must be read is up. Nothing when [messenger] has
/// gone.
void showNotice(
  ScaffoldMessengerState messenger,
  String text, {
  Duration duration = noticeTime,
  bool mustRead = false,
}) {
  if (!messenger.mounted) return;
  _post(
    messenger,
    _Notice(
      SnackBar(content: Text(text), duration: duration),
      mustRead: mustRead,
    ),
  );
}

/// The notice along the bottom that offers an Undo, and what its button
/// does, kept so that the `undo` key (`u`) can press it: a SnackBar's
/// action is not in reach of the keyboard otherwise (task 263). One at a
/// time: a new notice of any kind replaces it (unless it was shown with
/// `mustRead`), it goes by itself after [undoNoticeTime], and once it has
/// gone there is nothing left to undo. One that arrives while a notice
/// that must be read is up waits behind it like any other, and until it
/// shows the key has nothing to press. So the key only ever acts on the
/// notice that is on screen. The key is HomeScreen's, so it works on
/// whatever screen the notice shows over.
class UndoNotice {
  Future<void> Function()? _undo;
  ScaffoldMessengerState? _messenger;

  /// Shows [text] on [messenger] with a button labelled [label] that runs
  /// [undo]; the key runs it too for as long as the notice shows. What
  /// [undo] throws is caught and told in a notice of its own ([failed],
  /// else a general sentence): nobody awaits a button or a key.
  /// [mustRead] when [text] also tells of something that did not work
  /// (see [showNotice]).
  void show(
    ScaffoldMessengerState messenger,
    String text, {
    required String label,
    required Future<void> Function() undo,
    String failed = 'Could not undo that',
    bool mustRead = false,
  }) {
    if (!messenger.mounted) return;
    Future<void> guarded() => _guarded(messenger, undo, failed);
    final bar = SnackBar(
      content: Text(text),
      // A SnackBar with an action stays until it is hidden unless told
      // otherwise.
      persist: false,
      duration: undoNoticeTime,
      action: SnackBarAction(label: label, onPressed: () => unawaited(_run(guarded))),
    );
    // The key gets its undo only once the notice is on screen, which may
    // be later (behind a notice that must be read) or never (replaced
    // while it waited).
    void onShown(Future<SnackBarClosedReason> closed) {
      _undo = guarded;
      _messenger = messenger;
      // Gone, however (time, a swipe, its button, another notice): the
      // key has nothing to press any more.
      unawaited(
        closed.then((_) {
          if (identical(_undo, guarded)) _undo = _messenger = null;
        }),
      );
    }

    _post(messenger, _Notice(bar, mustRead: mustRead, onShown: onShown));
  }

  /// [undo], with a failure said on [messenger] in place of an unhandled
  /// error.
  Future<void> _guarded(ScaffoldMessengerState messenger, Future<void> Function() undo, String failed) async {
    try {
      await undo();
    } catch (e) {
      debugPrint('$failed: $e');
      showNotice(messenger, failed, mustRead: true);
    }
  }

  /// Forgets [undo] before running it, so the button and the key together
  /// undo once: the key hides the notice, whose button can still be
  /// pressed while it slides away.
  Future<void> _run(Future<void> Function() undo) async {
    if (!identical(_undo, undo)) return;
    _undo = _messenger = null;
    await undo();
  }

  /// The `undo` key: runs what the notice on screen offers and takes the
  /// notice away. False when no such notice shows, and then nothing
  /// happens.
  bool press() {
    final undo = _undo, messenger = _messenger;
    if (undo == null) return false;
    if (messenger != null && messenger.mounted) messenger.hideCurrentSnackBar();
    unawaited(_run(undo));
    return true;
  }
}

final undoNoticeProvider = Provider<UndoNotice>((ref) => UndoNotice());
