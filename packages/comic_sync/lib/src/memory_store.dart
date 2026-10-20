import 'dart:io';
import 'dart:typed_data';

import 'remote_store.dart';

/// A bucket in memory, for tests. [reachable] false makes every call fail
/// the way a switched-off server does.
class MemoryStore implements RemoteStore {
  final objects = <String, ({Uint8List bytes, Map<String, String> metadata})>{};
  bool reachable = true;

  /// Each object's ETag: a new one on every put, as a changed object gets.
  final _etags = <String, String>{};
  var _puts = 0;

  void _check() {
    if (!reachable) throw const RemoteException(RemoteFailure.unreachable, 'The bucket is out of reach');
  }

  @override
  Future<void> put(
    String key,
    Stream<Uint8List> bytes, {
    required int size,
    Map<String, String> metadata = const {},
    void Function(int sent)? onProgress,
  }) async {
    _check();
    final all = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      all.add(chunk);
      onProgress?.call(all.length);
    }
    objects[key] = (bytes: all.takeBytes(), metadata: {for (final e in metadata.entries) e.key.toLowerCase(): e.value});
    _etags[key] = '"put-${++_puts}"';
  }

  @override
  Future<Uint8List?> get(String key) async {
    _check();
    return objects[key]?.bytes;
  }

  @override
  Future<bool> download(String key, IOSink sink, {void Function(int received)? onProgress}) async {
    _check();
    final o = objects[key];
    if (o == null) return false;
    sink.add(o.bytes);
    onProgress?.call(o.bytes.length);
    return true;
  }

  @override
  Future<RemoteObject?> head(String key) async {
    _check();
    final o = objects[key];
    return o == null ? null : RemoteObject(key: key, size: o.bytes.length, etag: _etags[key], metadata: o.metadata);
  }

  @override
  Stream<RemoteObject> list(String prefix) async* {
    _check();
    for (final e in objects.entries.toList()) {
      if (e.key.startsWith(prefix)) yield RemoteObject(key: e.key, size: e.value.bytes.length, etag: _etags[e.key]);
    }
  }

  @override
  Future<void> delete(String key) async {
    _check();
    objects.remove(key);
    _etags.remove(key);
  }

  @override
  void close() {}
}
