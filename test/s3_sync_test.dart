import 'dart:io';

import 'package:comic_formats/comic_formats.dart';
import 'package:comic_sync/comic_sync.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/progress_store.dart';
import 'package:comicredr/src/data/s3_settings.dart';
import 'package:comicredr/src/data/s3_sync.dart';
import 'package:comicredr/src/data/secret_store.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/data/sidecar.dart';
import 'package:comicredr/src/data/sidecar_sync.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/scanner.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// One install: its own index, library folder, covers and sidecars, all
/// meeting the other through one bucket.
class Device {
  Device(this.name, Directory tmp, this.bucket)
    : db = AppDatabase(NativeDatabase.memory()),
      root = Directory('${tmp.path}/$name/Comics')..createSync(recursive: true),
      covers = '${tmp.path}/$name/covers' {
    progress = ProgressStore(db, debounce: Duration.zero);
    sidecars = SidecarSync(db, progress: progress, debounce: Duration.zero, coverDir: covers);
    store = LibraryStore(db);
    scanner = LibraryScanner(
      store,
      coverDir: covers,
      workers: 1,
      onBookRead: (path, key, {required folder}) => sidecars.attach(path, key, folder: folder),
    );
    s3 = S3Sync(
      db,
      sidecars: sidecars,
      settings: S3Settings(SettingsStore(db), secrets),
      storeFor: (_) => bucket,
      coverDir: covers,
      onDownloaded: scanner.scan,
      pushDelay: const Duration(hours: 1),
    );
    sidecars.onWritten = (key) => s3.sidecarWritten(key);
  }

  final String name;
  final MemoryStore bucket;
  final AppDatabase db;
  final Directory root;
  final String covers;
  final secrets = MemorySecretStore();
  late final ProgressStore progress;
  late final SidecarSync sidecars;
  late final LibraryStore store;
  late final LibraryScanner scanner;
  late final S3Sync s3;
  final notices = <String>[];

  Future<void> setUp() async {
    s3.notices.listen(notices.add);
    await store.addRoot(root.path);
    await S3Settings(
      SettingsStore(db),
      secrets,
    ).save(S3Config(endpoint: Uri.parse('http://garage.lan:3900'), bucket: 'comics', accessKey: 'GK1', secretKey: 's'));
  }

  Future<LibraryBook> book(String key) async => (await store.books()).singleWhere((b) => b.key == key);

  /// Reads to [page] and closes the book, as the reader does.
  Future<void> readTo(String key, int page, int pages) async {
    progress.save(key, ReadingPosition(page: page), pages);
    await progress.flush();
    await sidecars.flush();
    await sidecars.write(key);
  }

  Future<void> close() async {
    await s3.dispose();
    await db.close();
  }
}

