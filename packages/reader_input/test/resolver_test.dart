import 'package:reader_input/reader_input.dart';
import 'package:test/test.dart';

void main() {
  late KeySequenceResolver r;
  late DateTime t;

  setUp(() {
    r = KeySequenceResolver(Keymap.defaults());
    t = DateTime(2026, 9, 24);
  });

  ReaderCommand? press(String key, {int afterMs = 50}) {
    t = t.add(Duration(milliseconds: afterMs));
    return r.feed(key, t);
  }

  ReaderCommand? type(String keys) {
    ReaderCommand? last;
    for (final k in keys.split('')) {
      last = press(k);
    }
    return last;
  }

  test('single keys resolve at once, in both layers', () {
    expect(press('l'), const ReaderCommand(ReaderIntent.nextStep));
    expect(press('Right'), const ReaderCommand(ReaderIntent.scrollRight));
    expect(press('C-f'), const ReaderCommand(ReaderIntent.nextPage));
    expect(press('v'), const ReaderCommand(ReaderIntent.toggleGuided));
  });

  test('counts prefix a command', () {
    expect(type('5l'), const ReaderCommand(ReaderIntent.nextStep, count: 5));
    expect(type('42G'), const ReaderCommand(ReaderIntent.lastPage, count: 42));
    expect(press('3'), isNull);
    expect(press('C-f'), const ReaderCommand(ReaderIntent.nextPage, count: 3));
  });

  test('a count too long for an int is capped, not thrown', () {
    expect(type('99999999999999999999G'), const ReaderCommand(ReaderIntent.lastPage, count: 999999));
  });

  test('a leading zero is not a count', () {
    expect(press('0'), isNull);
    expect(r.isPending, isFalse);
  });

  test('two-key sequences', () {
    expect(press('g'), isNull);
    expect(r.pendingDisplay, 'g');
    expect(press('g'), const ReaderCommand(ReaderIntent.firstPage));
    expect(type('zw'), const ReaderCommand(ReaderIntent.fitWidth));
    expect(type('zz'), const ReaderCommand(ReaderIntent.fitPage));
  });

  test('marks take a register, and mm beats m<letter>', () {
    expect(type('ma'), const ReaderCommand(ReaderIntent.setMark, register: 'a'));
    expect(type("'q"), const ReaderCommand(ReaderIntent.jumpMark, register: 'q'));
    expect(type('mm'), const ReaderCommand(ReaderIntent.bookmark));
    expect(type("''"), const ReaderCommand(ReaderIntent.jumpBack));
  });

  test('a stale prefix times out', () {
    expect(press('g'), isNull);
    expect(press('g', afterMs: 700), isNull);
    expect(press('g'), const ReaderCommand(ReaderIntent.firstPage));
  });

  test('Esc cancels a pending sequence, and means back otherwise', () {
    expect(type('4z'), isNull);
    expect(press('Esc'), isNull);
    expect(r.isPending, isFalse);
    expect(press('Esc'), const ReaderCommand(ReaderIntent.back));
  });

  test('an unbound sequence is dropped without swallowing the next key', () {
    expect(type('zq'), isNull);
    expect(r.isPending, isFalse);
    expect(press('l'), const ReaderCommand(ReaderIntent.nextStep));
  });

  test('every intent has a binding', () {
    final bound = Keymap.defaults().bindings.map((b) => b.intent).toSet();
    expect(ReaderIntent.values.toSet().difference(bound), isEmpty);
  });
}
