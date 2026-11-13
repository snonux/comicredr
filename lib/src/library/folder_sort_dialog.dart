import 'package:flutter/material.dart';

import '../hotkeys.dart';
import 'folder_sort.dart';

/// `gS`, or the sort button on a sortable tab: the order the tab named
/// [tab] is in, with [note] on how the tab applies it under the orders.
/// A pick applies at once, so the covers behind follow; Alt and an order's
/// letter picks it, Alt+R reverses, Tab and Space work the chips, Esc or
/// Done closes it.
Future<void> showFolderSort(
  BuildContext context, {
  String tab = 'Folders',
  String note = '',
  required FolderSort sort,
  required ValueChanged<FolderSort> onChanged,
}) => showDialog<void>(
  context: context,
  builder: (context) => _FolderSortDialog(tab: tab, note: note, sort: sort, onChanged: onChanged),
);

class _FolderSortDialog extends StatefulWidget {
  const _FolderSortDialog({required this.tab, required this.note, required this.sort, required this.onChanged});

  final String tab, note;
  final FolderSort sort;
  final ValueChanged<FolderSort> onChanged;

  @override
  State<_FolderSortDialog> createState() => _FolderSortDialogState();
}

class _FolderSortDialogState extends State<_FolderSortDialog> {
  late FolderSort _sort = widget.sort;

  void _set(FolderSort s) {
    setState(() => _sort = s);
    widget.onChanged(s);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DialogHotkeys(
      child: AlertDialog(
        key: const Key('sortDialog'),
        title: Text('Sort the ${widget.tab} tab'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(spacing: 8, runSpacing: 4, children: [for (final o in SortOrder.values) _order(o)]),
                const SizedBox(height: 12),
                Text(_sort.label, key: const Key('sortDialogLabel'), style: theme.textTheme.bodyMedium),
                if (widget.note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(widget.note, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
        actions: _actions(context),
      ),
    );
  }

  /// The chip of [order], with its letter: Alt and it picks the order.
  Widget _order(SortOrder order) {
    void pick() => _set(FolderSort(order: order, reversed: _sort.reversed));
    return ChoiceChip(
      key: Key('sort-${order.name}'),
      autofocus: order == _sort.order,
      label: Mnemonic(order.label, letter: order.letter, onPressed: pick),
      selected: _sort.order == order,
      onSelected: (_) => pick(),
    );
  }

  /// Reverse (Alt+R) and Done (Alt+D).
  List<Widget> _actions(BuildContext context) => [
    TextButton.icon(
      key: const Key('sortReverse'),
      icon: Icon(_sort.reversed ? Icons.arrow_upward : Icons.arrow_downward),
      onPressed: () => _set(_sort.flipped()),
      label: const Mnemonic('Reverse'),
    ),
    FilledButton(key: const Key('sortDone'), onPressed: () => Navigator.pop(context), child: const Mnemonic('Done')),
  ];
}
