import 'package:comicredr/src/library/folder_sort.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:flutter_test/flutter_test.dart';

LibraryBook book(
  String name, {
  String series = 'S',
  String? number,
  int added = 1,
  int? read,
  int? modified,
  int? size,
  int pages = 10,
  int? year,
}) => LibraryBook(
  key: name,
  series: series,
  seriesId: 1,
  number: number,
  pageCount: pages,
  format: 'cbz',
  path: '/c/$name.cbz',
  addedAt: DateTime(2020, 1, added),
  readAt: read == null ? null : DateTime(2021, 1, read),
  modified: modified == null ? null : DateTime(2019, 1, modified),
  size: size,
  year: year,
);

List<String> names(Iterable<LibraryBook> books) => [for (final b in books) p(b.path)];
String p(String path) => path.split('/').last.replaceAll('.cbz', '');

void main() {
  final a = book('a 10', added: 3, read: 1, modified: 2, size: 300, pages: 30, year: 1950, series: 'Zorro');
  final b = book('a 2', added: 1, modified: 5, size: 100, pages: 0, series: 'Akira', number: '2');
  final c = book('b', added: 2, read: 7, size: 200, pages: 50, year: 1940, series: 'Akira', number: '10');
  final all = [a, b, c];

  test('each order, its usual way round and reversed', () {
    final want = {
      SortOrder.name: ['a 2', 'a 10', 'b'],
      SortOrder.added: ['a 10', 'b', 'a 2'],
      SortOrder.read: ['b', 'a 10', 'a 2'],
      SortOrder.modified: ['a 2', 'a 10', 'b'],
      SortOrder.size: ['a 10', 'b', 'a 2'],
      SortOrder.pages: ['b', 'a 10', 'a 2'],
      SortOrder.series: ['a 2', 'b', 'a 10'],
      SortOrder.year: ['a 10', 'b', 'a 2'],
    };
    // Reversed, every comic with a value turns round; one without stays last.
    final reversed = {
      SortOrder.name: ['b', 'a 10', 'a 2'],
      SortOrder.added: ['a 2', 'b', 'a 10'],
      SortOrder.read: ['a 10', 'b', 'a 2'],
      SortOrder.modified: ['a 10', 'a 2', 'b'],
      SortOrder.size: ['a 2', 'b', 'a 10'],
      SortOrder.pages: ['a 10', 'b', 'a 2'],
      SortOrder.series: ['a 10', 'b', 'a 2'],
      SortOrder.year: ['b', 'a 10', 'a 2'],
    };
    for (final o in SortOrder.values) {
      expect(names(FolderSort(order: o).books(all)), want[o], reason: o.name);
      expect(names(FolderSort(order: o, reversed: true).books(all)), reversed[o], reason: '${o.name} reversed');
    }
  });

  test('ties and comics without the value go by file name', () {
    final x = book('x'), y = book('y');
    expect(names(const FolderSort(order: SortOrder.added).books([y, x])), ['x', 'y']);
    expect(names(const FolderSort(order: SortOrder.read, reversed: true).books([y, x])), ['x', 'y']);
  });

  test('folders go by their first comic in the order; by name they stay as they are', () {
    final f1 = LibraryFolder('/c/one', [a]);
    final f2 = LibraryFolder('/c/two', [b, c]);
    const empty = LibraryFolder('/c/empty', []);
    List<String> folderNames(FolderSort s) => [
      for (final f in s.folders([f1, empty, f2])) f.name,
    ];
    expect(folderNames(FolderSort.usual), ['one', 'empty', 'two']);
    expect(folderNames(const FolderSort(reversed: true)), ['two', 'empty', 'one']);
    // two holds the comic read last.
    expect(folderNames(const FolderSort(order: SortOrder.read)), ['two', 'one', 'empty']);
    // Reversed, the one read earliest is one's.
    expect(folderNames(const FolderSort(order: SortOrder.read, reversed: true)), ['one', 'two', 'empty']);
    expect(folderNames(const FolderSort(order: SortOrder.size)), ['one', 'two', 'empty']);
  });

  test('saved and read back; anything else is the usual order', () {
    for (final o in SortOrder.values) {
      for (final r in [false, true]) {
        final s = FolderSort(order: o, reversed: r);
        expect(FolderSort.decode(s.encode()), s);
      }
    }
    expect(FolderSort.usual.encode(), isNull);
    expect(const FolderSort(order: SortOrder.size, reversed: true).encode(), 'size:reversed');
    for (final text in [null, '', 'colour', 'size:upside', 'size:reversed:x', ':reversed']) {
      expect(FolderSort.decode(text), FolderSort.usual, reason: '$text');
    }
  });

  test('go steps through every order and back, the way round kept; gO turns it', () {
    var s = const FolderSort(reversed: true);
    final seen = <SortOrder>[];
    for (var i = 0; i < SortOrder.values.length; i++) {
      seen.add(s.order);
      s = s.next();
      expect(s.reversed, isTrue);
    }
    expect(seen, SortOrder.values);
    expect(s.order, SortOrder.name);
    expect(s.flipped(), FolderSort.usual);
    expect(const FolderSort(order: SortOrder.read).label, 'Last read, latest first');
  });

  test('every order has its own letter in the window, none of Reverse and Done', () {
    final letters = [for (final o in SortOrder.values) o.letter, 'r', 'd'];
    expect(letters.toSet(), hasLength(letters.length));
    for (final o in SortOrder.values) {
      expect(o.label.toLowerCase(), contains(o.letter), reason: o.name);
    }
  });
}
