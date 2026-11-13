import 'library_store.dart';

/// One cover in a grid: a book, or a collection standing for its books.
sealed class LibraryItem {
  String get id;
}

class BookItem extends LibraryItem {
  BookItem(this.book);
  final LibraryBook book;
  @override
  // With its path: on the Folders tab two copies of a comic can sit side by side.
  String get id => 'b:${book.key}:${book.path}';
}

class GroupItem extends LibraryItem {
  GroupItem(this.group);
  final LibraryGroup group;
  @override
  String get id => 's:${group.id}';
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
