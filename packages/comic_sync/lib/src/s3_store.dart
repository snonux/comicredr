import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' show ClientException;
import 'package:minio/minio.dart';

import 'config.dart';
import 'remote_store.dart';

/// The bucket over S3, through the `minio` package: SigV4, path-style
/// addressing, multipart uploads. Written for Garage, and the same for
/// MinIO or AWS.
///
/// Every call gives up after [connectTimeout] without a connection, so a
/// home cluster that is switched off fails fast instead of hanging, and
/// the whole call after [callTimeout]. On Linux an `https_proxy` in the
/// environment is used.
class S3Store implements RemoteStore {
  S3Store(
    this.config, {
    this.connectTimeout = const Duration(seconds: 3),
    this.callTimeout = const Duration(seconds: 30),
  }) : _minio = Minio(
         endPoint: config.endpoint.host,
         port: config.endpoint.hasPort ? config.endpoint.port : null,
         useSSL: config.secure,
         accessKey: config.accessKey,
         secretKey: config.secretKey,
         region: config.region,
         pathStyle: true,
       );

  final S3Config config;
  final Duration connectTimeout;
  final Duration callTimeout;
  final Minio _minio;

  /// Runs [f] with HTTP clients that time out on connecting and honour the
  /// proxy variables, and turns what can go wrong into a RemoteException.
  /// [timeout] false for transfers, which take as long as they take.
  Future<T> _call<T>(Future<T> Function() f, {bool timeout = true}) async {
    try {
      final run = HttpOverrides.runWithHttpOverrides(f, _Overrides(connectTimeout));
      return await (timeout ? run.timeout(callTimeout) : run);
    } on RemoteException {
      rethrow;
    } catch (e) {
      throw describe(e);
    }
  }

  static bool _missing(Object e) =>
      e is MinioS3Error && e.response?.statusCode == 404 && e.error?.code != 'NoSuchBucket';

  /// What went wrong, in words, from whatever the client threw.
  static RemoteException describe(Object e) {
    if (e is RemoteException) return e;
    if (e is TimeoutException || e is SocketException || e is HttpException || e is ClientException) {
      return RemoteException(RemoteFailure.unreachable, 'No answer from the server (${_why(e)})');
    }
    if (e is HandshakeException || e is TlsException) {
      return RemoteException(RemoteFailure.certificate, 'The server\'s certificate was refused (${_short(e)})');
    }
    if (e is MinioS3Error) {
      final code = e.error?.code;
      final status = e.response?.statusCode;
      if (code == 'NoSuchBucket') return const RemoteException(RemoteFailure.noBucket, 'There is no such bucket');
      if (status == 403 ||
          status == 401 ||
          const {'AccessDenied', 'InvalidAccessKeyId', 'SignatureDoesNotMatch'}.contains(code)) {
        return RemoteException(RemoteFailure.denied, 'The keys were refused (${code ?? status})');
      }
      return RemoteException(RemoteFailure.other, 'The server said ${code ?? status}: ${e.message ?? ''}'.trim());
    }
    return RemoteException(RemoteFailure.other, _short(e));
  }

  /// Why a connection failed, in a few words rather than the socket's
  /// whole message.
  static String _why(Object e) {
    final s = e.toString().toLowerCase();
    if (e is TimeoutException || s.contains('timed out')) return 'timed out';
    if (s.contains('connection refused')) return 'connection refused';
    if (s.contains('failed host lookup') || s.contains('name or service not known')) return 'no such host';
    if (s.contains('network is unreachable') || s.contains('no route to host')) return 'network unreachable';
    return 'no connection';
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  @override
  Future<void> put(
    String key,
    Stream<Uint8List> bytes, {
    required int size,
    Map<String, String> metadata = const {},
    void Function(int sent)? onProgress,
  }) => _call(
    () => _minio.putObject(
      config.bucket,
      key,
      bytes,
      size: size,
      // 16 MiB parts: a comic of a few hundred MB is a few dozen requests.
      chunkSize: 16 * 1024 * 1024,
      metadata: metadata,
      onProgress: onProgress,
    ),
    timeout: false,
  );

  @override
  Future<Uint8List?> get(String key) => _call(() async {
    try {
      final stream = await _minio.getObject(config.bucket, key);
      final all = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        all.add(chunk);
      }
      return all.takeBytes();
    } catch (e) {
      if (_missing(e)) return null;
      rethrow;
    }
  }, timeout: false);

  @override
  Future<RemoteObject?> head(String key) => _call(() async {
    try {
      final stat = await _minio.statObject(config.bucket, key, retrieveAcls: false);
      return RemoteObject(
        key: key,
        size: stat.size ?? 0,
        etag: stat.etag,
        metadata: {
          for (final e in (stat.metaData ?? const <String, String?>{}).entries)
            if (e.value != null) e.key.toLowerCase(): e.value!,
        },
      );
    } catch (e) {
      // A HEAD answer has no body, so a missing object is only its 404.
      if (e is MinioS3Error && e.response?.statusCode == 404) return null;
      rethrow;
    }
  });

  @override
  Stream<RemoteObject> list(String prefix) async* {
    final pages = StreamIterator(
      HttpOverrides.runWithHttpOverrides(
        () => _minio.listObjectsV2(config.bucket, prefix: prefix, recursive: true),
        _Overrides(connectTimeout),
      ),
    );
    try {
      while (true) {
        final bool more;
        try {
          more = await pages.moveNext().timeout(callTimeout);
        } catch (e) {
          throw describe(e);
        }
        if (!more) break;
        for (final o in pages.current.objects) {
          final key = o.key;
          if (key == null) continue;
          yield RemoteObject(key: key, size: o.size ?? 0, etag: o.eTag);
        }
      }
    } finally {
      await pages.cancel();
    }
  }

  @override
  Future<void> delete(String key) => _call(() => _minio.removeObject(config.bucket, key));

  @override
  void close() {}
}

class _Overrides extends HttpOverrides {
  _Overrides(this.connectTimeout);

  final Duration connectTimeout;

  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)
    ..connectionTimeout = connectTimeout
    ..findProxy = HttpClient.findProxyFromEnvironment;
}
