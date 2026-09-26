import 'package:comic_formats/comic_formats.dart';
import 'package:test/test.dart';

void main() {
  (String?, String?, int?, int?, String?) parse(String name) {
    final m = parseFileName(name);
    return (m.series, m.number, m.volume, m.year, m.title);
  }

  test('the plan\'s example and its usual mutations', () {
    expect(parse('Series Name v01 #003 (2019).cbz'), ('Series Name', '3', 1, 2019, null));
    expect(parse('Daredevil 181 (1982).cbz'), ('Daredevil', '181', null, 1982, null));
    expect(parse('Series_Name_003.cbz'), ('Series Name', '3', null, null, null));
    expect(parse('reptisaurus-v2-005.cbz'), ('Reptisaurus', '5', 2, null, null));
    expect(parse('Swamp Thing 21 - The Anatomy Lesson (1984).pdf'), (
      'Swamp Thing',
      '21',
      null,
      1984,
      'The Anatomy Lesson',
    ));
    expect(parse('Watchmen 01 of 12 (1986) (digital).cbz'), ('Watchmen', '1', null, 1986, null));
    expect(parse('X-Men #1.5 (2019).cbz'), ('X-Men', '1.5', null, 2019, null));
    expect(parse('Weird Comics 004 (Fox) (1940) (c2c) (Mark Bowen).cbz'), ('Weird Comics', '4', null, 1940, null));
    expect(parse('pepper-carrot-e06'), ('Pepper Carrot', '6', null, null, null));
  });

  test('a name without a number is a series of one', () {
    expect(parse('Barefoot Bride.pdf'), ('Barefoot Bride', null, null, null, null));
    expect(parse('Preacher'), ('Preacher', null, null, null, null));
  });

  test('series keys ignore case, punctuation and a leading The', () {
    expect(seriesKey('The Amazing Spider-Man'), seriesKey('amazing spider man'));
    expect(seriesKey('Pepper&Carrot'), seriesKey('pepper and carrot'));
    expect(seriesKey('Daredevil'), isNot(seriesKey('Daredevil Annual')));
  });

  test('issue numbers sort as numbers', () {
    expect(issueOrder('003'), 3);
    expect(issueOrder('1.5'), 1.5);
    expect(issueOrder('12a'), 12);
    expect(issueOrder('Annual'), isNull);
    expect(issueOrder(null), isNull);
  });

  test('an issue number too long for an int is kept as written', () {
    expect(parse('Spawn #12345678901234567890.cbz'), ('Spawn', '12345678901234567890', null, null, null));
    expect(parse('Spawn #0007.cbz'), ('Spawn', '7', null, null, null));
    expect(parse('Spawn #000.cbz'), ('Spawn', '0', null, null, null));
  });
}
