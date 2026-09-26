# 1. Installing

[Contents](README.md) · Next: [Getting started](02-getting-started.md)

ComicRedr runs on a Linux laptop and an Android phone, and needs no
account. It should work on any Linux distribution, but it has only been
tested on Fedora.

## On Linux

ComicRedr is built from its source with `make` and `make install`.
[Installing on Linux](../install-linux.md) has the tools to install
first and every step.

## On an Android phone

Add snonux's [F-Droid repository](https://github.com/snonux/fdroid) to
the F-Droid app and install ComicRedr from there. Without F-Droid, build
the APK on your laptop and install it over USB.
[Installing on Android](../install-android.md) has both ways.

What to do on the phone the first time is in
[On the phone](10-phone.md#first-start).

## The panel detector

Guided view and balloon mode rely on a small detector that finds the
panels, speech balloons and captions on each page. It is built into the
app, on Linux and on the phone. It runs on
your own processor, a fraction of a second a page; how it is used is in
[How panels are found](05-guided-view.md#how-panels-are-found).

It was trained only on comics whose licences allow it: public-domain
golden- and silver-age books, US government comics, and Creative Commons
BY comics such as Pepper&Carrot. The model is under the same Apache 2.0
licence as the rest of ComicRedr, and [NOTICE](../../NOTICE) credits
every book it learned from. Everything needed to train it again is in the
repository; [Training the detector](../training.md) has the steps
(`make train-model`).

To try another model without rebuilding, see
[Another detector model](../install-linux.md#another-detector-model).

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
