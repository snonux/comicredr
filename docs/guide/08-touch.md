# 8. Touch

[Contents](README.md) · Previous: [Managing your comics](07-managing-comics.md) · Next: [The keyboard](09-keyboard.md)

Everything in ComicRedr works by touch, on a phone, a tablet and a Linux
laptop's touchscreen alike: every gesture below, the tap zones and your
own gestures are the same on all of them.

## Gestures

| Gesture | What it does |
|---|---|
| Tap the right edge | Next page, or next panel in guided view |
| Tap the left edge | Back |
| Tap the middle | Fullscreen on and off (and with it the status line) |
| Swipe left or right | Next or back |
| Double-tap the middle column | Zoom in on that spot, or back out (in guided view, on a panel: centre it again) |
| Pinch | Zoom |
| Drag | Move around a zoomed page |
| Hold a finger on the middle | [The time](04-reading.md#what-time-is-it) |
| Tap with two fingers | [Enlarge a part of the page](04-reading.md#by-touch): pick a half, third, strip or quarter, then tap the edges to go part by part |
| Drag along the progress bar | Preview pages, and let go to jump |
| Pinch the page grid | Bigger or smaller pages; drag to scroll, tap one to go there |
| Pinch the covers in the library | [Bigger or smaller covers](03-library.md#bigger-and-smaller-covers) |

The buttons on the status line do the rest: guided view, balloons (in
guided view), the page grid, a bookmark here, the list of bookmarks and
fullscreen; on a wider screen also the comic's details, two pages side
by side and the parts of a page. On Android, the back gesture works
like `Esc`: it leaves guided view, then the book. On Linux the status
line starts with a back arrow that does the same. In fullscreen, tap the
middle first to bring the status line back.

In the library, on a wide screen, tap a cover to pick it and tap it
again to open it. On a narrower one (a phone, a tablet held upright, a
small window) the first tap shows its details on a page of their own,
with a **Read** button. A
long press shows a cover's details, a finger scrolls the covers, and two
fingers spread apart or pinched together make them
[bigger or smaller](03-library.md#bigger-and-smaller-covers); Settings
has two buttons that do the same.

## The tap zones

The page is split into nine zones: three columns (the side ones each 30%
of the width) and three rows. Press `gt` while reading to see what each
zone does; it fades after a moment.

![gt shows the tap zones](images/touch-zones.webp)

Settings → **Touch** has three layouts:

| Layout | For |
|---|---|
| **Standard** | Tap the left edge to go back, the right edge to go on, the middle for the status line. |
| **Left-handed** | Mirrored for the left thumb: the left edge goes on, the right edge goes back. |
| **One thumb** | Tap almost anywhere to go on; only the top row goes back. |

| | |
|---|---|
| ![The touch layouts in Settings on the laptop](images/settings-touch.webp) | <img src="images/android-settings-touch.webp" width="260" alt="The touch layouts in Settings on an Android phone"> |
| Settings on the laptop | and on the phone |

The first comic you open after picking a layout shows its zones for a
few seconds.

## Your own gestures

Any tap, double-tap or long press in any of the nine zones, the four
swipes and a two-finger tap can do any action ComicRedr has. You set them
in the `[touch]` section of `keys.toml`; [chapter 9](09-keyboard.md#your-own-keys)
shows how. For example, to make a long press in the top right corner set a
bookmark:

```toml
[touch]
longPress = [
  "", "", "bookmark",
  "", "showTime", "",
  "", "", "",
]
```

Each action is called by its name in [docs/keys.toml](../keys.toml)
(`nextStep`, `bookmark`, `fullscreen`, …), and `""` does nothing. A line
replaces that whole gesture, which is why the example keeps the time in
the middle. The gestures you don't list keep what the layout picked in
Settings gives them. Pinch zoom and
dragging a zoomed page always work and can't be changed.

[Contents](README.md) · Previous: [Managing your comics](07-managing-comics.md) · Next: [The keyboard](09-keyboard.md)
