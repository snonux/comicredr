<p align="center">
  <img src="linux/packaging/org.snonux.comicredr.svg" alt="ComicRedr icon" width="128">
</p>

<h1 align="center">ComicRedr</h1>

A comic reader with Comixology-style guided view, for a Fedora laptop and
an Android phone. It reads CBZ, PDF and folders of page images, runs
entirely on your own machine, and needs no account, sync or network.

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

## Features

- **Guided view** glides from panel to panel, and **balloon mode** from
  speech balloon to speech balloon inside each panel. Panels are found by a
  small detector that runs on your own CPU.
- **Single page or two-page spreads**, with zoom, a night filter and
  automatic trimming of white scanner margins.
- **See before you jump**: `p` opens a grid of page thumbnails, and
  dragging along the progress bar previews the page under your finger.
- **A library** of your comics folders: covers, series, search,
  collections, a folder view, bookmarks and a reading history.
- **Picks up where you left off**, on the same page, panel and zoom, even
  after you rename or copy the file.
- **Keyboard first**, with a vi layer on top of the usual keys and your
  own key bindings, plus full touch support on the phone and on a laptop
  touchscreen.
- **Your data travels with the comic**: panels, bookmarks and your position
  live in a small `.crdb` file beside it, so a comic copied to the phone
  opens there ready to read. Settings can keep those files in one folder
  instead.
- **CBZ, PDF and folders of page images**, on Fedora and Android.

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
make model MODEL=path/to/comicredr-panels.onnx   # once, see The trained detector
make                  # build it
make run              # try it without installing
make install          # add it to the GNOME app grid, no sudo needed
```

After `make install`, ComicRedr is in Activities with its own icon, and
**Open With → ComicRedr** works on CBZ and PDF files. To update, run
`git pull && make && make install`; `make uninstall` removes it and keeps
your reading progress. `make help` lists everything else.

To install on another Fedora machine without Flutter, `make tarball`
builds `build/comicredr-VERSION-linux-x64.tar.gz`; unpack it there and run
`./install.sh`.

### The trained detector

The trained model finds panels much more reliably than classic computer
vision and is the only way to get balloon mode. It is one file,
`comicredr-panels.onnx`, kept out of this repository because it builds on
a model trained on research-only data: get it from whoever gave you
ComicRedr, or train it yourself (see [AGENTS.md](AGENTS.md)). With it in
the checkout, `make` builds it into the Linux app and `make apk` into the
Android APK, so an installed app needs nothing else.

| Make target | What it does |
|---|---|
| `make model MODEL=path/to/comicredr-panels.onnx` | Puts the model in the checkout (`assets/models/`), once per checkout. |
| `make && make install` | Builds and installs the Linux app with the model inside. |
| `make apk && make install-apk` | Builds and installs the Android APK with the model inside. |
| `make install-model MODEL=file.onnx` | Adds a model to the installed Linux app without rebuilding; it wins over the built-in one. |
| `make push-model MODEL=file.onnx` | The same on the phone, over USB. |
| `make NO_MODEL=1` | Builds without a model; the app uses classic computer vision. |

For example, on a new laptop:

```sh
make model MODEL=~/Downloads/comicredr-panels.onnx
make && make install     # Linux
make apk && make install-apk   # Android, phone on USB
```

Without the model, `make` and `make apk` stop and say what to run. Restart
the app after `install-model` or `push-model`.

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

> **Back up `~/.config/comicredr/release.jks` and `android/key.properties`.**
> Android only installs an update over the old app, keeping your library
> and positions, when it is signed with the same key. On a new laptop,
> restore both files instead of running `make keystore` again.

On first start, copy some comics to the phone (for example into `Comics`),
tap the folder button, allow **All files access** on the settings page it
opens, then add the folder. The buttons on the reader's status line switch
guided view, balloons and bookmarks, and a Bluetooth keyboard gets the same
keys as the laptop.

## Quick start

1. **Add your comics.** Press `A`, or click **Add your comics folder**, and
   pick the folder your comics are in. Every CBZ, PDF and folder of page
   images under it turns up as a cover, grouped into series.
2. **Read.** Pick a book and press `Enter`. `→` and `←` (or `Space`) turn
   pages; `Esc` goes back to the library.
3. **Try guided view.** Press `v` to go panel by panel, and `b` to step
   through the speech balloons too. Pages the detector isn't sure about,
   such as a splash page, are shown whole.
4. **Press `?` whenever you need a key.** It shows the full keymap, and `/`
   searches it (`zoom`, `bookmark`, `night`).

A single file opens without the library too: `comicredr book.cbz`,
**Open With → ComicRedr** in Files, `o` in the app, or drag it onto the
window. To take a comic to the phone or another laptop, copy its `.crdb`
file along with it.

Any key can be changed in `~/.config/comicredr/keys.toml`: `make keys`
starts one from [docs/keys.toml](docs/keys.toml), which lists every action.

### Touch

Tap or swipe at the left and right edges to turn, pinch or double-tap to
zoom, drag to pan, and tap the middle to hide the status line. Drag along
the progress bar to scrub through the book, or tap the grid button for
every page at once. Android's
back gesture leaves guided view, then the book.

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

What changed in each version is in [CHANGELOG.md](CHANGELOG.md).
Development notes, the test scripts and how the detector is trained are in
[AGENTS.md](AGENTS.md).
