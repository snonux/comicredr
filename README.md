<p align="center">
  <img src="linux/packaging/org.snonux.comicredr.svg" alt="ComicRedr icon" width="128">
</p>

<h1 align="center">ComicRedr</h1>

A comic reader for a Fedora laptop and an Android phone, made for reading
panel by panel. Its **guided view** glides from one panel to the next, and
from one speech balloon to the next, like Comixology did. It reads the comics
you already have, runs entirely on your own machine, and needs no account,
cloud or network.

- Reads CBZ, CBT, comic EPUB, PDF, folders of page images and single
  PNG, JPEG or WebP pages.
- Finds panels and balloons with a small detector built into the app,
  on your own CPU.
- Remembers your page, panel and zoom in each comic, and carries them to
  the phone with the file.
- Works from the keyboard (with a vi layer for those who want it) and by
  touch.
- Free software under the Apache License 2.0.

The full list of features is [at the bottom of this page](#features).

## Screenshots

![The library: series of covers, with the selected book's details beside them](docs/screenshots/library.webp)

The library: every book in your comics folders as a cover, grouped by
series, with the selected book's details beside them.

| | |
|---|---|
| ![A page of All Top Comics in single-page view](docs/screenshots/page.webp) | ![A two-page spread of Pepper&Carrot](docs/screenshots/spread.webp) |
| Single page, with the page counter and progress bar | Two-page spread (`d`) |
| ![Guided view framing one panel, the rest of the page dimmed](docs/screenshots/guided.webp) | ![Balloon mode zoomed in on one speech balloon](docs/screenshots/balloon.webp) |
| Guided view (`v`) on panel 2 of 6, found by the trained detector | Balloon mode (`b`) steps through the speech balloons in each panel |
| ![Guided view on a painted modern page](docs/screenshots/guided-painted.webp) | ![The night filter on a page](docs/screenshots/night.webp) |
| Guided view on painted art with no gutters | Night filter (`i`) |

The comics are golden- and silver-age books that are in the public domain
because their copyright was not renewed, from the Digital Comic Museum's
archive.org mirror (the reader screenshots show *All Top Comics* 6, Norlen,
1959), and [Pepper&Carrot](https://www.peppercarrot.com) episode 6, *The
Potion Contest*, by David Revoy, licensed
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## Install on Fedora

Install the build tools and Flutter once:

```sh
sudo dnf install git clang cmake ninja-build pkgconf-pkg-config gtk3-devel
git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
flutter doctor        # the "Linux toolchain" line should be green
```

Then build and install ComicRedr:

```sh
git clone https://github.com/snonux/comicredr.git && cd comicredr
make                  # build it
make run              # try it without installing
make install          # add it to the GNOME app grid, no sudo needed
```

The panel detector for guided view is part of the repository, so `make`
builds it in: there is nothing else to download or train.

After `make install`, ComicRedr is in Activities with its own icon, and
**Open With → ComicRedr** works on CBZ, CBT, EPUB and PDF files, on
folders, and on PNG, JPEG and WebP images without becoming your image
viewer or file manager. To update, run
`git pull && make && make install`; `make uninstall` removes it and keeps
your reading progress. `make help` lists everything else.

To install on another Fedora machine without Flutter, `make tarball`
builds `build/comicredr-VERSION-linux-x64.tar.gz`; unpack it there and run
`./install.sh`.

## Install on an Android phone

ComicRedr is sideloaded as an APK; there is no app store build. You build
it on the laptop and install it over USB. On top of the Fedora setup above,
you need a JDK and the Android command-line tools:

```sh
sudo dnf install java-21-openjdk-devel android-tools
mkdir -p ~/Android/Sdk/cmdline-tools && cd ~/Android/Sdk/cmdline-tools
curl -LO https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip
unzip commandlinetools-linux-*_latest.zip && mv cmdline-tools latest
export ANDROID_HOME=~/Android/Sdk   # put this in ~/.bashrc too
~/Android/Sdk/cmdline-tools/latest/bin/sdkmanager "platform-tools"
flutter config --android-sdk ~/Android/Sdk
flutter doctor --android-licenses
```

Turn on **USB debugging** on the phone, plug it in, and from the checkout:

```sh
make keystore       # once: creates your signing key
make apk            # build the APK
make install-apk    # install it, keeping the app's data
```

The APK carries the same built-in panel detector.

> **Back up `~/.config/comicredr/release.jks` and `android/key.properties`.**
> Android only installs an update over the old app, keeping your library
> and positions, when it is signed with the same key. On a new laptop,
> restore both files instead of running `make keystore` again.

On first start, copy some comics into the phone's `Comics` folder, tap
the folder button and allow **All files access** on the settings page it
opens; back in the app, `Comics` is in the library. Any other folder is
added from the same button. The buttons on the reader's status line switch
guided view, balloons and bookmarks, and a Bluetooth keyboard gets the same
keys as the laptop.

## Quick start

1. **Add your comics.** Put them in `~/Comics` and they are in the
   library the first time ComicRedr starts. Kept somewhere else? Press `A`,
   or click **Add your comics folder**, and pick that folder. Every CBZ, CBT,
   EPUB, PDF, one-page image and folder of page images under it turns up as
   a cover, grouped into series. Take `~/Comics` out of the library and it
   stays out.
2. **Read.** Pick a book and press `Enter`. `→` and `←` (or `Space`) turn
   pages; `Esc` goes back to the library.
3. **Try guided view.** Press `v` to go panel by panel, and `b` to step
   through the speech balloons too. Pages the detector isn't sure about,
   such as a splash page, are shown whole.
4. **Press `?` whenever you need a key.** It shows the full keymap, and `/`
   searches it (`zoom`, `bookmark`, `night`).

A single file opens without the library too: `comicredr book.cbz`,
**Open With → ComicRedr** in Files, `o` in the app, or drag it onto the
window. A folder of comics, `comicredr ~/Comics/Marvel` or dropped on the
window, opens the Folders tab there, and is added to the library if it
isn't in it yet. To take a comic to the phone or another laptop, copy its
hidden `.crdb` file along with it (`.book.cbz.crdb` beside `book.cbz`).

Any key can be changed in `keys.toml` (see below for where): `make keys`
starts one from [docs/keys.toml](docs/keys.toml), which lists every action.

### Touch

Tap or swipe at the left and right edges to turn, pinch or double-tap to
zoom, drag to pan, and tap the middle to hide the status line. Drag along
the progress bar to scrub through the book, or tap the grid button for
every page at once. Android's
back gesture leaves guided view, then the book.

Settings has a left-handed and a one-thumb layout, and `gt` shows the
zones while reading. The `[touch]` section of `keys.toml` gives any action
to a tap, double-tap or long press in each of nine zones, to a swipe, or
to a two-finger tap.

### Where your data lives

Each comic's panels, bookmarks, position and edits are in its hidden
`.crdb` sidecar. Everything else (the library folders, settings, history,
covers and thumbnails, `keys.toml`, an installed model) is in one folder,
which `?` names:

- `~/Comics/.comicredr/` when `~/Comics` existed on the first start.
  Nothing of ComicRedr's is then written outside `~/Comics`.
- Otherwise `~/.local/share/org.snonux.comicredr/`, with covers in
  `~/.cache/org.snonux.comicredr/` and keys in `~/.config/comicredr/keys.toml`.
  An install that already has its database there keeps it there.
- On Android the app's private storage; `keys.toml` and an added model go
  in `Android/data/org.snonux.comicredr/files/`.

Deleting that folder starts the app afresh: add your comic folders again
and one scan brings back everything the sidecars hold. Settings and the
reading history are lost.

### The trained detector

Guided view and balloon mode rely on a small detector that finds the panels,
speech balloons and captions on each page. It is built into the app, so
there is nothing to download or set up: `make` and `make install` (or
`make apk`) include it. It runs on your own CPU, and a page takes about a
sixth of a second. Pages it is unsure about, like a splash page, are shown
whole instead of guessed at.

It was trained only on comics whose licences allow it: public-domain
golden- and silver-age books, US government comics, and Creative Commons
BY comics such as Pepper&Carrot. The model is under the same Apache 2.0
licence as the rest of ComicRedr, and [NOTICE](NOTICE) credits every
book it learned from. Everything needed to train it again is in this
repository; [docs/training.md](docs/training.md) has the steps
(`make train-model`).

To try another model without rebuilding, `make install-model MODEL=file.onnx`
(or `make push-model` for the phone) puts it beside the app, where it wins
over the built-in one until the next `make install` (or `make install-apk`)
moves it aside to `comicredr-panels.onnx.old`. `make install KEEP_MODEL=1`
keeps it.

### The CBR files you already have

ComicRedr doesn't read RAR archives. Convert them to CBZ once; it takes a
couple of seconds a book:

```sh
sudo dnf install unar zip
for f in *.cbr; do
  d=$(mktemp -d)
  unar -q -o "$d" "$f"
  (cd "$d" && zip -qr0 "$OLDPWD/${f%.cbr}.cbz" .)
  rm -rf "$d"
done
```

A `.cbr` that is really a ZIP opens as it is.

## More

- What changed in each version: [CHANGELOG.md](CHANGELOG.md)
- Training the panel detector: [docs/training.md](docs/training.md)
- Notes for developers, the test scripts and conventions: [AGENTS.md](AGENTS.md)

## Features

Every key below can be changed, and `?` in the app lists them all.

### Guided view

- **Panel by panel** (`v`): the camera glides to each panel in reading
  order and dims the rest of the page. Slanted and cut-corner panels are
  dimmed along their real outline.
- **Balloon by balloon** (`b`): inside each panel, the view steps through
  the speech and thought balloons. Narration captions are skipped.
- **The whole page first and last** (`w`): each page can show whole before
  its first panel and after its last one, or go straight from panel to
  panel.
- **Pages it can't guide** (splash pages, ads, text pages) show whole. The
  first press holds on them and turns the background a dark wine red, so
  you see the page before the next press turns it. `gw` swaps the red for
  a quick zoom out and back, and `W` turns the hold off. The status line
  says why a page is shown whole.
- **Ready as you open a book**: panels are found in the background,
  starting at your page. After each library scan, the whole library is
  analysed at low priority, carrying on after a restart. This is off by
  default on the phone.
- **Wide scanner margins** are cut off before detection, so a page
  scanned with a lot of blank paper around it is still guided.
- `X` (or Reset in a book's details) finds a comic's panels again, or
  resets everything about it.

### Reading

- **Single page, two-page spreads (`d`, `D` to shift the pairing) or
  continuous scrolling (`s`)**, left to right or right to left (`r`, per
  book). A scanned double-page spread stays whole, and the pages after it
  keep their sides.
- **Zoom and pan**: `+` `-` `=`, fit width (`zw`), height (`zh`) or page
  (`zz`), `Z` to zoom on a spot, a pinch, a double-tap or the scroll wheel.
- **Enlarge part of a page**: `H1` `H2` for halves, `B1` to `B3` for
  thirds, `Q1` to `Q4` for quarters. `→` steps through the parts before
  the page turns, and `Esc` shows the whole page again.
- **Turn the comic** a quarter at a time: `>` clockwise, `<` the other way
  (`2>` turns it upside down), `gr` back upright. The turn is kept for
  that comic, in guided view too.
- **Night filter** (`i`) and **auto-trim** of white scanner margins (`t`),
  both remembered.
- **Clean-up for old scans** (`c`): yellowed paper turns white, faded ink
  dark, and pages with fewer pixels than your screen are enlarged and
  sharpened in the background.
- **Fullscreen** (`f` or F11), for the library and the reader: no title
  bar or border, only the comic. Move the mouse to the bottom edge to see
  where you are.
- **The time at a glance** (`T`, or a long press in the middle): the time,
  large, for two seconds.
- **Page thumbnails** (`p`): a grid of every page to jump to, zoomable
  with `+` and `-`. Dragging along the progress bar, or hovering over it,
  previews the page under the pointer.
- **Picks up where you left off**: the same page, panel, balloon and
  zoom, even after the file is renamed or copied. A resize or a phone
  rotation keeps the view.
- **Next and previous book** in the series or folder with `]` and `[`.

### Bookmarks and notes

- **Bookmarks** on a page, or on a panel in guided view (`mm`, again to
  take it off), with a short note if you like. A ribbon on the page and
  notches on the progress bar show where they are.
- `M` lists a book's bookmarks with a picture of each page. `}` and `{`
  jump between them, and the library's Bookmarks tab gathers every book's,
  searchable by note.
- **vi marks**: `m` and a letter sets a mark, `'` and the letter jumps
  back to it, and `''` returns to where you were before a jump.

### Library

- **Your comics folders as covers**, on Reading, Series, Books, Folders,
  Collections and Bookmarks tabs. `~/Comics` is added by itself when it
  exists, and books are grouped into series.
- **Search** the library with `/`.
- **The Folders tab** follows your folders on disk, with `Backspace` to go
  up. Files added, moved or deleted show up while it is open, and `R`
  rescans.
- **Collections** of your own, made from a book's details, and a
  **Favourites** collection: `*` adds or removes a comic, and `gf` or the
  star opens it.
- **Shuffle** (`S` on the Folders tab, `gs` to pick again): each comic
  shows a random page instead of its cover.
- **Details of every comic** (`I`): the file and its real format, page
  sizes, how sharp the scans are on your screen, JPEG quality, the images
  inside a PDF, metadata, reading time, and what detection found on each
  page.
- **Fix a book's title, series or issue** (`e`). The comic file itself is
  never changed.
- **A reading history** of your sittings.
- **Delete a comic** (Shift+Delete or `gd`) after a confirmation. The file
  and its sidecar are gone for good, not moved to the trash.

### Files and formats

- **CBZ, CBT and PDF**, **comic EPUBs** made of page images (text ebooks
  are refused), **folders of page images** (JPEG, PNG, WebP, GIF, BMP,
  sub-folders included) and **single PNG, JPEG or WebP pages** as
  one-page comics. The file's contents decide the format, not its name.
- **Open a comic without the library**: `comicredr book.cbz`, Open With in
  Files, `o` in the app, or a drop on the window. A folder given the same
  way opens as a book or in the Folders tab.
- **Your data travels with the comic**: panels, bookmarks, marks, notes,
  edits, collections and your position live in a small hidden `.crdb`
  file beside it. A comic copied to the phone opens there ready to read,
  and positions from each device are offered back. Settings can keep all
  these files in one folder instead, or export them.
- **Everything else in one place**: with a `~/Comics` folder, the app's
  own data lives in `~/Comics/.comicredr/` (see
  [Where your data lives](#where-your-data-lives)).
- CBR is not supported. [The CBR files you already have](#the-cbr-files-you-already-have)
  shows how to convert them.

### Keyboard and touch

- **Keyboard first**: the usual keys, plus a vi layer with counts
  (`5l`), sequences (`gg`, `zw`) and marks.
- **Your own keys**: any action can be rebound in `keys.toml`, and
  `make keys` starts one from [docs/keys.toml](docs/keys.toml).
- **`?`** shows the live keymap and where your data is, and `/` searches
  it.
- **Touch** on the phone and on a laptop touchscreen: taps, double-taps
  and long presses in nine zones, swipes and a two-finger tap. There are
  standard, left-handed and one-thumb layouts, and `gt` shows the zones.
  The `[touch]` section of `keys.toml` remaps any of them.
- **Accessible**: large status-line buttons, pages and overlays labelled
  for screen readers, notices read out, and the layout holds at double
  text size.

### Platforms

- **Fedora (GNOME)**: `make install` adds a launcher with its own icon and
  Open With entries without taking over your image viewer or file
  manager. `make tarball` packs the app for a machine without Flutter.
- **Android**: a sideloaded APK with the same reader, the same detector
  and the same keys on a Bluetooth keyboard. Status-line buttons cover
  guided view, balloons and bookmarks, and the back gesture steps out.
- **Offline and private**: no account, no sync service, no network.
