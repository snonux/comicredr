# 10. On a phone or tablet

[Contents](README.md) · Previous: [The keyboard](09-keyboard.md) · Next: [Your data](11-your-data.md)

ComicRedr on an Android phone or tablet is the same app as on the laptop,
laid out for the screen it is on. How to build it and put it on the
device is in [Installing](01-installing.md#on-an-android-phone-or-tablet).
A tablet gets [a layout of its own](#on-a-tablet).

| | | |
|---|---|---|
| <img src="images/android-library.webp" width="240" alt="The library on an Android phone"> | <img src="images/android-reader.webp" width="240" alt="A page on an Android phone"> | <img src="images/android-guided.webp" width="240" alt="Guided view on an Android phone"> |
| The library, with its tabs at the bottom | A page, with the status line's buttons | Guided view: a panel fills the width |

These pictures are from the Android 14 emulator.

## First start

1. Copy some comics into the phone's `Comics` folder (over USB, or
   however you like).
2. Start ComicRedr and tap the folder button.
3. Android asks you to allow **All files access** for ComicRedr on a
   settings page. Allow it, then come back. (Android 10 and older ask
   in a dialog instead.)
4. `Comics` is now in the library. The folder button adds any other
   folder.

| | | |
|---|---|---|
| <img src="images/android-empty.webp" width="240" alt="The first start on an Android phone"> | <img src="images/android-allow-dialog.webp" width="240" alt="ComicRedr asks for access to your comics"> | <img src="images/android-all-files.webp" width="240" alt="Android's All files access page"> |
| The first start | ComicRedr explains what it needs | Android's settings page: turn the switch on |

## What is different on the phone

- The library's tabs are at the bottom, and tapping a cover opens a page
  with its details and a **Read** button. A long press does the same.
- The reader's status line has buttons for guided view, balloons, the
  page grid, bookmarks and fullscreen; see [Touch](08-touch.md) for the
  gestures.
- The back gesture works like `Esc`: out of guided view, then out of the
  book, then up through the library.
- The phone turns with you: turning it keeps your page, zoom and panel.
- As on the laptop, panels are only found for the comic you have open,
  ahead of the page you are on.
- A Bluetooth keyboard works, with all the same keys.

## On a tablet

A tablet is laid out like the laptop rather than like a big phone. The
library's tabs run down the left side, and held sideways (or on any
screen more than 1000 points wide) a tap on a cover shows its details
beside the covers instead of on a page of their own.

![The library on a 10-inch tablet held sideways](images/android-tablet-library.webp)

- The reader's status line keeps the book's title and adds the details
  button and one for [two pages side by side](04-reading.md#two-pages-side-by-side).
  Held sideways, two pages fill a 10-inch screen about as well as one
  page fills it upright.
- Turning the tablet, or putting ComicRedr in split screen next to
  another app, keeps the page, the zoom and the panel. The narrower
  ComicRedr's half of the screen gets, the more it looks like the phone:
  below 600 points wide the tabs move to the bottom.
- ComicRedr keeps more decoded pages in memory on a tablet, sized to its
  screen, so turning pages stays quick at the higher resolution.

![Two pages side by side on a tablet held sideways, in fullscreen](images/android-tablet-spread.webp)

<img src="images/android-tablet-portrait.webp" width="320" alt="A page on a tablet held upright">

These pictures are from the Android 14 emulator's Pixel Tablet
(2560 × 1600).

## From the laptop to the phone and back

Every comic carries a small hidden [sidecar file](11-your-data.md) with
its bookmarks, found panels and where you are. Copy the comic together
with its sidecar (`.book.cbz.crdb` beside `book.cbz`) and it opens on the
phone ready to read, without finding its panels again.

If you read further on the other device, ComicRedr notices when you open
the comic and asks whether to go there:

> **Read further on phone**
> This comic was last read on phone, up to page 24, panel 3. Go there?

Your own keys and a detector model of your own can go onto the phone
too: `make push-keys` and `make push-model MODEL=file.onnx` from the
laptop.

[Contents](README.md) · Previous: [The keyboard](09-keyboard.md) · Next: [Your data](11-your-data.md)
