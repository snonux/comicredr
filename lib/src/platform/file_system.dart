import 'dart:io';
import 'dart:typed_data';

/// The platform seam for files (design plan section 8). With All-files
/// access on a sideloaded Android build, [IoFileSystem] serves both targets
/// over real paths; a SAF-backed implementation is only needed later, for
/// removable SD volumes.
abstract interface class PlatformFileSystem {
  Stream<String> list(String root, {bool recursive = true});
  Future<Uint8List> readHead(String path, int bytes);
  Future<RandomAccessFile> open(String path);
  Future<FileStat> stat(String path);
}

class IoFileSystem implements PlatformFileSystem {
  const IoFileSystem();

  @override
  Stream<String> list(String root, {bool recursive = true}) =>
      Directory(root).list(recursive: recursive, followLinks: false).where((e) => e is File).map((e) => e.path);

  @override
  Future<Uint8List> readHead(String path, int bytes) async {
    final f = await File(path).open();
    try {
      return await f.read(bytes);
    } finally {
      await f.close();
    }
  }

  @override
  Future<RandomAccessFile> open(String path) => File(path).open();

  @override
  Future<FileStat> stat(String path) => FileStat.stat(path);
}
