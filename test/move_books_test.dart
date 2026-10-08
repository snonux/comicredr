import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/move_books.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Moving a comic with [moveComic]: the file, its real `.crdb` sidecar and
/// the index row follow it, so reading progress and bookmarks stay put.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProgressStore progress;
  late SidecarSync sync;
  late LibraryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('move_books_test');
    db = AppDatabase(NativeDatabase.memory());
    progress = ProgressStore(db, debounce: Duration.zero);
    sync = SidecarSync(db, progress: progress, debounce: Duration.zero);
    store = LibraryStore(db);
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Directory dir(String name) => Directory('${tmp.path}/$name')..createSync(recursive: true);

  Future<(String path, String key)> bookIn(Directory root, String name, {int pages = 4}) async {
    final path = writeBook(root, name, pages);
    final key = await contentKey(path);
    await store.addRoot(root.path);
    await LibraryScanner(store, coverDir: '${tmp.path}/covers', workers: 1).scan();
    await sync.attach(path, key, folder: false);
    return (path, key);
  }

  Future<void> readTo(String key, {required int page, int? panel}) async {
    progress.save(key, ReadingPosition(page: page, panel: panel, guided: panel != null), 4);
    await MarkStore(db).addBookmark(key, page, panel);
    expect(await sync.write(key), isTrue);
  }

  test('moveComic takes the sidecar along and keeps progress and bookmarks', () async {
    final comics = dir('Comics');
    final (from, key) = await bookIn(comics, 'Daredevil 181.cbz');
    await readTo(key, page: 2, panel: 1);
    final beside = sidecarPath(from, folder: false);
    expect(File(beside).existsSync(), isTrue);
    expect(readSidecar(beside)!.progress.single.page, 2);

    final dest = dir('Comics/Read');
    final to = await moveComic(
      from: from,
      dir: dest.path,
      contentKey: key,
      folder: false,
      sidecars: sync,
      store: store,
    );
    expect(to, '${dest.path}/Daredevil 181.cbz');
    expect(File(from).existsSync(), isFalse);
    expect(File(to).existsSync(), isTrue);
    expect(File(beside).existsSync(), isFalse);
    final movedSide = sidecarPath(to, folder: false);
    expect(File(movedSide).existsSync(), isTrue);

    // The app index still has the place and the bookmark, keyed by content.
    final at = await progress.load(key);
    expect((at?.page, at?.panel, at?.guided), (2, 1, true));
    expect((await store.watchBookmarks(key).first).map((b) => b.page), contains(2));
    expect((await store.books()).single.path, to);

    // The sidecar file itself still holds the place for another install.
    final side = readSidecar(movedSide)!;
    expect(side.progress.single.page, 2);
    expect(side.progress.single.panel, 1);
    final mark = side.bookmarks.where((b) => b.deletedAt == null).single;
    expect((mark.page, mark.panel), (2, 1));
  });

  test('without a sidecar file, moveComic still keeps progress in the index', () async {
    final comics = dir('Comics');
    final (from, key) = await bookIn(comics, 'NoSide.cbz');
    progress.save(key, const ReadingPosition(page: 3, panel: 0, guided: true), 4);
    await MarkStore(db).addBookmark(key, 3, 0);
    // Never written: no .crdb beside the comic.
    expect(File(sidecarPath(from, folder: false)).existsSync(), isFalse);

    final dest = dir('Comics/Read');
    final to = await moveComic(
      from: from,
      dir: dest.path,
      contentKey: key,
      folder: false,
      sidecars: sync,
      store: store,
    );
    expect(File(to).existsSync(), isTrue);
    expect(File(sidecarPath(to, folder: false)).existsSync(), isFalse);
    final at = await progress.load(key);
    expect((at?.page, at?.panel, at?.guided), (3, 0, true));
    expect((await store.watchBookmarks(key).first).single.page, 3);
    expect((await store.books()).single.path, to);
  });

  test('with sidecars in one folder, the stored sidecar moves with the comic', () async {
    final comics = dir('Comics');
    final side = dir('side');
    sync = SidecarSync(db, progress: progress, debounce: Duration.zero, storeDir: () async => side.path);
    final (from, key) = await bookIn(comics, 'Saga 1.cbz');
    await readTo(key, page: 1);
    final stored = storedSidecarPath(from, folder: false, dir: side.path, roots: [(id: 1, path: comics.path)]);
    expect(File(stored).existsSync(), isTrue);
    expect(readSidecar(stored)!.progress.single.page, 1);
    expect(readSidecar(stored)!.progress.single.panel, isNull);

    final dest = dir('Comics/Finished');
    final to = await moveComic(
      from: from,
      dir: dest.path,
      contentKey: key,
      folder: false,
      sidecars: sync,
      store: store,
    );
    expect(File(stored).existsSync(), isFalse);
    final movedStored = storedSidecarPath(to, folder: false, dir: side.path, roots: [(id: 1, path: comics.path)]);
    expect(File(movedStored).existsSync(), isTrue);
    final moved = readSidecar(movedStored)!;
    expect(moved.progress.single.page, 1);
    expect(moved.bookmarks.where((b) => b.deletedAt == null).single.page, 1);
    expect((await progress.load(key))?.page, 1);
    expect(sidecarPath(to, folder: false), isNot(movedStored));
  });

  test('a folder book moves as one folder; its sidecar stays inside', () async {
    final comics = dir('Comics');
    final folder = dir('Comics/Pepper');
    for (var i = 1; i <= 3; i++) {
      File('${folder.path}/p$i.png').writeAsBytesSync([...png, i]);
    }
    await store.addRoot(comics.path);
    await LibraryScanner(store, coverDir: '${tmp.path}/covers', workers: 1).scan();
    final books = await store.books();
    final book = books.singleWhere((b) => b.isFolder);
    await sync.attach(book.path, book.key, folder: true);
    await readTo(book.key, page: 1);
    final inside = sidecarPath(book.path, folder: true);
    expect(File(inside).existsSync(), isTrue);

    final dest = dir('Comics/Read');
    final to = await moveComic(
      from: book.path,
      dir: dest.path,
      contentKey: book.key,
      folder: true,
      sidecars: sync,
      store: store,
    );
    expect(to, '${dest.path}/Pepper');
    expect(Directory(book.path).existsSync(), isFalse);
    expect(Directory(to).existsSync(), isTrue);
    expect(File(sidecarPath(to, folder: true)).existsSync(), isTrue);
    expect(readSidecar(sidecarPath(to, folder: true))!.progress.single.page, 1);
    expect((await progress.load(book.key))?.page, 1);
  });

  test('when the comic cannot be moved, nothing else changes', () async {
    final comics = dir('Comics');
    final (from, key) = await bookIn(comics, 'Kept.cbz');
    await readTo(key, page: 3);
    final beside = sidecarPath(from, folder: false);
    final before = File(beside).readAsBytesSync();

    expect(
      () => moveComic(
        from: from,
        dir: '${tmp.path}/no-such-folder',
        contentKey: key,
        folder: false,
        sidecars: sync,
        store: store,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(from).existsSync(), isTrue);
    expect(File(beside).readAsBytesSync(), before);
    expect((await progress.load(key))?.page, 3);
    expect((await store.books()).single.path, from);
  });

  test('a comic is never moved onto another of the same name', () async {
    // Two marked comics of one name, moved to one folder: the second must
    // not replace the first (a rename would, without a word).
    final (first, firstKey) = await bookIn(dir('Comics/A'), 'Vol 01.cbz', pages: 3);
    final (second, secondKey) = await bookIn(dir('Comics/B'), 'Vol 01.cbz', pages: 5);
    final target = dir('Comics/ToRead').path;
    final moved = await moveComic(
      from: first,
      dir: target,
      contentKey: firstKey,
      folder: false,
      sidecars: sync,
      store: store,
    );
    final kept = File(moved).readAsBytesSync();
    await expectLater(
      () => moveComic(from: second, dir: target, contentKey: secondKey, folder: false, sidecars: sync, store: store),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(moved).readAsBytesSync(), kept);
    expect(File(second).existsSync(), isTrue);
    expect(await contentKey(moved), firstKey);
  });

  test('matchesTarget wants every typed word in the label', () {
    const t = (path: '/Comics/Marvel/1980s', label: 'Comics/Marvel/1980s');
    expect(matchesTarget(t, 'marvel 1980'), isTrue);
    expect(matchesTarget(t, '1980 marvel'), isTrue);
    expect(matchesTarget(t, 'dc'), isFalse);
    expect(matchesTarget(t, ''), isTrue);
  });

  test('listMoveTargets skips folder books and hidden folders', () {
    final comics = dir('Comics');
    dir('Comics/Read');
    dir('Comics/.cache');
    final folderBook = dir('Comics/Pepper');
    File('${folderBook.path}/p1.png').writeAsBytesSync(png);
    final targets = listMoveTargets([comics.path], {folderBook.path});
    final labels = [for (final t in targets) t.label];
    expect(labels, containsAll(['Comics', 'Comics/Read']));
    expect(labels, isNot(contains('Comics/Pepper')));
    expect(labels, isNot(contains('Comics/.cache')));
  });
}
