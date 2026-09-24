import 'intents.dart';
import 'keymap.dart';

/// Turns key tokens into [ReaderCommand]s, handling what Flutter's own
/// `Shortcuts` cannot: count prefixes (`5l`, `42G`) and multi-key sequences
/// (`gg`, `zw`, `ma`, `'a`).
///
/// Feed every key press to [feed]. It returns a command once a binding is
/// complete, or null while a count or prefix is pending. A pending prefix
/// that sees no further key within [timeout] is dropped; the caller passes
/// the current time in, so this class needs no timer and tests need no clock.
class KeySequenceResolver {
  KeySequenceResolver(this.keymap, {this.timeout = const Duration(milliseconds: 600)});

  final Keymap keymap;
  final Duration timeout;

  final List<String> _pending = [];
  String _count = '';
  DateTime? _lastKey;

  /// What has been typed so far and not yet resolved, for a status hint.
  String get pendingDisplay => '$_count${_pending.join()}';

  bool get isPending => _pending.isNotEmpty || _count.isNotEmpty;

  void reset() {
    _pending.clear();
    _count = '';
  }

  ReaderCommand? feed(String token, DateTime now) {
    final last = _lastKey;
    _lastKey = now;
    if (last != null && isPending && now.difference(last) > timeout) {
      reset();
    }

    if (token == 'Esc' && isPending) {
      // Esc cancels a half-typed sequence before it means anything else.
      reset();
      return null;
    }

    if (_pending.isEmpty && _isDigit(token) && (token != '0' || _count.isNotEmpty)) {
      _count += token;
      return null;
    }

    _pending.add(token);
    final seq = List<String>.unmodifiable(_pending);

    // An exact binding wins over a letter slot, so `mm` is a bookmark and
    // `ma` is mark a.
    for (final b in keymap.bindings) {
      if (!b.hasLetterSlot && _equals(b.keys, seq)) {
        return _emit(ReaderCommand(b.intent, count: _countValue));
      }
    }
    for (final b in keymap.bindings) {
      if (b.hasLetterSlot && b.keys.length == seq.length && _matchesSlot(b.keys, seq)) {
        final slot = b.keys.indexOf(letterSlot);
        return _emit(ReaderCommand(b.intent, count: _countValue, register: seq[slot]));
      }
    }
    final isPrefix = keymap.bindings.any(
      (b) => b.keys.length > seq.length && _matchesSlot(b.keys.sublist(0, seq.length), seq),
    );
    if (!isPrefix) {
      reset();
    }
    return null;
  }

  int? get _countValue => _count.isEmpty ? null : int.parse(_count);

  ReaderCommand _emit(ReaderCommand c) {
    reset();
    return c;
  }

  static bool _isDigit(String t) => t.length == 1 && t.codeUnitAt(0) >= 48 && t.codeUnitAt(0) <= 57;

  static bool _isLetter(String t) => t.length == 1 && t.codeUnitAt(0) >= 97 && t.codeUnitAt(0) <= 122;

  static bool _equals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _matchesSlot(List<String> pattern, List<String> seq) {
    if (pattern.length != seq.length) return false;
    for (var i = 0; i < seq.length; i++) {
      final p = pattern[i];
      if (p == letterSlot ? !_isLetter(seq[i]) : p != seq[i]) return false;
    }
    return true;
  }
}
