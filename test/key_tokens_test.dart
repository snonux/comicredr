import 'package:comicredr/src/input/key_tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_input/reader_input.dart';

void main() {
  test('every key name keys.toml accepts is one a key press spells', () {
    expect(tokenKeyNames.toSet(), containsAll(namedKeys));
  });
}
