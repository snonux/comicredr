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

  test('symlinked comics and folders are listed, each real folder once', () {
    final tmp = Directory.systemTemp.createTempSync('scanner_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nas = Directory('${tmp.path}/nas')..createSync();
    final saga = writeBook(nas, 'Saga 01.cbz', 2);
    final series = Directory('${nas.path}/Hellboy')..createSync();
    writeBook(series, 'Hellboy 01.cbz', 2);
    final pages = Directory('${nas.path}/Pepper')..createSync();
    File('${pages.path}/01.png').writeAsBytesSync(png);

    final root = Directory('${tmp.path}/Comics')..createSync();
    Link('${root.path}/Saga 01.cbz').createSync(saga);
    Link('${root.path}/Hellboy').createSync(series.path);
    Link('${root.path}/Pepper').createSync(pages.path);
    Link('${series.path}/up').createSync(root.path); // Back up the tree.
    Link('${root.path}/Gone.cbz').createSync('${nas.path}/missing.cbz');

    final found = {for (final c in findBooks(root.path)) c.relPath: c};
    expect(found.keys, unorderedEquals(['Saga 01.cbz', 'Hellboy/Hellboy 01.cbz', 'Pepper']));
    expect(found['Saga 01.cbz']!.size, File(saga).lengthSync(), reason: 'the size of the comic, not the link');
  });
}
