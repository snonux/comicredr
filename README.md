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
- Finds panels, speech balloons and captions with a small detector built
  into the app, on your own CPU.
- Single pages, two-page spreads or continuous scrolling, with zoom, a
  night filter, margin trimming and clean-up for yellowed old scans.
- A library of your comics folders: covers, series, folders, search,
  collections, favourites, bookmarks with notes and a reading history.
- Remembers your page, panel and zoom in each comic, and carries them
  and your bookmarks to the phone with the file.
- Works from the keyboard (with a vi layer for those who want it) and by
  touch, and every key can be changed.
- Free software under the Apache License 2.0.

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

The easiest way is F-Droid: add the repository
<https://snonux.github.io/fdroid/repo> (see
[snonux/fdroid](https://github.com/snonux/fdroid) for the one-tap link and
fingerprint) and install ComicRedr from there; F-Droid then keeps it
updated. It serves the signed APK of each tagged release (arm64 phones).

To build it yourself instead, you build it on the laptop and install it
over USB. On top of the Fedora setup above, you need a JDK and the Android
command-line tools:

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
> restore both files instead of running `make keystore` again. The
> F-Droid builds are signed with the same key, so either kind of APK
> updates the other.

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
   searches it (`zoom`, `bookmark`, `night`). Everything else, with
   pictures, is in [the guide](docs/guide/README.md).

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

## Releases

A release is a `vX.Y.Z` tag on a commit whose `pubspec.yaml` says
`version: X.Y.Z+N`, with `N` one more than the last release:

1. Bump `version:` in `pubspec.yaml` and move the `Unreleased` notes in
   `CHANGELOG.md` under the new version.
2. Write `fastlane/metadata/android/en-US/changelogs/N.txt`, a few lines
   (at most 500 characters) that F-Droid shows as *What's new*.
3. Commit, `git tag vX.Y.Z`, `git push && git push --tags`.

The tag starts `.github/workflows/release.yml`, which builds the arm64 APK with
the release key and attaches it to the GitHub release of the tag. The
[F-Droid repository](https://github.com/snonux/fdroid) picks it up with the
store listing in `fastlane/` at that tag. The workflow needs these
repository secrets, taken from `android/key.properties`:

```sh
base64 -w0 ~/.config/comicredr/release.jks | gh secret set ANDROID_KEYSTORE
gh secret set ANDROID_KEY_ALIAS          # comicredr
gh secret set ANDROID_KEYSTORE_PASSWORD  # storePassword
gh secret set ANDROID_KEY_PASSWORD       # keyPassword
```

With an optional `FDROID_DISPATCH_TOKEN` (a fine-grained token with
*Contents: read and write* on snonux/fdroid) the F-Droid repository
refreshes right away instead of within six hours.

## More

- Every feature, with screenshots and short animations: [the ComicRedr guide](docs/guide/README.md)
- What changed in each version: [CHANGELOG.md](CHANGELOG.md)
- How it works inside, with diagrams and the detector model explained: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Training the panel detector: [docs/training.md](docs/training.md)
- Notes for developers, the test scripts and conventions: [AGENTS.md](AGENTS.md)
