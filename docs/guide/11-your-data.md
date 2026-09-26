# 11. Your data

[Contents](README.md) · Previous: [On the phone](10-phone.md) · Next: [Settings](12-settings.md)

ComicRedr keeps everything on your own machine, in two places: a small
file beside each comic, and one folder for the app itself. Nothing is
sent anywhere, and there is no account.

## The sidecar beside each comic

For every comic, ComicRedr writes a small hidden file beside it, its
*sidecar*: `.book.cbz.crdb` beside `book.cbz`, or `.comicredr.crdb`
inside a folder book. It holds:

- where you are, on each of your devices, and how the comic was turned;
- the panels and balloons found on its pages;
- your bookmarks, notes and marks;
- your [edits](07-managing-comics.md#fix-a-title-or-series) to its title
  and series;
- the collections it is in, Favourites included.

Because it sits beside the comic, it goes wherever the comic goes: copy
both to the phone or another laptop and everything is there. ComicRedr
recognises a comic by its content, not its name, so renaming or moving
the file doesn't lose anything either.

When two copies of a sidecar meet (you read on the laptop and on the
phone), ComicRedr merges them: bookmarks from both, the later edit of
each field, and a bookmark you took off stays off.

### Keeping the sidecars in one folder

If you would rather not have hidden files beside your comics, or the
comics are on a drive ComicRedr can't write to, Settings → **Sidecars**
→ **In one folder** keeps them all in one folder of your choice, laid out
like your library. ComicRedr offers to move the ones already there.
Sidecars left beside comics are still read.

**Export sidecars to a folder…** in Settings writes a copy of every
sidecar to a folder, for a backup. Settings can also turn sidecars off;
everything is then kept in the app's own folder only.

Where a folder can't be written to at all, ComicRedr says so and keeps
that comic's data in its own folder.

## The app's own folder

The library's folders, your settings, the reading history, covers and
page thumbnails, your `keys.toml` and a detector model of your own are
kept in one folder. `?` shows which:

- `~/Comics/.comicredr/` when you have a `~/Comics` folder. Nothing of
  ComicRedr's is then written outside `~/Comics`, so backing up that one
  folder backs up everything.
- Otherwise `~/.local/share/org.snonux.comicredr/`, with covers in
  `~/.cache/org.snonux.comicredr/` and `keys.toml` in
  `~/.config/comicredr/`. An install that already keeps its data there
  goes on doing so.
- On the phone, the app's private storage, with `keys.toml` and an added
  model in `Android/data/org.snonux.comicredr/files/`.

Deleting that folder starts ComicRedr afresh. Add your comic folders
again and one scan brings back everything the sidecars hold: positions,
bookmarks, panels, edits and collections. The settings and the reading
history are lost, unless you exported them first.

## Back up and restore your settings

Settings → **Back up** → **Export settings…** saves everything of yours
that is not a comic in one file, `comicredr-settings-2026-09-26.json`:

- every setting, including the ones changed while reading (fullscreen,
  the night filter, auto-trim, the page grid's size, shuffle);
- your library folders and where the sidecars are kept;
- your `keys.toml`, if you have one;
- for every comic, where you are, your bookmarks, notes and marks, the
  collections and Favourites, your edits to titles and series, and the
  reading history.

**Import settings…** reads such a file back, shows what it holds and
asks before it changes anything. Everything shows at once: the settings,
the keys, the touch zones and the library folders, which are scanned
straight away.

This is how to keep everything when the app's own data is wiped: on the
phone, moving from a build you made yourself to the F-Droid one means
uninstalling, which deletes it. Export first, keep the file somewhere
safe (Downloads, or your comics folder), install the new app, give it
All files access and import.

- On the laptop, a save dialog asks where the file goes. On the phone,
  pick a folder; the file is made there, never over another one.
- Your settings become the file's. Positions, bookmarks, collections,
  edits and history are merged with what is already there, the same way
  two sidecars are: the later position wins, and a bookmark you took off
  stays off. Importing twice is the same as importing once.
- Comics are recognised by their content, so positions and bookmarks
  find a comic even where its path is different. Library folders and the
  sidecar folder are paths: the ones that do not exist on this device
  are left out, and the notice says which.
- A `keys.toml` already there is kept as `keys.toml.bak` when the file's
  is different.
- Not in the file: the comics, their covers, thumbnails and panels (a
  scan and the sidecars bring those back; panels would make the file
  megabytes), a detector model you added (copy that file yourself), and
  the device's name for the sidecars, which stays each device's own.
- A file from another app, or from a newer ComicRedr, is refused with a
  message saying why; settings a newer version added are skipped.

[Contents](README.md) · Previous: [On the phone](10-phone.md) · Next: [Settings](12-settings.md)
