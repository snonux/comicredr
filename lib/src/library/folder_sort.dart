import 'package:comic_formats/comic_formats.dart' show naturalCompare;

import 'library_store.dart';

/// What a tab of the library can be sorted by (`gS`, `go`), each with the way
/// round it goes unless reversed (`gO`): names A to Z, the rest newest,
/// latest, biggest or most first. Issue is volume, then issue number.
enum SortOrder {
  name('Name', 'n', 'A to Z', 'Z to A'),
  added('Added', 'a', 'newest first', 'oldest first'),
  read('Last read', 'l', 'latest first', 'earliest first'),
  modified('Modified', 'm', 'newest first', 'oldest first'),
  size('Size', 's', 'biggest first', 'smallest first'),
  pages('Pages', 'p', 'most first', 'fewest first'),
  issue('Issue', 'i', 'first to last', 'last to first'),
  year('Year', 'y', 'newest first', 'oldest first');

  const SortOrder(this.label, this.letter, this.way, this.reversedWay);

  /// The order's name, and the letter Alt takes for it in the window.
  final String label, letter;

  /// How it goes, as it is and reversed.
  final String way, reversedWay;
}

/// The order of a tab of the library: one of [SortOrder], maybe reversed.
/// Named for the Folders tab, the first one sorted; since task 534 every
/// tab that lists comics but History has one of its own (LibraryScreen's
/// `sortSettings`), saved under its own setting (`library.folderSort` for
/// the Folders tab), unset for the tab's usual order, so it is kept across
/// restarts and travels in a settings file.
class FolderSort {
  const FolderSort({this.order = SortOrder.name, this.reversed = false});

  /// File-name order, as the tabs were before they could be sorted.
  static const usual = FolderSort();

  final SortOrder order;
  final bool reversed;

  /// `Last read, latest first`: for the sort line and the notices.
  String get label => '${order.label}, ${reversed ? order.reversedWay : order.way}';

  /// The next order along (`go`), the way round kept.
  FolderSort next() =>
      FolderSort(order: SortOrder.values[(order.index + 1) % SortOrder.values.length], reversed: reversed);

  /// The other way round (`gO`).
  FolderSort flipped() => FolderSort(order: order, reversed: !reversed);

  /// As saved: `size` or `size:reversed`, null for the tab's [usual]
  /// order (name order for most tabs; the Reading tab's is last read).
  String? encode({FolderSort usual = FolderSort.usual}) =>
      this == usual ? null : (reversed ? '${order.name}:reversed' : order.name);

  /// What [encode] wrote; nothing, or anything else (a file edited by
  /// hand, an order a later version added), is the tab's [usual] order.
  /// `series` was the order of the same name while the library still
  /// grouped by series; it reads as the issue order now.
  static FolderSort decode(String? text, {FolderSort usual = FolderSort.usual}) {
    final [name, ...rest] = (text ?? '').split(':');
    final order =
        SortOrder.values.where((o) => o.name == name).firstOrNull ?? (name == 'series' ? SortOrder.issue : null);
    if (order == null || rest.length > 1 || (rest.isNotEmpty && rest.first != 'reversed')) return usual;
    return FolderSort(order: order, reversed: rest.isNotEmpty);
  }

  /// [a] before [b] in this order. A comic without the value (never read,
  /// no year, an unknown page count) goes after every comic with one,
  /// either way round; ties, and two without, go by file name.
  int compareBooks(LibraryBook a, LibraryBook b) {
    final int c;
    if (order == SortOrder.name) {
      c = LibraryFolder.fileOrder(a, b);
    } else if (order == SortOrder.issue) {
      c = LibraryBook.bookOrder(a, b);
    } else {
      final va = _value(a), vb = _value(b);
      if (va == null && vb == null) return LibraryFolder.fileOrder(a, b);
      if (va == null || vb == null) return va == null ? 1 : -1;
      // Newest, latest, biggest, most first: the larger value first.
      c = vb.compareTo(va);
    }
    final way = reversed ? -c : c;
    return way != 0 ? way : LibraryFolder.fileOrder(a, b);
  }

  /// [b]'s value for a value order, null where it has none.
  Comparable<Object>? _value(LibraryBook b) => switch (order) {
    SortOrder.added => b.addedAt,
    SortOrder.read => b.readAt,
    SortOrder.modified => b.modified,
    SortOrder.size => b.size,
    SortOrder.pages => b.pageCount > 0 ? b.pageCount : null,
    SortOrder.year => b.year,
    SortOrder.name || SortOrder.issue => null,
  } as Comparable<Object>?;

  /// [books] in this order. With [completedLast] (the Reading tab) the
  /// comics marked or read as completed come after the others, each part
  /// in this order.
  List<LibraryBook> books(List<LibraryBook> books, {bool completedLast = false}) => [...books]
    ..sort(
      completedLast ? (a, b) => a.completed != b.completed ? (a.completed ? 1 : -1) : compareBooks(a, b) : compareBooks,
    );

  /// [folders] in this order: see [byFirstBook].
  List<LibraryFolder> folders(List<LibraryFolder> folders) => byFirstBook(folders, (f) => f.books, (f) => f.name);

  /// [groups] (folders, collections) in this order, each going by the
  /// comic of it that comes first (the folder whose newest comic is newest
  /// first, and so on); by name they stay as they are, which for library
  /// folders is the order they were added in and for collections their
  /// names A to Z. One with no comic goes last; ties go by [nameOf].
  List<T> byFirstBook<T extends Object>(
    List<T> groups,
    List<LibraryBook> Function(T) booksOf,
    String Function(T) nameOf,
  ) {
    if (order == SortOrder.name) return reversed ? groups.reversed.toList() : groups;
    final first = <T, LibraryBook?>{for (final g in groups) g: booksOf(g).isEmpty ? null : booksOf(g).reduce(_earlier)};
    int compare(T a, T b) {
      final fa = first[a], fb = first[b];
      if (fa == null || fb == null) return fa == null ? (fb == null ? 0 : 1) : -1;
      final c = compareBooks(fa, fb);
      return c != 0 ? c : naturalCompare(nameOf(a), nameOf(b));
    }

    return [...groups]..sort(compare);
  }

  LibraryBook _earlier(LibraryBook a, LibraryBook b) => compareBooks(a, b) <= 0 ? a : b;

  @override
  bool operator ==(Object other) => other is FolderSort && other.order == order && other.reversed == reversed;

  @override
  int get hashCode => Object.hash(order, reversed);
}
