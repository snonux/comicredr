import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/book_paths.dart';
import '../data/data_dirs.dart';
import '../data/sidecar.dart';
import 'library_store.dart';

/// Called for each book a scan reads, to merge its sidecar into the index.
typedef OnBookRead = Future<void> Function(String path, String contentKey, {required bool folder});

/// Where a scan is, for the library's status line.
class ScanStatus {
  const ScanStatus({this.running = false, this.done = 0, this.total = 0, this.failed = const []});

  final bool running;

  /// Books read in phase two so far, out of [total] new or changed ones.
  final int done;
  final int total;

  /// Files that looked like books but could not be read, with why.
  final List<(String, String)> failed;
}

/// A book-shaped entry found under a root in phase one.
typedef Candidate = ({String relPath, int size, int mtimeMs});

/// The two-phase incremental scan (design plan section 4). Phase one walks
/// every root and compares size and mtime against the index, cheap enough
/// to run on every launch. Phase two opens only new or changed books, on
/// worker isolates, a few at a time: page count, metadata and a 512 px cover
/// each. Books land in the index one by one, so the library fills in while
/// the scan runs.
class LibraryScanner {
  LibraryScanner(this.store, {required this.coverDir, this.onBookRead, int? workers})
    : workers = workers ?? math.max(1, math.min(3, Platform.numberOfProcessors - 2));

  final LibraryStore store;
  final String coverDir;
  final OnBookRead? onBookRead;
  final int workers;

  final _status = StreamController<ScanStatus>.broadcast();
  ScanStatus _last = const ScanStatus();
  Future<void>? _running;
  bool _again = false;

  Stream<ScanStatus> get status => _status.stream;
  ScanStatus get last => _last;

  /// Scans every root. A scan asked for while one runs starts once that one
  /// ends, rather than twice at once.
  Future<void> scan() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _scanOnce();
    } while (_again);
  }

  void _emit(ScanStatus s) {
    _last = s;
    if (!_status.isClosed) _status.add(s);
  }

  Future<void> _scanOnce() async {
    _emit(const ScanStatus(running: true));
    final todo = <(int, String, Candidate)>[];
    for (final root in await store.roots()) {
      final List<Candidate> found;
      try {
        found = await _find(root.path);
      } catch (e) {
        debugPrint('Cannot scan ${root.path}: $e');
        continue; // An unplugged drive is not an empty one: keep its books.
      }
      final known = await store.filesUnder(root.id);
      final seen = <String>{};
      for (final c in found) {
        seen.add(c.relPath);
        final k = known[c.relPath];
        final unchanged = k != null && k.size == c.size && k.mtime.millisecondsSinceEpoch ~/ 1000 == c.mtimeMs ~/ 1000;
        // A cleared cache loses covers; reading the book again puts it back.
        if (unchanged && File(coverFile(coverDir, k.contentKey)).existsSync()) continue;
        todo.add((root.id, root.path, c));
      }
      await store.forgetFiles(root.id, known.keys.where((k) => !seen.contains(k)));
    }
    await store.removeOrphans();

    // Nearest the top of the shelf first, so covers fill in in order.
    todo.sort((a, b) => naturalCompare(a.$3.relPath, b.$3.relPath));
    final failed = <(String, String)>[];
    var done = 0;
    _emit(ScanStatus(running: true, total: todo.length));
    var next = 0;
    Future<void> worker() async {
      while (next < todo.length) {
        final (rootId, rootPath, c) = todo[next++];
        final path = bookPath(rootPath, c.relPath);
        try {
          final info = await _read(path, coverDir);
          await store.putBook(rootId, c.relPath, c.size, DateTime.fromMillisecondsSinceEpoch(c.mtimeMs), info);
          try {
            await onBookRead?.call(path, info.contentKey, folder: info.kind == BookKind.folder);
          } catch (e) {
            debugPrint('Could not read the sidecar of $path: $e');
          }
        } catch (e) {
          failed.add((path, e is FormatException ? e.message : '$e'));
        }
        done++;
        _emit(ScanStatus(running: true, done: done, total: todo.length, failed: failed));
      }
    }

    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    await store.removeOrphans();
    _emit(ScanStatus(done: done, total: todo.length, failed: failed));
  }

  /// Rescans when anything under a root changes: inotify on Linux. Android
  /// rescans when the app comes back to the front instead. Returns a handle
  /// to stop watching.
  ///
  /// Dart's recursive watch only reports the top folder on Linux, so every
  /// folder under a root gets a watch of its own, set up again after each
  /// scan so new folders are watched too.
  Future<StreamSubscription<void>?> watch() async {
    if (!Platform.isLinux) return null;
    final events = StreamController<void>();
    var subs = <StreamSubscription<FileSystemEvent>>[];
    var closed = false;
    Timer? debounce;
    Future<void> rewatch() async {
      for (final s in subs) {
        await s.cancel();
      }
      subs = [];
      for (final root in await store.roots()) {
        if (closed) return;
        for (final dir in await _folders(root.path)) {
          try {
            // The app's own sidecar writes, and its data folder appearing in
            // ~/Comics, are not library changes.
            subs.add(
              Directory(dir)
                  .watch()
                  .where((e) => !isSidecarFile(e.path) && p.basename(e.path) != comicsDataName)
                  .listen((_) => events.add(null), onError: (_) {}),
            );
          } catch (e) {
            debugPrint('Cannot watch $dir: $e');
          }
        }
      }
    }

    await rewatch();
    events.onCancel = () async {
      closed = true;
      debounce?.cancel();
      for (final s in subs) {
        await s.cancel();
      }
    };
    // A copy of a big CBZ fires many events; scan once it goes quiet.
    return events.stream.listen((_) {
      debounce?.cancel();
      // Watch new folders before scanning, so a comic copied into one
      // while the scan runs still fires an event.
      debounce = Timer(const Duration(seconds: 2), () async {
        if (!closed) await rewatch();
        await scan();
      });
    });
  }

  Future<void> dispose() => _status.close();
}

