import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader_input/reader_input.dart';

import 'reader_notifier.dart';
import 'thumbnails.dart';

/// The open book's pages as a grid of thumbnails (`p`), to see pages before
/// jumping to one. The current page is outlined in blue and the selection
/// in amber, which shows on paper and art alike; bookmarked pages carry a
/// bookmark and marked ones their letter. Arrows and `hjkl` move the
/// selection, Enter, a click or a tap jumps, Esc or back closes.
///
/// Tiles are built only as they scroll into view, each thumbnail decoded at
/// the tile's own size and dropped from the image cache when its tile goes,
/// so a long book costs no more memory than one screenful.
class PageGrid extends ConsumerStatefulWidget {
  const PageGrid({super.key, required this.onPick, required this.onClose, this.onDetails});

  final ValueChanged<int> onPick;
  final VoidCallback onClose;

  /// Opens the book's details (`I`): the way there on a phone, whose
  /// status line has no room for the button.
  final VoidCallback? onDetails;

  @override
  ConsumerState<PageGrid> createState() => PageGridState();
}

class PageGridState extends ConsumerState<PageGrid> {
  final _scroll = ScrollController();
  late int _selected = ref.read(readerProvider).page;
  int _columns = 1;
  double _rowExtent = 1;
  double _tileWidth = 1;
  bool _placed = false;

  static const _pad = 12.0;
  static const _gap = 8.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Grid intents while it is open; everything else is swallowed, so a key
  /// meant for the page does nothing behind the grid.
  void handle(ReaderCommand c) {
    final s = ref.read(readerProvider);
    final n = s.pageCount;
    if (n == 0) return;
    // Right to left lays the grid out mirrored, so the arrow pointing at a
    // tile still moves to it.
    final mirror = s.rightToLeft ? -1 : 1;
    final screen = math.max(1, _viewport ~/ _rowExtent);
    switch (c.intent) {
      case ReaderIntent.nextStep:
        _select(_selected + mirror * c.times);
      case ReaderIntent.prevStep:
        _select(_selected - mirror * c.times);
      case ReaderIntent.panDown:
        _select(_selected + _columns * c.times);
      case ReaderIntent.panUp:
        _select(_selected - _columns * c.times);
      case ReaderIntent.nextPage:
      case ReaderIntent.halfPageDown:
        _select(_selected + _columns * screen * c.times);
      case ReaderIntent.prevPage:
      case ReaderIntent.halfPageUp:
        _select(_selected - _columns * screen * c.times);
      case ReaderIntent.firstPage:
        _select(0);
      case ReaderIntent.lastPage:
        _select(c.count != null ? c.count! - 1 : n - 1);
      case ReaderIntent.activate:
        widget.onPick(_selected);
      case ReaderIntent.back:
      case ReaderIntent.pageGrid:
        widget.onClose();
      default:
        break;
    }
  }

  double get _viewport => _scroll.hasClients ? _scroll.position.viewportDimension : 0;

  void _select(int i) {
    final n = ref.read(readerProvider).pageCount;
    setState(() => _selected = i.clamp(0, n - 1));
    _reveal();
  }

  /// Scrolls just far enough to show the selected tile.
  void _reveal() {
    if (!_scroll.hasClients) return;
    final top = _pad + (_selected ~/ _columns) * _rowExtent;
    final bottom = top + _rowExtent - _gap + _pad;
    final at = _scroll.offset;
    final target = top - _pad < at
        ? top - _pad
        : bottom > at + _viewport
        ? bottom - _viewport
        : null;
    if (target == null) return;
    final to = target.clamp(0.0, _scroll.position.maxScrollExtent);
    MediaQuery.disableAnimationsOf(context)
        ? _scroll.jumpTo(to)
        : unawaited(_scroll.animateTo(to, duration: const Duration(milliseconds: 120), curve: Curves.easeOut));
  }

