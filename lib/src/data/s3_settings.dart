import 'package:comic_sync/comic_sync.dart';

import 'secret_store.dart';
import 'settings_store.dart';

/// The S3 sync settings as the settings page edits them. The secret key
/// is only ever typed in, never shown again: [hasSecret] says whether one
/// is kept.
class S3Fields {
  const S3Fields({
    this.endpoint = '',
    this.region = S3Config.defaultRegion,
    this.bucket = '',
    this.prefix = S3Config.defaultPrefix,
    this.accessKey = '',
    this.hasSecret = false,
    this.secretPlace,
  });

  final String endpoint;
  final String region;
  final String bucket;
  final String prefix;
  final String accessKey;
  final bool hasSecret;
  final SecretPlace? secretPlace;

  /// Sync is set up: an endpoint and bucket are saved.
  bool get isSet => endpoint.isNotEmpty && bucket.isNotEmpty;
}

/// Loads and saves the S3 settings: endpoint, region, bucket, prefix and
/// access key id as ordinary settings (they travel in a settings file),
/// the secret key in the [SecretStore] only.
class S3Settings {
  S3Settings(this._settings, this._secrets);

  final SettingsStore _settings;
  final SecretStore _secrets;

  /// The secret's name in the keystore, and its file's when there is none.
  static const secretName = 's3-secret';

  Future<S3Fields> load() async => S3Fields(
    endpoint: await _settings.loadString(SettingsStore.s3Endpoint) ?? '',
    region: await _settings.loadString(SettingsStore.s3Region) ?? S3Config.defaultRegion,
    bucket: await _settings.loadString(SettingsStore.s3Bucket) ?? '',
    prefix: await _settings.loadString(SettingsStore.s3Prefix) ?? S3Config.defaultPrefix,
    accessKey: await _settings.loadString(SettingsStore.s3AccessKey) ?? '',
    hasSecret: await _secrets.placeOf(secretName) != null,
    secretPlace: await _secrets.placeOf(secretName),
  );

  /// The saved settings as a config to connect with, or null when sync is
  /// not set up or the secret is missing.
  Future<S3Config?> config() async {
    final f = await load();
    final endpoint = S3Config.parseEndpoint(f.endpoint);
    final secret = await _secrets.read(secretName);
    if (!f.isSet || endpoint == null || secret == null || f.accessKey.isEmpty) return null;
    return S3Config(
      endpoint: endpoint,
      region: f.region.isEmpty ? S3Config.defaultRegion : f.region,
      bucket: f.bucket,
      prefix: f.prefix,
      accessKey: f.accessKey,
      secretKey: secret,
    );
  }

  /// Saves [config]; the secret goes to the keystore. Returns where.
  Future<SecretPlace?> save(S3Config config) async {
    await _settings.saveString(SettingsStore.s3Endpoint, config.endpoint.toString());
    await _settings.saveString(SettingsStore.s3Region, config.region);
    await _settings.saveString(SettingsStore.s3Bucket, config.bucket);
    await _settings.saveString(SettingsStore.s3Prefix, config.prefix);
    await _settings.saveString(SettingsStore.s3AccessKey, config.accessKey);
    return _secrets.write(secretName, config.secretKey);
  }

  /// Turns sync off: forgets every setting and the secret.
  Future<void> clear() async {
    for (final key in SettingsStore.s3Keys) {
      await _settings.saveString(key, null);
    }
    await _secrets.write(secretName, null);
  }

  /// The saved secret, for a Test connection or save that left the field
  /// empty to keep it.
  Future<String?> secret() => _secrets.read(secretName);
}
