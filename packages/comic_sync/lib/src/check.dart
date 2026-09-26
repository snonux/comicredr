import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'config.dart';
import 'remote_store.dart';

/// What Test connection found: [ok], or the step that failed and why.
class ConnectionReport {
  const ConnectionReport.ok(this.elapsed) : failure = null, step = null, message = null;
  ConnectionReport.failed(this.step, RemoteException e, this.elapsed) : failure = e.failure, message = e.message;

  final RemoteFailure? failure;

  /// Which of writing, reading, listing and removing failed.
  final String? step;
  final String? message;
  final Duration elapsed;

  bool get ok => failure == null;

  /// One sentence for the settings page.
  String describe(S3Config config) {
    if (ok) return 'Connected to ${config.bucket} on ${config.host} (${elapsed.inMilliseconds} ms).';
    final hint = switch (failure!) {
      RemoteFailure.unreachable => 'Is the server on, and is the address right?',
      RemoteFailure.denied => 'Check the access key and secret key, and that the key may use this bucket.',
      RemoteFailure.noBucket => 'Check the bucket name.',
      RemoteFailure.certificate => 'The address needs a certificate this device trusts.',
      RemoteFailure.other => '',
    };
    return 'Could not $step: $message. $hint'.trim();
  }
}

/// Writes a small object under the prefix, reads it back, finds it in a
/// listing and removes it: everything sync will do, once, on the real
/// bucket.
Future<ConnectionReport> checkConnection(RemoteStore store, S3Config config) async {
  final watch = Stopwatch()..start();
  final key = config.key('.check/${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}');
  final body = Uint8List.fromList(utf8.encode('ComicRedr connection check\n'));
  var step = 'write to the bucket';
  try {
    await store.put(key, Stream.value(body), size: body.length, metadata: {'written-at': '0'});
    step = 'read from the bucket';
    final back = await store.get(key);
    if (back == null || utf8.decode(back) != utf8.decode(body)) {
      throw const RemoteException(RemoteFailure.other, 'what came back differs from what was written');
    }
    final head = await store.head(key);
    if (head?.metadata['written-at'] != '0') {
      throw const RemoteException(RemoteFailure.other, 'the object came back without its metadata');
    }
    step = 'list the bucket';
    final found = await store.list(config.key('.check/')).any((o) => o.key == key);
    if (!found) throw const RemoteException(RemoteFailure.other, 'the object is missing from the listing');
    step = 'remove from the bucket';
    await store.delete(key);
    return ConnectionReport.ok(watch.elapsed);
  } on RemoteException catch (e) {
    return ConnectionReport.failed(step, e, watch.elapsed);
  }
}
