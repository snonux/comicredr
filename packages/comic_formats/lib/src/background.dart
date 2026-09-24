import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'cbz.dart';
import 'document.dart';

/// Runs a [ComicDocument] on its own isolate, so archive reads and inflates
/// never touch the UI isolate (design plan section 1: nothing blocks the
/// page turn). The document is opened on the worker; only page bytes cross
/// back, as transferable buffers.
class BackgroundDocument implements ComicDocument {
  BackgroundDocument._(this._send, this._port, this._receive, this.pageCount, this._isolate) {
    _receive.listen(_onReply);
  }

  /// Opens the ZIP at [path] on a new isolate.
  static Future<BackgroundDocument> openCbz(String path) async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(_worker, (receive.sendPort, path));
    final first = Completer<Object?>();
    late StreamSubscription<Object?> sub;
    final broadcast = receive.asBroadcastStream();
    sub = broadcast.listen((m) {
      sub.cancel();
      first.complete(m);
    });
    final hello = await first.future;
    if (hello case (SendPort send, int pages)) {
      return BackgroundDocument._(send, receive, broadcast, pages, isolate);
    }
    receive.close();
    isolate.kill();
    throw FormatException('$hello');
  }

  final SendPort _send;
  final ReceivePort _port;
  final Stream<Object?> _receive;
  final Isolate _isolate;
  final Map<int, Completer<Object?>> _pending = {};
  int _next = 0;

  @override
  final int pageCount;

  Future<Object?> _call(String op, [int arg = 0]) {
    final id = _next++;
    final c = _pending[id] = Completer<Object?>();
    _send.send((id, op, arg));
    return c.future;
  }

  void _onReply(Object? m) {
    if (m case (int id, Object? value)) {
      final c = _pending.remove(id);
      if (value is _Failure) {
        c?.completeError(FormatException(value.message));
      } else {
        c?.complete(value);
      }
    }
  }

  @override
  Future<Uint8List?> rawPage(int index) async =>
      (await _call('page', index) as TransferableTypedData).materialize().asUint8List();

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight}) async =>
      PageImage((await rawPage(index))!);

  @override
  Future<ComicMeta?> embeddedMetadata() async => await _call('meta') as ComicMeta?;

  @override
  Future<void> close() async {
    await _call('close');
    _port.close();
    _isolate.kill();
  }
}

class _Failure {
  const _Failure(this.message);
  final String message;
}

Future<void> _worker((SendPort, String) args) async {
  final (reply, path) = args;
  final CbzDocument doc;
  try {
    doc = CbzDocument.open(path);
  } catch (e) {
    reply.send('$e');
    return;
  }
  final requests = ReceivePort();
  reply.send((requests.sendPort, doc.pageCount));
  await for (final m in requests) {
    final (int id, String op, int arg) = m as (int, String, int);
    try {
      switch (op) {
        case 'page':
          reply.send((id, TransferableTypedData.fromList([(await doc.rawPage(arg))!])));
        case 'meta':
          reply.send((id, await doc.embeddedMetadata()));
        case 'close':
          await doc.close();
          reply.send((id, null));
          requests.close();
      }
    } catch (e) {
      reply.send((id, _Failure('$e')));
    }
  }
}
