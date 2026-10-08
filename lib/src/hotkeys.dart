import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reader_input/reader_input.dart';

// Every button and dialog has a key (task 263). Two rules, one for each
// place a button can be:
//
// * On a screen (the library, the reader and what lies over it) keys go to
//   ReaderKeyboard, so a button there has a [ReaderIntent] with a key in
//   the keymap, and its tooltip or label names that key as it is now
//   ([KeyHints.tip]), also after keys.toml changed it.
// * In a dialog (a route of its own, which has the focus) the dialog is
//   wrapped in [DialogHotkeys] and its buttons are labelled with
//   [Mnemonic]: Alt and the underlined letter presses the button, as on
//   any Linux desktop. Alt, so that a letter typed into a dialog's text
//   field stays a letter. Esc, Enter, Tab and the arrows are Flutter's.

/// The live keymap for the widgets below it, so a tooltip names the key
/// that works now. Put above the Navigator (MaterialApp.builder): dialogs
/// read it too. Without one (a widget pumped alone in a test) the default
/// keys are named.
class KeyHints extends InheritedWidget {
  const KeyHints({super.key, required this.keymap, required super.child});

  final Keymap keymap;

  static final _defaults = Keymap.defaults();

  static Keymap of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<KeyHints>()?.keymap ?? _defaults;

  /// [text] with [intent]'s first key in brackets, `Favourites (gf)`; just
  /// [text] when keys.toml left the intent without a key.
  static String tip(BuildContext context, String text, ReaderIntent intent) => of(context).tip(text, intent);

  @override
  bool updateShouldNotify(KeyHints old) => old.keymap != keymap;
}

/// Wraps a dialog so that Alt and a letter presses the button whose
/// [Mnemonic] label has that letter. The letters are underlined on a
/// desktop; on a phone or tablet only while Alt is held, so nothing
/// changes for touch, and a keyboard plugged into one works the same.
///
/// Tab and Shift+Tab stop at every control of the dialog, in the order
/// they are written. The letters are taken by an early key handler of the
/// [FocusManager], for the dialog whose route is on top, not by a node of
/// the focus tree: they work before anything in the dialog has the focus,
/// and the wrapper never takes the focus, which would keep a field that
/// shows only once the dialog has loaded (the S3 settings) from getting
/// its `autofocus`. A dialog still gives its default button or first field
/// `autofocus`, for Enter.
///
/// An early handler, and not one of [HardwareKeyboard]: Flutter hands a
/// key to the hardware handlers and to the focus tree both, whatever the
/// first answer, so a `Shortcuts` in the dialog acted on the very press a
/// label had taken (Alt+R in the comic's details popped two routes, the
/// second one the app's own). What an early handler takes, the focus tree
/// never sees. This is the one place a dialog's Alt+letter is handled: a
/// dialog adds none of its own, and one whose button is not always built
/// names its key with [DialogKey].
class DialogHotkeys extends StatefulWidget {
  const DialogHotkeys({super.key, required this.child});

  final Widget child;

  /// Tests set this to see a phone's dialogs (letters underlined only
  /// while Alt is held); null follows the platform.
  @visibleForTesting
  static bool? debugTouchFirst;

  static bool get _touchFirst => debugTouchFirst ?? (Platform.isAndroid || Platform.isIOS);

  @override
  State<DialogHotkeys> createState() => _DialogHotkeysState();
}

class _DialogHotkeysState extends State<DialogHotkeys> {
  /// The labels and [DialogKey]s under the dialog that are built now.
  final _keys = <_Lettered>{};
  bool _alt = HardwareKeyboard.instance.isAltPressed;

  /// The route the dialog is in; its keys are only its own while that
  /// route is the one on top (Settings under a question it asked is not).
  ModalRoute<Object?>? _route;

  /// One for the dialog's life: a new policy at every build would have
  /// Flutter sort the controls anew each time.
  late final _order = _WrittenOrderPolicy(() => context);

