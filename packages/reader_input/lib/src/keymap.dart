import 'intents.dart';

/// Placeholder in a binding that matches any single lowercase letter and
/// becomes the command's register (`m<letter>`, `'<letter>`).
const letterSlot = '<letter>';

/// A key token is one key press, spelled the way bindings are written:
/// a printable character as itself (`l`, `G`, `'`), a named key by name
/// (`Right`, `PageDown`, `Space`, `Esc`, `F11`), with `C-` and `S-` prefixes
/// for Ctrl and Shift on keys where Shift does not already change the
/// character (`C-f`, `S-Space`, `S-Tab`).
class Binding {
  const Binding(this.keys, this.intent, {this.layer = Layer.vi});

  final List<String> keys;
  final ReaderIntent intent;
  final Layer layer;

  bool get hasLetterSlot => keys.contains(letterSlot);
}

/// Standard bindings work the way any reader does; vi bindings sit on top.
/// Both are live at once, the layer only groups them in the `?` overlay.
enum Layer { standard, vi }

class Keymap {
  Keymap(this.bindings);

  final List<Binding> bindings;

  /// The default map from the design plan, section 5.
  factory Keymap.defaults() {
    const s = Layer.standard;
    return Keymap(const [
      // Moving.
      Binding(['l'], ReaderIntent.nextStep),
      Binding(['h'], ReaderIntent.prevStep),
      Binding(['Right'], ReaderIntent.scrollRight, layer: s),
      Binding(['Left'], ReaderIntent.scrollLeft, layer: s),
      Binding(['Space'], ReaderIntent.nextStep, layer: s),
      Binding(['S-Space'], ReaderIntent.prevStep, layer: s),
      Binding(['C-f'], ReaderIntent.nextPage),
      Binding(['C-b'], ReaderIntent.prevPage),
      Binding(['PageDown'], ReaderIntent.nextPage, layer: s),
      Binding(['PageUp'], ReaderIntent.prevPage, layer: s),
      Binding(['j'], ReaderIntent.panDown),
      Binding(['k'], ReaderIntent.panUp),
      Binding(['Down'], ReaderIntent.panDown, layer: s),
      Binding(['Up'], ReaderIntent.panUp, layer: s),
      Binding(['C-d'], ReaderIntent.halfPageDown),
      Binding(['C-u'], ReaderIntent.halfPageUp),
      Binding(['g', 'g'], ReaderIntent.firstPage),
      Binding(['G'], ReaderIntent.lastPage),
      Binding(['Home'], ReaderIntent.firstPage, layer: s),
      Binding(['End'], ReaderIntent.lastPage, layer: s),
      Binding(['p'], ReaderIntent.pageGrid),
      Binding(['I'], ReaderIntent.showDetails),
      Binding([']'], ReaderIntent.nextBook),
      Binding(['['], ReaderIntent.prevBook),
      // Switching how the page is shown.
      Binding(['v'], ReaderIntent.toggleGuided),
      Binding(['b'], ReaderIntent.toggleBalloons),
      Binding(['w'], ReaderIntent.toggleWholePage),
      Binding(['W'], ReaderIntent.togglePauseWhole),
      Binding(['g', 'w'], ReaderIntent.cyclePauseCue),
      Binding(['Tab'], ReaderIntent.cycleModeForward, layer: s),
      Binding(['S-Tab'], ReaderIntent.cycleModeBack, layer: s),
      Binding(['d'], ReaderIntent.toggleSpread),
      Binding(['D'], ReaderIntent.shiftSpread),
      Binding(['s'], ReaderIntent.toggleContinuous),
      Binding(['r'], ReaderIntent.toggleDirection),
      Binding(['>'], ReaderIntent.rotateClockwise),
      Binding(['<'], ReaderIntent.rotateCounterClockwise),
      Binding(['g', 'r'], ReaderIntent.rotateReset),
      Binding(['z', 'w'], ReaderIntent.fitWidth),
      Binding(['z', 'h'], ReaderIntent.fitHeight),
      Binding(['z', 'z'], ReaderIntent.fitPage),
      Binding(['+'], ReaderIntent.zoomIn, layer: s),
      Binding(['-'], ReaderIntent.zoomOut, layer: s),
      Binding(['='], ReaderIntent.zoomReset, layer: s),
      Binding(['Z'], ReaderIntent.zoomToggle),
      // A fixed part of the page: H for halves, B for thirds (bands), Q for
      // quarters, then the part's number, top to bottom, left to right.
      Binding(['H', '1'], ReaderIntent.regionUpperHalf),
      Binding(['H', '2'], ReaderIntent.regionLowerHalf),
      Binding(['B', '1'], ReaderIntent.regionUpperThird),
      Binding(['B', '2'], ReaderIntent.regionMiddleThird),
      Binding(['B', '3'], ReaderIntent.regionLowerThird),
      Binding(['Q', '1'], ReaderIntent.regionTopLeft),
      Binding(['Q', '2'], ReaderIntent.regionTopRight),
      Binding(['Q', '3'], ReaderIntent.regionBottomLeft),
      Binding(['Q', '4'], ReaderIntent.regionBottomRight),
      Binding(['t'], ReaderIntent.autoTrim),
      Binding(['i'], ReaderIntent.nightFilter),
      Binding(['c'], ReaderIntent.cleanUp),
      Binding(['f'], ReaderIntent.fullscreen),
      Binding(['F11'], ReaderIntent.fullscreen, layer: s),
      // Marks, search and getting out.
      Binding(['m', 'm'], ReaderIntent.bookmark),
      Binding(['}'], ReaderIntent.nextBookmark),
      Binding(['{'], ReaderIntent.prevBookmark),
      Binding(['M'], ReaderIntent.bookmarkList),
      Binding(['*'], ReaderIntent.toggleFavourite),
      Binding(['g', 'f'], ReaderIntent.showFavourites),
      Binding(['x'], ReaderIntent.remove),
      Binding(['Delete'], ReaderIntent.remove, layer: s),
      Binding(['m', letterSlot], ReaderIntent.setMark),
      Binding(["'", "'"], ReaderIntent.jumpBack),
      Binding(["'", letterSlot], ReaderIntent.jumpMark),
      Binding(['/'], ReaderIntent.search),
      Binding(['n'], ReaderIntent.searchNext),
      Binding(['N'], ReaderIntent.searchPrev),
      Binding(['o'], ReaderIntent.openFile),
      Binding(['O'], ReaderIntent.openFolder),
      Binding(['Esc'], ReaderIntent.back, layer: s),
      // The library.
      Binding(['Enter'], ReaderIntent.activate, layer: s),
      Binding(['Backspace'], ReaderIntent.up, layer: s),
      Binding(['A'], ReaderIntent.addRoot),
      Binding(['R'], ReaderIntent.rescan),
      Binding(['S'], ReaderIntent.toggleShuffle),
      Binding(['g', 's'], ReaderIntent.reshuffle),
      Binding(['X'], ReaderIntent.resetBook),
      Binding(['e'], ReaderIntent.editBook),
      Binding(['g', 'd'], ReaderIntent.deleteBook),
      Binding(['S-Delete'], ReaderIntent.deleteBook, layer: s),
      Binding(['?'], ReaderIntent.showKeymap, layer: s),
      Binding(['g', 't'], ReaderIntent.showTouchZones),
      Binding(['T'], ReaderIntent.showTime),
    ]);
  }

  /// Human-readable key spelling for the `?` overlay, e.g. `gg`, `m<a-z>`.
  static String describe(Binding b) => b.keys
      .map((k) => k == letterSlot ? '<a-z>' : k)
      .join(b.keys.every((k) => k.length == 1 || k == letterSlot) ? '' : ' ');
}
