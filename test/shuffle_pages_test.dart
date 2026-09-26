import 'dart:io';

import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/shuffle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a page asked for after close answers null instead of never', () async {
    final tmp = Directory.systemTemp.createTempSync('shuffle_pages_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final pages = ShufflePages(dir: tmp.path, open: (_) => throw StateError('must not open'))..close();
    final book = LibraryBook(
      key: 'k',
      series: 'S',
      seriesId: 1,
      pageCount: 4,
      format: 'cbz',
      path: '${tmp.path}/b.cbz',
      addedAt: DateTime(2026),
    );
    expect(await pages.get(book, 2).timeout(const Duration(seconds: 2)), isNull);
  });
}
