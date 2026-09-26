# The ComicRedr guide

A short book about using ComicRedr: what each feature is for, how to use
it, and what it looks like. Read it front to back as a tutorial, or jump
to what you need from the contents below. Every picture is taken from the
app itself.

ComicRedr runs on a Linux laptop and an Android phone. It should work on
any Linux distribution, but it has only been tested on Fedora.

![Guided view stepping from panel to panel](images/guided.gif)

GitHub shows the animations paused when your system asks for reduced
motion (or its own setting, Accessibility → Autoplay animated images, is
off): click one to play it.

In the app, `?` lists every key and searches them, so you never have to
come back here for a key you forgot.

## Contents

1. [Installing](01-installing.md)
   - [On Linux](01-installing.md#on-linux)
   - [On an Android phone](01-installing.md#on-an-android-phone)
   - [The panel detector](01-installing.md#the-panel-detector)
   - [The CBR files you already have](01-installing.md#the-cbr-files-you-already-have)
2. [Getting started](02-getting-started.md)
   - [What it reads](02-getting-started.md#what-it-reads)
   - [Add your comics](02-getting-started.md#add-your-comics)
   - [Open a comic](02-getting-started.md#open-a-comic)
     and [carry on where you stopped: `C`](02-getting-started.md#carry-on-where-you-stopped-c)
   - [Try guided view](02-getting-started.md#try-guided-view)
   - [When you need a key: `?`](02-getting-started.md#when-you-need-a-key-)
3. [The library](03-library.md)
   - [Moving around](03-library.md#moving-around)
   - [The tabs](03-library.md#the-tabs): [series](03-library.md#series),
     [folders](03-library.md#folders), [shuffle](03-library.md#shuffle),
     [history](03-library.md#history)
   - [Search](03-library.md#search)
   - [Favourites](03-library.md#favourites)
   - [Collections](03-library.md#collections)
   - [Adding, rescanning and taking out folders](03-library.md#adding-rescanning-and-taking-out-folders)
4. [Reading a comic](04-reading.md)
   - [Turning pages](04-reading.md#turning-pages)
   - [Jump around with the progress bar](04-reading.md#jump-around-with-the-progress-bar)
   - [See every page at once](04-reading.md#see-every-page-at-once)
   - [Two pages side by side](04-reading.md#two-pages-side-by-side)
   - [Zoom](04-reading.md#zoom)
   - [Parts of a page](04-reading.md#parts-of-a-page)
   - [Turn the comic](04-reading.md#turn-the-comic)
   - [Old scans: clean-up, trim and the night filter](04-reading.md#old-scans-clean-up-trim-and-the-night-filter)
   - [Fullscreen](04-reading.md#fullscreen)
   - [What time is it?](04-reading.md#what-time-is-it)
5. [Guided view](05-guided-view.md)
   - [Panel by panel](05-guided-view.md#panel-by-panel)
   - [Balloon by balloon](05-guided-view.md#balloon-by-balloon)
   - [Pages shown whole](05-guided-view.md#pages-shown-whole) and
     [a quick press stays](05-guided-view.md#a-quick-press-stays)
   - [How panels are found](05-guided-view.md#how-panels-are-found)
6. [Bookmarks and marks](06-bookmarks.md)
   - [Set a bookmark](06-bookmarks.md#set-a-bookmark)
   - [Jump between bookmarks](06-bookmarks.md#jump-between-bookmarks)
   - [The Bookmarks tab](06-bookmarks.md#the-bookmarks-tab)
   - [Marks, for vi users](06-bookmarks.md#marks-for-vi-users)
   - [They travel with the comic](06-bookmarks.md#they-travel-with-the-comic)
7. [Managing your comics](07-managing-comics.md)
   - [Details of a comic](07-managing-comics.md#details-of-a-comic)
   - [Fix a title or series](07-managing-comics.md#fix-a-title-or-series)
   - [Reset a comic](07-managing-comics.md#reset-a-comic)
   - [Delete a comic](07-managing-comics.md#delete-a-comic)
8. [Touch](08-touch.md)
   - [Gestures](08-touch.md#gestures)
   - [The tap zones](08-touch.md#the-tap-zones)
   - [Your own gestures](08-touch.md#your-own-gestures)
9. [The keyboard](09-keyboard.md)
   - [`?` shows every key](09-keyboard.md#-shows-every-key)
   - [The keys you'll use most](09-keyboard.md#the-keys-youll-use-most)
   - [Sequences and counts](09-keyboard.md#sequences-and-counts)
   - [Your own keys](09-keyboard.md#your-own-keys)
10. [On the phone](10-phone.md)
    - [First start](10-phone.md#first-start)
    - [What is different on the phone](10-phone.md#what-is-different-on-the-phone)
    - [From the laptop to the phone and back](10-phone.md#from-the-laptop-to-the-phone-and-back)
11. [Your data](11-your-data.md)
    - [The sidecar beside each comic](11-your-data.md#the-sidecar-beside-each-comic)
    - [Keeping the sidecars in one folder](11-your-data.md#keeping-the-sidecars-in-one-folder)
    - [The app's own folder](11-your-data.md#the-apps-own-folder)
    - [Back up and restore your settings](11-your-data.md#back-up-and-restore-your-settings)
12. [Settings](12-settings.md)

How ComicRedr works inside is a different story, told in
[the architecture document](../architecture.md).

## Credits

The comics in these pictures are free to show:

- Golden- and silver-age comics in the public domain because their
  copyright was not renewed, from the Digital Comic Museum's archive.org
  mirror and other archive.org uploads: *All Top Comics* 6 (Norlen, 1959),
  *International Comics* 4 (EC, 1947), *Mercy for Millions* (True Comics,
  1945), *Weird Comics* 4 (Fox, 1940), *First Love Illustrated* 78
  (Harvey, 1957), *Space War* 2 (Charlton, 1959) and *Reptisaurus* 5
  (Charlton, 1962).
- [Pepper&Carrot](https://www.peppercarrot.com) episode 6, *The Potion
  Contest*, by David Revoy, licensed
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

The pictures are made by `tool/guide_shots.sh`, which drives the real app
and can take them all again after a change.
