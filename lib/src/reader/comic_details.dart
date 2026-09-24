import 'dart:async';

import 'package:comic_formats/comic_formats.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/meta_edits.dart';
import 'comic_report.dart';
import 'open_book.dart';

/// Shows the details of [book] (`I`, the status line's info button, or
/// Details in the library): the file, its pages and their scans, metadata,
/// reading and detection, page by page. [onJump] goes to a page picked in
/// the list (the reader only); [onRedoPanels] runs once the view has
/// closed, when Redo panels was pressed. [closeKeys] are the characters
/// that opened it, which close it again.
Future<void> showComicDetails(
  BuildContext context,
  OpenBook book, {
  int? currentPage,
  ValueChanged<int>? onJump,
  Future<void> Function()? onRedoPanels,
  Set<String> closeKeys = const {'I'},
}) async {
  final narrow = MediaQuery.sizeOf(context).width < 600;
  final picked = await showDialog<_Picked>(
    context: context,
    builder: (context) {
      final details = ComicDetails(
        book: book,
        currentPage: currentPage,
        canJump: onJump != null,
        canRedo: onRedoPanels != null,
        closeKeys: closeKeys,
      );
      return narrow
          ? Dialog.fullscreen(child: details)
          : Dialog(
              insetPadding: const EdgeInsets.all(24),
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: details),
            );
    },
  );
  switch (picked) {
    case _JumpTo(:final page):
      onJump?.call(page);
    case _RedoPanels():
      await onRedoPanels?.call();
    case null:
  }
}

sealed class _Picked {
  const _Picked();
}

class _JumpTo extends _Picked {
  const _JumpTo(this.page);
  final int page;
}

class _RedoPanels extends _Picked {
  const _RedoPanels();
}

/// The details view itself; see [showComicDetails].
class ComicDetails extends ConsumerStatefulWidget {
  const ComicDetails({
    super.key,
    required this.book,
    this.currentPage,
    this.canJump = false,
    this.canRedo = false,
    this.closeKeys = const {'I'},
  });

  final OpenBook book;
  final int? currentPage;
  final bool canJump;
  final bool canRedo;
  final Set<String> closeKeys;

  @override
  ConsumerState<ComicDetails> createState() => _ComicDetailsState();
}

