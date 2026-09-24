import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:reader_input/reader_input.dart';

import 'key_tokens.dart';

/// Sits at the top of the reader, turns key presses into [ReaderCommand]s
/// through a [KeySequenceResolver], and hands each one to [onCommand].
/// Gestures on the phone call the same [onCommand] with the same intents.
class ReaderKeyboard extends StatefulWidget {
  const ReaderKeyboard({
    super.key,
    required this.keymap,
    required this.onCommand,
    this.onPendingChanged,
    required this.child,
  });

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

  @override
  void didUpdateWidget(ReaderKeyboard old) {
    super.didUpdateWidget(old);
    if (old.keymap != widget.keymap) _resolver = KeySequenceResolver(widget.keymap);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final token = keyToken(event, ctrl: keys.isControlPressed, shift: keys.isShiftPressed);
    if (token == null) return KeyEventResult.ignored;
    final command = _resolver.feed(token, DateTime.now());
    widget.onPendingChanged?.call(_resolver.pendingDisplay);
    if (command != null) widget.onCommand(command);
    return command != null || _resolver.isPending ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(autofocus: true, onKeyEvent: _onKey, child: widget.child);
}
