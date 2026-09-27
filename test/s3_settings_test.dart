import 'package:comic_sync/comic_sync.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/data/s3_settings.dart';
import 'package:comicredr/src/data/secret_store.dart';
import 'package:comicredr/src/data/settings_file.dart';
import 'package:comicredr/src/data/settings_store.dart';
import 'package:comicredr/src/library/library_store.dart';
import 'package:comicredr/src/library/s3_settings_dialog.dart';
import 'package:comicredr/src/library/settings_transfer.dart';
import 'package:comicredr/src/providers.dart';
import 'package:comicredr/src/reader/reader_providers.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// S3 sync's settings (design plan section 13): saved as settings, the
/// secret key only in the keystore, never in the index or a settings file.
void main() {
  late AppDatabase db;
  late MemorySecretStore secrets;
  late S3Settings s3;

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    secrets = MemorySecretStore();
    s3 = S3Settings(SettingsStore(db), secrets);
  });

  tearDown(() => db.close());

  final config = S3Config(
    endpoint: Uri.parse('https://garage.example.org'),
    bucket: 'comics',
    accessKey: 'GKabc',
    secretKey: 'the-secret',
    prefix: 'shelf/',
  );

  Future<String> everySetting() async => [for (final r in await db.select(db.settings).get()) r.value].join('\n');

  test('saved, loaded, and turned off; the secret never in the index', () async {
    expect((await s3.load()).isSet, isFalse);
    expect(await s3.config(), isNull);
    expect(await s3.save(config), SecretPlace.keyring);
    final f = await s3.load();
    expect(
      [f.endpoint, f.region, f.bucket, f.prefix, f.accessKey, f.hasSecret],
      ['https://garage.example.org', 'garage', 'comics', 'shelf/', 'GKabc', true],
    );
    final back = (await s3.config())!;
    expect(
      [back.endpoint, back.bucket, back.secretKey, back.prefix],
      [config.endpoint, 'comics', 'the-secret', 'shelf/'],
    );
    expect(await everySetting(), isNot(contains('the-secret')));
    await s3.clear();
    expect((await s3.load()).isSet, isFalse);
    expect(secrets.values, isEmpty);
    expect(await db.select(db.settings).get(), isEmpty);
  });

  test('a settings file carries the bucket but not the secret, and one without them leaves them', () async {
    await s3.save(config);
    final text = await exportSettings(db);
    expect(text, contains('garage.example.org'));
    expect(text, isNot(contains('the-secret')));

    // Another install: its own sync set up; a file from before S3 sync.
    final other = AppDatabase(NativeDatabase.memory());
    addTearDown(other.close);
    final otherS3 = S3Settings(SettingsStore(other), MemorySecretStore());
    await otherS3.save(
      S3Config(endpoint: Uri.parse('http://garage.lan:3900'), bucket: 'mine', accessKey: 'GKx', secretKey: 's'),
    );
    await importSettings(
      SettingsFile.decode('{"app": "org.snonux.comicredr", "kind": "settings", "format": 1}'),
      library: LibraryStore(other),
    );
    expect((await otherS3.load()).bucket, 'mine');
    // The laptop's file sets the bucket; the phone's secret stays its own.
    await importSettings(SettingsFile.decode(text), library: LibraryStore(other));
    final now = await otherS3.config();
    expect([now!.bucket, now.host, now.secretKey], ['comics', 'garage.example.org', 's']);
  });

  group('the dialog', () {
    late MemoryStore bucket;
    late ProviderContainer c;

    Future<void> open(WidgetTester tester) async {
      bucket = MemoryStore();
      c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secretStoreProvider.overrideWithValue(secrets),
          remoteStoreFactoryProvider.overrideWithValue((_) => bucket),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(onPressed: () => showS3Settings(context), child: const Text('open')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    testWidgets('filled in, tested, saved, reopened and turned off', (tester) async {
      await open(tester);
      expect(find.text('S3 sync'), findsOneWidget);
      expect(find.byKey(const Key('s3-turnOff')), findsNothing);
      await tester.enterText(find.byKey(const Key('s3-endpoint')), 'http://garage.lan:3900');
      await settle(tester);
      expect(find.textContaining('travel unencrypted'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('s3-bucket')), 'comics');
      await tester.enterText(find.byKey(const Key('s3-accessKey')), 'GKabc');
      await tester.ensureVisible(find.byKey(const Key('s3-test')));
      await tester.tap(find.byKey(const Key('s3-test')));
      await settle(tester);
      expect(find.text('Give the secret key'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('s3-secret')), 'the-secret');
      bucket.reachable = false;
      await tester.ensureVisible(find.byKey(const Key('s3-test')));
      await tester.tap(find.byKey(const Key('s3-test')));
      await settle(tester);
      expect(find.textContaining('Could not write to the bucket'), findsOneWidget);
      expect(find.textContaining('Is the server on'), findsOneWidget);

      bucket.reachable = true;
      await tester.ensureVisible(find.byKey(const Key('s3-test')));
      await tester.tap(find.byKey(const Key('s3-test')));
      await settle(tester);
      expect(find.textContaining('Connected to comics on garage.lan:3900'), findsOneWidget);
      expect(bucket.objects, isEmpty, reason: 'the check cleans up after itself');

      await tester.tap(find.byKey(const Key('s3-save')));
      await settle(tester);
      expect(find.text('S3 sync'), findsNothing);
      final saved = (await tester.runAsync(() => c.read(s3SettingsProvider).config()))!;
      expect(
        [saved.endpoint.toString(), saved.bucket, saved.prefix, saved.secretKey],
        ['http://garage.lan:3900', 'comics', 'comicredr/', 'the-secret'],
      );

      // Reopened: the secret is not shown, and an empty field keeps it.
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.textContaining('A secret key is saved in the keyring'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('s3-secret'))).controller!.text, isEmpty);
      await tester.enterText(find.byKey(const Key('s3-prefix')), 'shelf');
      await tester.tap(find.byKey(const Key('s3-save')));
      await settle(tester);
      final again = (await tester.runAsync(() => c.read(s3SettingsProvider).config()))!;
      expect([again.prefix, again.secretKey], ['shelf/', 'the-secret']);

      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('s3-turnOff')));
      await tester.tap(find.byKey(const Key('s3-turnOff')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('s3-off-confirm')));
      await settle(tester);
      expect(await tester.runAsync(() => c.read(s3SettingsProvider).config()), isNull);
      expect(secrets.values, isEmpty);
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
