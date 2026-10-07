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
      Binding(['g', '+'], ReaderIntent.scrollFaster),
      Binding(['g', '-'], ReaderIntent.scrollSlower),
      Binding(['g', '>'], ReaderIntent.scrollSmoother),
      Binding(['g', '<'], ReaderIntent.scrollCrisper),
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
      // Parts of a page: 11 whole, 00 leave the split; letter+number or two
      // quick digits (first digit = how many parts: 2 halves … 5 quarters).
      Binding(['1', '1'], ReaderIntent.regionWhole),
      Binding(['0', '0'], ReaderIntent.regionPrevious),
      Binding(['H', '1'], ReaderIntent.regionUpperHalf),
      Binding(['H', '2'], ReaderIntent.regionLowerHalf),
      Binding(['B', '1'], ReaderIntent.regionUpperThird),
      Binding(['B', '2'], ReaderIntent.regionMiddleThird),
      Binding(['B', '3'], ReaderIntent.regionLowerThird),
      Binding(['L', '1'], ReaderIntent.regionStrip1),
      Binding(['L', '2'], ReaderIntent.regionStrip2),
      Binding(['L', '3'], ReaderIntent.regionStrip3),
      Binding(['L', '4'], ReaderIntent.regionStrip4),
      Binding(['Q', '1'], ReaderIntent.regionTopLeft),
      Binding(['Q', '2'], ReaderIntent.regionTopRight),
      Binding(['Q', '3'], ReaderIntent.regionBottomLeft),
      Binding(['Q', '4'], ReaderIntent.regionBottomRight),
      Binding(['2', '1'], ReaderIntent.regionUpperHalf),
      Binding(['2', '2'], ReaderIntent.regionLowerHalf),
      Binding(['3', '1'], ReaderIntent.regionUpperThird),
      Binding(['3', '2'], ReaderIntent.regionMiddleThird),
      Binding(['3', '3'], ReaderIntent.regionLowerThird),
      Binding(['4', '1'], ReaderIntent.regionStrip1),
      Binding(['4', '2'], ReaderIntent.regionStrip2),
      Binding(['4', '3'], ReaderIntent.regionStrip3),
      Binding(['4', '4'], ReaderIntent.regionStrip4),
      Binding(['5', '1'], ReaderIntent.regionTopLeft),
      Binding(['5', '2'], ReaderIntent.regionTopRight),
      Binding(['5', '3'], ReaderIntent.regionBottomLeft),
      Binding(['5', '4'], ReaderIntent.regionBottomRight),
      Binding(['g', 'p'], ReaderIntent.pickPart),
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
      Binding(['C'], ReaderIntent.continueReading),
      Binding(['Esc'], ReaderIntent.back, layer: s),
      // The library.
      Binding(['Enter'], ReaderIntent.activate, layer: s),
      Binding(['Backspace'], ReaderIntent.up, layer: s),
      Binding(['A'], ReaderIntent.addRoot),
      Binding(['g', 'A'], ReaderIntent.removeRoot),
      Binding(['R'], ReaderIntent.rescan),
      Binding(['g', '!'], ReaderIntent.showScanFailures),
      Binding(['S'], ReaderIntent.toggleShuffle),
      Binding(['g', 's'], ReaderIntent.reshuffle),
      Binding(['F'], ReaderIntent.filterFolders),
      Binding(['X'], ReaderIntent.resetBook),
      Binding(['e'], ReaderIntent.editBook),
      Binding(['g', 'd'], ReaderIntent.deleteBook),
      Binding(['S-Delete'], ReaderIntent.deleteBook, layer: s),
      Binding(['g', 'u'], ReaderIntent.uploadToS3),
      Binding(['g', 'U'], ReaderIntent.removeFromS3),
      Binding(['g', 'D'], ReaderIntent.downloadFromS3),
      Binding(['g', 'm'], ReaderIntent.moveBooks),
      Binding(['g', 'c'], ReaderIntent.addToCollection),
      Binding(['V'], ReaderIntent.markBook),
      Binding(['S-Left'], ReaderIntent.markLeft, layer: s),
      Binding(['S-Right'], ReaderIntent.markRight, layer: s),
      Binding(['S-Up'], ReaderIntent.markUp, layer: s),
      Binding(['S-Down'], ReaderIntent.markDown, layer: s),
      Binding(['S-Home'], ReaderIntent.markToFirst, layer: s),
      Binding(['S-End'], ReaderIntent.markToLast, layer: s),
      Binding(['C-a'], ReaderIntent.markAll, layer: s),
      // Every button on screen has a key (t263): these had none.
      Binding(['u'], ReaderIntent.undo),
      Binding(['g', ','], ReaderIntent.showSettings),
      Binding(['?'], ReaderIntent.showKeymap, layer: s),
      Binding(['g', 't'], ReaderIntent.showTouchZones),
      Binding(['T'], ReaderIntent.showTime),
    ]);
  }

  /// The first key bound to [intent], spelled for a person ([spoken]); null
  /// when it has none (unbound in keys.toml). What a button's tooltip names.
  String? hint(ReaderIntent intent) {
    for (final b in bindings) {
      if (b.intent == intent) return spoken(b);
    }
    return null;
  }

  /// [text] with [intent]'s key after it in brackets, `Favourites (gf)`:
  /// a button's tooltip or label. [text] alone when the intent has no key.
  String tip(String text, ReaderIntent intent) {
    final key = hint(intent);
    return key == null ? text : '$text ($key)';
  }

  /// A binding as a tooltip says it: [describe], but with Ctrl and Shift
  /// written out (`Ctrl+A`, `Shift+Delete`), since `C-a` is keys.toml's
  /// spelling and means nothing on a button.
  static String spoken(Binding b) {
    String one(String k) {
      if (k == letterSlot) return '<a-z>';
      if (k.startsWith('C-S-')) return 'Ctrl+Shift+${k.substring(4)}';
      if (k.startsWith('C-')) return 'Ctrl+${k.length == 3 ? k.substring(2).toUpperCase() : k.substring(2)}';
      if (k.startsWith('S-') && k.length > 2) return 'Shift+${k.substring(2)}';
      return k;
    }

    return b.keys.map(one).join(b.keys.every((k) => k.length == 1 || k == letterSlot) ? '' : ' ');
  }

  /// Human-readable key spelling for the `?` overlay, e.g. `gg`, `m<a-z>`.
  static String describe(Binding b) => b.keys
      .map((k) => k == letterSlot ? '<a-z>' : k)
      .join(b.keys.every((k) => k.length == 1 || k == letterSlot) ? '' : ' ');
}
