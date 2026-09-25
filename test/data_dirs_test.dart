import 'dart:io';

import 'package:comicredr/src/data/data_dirs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory home;
  late Map<String, String> env;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('home');
    env = {'HOME': home.path};
  });

  tearDown(() => home.delete(recursive: true));

  String? folder() => comicsDataFolder(environment: env, android: false);
  void make(String path) => File(p.join(home.path, path)).createSync(recursive: true);

  test('no ~/Comics: the usual places', () {
    expect(folder(), isNull);
  });

  test('~/Comics and no database yet: everything in ~/Comics/.comicredr', () {
    Directory(p.join(home.path, 'Comics')).createSync();
    expect(folder(), p.join(home.path, 'Comics', '.comicredr'));
    // Settled on later starts: the database there doesn't change it.
    make('Comics/.comicredr/comicredr.sqlite');
    expect(folder(), p.join(home.path, 'Comics', '.comicredr'));
  });

  test('a database in the usual place stays there, ~/Comics or not', () {
    Directory(p.join(home.path, 'Comics')).createSync();
    make('.local/share/org.snonux.comicredr/comicredr.sqlite');
    expect(folder(), isNull);
  });

  test('the usual place follows XDG_DATA_HOME and the old executable-named folder', () {
    Directory(p.join(home.path, 'Comics')).createSync();
    env['XDG_DATA_HOME'] = p.join(home.path, 'data');
    make('.local/share/org.snonux.comicredr/comicredr.sqlite');
    expect(folder(), isNotNull, reason: 'XDG_DATA_HOME moves the usual place');
    make('data/comicredr/comicredr.sqlite');
    expect(folder(), isNull);
  });

  test('an installed model alone does not keep the usual place', () {
    Directory(p.join(home.path, 'Comics')).createSync();
    make('.local/share/org.snonux.comicredr/models/comicredr-panels.onnx');
    expect(folder(), isNotNull);
  });

  test('~/Comics as a symlink to a folder counts; a dangling one does not', () {
    final real = Directory(p.join(home.path, 'Elsewhere', 'Real Comics'))..createSync(recursive: true);
    final link = Link(p.join(home.path, 'Comics'))..createSync(real.path);
    expect(folder(), p.join(home.path, 'Comics', '.comicredr'));
    real.deleteSync();
    expect(folder(), isNull);
    link.deleteSync();
  });

  test('Android keeps its private folders', () {
    expect(comicsDataFolder(environment: env, android: true), isNull);
  });

  test('keys.toml and the old data folder under XDG', () {
    expect(xdgKeysFile({'HOME': '/h'}), '/h/.config/comicredr/keys.toml');
    expect(xdgKeysFile({'HOME': '/h', 'XDG_CONFIG_HOME': '/c'}), '/c/comicredr/keys.toml');
    expect(xdgDataFolder({'HOME': '/h'}), '/h/.local/share/org.snonux.comicredr');
  });
}
