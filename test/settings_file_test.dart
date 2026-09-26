import 'dart:convert';
import 'dart:io';

import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_file.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/input/touch_providers.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/settings_transfer.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_notifier.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_input/reader_input.dart';

/// Settings → Export settings and Import settings (SettingsFile): the
/// round trip with every setting changed, what a file must be to be taken,
/// what it may have that this version does not know, and the merge.
void main() {
  late Directory tmp;
  late AppDatabase from;
  late AppDatabase to;

  // Two in-memory databases, each its own executor: an install and a fresh one.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('settings_file');
    from = AppDatabase(NativeDatabase.memory());
    to = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await from.close();
    await to.close();
    await tmp.delete(recursive: true);
  });

  Future<Directory> dir(String name) => Directory(p.join(tmp.path, name)).create(recursive: true);

  // Seconds, as the index stores times.
  final t0 = DateTime(2026, 9, 20, 10, 30, 15);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

  /// Every setting at a value other than its default.
  Future<Map<String, Object>> changedSettings() async => {
    SettingsStore.wholePageSteps: false,
    SettingsStore.pauseWhole: false,
    SettingsStore.night: true,
    SettingsStore.autoTrim: true,
    SettingsStore.fullscreen: true,
    SettingsStore.cleanUp: true,
    SettingsStore.writeSidecars: false,
    SettingsStore.sidecarDir: (await dir('Stash')).path,
    SettingsStore.gridZoom: '212.5',
    SettingsStore.shuffle: true,
    SettingsStore.touchPreset: 'oneThumb',
  };

  /// A full install in [from]: settings, device, two library folders and a
  /// row of every kind, a removed bookmark and collection among them.
  Future<void> fill() async {
    final settings = SettingsStore(from);
    for (final MapEntry(:key, :value) in (await changedSettings()).entries) {
      value is bool ? await settings.saveBool(key, value) : await settings.saveString(key, value as String);
    }
    // This device's own ~/Comics taken out: not for another device to act on.
    await settings.saveBool(SettingsStore.defaultFolderRemoved, true);
    await from.batch((b) {
      b.insertAll(from.settings, [
        SettingRow(key: 'device.id', value: jsonEncode('laptop')),
        SettingRow(key: 'device.name', value: jsonEncode('Laptop')),
        SettingRow(key: 'someday.setting', value: jsonEncode(1)),
      ]);
    });
    await LibraryStore(from).addRoot((await dir('Comics')).path);
    await LibraryStore(from).addRoot((await dir('Manga')).path);
    await from.batch((b) {
      b.insertAll(from.progress, [
        ProgressData(
          contentKey: 'a',
          page: 7,
          panel: 3,
          percent: 0.5,
          finished: false,
          updatedAt: at(1),
          viewJson: '{"balloon":1,"guided":true,"spread":false,"rotation":1}',
        ),
        ProgressData(contentKey: 'b', page: 20, percent: 1, finished: true, updatedAt: at(2)),
      ]);
      b.insertAll(from.bookmarks, [
        Bookmark(id: 'bm1', contentKey: 'a', page: 2, panel: 1, note: 'the splash', createdAt: at(3)),
        Bookmark(id: 'bm2', contentKey: 'a', page: 5, mark: 'q', createdAt: at(4)),
        Bookmark(id: 'bm3', contentKey: 'b', page: 1, createdAt: at(5), deletedAt: at(6)),
      ]);
      b.insertAll(from.collectionBooks, [
        CollectionBook(name: 'Favourites', contentKey: 'a', addedAt: at(7)),
        CollectionBook(name: 'Moore', contentKey: 'b', addedAt: at(8), removedAt: at(9)),
      ]);
      b.insertAll(from.overrides, [
        const Override(contentKey: 'a', field: 'series', value: '{"value":"Swamp Thing","at":1790000000000}'),
        const Override(contentKey: 'b', field: 'year', value: '{"value":null,"at":1790000000000,"fromFile":true}'),
      ]);
      b.insertAll(from.readLog, [
        ReadLogData(contentKey: 'a', startedAt: at(10), endedAt: at(20), pages: 12),
        ReadLogData(contentKey: 'b', startedAt: at(30), endedAt: at(31), pages: 2),
      ]);
    });
  }

  Future<Map<String, Object?>> settingsOf(AppDatabase db) async => {
    for (final r in await db.select(db.settings).get()) r.key: jsonDecode(r.value),
  };

  Future<SettingsImport> import(String text, {String? keysPath}) =>
      importSettings(SettingsFile.decode(text), library: LibraryStore(to), keysPath: keysPath);

  test('the test changes every setting a file carries', () async {
    expect((await changedSettings()).keys.toSet(), SettingsStore.backedUp.keys.toSet());
  });

  test('every setting, folder, keys.toml and row comes back in a fresh install', () async {
    await fill();
    final keys = File(p.join(tmp.path, 'old', 'keys.toml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('[keys]\nnextStep = ["n"]\n');
    final text = await exportSettings(from, keysPath: keys.path, now: at(60));
    final json = jsonDecode(text) as Map<String, Object?>;
    expect(json['app'], 'org.snonux.comicredr');
    expect(json['kind'], 'settings');
    expect(json['format'], settingsFileFormat);
    expect(json['exportedAt'], at(60).toUtc().toIso8601String());
    expect((json['settings']! as Map).keys, isNot(contains(SettingsStore.defaultFolderRemoved)));

    final newKeys = p.join(tmp.path, 'new', 'keys.toml');
    final done = await import(text, keysPath: newKeys);

    final want = await changedSettings();
    expect(await settingsOf(to), want, reason: 'this install keeps its own device id; unknown settings stay out');
    expect(
      [for (final r in await LibraryStore(to).roots()) r.path],
      [p.join(tmp.path, 'Comics'), p.join(tmp.path, 'Manga')],
    );
    expect(File(newKeys).readAsStringSync(), keys.readAsStringSync());
    expect(await to.select(to.progress).get(), unorderedEquals(await from.select(from.progress).get()));
    expect(await to.select(to.bookmarks).get(), unorderedEquals(await from.select(from.bookmarks).get()));
    expect(await to.select(to.collectionBooks).get(), unorderedEquals(await from.select(from.collectionBooks).get()));
    expect(await to.select(to.overrides).get(), unorderedEquals(await from.select(from.overrides).get()));
    expect(await to.select(to.readLog).get(), unorderedEquals(await from.select(from.readLog).get()));

    expect(done.settings, want.length);
    expect(done.foldersAdded, 2);
    expect(done.keysWritten, isTrue);
    expect(done.skipped, 0);
    expect(done.books, {'a', 'b'});
    expect(
      importNotice(done),
      'Imported 11 settings, 2 library folders, keys.toml, 2 positions, 2 bookmarks, 1 collection entry, 2 edits '
      'and 2 history entries.',
    );

    // Exported again, the new install writes the same file.
    expect(await exportSettings(to, keysPath: newKeys, now: at(60)), text);
  });

  test('the defaults go out as nothing and come back as the defaults', () async {
    await SettingsStore(to).saveBool(SettingsStore.night, true);
    await SettingsStore(to).saveString(SettingsStore.touchPreset, 'leftHanded');
    final text = await exportSettings(from);
    expect((jsonDecode(text) as Map)['settings'], isEmpty);
    final done = await import(text);
    expect(await settingsOf(to), isEmpty);
    expect(done.settings, 0);
    expect(importNotice(done), 'Imported the default settings.');
  });

  group('a file that is not one is refused', () {
    Future<String> refusal(Object text) async {
      try {
        SettingsFile.decode(text is String ? text : jsonEncode(text));
      } on SettingsFileException catch (e) {
        return e.message;
      }
      fail('taken: $text');
    }

    final good = {'app': 'org.snonux.comicredr', 'kind': 'settings', 'format': 1};

    test('not JSON', () async {
      expect(await refusal('[keys]\nnextStep = "n"'), 'This is not a ComicRedr settings file: it is not JSON.');
      expect(await refusal(''), contains('not JSON'));
    });

    test('JSON, but not a settings file', () async {
      expect(await refusal([1, 2]), 'This is not a ComicRedr settings file.');
      expect(await refusal({'settings': <String, Object?>{}}), 'This is not a ComicRedr settings file.');
      expect(await refusal({...good, 'app': 7}), 'This is not a ComicRedr settings file.');
      expect(await refusal({...good, 'kind': 'sidecar'}), 'This ComicRedr file is not a settings file.');
      expect(await refusal({...good}..remove('kind')), 'This ComicRedr file is not a settings file.');
    });

    test("another app's", () async {
      expect(await refusal({...good, 'app': 'org.snonux.gallery'}), contains('from another app (org.snonux.gallery)'));
    });

    test('an unknown format', () async {
      expect(await refusal({...good}..remove('format')), 'This settings file has an unknown format (null).');
      expect(await refusal({...good, 'format': 0}), contains('unknown format (0)'));
      expect(await refusal({...good, 'format': '1'}), contains('unknown format (1)'));
      expect(await refusal({...good, 'format': 1.5}), contains('unknown format'));
    });

    test('a newer format', () async {
      expect(
        await refusal({...good, 'format': settingsFileFormat + 1}),
        'This settings file is from a newer ComicRedr (format ${settingsFileFormat + 1}; '
        'this one reads $settingsFileFormat). Update ComicRedr first.',
      );
    });

    test('a bare minimum is taken', () {
      final file = SettingsFile.decode(jsonEncode(good));
      expect(file.settings, isEmpty);
      expect(file.books, isEmpty);
      expect(file.skipped, 0);
    });
  });

  test('what this version does not know is skipped, and the rest imported', () async {
    final text = jsonEncode({
      'app': 'org.snonux.comicredr',
      'kind': 'settings',
      'format': 1,
      'fromTheFuture': {'anything': true},
      'appVersion': 3, // Not a version: left out.
      'settings': {
        SettingsStore.night: true,
        SettingsStore.shuffle: true,
        'reader.hologram': true, // A setting from later.
        SettingsStore.cleanUp: 'yes', // The wrong kind.
        SettingsStore.gridZoom: 'big', // Not a size.
      },
      'libraryFolders': [(await dir('Comics')).path, 42, ''],
      'positions': [
        {'contentKey': 'a', 'page': 3, 'percent': 0.2, 'updatedAt': t0.toUtc().toIso8601String(), 'colour': 'red'},
        {'contentKey': 'b', 'page': 'three'},
        'nonsense',
      ],
      'bookmarks': {'not': 'a list'},
      'collections': [
        {'name': 'Favourites', 'contentKey': 'a', 'addedAt': t0.toIso8601String()},
      ],
      'readingHistory': [
        {'contentKey': 'a', 'startedAt': 'yesterday', 'endedAt': 'today', 'pages': 3},
      ],
      'keysToml': 12,
    });
    final file = SettingsFile.decode(text);
    expect(file.skipped, 3 + 2 + 2 + 1 + 1 + 1, reason: 'settings, folders, positions, bookmarks, history, keys');
    final done = await import(text);
    expect(await settingsOf(to), {SettingsStore.night: true, SettingsStore.shuffle: true});
    expect(done.foldersAdded, 1);
    expect(done.keysWritten, isFalse);
    final pos = await to.select(to.progress).getSingle();
    expect((pos.contentKey, pos.page, pos.panel, pos.finished, pos.updatedAt), ('a', 3, null, false, t0));
    expect((await to.select(to.collectionBooks).getSingle()).name, 'Favourites');
    expect(await to.select(to.bookmarks).get(), isEmpty);
    expect(await to.select(to.readLog).get(), isEmpty);
    expect(importNotice(done), endsWith('10 entries this version does not know skipped.'));
  });

  test('an import merges with what is here, and twice is the same as once', () async {
    await fill();
    final text = await exportSettings(from);
    // This install read on further in a, took bm1 off, and has a bookmark,
    // a collection and a sitting of its own.
    await to.batch((b) {
      b.insertAll(to.progress, [
        ProgressData(contentKey: 'a', page: 9, percent: 0.7, finished: false, updatedAt: at(100)),
        ProgressData(contentKey: 'b', page: 2, percent: 0.1, finished: false, updatedAt: at(0)),
      ]);
      b.insertAll(to.bookmarks, [
        Bookmark(
          id: 'bm1',
          contentKey: 'a',
          page: 2,
          panel: 1,
          note: 'the splash',
          createdAt: at(3),
          deletedAt: at(50),
        ),
        Bookmark(id: 'mine', contentKey: 'c', page: 4, createdAt: at(51)),
      ]);
      b.insertAll(to.collectionBooks, [CollectionBook(name: 'Horror', contentKey: 'a', addedAt: at(52))]);
      b.insertAll(to.readLog, [ReadLogData(contentKey: 'a', startedAt: at(10), endedAt: at(20), pages: 12)]);
    });
    for (var i = 0; i < 2; i++) {
      await import(text);
      final prog = {for (final r in await to.select(to.progress).get()) r.contentKey: r.page};
      expect(prog, {'a': 9, 'b': 20}, reason: 'the later position wins');
      final marks = {for (final b in await to.select(to.bookmarks).get()) b.id: b.deletedAt != null};
      expect(marks, {'bm1': true, 'bm2': false, 'bm3': true, 'mine': false}, reason: 'a removal wins');
      final groups = {for (final c in await to.select(to.collectionBooks).get()) '${c.name}/${c.contentKey}'};
      expect(groups, {'Favourites/a', 'Moore/b', 'Horror/a'});
      expect(await to.select(to.readLog).get(), hasLength(2), reason: 'a sitting already here is not added again');
      expect(await to.select(to.overrides).get(), hasLength(2));
      expect(await LibraryStore(to).roots(), hasLength(2));
    }
  });

  test('paths not on this device are left out, and said so', () async {
    await fill();
    final text = await exportSettings(from);
    final here = (await settingsOf(from))[SettingsStore.sidecarDir]! as String;
    final mine = (await dir('MyStash')).path;
    await SettingsStore(to).saveString(SettingsStore.sidecarDir, mine);
    await Directory(here).delete();
    await Directory(p.join(tmp.path, 'Manga')).delete();
    final done = await import(text);
    expect((await settingsOf(to))[SettingsStore.sidecarDir], mine, reason: 'the sidecar folder stays this one');
    expect([for (final r in await LibraryStore(to).roots()) p.basename(r.path)], ['Comics']);
    expect(done.foldersMissing, [p.join(tmp.path, 'Manga')]);
    expect(done.sidecarDirMissing, here);
    expect(done.settings, 10);
    expect(importNotice(done), contains('1 library folder not on this device: ${p.join(tmp.path, 'Manga')}.'));
    expect(importNotice(done), contains("The sidecar folder $here is not on this device; kept this one's."));
  });

  test("import never takes a library folder out, nor carries ~/Comics being taken out", () async {
    // This device's library: its own Comics folder and one of its own.
    final mine = await dir('phone/Comics');
    final other = await dir('phone/Books');
    await LibraryStore(to).addRoot(mine.path);
    await LibraryStore(to).addRoot(other.path);
    final text = jsonEncode({
      'app': 'org.snonux.comicredr',
      'kind': 'settings',
      'format': 1,
      'settings': {SettingsStore.defaultFolderRemoved: true, SettingsStore.night: true},
      'libraryFolders': [(await dir('laptop/Comics')).path],
    });
    final done = await import(text);
    expect([
      for (final r in await LibraryStore(to).roots()) r.path,
    ], unorderedEquals([mine.path, other.path, p.join(tmp.path, 'laptop', 'Comics')]));
    expect(await settingsOf(to), {SettingsStore.night: true});
    expect(done.skipped, 1, reason: 'defaultFolderRemoved is not a setting a file carries');

    // Taken out here, it stays taken out whatever the file says.
    await SettingsStore(to).saveBool(SettingsStore.defaultFolderRemoved, true);
    await import(jsonEncode({'app': 'org.snonux.comicredr', 'kind': 'settings', 'format': 1}));
    expect(await SettingsStore(to).loadBool(SettingsStore.defaultFolderRemoved), isTrue);
  });

  test("a file without this device's sidecar settings leaves them; one with them sets them", () async {
    final stash = (await dir('PhoneStash')).path;
    await SettingsStore(to).saveString(SettingsStore.sidecarDir, stash);
    await SettingsStore(to).saveBool(SettingsStore.writeSidecars, false);
    await SettingsStore(to).saveBool(SettingsStore.night, true);
    // The laptop's: sidecars beside its comics, written, both the defaults.
    await SettingsStore(from).saveBool(SettingsStore.cleanUp, true);
    await import(await exportSettings(from));
    expect(await settingsOf(to), {
      SettingsStore.sidecarDir: stash,
      SettingsStore.writeSidecars: false,
      SettingsStore.cleanUp: true,
    }, reason: 'the night filter goes back to its default, the sidecar settings stay');

    // A backup of this device's own, after a reinstall, brings them back.
    await to.delete(to.settings).go();
    await SettingsStore(from).saveString(SettingsStore.sidecarDir, stash);
    await SettingsStore(from).saveBool(SettingsStore.writeSidecars, false);
    await import(await exportSettings(from));
    expect((await settingsOf(to))[SettingsStore.sidecarDir], stash);
    expect((await settingsOf(to))[SettingsStore.writeSidecars], false);
  });

  test('keys.toml that cannot be written is said so, and the rest is imported', () async {
    final blocker = File(p.join(tmp.path, 'not-a-folder'))..writeAsStringSync('');
    final text = jsonEncode({
      'app': 'org.snonux.comicredr',
      'kind': 'settings',
      'format': 1,
      'settings': {SettingsStore.night: true},
      'keysToml': '[keys]\n',
      'libraryFolders': [(await dir('Comics')).path],
    });
    final done = await import(text, keysPath: p.join(blocker.path, 'keys.toml'));
    expect(done.keysWritten, isFalse);
    expect(done.keysError, isNotNull);
    expect(await settingsOf(to), {SettingsStore.night: true});
    expect(await LibraryStore(to).roots(), hasLength(1));
    expect(importNotice(done), contains('keys.toml could not be written ('));
    expect(importNotice(done), contains('the rest was imported.'));
  });

  test('the index changes all or nothing', () async {
    await SettingsStore(to).saveBool(SettingsStore.night, true);
    // Adding the library folder, the last step, fails.
    await to.customStatement(
      "CREATE TRIGGER no_roots BEFORE INSERT ON roots BEGIN SELECT RAISE(ABORT, 'no folders today'); END",
    );
    final text = jsonEncode({
      'app': 'org.snonux.comicredr',
      'kind': 'settings',
      'format': 1,
      'settings': {SettingsStore.cleanUp: true},
      'positions': [
        {'contentKey': 'a', 'page': 3, 'percent': 0.2, 'updatedAt': t0.toUtc().toIso8601String()},
      ],
      'libraryFolders': [(await dir('Comics')).path],
    });
    await expectLater(import(text), throwsA(anything));
    expect(await settingsOf(to), {SettingsStore.night: true}, reason: 'the settings are as they were');
    expect(await to.select(to.progress).get(), isEmpty, reason: 'and no position came in');
  });

  test('a keys.toml already here is kept aside when it differs; none in the file leaves it be', () async {
    final keys = File(p.join(tmp.path, 'keys.toml'))..writeAsStringSync('mine');
    final theirs = jsonEncode({'app': 'org.snonux.comicredr', 'kind': 'settings', 'format': 1, 'keysToml': 'theirs'});
    expect((await import(theirs, keysPath: keys.path)).keysWritten, isTrue);
    expect(keys.readAsStringSync(), 'theirs');
    expect(File('${keys.path}.bak').readAsStringSync(), 'mine');
    expect((await import(theirs, keysPath: keys.path)).keysWritten, isFalse, reason: 'the same again');
    final none = jsonEncode({'app': 'org.snonux.comicredr', 'kind': 'settings', 'format': 1});
    expect((await import(none, keysPath: keys.path)).keysWritten, isFalse);
    expect(keys.readAsStringSync(), 'theirs');
  });

  test('a new file never overwrites one there', () async {
    final d = await dir('Download');
    final name = settingsFileName(DateTime(2026, 9, 3));
    expect(name, 'comicredr-settings-2026-09-03.json');
    expect(p.basename(await writeNewFile(d.path, name, '1')), name);
    expect(p.basename(await writeNewFile(d.path, name, '2')), 'comicredr-settings-2026-09-03-2.json');
    expect(File(p.join(d.path, name)).readAsStringSync(), '1');
  });

  test('the reader, the touch preset and the keymap take an import up at once', () async {
    final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(to)]);
    addTearDown(container.dispose);
    await fill();
    expect(container.read(readerProvider).night, isFalse);
    expect(container.read(touchPresetProvider), TouchPreset.standard);
    await import(await exportSettings(from));
    await container.read(readerProvider.notifier).reloadSettings();
    await container.read(touchPresetProvider.notifier).reload();
    final s = container.read(readerProvider);
    expect(
      (s.wholePageSteps, s.pauseWhole, s.night, s.trim, s.cleanUp, s.fullscreen),
      (false, false, true, true, true, true),
    );
    expect(container.read(touchPresetProvider), TouchPreset.oneThumb);

    final before = container.read(keymapProvider);
    container.read(reloadedKeymapProvider.notifier).set((
      load: keymapFromToml('[keys]\nnextStep = ["n"]\n'),
      path: 'keys.toml',
    ));
    expect(container.read(keymapProvider), isNot(same(before)));
    expect(container.read(keymapLoadProvider).path, 'keys.toml');

    // A file with the defaults puts the reader back to them.
    final empty = AppDatabase(NativeDatabase.memory());
    addTearDown(empty.close);
    await import(await exportSettings(empty));
    await container.read(readerProvider.notifier).reloadSettings();
    final d = container.read(readerProvider);
    expect((d.wholePageSteps, d.pauseWhole, d.night, d.fullscreen), (true, true, false, false));
  });
}
