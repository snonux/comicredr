import 'package:comicredr/src/library/library_panes.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// A comic of the library, completed or not.
LibraryBook book(String name, {bool completed = false}) => LibraryBook(
  key: name,
  series: 'S',
  pageCount: 10,
  format: 'cbz',
  path: '/c/$name.cbz',
  addedAt: DateTime(2020),
  completedMark: completed ? true : null,
);

void main() {
  test('a count of books is singular for one (task xg4)', () {
    expect(bookCount(0), '0 books');
    expect(bookCount(1), '1 book');
    expect(bookCount(2), '2 books');
  });

  test('a collection tile counts its books in the singular for one (task xg4)', () {
    expect(groupCount(const LibraryGroup(1, 'Unread', [])), '0 books');
    expect(groupCount(LibraryGroup(1, 'Unread', [book('a')])), '1 book');
    expect(groupCount(LibraryGroup(1, 'Unread', [book('a'), book('b')])), '2 books');
    expect(groupCount(LibraryGroup(1, 'Done', [book('a', completed: true)])), '1 book · 1 read');
  });

  test('a folder tile counts its books in the singular for one', () {
    expect(folderCount(LibraryFolder('/c', [book('a')])), '1 book');
    expect(folderCount(LibraryFolder('/c', [book('a'), book('b', completed: true)])), '2 books · 1 read');
  });
}
