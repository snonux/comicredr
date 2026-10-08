import 'dart:io';
import 'dart:typed_data';

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

  /// The ones among [notices] said as failures, which the app keeps up.
  final failures = <String>[];

  Future<void> setUp() async {
    s3.notices.listen((n) {
      notices.add(n.text);
      if (n.failure) failures.add(n.text);
    });
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
  late RefusingStore bucket;
  late Device laptop, phone;

  // Two devices, two in-memory indexes.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('s3_sync_test');
    bucket = RefusingStore();
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
    // The index knows which sidecar of the bucket it has: the one fetched.
    final shelf = (await phone.db.select(phone.db.s3Books).get()).singleWhere((r) => r.contentKey == key);
    final inBucket = bucket.objects[BookObjects('Comics/', key).sidecar]!.metadata[writtenAtMeta]!;
    expect(shelf.sidecarAt, int.parse(inBucket));

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
    // Out of reach is a failure to read; uploaded and back are routine.
    expect(laptop.failures, [contains('out of reach')]);
    expect(laptop.notices.length, greaterThan(laptop.failures.length));
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

  group('what the sync says', () {
    /// [n] comics put on S3 by the laptop and seen there by the phone;
    /// their keys.
    Future<List<String>> shelved(int n, {String folder = ''}) async {
      final dir = Directory('${laptop.root.path}/$folder')..createSync(recursive: true);
      final keys = <String>[];
      for (var i = 1; i <= n; i++) {
        writeBook(dir, 'Pep $i.cbz', i);
      }
      await laptop.scanner.scan();
      for (var i = 1; i <= n; i++) {
        keys.add(await contentKey('${dir.path}/Pep $i.cbz'));
      }
      await laptop.s3.upload(keys);
      await laptop.s3.drain();
      await phone.s3.refreshShelf();
      await pumpEventQueue();
      laptop.notices.clear();
      laptop.failures.clear();
      return keys;
    }

    test('marked downloads with the bucket off: one notice for them all, the rest not tried', () async {
      final keys = await shelved(5);
      bucket.reachable = false;
      await phone.s3.downloadAll(keys);
      await pumpEventQueue();
      expect(phone.notices, [
        allOf(contains('is out of reach'), contains('saving on this device')),
        'S3 is out of reach: 5 comics can be downloaded when it is back',
      ]);
      expect(phone.failures, phone.notices);
      // One alone is named.
      phone.notices.clear();
      phone.failures.clear();
      await phone.s3.download(keys.first);
      await phone.s3.downloadAll([keys.last]);
      await pumpEventQueue();
      expect(phone.notices, [
        'S3 is out of reach: Pep #1 can be downloaded when it is back',
        'S3 is out of reach: Pep #5 can be downloaded when it is back',
      ]);
      expect(phone.failures, phone.notices);
    });

    test('the bucket going off part of the way: the ones left are counted', () async {
      final keys = await shelved(4);
      bucket.offAfter = 2;
      await phone.s3.downloadAll(keys);
      await pumpEventQueue();
      expect(phone.notices.where((n) => n.startsWith('Downloaded ')), hasLength(2));
      expect(phone.notices.last, 'S3 is out of reach: 2 comics can be downloaded when it is back');
      expect(phone.failures, hasLength(2));
      // The two that came are on disk, and no third comic.
      expect(filesUnder(phone.root).where((f) => f.endsWith('.cbz')), ['Pep 1.cbz', 'Pep 2.cbz']);
    });

    test('a download cut off part of the way keeps nothing of the comic', () async {
      // A folder book with one page here and the bucket off at the second.
      final dir = Directory('${laptop.root.path}/Pepper')..createSync();
      for (final (i, name) in ['p1.png', 'p2.png', 'sub/p3.png'].indexed) {
        File('${dir.path}/$name')
          ..createSync(recursive: true)
          ..writeAsBytesSync([...png, i]);
      }
      final keys = await shelved(1);
      final folder = await contentKey(dir.path);
      await laptop.s3.upload([folder]);
      await laptop.s3.drain();
      await phone.s3.refreshShelf();
      bucket.offAt = '/files/p2.png';
      expect(await phone.s3.download(folder), isNull);
      expect(bucket.reachable, isFalse);
      expect(Directory('${phone.root.path}/Pepper').existsSync(), isFalse);
      expect(filesUnder(phone.root), isEmpty);

      // A comic that came whole, and the bucket off when its sidecar is asked for.
      bucket
        ..reachable = true
        ..offAt = '/sidecar.crdb';
      expect(await phone.s3.download(keys.single), isNull);
      expect(bucket.reachable, isFalse);
      expect(filesUnder(phone.root), isEmpty);
      await pumpEventQueue();
      expect(phone.failures.last, 'S3 is out of reach: Pep #1 can be downloaded when it is back');
    });

    test('marked downloads without a library folder: said once', () async {
      final keys = await shelved(3);
      await phone.store.removeRoot((await phone.db.select(phone.db.roots).get()).single.id);
      await phone.s3.refreshShelf();
      await phone.s3.downloadAll(keys);
      await pumpEventQueue();
      expect(phone.notices, ['Add a library folder first: downloads go into it']);
      expect(phone.failures, phone.notices);
    });

    test('a refusal that is not about one comic does not stop a batch, and is a failure', () async {
      final keys = await shelved(2);
      bucket.refuse = 'Access denied';
      await phone.s3.downloadAll(keys);
      await pumpEventQueue();
      expect(phone.notices, ['Could not download Pep #1: Access denied', 'Could not download Pep #2: Access denied']);
      expect(phone.failures, phone.notices);
    });

    test('refused keys are said once a drain, however many comics wait', () async {
      for (var i = 1; i <= 3; i++) {
        writeBook(laptop.root, 'Pep $i.cbz', i);
      }
      await laptop.scanner.scan();
      final keys = [for (final b in await laptop.store.books()) b.key];
      bucket.refuse = 'Access denied';
      expect(await laptop.s3.upload(keys), 3);
      await laptop.s3.drain();
      await pumpEventQueue();
      expect(laptop.notices, ['S3: Access denied']);
      expect(laptop.failures, laptop.notices);
      expect(laptop.s3.current.waiting, 3);
      // The next drain tries them again and says it once more.
      await laptop.s3.drain();
      await pumpEventQueue();
      expect(laptop.notices, ['S3: Access denied', 'S3: Access denied']);
    });

    test('a download that does not match, or cannot be written, is a failure', () async {
      final keys = await shelved(2, folder: 'Sub');
      await truncate(bucket, BookObjects('Comics/', keys[0]).comic('cbz'));
      expect(await phone.s3.download(keys[0]), isNull);
      // "Nothing was kept": the comic that came is gone again.
      expect(filesUnder(phone.root), isEmpty);
      // A file where the comic's folder would be.
      final sub = Directory('${phone.root.path}/Sub');
      if (sub.existsSync()) sub.deleteSync(recursive: true);
      File('${phone.root.path}/Sub').writeAsStringSync('in the way');
      expect(await phone.s3.download(keys[1]), isNull);
      expect(filesUnder(phone.root), ['Sub']);
      await pumpEventQueue();
      expect(phone.notices, [
        'The download of Pep #1 did not match what was uploaded; nothing was kept',
        startsWith('Could not download Pep #2: '),
      ]);
      expect(phone.failures, phone.notices);
    });

    test('what worked is no failure: uploaded, downloaded, on S3 already, removed, back', () async {
      final keys = await shelved(1);
      await phone.s3.download(keys.single);
      await phone.s3.upload(keys);
      await phone.s3.drain();
      await phone.s3.removeFromS3(keys);
      await phone.s3.drain();
      bucket.reachable = false;
      await phone.s3.upload(keys);
      await phone.s3.drain();
      bucket.reachable = true;
      await phone.s3.drain();
      await pumpEventQueue();
      expect(phone.notices, [
        'Downloaded Pep #1',
        'Pep #1 was on S3 already; its newest sidecar is on both',
        'Removed Pep #1 from S3',
        contains('is out of reach; saving on this device'),
        'Uploaded Pep #1 to S3',
        'S3 is back; 1 comic caught up',
      ]);
      expect(phone.failures, [contains('is out of reach; saving on this device')]);
    });
  });

  group('a comic that is on S3 already', () {
    late String key, laptopPath, phonePath;
    late BookObjects o;

    // The laptop uploaded it and read to page 3; the phone has its own
    // copy of the same file, never synced.
    setUp(() async {
      laptopPath = writeBook(laptop.root, 'Weird Comics 4.cbz', 8);
      await laptop.scanner.scan();
      key = await contentKey(laptopPath);
      await laptop.readTo(key, 3, 8);
      await laptop.s3.upload([key]);
      await laptop.s3.drain();
      o = BookObjects('Comics/', key);
      phonePath = File(laptopPath).copySync('${phone.root.path}/Weird Comics 4.cbz').path;
      await phone.scanner.scan();
      await phone.s3.refreshShelf();
    });

    test('is not sent again, and the newer bucket sidecar comes in', () async {
      final comic = bucket.objects[o.comic('cbz')]!.bytes;
      final manifest = bucket.objects[o.manifest]!.bytes;
      expect(await phone.s3.upload([key]), 1);
      await phone.s3.drain();

      expect(identical(bucket.objects[o.comic('cbz')]!.bytes, comic), isTrue);
      expect(identical(bucket.objects[o.manifest]!.bytes, manifest), isTrue);
      // The laptop's sidecar replaced the phone's, and its place came with it.
      final side = await phone.sidecars.sidecarFor(phonePath, folder: false);
      expect('${sidecarWrittenAt(side)}', bucket.objects[o.sidecar]!.metadata[writtenAtMeta]);
      expect((await phone.book(key)).page, 3);
      expect((await phone.book(key)).s3?.mark, S3Mark.synced);
      await pumpEventQueue();
      expect(phone.notices.last, 'Weird Comics #4 was on S3 already; its newest sidecar is on both');
    });

    test('a newer sidecar here goes up instead', () async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await phone.readTo(key, 6, 8);
      await phone.s3.drain();
      await phone.s3.upload([key]);
      await phone.s3.drain();
      final side = await phone.sidecars.sidecarFor(phonePath, folder: false);
      expect(bucket.objects[o.sidecar]!.metadata[writtenAtMeta], '${sidecarWrittenAt(side)}');
      expect(await laptop.s3.pullOnOpen(key), isTrue);
      expect((await laptop.sidecars.attach(laptopPath, key, folder: false)).elsewhere?.page, 6);
    });

    test('a comic of another size in the bucket is sent again', () async {
      final broken = await truncate(bucket, o.comic('cbz'));
      await phone.s3.upload([key]);
      await phone.s3.drain();
      expect(bucket.objects[o.comic('cbz')]!.bytes.length, File(phonePath).lengthSync());
      expect(bucket.objects[o.comic('cbz')]!.bytes.length, isNot(broken));
    });
  });
}