// Top-level, so the closure sent to the worker captures a path and
// nothing else.
Future<List<Candidate>> _find(String root) => Isolate.run(() => findBooks(root));

Future<List<String>> _folders(String root) => Isolate.run(() {
  final out = <String>[];
  void walk(Directory d) {
    out.add(d.path);
    try {
      for (final e in d.listSync(followLinks: false)) {
        if (e is Directory && !p.basename(e.path).startsWith('.')) walk(e);
      }
    } on FileSystemException {
      // Unreadable: nothing under it to watch.
    }
  }

  walk(Directory(root));
  return out;
});

Future<BookInfo> _read(String path, String coverDir) => readBookInfoInBackground(path, coverDir: coverDir);

/// Phase one for one root: every comic file under [root], and every folder
/// book ([isFolderBook]: page images directly, no other book anywhere under
/// it), with size and mtime. A PNG, JPEG or WebP outside a folder book,
/// such as one beside CBZs or a cover.jpg beside image-folder comics, is a one-page comic of
/// its own.
/// Hidden files and folders are skipped. Runs on a worker isolate.
List<Candidate> findBooks(String root) {
  final out = <Candidate>[];
  void walk(Directory dir, String rel) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return; // Unreadable folder: skip it, keep going.
    }
    final images = entries.whereType<File>().where((f) => isPageEntry(p.basename(f.path))).toList();
    if (images.isNotEmpty && !holdsOtherBooks(entries)) {
      // A folder book: size is its pages' total, mtime the newest of them,
      // so an added or replaced page counts as a change. Not the folder's
      // own mtime: writing the sidecar inside it changes that.
      var size = 0;
      var mtime = 0;
      for (final f in images) {
        final s = f.statSync();
        size += s.size;
        mtime = math.max(mtime, s.modified.millisecondsSinceEpoch);
      }
      out.add((relPath: rel, size: size, mtimeMs: mtime));
      return;
    }
    for (final e in entries) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      final childRel = rel.isEmpty ? name : '$rel/$name';
      if (e is Directory) {
        walk(e, childRel);
      } else if (e is File && (isComicFileName(name) || isSingleImageName(name))) {
        final s = e.statSync();
        out.add((relPath: childRel, size: s.size, mtimeMs: s.modified.millisecondsSinceEpoch));
      }
    }
  }

  walk(Directory(root), '');
  return out;
}
