import 'dart:io';
import 'dart:typed_data';

import 'package:comic_sync/comic_sync.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late S3Store store;
  var status = 502;
  var xml = false;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = status;
      request.response.headers.contentType = xml ? ContentType('application', 'xml') : ContentType.html;
      request.response.write(
        xml
            ? '<Error><Code>ServiceUnavailable</Code><Message>Try later</Message></Error>'
            : '<html><body>Bad Gateway</body></html>',
      );
      await request.response.close();
    });
    store = S3Store(
      S3Config(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        bucket: 'comics',
        accessKey: 'test',
        secretKey: 'test',
      ),
    );
  });
  tearDown(() async {
    store.close();
    await server.close(force: true);
  });

  for (final code in [500, 502, 503, 504]) {
    test('HTTP $code pauses sync for listings, reads, writes and removals', () async {
      status = code;
      for (final asXml in [false, true]) {
        xml = asXml;
        final unavailable = isA<RemoteException>().having((e) => e.failure, 'failure', RemoteFailure.unreachable);
        await expectLater(store.list('Comics/').toList(), throwsA(unavailable));
        await expectLater(store.head('comic.cbz'), throwsA(unavailable));
        await expectLater(store.get('comic.cbz'), throwsA(unavailable));
        await expectLater(store.put('sidecar.crdb', Stream.value(Uint8List(1)), size: 1), throwsA(unavailable));
        await expectLater(store.delete('sidecar.crdb'), throwsA(unavailable));
      }
    });
  }

  test('HTTP 403 remains a key refusal', () async {
    status = 403;
    xml = true;
    await expectLater(
      store.head('comic.cbz'),
      throwsA(isA<RemoteException>().having((e) => e.failure, 'failure', RemoteFailure.denied)),
    );
  });
}
