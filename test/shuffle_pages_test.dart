import 'dart:io';

import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/shuffle.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

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

  testWidgets('a page is made at the size asked for: 256 px beside the others, 512 px in w512', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('shuffle_pages_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // Pages wider than both sizes, so each file is as wide as it was asked.
    final page = gridPage(1024, 1536, [(64, 64, 896, 1408)]);
    final path = writeBookOf(tmp, 'b.cbz', [page, page, page]);
    final pages = ShufflePages(dir: '${tmp.path}/pages');
    addTearDown(pages.close);
    final book = LibraryBook(
      key: 'k',
      series: 'S',
      seriesId: 1,
      pageCount: 3,
      format: 'cbz',
      path: path,
      addedAt: DateTime(2026),
    );
    // The real making, on its worker and isolates: waited for itself, with
    // a limit that only says "never", far beyond what a busy machine needs.
    final (usual, big) = (await tester.runAsync(() async {
      const never = Duration(minutes: 5);
      return (await pages.get(book, 1).timeout(never), await pages.get(book, 2, size: 512).timeout(never));
    }))!;
    expect(usual, '${tmp.path}/pages/k/2.jpg');
    expect(big, '${tmp.path}/pages/k/w512/3.jpg');
    expect(_jpegWidth(File(usual!)), 256);
    expect(_jpegWidth(File(big!)), 512);
    expect(File('${tmp.path}/pages/k/w512/2.jpg').existsSync(), isFalse, reason: 'only what was asked for');
  });
}

/// The width in a JPEG file's frame header (the SOF0 to SOF2 segment).
int _jpegWidth(File file) {
  final b = file.readAsBytesSync();
  for (var i = 2; i + 9 < b.length;) {
    if (b[i] != 0xff) throw FormatException('No JPEG segment at $i');
    if (b[i + 1] >= 0xc0 && b[i + 1] <= 0xc2) return b[i + 7] << 8 | b[i + 8];
    i += 2 + (b[i + 2] << 8 | b[i + 3]);
  }
  throw const FormatException('No frame header');
}
