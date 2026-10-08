import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// The notices along the bottom (SnackBars). One rule for all of them: a
// notice takes the place of whatever notice is up, at once, so there is
// never a queue. Before, a notice shown while an Undo notice was up waited
// behind it unseen, and an Undo notice never went by itself. Every notice
// of the app is shown through [showNotice] or [UndoNotice.show];
// test/hotkeys_test.dart fails on a `showSnackBar` anywhere else in lib/.

/// How long a notice without a button shows unless its caller says.
const noticeTime = Duration(seconds: 4);

/// How long a notice with an Undo shows before it goes by itself, and the
/// `undo` key with it. Longer than a plain notice: it has to be read and
/// then answered.
const undoNoticeTime = Duration(seconds: 10);

/// Takes away whatever notice [messenger] shows or has waiting, without
/// the slide out: the next one is then the one on screen, not one queued
/// behind a notice on its way out.
void _clear(ScaffoldMessengerState messenger) => messenger
  ..clearSnackBars()
  ..removeCurrentSnackBar();

/// Shows [text] along the bottom in place of whatever notice is up, an
/// Undo notice too (its undo is then no longer offered, by button or key).
/// Nothing when [messenger] has gone.
void showNotice(ScaffoldMessengerState messenger, String text, {Duration duration = noticeTime}) {
  if (!messenger.mounted) return;
  _clear(messenger);
  messenger.showSnackBar(SnackBar(content: Text(text), duration: duration));
}

/// The notice along the bottom that offers an Undo, and what its button
/// does, kept so that the `undo` key (`u`) can press it: a SnackBar's
/// action is not in reach of the keyboard otherwise (task 263). One at a
/// time: a new notice of any kind replaces it, it goes by itself after
/// [undoNoticeTime], and once it has gone there is nothing left to undo.
/// So the key only ever acts on the notice that is on screen. The key is
/// HomeScreen's, so it works on whatever screen the notice shows over.
class UndoNotice {
  Future<void> Function()? _undo;
  ScaffoldMessengerState? _messenger;

  /// Shows [text] on [messenger] with a button labelled [label] that runs
  /// [undo]; the key runs it too for as long as the notice shows. What
  /// [undo] throws is caught and told in a notice of its own ([failed],
  /// else a general sentence): nobody awaits a button or a key.
  void show(
    ScaffoldMessengerState messenger,
    String text, {
    required String label,
    required Future<void> Function() undo,
    String failed = 'Could not undo that',
  }) {
    if (!messenger.mounted) return;
    _clear(messenger);
    Future<void> guarded() => _guarded(messenger, undo, failed);
    final shown = messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        // A SnackBar with an action stays until it is hidden unless told
        // otherwise.
        persist: false,
        duration: undoNoticeTime,
        action: SnackBarAction(label: label, onPressed: () => unawaited(_run(guarded))),
      ),
    );
    _undo = guarded;
    _messenger = messenger;
    // Gone, however (time, a swipe, its button, another notice): the key
    // has nothing to press any more.
    unawaited(
      shown.closed.then((_) {
        if (identical(_undo, guarded)) _undo = _messenger = null;
      }),
    );
  }

  /// [undo], with a failure said on [messenger] in place of an unhandled
  /// error.
  Future<void> _guarded(ScaffoldMessengerState messenger, Future<void> Function() undo, String failed) async {
    try {
      await undo();
    } catch (e) {
      debugPrint('$failed: $e');
      showNotice(messenger, failed);
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
