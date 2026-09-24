import 'package:flutter/services.dart';

final _named = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.arrowLeft: 'Left',
  LogicalKeyboardKey.arrowRight: 'Right',
  LogicalKeyboardKey.arrowUp: 'Up',
  LogicalKeyboardKey.arrowDown: 'Down',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.escape: 'Esc',
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.numpadEnter: 'Enter',
  LogicalKeyboardKey.f11: 'F11',
};

/// Spells a key press as a `reader_input` token: `l`, `G`, `C-f`, `S-Tab`,
/// `PageDown`. Returns null for bare modifiers and keys nothing binds.
///
/// Printable keys use the character the keyboard layout produced, so `G`,
/// `?` and `'` work on any layout; Shift only appears as `S-` on named keys.
String? keyToken(KeyEvent event, {required bool ctrl, required bool shift}) {
  final named = _named[event.logicalKey];
  if (named != null) {
    return '${ctrl ? 'C-' : ''}${shift ? 'S-' : ''}$named';
  }
  if (ctrl) {
    // With Ctrl held, event.character is a control code, so use the key label.
    final label = event.logicalKey.keyLabel;
    return label.length == 1 ? 'C-${label.toLowerCase()}' : null;
  }
  final ch = event.character;
  if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 0x20) return null;
  return ch;
}
