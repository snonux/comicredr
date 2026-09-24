import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import 'input/reader_keyboard.dart';
import 'providers.dart';

class ComicRedrApp extends StatelessWidget {
  const ComicRedrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ComicRedr',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0B6FB4), useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF0B6FB4),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const ShellScreen(),
    );
  }
}

/// M2 placeholder: opens nothing yet, but wires the keyboard layer end to
/// end so every binding can be tried on the laptop and a phone keyboard.
class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  String _pending = '';
  bool _showKeymap = false;

  void _onCommand(ReaderCommand command) {
    ref.read(lastCommandProvider.notifier).set(command);
    setState(() {
      if (command.intent == ReaderIntent.showKeymap) {
        _showKeymap = !_showKeymap;
      } else if (command.intent == ReaderIntent.back) {
        _showKeymap = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final keymap = ref.watch(keymapProvider);
    final last = ref.watch(lastCommandProvider);
    final theme = Theme.of(context);
    return ReaderKeyboard(
      keymap: keymap,
      onCommand: _onCommand,
      onPendingChanged: (p) => setState(() => _pending = p),
      child: Scaffold(
        body: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('ComicRedr', style: theme.textTheme.displaySmall),
                  const SizedBox(height: 12),
                  Text('Nothing to open yet. Press ? for the keymap.', style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 24),
                  Text(
                    last == null ? '' : last.toString(),
                    key: const Key('last-command'),
                    style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            if (_pending.isNotEmpty)
              Positioned(
                right: 16,
                bottom: 16,
                child: Text(_pending, style: theme.textTheme.titleMedium?.copyWith(fontFamily: 'monospace')),
              ),
            if (_showKeymap) KeymapOverlay(keymap: keymap),
          ],
        ),
      ),
    );
  }
}

/// The `?` overlay, generated from the same table the app binds from, so it
/// cannot drift from the real keys.
class KeymapOverlay extends StatelessWidget {
  const KeymapOverlay({super.key, required this.keymap});

  final Keymap keymap;

  @override
  Widget build(BuildContext context) {
    final byIntent = <ReaderIntent, List<Binding>>{};
    for (final b in keymap.bindings) {
      byIntent.putIfAbsent(b.intent, () => []).add(b);
    }
    final theme = Theme.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: theme.colorScheme.surface.withValues(alpha: 0.96),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            for (final MapEntry(key: intent, value: bindings) in byIntent.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 200,
                      child: Text(
                        bindings.map(Keymap.describe).join('  '),
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                    Expanded(child: Text(intent.description)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
