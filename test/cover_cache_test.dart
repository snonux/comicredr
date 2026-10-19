import 'dart:io';
import 'dart:typed_data';

import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/book_paths.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/make_cover.dart' as covers;
import 'package:comicredr/src/library/scanner.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Both the pure-Dart worker and the app's Flutter decoder must share
  // covers by content, independently of a comic's path or file name.
  for (final flutterDecoder in [false, true]) {
    group(flutterDecoder ? 'Flutter covers' : 'worker covers', () {
      late Directory tmp;
      late Directory first;
      late Directory second;
      late AppDatabase db;
      late LibraryStore store;
      late LibraryScanner scanner;
      late String coverDir;
      var made = 0;

      setUp(() async {
        tmp = Directory.systemTemp.createTempSync('cover_cache_test');
        first = Directory('${tmp.path}/First')..createSync();
        second = Directory('${tmp.path}/Second')..createSync();
        coverDir = '${tmp.path}/covers';
        db = AppDatabase(NativeDatabase.memory());
        store = LibraryStore(db);
        await store.addRoot(first.path);
        await store.addRoot(second.path);
        made = 0;
        scanner = LibraryScanner(
          store,
          coverDir: coverDir,
          workers: 1,
          makeCover: flutterDecoder
              ? (path, page, file) {
                  made++;
                  return covers.makeCover(path, page, file);
                }
              : null,
        );
      });
      tearDown(() async {
        await scanner.dispose();
        await db.close();
        tmp.deleteSync(recursive: true);
      });

      List<String> coverFiles() => Directory(coverDir).listSync().whereType<File>().map((f) => f.path).toList();

      test('moving, renaming and copying a comic reuses its existing cover', () async {
        final source = File(writeBook(first, 'Saga 01.cbz', 2));
        await scanner.scan();
        expect(scanner.last.failed, isEmpty);
        final key = (await store.books()).single.key;
        final cover = File(coverFile(coverDir, key));
        final bytes = cover.readAsBytesSync();
        cover.setLastModifiedSync(DateTime(2001));
        final stamp = cover.lastModifiedSync();

        final moved = source.renameSync('${second.path}/Saga 01.cbz');
        await scanner.scan();
        expect((await store.books()).single.path, moved.path);
        final renamed = moved.renameSync('${second.path}/Renamed.cbz');
        await scanner.scan();
        expect((await store.books()).single.path, renamed.path);
        renamed.copySync('${first.path}/Another name.cbz');
        await scanner.scan();

        expect(scanner.last.failed, isEmpty);
        expect((await store.books()).single.key, key);
        expect(await db.select(db.files).get(), hasLength(2));
        expect(coverFiles(), [cover.path]);
        expect(cover.readAsBytesSync(), bytes);
        expect(cover.lastModifiedSync(), stamp, reason: 'reuse the file without rendering it again');
        if (flutterDecoder) expect(made, 1);
      });

      test('same file name with different contents has a separate cover', () async {
        final dark = encodeGrayPng(4, 4, Uint8List(16));
        final light = encodeGrayPng(4, 4, Uint8List.fromList(List.filled(16, 255)));
        writeBookOf(first, 'Issue 01.cbz', [dark]);
        writeBookOf(second, 'Issue 01.cbz', [light]);
        await scanner.scan();

        expect(scanner.last.failed, isEmpty);
        final books = await store.books();
        expect(books, hasLength(2));
        final darkCover = File(coverFile(coverDir, books.singleWhere((b) => b.path.startsWith(first.path)).key));
        final lightCover = File(coverFile(coverDir, books.singleWhere((b) => b.path.startsWith(second.path)).key));
        expect(darkCover.path, isNot(lightCover.path));
        expect(darkCover.readAsBytesSync(), isNot(lightCover.readAsBytesSync()));
        expect(coverFiles(), hasLength(2));
        if (flutterDecoder) expect(made, 2);
      });

      test('moving and renaming a folder book reuses its cover', () async {
        final folder = Directory('${first.path}/Pepper')..createSync();
        File('${folder.path}/01.png').writeAsBytesSync(png);
        await scanner.scan();
        final key = (await store.books()).single.key;
        final cover = File(coverFile(coverDir, key));
        cover.setLastModifiedSync(DateTime(2001));
        final stamp = cover.lastModifiedSync();

        final moved = folder.renameSync('${second.path}/Renamed folder');
        await scanner.scan();
        expect(scanner.last.failed, isEmpty);
        final book = (await store.books()).single;
        expect((book.path, book.key, book.isFolder), (moved.path, key, true));
        expect(coverFiles(), [cover.path]);
        expect(cover.lastModifiedSync(), stamp);
        if (flutterDecoder) expect(made, 1);
      });

      test('an unchanged comic is skipped, but its missing cover is rebuilt', () async {
        writeBook(first, 'Saga 01.cbz', 2);
        await scanner.scan();
        final key = (await store.books()).single.key;
        final cover = File(coverFile(coverDir, key));
        final bytes = cover.readAsBytesSync();
        await scanner.scan();
        expect(scanner.last.total, 0);

        cover.deleteSync();
        await scanner.scan();
        expect(scanner.last.failed, isEmpty);
        expect(scanner.last.total, 1);
        expect((await store.books()).single.key, key);
        expect(cover.readAsBytesSync(), bytes);
        if (flutterDecoder) expect(made, 2);
      });
    });
  }
}
