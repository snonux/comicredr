import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_store.dart';
import '../providers.dart';
import '../reader/reader_notifier.dart';
import 'library_detection.dart';
import 'library_store.dart';
import 'scanner.dart';

/// Where covers go: `<cache>/covers`, set at startup from the platform's
/// cache directory. Always safe to delete; a rescan puts them back.
final coverDirProvider = Provider<String>((ref) => '${Directory.systemTemp.path}/comicredr-covers');

final libraryStoreProvider = Provider<LibraryStore>((ref) => LibraryStore(ref.watch(databaseProvider)));

final scannerProvider = Provider<LibraryScanner>((ref) {
  final sidecars = ref.watch(sidecarSyncProvider);
  final scanner = LibraryScanner(
    ref.watch(libraryStoreProvider),
    coverDir: ref.watch(coverDirProvider),
    onBookRead: (path, key, {required folder}) => sidecars.attach(path, key, folder: folder),
  );
  ref.onDispose(scanner.dispose);
  return scanner;
});

final scanStatusProvider = StreamProvider<ScanStatus>((ref) => ref.watch(scannerProvider).status);

final booksProvider = StreamProvider<List<LibraryBook>>((ref) => ref.watch(libraryStoreProvider).watchBooks());

final rootsProvider = StreamProvider<List<RootInfo>>((ref) => ref.watch(libraryStoreProvider).watchRoots());

final bookmarksProvider = StreamProvider.family<List<BookmarkInfo>, String>(
  (ref, key) => ref.watch(libraryStoreProvider).watchBookmarks(key),
);

/// Every book's bookmarks and marks, for the library's Bookmarks tab.
final allBookmarksProvider = StreamProvider<List<BookmarkInfo>>(
  (ref) => ref.watch(libraryStoreProvider).watchAllBookmarks(),
);

final historyProvider = StreamProvider<List<HistoryEntry>>((ref) => ref.watch(libraryStoreProvider).watchHistory());

/// The whole-library panel pass. It starts after every library scan and
/// holds off while the reader is busy or pages were turned in the last
/// second and a half.
final libraryDetectionProvider = Provider<LibraryDetection>((ref) {
  final settings = ref.watch(settingsStoreProvider);
  final sidecars = ref.watch(sidecarSyncProvider);
  var lastTurn = DateTime(0);
  ref.listen(readerProvider, (_, _) => lastTurn = DateTime.now());
  final detection = LibraryDetection(
    library: ref.watch(libraryStoreProvider),
    panels: ref.watch(panelStoreProvider),
    detector: () => ref.read(panelDetectorProvider.future),
    enabled: () async =>
        await settings.loadBool(SettingsStore.detectLibrary).catchError((_) => null) ?? detectLibraryByDefault,
    onBook: (book) => sidecars.attach(book.path, book.key, folder: book.isFolder),
    onSaved: sidecars.touch,
    busy: () =>
        ref.read(readerProvider.notifier).detecting ||
        ref.read(readerProvider).loading ||
        DateTime.now().difference(lastTurn) < const Duration(milliseconds: 1500),
    openKey: () => ref.read(readerProvider).book?.key,
  );
  final scans = ref.watch(scannerProvider).status.where((s) => !s.running).listen((_) => detection.run());
  ref.onDispose(() async {
    await scans.cancel();
    await detection.dispose();
  });
  return detection;
});

/// On by default on the laptop. Off on the phone, where it would run the
/// battery down; Settings turns it on.
bool get detectLibraryByDefault => defaultTargetPlatform != TargetPlatform.android;

final detectionStatusProvider = StreamProvider<DetectionStatus>((ref) => ref.watch(libraryDetectionProvider).status);
