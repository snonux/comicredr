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
    expect(type('9G'), const ReaderCommand(ReaderIntent.lastPage, count: 9));
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

    test('fire a page part at once', () {
      for (final (keys, intent) in [
        ('11', ReaderIntent.regionUpperHalf),
        ('12', ReaderIntent.regionLowerHalf),
        ('21', ReaderIntent.regionUpperThird),
        ('22', ReaderIntent.regionMiddleThird),
        ('23', ReaderIntent.regionLowerThird),
        ('31', ReaderIntent.regionStrip1),
        ('32', ReaderIntent.regionStrip2),
        ('33', ReaderIntent.regionStrip3),
        ('34', ReaderIntent.regionStrip4),
        ('41', ReaderIntent.regionTopLeft),
        ('42', ReaderIntent.regionTopRight),
        ('43', ReaderIntent.regionBottomLeft),
        ('44', ReaderIntent.regionBottomRight),
      ]) {
        expect(type(keys), ReaderCommand(intent), reason: keys);
        expect(r.isPending, isFalse);
        expect(r.deadline, isNull);
      }
    });

    test('G takes a page number after it', () {
      expect(press('G'), isNull);
      expect(r.deadline, t.add(const Duration(milliseconds: 500)));
      expect(type('12'), isNull);
      expect(r.pendingDisplay, 'G12');
      expect(press('Enter'), const ReaderCommand(ReaderIntent.lastPage, count: 12));
      // Ended by a pause.
      expect(type('G7'), isNull);
      expect(settle(499), isNull);
      expect(settle(1), const ReaderCommand(ReaderIntent.lastPage, count: 7));
      // G alone is the last page, after the pause.
      expect(press('G'), isNull);
      expect(settle(500), const ReaderCommand(ReaderIntent.lastPage));
      // Ended by another key, which counts as typed.
      expect(type('G3'), isNull);
      expect(press('l'), const ReaderCommand(ReaderIntent.lastPage, count: 3));
      expect(r.takeQueued(), const ReaderCommand(ReaderIntent.nextStep));
      expect(r.takeQueued(), isNull);
      // Esc cancels it; End does not wait.
      expect(type('G4'), isNull);
      expect(press('Esc'), isNull);
      expect(r.isPending, isFalse);
      expect(press('End'), const ReaderCommand(ReaderIntent.lastPage));
      // A key after the pause the timer missed: the number, then the key.
      expect(type('G5'), isNull);
      expect(press('l', afterMs: 800), const ReaderCommand(ReaderIntent.lastPage, count: 5));
      expect(r.takeQueued(), const ReaderCommand(ReaderIntent.nextStep));
    });

    test('typed quickly before a key are the part, then the key', () {
      expect(type('12'), const ReaderCommand(ReaderIntent.regionLowerHalf));
      expect(press('l'), const ReaderCommand(ReaderIntent.nextStep));
    });

    test('other counts are untouched', () {
      expect(type('5l'), const ReaderCommand(ReaderIntent.nextStep, count: 5));
      expect(type('15G'), const ReaderCommand(ReaderIntent.lastPage, count: 15));
      expect(type('60G'), const ReaderCommand(ReaderIntent.lastPage, count: 60));
    });

    test('typed slowly are a count', () {
      expect(press('1'), isNull);
      expect(press('1', afterMs: 501), isNull);
      expect(r.deadline, isNull);
      expect(press('G'), const ReaderCommand(ReaderIntent.lastPage, count: 11));
    });

    test('a longer digit binding waits for its last digit', () {
      final keymap = Keymap([
        ...Keymap.defaults().bindings,
        const Binding(['1', '1', '1'], ReaderIntent.autoTrim),
      ]);
      r = KeySequenceResolver(keymap);
      expect(type('11'), isNull);
      expect(r.deadline, t.add(const Duration(milliseconds: 400)));
      expect(settle(399), isNull);
      expect(settle(1), const ReaderCommand(ReaderIntent.regionUpperHalf));
      expect(type('111'), const ReaderCommand(ReaderIntent.autoTrim));
      expect(type('11'), isNull);
      expect(press('Esc'), isNull);
      expect(settle(), isNull);
      expect(r.isPending, isFalse);
    });

    test('the letter keys still work', () {
      expect(type('H1'), const ReaderCommand(ReaderIntent.regionUpperHalf));
      expect(type('L3'), const ReaderCommand(ReaderIntent.regionStrip3));
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