class _ComicDetailsState extends ConsumerState<ComicDetails> {
  late final Future<ComicReport> _report = readComicReport(ref, widget.book);
  Future<List<PdfImage>>? _pdfImages;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollBy(double fraction) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    unawaited(
      _scroll.animateTo(
        (pos.pixels + fraction * pos.viewportDimension).clamp(0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.pop(context);
    return CallbackShortcuts(
      bindings: {
        for (final k in widget.closeKeys) CharacterActivator(k): close,
        const CharacterActivator('j'): () => _scrollBy(0.15),
        const CharacterActivator('k'): () => _scrollBy(-0.15),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _scrollBy(0.15),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _scrollBy(-0.15),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _scrollBy(0.9),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _scrollBy(-0.9),
        const SingleActivator(LogicalKeyboardKey.space): () => _scrollBy(0.9),
        const CharacterActivator('G'): () => _scrollBy(1e9),
        const SingleActivator(LogicalKeyboardKey.end): () => _scrollBy(1e9),
        const SingleActivator(LogicalKeyboardKey.home): () => _scrollBy(-1e9),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          key: const Key('comicDetails'),
          children: [
            _TitleBar(title: widget.book.title, onClose: close),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<ComicReport>(
                future: _report,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(child: Text('Could not read the details: ${snap.error}'));
                  }
                  final r = snap.data;
                  if (r == null) return const Center(child: CircularProgressIndicator());
                  if (r.isPdf) _pdfImages ??= pdfImagesOf(r.path, r.contentKey);
                  return _body(context, r);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ComicReport r) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context).height * MediaQuery.devicePixelRatioOf(context);
    final rows = <Widget>[
      ..._fileSection(r),
      ..._pagesSection(r, screen),
      ..._metaSection(r),
      ..._readingSection(r),
      ..._detectionSection(context, r),
      _heading('Page by page', note: widget.canJump ? 'Click or tap a page to go to it' : null),
    ];
    final detected = {for (final d in r.detection.pages) d.page: d};
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        key: const Key('detailsList'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        itemCount: rows.length + r.pages.count,
        itemBuilder: (context, i) {
          if (i < rows.length) return rows[i];
          final page = i - rows.length;
          return _pageRow(theme, page, r.pages.facts[page], detected[page]);
        },
      ),
    );
  }

  List<Widget> _fileSection(ComicReport r) {
    final written = r.sidecars.firstOrNull;
    return [
      _heading('File'),
      _row('Path', r.path, selectable: true),
      _row('Format', r.formatLabel),
      _row('Size', formatBytes(r.bytes)),
      if (r.modified != null) _row('Modified', _date(r.modified!)),
      _row('Content key', r.contentKey, selectable: true),
      _row(
        'Sidecar',
        written == null
            ? 'None: this comic\'s data stays in the app'
            : [
                '${written.path}${written.bytes == null ? ' (not written yet)' : ' (${formatBytes(written.bytes!)})'}',
                for (final s in r.sidecars.skip(1))
                  if (s.bytes != null) 'Also read: ${s.path} (${formatBytes(s.bytes!)})',
              ].join('\n'),
        selectable: true,
      ),
    ];
  }

  List<Widget> _pagesSection(ComicReport r, double screen) {
    final s = r.pages;
    final sizes = s.sizes;
    final q = s.jpegQuality;
    String dims(PageFacts f) => '${f.width} × ${f.height}${r.isPdf ? ' pt' : ''}';
    final out = <Widget>[
      _heading('Pages'),
      _row('Pages', '${s.count}${s.wide > 0 ? ', ${s.wide} of them wide (double-page spreads)' : ''}'),
    ];
    if (r.isPdf) {
      if (sizes != null) {
        final m = sizes.median;
        out.add(
          _row(
            'Page size',
            '${_inches(m.width!)} × ${_inches(m.height!)} in (${dims(m)})'
                '${s.uniform ? '' : ', from ${dims(sizes.min)} to ${dims(sizes.max)}'}',
          ),
        );
      }
      out.add(
        FutureBuilder<List<PdfImage>>(
          future: _pdfImages,
          builder: (context, snap) {
            if (snap.hasError) return _row('Images', 'Could not read them: ${snap.error}');
            final images = snap.data;
            if (images == null) return _row('Images', 'Reading the file…');
            return Column(children: _pdfImageRows(images, s.count, sizes?.median, screen));
          },
        ),
      );
      return out;
    }
    if (sizes != null) {
      out.add(
        _row(
          'Pixels',
          s.uniform
              ? '${dims(sizes.median)} on every page'
              : '${dims(sizes.median)} typical, from ${dims(sizes.min)} to ${dims(sizes.max)}',
        ),
      );
      final sharp = sharpness(sizes.median.height!, screen);
      out.add(
        _row(
          'Sharpness',
          '${sharp.verdict} (this window is ${screen.round()} px tall)'
              '${sharp.soft ? '. Clean-up (c) enlarges and sharpens pages smaller than the screen.' : ''}',
          key: const Key('detailsSharpness'),
        ),
      );
    }
    out.add(_row('Stored as', [for (final (f, n) in s.formats) '${_formatName(f)} $n'].join(', ')));
    if (q != null) {
      out.add(
        _row(
          'JPEG quality',
          q.min == q.max
              ? '${q.median}: ${jpegVerdict(q.median)}'
              : '${q.median} typical (${q.min} to ${q.max}): ${jpegVerdict(q.median)}',
          key: const Key('detailsJpegQuality'),
        ),
      );
    }
    final extras = [
      if (s.gray > 0) '${s.gray == s.count ? 'every page' : '${s.gray} pages'} in greyscale',
      if (s.progressive > 0) '${s.progressive} progressive JPEG${s.progressive == 1 ? '' : 's'}',
      if (s.dpi != null) 'scanned at ${s.dpi} dpi, the files say',
    ];
    if (extras.isNotEmpty) out.add(_row('Also', extras.join('; ')));
    if (s.count > 0) out.add(_row('Per page', '${formatBytes(s.storedBytes ~/ s.count)} on average'));
    return out;
  }

  List<Widget> _pdfImageRows(List<PdfImage> images, int pages, PageFacts? page, double screen) {
    if (images.isEmpty) {
      return [_row('Images', 'None: the pages are drawn, not scanned, and stay sharp at any size')];
    }
    // The page scans: images at least a quarter the size of the largest,
    // not the logos and ornaments beside them, nor the low-resolution
    // colour layer of a layered scan.
    final biggest = images.map((i) => i.width * i.height).reduce((a, b) => a > b ? a : b);
    final scans = images.where((i) => i.width * i.height * 4 >= biggest).toList()
      ..sort((a, b) => (a.width * a.height).compareTo(b.width * b.height));
    final m = scans[scans.length ~/ 2];
    final filters = <String, int>{};
    for (final i in images) {
      filters[i.filter] = (filters[i.filter] ?? 0) + 1;
    }
    final q = [
      for (final i in images)
        if (i.quality != null) i.quality!,
    ]..sort();
    final dpi = page == null || page.width == null ? null : (m.width / (page.width! / 72)).round();
    final sharp = sharpness(m.height, screen);
    // Internet Archive and DjVu-style PDFs keep the ink as a sharp one-bit
    // mask over a colour layer.
    final masks = images.where((i) => i.bits == 1 || i.filter == 'jbig2' || i.filter == 'ccitt').length;
    final layered = masks * 2 >= pages && masks < images.length;
    return [
      _row(
        'Images',
        '${_n(images.length, 'image')} on ${_n(pages, 'page')}, the page-sized ones typically '
            '${m.width} × ${m.height} px${dpi == null ? '' : ', about $dpi dpi'}'
            '${layered ? '. Layered scans: the ink is a sharp black-and-white layer over the colour' : ''}',
        key: const Key('detailsPdfImages'),
      ),
      _row(
        'Stored as',
        [
          for (final e in (filters.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
            '${_formatName(e.key)} ${e.value}',
        ].join(', '),
      ),
      if (q.isNotEmpty)
        _row(
          'JPEG quality',
          '${q[q.length ~/ 2]}${q.first == q.last ? '' : ' typical (${q.first} to ${q.last})'}: ${jpegVerdict(q[q.length ~/ 2])}',
          key: const Key('detailsJpegQuality'),
        ),
      _row(
        'Sharpness',
        '${sharp.verdict} (this window is ${screen.round()} px tall)',
        key: const Key('detailsSharpness'),
      ),
    ];
  }

  List<Widget> _metaSection(ComicReport r) {
    final m = r.meta;
    String mark(MetaField f, String s) => r.edited.contains(f) ? '$s  (edited)' : s;
    return [
      _heading('Metadata', note: 'From ${r.metaSource}${r.edited.isEmpty ? '' : ', with edits made here (e)'}'),
      if (m?.series != null) _row('Series', mark(MetaField.series, m!.series!)),
      if (m?.number != null) _row('Issue', mark(MetaField.number, m!.number!)),
      if (m?.title != null) _row('Title', mark(MetaField.title, m!.title!)),
      if (m?.volume != null) _row('Volume', mark(MetaField.volume, '${m!.volume}')),
      if (m?.year != null) _row('Year', mark(MetaField.year, '${m!.year}')),
      if (m != null && m.writers.isNotEmpty) _row('Writers', mark(MetaField.writers, m.writers.join(', '))),
      if (m != null && m.artists.isNotEmpty) _row('Artists', mark(MetaField.artists, m.artists.join(', '))),
      if (m?.summary != null) _row('Summary', mark(MetaField.summary, m!.summary!)),
      if (m?.frontCoverPage != null) _row('Cover', 'page ${m!.frontCoverPage! + 1}'),
      if (m?.rightToLeft ?? false) _row('Direction', 'right to left'),
    ];
  }

  List<Widget> _readingSection(ComicReport r) {
    final g = r.reading;
    final pages = r.pages.count;
    return [
      _heading('Reading'),
      _row(
        'Progress',
        g.finished
            ? 'Finished'
            : g.page == null
            ? 'Not started'
            : 'Page ${g.page! + 1} of $pages (${((g.percent ?? 0) * 100).round()}%)',
      ),
      if (g.updatedAt != null) _row('Last read', _date(g.updatedAt!)),
      if (g.sittings > 0)
        _row(
          'Time read',
          '${formatDuration(g.time)} in ${g.sittings} sitting${g.sittings == 1 ? '' : 's'}, ${g.pagesShown} pages shown'
              '${g.firstRead == null ? '' : ', first on ${_day(g.firstRead!)}'}',
        ),
      _row(
        'Bookmarks',
        '${g.bookmarks} bookmark${g.bookmarks == 1 ? '' : 's'}, ${g.marks} mark${g.marks == 1 ? '' : 's'}',
      ),
      if (g.collections.isNotEmpty) _row('Collections', g.collections.join(', ')),
    ];
  }

  List<Widget> _detectionSection(BuildContext context, ComicReport r) {
    final d = r.detection;
    final n = d.pages.length;
    final conf = d.confidence;
    String pct(double? c) => c == null ? '–' : c.toStringAsFixed(2);
    return [
      _heading('Panels and balloons'),
      _row('Detector', d.detector),
      _row(
        'Analysed',
        '$n of ${d.pageCount} pages'
            '${d.stale > 0 ? '; ${d.stale} more by an older detector, analysed again when shown' : ''}'
            '${n < d.pageCount ? '. The rest are found as you read, or by the library pass.' : ''}',
        key: const Key('detailsAnalysed'),
      ),
      if (n > 0) ...[
        if (d.sources.length > 1 || d.sources.first.$1 != d.current)
          _row('Found by', [for (final (s, k) in d.sources) '$s: $k pages'].join('; ')),
        _row(
          'Guided view',
          '${_n(d.guided, 'page')} ${d.guided == 1 ? 'steps' : 'step'} panel by panel, ${n - d.guided} shown whole',
          key: const Key('detailsGuided'),
        ),
        if (d.wholeReasons.isNotEmpty)
          _row('Shown whole', [for (final (why, k) in d.wholeReasons) '$k: $why'].join('\n')),
        _row(
          'Found',
          '${_n(d.frames, 'panel')}, ${_n(d.balloons, 'balloon')}${d.captions > 0 ? ', ${_n(d.captions, 'caption')}' : ''}'
              '${d.outlined > 0 ? '; ${d.outlined} panels are not rectangles' : ''}',
          key: const Key('detailsFound'),
        ),
        _row('Confidence', 'panels ${pct(conf.frames)}, balloons ${pct(conf.balloons)} (mean, 0 to 1)'),
        _row(
          'Time',
          '${(d.millis / 1000).toStringAsFixed(1)} s in all, ${(d.millis / n).round()} ms a page on average',
        ),
        if (d.trimmed > 0)
          _row(
            'Margins',
            '${d.trimmed} page${d.trimmed == 1 ? ' has' : 's have'} wide scanned margins: '
                'detection looked at the page without them, and auto-trim (t) cuts them off on screen',
          ),
      ],
      if (widget.canRedo)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('detailsRedoPanels'),
              onPressed: () => Navigator.pop(context, const _RedoPanels()),
              icon: const Icon(Icons.refresh),
              label: const Text('Redo panels'),
            ),
          ),
        ),
    ];
  }

  Widget _pageRow(ThemeData theme, int page, PageFacts f, PageDetection? d) {
    final image = [
      if (f.width != null) '${f.width} × ${f.height}${f.isPdf ? ' pt' : ''}',
      if (!f.isPdf) _formatName(f.format),
      if (f.quality != null) 'q${f.quality}',
      if (f.bytes != null) formatBytes(f.bytes!),
    ].join(' · ');
    final String found;
    final String how;
    if (d == null) {
      found = 'not analysed yet';
      how = '';
    } else {
      found = [
        '${d.frames} panel${d.frames == 1 ? '' : 's'}',
        if (d.balloons > 0) '${d.balloons} balloon${d.balloons == 1 ? '' : 's'}',
        if (d.captions > 0) '${d.captions} caption${d.captions == 1 ? '' : 's'}',
      ].join(', ');
      how = [
        d.guided ? 'guided' : 'whole: ${_why(d.panels.gate.reasons.first)}',
        if (d.confidence != null) 'confidence ${d.confidence!.toStringAsFixed(2)}',
        '${d.found.millis} ms',
        if (d.trimmed) 'margins trimmed',
      ].join(' · ');
    }
    final current = page == widget.currentPage;
    return ListTile(
      key: ValueKey('detailsPage$page'),
      dense: true,
      selected: current,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: SizedBox(
        width: 44,
        child: Text('${page + 1}', textAlign: TextAlign.right, style: theme.textTheme.titleSmall),
      ),
      title: Text('$found${current ? '  (this page)' : ''}'),
      subtitle: Text([how, image].where((s) => s.isNotEmpty).join('\n')),
      trailing: d == null
          ? null
          : Icon(
              d.guided ? Icons.view_quilt : Icons.crop_portrait,
              size: 20,
              semanticLabel: d.guided ? 'guided' : 'shown whole',
            ),
      onTap: widget.canJump ? () => Navigator.pop(context, _JumpTo(page)) : null,
    );
  }

  Widget _heading(String text, {String? note}) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: Theme.of(context).textTheme.titleMedium),
        if (note != null) Text(note, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );

