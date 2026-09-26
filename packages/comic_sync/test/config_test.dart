import 'package:comic_sync/comic_sync.dart';
import 'package:test/test.dart';

void main() {
  test('endpoints are read as URLs, a bare host as https', () {
    expect(S3Config.parseEndpoint('http://garage.lan:3900').toString(), 'http://garage.lan:3900');
    expect(S3Config.parseEndpoint(' garage.example.org ').toString(), 'https://garage.example.org');
    expect(S3Config.parseEndpoint('https://s3.example.org/').toString(), 'https://s3.example.org');
    expect(S3Config.parseEndpoint(''), isNull);
    expect(S3Config.parseEndpoint('ftp://x'), isNull);
    expect(S3Config.parseEndpoint('https://s3.example.org/bucket'), isNull);
  });

  test('prefixes end in one slash', () {
    expect(S3Config.normalisePrefix('comicredr'), 'comicredr/');
    expect(S3Config.normalisePrefix('/a/b//'), 'a/b/');
    expect(S3Config.normalisePrefix(' '), '');
  });

  test('host leaves out the default port', () {
    S3Config at(String e) =>
        S3Config(endpoint: S3Config.parseEndpoint(e)!, bucket: 'b', accessKey: 'k', secretKey: 's');
    expect(at('https://g.example.org').host, 'g.example.org');
    expect(at('http://g.lan:3900').host, 'g.lan:3900');
  });
}
