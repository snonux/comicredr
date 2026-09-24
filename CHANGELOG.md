# Changelog

Versions follow [semantic versioning](https://semver.org). The version
lives in `pubspec.yaml`; `make version` prints it, `comicredr --version`
reports it, and the app shows it in the library's status line and in
the `?` overlay.

## Unreleased

- **Wide scanned margins:** guided view no longer shows a page whole just
  because it was scanned with a wide blank margin. The trained detector
  looks at such a page with the margin cut off, whether or not `t` is on;
  with a 12% margin added to the labelled test pages, 68 of 100 are guided
  right instead of 28. Books are detected again once.

- **M9, polish and ship:** `t` auto-trims the white margins off scanned
  pages, and it and the night filter (`i`) are now remembered across books
  and restarts. Any key can be remapped in
  `~/.config/comicredr/keys.toml` ([docs/keys.toml](docs/keys.toml) has the
  defaults; `make keys` starts one). `/` in the `?` overlay searches it,
  fuzzily or with a `/regex/`. `make tarball` packs the Linux release with
  an `install.sh`. Accessibility: 48 px status-line buttons, pages and the
  overlay labelled for screen readers, notices read out as they appear, and
  the layout holds at double text size.

- **Slanted panels:** guided view dims along a panel's real outline when
  it is not a rectangle (slanted gutters, cut corners), so the
  neighbouring panels' corners no longer stay lit. Pages whose slanted
  panels' boxes overlap are now guided instead of shown whole, and read
  top panel first. Books are detected again once.

- **Android:** the APK builds and has been tested on an Android 14
  emulator. `make keystore`, `make apk`, `make install-apk` and
  `make push-model` build, sign and sideload it; the README has the steps.
  PDFs no longer all fail to open on Android, the back gesture steps out
  of guided view and the book instead of closing the app, and the
  reader's status line has buttons for guided view, balloons and
  bookmarks, and puts the page counter first on a phone. The app has its
  own launcher icon.

## 0.1.0 (2026-09-24)

The first tagged version: a working reader on the Fedora desktop, with
guided view. Android builds exist in the tree but are not tested yet.

- **Library:** point it at your comics folders and it scans them into
  Reading, Series, Books and Folders tabs, with covers, series grouping
  from file names, search and bookmarks.
- **Formats:** CBZ files, PDFs (rendered with PDFium) and plain folders of
  page images. CBR is not supported; the README shows how to convert.
- **Reading:** single page or two-page spreads with cover pairing,
  left-to-right or right-to-left, zoom and pan, a night filter, a
  `page X / N` counter and a progress bar.
- **Guided view (`v`):** steps panel by panel, with `panel X / N` in the
  status line. Panels come from the trained ONNX detector when it is
  installed (`make install-model`) and from classic computer vision behind
  a confidence gate otherwise. Pages the gate rejects show whole.
- **Balloon mode (`b`):** steps through the speech balloons inside each
  panel, zoomed in on each one.
- **Keyboard:** standard keys plus a vi-style layer with counts, marks and
  sequences; `?` shows the whole keymap.
- **Touch:** pinch zoom, pan, edge taps and swipes, on the desktop as well
  as the phone.
- **Resume:** reopening a book returns to the same page, panel, balloon,
  mode and zoom.
- **Linux install:** `make install` puts the app, a GNOME launcher, the
  icon and "Open with" entries for CBZ and PDF under `~/.local`.

Not in this version: per-comic sidecar files (M8).
Panels are cached in the app's own database until the sidecars arrive.
