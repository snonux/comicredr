import 'dart:io';

import 'package:reader_input/reader_input.dart';

/// Writes the default keymap to docs/keys.toml, the file people copy to
/// ~/.config/comicredr/keys.toml. Run from the repository root after
/// changing Keymap.defaults(); a test fails until it is regenerated.
void main() => File('docs/keys.toml').writeAsStringSync(keymapToToml(Keymap.defaults()));
