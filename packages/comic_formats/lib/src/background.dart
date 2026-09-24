import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'book_info.dart';
import 'document.dart';
import 'open.dart';
import 'page_facts.dart';

/// Runs a [ComicDocument] on another isolate, so archive inflates, file
/// reads and PDF renders never touch the UI isolate (design plan section 1:
/// nothing blocks the page turn). The document is opened on the worker;
/// only page bytes cross back, as transferable buffers.
///
/// A CBZ or a folder gets an isolate of its own. Every PDF shares one: each
/// isolate that touches PDFium starts its own PDFium worker, and two of those
/// at once crash the process, which the library scan reading covers while a
/// PDF is open would otherwise do.
class BackgroundDocument implements ComicDocument {
  BackgroundDocument._(this._host, this._doc, this.pageCount, this._ownsHost);

  /// Opens the book at [path] on a worker isolate, with the adapter
  /// [openDocument] picks for it.
  static Future<BackgroundDocument> open(String path) async {
    final pdf = _isPdf(path);
    final host = pdf ? await _Host.shared() : await _Host.spawn();
    try {
      final (int doc, int pages) = await host.call('open', path: path) as (int, int);
      return BackgroundDocument._(host, doc, pages, !pdf);
    } catch (_) {
      if (!pdf) host.kill();
      rethrow;
    }
  }

  final _Host _host;
  final int _doc;

  /// Whether the isolate is this book's own, to stop when it closes.
  final bool _ownsHost;

  @override
  final int pageCount;

  @override
  Future<Uint8List?> rawPage(int index) async =>
      (await _host.call('raw', doc: _doc, args: (index, 0, 0)) as TransferableTypedData?)?.materialize().asUint8List();

  @override
  Future<PageImage> page(int index, {required int targetWidth, required int targetHeight, PageRegion? region}) async {
    final (TransferableTypedData bytes, int? w, int? h, bool bgra, PageRegion? drawn) = await _host.call(
      'page',
      doc: _doc,
      args: (index, targetWidth, targetHeight),
      region: region,
    ) as (TransferableTypedData, int?, int?, bool, PageRegion?);
    return PageImage(bytes.materialize().asUint8List(), width: w, height: h, bgra: bgra, region: drawn);
  }

  @override
  Future<List<(int, int)?>> pageSizes() async => (await _host.call('sizes', doc: _doc) as List).cast<(int, int)?>();

  @override
  Future<List<PageFacts>> pageFacts() async => (await _host.call('facts', doc: _doc) as List).cast<PageFacts>();

  @override
  Future<ComicMeta?> embeddedMetadata() async => await _host.call('meta', doc: _doc) as ComicMeta?;

  @override
  Future<void> close() async {
    await _host.call('close', doc: _doc);
    if (_ownsHost) _host.kill();
  }
}

/// [readBookInfo] off the calling isolate: a PDF on the isolate every PDF
/// shares (see [BackgroundDocument]), anything else on a short-lived one.
Future<BookInfo> readBookInfoInBackground(String path, {required String coverDir}) async {
  if (_isPdf(path)) {
    return await (await _Host.shared()).call('info', path: path, coverDir: coverDir) as BookInfo;
  }
  return Isolate.run(() => readBookInfo(path, coverDir: coverDir));
}

/// Whether [path] is a PDF; a file that cannot be read is left for the
/// worker to refuse properly.
bool _isPdf(String path) {
  try {
    return bookKind(path) == BookKind.pdf;
  } catch (_) {
    return false;
  }
}

class _Failure {
  const _Failure(this.message);
  final String message;
}

typedef _Request = (
  int id,
  String op,
  int doc,
  (int, int, int) args,
  String? path,
  String? coverDir,
  PageRegion? region,
);

/// A worker isolate holding open documents, serving one request at a time,
/// newest first.
class _Host {
  _Host._(this._send, this._port, this._isolate) {
    _port.listen(_onReply);
  }

  static Future<_Host>? _shared;

  /// The isolate every PDF goes through, started once.
  static Future<_Host> shared() => _shared ??= spawn();

  static Future<_Host> spawn() async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(_hostMain, receive.sendPort);
    final replies = receive.asBroadcastStream();
    final send = await replies.first as SendPort;
    return _Host._(send, _Port(receive, replies), isolate);
  }

  final SendPort _send;
  final _Port _port;
  final Isolate _isolate;
  final Map<int, Completer<Object?>> _pending = {};
  int _next = 0;

  Future<Object?> call(
    String op, {
    int doc = -1,
    (int, int, int) args = (0, 0, 0),
    String? path,
    String? coverDir,
    PageRegion? region,
  }) {
    final id = _next++;
    final c = _pending[id] = Completer<Object?>();
    _send.send((id, op, doc, args, path, coverDir, region));
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

  void kill() {
    _port.close();
    _isolate.kill();
    for (final c in _pending.values) {
      c.completeError(const FormatException('The book was closed'));
    }
    _pending.clear();
  }
}

/// A receive port with its broadcast stream, so the first message (the
/// worker's send port) and the rest can be listened to separately.
class _Port {
  _Port(this._port, this._stream);
  final ReceivePort _port;
  final Stream<Object?> _stream;
  void listen(void Function(Object?) f) => _stream.listen(f);
  void close() => _port.close();
}

Future<void> _hostMain(SendPort reply) async {
  final requests = ReceivePort();
  reply.send(requests.sendPort);
  final docs = <int, ComicDocument>{};
  var nextDoc = 0;
  // One request at a time, newest first. A PDF render takes most of a
  // second, and the page just turned to was asked for last, after the
  // prefetches for the page before it, so it should not wait behind them.
  final queue = <_Request>[];
  Future<void>? busy;

  Future<void> serve(_Request r) async {
    final (id, op, doc, args, path, coverDir, region) = r;
    try {
      switch (op) {
        case 'open':
          final d = await openDocument(path!);
          docs[nextDoc] = d;
          reply.send((id, (nextDoc++, d.pageCount)));
        case 'page':
          final (index, w, h) = args;
          final p = await docs[doc]!.page(index, targetWidth: w, targetHeight: h, region: region);
          reply.send((id, (TransferableTypedData.fromList([p.bytes]), p.width, p.height, p.bgra, p.region)));
        case 'raw':
          final raw = await docs[doc]!.rawPage(args.$1);
          reply.send((id, raw == null ? null : TransferableTypedData.fromList([raw])));
        case 'sizes':
          reply.send((id, await docs[doc]!.pageSizes()));
        case 'facts':
          reply.send((id, await docs[doc]!.pageFacts()));
        case 'meta':
          reply.send((id, await docs[doc]!.embeddedMetadata()));
        case 'close':
          await docs.remove(doc)?.close();
          reply.send((id, null));
        case 'info':
          reply.send((id, await readBookInfo(path!, coverDir: coverDir!)));
      }
    } catch (e) {
      reply.send((id, _Failure(e is FormatException ? e.message : '$e')));
    }
  }

  Future<void> pump() async {
    while (queue.isNotEmpty) {
      await serve(queue.removeLast());
    }
  }

  await for (final m in requests) {
    final r = m as _Request;
    if (r.$2 == 'close') {
      // Whatever is still queued for this book is for a book going away.
      queue.removeWhere((q) {
        if (q.$3 != r.$3) return false;
        reply.send((q.$1, const _Failure('The book was closed')));
        return true;
      });
    }
    queue.add(r);
    busy ??= pump().whenComplete(() => busy = null);
  }
}