  /// On opening: the current page in the middle of the screen.
  void _centre() {
    if (!_scroll.hasClients) return;
    final top = _pad + (_selected ~/ _columns) * _rowExtent;
    _scroll.jumpTo((top - (_viewport - _rowExtent) / 2).clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerProvider);
    final thumbs = ref.watch(thumbnailsProvider);
    final theme = Theme.of(context);
    final n = s.pageCount;
    final bookmarked = {
      for (final b in s.bookmarks)
        if (b.mark == null) b.page,
    };
    final marks = <int, List<String>>{};
    for (final e in s.marks.entries) {
      (marks[e.value.page] ??= []).add(e.key);
    }
    return Material(
      key: const Key('pageGrid'),
      color: Colors.black.withValues(alpha: 0.92),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Pages  ·  ${s.book?.title ?? ''}',
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.onDetails != null)
                  IconButton(
                    key: const Key('pageGridDetails'),
                    icon: const Icon(Icons.info_outline),
                    tooltip: 'Details (I)',
                    onPressed: widget.onDetails,
                  ),
                IconButton(
                  key: const Key('pageGridClose'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close (Esc)',
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // About three columns on a phone, more on the laptop.
                final target = constraints.maxWidth < 600 ? 110.0 : 150.0;
                final inner = constraints.maxWidth - 2 * _pad;
                _columns = math.max(2, ((inner + _gap) / (target + _gap)).floor());
                _tileWidth = (inner - (_columns - 1) * _gap) / _columns;
                _rowExtent = _tileWidth * 1.5 + _labelHeight + _gap;
                if (!_placed) {
                  _placed = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _centre();
                  });
                }
                return Directionality(
                  textDirection: s.rightToLeft ? TextDirection.rtl : TextDirection.ltr,
                  child: GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(_pad),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _columns,
                      mainAxisSpacing: _gap,
                      crossAxisSpacing: _gap,
                      mainAxisExtent: _rowExtent - _gap,
                    ),
                    itemCount: n,
                    itemBuilder: (context, i) => _Tile(
                      key: ValueKey(i),
                      index: i,
                      thumbs: thumbs,
                      width: _tileWidth,
                      current: s.unit.contains(i),
                      selected: i == _selected,
                      bookmarked: bookmarked.contains(i),
                      marks: marks[i] ?? const [],
                      onTap: () => widget.onPick(i),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Room under each thumbnail for its page number.
const _labelHeight = 22.0;

class _Tile extends StatefulWidget {
  const _Tile({
    super.key,
    required this.index,
    required this.thumbs,
    required this.width,
    required this.current,
    required this.selected,
    required this.bookmarked,
    required this.marks,
    required this.onTap,
  });

  final int index;
  final Thumbnails? thumbs;
  final double width;
  final bool current;
  final bool selected;
  final bool bookmarked;
  final List<String> marks;
  final VoidCallback onTap;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  ImageProvider? _image;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.thumbs?.get(widget.index).then((path) {
        if (path != null && mounted) setState(() => _image = _provider(path));
      }),
    );
  }

  ImageProvider _provider(String path) {
    final px = (widget.width * MediaQuery.devicePixelRatioOf(context)).round();
    return ResizeImage(FileImage(File(path)), width: px, policy: ResizeImagePolicy.fit);
  }

  @override
  void dispose() {
    widget.thumbs?.cancel(widget.index);
    // Scrolled away: its pixels leave the image cache with it.
    unawaited(_image?.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = widget.index + 1;
    final border = widget.selected
        ? Border.all(color: Colors.amber, width: 4)
        : widget.current
        ? Border.all(color: scheme.primary, width: 3)
        : Border.all(color: Colors.white12);
    return Semantics(
      button: true,
      selected: widget.current,
      label: [
        'Page $page',
        if (widget.current) 'current page',
        if (widget.bookmarked) 'bookmarked',
        for (final m in widget.marks) 'mark $m',
      ].join(', '),
      child: InkWell(
        key: Key('pageTile-${widget.index}'),
        onTap: widget.onTap,
        canRequestFocus: false,
        child: ExcludeSemantics(
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: Colors.white10,
                  // On top of the picture, which fills the tile.
                  foregroundDecoration: BoxDecoration(border: border),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_image case final image?)
                        Image(image: image, fit: BoxFit.contain, gaplessPlayback: true)
                      else
                        const Center(child: Icon(Icons.image_outlined, color: Colors.white24)),
                      if (widget.bookmarked || widget.marks.isNotEmpty)
                        PositionedDirectional(
                          top: 2,
                          end: 2,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final m in widget.marks)
                                Container(
                                  margin: const EdgeInsets.only(right: 2),
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  color: scheme.secondaryContainer,
                                  child: Text(m, style: TextStyle(color: scheme.onSecondaryContainer)),
                                ),
                              if (widget.bookmarked)
                                Icon(Icons.bookmark, key: Key('pageBookmark-${widget.index}'), color: scheme.primary),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: _labelHeight,
                child: Center(
                  child: Text(
                    '$page',
                    style: TextStyle(
                      color: widget.current ? scheme.primary : Colors.white70,
                      fontWeight: widget.current ? FontWeight.bold : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
