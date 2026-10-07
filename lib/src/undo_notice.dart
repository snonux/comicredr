import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The notice along the bottom that offers an Undo, and what its button
/// does, kept so that the `undo` key (`u`) can press it: a SnackBar's
/// action is not in reach of the keyboard otherwise (task 263). One at a
/// time: a new notice replaces the last, and once the notice has gone
/// there is nothing left to undo. The key is HomeScreen's, so it works on
/// whatever screen the notice shows over. (The notice does not go by
/// itself: a SnackBar with an action stays until it is hidden.)
class UndoNotice {
  Future<void> Function()? _undo;
  ScaffoldMessengerState? _messenger;

  /// Shows [text] on [messenger] with a button labelled [label] that runs
  /// [undo]; the key runs it too for as long as the notice shows.
  void show(
    ScaffoldMessengerState messenger,
    String text, {
    required String label,
    required Future<void> Function() undo,
  }) {
    messenger.hideCurrentSnackBar();
    final shown = messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        action: SnackBarAction(label: label, onPressed: () => unawaited(_run(undo))),
      ),
    );
    _undo = undo;
    _messenger = messenger;
    unawaited(
      shown.closed.then((_) {
        if (identical(_undo, undo)) _undo = _messenger = null;
      }),
    );
  }

  /// Forgets [undo] before running it, so the button and the key together
  /// undo once: the key hides the notice, whose button can still be
  /// pressed while it slides away.
  Future<void> _run(Future<void> Function() undo) async {
    if (!identical(_undo, undo)) return;
    _undo = _messenger = null;
    await undo();
  }

  /// The `undo` key: runs what the notice offers and takes the notice
  /// away. False when no such notice shows, and then nothing happens.
  bool press() {
    final undo = _undo, messenger = _messenger;
    if (undo == null) return false;
    if (messenger != null && messenger.mounted) messenger.hideCurrentSnackBar();
    unawaited(_run(undo));
    return true;
  }
}

final undoNoticeProvider = Provider<UndoNotice>((ref) => UndoNotice());
