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
  Widget build(BuildContext context) => DialogHotkeys(
    child: AlertDialog(
      key: const Key('filterDialog'),
      title: const Text('Filter the Folders tab'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: _parts(Theme.of(context)),
          ),
        ),
      ),
      actions: _actions(context),
    ),
  );

  /// The filter's parts, each a heading over its line of chips, in the
  /// order Tab walks them: type, size, date, completed. A new part goes at
  /// the end, since the e2e scripts count Tab stops from the first chip.
  List<Widget> _parts(ThemeData theme) {
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(text, style: theme.textTheme.titleSmall),
    );
    // A format filtered on that is no longer in the library still shows, so
    // it can be taken off.
    final formats = {...widget.formats, ..._filter.formats}.toList()
      ..sort((a, b) => formatLabel(a).compareTo(formatLabel(b)));
    return [
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
          _choice('filterSize-${s.name}', s.label, _filter.size == s, _filter.copyWith(size: s)),
      ]),
      heading('Modified (the file\'s date)'),
      _chips([
        for (final d in DateRange.values)
          _choice('filterDate-${d.name}', d.label, _filter.date == d, _filter.copyWith(date: d)),
      ]),
      heading('Completed (marked so, or left on the last page)'),
      _chips([
        for (final c in CompletedFilter.values)
          _choice('filterCompleted-${c.name}', c.label, _filter.completed == c, _filter.copyWith(completed: c)),
      ]),
    ];
  }

  /// One chip of a part of which one choice holds: [selected] while it is
  /// the one, and a press makes the filter [picked].
  Widget _choice(String key, String label, bool selected, FolderFilter picked) =>
      ChoiceChip(key: Key(key), label: Text(label), selected: selected, onSelected: (_) => _set(picked));

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
