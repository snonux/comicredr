import 'dart:async';
import 'dart:io';

import 'package:comicredr/src/data/data_dirs.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs before every test file under test/: gives the app an empty scratch
/// home, so a test never reads or writes the developer's own data. Widget
/// tests run the real start-up, which adds `~/Comics` to an empty library,
/// keeps its data in `~/Comics/.comicredr` and reads `keys.toml` and
/// installed models from there; with the real HOME a run scanned a real
/// library, wrote test positions into its sidecars, and failed on what it
/// found. The scratch home has no `Comics`, as on CI.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final home = Directory.systemTemp.createTempSync('comicredr_home_');
  debugUseHome(home.path);
  tearDownAll(() {
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A file still open at the end is left to the temp cleaner.
    }
  });
  await testMain();
}
