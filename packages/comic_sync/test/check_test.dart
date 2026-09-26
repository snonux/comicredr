import 'package:comic_sync/comic_sync.dart';
import 'package:test/test.dart';

void main() {
  final config = S3Config(
    endpoint: Uri.parse('http://garage.lan:3900'),
    bucket: 'comics',
    accessKey: 'k',
    secretKey: 's',
  );

  test('a working bucket passes and is left as it was', () async {
    final store = MemoryStore();
    final report = await checkConnection(store, config);
    expect(report.ok, isTrue);
    expect(report.describe(config), startsWith('Connected to comics on garage.lan:3900'));
    expect(store.objects, isEmpty);
  });

  test('a bucket out of reach says so and what to look at', () async {
    final report = await checkConnection(MemoryStore()..reachable = false, config);
    expect(report.failure, RemoteFailure.unreachable);
    expect(report.describe(config), contains('Is the server on'));
    expect(report.describe(config), startsWith('Could not write to the bucket'));
  });
}
