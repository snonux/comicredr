# ComicRedr

A local-first comic reader with Comixology-style guided view, for a Fedora
laptop and an Android phone. CBZ, PDF and folders of page images; no sync,
no network, everything on CPU. The design plan is the reference for every
decision here.

## Quick start on Fedora

> **Current state (M3):** CBZ files open and read in single-page or
> two-page mode, with zoom, the full keymap, touch gestures, and resume. Guided view (M4),
> PDF and folders (M6), and the library (M7) are still to come.

### 1. Install the build tools and Flutter

```sh
sudo dnf install git clang cmake ninja-build pkgconf-pkg-config gtk3-devel
git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
flutter doctor        # the "Linux toolchain" line should be green
```

### 2. Build and start

```sh
git clone https://github.com/snonux/comicredr.git && cd comicredr
flutter pub get
flutter run -d linux                  # debug build, hot reload with r
```

For a standalone release build:

```sh
flutter build linux --release
./build/linux/x64/release/bundle/comicredr
```

The `bundle/` directory is self-contained. Copy it anywhere, for example
`~/.local/opt/comicredr`, and start the `comicredr` binary inside it.

### 3. Open a comic book

Any of these opens a `.cbz` straight away, without adding it to a library:

- pass it on the command line: `comicredr ~/Comics/Daredevil\ 181.cbz`
- press `o`, or click **Open a comic**, for a file picker
- drag the file onto the window

The book reopens at the page where you left it, even after you rename or
copy it, because progress is keyed on the file's content rather than its
path. `]` and `[` open the next and previous book in the same folder. `Esc`
closes the book.

The file's first bytes decide how it is read, not its extension, so a `.cbr`
that is really a ZIP opens as-is. PDFs and folders of images arrive in M6.

#### The CBR files you already have

A genuine RAR is refused with a message pointing here. Convert it once to
CBZ. This takes a couple of seconds a book, and the CBZ opens faster:

```sh
sudo dnf install unar zip
for f in *.cbr; do
  d=$(mktemp -d)
  unar -q -o "$d" "$f"
  (cd "$d" && zip -qr0 "$OLDPWD/${f%.cbr}.cbz" .)
  rm -rf "$d"
done
```

### 4. Navigate

Two keymaps are live at the same time: standard keys, and a vi layer on top
of them. You don't need to learn the vi layer to use the reader. Press `?`
to see the full keymap in the app. The overlay is generated from the same
table the app binds from.

| Do this | Standard | vi |
|---|---|---|
| Next / previous step (a panel in guided view, a page otherwise) | `→` `←`, `Space` `Shift+Space` | `l` `h` |
| Next / previous page, skipping panels | `PgDn` `PgUp` | `Ctrl+f` `Ctrl+b` |
| Pan, or scroll in continuous mode | `↓` `↑` | `j` `k`, `Ctrl+d` `Ctrl+u` for half a screen |
| First / last page | `Home` `End` | `gg` `G`, and `42G` goes to page 42 |
| Guided view on and off (M4) | | `v` |
| Switch between single page and spread | `Tab` `Shift+Tab` | `d` |
| Shift the spread pairing by one page | | `D` |
| Fit width, height or whole page | | `zw` `zh` `zz` |
| Zoom in, out, reset | `+` `-` `=` | |
| Hide the status line (and system bars on Android) | `F11` | `f` |
| Night filter | | `i` |
| Set mark a–z / jump to mark / jump back | | `ma` / `'a` / `''` |
| Next / previous book in the same folder (the series, once the library lands in M7) | | `]` `[` |
| Close the book, or cancel a half-typed key | `Esc` | |
| Open a file | | `o` |

A count in front of a key repeats it: `5l` moves five pages (five panels
once guided view lands), and `3 Ctrl+f` turns three pages. Marks last while
the book is open for now; saved bookmarks arrive with sidecars in M8. A key
whose feature has not landed yet says so on the status line. A half-typed sequence such as `g` or `4z`
shows in the bottom-right corner. It is dropped if you don't finish it
within 600 ms.

### 5. Touch

A touchscreen works the same on the Fedora laptop as on the phone, and every
gesture does what the matching key does. A mouse click never turns a page,
so clicking into the window is safe.

| Do this | Touch | Same as |
|---|---|---|
| Next / previous step (a panel in guided view, a page otherwise) | tap the right or left edge, or swipe left or right | `→` `←` |
| Zoom | pinch with two fingers, or double-tap the middle to zoom in on that spot | `+` `-` |
| Back to the whole page | double-tap the middle again | `=` |
| Move around a zoomed page | drag with one finger | `↓` `↑` |
| Hide or show the status line | tap the middle | `F11` |

The edges are the outer 30% of the screen on each side. A swipe on a
zoomed page pans it instead of turning; swipe again once it stops at the
edge of the page to turn. Right to left books mirror taps and swipes just
as they mirror the arrow keys. A touchpad pinch zooms too.

## Layout

```
lib/                      Flutter app: reader screen, page cache, keyboard layer, Drift index
packages/comic_formats    ComicDocument, the CBZ adapter and its worker isolate, sniffing, sort
packages/comic_analysis   Panel model, reading order, the guided-view confidence gate
packages/reader_input     ReaderIntents, default keymap, vi key-sequence resolver
spike/                    M1 throwaway: classic-CV panel detection and overlays
test/corpus.manifest.toml Free test comics, fetched into git-ignored test/corpus/
```

## Develop

```sh
dart run build_runner build -d   # regenerate Drift code after schema edits
flutter analyze && flutter test
for p in packages/*; do (cd $p && dart test); done
tool/e2e_linux.sh        # release build under Xvfb, driven by real keys and injected GTK touches, screenshots in build/e2e/
```

## M1 detection spike

```sh
pip install opencv-python-headless numpy pillow pypdfium2 huggingface_hub ultralytics
python3 spike/make_synthetic.py                       # synthetic pages with ground truth
python3 spike/fetch_corpus.py                         # real comics + pretrained model
python3 spike/extract_pages.py test/corpus spike/pages
cd spike && python3 run_spike.py pages out --weights ../test/corpus/models/<model>.pt
```

`out/contact.jpg` shows every overlay: green boxes passed the confidence
gate, red ones fell back to plain paging, blue are the pretrained detector's
frames, magenta its balloons. Pages are sampled into one folder per style
(from the manifest's `style` field), `out/contact-<style>.jpg` puts classic
CV and the pretrained model side by side for each style, and `results.json`
carries a per-style summary.
