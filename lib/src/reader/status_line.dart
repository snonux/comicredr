import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:reader_input/reader_input.dart';

import 'guided.dart';
import 'layout.dart';
import 'reader_notifier.dart';
import 'region.dart';

/// The line under the page: where the reader is, what it is doing, and
/// buttons for the modes a phone can't reach by key.
class StatusLine extends StatelessWidget {
  const StatusLine({
    super.key,
    required this.state,
    required this.pending,
    required this.onCommand,
    this.gridOpen = false,
    this.bookmarksOpen = false,
  });

  /// Whether the status line has a back button: everywhere but Android,
  /// whose back gesture does the same.
  static bool get showBack => !Platform.isAndroid;

  /// Where guided view is on the page, or why it shows the whole page.
  static String _guided(ReaderState s) {
    final found = s.panels[s.page];
    if (found == null) return 'guided: finding panels…';
    final stops = s.stopsOn(s.page);
    if (stops.isEmpty) return 'guided: whole page (${found.gate.reasons.first})';
    if (s.panelIndex < 0) {
      return s.panel >= pageEnd
          ? 'guided: whole page, ${stops.length} panels read'
          : 'guided: whole page, then ${stops.length} panels';
    }
    final panel = 'guided: panel ${s.panelIndex + 1} / ${stops.length}';
    if (!s.balloons) return panel;
    final n = s.balloonsOn(s.page, s.panelIndex).length;
    if (found.balloons.isEmpty) return '$panel  ·  no balloons found';
    return n == 0
        ? '$panel  ·  no balloons'
        : '$panel  ·  balloon ${s.balloonIndex < 0 ? '–' : s.balloonIndex + 1} / $n';
  }

  final ReaderState state;
  final String pending;

  /// Whether the page grid is open.
  final bool gridOpen;

  /// Whether the bookmark list is open.
  final bool bookmarksOpen;

  /// For the buttons: a phone without a keyboard has no other way into
  /// guided view, balloons or bookmarks.
  final ValueChanged<ReaderCommand> onCommand;

  Widget _button(String key, IconData icon, String tip, ReaderIntent intent, {bool on = false}) => IconButton(
    key: Key(key),
    icon: Icon(icon),
    tooltip: tip,
    isSelected: on,
    // Full 48 px targets: the Fedora laptop has a touchscreen too.
    onPressed: () => onCommand(ReaderCommand(intent)),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = state.book;
    final unit = state.unit;
    final pages = unit.isEmpty
        ? ''
        : unit.length == 1
        ? 'page ${unit.first + 1} / ${state.pageCount}'
        : 'pages ${unit.first + 1}–${unit.last + 1} / ${state.pageCount}';
    final details = [
      if (book != null) pages,
      if (book != null && state.guided) _guided(state),
      if (book != null && !state.guided && state.mode == PageMode.spread) 'spread',
      if (book != null && state.region != null) describeRegion(state.region!, rightToLeft: state.rightToLeft),
      if (state.rightToLeft) 'RTL',
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // A phone in portrait has room for about 40 characters: the page and
        // panel counters come first there, the title after them, and the
        // file name, which repeats the title, is left out.
        final narrow = constraints.maxWidth < 600;
        // A small tablet, or a big one in split screen, has the buttons in
        // one row but was left too little room for the counters behind the
        // title and the file name: they come first there too, and the file
        // name only shows where there is room to spare.
        final countersFirst = constraints.maxWidth < 840;
        final fileName = constraints.maxWidth >= 1000;
        final left =
            (countersFirst ? [...details, if (book != null) book.title] : [if (book != null) book.title, ...details])
                .join('  ·  ');
        final status = Expanded(
          // A live region, so a screen reader reads out each notice and page
          // turn as it happens.
          child: Semantics(
            liveRegion: true,
            child: Text(
              state.message ?? left,
              key: const Key('status'),
              maxLines: narrow ? 2 : 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
        final pendingKeys = Text(
          pending,
          key: const Key('pending'),
          style: const TextStyle(fontFamily: 'monospace'),
        );
        // Esc in a button: Android has its back gesture for this, but a
        // Linux touchscreen had no way out of guided view or the book.
        final back = book != null && showBack
            ? _button('backButton', Icons.arrow_back, 'Back (Esc)', ReaderIntent.back)
            : null;
        final buttons = [
          if (book != null) ...[
            const SizedBox(width: 4),
            if (state.guided)
              _button(
                'balloonsButton',
                state.balloons ? Icons.chat_bubble : Icons.chat_bubble_outline,
                'Balloon by balloon (b)',
                ReaderIntent.toggleBalloons,
                on: state.balloons,
              ),
            _button(
              'guidedButton',
              state.guided ? Icons.view_quilt : Icons.view_quilt_outlined,
              'Guided view (v)',
              ReaderIntent.toggleGuided,
              on: state.guided,
            ),
            // A tablet on its side has room for two pages, and without a
            // keyboard no other way to them. A phone has room for neither.
            if (!narrow && !state.guided)
              _button(
                'spreadButton',
                state.mode == PageMode.spread ? Icons.menu_book : Icons.menu_book_outlined,
                state.mode == PageMode.spread ? 'One page (d)' : 'Two pages side by side (d)',
                ReaderIntent.toggleSpread,
                on: state.mode == PageMode.spread,
              ),
            _button('pagesButton', Icons.grid_view, 'Pages (p)', ReaderIntent.pageGrid, on: gridOpen),
            // A phone has no room for it here; the page grid has one.
            if (!narrow) _button('detailsButton', Icons.info_outline, 'Details (I)', ReaderIntent.showDetails),
            if (state.bookmarksHere.isNotEmpty)
              _button(
                'bookmarkButton',
                Icons.bookmark,
                'Remove the bookmark here (mm)',
                ReaderIntent.bookmark,
                on: true,
              )
            else
              _button('bookmarkButton', Icons.bookmark_add_outlined, 'Bookmark here (mm)', ReaderIntent.bookmark),
            _button(
              'bookmarksButton',
              Icons.bookmarks_outlined,
              'Bookmarks (M)',
              ReaderIntent.bookmarkList,
              on: bookmarksOpen,
            ),
            _button(
              'fullscreenButton',
              state.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              state.fullscreen ? 'Leave fullscreen (f)' : 'Fullscreen (f)',
              ReaderIntent.fullscreen,
            ),
          ],
        ];
        return Container(
          color: theme.colorScheme.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          // On a phone the buttons left the text a dozen characters, so a
          // notice or why guided view shows the page whole could not be
          // read: there the text has a line of its own above the buttons.
          child: narrow && book != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [status, pendingKeys]),
                    Row(children: [?back, const Spacer(), ...buttons]),
                  ],
                )
              : Row(
                  children: [
                    if (back != null) ...[back, const SizedBox(width: 4)],
                    status,
                    pendingKeys,
                    if (book != null && fileName) ...[
                      const SizedBox(width: 12),
                      Text(p.basename(book.path), style: theme.textTheme.bodySmall),
                    ],
                    ...buttons,
                  ],
                ),
        );
      },
    );
  }
}
