import 'package:comic_formats/comic_formats.dart' show naturalCompare, seriesKey;

import 'library_store.dart';

/// What the Folders tab can be sorted by (`gS`, `go`), each with the way
/// round it goes unless reversed (`gO`): names and series A to Z, the
/// rest newest, latest, biggest or most first.
enum SortOrder {
  name('Name', 'n', 'A to Z', 'Z to A'),
  added('Added', 'a', 'newest first', 'oldest first'),
  read('Last read', 'l', 'latest first', 'earliest first'),
  modified('Modified', 'm', 'newest first', 'oldest first'),
  size('Size', 's', 'biggest first', 'smallest first'),
  pages('Pages', 'p', 'most first', 'fewest first'),
  series('Series', 'e', 'A to Z', 'Z to A'),
  year('Year', 'y', 'newest first', 'oldest first');

  const SortOrder(this.label, this.letter, this.way, this.reversedWay);

  /// The order's name, and the letter Alt takes for it in the window.
  final String label, letter;

  /// How it goes, as it is and reversed.
  final String way, reversedWay;
}

/// The Folders tab's order: one of [SortOrder], maybe reversed. Saved as
/// `library.folderSort` (unset for the usual name order), so it is kept
/// across restarts and travels in a settings file.
class FolderSort {
  const FolderSort({this.order = SortOrder.name, this.reversed = false});

  /// File-name order, as the tab was before it could be sorted.
  static const usual = FolderSort();

  final SortOrder order;
  final bool reversed;

  bool get isUsual => this == usual;

  /// `Last read, latest first`: for the sort line and the notices.
  String get label => '${order.label}, ${reversed ? order.reversedWay : order.way}';

  /// The next order along (`go`), the way round kept.
  FolderSort next() =>
      FolderSort(order: SortOrder.values[(order.index + 1) % SortOrder.values.length], reversed: reversed);

  /// The other way round (`gO`).
  FolderSort flipped() => FolderSort(order: order, reversed: !reversed);

  /// As saved: `size` or `size:reversed`, null for the usual order.
  String? encode() => isUsual ? null : (reversed ? '${order.name}:reversed' : order.name);

  /// What [encode] wrote; anything else (a file edited by hand, an order
  /// a later version added) is the usual order.
  static FolderSort decode(String? text) {
    final [name, ...rest] = (text ?? '').split(':');
    final order = SortOrder.values.where((o) => o.name == name).firstOrNull;
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
    } else if (order == SortOrder.series) {
      c = _bySeries(a, b);
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
    SortOrder.name || SortOrder.series => null,
  } as Comparable<Object>?;

  static int _bySeries(LibraryBook a, LibraryBook b) {
    final s = naturalCompare(seriesKey(a.series), seriesKey(b.series));
    return s != 0 ? s : LibraryBook.seriesOrder(a, b);
  }

  /// [books] in this order.
  List<LibraryBook> books(List<LibraryBook> books) => [...books]..sort(compareBooks);

  /// [folders] in this order, each going by the comic of it that comes
  /// first (the folder whose newest comic is newest first, and so on);
  /// by name they stay as they are, which for library folders is the
  /// order they were added in. A folder with no comic goes last.
  List<LibraryFolder> folders(List<LibraryFolder> folders) {
    if (order == SortOrder.name) return reversed ? folders.reversed.toList() : folders;
    final first = {for (final f in folders) f: f.books.isEmpty ? null : f.books.reduce(_earlier)};
    int compare(LibraryFolder a, LibraryFolder b) {
      final fa = first[a], fb = first[b];
      if (fa == null || fb == null) return fa == null ? (fb == null ? 0 : 1) : -1;
      final c = compareBooks(fa, fb);
      return c != 0 ? c : naturalCompare(a.name, b.name);
    }

    return [...folders]..sort(compare);
  }

  LibraryBook _earlier(LibraryBook a, LibraryBook b) => compareBooks(a, b) <= 0 ? a : b;

  @override
  bool operator ==(Object other) => other is FolderSort && other.order == order && other.reversed == reversed;

  @override
  int get hashCode => Object.hash(order, reversed);
}
