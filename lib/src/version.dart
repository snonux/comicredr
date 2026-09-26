/// The app version, shown in the empty screen and the `?` overlay.
///
/// pubspec.yaml is the source of truth; test/version_test.dart fails when
/// the two disagree, so bump both together. The Linux `--version` flag
/// takes its value from pubspec.yaml through CMake.
const appVersion = '0.2.1';
