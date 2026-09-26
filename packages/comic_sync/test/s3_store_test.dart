/// Runs against a real bucket when GARAGE_TEST_* are set (tool/garage_local.sh
/// prints them for a local Garage), and is skipped otherwise.
@Tags(['s3'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:comic_sync/comic_sync.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  final endpoint = env['GARAGE_TEST_ENDPOINT'];
  final skip = endpoint == null ? 'GARAGE_TEST_ENDPOINT is not set' : null;
  final run = DateTime.now().microsecondsSinceEpoch;

  S3Config config({String? secret, String? bucket, String? endpoint_}) => S3Config(
    endpoint: S3Config.parseEndpoint(endpoint_ ?? endpoint!)!,
    region: env['GARAGE_TEST_REGION'] ?? S3Config.defaultRegion,
    bucket: bucket ?? env['GARAGE_TEST_BUCKET']!,
    accessKey: env['GARAGE_TEST_ACCESS_KEY_ID']!,
    secretKey: secret ?? env['GARAGE_TEST_SECRET_ACCESS_KEY']!,
    prefix: 'comicredr-tests/$run/',
  );

  test('put, head, get, list and delete', () async {
    final c = config();
    final store = S3Store(c);
    final key = c.key('books/abc/sidecar.crdb');
    final bytes = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    await store.put(key, Stream.value(bytes), size: bytes.length, metadata: {'written-at': '1790452000000'});
    final head = await store.head(key);
    expect(head!.size, 1000);
    expect(head.metadata['written-at'], '1790452000000');
    expect(await store.get(key), bytes);
    expect(await store.list(c.key('books/')).map((o) => o.key).toList(), [key]);
    await store.delete(key);
    expect(await store.head(key), isNull);
    expect(await store.get(key), isNull);
    await store.delete(key);
  }, skip: skip);

  test(
    'a large object goes up in parts and comes back whole',
    () async {
      final c = config();
      final store = S3Store(c);
      final key = c.key('books/big/comic.cbz');
      const size = 40 * 1024 * 1024 + 123;
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i += 4096) {
        bytes[i] = i ~/ 4096 % 256;
      }
      var sent = 0;
      await store.put(
        key,
        Stream.fromIterable([
          for (var i = 0; i < size; i += 1 << 20) bytes.sublist(i, i + (1 << 20) > size ? size : i + (1 << 20)),
        ]),
        size: size,
        onProgress: (n) => sent = n,
      );
      expect(sent, size);
      expect((await store.head(key))!.size, size);
      expect(await store.get(key), bytes);
      await store.delete(key);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('the connection check passes', () async {
    final c = config();
    final report = await checkConnection(S3Store(c), c);
    expect(report.ok, isTrue, reason: report.describe(c));
  }, skip: skip);

  test('a wrong secret is refused, a missing bucket named, a dead port unreachable', () async {
    final wrong = config(secret: 'x' * 64);
    expect((await checkConnection(S3Store(wrong), wrong)).failure, RemoteFailure.denied);
    final nobucket = config(bucket: 'comicredr-no-such-bucket-$run');
    expect(
      (await checkConnection(S3Store(nobucket), nobucket)).failure,
      anyOf(RemoteFailure.noBucket, RemoteFailure.denied),
    );
    final off = config(endpoint_: 'http://127.0.0.1:9');
    final watch = Stopwatch()..start();
    expect((await checkConnection(S3Store(off), off)).failure, RemoteFailure.unreachable);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  }, skip: skip);
}
