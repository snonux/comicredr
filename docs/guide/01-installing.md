# 1. Installing

[Contents](README.md) · Next: [Getting started](02-getting-started.md)

ComicRedr is built from its source on your own Fedora laptop, and the
phone app is built there too and installed over USB. There is no app
store build and nothing to sign up for. The panel detector that guided
view needs is part of the source, so there is nothing else to download.

## On Fedora

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

## On an Android phone

The phone app is an APK you build on the laptop and install over USB. On
top of the Fedora setup above, you need a JDK and the Android
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
> restore both files instead of running `make keystore` again.

What to do on the phone the first time is in
[On the phone](10-phone.md#first-start).

## The panel detector

Guided view and balloon mode rely on a small detector that finds the
panels, speech balloons and captions on each page. It is built into the
app, so `make` and `make install` (or `make apk`) include it. It runs on
your own processor, a fraction of a second a page; how it is used is in
[How panels are found](05-guided-view.md#how-panels-are-found).

It was trained only on comics whose licences allow it: public-domain
golden- and silver-age books, US government comics, and Creative Commons
BY comics such as Pepper&Carrot. The model is under the same Apache 2.0
licence as the rest of ComicRedr, and [NOTICE](../../NOTICE) credits
every book it learned from. Everything needed to train it again is in the
repository; [Training the detector](../training.md) has the steps
(`make train-model`).

To try another model without rebuilding, `make install-model
MODEL=file.onnx` (or `make push-model` for the phone) puts it beside the
app, where it wins over the built-in one until the next `make install`
(or `make install-apk`) moves it aside to `comicredr-panels.onnx.old`.
`make install KEEP_MODEL=1` keeps it. A build made with `make NO_MODEL=1`
has no model and finds panels with classic computer vision, without
balloons.

## The CBR files you already have

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

[Contents](README.md) · Next: [Getting started](02-getting-started.md)