  Widget _row(String label, String value, {bool selectable = false, Key? key}) {
    final theme = Theme.of(context);
    final v = selectable ? SelectableText(value) : Text(value);
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 420
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  v,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(label, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                  Expanded(child: v),
                ],
              ),
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
    child: Row(
      children: [
        const Icon(Icons.info_outline),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Details: $title',
            style: Theme.of(context).textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          key: const Key('detailsClose'),
          icon: const Icon(Icons.close),
          tooltip: 'Close (Esc)',
          onPressed: onClose,
        ),
      ],
    ),
  );
}

String _formatName(String f) => switch (f) {
  'jpeg' => 'JPEG',
  'png' => 'PNG',
  'webp' => 'WebP',
  'gif' => 'GIF',
  'bmp' => 'BMP',
  'jpeg2000' => 'JPEG 2000',
  'flate' => 'lossless (Flate)',
  'ccitt' => 'black and white (CCITT)',
  'jbig2' => 'black and white (JBIG2)',
  'raw' => 'uncompressed',
  'pdf' => 'PDF',
  _ => 'unreadable',
};

/// A gate reason for one page: its own numbers, but not "0 panel(s)".
String _why(String reason) => reason.contains('nothing to guide through') ? wholeReason(reason) : reason;

/// [n] [word]s, with the s only when it takes one.
String _n(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

String _inches(int points) => (points / 72).toStringAsFixed(1);

String _two(int n) => n.toString().padLeft(2, '0');
String _day(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';
String _date(DateTime t) => '${_day(t)} ${_two(t.hour)}:${_two(t.minute)}';