/// Every file under [dir], sidecars too, as sorted paths from it.
List<String> filesUnder(Directory dir) =>
    [for (final f in dir.listSync(recursive: true).whereType<File>()) f.path.substring(dir.path.length + 1)]..sort();

/// Cuts the object at [name] short, as an upload that broke off would
/// leave it; returns its new length.
Future<int> truncate(MemoryStore bucket, String name) async {
  final was = bucket.objects[name]!;
  bucket.objects[name] = (bytes: was.bytes.sublist(0, was.bytes.length ~/ 2), metadata: was.metadata);
  return bucket.objects[name]!.bytes.length;
}

/// A bucket that can also refuse (wrong keys), and go off after so many
/// comics were fetched or when one object is asked for.
class RefusingStore extends MemoryStore {
  /// What every call is refused with; null for a bucket that answers.
  String? refuse;

  /// Downloads still answered before the bucket goes out of reach; null
  /// for no such end.
  int? offAfter;

  /// The bucket goes out of reach when an object whose name has this in
  /// it is asked for or about; null for no such end.
  String? offAt;

  void _offAt(String key) {
    if (offAt case final part? when key.contains(part)) reachable = false;
  }

  void _refused() {
    if (refuse case final why?) throw RemoteException(RemoteFailure.denied, why);
  }

  @override
  Future<void> put(
    String key,
    Stream<Uint8List> bytes, {
    required int size,
    Map<String, String> metadata = const {},
    void Function(int sent)? onProgress,
  }) {
    _refused();
    return super.put(key, bytes, size: size, metadata: metadata, onProgress: onProgress);
  }

  @override
  Future<RemoteObject?> head(String key) {
    _refused();
    _offAt(key);
    return super.head(key);
  }

  @override
  Future<bool> download(String key, IOSink sink, {void Function(int received)? onProgress}) {
    _refused();
    _offAt(key);
    if (offAfter case final left? when key.contains('/comic.')) {
      if (left == 0) reachable = false;
      offAfter = left - 1;
    }
    return super.download(key, sink, onProgress: onProgress);
  }
}
