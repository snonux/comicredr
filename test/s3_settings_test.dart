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
import 'package:comicredr/src/undo_notice.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        ['http://garage.lan:3900', 'comics', 'Comics/', 'the-secret'],
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

    /// The `s3-…` key of the control that has the focus.
    String? focused() {
      String? name;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
        final key = e.widget.key;
        if (key is! ValueKey<String> || !key.value.startsWith('s3-')) return true;
        name = key.value;
        return false;
      });
      return name;
    }

    testWidgets('the fields and buttons in their order, top to bottom and by Tab', (tester) async {
      await tester.runAsync(() => s3.save(config));
      await open(tester);
      const fields = ['s3-endpoint', 's3-region', 's3-bucket', 's3-prefix', 's3-accessKey', 's3-secret'];
      const order = [...fields, 's3-test', 's3-turnOff', 's3-cancel', 's3-save'];
      // As written, which is the order Tab takes.
      expect([
        for (final f in tester.widgetList<TextField>(find.byType(TextField))) (f.key! as ValueKey<String>).value,
      ], fields);
      // On screen: each field under the one before, then Test connection
      // and Turn off on a line (the fields scroll, so how they lie to the
      // buttons under them is not looked at), Save right of Cancel.
      final at = {for (final k in order) k: tester.getTopLeft(find.byKey(Key(k)))};
      for (var i = 1; i <= fields.length; i++) {
        expect(at[order[i]]!.dy, greaterThan(at[order[i - 1]]!.dy), reason: '${order[i]} under ${order[i - 1]}');
      }
      expect(at['s3-turnOff']!.dx, greaterThan(at['s3-test']!.dx));
      expect(at['s3-turnOff']!.dy, greaterThan(at['s3-secret']!.dy));
      expect(at['s3-save']!.dx, greaterThan(at['s3-cancel']!.dx));
      // Tab from the address, which has the focus, goes through them all
      // and round to the address again.
      expect(focused(), 's3-endpoint');
      for (final next in [...order.skip(1), 's3-endpoint']) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focused(), next);
      }
    });

    /// Saving starts the sync, whose timers must not outlive the test.
    Future<void> stopSync(WidgetTester tester) => tester.runAsync(() => c.read(s3SyncProvider).dispose());

    /// Fills the dialog in and saves; the notice that says so.
    Future<String> save(WidgetTester tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const Key('s3-endpoint')), 'http://garage.lan:3900');
      await tester.enterText(find.byKey(const Key('s3-bucket')), 'comics');
      await tester.enterText(find.byKey(const Key('s3-accessKey')), 'GKabc');
      await tester.enterText(find.byKey(const Key('s3-secret')), 'the-secret');
      await tester.tap(find.byKey(const Key('s3-save')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      return (tester.widget<SnackBar>(find.byType(SnackBar)).content as Text).data!;
    }

    testWidgets('saved without a keyring: the warning stays its time, whatever the sync says next', (tester) async {
      secrets.place = SecretPlace.file;
      final warning = await save(tester);
      expect(warning, contains('in a private file (no keyring answered)'));
      final messenger = tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
      showNotice(messenger, 'Uploaded Akira to S3');
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(warning), findsOneWidget);
      expect(find.text('Uploaded Akira to S3'), findsNothing);
      // Its time up, the one that waited shows.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(warning), findsNothing);
      expect(find.text('Uploaded Akira to S3'), findsOneWidget);
      await stopSync(tester);
    });

    testWidgets('saved into the keyring: a routine notice, replaced by the next at once', (tester) async {
      final said = await save(tester);
      expect(said, contains('in the keyring'));
      showNotice(tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)), 'Uploaded Akira to S3');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(said), findsNothing);
      expect(find.text('Uploaded Akira to S3'), findsOneWidget);
      await stopSync(tester);
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
