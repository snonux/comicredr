# 11. Your data

[Contents](README.md) · Previous: [On a phone or tablet](10-phone.md) · Next: [Settings](12-settings.md)

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
bookmarks, panels, edits and collections. Only the settings and the
reading history are lost.

[Contents](README.md) · Previous: [On a phone or tablet](10-phone.md) · Next: [Settings](12-settings.md)
