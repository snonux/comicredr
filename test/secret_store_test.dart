import 'dart:async';
import 'dart:io';

import 'package:comicredr/src/data/secret_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// A keyring that counts what it is asked, and can be made to hang as a
/// locked or busy GNOME keyring does on Linux.
class _CountingKeyring implements FlutterSecureStorage {
  final values = <String, String>{};
  var reads = 0;
  var hang = false;

  @override
  Future<String?> read({
    required String key,
    Object? iOptions,
    Object? aOptions,
    Object? lOptions,
    Object? webOptions,
    Object? mOptions,
    Object? wOptions,
  }) {
    reads++;
    return hang ? Completer<String?>().future : Future.value(values[key]);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    Object? iOptions,
    Object? aOptions,
    Object? lOptions,
    Object? webOptions,
    Object? mOptions,
    Object? wOptions,
  }) {
    if (hang) return Completer<void>().future;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return Future.value();
  }

  @override
  Future<void> delete({
    required String key,
    Object? iOptions,
    Object? aOptions,
    Object? lOptions,
    Object? webOptions,
    Object? mOptions,
    Object? wOptions,
  }) async => values.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('secrets'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the keyring is asked once a run, however often the secret is read', () async {
    final keyring = _CountingKeyring()..values['s3-secret'] = 'abc';
    final store = KeyringSecretStore(fallbackDir: () async => dir.path, storage: keyring);
    for (var i = 0; i < 5; i++) {
      expect(await store.read('s3-secret'), 'abc');
      expect(await store.placeOf('s3-secret'), SecretPlace.keyring);
    }
    expect(keyring.reads, 1);
  });

  test('a write is what later reads give, without asking again', () async {
    final keyring = _CountingKeyring();
    final store = KeyringSecretStore(fallbackDir: () async => dir.path, storage: keyring);
    expect(await store.read('s3-secret'), isNull);
    expect(await store.write('s3-secret', 'new'), SecretPlace.keyring);
    final asked = keyring.reads;
    expect(await store.read('s3-secret'), 'new');
    expect(await store.write('s3-secret', null), isNull);
    expect(await store.read('s3-secret'), isNull);
    expect(keyring.reads, asked);
  });

  test('a keyring that does not answer is not asked again; the file is used', () async {
    final keyring = _CountingKeyring()..hang = true;
    final store = KeyringSecretStore(
      fallbackDir: () async => dir.path,
      storage: keyring,
      timeout: const Duration(milliseconds: 50),
    );
    expect(await store.write('s3-secret', 'kept'), SecretPlace.file);
    expect(keyring.reads, 0); // The write itself hung before reading back.
    expect(await store.read('s3-secret'), 'kept');
    final other = await store.read('other');
    expect(other, isNull);
    expect(keyring.reads, 0);
  });
}
