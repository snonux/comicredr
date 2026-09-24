import 'dart:io';

import 'package:comicredr/src/reader/open_book.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('open_book_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory folderBook(String name, int pages) {
    final dir = Directory('${tmp.path}/$name')..createSync();
    for (var i = 1; i <= pages; i++) {
      File('${dir.path}/page$i.png').writeAsBytesSync([...png, i]);
    }
    return dir;
  }

  test('] and [ step through CBZs, PDFs and folder books in natural order', () async {
    final a = writeBook(tmp, 'Book 1.cbz', 2);
    File('${tmp.path}/Book 2.pdf').writeAsStringSync('%PDF-1.4');
    final c = folderBook('Book 10', 2);
    folderBook('Book 3', 1);
    Directory('${tmp.path}/Not a book').createSync(); // No pages: skipped.
    File('${tmp.path}/notes.txt').writeAsStringSync('skipped');

    expect(await siblingBook(a, next: true), '${tmp.path}/Book 2.pdf');
    expect(await siblingBook('${tmp.path}/Book 2.pdf', next: true), '${tmp.path}/Book 3');
    expect(await siblingBook('${tmp.path}/Book 3/', next: true), c.path);
    expect(await siblingBook(c.path, next: true), isNull);
    expect(await siblingBook(c.path, next: false), '${tmp.path}/Book 3');
  });

  test('a folder of pages opens as a book titled after the folder', () async {
    final dir = folderBook('Preacher v1.01', 3);
    final book = await openBook('${dir.path}/');
    expect((book.doc.pageCount, book.title, book.folder), (3, 'Preacher v1.01', true));
    await book.doc.close();
  });

  test('a PNG opens as a one-page comic, and ] steps to the image beside it', () async {
    final a = writeBook(tmp, 'Book 1.cbz', 2);
    final strip = File('${tmp.path}/Book 2.png')..writeAsBytesSync([...png, 2]);
    File('${tmp.path}/Book 3.jpg').writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0]);
    File('${tmp.path}/Book 4.gif').writeAsBytesSync([0x47, 0x49, 0x46]);
    final book = await openBook(strip.path);
    expect((book.doc.pageCount, book.title, book.folder), (1, 'Book 2', false));
    await book.doc.close();

    expect(await siblingBook(a, next: true), strip.path);
    expect(await siblingBook(strip.path, next: true), '${tmp.path}/Book 3.jpg');
    expect(await siblingBook('${tmp.path}/Book 3.jpg', next: true), isNull, reason: 'a GIF is only ever a page');
  });

  test('pages of a folder book are not books beside it, but an image opened from one steps to the next', () async {
    final dir = folderBook('Strips', 3);
    final other = folderBook('Zines', 1);
    expect(await siblingBook(dir.path, next: true), other.path);
    expect(await siblingBook('${dir.path}/page1.png', next: true), '${dir.path}/page2.png');
  });

  test('a RAR is refused with the conversion hint', () async {
    final rar = File('${tmp.path}/x.cbr')..writeAsBytesSync([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0]);
    expect(openBook(rar.path), throwsA(isA<OpenBookException>().having((e) => e.message, 'message', contains('unar'))));
  });
}
