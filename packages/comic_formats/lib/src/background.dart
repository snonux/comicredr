import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'document.dart';
import 'open.dart';

/// Runs a [ComicDocument] on its own isolate, so archive inflates, file
/// reads and PDF renders never touch the UI isolate (design plan section 1:
/// nothing blocks the page turn). The document is opened on the worker;
/// only page bytes cross back, as transferable buffers.
class BackgroundDocument implements ComicDocument {
  BackgroundDocument._(this._send, this._port, this._receive, this.pageCount, this._isolate) {
    _receive.listen(_onReply);
  }

  /// Opens the book at [path] on a new isolate, with the adapter
  /// [openDocument] picks for it.
  static Future<BackgroundDocument> open(String path) async {
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

  Future<Object?> _call(String op, [(int, int, int) args = (0, 0, 0)]) {
    final id = _next++;
    final c = _pending[id] = Completer<Object?>();
    _send.send((id, op, args));
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
      (await _call('raw', (index, 0, 0)) as TransferableTypedData?)?.materialize().asUint8List();

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight}) async {
    final (TransferableTypedData bytes, int? w, int? h, bool bgra) =
        await _call('page', (index, targetWidth, targetHeight)) as (TransferableTypedData, int?, int?, bool);
    return PageImage(bytes.materialize().asUint8List(), width: w, height: h, bgra: bgra);
  }

  @override
  Future<ComicMeta?> embeddedMetadata() async => await _call('meta') as ComicMeta?;

  @override
  Future<void> close() async {
    await _call('close');
    _port.close();
    _isolate.kill();
    for (final c in _pending.values) {
      c.completeError(const FormatException('The book was closed'));
    }
    _pending.clear();
  }
}

class _Failure {
  const _Failure(this.message);
  final String message;
}

Future<void> _worker((SendPort, String) args) async {
  final (reply, path) = args;
  final ComicDocument doc;
  try {
    doc = await openDocument(path);
  } catch (e) {
    reply.send('$e');
    return;
  }
  final requests = ReceivePort();
  reply.send((requests.sendPort, doc.pageCount));
  // One request at a time, newest first. A PDF render takes most of a
  // second, and the page just turned to was asked for last, after the
  // prefetches for the page before it, so it should not wait behind them.
  final queue = <(int, String, (int, int, int))>[];
  Future<void>? busy;
  Future<void> pump() async {
    while (queue.isNotEmpty) {
      final (id, op, args) = queue.removeLast();
      try {
        switch (op) {
          case 'page':
            final (index, w, h) = args;
            final p = await doc.page(index, targetWidth: w, targetHeight: h);
            reply.send((id, (TransferableTypedData.fromList([p.bytes]), p.width, p.height, p.bgra)));
          case 'raw':
            final raw = await doc.rawPage(args.$1);
            reply.send((id, raw == null ? null : TransferableTypedData.fromList([raw])));
          case 'meta':
            reply.send((id, await doc.embeddedMetadata()));
        }
      } catch (e) {
        reply.send((id, _Failure('$e')));
      }
    }
  }

  await for (final m in requests) {
    final request = m as (int, String, (int, int, int));
    if (request.$2 == 'close') {
      // Whatever is still queued is for a book that is going away.
      for (final (id, _, _) in queue) {
        reply.send((id, const _Failure('The book was closed')));
      }
      queue.clear();
      await busy;
      await doc.close();
      reply.send((request.$1, null));
      requests.close();
      break;
    }
    queue.add(request);
    busy ??= pump().whenComplete(() => busy = null);
  }
}
