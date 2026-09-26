import 'library_store.dart';

/// One cover in a grid: a book, or a series standing for its books.
sealed class LibraryItem {
  String get id;
}

class BookItem extends LibraryItem {
  BookItem(this.book);
  final LibraryBook book;
  @override
  String get id => 'b:${book.key}';
}

class SeriesItem extends LibraryItem {
  SeriesItem(this.series);
  final LibrarySeries series;
  @override
  String get id => 's:${series.id}';
}

/// A row on the Bookmarks tab: a bookmark or mark, with its book.
class BookmarkItem extends LibraryItem {
  BookmarkItem(this.bookmark, this.book);
  final BookmarkInfo bookmark;
  final LibraryBook book;
  @override
  String get id => 'm:${bookmark.id}';
}

class FolderItem extends LibraryItem {
  FolderItem(this.folder);
  final LibraryFolder folder;
  @override
  String get id => 'f:${folder.path}';
}
