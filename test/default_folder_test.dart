import 'dart:io';

import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/library/default_folder.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late AppDatabase db;
  late LibraryStore library;
  late SettingsStore settings;
  late Directory home;
  late String comics;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    library = LibraryStore(db);
    settings = SettingsStore(db);
    home = await Directory.systemTemp.createTemp('home');
    comics = p.join(home.path, 'Comics');
  });

  tearDown(() async {
    await db.close();
    await home.delete(recursive: true);
  });

  Future<List<String>> roots() async => [for (final r in await library.roots()) r.path];

  test('~/Comics under HOME, the shared Comics folder on Android', () {
    expect(defaultComicsFolder(environment: {'HOME': '/home/me'}, android: false), '/home/me/Comics');
    expect(defaultComicsFolder(environment: const {}, android: false), isNull);
    expect(defaultComicsFolder(android: true), '/storage/emulated/0/Comics');
  });

  test('no ~/Comics: the library stays empty', () async {
    expect(await addDefaultFolder(library, settings, comics), isFalse);
    expect(await roots(), isEmpty);
  });

  test('~/Comics joins an empty library, once', () async {
    await Directory(comics).create();
    expect(await addDefaultFolder(library, settings, comics), isTrue);
    expect(await addDefaultFolder(library, settings, comics), isFalse);
    expect(await roots(), [comics]);
  });

  test('a ~/Comics made later is picked up at the next start', () async {
    expect(await addDefaultFolder(library, settings, comics), isFalse);
    await Directory(comics).create();
    expect(await addDefaultFolder(library, settings, comics), isTrue);
    expect(await roots(), [comics]);
  });

  test('a library folder of their own keeps ~/Comics out', () async {
    await Directory(comics).create();
    final other = await Directory(p.join(home.path, 'Other')).create();
    await library.addRoot(other.path);
    expect(await addDefaultFolder(library, settings, comics), isFalse);
    expect(await roots(), [other.path]);
  });

  test('taken out of the library, ~/Comics stays out', () async {
    await Directory(comics).create();
    await addDefaultFolder(library, settings, comics);
    final root = (await library.roots()).single;
    await removeLibraryFolder(library, settings, root.id, root.path, defaultFolder: comics);
    expect(await roots(), isEmpty);
    expect(await addDefaultFolder(library, settings, comics), isFalse);
    expect(await roots(), isEmpty);
  });

  test('taking out another folder does not keep ~/Comics out', () async {
    final other = await Directory(p.join(home.path, 'Other')).create();
    final id = await library.addRoot(other.path);
    await removeLibraryFolder(library, settings, id, other.path, defaultFolder: comics);
    await Directory(comics).create();
    expect(await addDefaultFolder(library, settings, comics), isTrue);
  });

  test('~/Comics as a symlink: added by its own path, and taken out stays out', () async {
    final real = Directory(p.join(home.path, 'Real'))..createSync();
    Link(comics).createSync(real.path);
    expect(await addDefaultFolder(library, settings, comics), isTrue);
    expect(await roots(), [comics]);
    final root = (await library.roots()).single;
    await removeLibraryFolder(library, settings, root.id, root.path, defaultFolder: comics);
    expect(await addDefaultFolder(library, settings, comics), isFalse);
    expect(await roots(), isEmpty);
  });

  test('a dangling ~/Comics symlink is no ~/Comics', () async {
    Link(comics).createSync(p.join(home.path, 'gone'));
    expect(await addDefaultFolder(library, settings, comics), isFalse);
  });
}
