# Changelog

Versions follow [semantic versioning](https://semver.org). The version
lives in `pubspec.yaml`; `make version` prints it, `comicredr --version`
reports it, and the app shows it in the library's status line and in
the `?` overlay.

## Unreleased

- **Panels from a large AI model (optional):** `tool/llm_panels.py` turns a
  comic's pages into pictures for Claude Code, Codex or another agent that
  can look at images, hands it the prompt, draws its answer back on the
  pages for checking, and writes the panels, balloons and captions it found
  into the comic's sidecar. Guided view then uses them on those pages
  instead of the built-in detector's, which stays the default everywhere
  else; `X` → Redo panels goes back to the detector. On 40 test pages the
  detector mostly gets wrong or shows whole, Claude's panels were right on
  31 and the detector's on 8 (guide, "Panels from a large AI model").
  Balloon by balloon now skips captions, which only imported panels have.

## 0.8.0

- **Unread:** comics that turn up in a library folder, never seen before,
  go into a collection called Unread by themselves; opening one takes it
  out. Moved, renamed or copied comics are not new, and the first look
  through a folder (a fresh install, a folder just added) takes what is
  there as already seen. The comics already in the library are seen too.
- **Training the detector:** every `make train-model` run is kept, with
  its checkpoint, data, command and its scores against the shipped model,
  and the same `RUN=` resumes a stopped run. `FROM=shipped` (or a kept
  run) trains on top instead of starting from COCO, and
  `make score-model MODEL=...` compares any model with the built-in one on
  the three test sets, speed and size included, and lists the pages whose
  outcome changed. docs/training.md now opens with which model to train
  and how, how the shipped one was trained, and when a new one is better.

## 0.7.1

- **Fit width by touch:** the reader's status line has a fit width
  button (outside guided view), so a phone without a keyboard can do
  what `zw` does; tapped again it shows the whole page, as `zz` does.
- **One finger scrolls in guided view:** a drag with one finger now moves
  the page around the panel, as it already did on a zoomed page outside
  guided view; two fingers still pinch to zoom. A quick flick still steps
  to the next or previous panel, and taps work as before.

## 0.7.0

- **Sort the Folders tab:** by name, date added, last read, the file's
  date, size, pages, series and issue, or year, each either way round.
  `gS` or the **Sort** button at the end of the filter line opens the
  choice (`Alt` and a letter picks an order, `Alt+R` reverses it), `go`
  steps to the next order and `gO` turns it round. Subfolders follow the
  same order, comics without the value go last, and the order is kept
  across restarts and in exported settings.

- **Fixed:** moving comics (`gm`) never replaces a comic already in the
  folder without asking. Two marked comics of the same file name moved
  into one folder used to leave only the second; now the second stays
  where it was and the notice says it could not be moved.
- **Fixed:** with a comic begun, the library sometimes opened on the
  Series tab instead of Reading, when the comics were read in after the
  library folders.
- **Fixed:** `gA` says so when the library could not be updated, instead
  of doing nothing.

- **Completed comics:** a comic read to the end is marked completed.
  Reading on to the last page does it (a key, a tap or a swipe that
  turns onto it; a jump there with `G`, the page grid, the progress bar
  or a bookmark does not, so a look at the end marks nothing), and `gC`
  does it by hand, or
  takes the mark off: in a comic (also over its page grid and bookmark
  list), on a cover, on all the marked covers (**Completed** in the bar
  over them), and with the tick in a comic's details. In the library the
  notice has an **Undo** (`u`), and says when comics were left out
  because they are only on S3. A completed comic has the green check on
  its cover, which used to show only while a comic was left on its last
  page; now it stays when the comic is read again. The mark is kept in
  the comic's sidecar and in a settings export, so it travels; the later
  change wins when two devices differ, taking the mark off included, and
  **Reset everything** forgets it. Comics left on their last page before
  this count as completed as before, and so does a comic of one page
  once it has been opened; `gC` marks either not completed. A settings
  import counts completed marks by name ("3 edits and 30 completed
  marks").
- **The Folders tab's filter (`F`) knows completed comics:** **Completed
  only**, **Not completed** (what is still to read) or all of them, with
  the type, size and date as before. A filter saved earlier is read as it
  was. A comic that leaves the tab because it was just marked hands the
  selection to the cover next to it.
- **The comic read last opens at start:** ComicRedr starts in the comic
  you were reading, at the page and panel you left, as `C` does. A comic
  or folder you open ComicRedr with wins, and with nothing read yet, or
  the comic gone, the library shows as before. Settings → Library →
  **Open the comic read last when ComicRedr starts** turns it off.
- **Filter the Folders tab by length:** `F` has a **Length** part, by
  page count: under 24 pages, 24 to 64, 64 to 200, or over 200. Like the
  others it is picked with `Tab` and `Space`, shows on the line under the
  search box, and is kept across restarts.

- **A key for every button and dialog:** everything that can be clicked
  can now be done from the keyboard.
  - Buttons that had no key have one: `g,` opens Settings (in a comic
    too), `u` is the **Undo** of the notice along the bottom, on
    whatever screen that notice shows (over a comic opened in the
    meantime as well), `gA` takes the selected library folder out of
    the library (its button now says what it did too, and both offer an
    **Undo** that puts the folder back and scans it), `gD` downloads a
    comic that is only on S3, `g!` lists the comics the last scan could
    not read, and `x` takes the selected comic out of an open
    collection, or the marked ones (with Undo), as it did in the
    Favourites. They are actions like the others: `?` lists them and
    `keys.toml` can change them.
  - A notice with an **Undo** goes by itself after about ten seconds
    (it used to stay until something else took it away), and a new
    notice takes the place of the one that is up at once: before, a
    notice could wait unseen behind one with an Undo. Only a notice
    that something went wrong ("Could not download …", "S3 is out of
    reach", a problem in keys.toml) is not cut short: it stays its few
    seconds, and what comes meanwhile shows after it. Many at once do
    not hold the screen for long: the same one is not repeated, and
    after the first two the rest are counted ("… and 5 more notices").
    Marked downloads with the server off or no library folder say so
    once ("S3 is out of reach: 5 comics can be downloaded when it is
    back"), and refused keys once a try, not once a comic. `u` only ever
    undoes what the notice on screen offers, also with the `?` help up,
    and an undo that fails says so. `x` with marked comics of which none
    is in the open collection says so.
  - A button's tooltip names its key as it is now, also after you
    changed it in `keys.toml` (*Settings (g,)*); before, the keys in
    tooltips were fixed text and some buttons named none.
  - In every dialog `Alt` with the underlined letter presses that button
    (`Alt+C` Cancel, `Alt+D` Delete for good, `Alt+S` Save …). `Alt`, so
    a letter typed into a name stays a letter. The underline is drawn
    in the label's own colour, so it shows on the filled buttons too. On
    a phone the letters are underlined only while `Alt` is held on a
    plugged-in keyboard.
  - Every dialog starts with the focus on a control: Cancel where
    something would be lost (now also before clearing the reading
    history), the main button or the first field elsewhere; Settings
    starts on Close. `Enter` in a field of the S3 settings saves, and in
    the phone's folder questions it is the dialog's button.
  - `Tab` and `Shift+Tab` now reach every control of a dialog, in the
    order they are written. In Settings, which scrolls, `Tab` used to go
    round a handful of controls and never reach the switches, the
    sliders or most buttons.
  - Whatever has the keyboard focus has a ring around it; the tint
    Material draws could hardly be seen on the dark theme. It shows
    while keys are in use, not for touch.
  - In the details of a comic `Alt+P` is Redo panels, from anywhere in
    the list: the same letter as Redo panels in the reset question,
    where `Alt+R` is Reset everything.
  - In Settings `Alt+M` and `Alt+B` are the two cover size buttons
    (smaller, bigger).
  - `Alt` with a key that types nothing (an arrow, `Enter`, `Home`)
    still does what the key does alone; only `Alt` with a letter, a
    digit or a sign is kept for dialogs.
- **Bigger and smaller text in the `?` help:** in the list of keys `+`
  makes all of its text a step bigger, up to three times the usual size,
  `-` makes it smaller again (down to 0.7 of the usual size) and `=` puts
  the usual size back. `Ctrl` and the mouse wheel, a pinch on a touchpad
  and two fingers on a touchscreen do the same. They are the zoom keys,
  so keys of your own from `keys.toml` work, and the first line of the
  help names them. The size is remembered across restarts and goes into
  a settings export. While the help is open the keys change only the
  help, not the comic or the covers behind it; typed into the help's
  search, `+` and `-` are searched for as before, and size the text again
  after `Enter`. With big text in a narrow window each action's keys go
  on a line above what it does, so nothing is cut off. The help's title
  line and the notes under it (the data folder, the `keys.toml` in use)
  now scroll away with the list instead of staying on top: in big
  letters they would have left no room for the keys. The version has a
  line of its own under the list, where it lay over the list's last
  lines; it keeps its usual size whatever the help's. The list stays
  where you were reading when the size changes: what was along its top
  (an action, or the title or a note) is still there, from the first
  frame on. Where the system's
  text is set bigger (a phone's font size), the keys go above what they
  do as soon as the letters as drawn need it, at the usual size too.
- **Bigger and smaller covers in the library:** `+` and `-` now size the
  covers on the Folders tab and every other tab of covers (Reading,
  Series, Books, Collections), a column fewer or more a press, and `=`
  puts the usual size back. `Ctrl` and the mouse wheel and a pinch on a
  touchpad do the same, and on a phone or any touchscreen two fingers
  spread apart or pinched together on the covers. The selected cover
  stays in view, the size is one for all those tabs, it is remembered
  across restarts and goes into a settings export. Typing `+` or `-` in
  the search box still types, and the keys do nothing while no covers
  show (a list tab, a cover's details filling a phone's screen).
  Settings → **Library → Cover size** has the same steps as two buttons
  and **Usual size**, for a phone when pinching is not an option; the
  line says how many covers there are in a row, also when the window
  changes or comics arrive while Settings is open. Covers
  are kept 512 pixels wide, so on a phone or a high-resolution screen
  the biggest sizes are a little soft. At the usual size nothing
  changes: the number of covers in a row at every window width, how
  covers and shuffled pages are drawn and the memory they take. Steps
  that end on the number of covers the usual size shows in the window
  (`+` and then `-`) are the usual size again, with nothing kept. Covers
  made smaller take less memory each. In shuffle a page 512 pixels wide
  is made instead of the 256 pixel one only for a tile that is both
  sized by hand (not at the usual size) and more than 332.8 device
  pixels wide: 332.8 points on a screen of one pixel a point, 166.4 on a
  2x screen, about 111 on a 3x phone. In the page
  grid (`p`), a finger resting on a page during a pinch no longer opens
  that page when it lifts, a third finger joining a pinch no longer
  makes the size jump, and a `+` or `-` typed with two fingers down is no
  longer taken back by the pinch.
- **Fixed:** the page grid's size is now kept exactly, so a wide window
  with many small pages comes back with the same number in a row after a
  restart (it could come back with one fewer). A settings file whose
  page grid or cover size is not a real size (`NaN`, a negative number,
  `Infinity`) is no longer taken: such a value used to stop the page
  grid from showing at all.
- **Collections and favourites from inside a comic:** `gc` now works
  with a comic open, asking which collection to put it in (new or one you
  have) without going back to the library, also for a comic opened from
  outside the library folders. `gc` and `*` work with the page grid (`p`)
  or the bookmark list (`M`) up too, which used to swallow them. The name
  can be typed straight after `gc`, before the question shows, in a comic
  and now on a cover in the library too: every letter lands in it and
  none turns a page or runs as a command (a name starting `gd` used to
  ask to delete the comic). Every collection is offered, in the library
  as in a comic, also one that only holds comics from outside the library
  folders. A name answered after the comic was closed or swapped for
  another adds nothing and says so. A collection a comic is in already
  is left as it is, in the library as in a comic: the notice says
  *Already in X*, and with several comics marked it counts only the ones
  added (*2 comics added to X; 1 was already in it*). The details'
  **Add to a collection** now says what it did, too. Since adding a
  comic to a collection it is in changes nothing, it no longer outvotes a
  removal made on another device in the meantime: when that device's
  sidecar arrives the comic goes out here as well (take it out and add
  it again to keep it). If the library cannot save a collection, the
  notice names the comic, or says how many of the marked ones were
  added, were in it already and were not added, and the marks stay.
- **Back to the first page, in the guide:** `Home` and `gg` have a
  section of their own in Reading a comic: where they land in guided
  view, `''` to come back, the page grid and the bookmark list.
- **Parts of a page by touch:** a two-finger tap opens a small copy of the
  page cut into halves, thirds, strips or quarters; tap a part to enlarge
  it, then tap the edges to go part by part, as the arrow keys do. `gp`
  and a status-line button (on wider screens) open it too.
- **Fixed:** in a comic's details the **Edit** button went to a line of
  its own beside **Continue reading** or **Read again**; it is now a
  pencil next to the star and the tick (`e` as before).
- **Fixed:** a download from S3 that broke off part of the way, or was
  refused, no longer leaves a `NAME.part` file in the library folder,
  neither of the comic nor of its sidecar.
- **Fixed:** with the system's text at twice its size or more on a phone,
  the line along the bottom of the library ran off the screen. It now
  leaves out the version number when there is no room for it (the `?`
  help still shows it).
- **Fixed (tests):** key sequences such as `gd` now time out by the
  test's own clock in the app's widget tests, and the tests that read the
  index wait for what they expect instead of for a fixed while, which
  made them fail or hang on a busy machine. The e2e scripts count
  differing pixels the same way on ImageMagick 6 and 7.

## 0.6.5

- **Page-part digits match how many parts you think in:** `21`/`22`
  halves, `31`-`33` thirds, `41`-`44` strips, `51`-`54` quarters (was
  `11`-`44`). `11` shows the whole page in the current split; `00` leaves
  the split. Letter keys `H1`-`Q4` are unchanged.

## 0.6.4

- Moving a comic to another folder (`gm`) keeps your place and takes its
  sidecar along, so progress, bookmarks and panels stay with it.

## 0.6.3

- Shuffle (`S`) works on every tab of covers, not only Folders: Reading,
  Series, Books and Collections too, a series showing a random page of a
  random comic in it.

## 0.6.2

- The Folders tab shows a comic in every folder that holds a copy of it,
  not only in the first one (`Unread/xman` before `xman`).
- Shuffle (`S` on the Folders tab) shuffles folder tiles too: a random
  page of a random comic in the folder.

## 0.6.1

- Android 7–10 explains the Storage permission dialog and offers **Allow
  access**; Android 11+ keeps **Open settings** for All files access.

## 0.6.0

Move comics to other folders, jump to a page with `G12`, and zoom into
parts of a page with two digits.

- **Move comics to another folder:** `gm`, or Move in the bar over marked
  comics, moves them (or the selected one) to a folder picked from a list
  of the library's folders, typed into to find one; New folder (`Ctrl+N`)
  makes one. Sidecars go along, so place, bookmarks and panels stay. A
  name already taken there asks first: skip or replace.
- **`gc`** puts the selected or marked comics in a collection.
- **`11`-`44` zoom at once, and page numbers go after `G`:** `G12` goes to
  page 12 (Enter or a short pause ends the number; `G` alone is still the
  last page, `End` at once), so the part keys need no wait. `12G` is no
  longer a page jump. Counts before other keys (`3l`, `2>`) stay.
- **Four strips:** `L1`-`L4` enlarge four full-width strips of a page,
  top to bottom, and `→` `←` go on strip by strip like the other parts.
- **Page parts by number:** `11` `12`, `21`-`23`, `31`-`34` (strips) and
  `41`-`44` (quarters), the two digits pressed within half a second, work
  as `H1` `H2`, `B1`-`B3`, `L1`-`L4` and `Q1`-`Q4`. They zoom at once.
- **The whole page before it turns:** reading in parts, the step after
  the last part shows the page whole before the next page comes; back
  from the first part the same.

## 0.5.0

Mark several comics at once, filter the Folders tab, read parts of a
page in turn, and set how smooth scrolling feels.

- **Android releases come as one APK per ABI** (armeabi-v7a, arm64-v8a,
  x86_64), `make apks`, so 32-bit phones and x86_64 devices get the app
  from F-Droid too and each phone downloads only its own libraries.

- **Usage guide in step with the app:** every chapter checked against
  the code and put right where it had drifted, a new section on reading
  manga right to left, and plainer wording throughout.
- **Marking fixes:** Cancel on a single marked comic's delete or reset,
  or on Remove from S3, now keeps the marks. A comic's details shown as
  a page of their own (a narrow window, a tablet held upright) have
  **Mark to act on several** too.
- **Looking past a panel or part:** `↓` `↑` (`j` `k`) in guided view or
  on a part of a page (`H1`, `B2`, `Q3`...), and a drag on a part, show
  what they bring on screen bright instead of leaving it dimmed. The next
  step frames the next panel or part, dimmed around as before.
- **Smooth scrolling speed:** `g+` and `g-`, or the slider in Settings
  under Pages, pick one of five speeds from Slowest to Fastest: how far
  an arrow key moves a zoomed page. Kept across restarts and in the
  settings backup.
- **Smoother scrolling, and its smoothness:** the arrow-key glide now
  eases in as well as out, a little softer than before by default. `g>`
  and `g<`, or a second slider in Settings, pick one of five steps from
  Crisp to Smoothest, apart from the speed.

- **Several comics at once:** in the library, `Shift` and the arrow keys
  mark a run of comics (`Shift+Home`/`Shift+End` to the first or last),
  `Ctrl+A` every comic shown, `Shift`+click up to a cover, alongside `V`
  and `Ctrl`+click. With comics marked, `gd` deletes, `X` resets and `*`
  favourites all of them, asking once; the bar over the covers adds
  Collection, Upload to S3, Download and Remove from S3. The phone's
  Select button is there without S3 too; wider screens have Mark in a
  comic's details.

- **Parts of a page, page by page:** after `H1`, `B1` or `Q1` the arrow
  keys (and `l` `h`, Space, taps) read the comic in that split: each page
  whole first, then its parts, then the next page. Started from guided
  view, a page with panels goes back to guided view.

- **Filter the Folders tab** by type, size and modification date: `F`,
  or the Filter line under the header. Pick one or more types (only the
  ones your library has), a size range and a date range; they combine
  with each other and with the search, and folders with nothing that
  passes are hidden. The line shows what is filtered, each part with an
  x, and Clear filter. The filter is kept across restarts and goes into
  settings files.

- **S3 sync**: uploading a comic that is in the bucket already (the same
  content and size, from either device) no longer sends it again or
  overwrites a newer sidecar there: the newest sidecar wins, pulled or
  pushed. `gu` on a synced comic, or **Sync with S3** on its page, syncs
  it by hand. In the reader the status line shows the open comic's
  upload, `S3 ↑ 42%`.

- **S3 sync** keeps comics under `Comics/` in the bucket by default,
  instead of `comicredr/`. A folder you already saved in Settings → S3
  sync stays as it is.

- **Building on Linux** now checks for the GTK and libsecret development
  packages first and names the one to install, instead of failing in
  CMake. Builds since 0.4.0 need `libsecret-devel` (Debian:
  `libsecret-1-dev`).

- **The time a quick press holds on a page shown whole** in guided view
  is 2 seconds again (5 since 0.4.0) and can be changed in Settings →
  Guided view: 1, 2, 3, 5 or 10 seconds. It goes in a settings export.

## 0.4.0

S3 sync between your devices, tablets, and continue reading.

- **S3 sync:** upload comics to a bucket on your own S3 server (Garage,
  MinIO) and carry on reading on the other device. Settings → S3 sync
  sets it up, with a Test connection that says which step failed; the
  secret key is kept in the system keyring (a private file when there is
  none) and never in a settings file. `gu` uploads the selected comic,
  or several marked with `V` (Ctrl+click, Select on a phone); a cloud on
  the cover says it is on S3. The other device lists them with their
  covers and downloads one by hand. Sidecars go both ways, the newest
  whole file winning, so the place you stopped at is offered on the
  other device. A switched-off server costs one notice; changes wait and
  go up when it is back. `gU` takes a comic off S3, and deleting one asks
  whether to delete it from S3 too. Android now asks for network access,
  used only for the bucket you set up.
- **Android tablets:** ComicRedr now makes good use of a tablet. The
  reader's status line has a button for two pages side by side (`d`),
  which fills a tablet held sideways; on a small tablet or in split
  screen the page counter comes first and is no longer cut off, and the
  library's search box is no longer squeezed. More decoded pages are
  kept in memory on a tablet's bigger screen, so page turns stay quick.
  The guide and install docs cover tablets.
- **Continue reading (`C`):** opens the comic read last on the page it
  was left at, even after a restart, guided view and panel included; in
  a comic, the one read before it. The library's header has the same as
  a play button for touch. A comic moved in the library is found by its
  content; a deleted one gets a notice.
- **Smooth scrolling:** on a zoomed page the arrow keys and `j` `k`
  glide instead of jumping, and a held key keeps the page sliding
  evenly. `←` `→` now move across a zoomed page and turn the page only
  from its edge (a held key stops there). Key pans stop at the page's
  edge rather than in the dark margin. Reduced motion keeps the jumps.
- **Pages shown whole in guided view** turn the background wine red as
  soon as they show, not on the first press. A press within 5 seconds of
  arriving stays and zooms the page out and back; the next one turns. A
  press after 5 seconds turns straight away. `gw` and the Colour/Zoom
  choice in Settings are gone: both cues are used now, and `W` still
  turns it all off.

## 0.3.0

Back up and restore your settings.

- **Export and import settings:** Settings → Back up saves every
  setting, the library folders, `keys.toml`, and each comic's position,
  bookmarks, collections, edits and reading history in one JSON file,
  and imports it again, so a reinstall (from a debug build to the
  F-Droid one, which wipes the app's data) loses nothing. The import
  checks the file is ComicRedr's, merges per comic the way sidecars do,
  and shows at once. See the guide's "Back up and restore your
  settings".

## 0.2.2

Panels on demand, and touch on Linux.

- **Panels only for the comic you read:** ComicRedr no longer works
  through the whole library in the background. It finds the panels of
  the open comic, from the page you are on to the end, with guided view
  on or off, and stops when the comic is closed. The library's
  "Finding panels" line, its pause button and the setting are gone. The
  same on Linux and Android.
- **Touch on Linux:** the status line starts with a back arrow, so a
  Linux touchscreen can leave guided view and the comic the way the
  phone's back gesture does. Every other gesture already worked there;
  `tool/e2e_touch_linux.sh` now checks all of them by touch alone.

## 0.2.1

Android fixes.

- **Open a comic (`o`) opens the file where it is:** the system picker
  now hands back the file's real path instead of a copy in the app's
  cache, so big PDFs no longer run it out of memory, and the position,
  sidecar and Delete apply to the real comic. Open a folder (`O`) works
  for SD cards too.
- **Android 7 to 10:** the app asks for storage access, so the library
  is no longer empty there.
- **System bars:** the reader's status line and progress bar stay clear
  of the navigation bar (Android 15 and after leaving fullscreen), and
  back leaves fullscreen first.
- **Phone layout:** the status text gets its own line above the buttons,
  Settings labels and the Collections tab ("Groups") no longer break
  mid-word, and a hardware keyboard no longer draws a green frame round
  the app.
- **Smaller APK:** only the ABIs built for are packed (the arm64 APK is
  about 10 MB smaller), so a 32-bit phone is no longer offered one that
  crashes.

## 0.2.0

- **The panel detector is built in and open:** a new D-FINE-S model,
  trained only on public-domain and CC BY comics, now ships in the
  repository and in every build, under Apache 2.0 like the rest of
  ComicRedr (LICENSE, NOTICE). No more `make model` step. It learned from
  998 labelled pages, including 37 books with slanted, curved,
  wedge-shaped and irregular frames and 7 modern indie books, plus 400
  synthetic modern pages laid out from their art, and nothing
  in it comes from Manga109 or Ultralytics.
  Narration captions are their own class, so balloon mode stops only on
  speech and thought balloons. Panels are detected again on first open.
  `make install` and `make install-apk` move a model installed earlier
  with `make install-model` or `make push-model` aside (`.onnx.old`), so
  the built-in one is used without any other step.

- **Turn the comic (`>`, `<`, `gr`):** a quarter turn clockwise or
  counter-clockwise, with a count for more (`2>` turns it upside down),
  and `gr` back upright. Guided view frames its panels on the turned page,
  zoom, `j` `k`, fit width and `H1`-`Q4` follow the screen, and the turn
  is kept for that comic with its position, in the sidecar too.

- **Everything in ~/Comics:** on Linux, when `~/Comics` exists and the app
  has no database in `~/.local/share` yet, it keeps its database, covers,
  thumbnails, `keys.toml` and installed models in `~/Comics/.comicredr/`,
  so all of it lives in one folder with the comics. Existing installs stay
  where they are; Android is unchanged. `?` names the folder.

- **The time at a glance (`T`, or a long press in the middle of the
  page):** the current time, large and centred on a dim backing, for two
  seconds, then it fades away; in the library, the reader and fullscreen.
  It follows the system's 12 or 24 hour setting and takes no taps.

- **Hidden sidecars:** a comic's sidecar is now `.book.cbz.crdb`, a
  hidden file, beside the comic and in the one sidecar folder alike (a
  folder book's `.comicredr.crdb` already was). A sidecar under the old
  visible name is renamed the next time the comic is opened or scanned,
  keeping its panels, bookmarks and positions; when both names exist the
  two are merged.

- **Zoom the page grid:** in the `p` grid, `+` and `-` (or Ctrl and the
  scroll wheel, a pinch, or the header's buttons) go from many small
  thumbnails to one page a row, keeping the selected page in view. Bigger
  tiles get sharper thumbnails (512 or 1024 px, made when first needed),
  and the size is remembered.

- **Comic details (`I`, the info button on the status line, or Details
  in the library):** the file (format as its bytes say, size, content key,
  sidecar), the pages (pixel sizes, wide spreads, what they are stored as,
  JPEG quality estimated from the quantisation tables, how sharp they are
  on this screen; for a PDF its page size and the scanned images inside,
  read from the file), metadata with hand edits marked, progress and time
  read, and detection: the detector, pages analysed, panels, balloons and
  captions found, why pages are shown whole, confidence and time, and
  every page on its own line. A page picked in the list is gone to, and
  Redo panels finds the comic's panels again. Only page headers are read.

- **Rebuilding the detector:** `make train-model` rebuilds the model from
  the free training comics on the CPU and checks the file before the
  build packs it.

- **Bookmarks you can use:** `mm` (or the bookmark button) now takes a
  bookmark off again when the page, or in guided view the panel, already
  has one, instead of adding another. A ribbon at the top right of the
  page and amber notches on the progress bar show where bookmarks are.
  `M` (or the list button) lists the book's bookmarks and marks with a
  picture of each page: Enter or a tap jumps, `e` writes a short note,
  `x` or Delete removes one. `}` and `{` jump to the next and previous
  bookmark. The library has a Bookmarks tab across every book (`M` there
  too), searchable by note; a book's details show and edit the notes.
  Notes travel in the sidecar: a note replaces the bookmark with a new
  one and marks the old one removed, so the merge needs no edit times.

- **One-page image comics:** a PNG, JPEG or WebP file opens as a comic of
  one page, from the command line, Open With or the open dialog, with
  guided view, balloons and its own sidecar. In the library, an image
  beside comic files is a one-pager of its own; a folder holding only page
  images (and folders of them) is still one folder book. The Linux
  launcher lists the image types under Open With, and the install keeps
  the image viewer you had as the default.

- **Page thumbnails:** `p` (or the grid button on the status line) opens
  a grid of the book's pages, the current one outlined and bookmarked or
  marked pages flagged; arrows, `hjkl`, `G` with a count, a click or a tap
  pick a page, and `''` goes back. Dragging along the progress bar, or
  hovering over it with the mouse, shows a small picture of the page under
  the pointer before you let go. Thumbnails are made only for the pages
  shown, off the UI thread, and kept on disk beside the covers.

- **Clean-up for old scans (`c`, or Settings → Pages):** yellowed paper
  turns white and faded ink dark again, with levels measured on each
  page's own paper colour, so the inks lose the yellow cast too. Zoomed in,
  or in guided view, a scan with fewer pixels than the screen shows is
  enlarged, at most twice over, and sharpened, in the background, and
  cached. Pages without paper, like painted art,
  only get a gentle contrast stretch. Panel detection still sees the page
  as scanned. Off by default, and kept once turned on.

- **Detector built in:** the trained panel and balloon model is packed
  into the Linux build and the APK, so guided view uses it without
  `make install-model` or `make push-model`. The build takes it from
  `assets/models/` (`make model MODEL=...` puts it there); a model
  installed the old way still wins, for trying another one.

- **Wide scanned margins:** guided view no longer shows a page whole just
  because it was scanned with a wide blank margin. The trained detector
  looks at such a page with the margin cut off, whether or not `t` is on;
  with a 12% margin added to the labelled test pages, 68 of 100 are guided
  right instead of 28. Books are detected again once.

- **Panels for the whole library:** after each library scan, the panels of
  every book are found in the background, so guided view is ready in any
  book as soon as it is opened. Progress shows on the library's status
  line, with a pause button; the pass skips what is done, goes on where it
  stopped after a restart, waits while the reader is busy, and can be
  switched off in Settings. Off by default on Android.

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
