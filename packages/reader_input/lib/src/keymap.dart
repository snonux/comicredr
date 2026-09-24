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
      Binding(['Right'], ReaderIntent.nextStep, layer: s),
      Binding(['Left'], ReaderIntent.prevStep, layer: s),
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
      Binding([']'], ReaderIntent.nextBook),
      Binding(['['], ReaderIntent.prevBook),
      // Switching how the page is shown.
      Binding(['v'], ReaderIntent.toggleGuided),
      Binding(['b'], ReaderIntent.toggleBalloons),
      Binding(['w'], ReaderIntent.toggleWholePage),
      Binding(['Tab'], ReaderIntent.cycleModeForward, layer: s),
      Binding(['S-Tab'], ReaderIntent.cycleModeBack, layer: s),
      Binding(['d'], ReaderIntent.toggleSpread),
      Binding(['D'], ReaderIntent.shiftSpread),
      Binding(['s'], ReaderIntent.toggleContinuous),
      Binding(['r'], ReaderIntent.toggleDirection),
      Binding(['z', 'w'], ReaderIntent.fitWidth),
      Binding(['z', 'h'], ReaderIntent.fitHeight),
      Binding(['z', 'z'], ReaderIntent.fitPage),
      Binding(['+'], ReaderIntent.zoomIn, layer: s),
      Binding(['-'], ReaderIntent.zoomOut, layer: s),
      Binding(['='], ReaderIntent.zoomReset, layer: s),
      Binding(['t'], ReaderIntent.autoTrim),
      Binding(['i'], ReaderIntent.nightFilter),
      Binding(['f'], ReaderIntent.fullscreen),
      Binding(['F11'], ReaderIntent.fullscreen, layer: s),
      // Marks, search and getting out.
      Binding(['m', 'm'], ReaderIntent.bookmark),
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
      Binding(['X'], ReaderIntent.resetBook),
      Binding(['?'], ReaderIntent.showKeymap, layer: s),
    ]);
  }

  /// Human-readable key spelling for the `?` overlay, e.g. `gg`, `m<a-z>`.
  static String describe(Binding b) => b.keys
      .map((k) => k == letterSlot ? '<a-z>' : k)
      .join(b.keys.every((k) => k.length == 1 || k == letterSlot) ? '' : ' ');
}