void main() {
  late Directory tmp;
  late MemoryStore bucket;
  late Device laptop, phone;

  // Two devices, two in-memory indexes.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('s3_sync_test');
    bucket = MemoryStore();
    laptop = Device('laptop', tmp, bucket);
    phone = Device('phone', tmp, bucket);
    await laptop.setUp();
    await phone.setUp();
  });
  tearDown(() async {
    await laptop.close();
    await phone.close();
    tmp.deleteSync(recursive: true);
  });

  test('a comic goes up with its sidecar, the manifest last, and shows as on S3', () async {
    final path = writeBook(Directory('${laptop.root.path}/Golden Age')..createSync(), 'Weird Comics 4.cbz', 6);
    await laptop.scanner.scan();
    final key = await contentKey(path);
    await laptop.readTo(key, 3, 6);

    expect(await laptop.s3.upload([key]), 1);
    await laptop.s3.drain();

    final o = BookObjects('Comics/', key);
    expect(bucket.objects.keys, containsAll([o.manifest, o.comic('cbz'), o.cover, o.sidecar]));
    final m = Manifest.decode(String.fromCharCodes(bucket.objects[o.manifest]!.bytes))!;
    expect((m.folder, m.fileName, m.size), ('Golden Age', 'Weird Comics 4.cbz', File(path).lengthSync()));
    final side = await laptop.sidecars.sidecarFor(path, folder: false);
    expect(bucket.objects[o.sidecar]!.metadata[writtenAtMeta], '${sidecarWrittenAt(side)}');
    expect((await laptop.book(key)).s3?.mark, S3Mark.synced);
    await pumpEventQueue();
    expect(laptop.notices, contains('Uploaded Weird Comics #4 to S3'));
  });

  test('laptop to phone and back: the position follows, newest sidecar wins', () async {
    final path = writeBook(Directory('${laptop.root.path}/Golden Age')..createSync(), 'Weird Comics 4.cbz', 8);
    await laptop.scanner.scan();
    final key = await contentKey(path);
    await laptop.readTo(key, 3, 8);
    await laptop.s3.upload([key]);
    await laptop.s3.drain();

    // The phone sees it with its cover, on S3 only, where it would go.
    await phone.s3.refreshShelf();
    var remote = await phone.book(key);
    expect(remote.remoteOnly, isTrue);
    expect(remote.path, '${phone.root.path}/Golden Age/Weird Comics 4.cbz');
    expect(File('${phone.covers}/$key.jpg').existsSync(), isTrue);

    // Downloaded by hand: the file, its sidecar, and the laptop's place.
    expect(await phone.s3.download(key), remote.path);
    remote = await phone.book(key);
    expect((remote.remoteOnly, remote.s3?.mark, remote.page), (false, S3Mark.synced, 3));

    // The phone reads on, later (the index keeps whole seconds); its
    // sidecar is the newest and goes up.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await phone.readTo(key, 6, 8);
    expect((await phone.book(key)).s3?.mark, S3Mark.waiting);
    await phone.s3.drain();
    expect((await phone.book(key)).s3?.mark, S3Mark.synced);

    // The laptop opens it: the phone's sidecar replaces its own, and the
    // phone's place is offered.
    expect(await laptop.s3.pullOnOpen(key), isTrue);
    final back = await laptop.sidecars.attach(path, key, folder: false);
    expect(back.elsewhere?.page, 6);
    // Its own place is kept until the offer is taken.
    expect((await laptop.book(key)).page, 3);
    // In step now: nothing more to fetch.
    expect(await laptop.s3.pullOnOpen(key), isFalse);
  });

  test('with the bucket off, changes wait and go up when it is back', () async {
    final path = writeBook(laptop.root, 'Pep.cbz', 4);
    await laptop.scanner.scan();
    final key = await contentKey(path);
    await laptop.s3.upload([key]);
    await laptop.s3.drain();

    bucket.reachable = false;
    await laptop.readTo(key, 2, 4);
    await laptop.s3.drain();
    expect(laptop.s3.current.reach, S3Reach.unreachable);
    expect(laptop.s3.current.waiting, 1);
    await pumpEventQueue();
    expect(laptop.notices.where((n) => n.contains('out of reach')), hasLength(1));
    // Opening while it is off never waits for it.
    expect(await laptop.s3.pullOnOpen(key), isFalse);

    bucket.reachable = true;
    await laptop.s3.drain();
    expect(laptop.s3.current.waiting, 0);
    await pumpEventQueue();
    expect(laptop.notices.last, 'S3 is back; 1 comic caught up');
    final side = await laptop.sidecars.sidecarFor(path, folder: false);
    expect(bucket.objects[BookObjects('Comics/', key).sidecar]!.metadata[writtenAtMeta], '${sidecarWrittenAt(side)}');
  });

  test('remove from S3 keeps the comic here; a comic removed elsewhere loses its badge', () async {
    final path = writeBook(laptop.root, 'Pep.cbz', 4);
    await laptop.scanner.scan();
    final key = await contentKey(path);
    await laptop.s3.upload([key]);
    await laptop.s3.drain();
    await phone.s3.refreshShelf();
    expect((await phone.book(key)).remoteOnly, isTrue);

    await laptop.s3.removeFromS3([key]);
    await laptop.s3.drain();
    expect(bucket.objects.keys.where((k) => k.contains(key)), isEmpty);
    expect(File(path).existsSync(), isTrue);
    expect((await laptop.book(key)).s3, isNull);

    // The phone's entry for it goes at the next look.
    await phone.s3.refreshShelf();
    expect((await phone.store.books()).where((b) => b.key == key), isEmpty);
  });

  test('a sidecar change for a comic removed from S3 elsewhere is not put back', () async {
    final path = writeBook(laptop.root, 'Pep.cbz', 4);
    await laptop.scanner.scan();
    final key = await contentKey(path);
    await laptop.s3.upload([key]);
    await laptop.s3.drain();
    await removeFromShelf(bucket, BookObjects('Comics/', key));

    await laptop.readTo(key, 1, 4);
    await laptop.s3.drain();
    expect(bucket.objects, isEmpty);
    expect((await laptop.book(key)).s3, isNull);
  });

  test('a folder book goes up file by file and comes down with the same key', () async {
    final dir = Directory('${laptop.root.path}/Pepper')..createSync();
    for (final (i, name) in ['p1.png', 'p2.png', 'sub/p3.png'].indexed) {
      File('${dir.path}/$name')
        ..createSync(recursive: true)
        ..writeAsBytesSync([...png, i]);
    }
    await laptop.scanner.scan();
    final key = await contentKey(dir.path);
    await laptop.s3.upload([key]);
    await laptop.s3.drain();
    final o = BookObjects('Comics/', key);
    expect(bucket.objects.keys, containsAll([o.file('p1.png'), o.file('sub/p3.png')]));

    await phone.s3.refreshShelf();
    final got = await phone.s3.download(key);
    expect(got, '${phone.root.path}/Pepper');
    expect(await contentKey(got!), key);
  });
}
