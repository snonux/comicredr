import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reader_input/reader_input.dart';

import 'version.dart';

/// The `?` overlay, generated from the same table the app binds from, so it
/// cannot drift from the real keys. `/` searches it: fuzzy words, or a
/// regular expression between slashes. Esc clears the search, then closes.
class KeymapOverlay extends StatefulWidget {
  const KeymapOverlay({
    super.key,
    required this.keymap,
    this.keysFile,
    this.dataDir,
    this.warnings = const [],
    this.onDone,
  });

  final Keymap keymap;

  /// The `keys.toml` the keymap was read from, if there was one.
  final String? keysFile;

  /// Where the app keeps its index, covers and thumbnails.
  final String? dataDir;

  /// What was wrong in that file.
  final List<String> warnings;

  /// Called when the search field hands the keys back to the reader.
  final VoidCallback? onDone;

  @override
  State<KeymapOverlay> createState() => KeymapOverlayState();
}

class KeymapOverlayState extends State<KeymapOverlay> {
  final _query = TextEditingController();
  final _field = FocusNode(debugLabel: 'keymap-search');
  bool _searching = false;

  @override
  void dispose() {
    _query.dispose();
    _field.dispose();
    super.dispose();
  }

  /// `/` while the overlay is open.
  void startSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _field.requestFocus();
    });
  }

  /// Esc: clears a search first. Returns false when there was none, and
  /// the overlay should close.
  bool back() {
    if (!_searching && _query.text.isEmpty) return false;
    _stopSearch(clear: true);
    return true;
  }

  void _stopSearch({required bool clear}) {
    setState(() {
      if (clear) {
        _query.clear();
        _searching = false;
      }
    });
    _field.unfocus();
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final found = searchKeymap(widget.keymap, _query.text);
    final mono = const TextStyle(fontFamily: 'monospace');
    return Positioned.fill(
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        label: 'Keyboard shortcuts',
        child: ColoredBox(
          color: theme.colorScheme.surface.withValues(alpha: 0.96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: _searching || _query.text.isNotEmpty
                    ? CallbackShortcuts(
                        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _stopSearch(clear: true)},
                        child: TextField(
                          key: const Key('keymap-search'),
                          controller: _query,
                          focusNode: _field,
                          autofocus: true,
                          style: mono,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Search: words, fuzzy (fulscr), or /regex/',
                            errorText: found.error,
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() {}),
                          // Enter keeps the filter and hands the keys back.
                          onSubmitted: (_) => _stopSearch(clear: false),
                        ),
                      )
                    : Text('Keys  ·  / searches  ·  Esc closes', style: theme.textTheme.titleMedium),
              ),
              if (widget.keysFile != null || widget.warnings.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: Text(
                    [if (widget.keysFile != null) 'Keys from ${widget.keysFile}', ...widget.warnings].join('\n'),
                    key: const Key('keymap-file'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: widget.warnings.isEmpty ? null : theme.colorScheme.error,
                    ),
                  ),
                ),
              if (widget.dataDir case final dir?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: Text(
                    'Library, settings, covers and history are kept in $dir; '
                    'everything else about a comic is in its sidecar.',
                    key: const Key('app-data'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              Expanded(
                child: Stack(
                  children: [
                    found.entries.isEmpty && found.error == null
                        ? Center(child: Text('Nothing matches "${_query.text}"'))
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
                            children: [
                              for (final e in found.entries) ...[
                                if (e.intent == ReaderIntent.regionUpperHalf && _query.text.isEmpty)
                                  Padding(
                                    key: const Key('keymap-parts'),
                                    padding: const EdgeInsets.only(top: 12, bottom: 4),
                                    child: Text(
                                      'Part of the page, enlarged: halves, thirds and quarters, '
                                      'numbered top to bottom, left to right',
                                      style: theme.textTheme.titleSmall,
                                    ),
                                  ),
                                MergeSemantics(
                                  child: Padding(
                                    key: ValueKey('keymap-${e.intent.name}'),
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          width: 200,
                                          child: Text(e.keys.isEmpty ? '(no key)' : e.keys.join('  '), style: mono),
                                        ),
                                        Expanded(child: Text(e.intent.description)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                    // In a corner, so the keymap list keeps its whole height.
                    Positioned(
                      right: 24,
                      bottom: 16,
                      child: Text(
                        'ComicRedr $appVersion',
                        key: const Key('keymap-version'),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
