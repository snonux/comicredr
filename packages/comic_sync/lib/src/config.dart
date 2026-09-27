/// Where the bucket is and how to sign in to it (design plan section 13).
/// The secret key comes from the platform keystore, never from the app
/// database, a sidecar or a settings file.
class S3Config {
  const S3Config({
    required this.endpoint,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
    this.region = defaultRegion,
    this.prefix = defaultPrefix,
  });

  /// Garage's default region name.
  static const defaultRegion = 'garage';

  /// Every object ComicRedr writes goes under this, so the bucket can hold
  /// other things too.
  static const defaultPrefix = 'comicredr/';

  /// The S3 endpoint, like `https://garage.example.org` or
  /// `http://garage.lan:3900`. Path-style addressing, so no bucket in it.
  final Uri endpoint;
  final String bucket;
  final String accessKey;
  final String secretKey;
  final String region;

  /// Ends in `/`, or is empty for the bucket's top level.
  final String prefix;

  bool get secure => endpoint.scheme == 'https';

  /// The endpoint as people write it, for the settings page and notices.
  String get host =>
      endpoint.hasPort && endpoint.port != (secure ? 443 : 80) ? '${endpoint.host}:${endpoint.port}' : endpoint.host;

  /// The full key for [path] under [prefix].
  String key(String path) => '$prefix$path';

  /// Reads [text] as an endpoint: a URL with http or https, or a bare host
  /// (taken as https). Null when it is not one.
  static Uri? parseEndpoint(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final uri = Uri.tryParse(t.contains('://') ? t : 'https://$t');
    if (uri == null || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
    if (uri.path.isNotEmpty && uri.path != '/') return null;
    return uri.replace(path: '', query: null, fragment: null);
  }

  /// [text] as a prefix: no leading slash, one trailing slash, or empty.
  static String normalisePrefix(String text) {
    final t = text.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return t.isEmpty ? '' : '$t/';
  }
}