  /// The key press a letter was last taken for, by any dialog: one press
  /// of a key is one press of a button, whoever else is asked about it.
  static KeyEvent? _taken;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    super.dispose();
  }

  /// What Alt and [letter] presses, if anything of the dialog has it.
  _Lettered? _keyFor(String letter) {
    final hits = [
      for (final l in _keys)
        if (l.mounted && l.letter == letter) l,
    ];
    assert(hits.length < 2, 'Two buttons of one dialog share Alt+$letter: ${hits.map((l) => l.name).toList()}');
    return hits.firstOrNull;
  }

  /// Every key press, before the focus tree is asked: follows Alt for the
  /// underlines of a phone's dialogs, and takes Alt with a button's
  /// letter. Handled when the key was a button's, and then no node of the
  /// focus tree (a field, a `Shortcuts`, a focused button) gets it.
  KeyEventResult _onKey(KeyEvent event) {
    if (!mounted) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isAltPressed != _alt) setState(() => _alt = keys.isAltPressed);
    if (!(_route?.isCurrent ?? true)) return KeyEventResult.ignored;
    // AltGr is not Alt: on many layouts it types @ and the like.
    if (!keys.isAltPressed || keys.isControlPressed || keys.isMetaPressed) return KeyEventResult.ignored;
    final label = event.logicalKey.keyLabel;
    if (label.length != 1) return KeyEventResult.ignored;
    final hit = _keyFor(label.toLowerCase());
    if (hit == null) return KeyEventResult.ignored;
    // A held key presses once; its repeats and its release are still the
    // dialog's, not a letter for a text field.
    if (event is KeyDownEvent && !identical(event, _taken)) {
      _taken = event;
      hit.press();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => _HotkeyScope(
    state: this,
    show: !DialogHotkeys._touchFirst || _alt,
    child: FocusTraversalGroup(policy: _order, child: widget.child),
  );
}

/// Tab goes through a dialog's controls in the order they are written:
/// the content from its top, then the buttons along the bottom.
///
/// Flutter's usual order is by where each control is on screen, which in
/// a dialog that scrolls (Settings) changes as Tab scrolls it: Tab went
/// round eight controls there and never reached the switches. Its
/// [WidgetOrderTraversalPolicy] is no help either: that is the order the
/// controls came into being, so the collection question's chips, which
/// are read from the index and arrive a moment after the buttons, came
/// after Cancel and Add. So this walks the dialog's own widgets, which
/// is the order on the page whenever they were made.
class _WrittenOrderPolicy extends FocusTraversalPolicy with DirectionalFocusTraversalPolicyMixin {
  _WrittenOrderPolicy(this._dialog);

  /// The [DialogHotkeys] the controls are under.
  final BuildContext Function() _dialog;

  @override
  Iterable<FocusNode> sortDescendants(Iterable<FocusNode> descendants, FocusNode currentNode) {
    final byWidget = <Element, FocusNode>{
      for (final node in descendants)
        if (node.context case final Element e) e: node,
    };
    final sorted = <FocusNode>[];
    void visit(Element e) {
      if (byWidget[e] case final node?) sorted.add(node);
      e.visitChildren(visit);
    }

    final dialog = _dialog();
    if (dialog is Element && dialog.mounted) dialog.visitChildren(visit);
    // A control that is not under the dialog's widgets keeps its turn at the end.
    final found = sorted.toSet();
    return [...sorted, ...descendants.where((n) => !found.contains(n))];
  }
}

class _HotkeyScope extends InheritedWidget {
  const _HotkeyScope({required this.state, required this.show, required super.child});

  final _DialogHotkeysState state;

  /// Whether the letters are underlined now.
  final bool show;

  @override
  bool updateShouldNotify(_HotkeyScope old) => old.show != show || old.state != state;
}

/// Something of a dialog that Alt and a letter presses: a [Mnemonic]
/// label or a [DialogKey].
mixin _Lettered<T extends StatefulWidget> on State<T> {
  _DialogHotkeysState? _scope;

  /// Lower case, as [DialogHotkeys] looks it up; null takes no key.
  String? get letter;

  /// For the message when two share a letter.
  String get name;

  void press();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = context.dependOnInheritedWidgetOfExactType<_HotkeyScope>()?.state;
    if (scope == _scope) return;
    _scope?._keys.remove(this);
    _scope = scope?.._keys.add(this);
  }

  @override
  void dispose() {
    _scope?._keys.remove(this);
    super.dispose();
  }
}

