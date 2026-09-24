/// Every action the reader can take. Keys, gestures and menus all dispatch
/// one of these, never a function directly (design plan section 5).
enum ReaderIntent {
  nextStep('Next panel in guided view, next page or spread otherwise'),
  prevStep('Previous panel in guided view, previous page or spread otherwise'),
  nextPage('Next page, ignoring panels'),
  prevPage('Previous page, ignoring panels'),
  panDown('Pan down, or scroll in continuous mode'),
  panUp('Pan up, or scroll in continuous mode'),
  halfPageDown('Half-screen scroll down in continuous mode'),
  halfPageUp('Half-screen scroll up in continuous mode'),
  firstPage('First page'),
  lastPage('Last page, or page N with a count'),
  nextBook('Next book in the same folder'),
  prevBook('Previous book in the same folder'),
  toggleGuided('Guided view, there and back'),
  cycleModeForward('Cycle single, double, continuous, guided'),
  cycleModeBack('Cycle modes backwards'),
  toggleSpread('Single page or two-page spread'),
  shiftSpread('Shift the spread pairing by one'),
  toggleContinuous('Continuous vertical scroll on or off'),
  toggleDirection('Reading direction for this book'),
  fitWidth('Fit width'),
  fitHeight('Fit height'),
  fitPage('Fit whole page; re-centre the panel in guided view'),
  zoomIn('Zoom in'),
  zoomOut('Zoom out'),
  zoomReset('Reset zoom'),
  autoTrim('Auto-trim scan margins'),
  nightFilter('Night filter'),
  fullscreen('Fullscreen'),
  bookmark('Bookmark here'),
  setMark('Set mark a-z'),
  jumpMark('Jump to mark a-z'),
  jumpBack('Jump back to before the last jump'),
  search('Search the book text'),
  searchNext('Next match'),
  searchPrev('Previous match'),
  openFile('Open a file without adding it to the library'),
  back('Back out one level'),
  showKeymap('Show the keymap');

  const ReaderIntent(this.description);

  final String description;
}

/// One resolved key sequence: the intent, plus the count typed before it
/// (`5l`) and the register letter for marks (`ma`, `'a`).
class ReaderCommand {
  const ReaderCommand(this.intent, {this.count, this.register});

  final ReaderIntent intent;
  final int? count;
  final String? register;

  /// The count to act on: a missing count means once.
  int get times => count ?? 1;

  @override
  bool operator ==(Object other) =>
      other is ReaderCommand && other.intent == intent && other.count == count && other.register == register;

  @override
  int get hashCode => Object.hash(intent, count, register);

  @override
  String toString() =>
      'ReaderCommand(${intent.name}'
      '${count != null ? ', count: $count' : ''}'
      '${register != null ? ', register: $register' : ''})';
}
