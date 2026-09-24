import 'package:reader_input/reader_input.dart';
import 'package:test/test.dart';

List<ReaderIntent> find(String q) => searchKeymap(Keymap.defaults(), q).entries.map((e) => e.intent).toList();

void main() {
  test('an empty query lists every action once', () {
    expect(find('  '), hasLength(ReaderIntent.values.length));
  });

  test('words match the description and the keys', () {
    expect(find('zoom'), containsAll([ReaderIntent.zoomIn, ReaderIntent.zoomOut, ReaderIntent.zoomReset]));
    expect(find('zoom in').first, ReaderIntent.zoomIn);
    expect(find('night'), [ReaderIntent.nightFilter]);
  });

  test('a key typed exactly puts its action first', () {
    expect(find('gg').first, ReaderIntent.firstPage);
    expect(find('C-f').first, ReaderIntent.nextPage);
    expect(find('t').first, ReaderIntent.autoTrim);
  });

  test('fuzzy: letters left out still match', () {
    expect(find('fulscr'), [ReaderIntent.fullscreen]);
    expect(find('ballon'), contains(ReaderIntent.toggleBalloons));
  });

  test('scattered letters across a sentence do not match', () {
    expect(find('xqz'), isEmpty);
  });

  test('/regex/ matches case-insensitively', () {
    expect(find('/^z/'), containsAll([ReaderIntent.fitWidth, ReaderIntent.fitHeight, ReaderIntent.fitPage]));
    expect(find('/^z/'), isNot(contains(ReaderIntent.zoomIn)));
    expect(find('/MARK a-z/'), [ReaderIntent.setMark, ReaderIntent.jumpMark]);
  });

  test('a broken regex says so', () {
    final r = searchKeymap(Keymap.defaults(), '/(/');
    expect(r.entries, isEmpty);
    expect(r.error, startsWith('Not a regex'));
  });
}
