import 'intents.dart';
import 'keymap.dart';

/// Turns key tokens into [ReaderCommand]s, handling what Flutter's own
/// `Shortcuts` cannot: count prefixes (`5l`, `2>`), a page number after the
/// key ([takesNumber]: `G12`) and multi-key sequences (`gg`, `zw`, `ma`,
/// `'a`).
///
/// Feed every key press to [feed]. It returns a command once a binding is
/// complete, or null while a count or prefix is pending. A pending prefix
/// that sees no further key within [timeout] is dropped; the caller passes
/// the current time in, so this class needs no timer and tests need no clock.
///
/// Digits are a count, except that a binding made only of digits (`21` for
/// the upper half) fires as soon as its digits come each within
/// [pairWindow] of the one before. When a longer digit binding starts with
/// the same digits, it waits [pairSettle] for one more. A leading zero is
/// not a count (`00` is a two-key sequence).
///
/// A one-character key of an intent in [takesNumber] (`G`, not `End`) waits [pairWindow] for digits
/// after it: `G12` is page 12. The number ends with Enter, any other key
/// (which then counts as typed, from [takeQueued]) or a pause of
/// [pairWindow]; `G` alone fires after that pause. The caller asks
/// [deadline] when to call [expire]. A count typed before the key still
/// counts (`12G`) and fires at once.
class KeySequenceResolver {
  KeySequenceResolver(
    this.keymap, {
    this.timeout = const Duration(milliseconds: 600),
    this.pairWindow = const Duration(milliseconds: 500),
    this.pairSettle = const Duration(milliseconds: 400),
  }) : _digitBindings = [
         for (final b in keymap.bindings)
           if (isDigitSequence(b.keys)) b,
       ];

  final Keymap keymap;
  final Duration timeout;
  final Duration pairWindow;
  final Duration pairSettle;

  /// Intents whose keys take a number after them (`G12`), the count the
  /// intent gets.
  static const takesNumber = {ReaderIntent.lastPage};

  final List<Binding> _digitBindings;

  /// The key waiting for a number after it, and the digits so far.
  Binding? _numbered;
  String _number = '';

  /// A command that came with the one [feed] returned: the key that ended
  /// a number after `G`.
  ReaderCommand? _queued;

  /// The second command of the last [feed], if it made two; null otherwise.
  ReaderCommand? takeQueued() {
    final q = _queued;
    _queued = null;
    return q;
  }

  final List<String> _pending = [];
  String _count = '';
  DateTime? _lastKey;

  /// Whether the count typed so far came quickly enough to be a digit binding.
  bool _quick = false;

  /// The digit binding the count spells, to fire at [deadline] unless another
  /// key comes first.
  Binding? _digits;
  DateTime? _deadline;

  /// When to call [expire], or null when no digit binding is waiting.
  DateTime? get deadline => _deadline;

  /// What has been typed so far and not yet resolved, for a status hint.
  String get pendingDisplay => _numbered != null ? '${_numbered!.keys.join()}$_number' : '$_count${_pending.join()}';

  bool get isPending => _pending.isNotEmpty || _count.isNotEmpty || _numbered != null;

  void reset() {
    _pending.clear();
    _count = '';
    _quick = false;
    _digits = null;
    _deadline = null;
    _numbered = null;
    _number = '';
  }

  /// Fires the digit binding waiting since the last digit once [deadline]
  /// has passed with no other key; null when there is none or it is early.
  ReaderCommand? expire(DateTime now) {
    if (_numbered != null) {
      final at = _deadline;
      return at == null || now.isBefore(at) ? null : _emitNumbered();
    }
    final b = _digits, at = _deadline;
    if (b == null || at == null || now.isBefore(at)) return null;
    return _emit(ReaderCommand(b.intent));
  }

  ReaderCommand? feed(String token, DateTime now) {
    if (_numbered != null) {
      final at = _deadline;
      final late = at != null && !now.isBefore(at);
      if (!late && _isDigit(token) && (token != '0' || _number.isNotEmpty)) {
        if (_number.length < 6) _number += token;
        _lastKey = now;
        _deadline = now.add(pairWindow);
        return null;
      }
      if (!late && token == 'Esc') {
        _lastKey = now;
        reset();
        return null;
      }
      final done = _emitNumbered();
      if (!late && token == 'Enter') {
        _lastKey = now;
        return done;
      }
      // Any other key ends the number and counts as typed.
      _queued = feed(token, now);
      return done;
    }
    final last = _lastKey;
    _lastKey = now;
    if (last != null && isPending && now.difference(last) > timeout) {
      reset();
    }
    _digits = null;
    _deadline = null;

    if (token == 'Esc' && isPending) {
      // Esc cancels a half-typed sequence before it means anything else.
      reset();
      return null;
    }

    if (_pending.isEmpty && _isDigit(token) && (token != '0' || _count.isNotEmpty)) {
      // Six digits is more pages than any book has; more would overflow.
      _quick = _count.isEmpty || (_quick && last != null && now.difference(last) <= pairWindow);
      if (_count.length < 6) _count += token;
      if (_quick && _count.length > 1) {
        _digits = _digitBindings.where((b) => b.keys.join() == _count).firstOrNull;
        if (_digits case final d?) {
          // Nothing longer starts with these digits: fire now, so the part
          // shows at once. Only a longer digit binding waits for [pairSettle].
          if (!_digitBindings.any((b) => b.keys.length > _count.length && b.keys.join().startsWith(_count))) {
            return _emit(ReaderCommand(d.intent));
          }
          _deadline = now.add(pairSettle);
        }
      }
      return null;
    }

    _pending.add(token);
    final seq = List<String>.unmodifiable(_pending);

    // An exact binding wins over a letter slot, so `mm` is a bookmark and
    // `ma` is mark a.
    for (final b in keymap.bindings) {
      if (!b.hasLetterSlot && _equals(b.keys, seq)) {
        if (takesNumber.contains(b.intent) && _count.isEmpty && b.keys.length == 1 && b.keys.first.length == 1) {
          // `G`: wait for a page number after it.
          reset();
          _numbered = b;
          _deadline = now.add(pairWindow);
          return null;
        }
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

  ReaderCommand _emitNumbered() =>
      _emit(ReaderCommand(_numbered!.intent, count: _number.isEmpty ? null : int.parse(_number)));

  ReaderCommand _emit(ReaderCommand c) {
    reset();
    return c;
  }

  /// Whether [keys] are two or more digits, not starting with 0: a binding
  /// typed as quickly as a count, like `21`. (`00` is an ordinary sequence.)
  static bool isDigitSequence(List<String> keys) => keys.length > 1 && keys.first != '0' && keys.every(_isDigit);

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