/// A dialog button's label: [text] with its hotkey letter underlined, and
/// Alt with that letter presses the button the label is in (any Material
/// button; a disabled one does nothing). The letter is the first of
/// [text] unless [letter] names another one in it, which a dialog needs
/// when two labels start alike (Cancel and Clear). For a control that is
/// no button, [onPressed] says what the key does.
///
/// [Mnemonic.shown] only underlines: for a button that is not always
/// built (a row of a lazy list), whose key a [DialogKey] holds.
///
/// Outside a [DialogHotkeys] it is plain text and no key.
class Mnemonic extends StatefulWidget {
  const Mnemonic(this.text, {super.key, this.letter, this.onPressed}) : pressed = true;

  const Mnemonic.shown(this.text, {super.key, this.letter}) : onPressed = null, pressed = false;

  final String text;
  final String? letter;
  final VoidCallback? onPressed;

  /// Whether the key presses through this label; false for [Mnemonic.shown].
  final bool pressed;

  /// The letter Alt takes for a label of [text], lower case.
  static String letterOf(String text, String? letter) => (letter ?? text.characters.first).toLowerCase();

  @override
  State<Mnemonic> createState() => _MnemonicState();
}

class _MnemonicState extends State<Mnemonic> with _Lettered<Mnemonic> {
  String get _letter => Mnemonic.letterOf(widget.text, widget.letter);

  @override
  String? get letter => widget.pressed ? _letter : null;

  @override
  String get name => widget.text;

  /// Presses the button this label is in, as a click would.
  @override
  void press() {
    if (widget.onPressed case final own?) {
      own();
      return;
    }
    context.visitAncestorElements((element) {
      final w = element.widget;
      if (w is! ButtonStyleButton) return true;
      w.onPressed?.call();
      return false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final show = context.dependOnInheritedWidgetOfExactType<_HotkeyScope>()?.show ?? false;
    final text = widget.text;
    final at = show ? text.toLowerCase().indexOf(_letter) : -1;
    if (at < 0) return Text(text);
    // The line in the label's own colour, whatever the button gives it
    // (filled, tonal, outlined, disabled, either theme). Material 3's text
    // styles name a decoration colour of their own, the surface's text
    // colour, which on a filled button is close to the fill: the letter
    // was underlined and nobody could see it. A button animates its label
    // colour through the DefaultTextStyle, so this follows it.
    final colour = DefaultTextStyle.of(context).style.color;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text.substring(0, at)),
          TextSpan(
            text: text.substring(at, at + 1),
            style: TextStyle(decoration: TextDecoration.underline, decorationColor: colour),
          ),
          TextSpan(text: text.substring(at + 1)),
        ],
      ),
    );
  }
}

/// Alt and [letter] does [onPressed] for as long as this is built, with
/// nothing to see: for a dialog's button that is a row of a lazily built
/// list and so is not there until scrolled to (Redo panels in the comic's
/// details). Put it around something of the dialog that is always built
/// and label the button with [Mnemonic.shown], which underlines the
/// letter and leaves the key to this. Null [onPressed] takes no key.
class DialogKey extends StatefulWidget {
  const DialogKey({super.key, required this.letter, required this.onPressed, required this.child});

  final String letter;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  State<DialogKey> createState() => _DialogKeyState();
}

class _DialogKeyState extends State<DialogKey> with _Lettered<DialogKey> {
  @override
  String? get letter => widget.onPressed == null ? null : widget.letter.toLowerCase();

  @override
  String get name => 'DialogKey ${widget.letter}';

  @override
  void press() => widget.onPressed?.call();

  @override
  Widget build(BuildContext context) => widget.child;
}

/// [theme] with a ring around whatever has the keyboard focus, so Tab and
/// the arrows can be followed through a dialog: Material's own mark is a
/// tint too faint to see on the dark theme. Flutter only reports a control
/// as focused while keys are in use, so touch never shows it.
ThemeData withFocusRing(ThemeData theme) {
  final ring = BorderSide(color: theme.colorScheme.onSurface, width: 2);
  final side = WidgetStateProperty.resolveWith<BorderSide?>((s) => s.contains(WidgetState.focused) ? ring : null);
  final button = ButtonStyle(side: side);
  return theme.copyWith(
    focusColor: theme.colorScheme.onSurface.withValues(alpha: 0.24),
    textButtonTheme: TextButtonThemeData(style: button),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button),
    iconButtonTheme: IconButtonThemeData(style: button),
    segmentedButtonTheme: SegmentedButtonThemeData(style: button),
    chipTheme: theme.chipTheme.copyWith(
      side: WidgetStateBorderSide.resolveWith((s) => s.contains(WidgetState.focused) ? ring : null),
    ),
  );
}
