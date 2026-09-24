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
    required this.child,
  });

  /// The node keys arrive on, for a parent to hand focus back to it.
  final FocusNode? focusNode;

  final Keymap keymap;
  final ValueChanged<ReaderCommand> onCommand;

  /// Called with the half-typed sequence (`4z`, `m`), empty when none.
  final ValueChanged<String>? onPendingChanged;
  final Widget child;

  @override
  State<ReaderKeyboard> createState() => _ReaderKeyboardState();
}

class _ReaderKeyboardState extends State<ReaderKeyboard> {
  late KeySequenceResolver _resolver = KeySequenceResolver(widget.keymap);
  late final _own = widget.focusNode == null ? FocusNode(debugLabel: 'ReaderKeyboard') : null;
  FocusNode get _focus => widget.focusNode ?? _own!;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
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
    if (old.keymap != widget.keymap) _resolver = KeySequenceResolver(widget.keymap);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // Typing into a text field (the library search) is not a command; Esc
    // leaves the field and comes back to the keys.
    if (FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      if (event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      _focus.requestFocus();
      return KeyEventResult.handled;
    }
    final keys = HardwareKeyboard.instance;
    final token = keyToken(event, ctrl: keys.isControlPressed, shift: keys.isShiftPressed);
    if (token == null) return KeyEventResult.ignored;
    final command = _resolver.feed(token, DateTime.now());
    widget.onPendingChanged?.call(_resolver.pendingDisplay);
    if (command != null) widget.onCommand(command);
    return command != null || _resolver.isPending ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: _focus, autofocus: true, onKeyEvent: _onKey, child: widget.child);
}
