# Installing ComicRedr on Linux

ComicRedr is built from its source on your own machine. It should work on
any Linux distribution, but it has only been tested on Fedora, so the
commands below use Fedora's package names; on another distribution,
install the same tools with its own package manager. The panel detector
that guided view needs is part of the source, so there is nothing else to
download. For the phone, see [Installing on Android](install-android.md).

## Build tools and Flutter

Install everything the build needs and Flutter once. This list was
checked on a bare Fedora 42, from nothing to the app running:

```sh
sudo dnf install git make clang cmake ninja-build pkgconf-pkg-config \
  gtk3-devel libsecret-devel unzip which
git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
flutter doctor        # the "Linux toolchain" line should be green
```

What each is for: `git`, `unzip` and `which` are what Flutter itself
needs; `make`, `clang`, `cmake`, `ninja-build` and `pkgconf-pkg-config`
build the Linux app; `gtk3-devel` is its window, and `libsecret-devel`
lets it keep the S3 sync key in the GNOME keyring. `make` checks for the
last two and names what is missing. Running ComicRedr needs nothing
more: GTK and libsecret come with every Fedora desktop, and the PDF
renderer, SQLite and the detector's ONNX Runtime are in the app itself
(the first build downloads PDFium, so it needs the network).

Optional, for a few extras: `unar` and `zip` to turn CBR files into CBZ
(see [The CBR files you already have](guide/01-installing.md#the-cbr-files-you-already-have)),
and `librsvg2-tools` for `make icons`.

## Build and install

Then build and install ComicRedr:

```sh
git clone https://github.com/snonux/comicredr.git && cd comicredr
make                  # build it
make run              # try it without installing
make install          # add it to the GNOME app grid, no sudo needed
```

After `make install`, ComicRedr is in Activities with its own icon, and
**Open With → ComicRedr** works on CBZ, CBT, EPUB and PDF files, on
folders, and on PNG, JPEG and WebP images, without becoming your image
viewer or file manager.

- To update: `git pull && make && make install`. Since 0.4.0 the build
  also needs `libsecret-devel` (for the S3 sync key in the keyring); `make`
  says so and names the package when it is missing.
- To remove it: `make uninstall`. Your reading progress stays.
- `make help` lists everything else.

To install on another Fedora machine without Flutter, `make tarball`
builds `build/comicredr-VERSION-linux-x64.tar.gz`; unpack it there and run
`./install.sh`.

## Another detector model

To try another model without rebuilding, `make install-model
MODEL=file.onnx` (or `make push-model` for the phone) puts it beside the
app, where it wins over the built-in one until the next `make install`
(or `make install-apk`) moves it aside to `comicredr-panels.onnx.old`.
`make install KEEP_MODEL=1` keeps it. A build made with `make NO_MODEL=1`
has no model and finds panels with classic computer vision, without
balloons.

Where the built-in model comes from, and how to train it again, is in
[Training the detector](training.md).

Once it runs, the [guide](guide/README.md) takes it from there.
