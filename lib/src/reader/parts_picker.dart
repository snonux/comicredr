import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import 'reader_notifier.dart';
import 'region.dart';
import 'thumbnails.dart';

/// The page parts by touch (a two-finger tap, `gp`, or the status line's
/// button): the page in small, cut into halves, thirds, strips or quarters,
/// and a tap on a part enlarges it as its keys (`H1`, `21`...) would. After
/// that, taps and swipes go part by part as the arrows do.
///
/// The parts are drawn as the page is seen, turned with the comic, since
/// that is how the keys pick them.
class PartsPicker extends ConsumerStatefulWidget {
  const PartsPicker({super.key, required this.split, required this.onPick, required this.onClose});

  /// The split shown first: the one being stepped through, else the last
  /// one picked.
  final PageSplit split;

  /// A part, Whole page or Stop was picked: the intent its keys send.
  final ValueChanged<ReaderIntent> onPick;
  final VoidCallback onClose;

  @override
  ConsumerState<PartsPicker> createState() => _PartsPickerState();
}

class _PartsPickerState extends ConsumerState<PartsPicker> {
  late PageSplit _split = widget.split;
  String? _thumb;
  int? _thumbPage;

  void _load(Thumbnails? thumbs, int page) {
    if (thumbs == null || _thumbPage == page) return;
    _thumbPage = page;
    _thumb = null;
    unawaited(
      thumbs.get(page, size: 512).then((path) {
        if (mounted && _thumbPage == page) setState(() => _thumb = path);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerProvider);
    final thumbs = ref.watch(thumbnailsProvider);
    final unit = s.unit;
    final region = s.region;
    final page = region != null && unit.contains(region.page) ? region.page : (unit.isEmpty ? 0 : unit.first);
    _load(thumbs, page);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final turned = s.rotation.isOdd;

    Widget part(int i) {
      final current = region != null && region.split == _split && region.part == i;
      return Material(
        color: current ? scheme.primary.withValues(alpha: 0.45) : Colors.black.withValues(alpha: 0.2),
        child: InkWell(
          key: Key('part-${_split.digit}${i + 1}'),
          onTap: () => widget.onPick(regionIntent(_split, i)),
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: Colors.white70)),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_split.names[i], style: theme.textTheme.titleSmall?.copyWith(color: Colors.white)),
                      Text(
                        '${_split.letter}${i + 1}  ·  ${_split.digit}${i + 1}',
                        style: theme.textTheme.labelSmall?.copyWith(color: Colors.white70, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final grid = Column(
      children: [
        for (var r = 0; r < _split.rows; r++)
          Expanded(
            child: Row(
              children: [for (var c = 0; c < _split.columns; c++) Expanded(child: part(r * _split.columns + c))],
            ),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = (constraints.maxWidth - 48).clamp(120.0, 440.0);
        final maxH = (constraints.maxHeight - 200).clamp(120.0, 640.0);
        // Until the thumbnail is there, a page-shaped box the parts can be
        // tapped on all the same.
        final placeholder = AspectRatio(
          aspectRatio: turned ? 3 / 2 : 2 / 3,
          child: ColoredBox(color: scheme.surfaceContainerHighest),
        );
        final thumb = _thumb;
        final picture = thumb == null
            ? placeholder
            : RotatedBox(
                quarterTurns: s.rotation,
                child: Image.file(
                  File(thumb),
                  key: ValueKey(thumb),
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => placeholder,
                ),
              );
        return GestureDetector(
          key: const Key('partsPicker'),
          // A tap beside the card closes it.
          onTap: widget.onClose,
          behavior: HitTestBehavior.opaque,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.7),
            child: SafeArea(
              child: Center(
                child: GestureDetector(
                  onTap: () {}, // Taps on the card stay on it.
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Enlarge a part of the page', style: theme.textTheme.titleMedium),
                          const SizedBox(height: 8),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: SegmentedButton<PageSplit>(
                              showSelectedIcon: false,
                              style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                              segments: [
                                for (final split in PageSplit.values)
                                  ButtonSegment(
                                    value: split,
                                    label: Text(split.label, key: Key('split-${split.name}')),
                                  ),
                              ],
                              selected: {_split},
                              onSelectionChanged: (v) => setState(() => _split = v.first),
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Whatever room the rest leaves, so the buttons never fall off a
                          // small phone.
                          Flexible(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
                              child: Stack(
                                children: [
                                  picture,
                                  Positioned.fill(child: grid),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            children: [
                              if (s.parts != null) ...[
                                TextButton(
                                  key: const Key('partsWhole'),
                                  onPressed: () => widget.onPick(ReaderIntent.regionWhole),
                                  child: const Text('Whole page'),
                                ),
                                TextButton(
                                  key: const Key('partsStop'),
                                  onPressed: () => widget.onPick(ReaderIntent.regionPrevious),
                                  child: const Text('Stop parts'),
                                ),
                              ],
                              TextButton(
                                key: const Key('partsClose'),
                                onPressed: widget.onClose,
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
