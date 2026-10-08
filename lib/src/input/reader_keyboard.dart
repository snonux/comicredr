import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:reader_input/reader_input.dart';

import 'key_tokens.dart';

/// Sits at the top of the reader, turns key presses into [ReaderCommand]s
/// through a [KeySequenceResolver], and hands each one to [onCommand].
/// Touch gestures (ReaderTouch) call the same [onCommand] with the same
/// intents.
class ReaderKeyboard extends StatefulWidget {
  const ReaderKeyboard({
    super.key,
    required this.keymap,
    required this.onCommand,
    this.onPendingChanged,
    this.focusNode,
    this.typeAhead,
    required this.child,
  });

  /// The node keys arrive on, for a parent to hand focus back to it.
  final FocusNode? focusNode;

  final Keymap keymap;
  final ValueChanged<ReaderCommand> onCommand;

  /// Called with the half-typed sequence (`4z`, `m`), empty when none.
  final ValueChanged<String>? onPendingChanged;

  /// Asked before a key is looked up: true when the key was taken as typing
  /// meant for a dialog that is on its way but has no focus yet (`gc`'s
  /// collection question), so it is no command and starts no sequence.
  final bool Function(KeyEvent event)? typeAhead;
  final Widget child;

  @override
  State<ReaderKeyboard> createState() => _ReaderKeyboardState();
}

class _ReaderKeyboardState extends State<ReaderKeyboard> {
  late KeySequenceResolver _resolver = KeySequenceResolver(widget.keymap);
  late final _own = widget.focusNode == null ? FocusNode(debugLabel: 'ReaderKeyboard') : null;
  FocusNode get _focus => widget.focusNode ?? _own!;

  /// Fires a digit binding (`111` over `11`) or a page number after `G` once
  /// no other key followed it.
  Timer? _digitTimer;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    _digitTimer?.cancel();
    _own?.dispose();
    super.dispose();
  }

  /// Focus can fall back to a scope above us, where no key reaches [_onKey]:
  /// clicking a folder open while the library search had the cursor did
  /// that, and every key went dead. Take it back, so `/` and the rest work.
  void _focusChanged() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary is! FocusScopeNode || !_focus.ancestors.contains(primary)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && FocusManager.instance.primaryFocus == primary) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(ReaderKeyboard old) {
    super.didUpdateWidget(old);
    if (old.keymap != widget.keymap) {
      _digitTimer?.cancel();
      _resolver = KeySequenceResolver(widget.keymap);
    }
  }

  void _armDigitTimer(DateTime now) {
    _digitTimer?.cancel();
    final at = _resolver.deadline;
    if (at == null) return;
    _digitTimer = Timer(at.difference(now), () {
      final command = _resolver.expire(at);
      _armDigitTimer(at);
      widget.onPendingChanged?.call(_resolver.pendingDisplay);
      if (command != null) widget.onCommand(command);
    });
  }

  static final _functionKeys = {
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  };

  /// Whether [event]'s key is one that types a character: a letter, a
  /// digit, a sign, Space. By the key, not by `event.character`, which is
  /// null for many keys while Alt is held.
  static bool _types(KeyEvent event) {
    final label = event.logicalKey.keyLabel;
    return label.characters.length == 1;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // Typing into a text field (the library search) is not a command; Esc
    // leaves the field and comes back to the keys. Function keys type
    // nothing, so they still work there (F11 for fullscreen).
    if (FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null &&
        !_functionKeys.contains(event.logicalKey)) {
      if (event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      _focus.requestFocus();
      return KeyEventResult.handled;
    }
    if (widget.typeAhead?.call(event) ?? false) return KeyEventResult.handled;
    final keys = HardwareKeyboard.instance;
    // Alt and a character is a dialog's key (DialogHotkeys), never a
    // command: no binding has Alt, and Alt+C pressed once too often after
    // a dialog closed would otherwise be c on the comic behind it. Keys
    // that type nothing (the arrows, Enter, Home, the F-keys) are no
    // dialog's letter and act with Alt held as they do without, as they
    // did before task 263. AltGr is not Alt.
    if (keys.isAltPressed && _types(event)) return KeyEventResult.ignored;
    final token = keyToken(event, ctrl: keys.isControlPressed, shift: keys.isShiftPressed);
    if (token == null) return KeyEventResult.ignored;
    // The key sequences' timeout goes by `clock`, which is the wall clock
    // in the app and the test's own clock in a widget test, where the
    // digit timer below runs too: a test that pumped between g and d then
    // lost the sequence whenever a loaded machine made the pump take more
    // than its 600 ms of real time (task 773).
    final now = clock.now();
    final command = _resolver.feed(token, now);
    _armDigitTimer(now);
    widget.onPendingChanged?.call(_resolver.pendingDisplay);
    if (command != null) widget.onCommand(event is KeyRepeatEvent ? command.asHeld : command);
    // The key that ended a number after G (G12 then l) counts as typed too.
    if (_resolver.takeQueued() case final queued?) {
      widget.onCommand(event is KeyRepeatEvent ? queued.asHeld : queued);
    }
    return command != null || _resolver.isPending ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: _focus, autofocus: true, onKeyEvent: _onKey, child: widget.child);
}
