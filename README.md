# ComicRedr

A local-first comic reader with Comixology-style guided view, for a Fedora
laptop and an Android phone. CBZ, PDF and folders of page images; no sync,
no network, everything on CPU. The design plan is the reference for every
decision here.

## Quick start on Fedora

> **Current state (M2):** the app starts and the whole keymap is live, but it
> cannot open a comic yet. Opening CBZ files arrives with the M3 reader. Until
> then, every key you press shows up on screen as the command it resolved to,
> which is how you can try the keymap today.

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

*Arrives in M3.* The plan gives three ways to open a book without adding it
to a library: press `o` for a file picker, drag a `.cbz` onto the window, or
pass it on the command line (`comicredr ~/Comics/Daredevil\ 181.cbz`). PDFs
and folders of page images follow in M6, and the browsable library in M7.
To turn existing `.cbr` files into CBZ, see section 3 of the design plan.
A `.cbr` that is really a ZIP will open as-is.

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
| Guided view on and off (returns to the mode you left) | | `v` |
| Cycle single, double, continuous and guided | `Tab` `Shift+Tab` | |
| Spread on and off / shift the spread pairing | | `d` / `D` |
| Fit width, height or whole page | | `zw` `zh` `zz` |
| Zoom in, out, reset | `+` `-` `=` | |
| Fullscreen | `F11` | `f` |
| Bookmark here / set mark a–z / jump to mark / jump back | | `mm` / `ma` / `'a` / `''` |
| Search, next and previous match | | `/` `n` `N` |
| Next / previous book in the series | | `]` `[` |
| Back out one level, or cancel a half-typed key | `Esc` | |

A count in front of a key repeats it: `5l` moves five panels, and
`3 Ctrl+f` turns three pages. A half-typed sequence such as `g` or `4z`
shows in the bottom-right corner. It is dropped if you don't finish it
within 600 ms.

## Layout

```
lib/                      Flutter app (M2 shell: keyboard layer, Riverpod, Drift index)
packages/comic_formats    ComicDocument interface, magic-byte sniffing, natural sort
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
