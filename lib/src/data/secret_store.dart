import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import 'data_dirs.dart';

/// Where a secret is kept.
enum SecretPlace {
  /// The platform keystore: the Secret Service (GNOME Keyring) on Linux,
  /// the Android Keystore on the phone.
  keyring,

  /// A file only this user can read, when no keyring answers.
  file,
}

/// Secrets, today only the S3 secret key: never in the app database, a
/// sidecar or a settings file (design plan section 13).
abstract interface class SecretStore {
  Future<String?> read(String name);

  /// Saves [value] under [name]; null forgets it. Returns where it went.
  Future<SecretPlace?> write(String name, String? value);

  /// Where [name] is kept now, or null when it is not.
  Future<SecretPlace?> placeOf(String name);
}

/// The keystore through flutter_secure_storage, and a mode 0600 file in
/// the folder [fallbackDir] gives when that fails: a Linux session without a keyring
/// running (a bare window manager, Xvfb) has no Secret Service. A keyring
/// that does not answer within [timeout] counts as none.
class KeyringSecretStore implements SecretStore {
  KeyringSecretStore({required this.fallbackDir, this.timeout = const Duration(seconds: 3)});

  final Future<String> Function() fallbackDir;
  final Duration timeout;
  final _storage = const FlutterSecureStorage();

  Future<File> _file(String name) async => File(p.join(await fallbackDir(), name));

  Future<T?> _keyring<T>(Future<T> Function() f) async {
    try {
      return await f().timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> read(String name) async {
    final fromKeyring = await _keyring(() => _storage.read(key: name));
    if (fromKeyring != null) return fromKeyring;
    final file = await _file(name);
    return file.existsSync() ? file.readAsStringSync().trim() : null;
  }

  @override
  Future<SecretPlace?> placeOf(String name) async {
    if (await _keyring(() => _storage.read(key: name)) != null) return SecretPlace.keyring;
    return (await _file(name)).existsSync() ? SecretPlace.file : null;
  }

  @override
  Future<SecretPlace?> write(String name, String? value) async {
    final file = await _file(name);
    if (value == null) {
      await _keyring(() async => _storage.delete(key: name));
      if (file.existsSync()) file.deleteSync();
      return null;
    }
    // Read back: without a Secret Service, libsecret on Linux can report a
    // write that went nowhere.
    final saved = await _keyring(() async {
      await _storage.write(key: name, value: value);
      return await _storage.read(key: name) == value;
    });
    if (saved == true) {
      // Once in the keyring, an older copy in the file must not linger.
      if (file.existsSync()) file.deleteSync();
      return SecretPlace.keyring;
    }
    await writePrivateFile(file, value);
    return SecretPlace.file;
  }
}

/// Writes [text] to [file] so that only this user can read it: the file is
/// made empty with mode 0600 first, then filled, so the secret is never in
/// a file others can read, not even for a moment.
Future<void> writePrivateFile(File file, String text) async {
  file.parent.createSync(recursive: true);
  if (!Platform.isWindows) {
    if (!file.existsSync()) file.createSync();
    final chmod = await Process.run('chmod', ['600', file.path]);
    if (chmod.exitCode != 0) throw FileSystemException('Could not make the file private', file.path);
  }
  file.writeAsStringSync(text, flush: true);
}

/// Where the fallback file goes: beside keys.toml in `~/.config/comicredr`
/// on Linux (not the app data folder, which may be ~/Comics/.comicredr and
/// copied around with the comics), the app's private folder on Android.
Future<String> secretFallbackDir() async {
  if (Platform.isAndroid) return (await appDataDirectory()).path;
  final keys = xdgKeysFile();
  return keys == null ? (await appDataDirectory()).path : p.dirname(keys);
}

/// A store in memory, for tests.
class MemorySecretStore implements SecretStore {
  final values = <String, String>{};
  SecretPlace place = SecretPlace.keyring;

  @override
  Future<String?> read(String name) async => values[name];

  @override
  Future<SecretPlace?> placeOf(String name) async => values.containsKey(name) ? place : null;

  @override
  Future<SecretPlace?> write(String name, String? value) async {
    if (value == null) {
      values.remove(name);
      return null;
    }
    values[name] = value;
    return place;
  }
}
