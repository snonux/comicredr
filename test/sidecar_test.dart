import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/read_log_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/reader/panel_detector.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'support/fixtures.dart';

/// One install of the app: its own index and its own sidecar sync.
class Device {
  Device() : db = AppDatabase(NativeDatabase.memory()) {
    progress = ProgressStore(db, debounce: Duration.zero);
    sync = SidecarSync(db, progress: progress, debounce: Duration.zero, storeDir: () async => store);
  }

  /// The sidecar folder setting: null keeps sidecars beside the comics.
  String? store;

  final AppDatabase db;
  late final ProgressStore progress;
  late final SidecarSync sync;
  PanelStore get panels => PanelStore(db);
  MarkStore get marks => MarkStore(db);
  LibraryStore get library => LibraryStore(db);

  Future<List<BookmarkInfo>> bookmarks(String key) => library.watchBookmarks(key).first;
}

/// Where the sidecar of the book at [book] goes: hidden, beside it.
String hidden(String book) => sidecarPath(book, folder: false);

void main() {
  late Directory tmp;
  late Device laptop;
  late Device phone;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sidecar_test');
    laptop = Device();
    phone = Device();
  });
  tearDown(() async {
    await laptop.db.close();
    await phone.db.close();
    tmp.deleteSync(recursive: true);
  });

  Directory dir(String name) => Directory('${tmp.path}/$name')..createSync(recursive: true);

  /// What the laptop does while reading: the model finds a frame and a
  /// balloon on page 2, mark a and a bookmark go in, and it stops on page
  /// 3, panel 2, in guided view.
  Future<(String, String)> readOnLaptop() async {
    final path = writeBook(dir('laptop'), 'Daredevil 181 (1982).cbz', 4);
    final key = await contentKey(path);
    await laptop.sync.attach(path, key, folder: false);
    await laptop.panels.save(
      key,
      1,
      const DetectedPage(
        [
          Panel(0.1, 0.1, 0.8, 0.4, confidence: 0.9, shape: [0.1, 0.1, 0.9, 0.1, 0.9, 0.4, 0.1, 0.5]),
        ],
        [Panel(0.2, 0.15, 0.2, 0.1, kind: PanelKind.balloon, confidence: 0.8)],
        source: PanelSource.model,
        version: modelDetectorVersion,
        millis: 400,
        trim: Trim(0.1, 0.05, 0.9, 0.95),
      ),
    );
    await laptop.marks.save(key, 'a', 1, 0);
    await laptop.marks.addBookmark(key, 3, null);
    laptop.progress.save(key, const ReadingPosition(page: 2, panel: 1, guided: true), 4);
    expect(await laptop.sync.write(key), isTrue);
    return (path, key);
  }

  test('the sidecar carries panels, marks and position to a device that never detected', () async {
    final (path, key) = await readOnLaptop();
    expect(File(hidden(path)).existsSync(), isTrue);

    // Copied to the phone, and renamed on the way without its sidecar.
    final there = '${dir('phone').path}/dd-181.cbz';
    File(path).copySync(there);
    File(hidden(path)).copySync('${dir('phone').path}/.Daredevil 181 (1982).cbz.crdb');

    final got = await phone.sync.attach(there, key, folder: false);
    expect(got.found, isTrue);
    expect(File(hidden(there)).existsSync(), isTrue, reason: 'the orphan is re-linked by content key');
    expect(File('${dir('phone').path}/.Daredevil 181 (1982).cbz.crdb').existsSync(), isFalse);

    // The phone has classic CV only, and still gets the model's panels.
    final pages = await phone.panels.load(key, source: PanelSource.classicCv, version: classicCvVersion);
    expect(pages.keys, [1]);
    expect(pages[1]!.source, PanelSource.model);
    expect((pages[1]!.frames.length, pages[1]!.balloons.length), (1, 1));
    expect(pages[1]!.frames.single.shape, [0.1, 0.1, 0.9, 0.1, 0.9, 0.4, 0.1, 0.5], reason: 'the outline travels too');
    expect(pages[1]!.trim, const Trim(0.1, 0.05, 0.9, 0.95), reason: 'and the part of the page detection saw');
    expect(await phone.marks.load(key), {'a': (page: 1, panel: 0)});
    expect((await phone.bookmarks(key)).map((b) => b.page), containsAll([1, 3]));

    // Never opened on the phone: the laptop's position is taken as is.
    expect(got.adopted?.page, 2);
    final at = await phone.progress.load(key);
    expect((at?.page, at?.panel, at?.guided), (2, 1, true));
  });

  test("another device's later position is offered, not taken", () async {
    final (path, key) = await readOnLaptop();
    await phone.sync.attach(path, key, folder: false);
    // Read on to the last page on the phone, a minute later.
    await phone.db
        .into(phone.db.progress)
        .insertOnConflictUpdate(
          ProgressCompanion.insert(
            contentKey: key,
            page: 3,
            percent: 1,
            updatedAt: DateTime.now().add(const Duration(minutes: 1)),
          ),
        );
    expect(await phone.sync.write(key), isTrue);

    final got = await laptop.sync.attach(path, key, folder: false);
    expect(got.elsewhere?.page, 3);
    expect(got.elsewhere?.deviceName, isNotEmpty);
    expect(got.adopted, isNull);
    expect((await laptop.progress.load(key))?.page, 2, reason: "the laptop's own spot is kept until asked");

    // Taking the offer makes it this device's, and the offer goes away.
    await laptop.sync.adopt(key, got.elsewhere!);
    expect((await laptop.progress.load(key))?.page, 3);
    await Future<void>.delayed(const Duration(seconds: 1)); // Positions are kept to the second.
    await laptop.sync.write(key);
    expect((await laptop.sync.attach(path, key, folder: false)).elsewhere, isNull);

    // Both devices' positions stay in the file.
    expect(readSidecar(hidden(path))!.progress, hasLength(2));
  });

  test('a removed bookmark stays removed when an older copy comes back', () async {
    final (path, key) = await readOnLaptop();
    final old = '${tmp.path}/old.crdb';
    File(hidden(path)).copySync(old);

    final mm = (await laptop.bookmarks(key)).firstWhere((b) => b.mark == null);
    await laptop.library.deleteBookmark(mm.id);
    await laptop.sync.write(key);

    File(old).copySync(hidden(path)); // The phone's stale copy, copied back.
    await laptop.sync.attach(path, key, folder: false);
    expect((await laptop.bookmarks(key)).where((b) => b.mark == null), isEmpty);
    await laptop.sync.write(key);
    expect(readSidecar(hidden(path))!.bookmarks.where((b) => b.mark == null).single.deletedAt, isNotNull);
  });

  test('a mark moved and then removed on the phone does not come back from the laptop', () async {
    final (path, key) = await readOnLaptop(); // Mark a on page 2.
    await phone.sync.attach(path, key, folder: false);
    // The index keeps times to the second.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await phone.marks.save(key, 'a', 3, 0);
    final moved = (await phone.bookmarks(key)).firstWhere((b) => b.mark == 'a');
    await phone.library.deleteBookmark(moved.id);
    await phone.sync.write(key);
    expect(await phone.marks.load(key), isEmpty);

    await laptop.sync.attach(path, key, folder: false);
    expect(await laptop.marks.load(key), isEmpty, reason: "the laptop's older a was replaced, then removed");
    await phone.sync.attach(path, key, folder: false);
    expect(await phone.marks.load(key), isEmpty);
  });

  test('a sidecar under the old visible name is renamed to the hidden one and keeps everything', () async {
    final (path, key) = await readOnLaptop();
    final visible = '$path.crdb';
    File(hidden(path)).renameSync(visible); // As an older app left it.

    final got = await phone.sync.attach(path, key, folder: false);
    expect(got.found, isTrue);
    expect(File(visible).existsSync(), isFalse);
    expect(File(hidden(path)).existsSync(), isTrue);
    expect((await phone.progress.load(key))?.page, 2);
    expect(await phone.marks.load(key), {'a': (page: 1, panel: 0)});
  });

  test('when both names exist they are merged into the hidden one', () async {
    final (path, key) = await readOnLaptop();
    final visible = '$path.crdb';
    File(hidden(path)).copySync(visible);
    // An older app on the phone went on writing the visible one.
    await phone.sync.attach(path, key, folder: false);
    await phone.marks.save(key, 'q', 3, 0);
    await phone.progress.flush();
    writeSidecar(visible, await phone.sync.gather(key), device: 'old-phone');

    await laptop.sync.attach(path, key, folder: false);
    expect(File(visible).existsSync(), isFalse);
    expect(await laptop.marks.load(key), {'a': (page: 1, panel: 0), 'q': (page: 3, panel: 0)});
    expect(readSidecar(hidden(path))!.progress, hasLength(2), reason: "the laptop's position and the phone's");
  });

  test('an orphan under the old visible name is re-linked to the renamed book', () async {
    final (path, key) = await readOnLaptop();
    final there = '${dir('phone').path}/dd-181.cbz';
    File(path).copySync(there);
    File(hidden(path)).copySync('${dir('phone').path}/Daredevil 181 (1982).cbz.crdb');

    expect((await phone.sync.attach(there, key, folder: false)).found, isTrue);
    expect(File(hidden(there)).existsSync(), isTrue);
    expect(File('${dir('phone').path}/Daredevil 181 (1982).cbz.crdb').existsSync(), isFalse);
  });

  test('a reset also clears a sidecar still under the old visible name', () async {
    final (path, key) = await readOnLaptop();
    File(hidden(path)).renameSync('$path.crdb');

    expect(await laptop.sync.reset(key, everything: true), isTrue);
    expect(File('$path.crdb').existsSync(), isFalse);
    await laptop.sync.attach(path, key, folder: false);
    expect(await laptop.marks.load(key), isEmpty, reason: 'nothing merged back from the old name');
  });

  test('resetting panels finds them again and keeps bookmarks and every position', () async {
    final (path, key) = await readOnLaptop();
    // The phone read it too, so the file holds a second position.
    await phone.sync.attach(path, key, folder: false);
    await phone.sync.write(key);
    // A write still waiting must not bring the panels back.
    laptop.sync.touch(key);

    expect(await laptop.sync.reset(key, everything: false), isTrue);
    expect(await laptop.panels.load(key, source: PanelSource.classicCv, version: classicCvVersion), isEmpty);
    var side = readSidecar(hidden(path))!;
    expect(side.analysed, isEmpty);
    expect(side.panels, isEmpty);
    expect(side.progress, hasLength(2));
    expect(side.bookmarks, hasLength(2));

    await laptop.sync.attach(path, key, folder: false);
    await laptop.sync.flush();
    expect(await laptop.panels.load(key, source: PanelSource.classicCv, version: classicCvVersion), isEmpty);
    expect(await laptop.marks.load(key), {'a': (page: 1, panel: 0)});
    expect((await laptop.progress.load(key))?.page, 2);
    side = readSidecar(hidden(path))!;
    expect(side.panels, isEmpty);
  });

  test('resetting everything starts the book from scratch but keeps its collections', () async {
    final (path, key) = await readOnLaptop();
    await laptop.library.addToCollection(key, 'Favourites');
    await ReadLogStore(laptop.db).record(key, DateTime(2026), DateTime(2026, 1, 1, 0, 10), 5);
    await laptop.sync.write(key);
    await phone.sync.attach(path, key, folder: false);
    await phone.sync.write(key);

    expect(await laptop.sync.reset(key, everything: true), isTrue);
    expect(await laptop.progress.load(key), isNull);
    expect(await laptop.marks.load(key), isEmpty);
    expect(await laptop.bookmarks(key), isEmpty);
    expect(await laptop.db.select(laptop.db.readLog).get(), isEmpty);
    final side = readSidecar(hidden(path))!;
    expect(side.panels, isEmpty);
    expect(side.bookmarks, isEmpty);
    expect(side.progress, isEmpty);
    expect(side.collections.map((c) => c.name), ['Favourites']);

    // Opened again: nothing comes back from the file, and nobody offers a position.
    final got = await laptop.sync.attach(path, key, folder: false);
    expect(got.adopted, isNull);
    expect(got.elsewhere, isNull);
    expect(await laptop.bookmarks(key), isEmpty);
    expect(await laptop.panels.load(key, source: PanelSource.classicCv, version: classicCvVersion), isEmpty);
    expect((await laptop.db.select(laptop.db.collectionBooks).get()).map((c) => c.name), ['Favourites']);
  });

  test('a folder that refuses the sidecar keeps everything in the index', () async {
    final path = writeBook(dir('share'), 'Swamp Thing 21.cbz', 3);
    final key = await contentKey(path);
    Directory(hidden(path)).createSync(); // Something in the way that cannot be replaced.
    await laptop.sync.attach(path, key, folder: false);
    await laptop.marks.save(key, 'b', 2, 0);
    expect(await laptop.sync.write(key), isFalse);
    expect(laptop.sync.isReadOnly(key), isTrue);
    expect(await laptop.marks.load(key), {'b': (page: 2, panel: 0)});
    expect(Directory(dir('share').path).listSync().whereType<File>().map((f) => f.path), [path]);
  });

  test('merging: newer detection wins, the latest mark wins, each device keeps its position', () {
    AnalysedPage run(int page, String source, int ver) =>
        AnalysedPage(contentKey: 'k', page: page, source: source, modelVer: ver, millis: 1, analysedAt: DateTime(2026));
    PanelRow frame(int page, String source, int ver, double x) => PanelRow(
      contentKey: 'k',
      page: page,
      idx: 0,
      x: x,
      y: 0,
      w: 0.5,
      h: 0.5,
      kind: 'frame',
      source: source,
      modelVer: ver,
      confidence: 1,
    );
    Bookmark mark(String id, String m, DateTime at) =>
        Bookmark(id: id, contentKey: 'k', page: 0, mark: m, createdAt: at);
    SidecarProgress spot(String device, int page, DateTime at) =>
        SidecarProgress(device: device, deviceName: device, page: page, percent: 0, finished: false, updatedAt: at);

    final laptop = SidecarData(
      contentKey: 'k',
      analysed: [run(0, 'model', 2), run(1, 'model', 1)],
      panels: [frame(0, 'model', 2, 0.1), frame(1, 'model', 1, 0.2)],
      bookmarks: [mark('1', 'a', DateTime(2026, 1, 2))],
      progress: [spot('laptop', 5, DateTime(2026, 1, 2))],
    );
    final phone = SidecarData(
      contentKey: 'k',
      analysed: [run(0, 'model', 1), run(1, 'model', 2), run(1, 'classicCv', 1)],
      panels: [frame(0, 'model', 1, 0.3), frame(1, 'model', 2, 0.4), frame(1, 'classicCv', 1, 0.5)],
      bookmarks: [mark('2', 'a', DateTime(2026, 1, 1))],
      progress: [spot('phone', 9, DateTime(2026, 1, 3)), spot('laptop', 1, DateTime(2026, 1, 1))],
    );
    for (final m in [mergeSidecars(laptop, phone), mergeSidecars(phone, laptop)]) {
      expect(
        {for (final r in m.panels) (r.page, r.source): (r.modelVer, r.x)},
        {(0, 'model'): (2, 0.1), (1, 'model'): (2, 0.4), (1, 'classicCv'): (1, 0.5)},
      );
      expect(m.bookmarks.map((b) => b.id), ['1']);
      expect({for (final p in m.progress) p.device: p.page}, {'laptop': 5, 'phone': 9});
    }
  });

  test('merging: two model files of one generation go by the later run, a newer generation wins', () {
    AnalysedPage run(int page, int ver, DateTime at) =>
        AnalysedPage(contentKey: 'k', page: page, source: 'model', modelVer: ver, millis: 1, analysedAt: at);
    PanelRow frame(int page, int ver) => PanelRow(
      contentKey: 'k',
      page: page,
      idx: 0,
      x: 0,
      y: 0,
      w: 0.5,
      h: 0.5,
      kind: 'frame',
      source: 'model',
      modelVer: ver,
      confidence: 1,
    );
    // Same generation, the smaller hash ran later; a generation-3 run beats
    // a later generation-2 one.
    const big = 299999999, small = 200000001, next = 300000005;
    final a = SidecarData(
      contentKey: 'k',
      analysed: [run(0, big, DateTime(2026, 1, 1)), run(1, next, DateTime(2026, 1, 1))],
      panels: [frame(0, big), frame(1, next)],
    );
    final b = SidecarData(
      contentKey: 'k',
      analysed: [run(0, small, DateTime(2026, 1, 2)), run(1, big, DateTime(2026, 1, 3))],
      panels: [frame(0, small), frame(1, big)],
    );
    for (final m in [mergeSidecars(a, b), mergeSidecars(b, a)]) {
      expect({for (final r in m.panels) r.page: r.modelVer}, {0: small, 1: next});
    }
  });

  test('scanning reads sidecars in, never lists them as books, and export mirrors the library', () async {
    final root = dir('Comics');
    final cbz = writeBook(dir('Comics/Indie'), 'Barefoot Bride.cbz', 3);
    final folder = dir('Comics/Pepper Carrot e06');
    for (var i = 1; i <= 2; i++) {
      File('${folder.path}/p$i.png').writeAsBytesSync([...png, i]);
    }
    final before = findBooks(root.path);

    // The laptop reads both, so both get sidecars.
    final keys = [await contentKey(cbz), await contentKey(folder.path)];
    await laptop.sync.attach(cbz, keys[0], folder: false);
    await laptop.sync.attach(folder.path, keys[1], folder: true);
    await laptop.marks.addBookmark(keys[0], 2, null);
    await laptop.marks.addBookmark(keys[1], 1, null);
    expect(await laptop.sync.write(keys[0]), isTrue);
    expect(await laptop.sync.write(keys[1]), isTrue);
    expect(File('${folder.path}/.comicredr.crdb').existsSync(), isTrue);
    expect(await contentKey(folder.path), keys[1], reason: 'the sidecar is not a page');

    // Same books, sizes and times: writing sidecars is not a change.
    final after = findBooks(root.path);
    expect(after.map((c) => (c.relPath, c.size, c.mtimeMs)), before.map((c) => (c.relPath, c.size, c.mtimeMs)));

    // A phone scanning the copied shelf gets the bookmarks without opening.
    final store = phone.library;
    await store.addRoot(root.path);
    await LibraryScanner(
      store,
      coverDir: '${tmp.path}/covers',
      workers: 1,
      onBookRead: (path, key, {required folder}) => phone.sync.attach(path, key, folder: folder),
    ).scan();
    expect((await store.books()).map((b) => b.name).toSet(), {'Barefoot Bride', 'Pepper Carrot #6'});
    expect((await phone.bookmarks(keys[0])).single.page, 2);
    expect((await phone.bookmarks(keys[1])).single.page, 1);

    // Export writes every book's sidecar under another folder, laid out
    // like the library.
    final out = '${tmp.path}/export';
    expect(await phone.sync.exportAll(out), 2);
    expect(readSidecar('$out/Indie/.Barefoot Bride.cbz.crdb')?.contentKey, keys[0]);
    expect(readSidecar('$out/Pepper Carrot e06/.comicredr.crdb')?.contentKey, keys[1]);
  });

  test('export keeps two books at the same place in two library folders apart', () async {
    final a = writeBook(dir('A/Comics'), 'X.cbz', 3);
    final b = writeBook(dir('B/Manga'), 'X.cbz', 4);
    final store = phone.library;
    await store.addRoot(p.dirname(a));
    await store.addRoot(p.dirname(b));
    await LibraryScanner(
      store,
      coverDir: '${tmp.path}/covers',
      workers: 1,
      onBookRead: (path, key, {required folder}) => phone.sync.attach(path, key, folder: folder),
    ).scan();
    final keys = [await contentKey(a), await contentKey(b)];
    expect(keys[0], isNot(keys[1]));

    final out = '${tmp.path}/export';
    expect(await phone.sync.exportAll(out), 2);
    expect(readSidecar('$out/Comics/.X.cbz.crdb')?.contentKey, keys[0]);
    expect(readSidecar('$out/Manga/.X.cbz.crdb')?.contentKey, keys[1]);
  });

  test('sidecar files are recognised for the folder watch to ignore', () {
    expect(isSidecarFile('/c/.Daredevil.cbz.crdb'), isTrue);
    expect(isSidecarFile('/c/Daredevil.cbz.crdb'), isTrue, reason: 'the old visible name');
    expect(isSidecarFile('/c/.Daredevil.cbz.crdb.tmp'), isTrue);
    expect(isSidecarFile('/c/Preacher/.comicredr.crdb'), isTrue);
    expect(isSidecarFile('/c/Daredevil.cbz'), isFalse);
  });

  test('a sidecar from a newer app is read but never written over', () async {
    final path = writeBook(dir('x'), 'A.cbz', 2);
    final key = await contentKey(path);
    await laptop.sync.attach(path, key, folder: false);
    await laptop.sync.write(key);
    final side = File(hidden(path));
    // Pretend a later version wrote it.
    sqlite3.open(side.path)
      ..execute('UPDATE meta SET schema_version = 99')
      ..close();
    final stamp = side.lastModifiedSync();
    await laptop.marks.save(key, 'c', 1, 0);
    await laptop.sync.write(key);
    expect(side.lastModifiedSync(), stamp);
    expect(readSidecar(side.path)?.schemaVersion, 99);
  });

  test('a sidecar folder is laid out like the library, by root name', () {
    const roots = [
      (id: 1, path: '/home/me/Comics'),
      (id: 2, path: '/home/me/Comics/Marvel'),
      (id: 3, path: '/mnt/nas/Comics'),
    ];
    String at(String book, {bool folder = false}) =>
        storedSidecarPath(book, folder: folder, dir: '/data/side', roots: roots);
    // The deepest root holding the book names it; two roots called Comics
    // are told apart by id.
    expect(at('/home/me/Comics/Indie/Bride.cbz'), '/data/side/Comics-1/Indie/.Bride.cbz.crdb');
    expect(at('/home/me/Comics/Marvel/DD 181.cbz'), '/data/side/Marvel/.DD 181.cbz.crdb');
    expect(at('/mnt/nas/Comics/Pepper', folder: true), '/data/side/Comics-3/Pepper/.comicredr.crdb');
    expect(at('/home/me/Comics/Marvel', folder: true), '/data/side/Marvel/.comicredr.crdb');
    // A book opened from outside the library keeps its full path.
    expect(at('/tmp/Loose.pdf'), '/data/side/elsewhere/tmp/.Loose.pdf.crdb');
    // One root: its own name, no id.
    expect(
      storedSidecarPath('/a/Comics/x.cbz', folder: false, dir: '/s', roots: const [(id: 7, path: '/a/Comics')]),
      '/s/Comics/.x.cbz.crdb',
    );
  });

  test('with a sidecar folder nothing is written beside the comics, and another install reads it', () async {
    final root = dir('Comics');
    final path = writeBook(dir('Comics/Indie'), 'Barefoot Bride.cbz', 3);
    final key = await contentKey(path);
    await laptop.library.addRoot(root.path);
    laptop.store = '${tmp.path}/side';
    await laptop.sync.attach(path, key, folder: false);
    await laptop.marks.addBookmark(key, 2, null);
    expect(await laptop.sync.write(key), isTrue);
    expect(File(hidden(path)).existsSync(), isFalse);
    final stored = '${tmp.path}/side/Comics/Indie/.Barefoot Bride.cbz.crdb';
    expect(readSidecar(stored)?.contentKey, key);
    expect(await laptop.sync.sidecarsOf(path, folder: false), [stored, hidden(path)]);

    // The phone keeps its comics elsewhere but syncs the same folder.
    final there = writeBook(dir('phone/Comics/Indie'), 'Barefoot Bride.cbz', 3);
    await phone.library.addRoot('${tmp.path}/phone/Comics');
    phone.store = '${tmp.path}/side';
    expect((await phone.sync.attach(there, key, folder: false)).found, isTrue);
    expect((await phone.bookmarks(key)).single.page, 2);
  });

  test('with a sidecar folder, one left beside the comic is still read and merged', () async {
    final root = dir('Comics');
    final path = writeBook(root, 'Swamp Thing 21.cbz', 3);
    final key = await contentKey(path);
    // Written beside the comic first, as before the setting.
    await laptop.sync.attach(path, key, folder: false);
    await laptop.marks.addBookmark(key, 1, null);
    await laptop.sync.write(key);
    expect(File(hidden(path)).existsSync(), isTrue);

    await phone.library.addRoot(root.path);
    phone.store = '${tmp.path}/side';
    await phone.sync.attach(path, key, folder: false);
    expect((await phone.bookmarks(key)).single.page, 1);
    await phone.marks.save(key, 'q', 2, 0);
    expect(await phone.sync.write(key), isTrue);
    final stored = readSidecar('${tmp.path}/side/Comics/.Swamp Thing 21.cbz.crdb')!;
    expect(stored.bookmarks.map((b) => (b.page, b.mark)).toSet(), {(1, null), (2, 'q')});
  });

  test('a comic renamed in the library finds its sidecar in the sidecar folder', () async {
    final root = dir('Comics');
    final path = writeBook(root, 'dd181.cbz', 3);
    final key = await contentKey(path);
    await laptop.library.addRoot(root.path);
    laptop.store = '${tmp.path}/side';
    await laptop.sync.attach(path, key, folder: false);
    await laptop.marks.save(key, 'a', 2, 0);
    await laptop.sync.write(key);

    final renamed = '${root.path}/Daredevil 181.cbz';
    File(path).renameSync(renamed);
    await phone.library.addRoot(root.path);
    phone.store = '${tmp.path}/side';
    expect((await phone.sync.attach(renamed, key, folder: false)).found, isTrue);
    expect(await phone.marks.load(key), {'a': (page: 2, panel: 0)});
    expect(File('${tmp.path}/side/Comics/.Daredevil 181.cbz.crdb').existsSync(), isTrue);
    expect(File('${tmp.path}/side/Comics/.dd181.cbz.crdb').existsSync(), isFalse);
  });

  test('switching places moves the sidecars there and back, when asked', () async {
    final root = dir('Comics');
    final cbz = writeBook(dir('Comics/Indie'), 'Barefoot Bride.cbz', 3);
    final folder = dir('Comics/Pepper Carrot e06');
    for (var i = 1; i <= 2; i++) {
      File('${folder.path}/p$i.png').writeAsBytesSync([...png, i]);
    }
    await laptop.library.addRoot(root.path);
    await LibraryScanner(
      laptop.library,
      coverDir: '${tmp.path}/covers',
      workers: 1,
      onBookRead: (path, key, {required folder}) => laptop.sync.attach(path, key, folder: folder),
    ).scan();
    for (final b in await laptop.library.books()) {
      await laptop.marks.addBookmark(b.key, 1, null);
      expect(await laptop.sync.write(b.key), isTrue);
    }
    final side = '${tmp.path}/side';
    File(hidden(cbz)).renameSync('$cbz.crdb'); // Left by an older app: counted and moved too.
    expect(await laptop.sync.countIn(null), 2);
    expect(await laptop.sync.countIn(side), 0);

    expect(await laptop.sync.moveAll(from: null, to: side), 2);
    expect(File(hidden(cbz)).existsSync(), isFalse);
    expect(File('$cbz.crdb').existsSync(), isFalse);
    expect(File('${folder.path}/.comicredr.crdb').existsSync(), isFalse);
    expect(File('$side/Comics/Indie/.Barefoot Bride.cbz.crdb').existsSync(), isTrue);
    expect(File('$side/Comics/Pepper Carrot e06/.comicredr.crdb').existsSync(), isTrue);

    // Meanwhile another install wrote one beside the CBZ: moving back
    // merges the two.
    final key = (await laptop.library.books()).firstWhere((b) => b.format == 'cbz').key;
    await phone.sync.attach(cbz, key, folder: false);
    await phone.marks.save(key, 'z', 2, 0);
    expect(await phone.sync.write(key), isTrue);

    expect(await laptop.sync.moveAll(from: side, to: null), 2);
    expect(readSidecar(hidden(cbz))?.bookmarks.map((b) => b.mark).toSet(), {null, 'z'});
    expect(await laptop.sync.countIn(side), 0);
  });

  test('a reset clears the sidecar in the sidecar folder and the one beside the comic', () async {
    final root = dir('Comics');
    final path = writeBook(root, 'Swamp Thing 21.cbz', 3);
    final key = await contentKey(path);
    await laptop.library.addRoot(root.path);
    await laptop.sync.attach(path, key, folder: false);
    await laptop.marks.addBookmark(key, 1, null);
    await laptop.sync.write(key); // Beside, before the setting.
    laptop.store = '${tmp.path}/side';
    await laptop.marks.addBookmark(key, 2, null);
    await laptop.sync.write(key);
    final stored = '${tmp.path}/side/Comics/.Swamp Thing 21.cbz.crdb';
    expect(readSidecar(stored)!.bookmarks, hasLength(2));

    expect(await laptop.sync.reset(key, everything: true), isTrue);
    for (final at in [stored, hidden(path)]) {
      expect(readSidecar(at)?.bookmarks.where((b) => b.deletedAt == null) ?? [], isEmpty, reason: at);
    }
  });
}
