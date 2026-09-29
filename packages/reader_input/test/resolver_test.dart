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

  group('two quick digits', () {
    ReaderCommand? settle([int ms = 400]) {
      t = t.add(Duration(milliseconds: ms));
      return r.expire(t);
    }

    test('fire a page part once nothing follows', () {
      expect(type('11'), isNull);
      expect(r.pendingDisplay, '11');
      expect(r.deadline, t.add(const Duration(milliseconds: 400)));
      expect(settle(399), isNull);
      expect(settle(1), const ReaderCommand(ReaderIntent.regionUpperHalf));
      expect(r.isPending, isFalse);
      expect(r.deadline, isNull);
      for (final (keys, intent) in [
        ('12', ReaderIntent.regionLowerHalf),
        ('21', ReaderIntent.regionUpperThird),
        ('22', ReaderIntent.regionMiddleThird),
        ('23', ReaderIntent.regionLowerThird),
        ('31', ReaderIntent.regionTopLeft),
        ('32', ReaderIntent.regionTopRight),
        ('33', ReaderIntent.regionBottomLeft),
        ('34', ReaderIntent.regionBottomRight),
      ]) {
        type(keys);
        expect(settle(), ReaderCommand(intent), reason: keys);
      }
    });

    test('stay a count when a key follows', () {
      expect(type('12G'), const ReaderCommand(ReaderIntent.lastPage, count: 12));
      expect(r.expire(t.add(const Duration(seconds: 1))), isNull);
      expect(type('31l'), const ReaderCommand(ReaderIntent.nextStep, count: 31));
      expect(type('112G'), const ReaderCommand(ReaderIntent.lastPage, count: 112));
      expect(settle(), isNull);
    });

    test('typed slowly are a count', () {
      expect(press('1'), isNull);
      expect(press('1', afterMs: 501), isNull);
      expect(r.deadline, isNull);
      expect(press('G'), const ReaderCommand(ReaderIntent.lastPage, count: 11));
    });

    test('other pairs and Esc fire nothing', () {
      expect(type('13'), isNull);
      expect(r.deadline, isNull);
      expect(settle(), isNull);
      r.reset();
      expect(type('34'), isNull);
      expect(press('Esc'), isNull);
      expect(settle(), isNull);
      expect(r.isPending, isFalse);
    });

    test('the letter keys still work', () {
      expect(type('H1'), const ReaderCommand(ReaderIntent.regionUpperHalf));
      expect(type('Q4'), const ReaderCommand(ReaderIntent.regionBottomRight));
    });
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
