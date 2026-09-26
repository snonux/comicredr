import 'package:comic_sync/comic_sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/s3_settings.dart';
import '../data/secret_store.dart';
import '../reader/reader_providers.dart';

/// Sets up S3 sync (design plan section 13): the bucket, the keys, and a
/// Test connection that writes, reads, lists and removes one small object.
/// Returns true when the settings changed.
Future<bool?> showS3Settings(BuildContext context) =>
    showDialog<bool>(context: context, builder: (_) => const S3SettingsDialog());

class S3SettingsDialog extends ConsumerStatefulWidget {
  const S3SettingsDialog({super.key});

  @override
  ConsumerState<S3SettingsDialog> createState() => _S3SettingsDialogState();
}

class _S3SettingsDialogState extends ConsumerState<S3SettingsDialog> {
  final _endpoint = TextEditingController();
  final _region = TextEditingController();
  final _bucket = TextEditingController();
  final _prefix = TextEditingController();
  final _accessKey = TextEditingController();
  final _secret = TextEditingController();
  final _scroll = ScrollController();
  S3Fields? _saved;
  bool _busy = false;

  /// The last Test connection's answer, and whether it was good.
  ({String text, bool ok})? _result;

  @override
  void initState() {
    super.initState();
    _load();
    for (final c in [_endpoint, _region, _bucket, _prefix, _accessKey, _secret]) {
      c.addListener(_edited);
    }
  }

  @override
  void dispose() {
    for (final c in [_endpoint, _region, _bucket, _prefix, _accessKey, _secret]) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final f = await ref.read(s3SettingsProvider).load();
    if (!mounted) return;
    setState(() {
      _saved = f;
      _endpoint.text = f.endpoint;
      _region.text = f.region;
      _bucket.text = f.bucket;
      _prefix.text = f.prefix;
      _accessKey.text = f.accessKey;
      _result = null;
    });
  }

  /// A test result no longer says anything once a field changes, and the
  /// address's note follows what is typed.
  void _edited() => setState(() => _result = null);

  bool get _plainHttp => S3Config.parseEndpoint(_endpoint.text)?.scheme == 'http';

  /// Shows [text] under Test connection and scrolls it into view: on a
  /// small screen the dialog scrolls, and the answer is at its end.
  void _say(String text, {required bool ok}) {
    if (!mounted) return;
    setState(() => _result = (text: text, ok: ok));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// The fields as a config, the saved secret standing in for an empty
  /// secret field; or why they are not one yet.
  Future<({S3Config? config, String? problem})> _config() async {
    final endpoint = S3Config.parseEndpoint(_endpoint.text);
    if (endpoint == null) return (config: null, problem: 'The address should look like https://garage.example.org');
    if (_bucket.text.trim().isEmpty) return (config: null, problem: 'Give the bucket\'s name');
    if (_accessKey.text.trim().isEmpty) return (config: null, problem: 'Give the access key id');
    final secret = _secret.text.trim().isNotEmpty ? _secret.text.trim() : await ref.read(s3SettingsProvider).secret();
    if (secret == null || secret.isEmpty) return (config: null, problem: 'Give the secret key');
    final region = _region.text.trim();
    return (
      config: S3Config(
        endpoint: endpoint,
        region: region.isEmpty ? S3Config.defaultRegion : region,
        bucket: _bucket.text.trim(),
        prefix: S3Config.normalisePrefix(_prefix.text),
        accessKey: _accessKey.text.trim(),
        secretKey: secret,
      ),
      problem: null,
    );
  }

  Future<void> _test() async {
    if (_busy) return;
    final (:config, :problem) = await _config();
    if (config == null) {
      _say(problem!, ok: false);
      return;
    }
    setState(() => _busy = true);
    final store = ref.read(remoteStoreFactoryProvider)(config);
    try {
      final report = await checkConnection(store, config);
      _say(report.describe(config), ok: report.ok);
    } finally {
      store.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final (:config, :problem) = await _config();
    if (config == null) {
      _say(problem!, ok: false);
      return;
    }
    final place = await ref.read(s3SettingsProvider).save(config);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'S3 sync set up for ${config.bucket} on ${config.host}; '
          'the secret key is ${place == SecretPlace.file ? 'in a private file (no keyring answered)' : 'in the keyring'}',
        ),
      ),
    );
    Navigator.pop(context, true);
  }

  Future<void> _turnOff() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn S3 sync off?'),
        content: const Text(
          'Forgets the bucket and the keys on this device. Nothing in the bucket and nothing on this device '
          'is deleted.',
        ),
        actions: [
          TextButton(
            key: const Key('s3-off-cancel'),
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('s3-off-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(s3SettingsProvider).clear();
    if (mounted) Navigator.pop(context, true);
  }

  Widget _field(
    String key,
    TextEditingController c,
    String label, {
    String? hint,
    bool secret = false,
    bool autofocus = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      key: Key('s3-$key'),
      controller: c,
      obscureText: secret,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: label, helperText: hint, helperMaxLines: 3),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = _saved;
    return AlertDialog(
      title: const Text('S3 sync'),
      content: SizedBox(
        width: 520,
        child: saved == null
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                controller: _scroll,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Comics you upload and their sidecars go to a bucket on your own S3 server, such as Garage '
                      'or MinIO, so another device can read on where you left off. Everything stays on this '
                      'device too; when the server is off, the app carries on without it.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    _field(
                      'endpoint',
                      _endpoint,
                      'Address',
                      autofocus: true,
                      hint: _plainHttp
                          ? 'Plain http: the keys are signed, but comics and sidecars travel unencrypted. Fine at '
                                'home, not over the internet.'
                          : 'Like https://garage.example.org or http://garage.lan:3900',
                    ),
                    _field('region', _region, 'Region', hint: 'Garage\'s is garage'),
                    _field('bucket', _bucket, 'Bucket'),
                    _field(
                      'prefix',
                      _prefix,
                      'Folder in the bucket',
                      hint: 'Everything ComicRedr writes goes under it',
                    ),
                    _field('accessKey', _accessKey, 'Access key id'),
                    _field(
                      'secret',
                      _secret,
                      'Secret key',
                      secret: true,
                      hint: saved.hasSecret
                          ? 'A secret key is saved ${saved.secretPlace == SecretPlace.file ? 'in a private file' : 'in the keyring'}; leave this empty to keep it'
                          : 'Kept in the keyring, never in settings files',
                    ),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          key: const Key('s3-test'),
                          onPressed: _test,
                          icon: _busy
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.wifi_tethering),
                          label: const Text('Test connection'),
                        ),
                        if (saved.isSet) ...[
                          const Spacer(),
                          TextButton(
                            key: const Key('s3-turnOff'),
                            onPressed: _busy ? null : _turnOff,
                            child: const Text('Turn off'),
                          ),
                        ],
                      ],
                    ),
                    if (_result case final r?)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              r.ok ? Icons.check_circle_outline : Icons.error_outline,
                              size: 18,
                              color: r.ok ? Colors.green : theme.colorScheme.error,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(r.text, key: const Key('s3-result'), style: theme.textTheme.bodySmall),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(key: const Key('s3-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('s3-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
