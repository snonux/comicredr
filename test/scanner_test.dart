import 'dart:io';

import 'package:comicredr/src/library/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  test("a page added to a folder book's sub-folder changes the book", () {
    final tmp = Directory.systemTemp.createTempSync('scanner_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final book = Directory('${tmp.path}/Pepper')..createSync();
    File('${book.path}/01.png').writeAsBytesSync(png);
    final extras = Directory('${book.path}/extras')..createSync();
    File('${extras.path}/01.png').writeAsBytesSync(png);

    final before = findBooks(tmp.path).single;
    expect(before.relPath, 'Pepper');
    File('${extras.path}/02.png').writeAsBytesSync([...png, 1]);
    final after = findBooks(tmp.path).single;
    expect(after.size, greaterThan(before.size), reason: 'FolderDocument reads extras/ too');
  });
}
