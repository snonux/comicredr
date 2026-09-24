import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/delete_book.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// `gd` or Shift+Delete deletes a comic after asking: the file, every
/// sidecar of it, and what the index keeps about it once no copy is left.
void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('delete_test');
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  group('deleteComic', () {
    late ProgressStore progress;
    late SidecarSync sync;
    late LibraryStore store;
    String? storeDir;
    String covers() => '${tmp.path}/covers';

    setUp(() {
      storeDir = null;
      progress = ProgressStore(db, debounce: Duration.zero);
      sync = SidecarSync(db, progress: progress, debounce: Duration.zero, storeDir: () async => storeDir);
      store = LibraryStore(db);
    });

    /// Two copies of one comic in the library, each with a sidecar, a
    /// bookmark, a cover and a page thumbnail.
    Future<(String, String, String)> shelf() async {
      final root = Directory('${tmp.path}/comics')..createSync();
      final a = writeBook(root, 'Daredevil 181.cbz', 3);
      final b = '${root.path}/Copy of Daredevil 181.cbz';
      File(a).copySync(b);
      final key = await contentKey(a);
      await store.addRoot(root.path);
      await LibraryScanner(store, coverDir: covers(), workers: 1).scan();
      await MarkStore(db).addBookmark(key, 1, null);
      for (final path in [a, b]) {
        await sync.attach(path, key, folder: false);
        expect(await sync.write(key), isTrue);
      }
      File('${covers()}/pages/$key/0.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      expect(File('${covers()}/$key.jpg').existsSync(), isTrue);
      return (a, b, key);
    }

    Future<List<BookmarkInfo>> bookmarks(String key) => store.watchBookmarks(key).first;

    Future<List<String>> delete(String path, String key) =>
        deleteComic(path: path, contentKey: key, folder: false, sidecars: sync, store: store, coverDir: covers());

    test('a copy goes with its sidecar; the book stays while another copy does', () async {
      final (a, b, key) = await shelf();
      expect(await delete(a, key), isEmpty);
      expect(File(a).existsSync(), isFalse);
      expect(File(sidecarPath(a, folder: false)).existsSync(), isFalse);
      expect(File(b).existsSync(), isTrue);
      expect(File(sidecarPath(b, folder: false)).existsSync(), isTrue);
      expect((await store.books()).single.path, b);
      expect(await bookmarks(key), hasLength(1));
      expect(File('${covers()}/$key.jpg').existsSync(), isTrue);

      // The last copy takes everything with it.
      expect(await delete(b, key), isEmpty);
      expect(File(b).existsSync(), isFalse);
      expect(File(sidecarPath(b, folder: false)).existsSync(), isFalse);
      expect(await store.books(), isEmpty);
      expect(await bookmarks(key), isEmpty);
      expect(File('${covers()}/$key.jpg').existsSync(), isFalse);
      expect(Directory('${covers()}/pages/$key').existsSync(), isFalse);

      // A change for the book that lands later writes no sidecar back.
      sync.touch(key);
      await sync.flush();
      expect(File(sidecarPath(b, folder: false)).existsSync(), isFalse);
    });

    test('sidecars kept in one folder go too, and the one beside the comic', () async {
      final (a, _, key) = await shelf();
      storeDir = '${tmp.path}/sidecars';
      expect(await sync.writeBeside(a, key, folder: false), isTrue);
      final places = await sync.sidecarsOf(a, folder: false);
      expect(places, hasLength(2));
      for (final s in places) {
        expect(File(s).existsSync(), isTrue, reason: s);
      }
      await delete(a, key);
      for (final s in places) {
        expect(File(s).existsSync(), isFalse, reason: s);
      }
    });

    test('a folder book goes as a whole', () async {
      final folder = Directory('${tmp.path}/Pepper')..createSync();
      for (var i = 1; i <= 3; i++) {
        File('${folder.path}/$i.png').writeAsBytesSync([...png, i]);
      }
      final key = await contentKey(folder.path);
      await sync.attach(folder.path, key, folder: true);
      expect(await sync.write(key), isTrue);
      final facts = await deleteFacts('Pepper', folder.path, folder: true, pages: 3);
      expect(facts.bytes, greaterThan(0));
      await deleteComic(
        path: folder.path,
        contentKey: key,
        folder: true,
        sidecars: sync,
        store: store,
        coverDir: covers(),
      );
      expect(folder.existsSync(), isFalse);
    });

    test('a comic that cannot be deleted keeps everything', () async {
      if (Platform.environment['USER'] == 'root' || Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
        markTestSkipped('root ignores folder permissions');
        return;
      }
      final (a, _, key) = await shelf();
      final dir = File(a).parent;
      Process.runSync('chmod', ['a-w', dir.path]);
      addTearDown(() => Process.runSync('chmod', ['u+w', dir.path]));
      await expectLater(delete(a, key), throwsA(isA<FileSystemException>()));
      expect(File(a).existsSync(), isTrue);
      expect(File(sidecarPath(a, folder: false)).existsSync(), isTrue);
      expect(await store.books(), hasLength(1));
      expect(await bookmarks(key), hasLength(1));
    });
  });

  group('in the app', () {
    setUp(() async => SettingsStore(db).saveBool(SettingsStore.wholePageSteps, false));

    Future<ProviderContainer> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db), classicCvOnly, noSidecars(db)],
          child: const ComicRedrApp(),
        ),
      );
      await tester.pump();
      return ProviderScope.containerOf(tester.element(find.byType(ComicRedrApp)));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    Future<void> gd(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'g');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD, character: 'd');
      await settle(tester);
    }

    testWidgets('gd asks with Cancel focused; Enter and Esc keep the comic', (tester) async {
      final path = writeBookOf(tmp, 'Delete 01.cbz', [grid4Page(), grid4Page()]);
      final c = await pumpApp(tester);
      await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
      await settle(tester);
      await gd(tester);
      expect(find.byKey(const Key('deleteDialog')), findsOneWidget);
      expect(find.text('Delete 01.cbz', findRichText: true), findsWidgets);
      expect(find.textContaining('deleted for good'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byKey(const Key('deleteDialog')), findsNothing);
      expect(File(path).existsSync(), isTrue);
      expect(c.read(readerProvider).book, isNotNull);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);
      expect(find.byKey(const Key('deleteDialog')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byKey(const Key('deleteDialog')), findsNothing);
      expect(File(path).existsSync(), isTrue);
      expect(c.read(readerProvider).book, isNotNull);
    });

    testWidgets('confirming deletes the comic and goes back to the library', (tester) async {
      final path = writeBookOf(tmp, 'Delete 02.cbz', [grid4Page(), grid4Page()]);
      final c = await pumpApp(tester);
      await tester.runAsync(() => c.read(readerProvider.notifier).open(path));
      await settle(tester);
      await gd(tester);
      await tester.tap(find.byKey(const Key('deleteConfirm')));
      for (var i = 0; i < 20 && File(path).existsSync(); i++) {
        await settle(tester);
      }
      expect(File(path).existsSync(), isFalse);
      expect(c.read(readerProvider).book, isNull);
      expect(find.textContaining('deleted'), findsWidgets);
    });
  });
}
