import 'package:flutter/material.dart';

import '../hotkeys.dart';
import 'folder_filter.dart';

/// `F`, or the filter button on the Folders tab: the type, size, date and
/// completed filter. Each change applies at once, so the covers behind it follow;
/// Tab and Space work the chips, Esc or Done closes it.
Future<void> showFolderFilter(
  BuildContext context, {
  required FolderFilter filter,
  required List<String> formats,
  required ValueChanged<FolderFilter> onChanged,
}) => showDialog<void>(
  context: context,
  builder: (context) => _FolderFilterDialog(filter: filter, formats: formats, onChanged: onChanged),
);

class _FolderFilterDialog extends StatefulWidget {
  const _FolderFilterDialog({required this.filter, required this.formats, required this.onChanged});

  final FolderFilter filter;
  final List<String> formats;
  final ValueChanged<FolderFilter> onChanged;

  @override
  State<_FolderFilterDialog> createState() => _FolderFilterDialogState();
}

class _FolderFilterDialogState extends State<_FolderFilterDialog> {
  late FolderFilter _filter = widget.filter;

  void _set(FolderFilter f) {
    setState(() => _filter = f);
    widget.onChanged(f);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(text, style: theme.textTheme.titleSmall),
    );
    // A format filtered on that is no longer in the library still shows, so
    // it can be taken off.
    final formats = {...widget.formats, ..._filter.formats}.toList()
      ..sort((a, b) => formatLabel(a).compareTo(formatLabel(b)));
    return DialogHotkeys(
      child: AlertDialog(
        key: const Key('filterDialog'),
        title: const Text('Filter the Folders tab'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                heading('Type (none picked: every type)'),
                _chips([
                  for (final (i, f) in formats.indexed)
                    FilterChip(
                      key: Key('filterType-$f'),
                      autofocus: i == 0,
                      label: Text(formatLabel(f)),
                      selected: _filter.formats.contains(f),
                      onSelected: (_) => _set(_filter.toggle(f)),
                    ),
                ]),
                heading('Size'),
                _chips([
                  for (final s in SizeRange.values)
                    ChoiceChip(
                      key: Key('filterSize-${s.name}'),
                      label: Text(s.label),
                      selected: _filter.size == s,
                      onSelected: (_) => _set(_filter.copyWith(size: s)),
                    ),
                ]),
                heading('Modified (the file\'s date)'),
                _chips([
                  for (final d in DateRange.values)
                    ChoiceChip(
                      key: Key('filterDate-${d.name}'),
                      label: Text(d.label),
                      selected: _filter.date == d,
                      onSelected: (_) => _set(_filter.copyWith(date: d)),
                    ),
                ]),
                heading('Completed (marked so, or left on the last page)'),
                _chips([
                  for (final c in CompletedFilter.values)
                    ChoiceChip(
                      key: Key('filterCompleted-${c.name}'),
                      label: Text(c.label),
                      selected: _filter.completed == c,
                      onSelected: (_) => _set(_filter.copyWith(completed: c)),
                    ),
                ]),
              ],
            ),
          ),
        ),
        actions: _actions(context),
      ),
    );
  }

  /// A line of chips that wraps.
  Widget _chips(List<Widget> chips) => Wrap(spacing: 8, runSpacing: 4, children: chips);

  /// Clear all (Alt+C; off while no filter is on) and Done (Alt+D).
  List<Widget> _actions(BuildContext context) => [
    TextButton(
      key: const Key('filterClear'),
      onPressed: _filter.isActive ? () => _set(FolderFilter.none) : null,
      child: const Mnemonic('Clear all'),
    ),
    FilledButton(key: const Key('filterDone'), onPressed: () => Navigator.pop(context), child: const Mnemonic('Done')),
  ];
}
