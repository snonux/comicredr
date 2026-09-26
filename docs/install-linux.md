# Installing ComicRedr on Linux

ComicRedr is built from its source on your own machine. It should work on
any Linux distribution, but it has only been tested on Fedora, so the
commands below use Fedora's package names; on another distribution,
install the same tools with its own package manager. The panel detector
that guided view needs is part of the source, so there is nothing else to
download. For the phone, see [Installing on Android](install-android.md).

## Build tools and Flutter

Install the build tools and Flutter once:

```sh
sudo dnf install git clang cmake ninja-build pkgconf-pkg-config gtk3-devel
git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
flutter doctor        # the "Linux toolchain" line should be green
```

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

- To update: `git pull && make && make install`.
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
