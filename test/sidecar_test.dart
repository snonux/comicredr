import 'dart:io';

import 'package:comic_analysis/comic_analysis.dart';
import 'package:comic_formats/comic_formats.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/panel_store.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:comicredr/src/reader/panel_detector.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/fixtures.dart';

/// One install of the app: its own index and its own sidecar sync.
class Device {
  Device() : db = AppDatabase(NativeDatabase.memory()) {
    progress = ProgressStore(db, debounce: Duration.zero);
    sync = SidecarSync(db, progress: progress, debounce: Duration.zero);
  }

  final AppDatabase db;
  late final ProgressStore progress;
  late final SidecarSync sync;
  PanelStore get panels => PanelStore(db);
  MarkStore get marks => MarkStore(db);
  LibraryStore get library => LibraryStore(db);

  Future<List<BookmarkInfo>> bookmarks(String key) => library.watchBookmarks(key).first;
}

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
    expect(File('$path.crdb').existsSync(), isTrue);

    // Copied to the phone, and renamed on the way without its sidecar.
    final there = '${dir('phone').path}/dd-181.cbz';
    File(path).copySync(there);
    File('$path.crdb').copySync('${dir('phone').path}/Daredevil 181 (1982).cbz.crdb');

    final got = await phone.sync.attach(there, key, folder: false);
    expect(got.found, isTrue);
    expect(File('$there.crdb').existsSync(), isTrue, reason: 'the orphan is re-linked by content key');
    expect(File('${dir('phone').path}/Daredevil 181 (1982).cbz.crdb').existsSync(), isFalse);

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
    expect(readSidecar('$path.crdb')!.progress, hasLength(2));
  });

  test('a removed bookmark stays removed when an older copy comes back', () async {
    final (path, key) = await readOnLaptop();
    final old = '${tmp.path}/old.crdb';
    File('$path.crdb').copySync(old);

    final mm = (await laptop.bookmarks(key)).firstWhere((b) => b.mark == null);
    await laptop.library.deleteBookmark(mm.id);
    await laptop.sync.write(key);

    File(old).copySync('$path.crdb'); // The phone's stale copy, copied back.
    await laptop.sync.attach(path, key, folder: false);
    expect((await laptop.bookmarks(key)).where((b) => b.mark == null), isEmpty);
    await laptop.sync.write(key);
    expect(readSidecar('$path.crdb')!.bookmarks.where((b) => b.mark == null).single.deletedAt, isNotNull);
  });

  test('a folder that refuses the sidecar keeps everything in the index', () async {
    final path = writeBook(dir('share'), 'Swamp Thing 21.cbz', 3);
    final key = await contentKey(path);
    Directory('$path.crdb').createSync(); // Something in the way that cannot be replaced.
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
    expect(readSidecar('$out/Indie/Barefoot Bride.cbz.crdb')?.contentKey, keys[0]);
    expect(readSidecar('$out/Pepper Carrot e06/.comicredr.crdb')?.contentKey, keys[1]);
  });

  test('sidecar files are recognised for the folder watch to ignore', () {
    expect(isSidecarFile('/c/Daredevil.cbz.crdb'), isTrue);
    expect(isSidecarFile('/c/.Daredevil.cbz.crdb.tmp'), isTrue);
    expect(isSidecarFile('/c/Preacher/.comicredr.crdb'), isTrue);
    expect(isSidecarFile('/c/Daredevil.cbz'), isFalse);
  });

  test('a sidecar from a newer app is read but never written over', () async {
    final path = writeBook(dir('x'), 'A.cbz', 2);
    final key = await contentKey(path);
    await laptop.sync.attach(path, key, folder: false);
    await laptop.sync.write(key);
    final side = File('$path.crdb');
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
}
