import 'dart:math' as math;

import 'library_store.dart';

/// `ga`: a comic picked at random from the ones still to read (snonux,
/// 2026-11-22). Unread is neither completed ([LibraryBook.completed]) nor
/// being read ([LibraryBook.started]), which is not the Unread collection
/// (only comics new since the app came). A comic only on S3 is left out,
/// since it cannot be opened before it is downloaded, and so is [except]
/// (the open comic, so a second `ga` brings another). [shown] is the
/// library's filter (`F`): a filter for CBZs picks a CBZ. Copies of one
/// comic (the same content key) count once, so a comic kept twice is not
/// twice as likely. Null when nothing is left.
LibraryBook? pickUnread(
  Iterable<LibraryBook> books, {
  required bool Function(LibraryBook) shown,
  String? except,
  math.Random? random,
}) {
  final seen = <String>{};
  final unread = [
    for (final b in books)
      if (!b.completed && !b.started && !b.remoteOnly && b.key != except && shown(b) && seen.add(b.key)) b,
  ];
  if (unread.isEmpty) return null;
  return unread[(random ?? math.Random()).nextInt(unread.length)];
}
