import 'dart:typed_data';

/// One object in the bucket, as a listing or a HEAD request tells it.
class RemoteObject {
  const RemoteObject({required this.key, required this.size, this.etag, this.metadata = const {}});

  /// The full key, prefix included.
  final String key;
  final int size;
  final String? etag;

  /// The object's `x-amz-meta-*` values, names lower case without that
  /// prefix. A listing leaves them out; [RemoteStore.head] has them.
  final Map<String, String> metadata;
}

/// Why a call to the bucket failed, in words the settings page and the
/// status line can show.
enum RemoteFailure {
  /// No answer: the server is off, the name does not resolve, the network
  /// is down or the connection timed out. The one that is expected, since
  /// a home cluster is off at times.
  unreachable,

  /// The access key or secret key is wrong, or the key may not use the
  /// bucket.
  denied,

  /// The bucket does not exist.
  noBucket,

  /// The TLS certificate was refused.
  certificate,

  /// Anything else the server said.
  other,
}

class RemoteException implements Exception {
  const RemoteException(this.failure, this.message);

  final RemoteFailure failure;
  final String message;

  @override
  String toString() => message;
}

/// The bucket, as sync sees it: a flat map of keys to bytes. Every call
/// either does what it says or throws a [RemoteException]. The app goes
/// through this only, so tests can swap in a [MemoryStore].
abstract interface class RemoteStore {
  /// Stores [bytes] at [key], replacing what is there, with [metadata] as
  /// `x-amz-meta-*` headers. [onProgress] gets the bytes sent so far.
  Future<void> put(
    String key,
    Stream<Uint8List> bytes, {
    required int size,
    Map<String, String> metadata = const {},
    void Function(int sent)? onProgress,
  });

  /// The object at [key], or null when there is none.
  Future<Uint8List?> get(String key);

  /// What is known about [key] without its bytes, or null when there is
  /// none.
  Future<RemoteObject?> head(String key);

  /// Every object under [prefix], metadata left out.
  Stream<RemoteObject> list(String prefix);

  /// Removes [key]; removing one that is not there is not an error.
  Future<void> delete(String key);

  /// Lets go of connections.
  void close();
}
