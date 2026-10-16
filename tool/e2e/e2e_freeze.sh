#!/usr/bin/env bash
# End-to-end check that reading stays smooth over a big library, on the
# Linux release build under Openbox in Xvfb. A library of thousands of
# comics is scanned once; then a comic is read with the library left on its
# Folders tab: pages turned, guided view, the next comics with ], back to
# the library and its covers walked with the arrows. The app runs with
# COMICREDR_STALLS=1, which logs each time the UI isolate was held up
# (StallWatch, lib/src/stall_watch.dart); the run fails on any hold-up of
# 400 ms or more, or a frame of 500 ms or more, after the scan. Before the
# fix each page turn re-sorted the hidden library: 36 freezes, 34 s in
# all, in a minute of reading over 3,000 comics.
#
#   tool/e2e/e2e_freeze.sh [count]     # count: comics in the library, 3000 by default
#
# Makes its own comics (small pages, so the scan takes a few minutes).
# The keyring half of the fix (S3 secret read once a run) needs a GNOME
# keyring, which Xvfb has not; test/secret_store_test.dart covers it.
#
# Needs: Xvfb, openbox, xdotool, ImageMagick, sqlite3, a C compiler and X11
# headers (tool/e2e/close_window.c), Python with Pillow.
# Output: build/e2e-freeze/*.png and build/e2e-freeze/app.log.
set -euo pipefail
cd "$(dirname "$0")/../.."

count=${1:-3000}
out=build/e2e-freeze
rm -rf "$out" && mkdir -p "$out/home/Comics"
[[ -x build/linux/x64/release/bundle/comicredr ]] || flutter build linux --release
cc -o "$out/close_window" tool/e2e/close_window.c -lX11

comics="$PWD/$out/home/Comics"
# Each comic its own content (a text entry first) over the same twelve
# pages of panels, in 25 series folders.
python3 - "$comics" "$count" <<'EOF2'
import io, os, random, sys, zipfile
from PIL import Image, ImageDraw
out, n = sys.argv[1], int(sys.argv[2])
random.seed(1)
pages = []
for i in range(12):
    im = Image.new('RGB', (600, 900), 'white')
    d = ImageDraw.Draw(im)
    for r in range(3):
        for c in range(2):
            x, y = 15 + c * 285, 15 + r * 290
            d.rectangle([x, y, x + 270, y + 275], outline='black', width=4,
                        fill=tuple(random.randrange(120, 250) for _ in range(3)))
    b = io.BytesIO()
    im.save(b, 'JPEG', quality=80)
    pages.append(b.getvalue())
for k in range(n):
    sub = os.path.join(out, f'Series {k % 25:02d}')
    os.makedirs(sub, exist_ok=True)
    with zipfile.ZipFile(os.path.join(sub, f'Issue {k:04d}.cbz'), 'w', zipfile.ZIP_STORED) as z:
        z.writestr('000.txt', f'comic {k}')
        for i, data in enumerate(pages):
            z.writestr(f'{i + 1:02d}.jpg', data)
EOF2
db="$comics/.comicredr/comicredr.sqlite"
first="$comics/Series 00/Issue 0000.cbz"

export DISPLAY=:93
Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
xvfb=$!
wm=
app=
trap 'kill $app $wm $xvfb 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
openbox >/dev/null 2>&1 &
wm=$!
sleep 1

failed=0
fail() { echo "  FAIL: $*"; failed=1; }
ok() { echo "  ok: $*"; }
k() { xdotool key --delay 40 "$@"; }
shot() { import -window root "$out/$1.png"; }

start() {
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME GDK_BACKEND=x11 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent COMICREDR_STALLS=1 HOME="$PWD/$out/home" \
    build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
  app=$!
  win=
  for _ in $(seq 1 150); do
    win=$(xdotool search --name ComicRedr 2>/dev/null | tail -1 || true)
    [[ -n $win ]] && break
    sleep 0.2
  done
  [[ -n $win ]] || { echo 'FAIL ComicRedr window did not appear'; exit 1; }
  xdotool windowactivate --sync "$win" 2>/dev/null || true
  sleep 2
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 120); do kill -0 "$app" 2>/dev/null || break; sleep 0.25; done
  kill "$app" 2>/dev/null || true
  wait "$app" 2>/dev/null || true
  app=
}
books() { sqlite3 "$db" 'select count(*) from books' 2>/dev/null || echo 0; }

echo "== scanning $count comics"
start --add-root "$comics"
for _ in $(seq 1 1800); do
  [[ $(books) -ge $count ]] && break
  sleep 1
done
[[ $(books) -ge $count ]] && ok "all $count comics in the index" || fail "only $(books) of $count comics scanned"
# This script reads the index with sqlite3 while the app writes it, as a
# second ComicRedr would: the app waits for the lock (busy_timeout).
if grep -q 'database is locked' "$out/app.log"; then
  fail "the app's writes failed with database is locked"
else
  ok "no write refused while sqlite3 read the index"
fi
sleep 3
stop

echo "== reading with the library on its Folders tab"
start "$first"
for _ in $(seq 1 3); do k l; sleep 0.3; done
k Escape
sleep 3
k Tab f
sleep 1
k Return
sleep 2
shot 01_folders
k C
sleep 3
shot 02_reading
reading_from=$(date +%s)
for i in $(seq 1 60); do
  k l
  sleep 0.15
  if ((i % 10 == 0)); then
    k bracketright
    sleep 0.5
  fi
done
k v
for _ in $(seq 1 40); do
  k l
  sleep 0.15
done
k v
shot 03_read_on
# The first Esc may only end a held whole page or guided view's step.
k Escape
sleep 1
k Escape
sleep 2
for _ in $(seq 1 20); do k Right; done
sleep 2
shot 04_library_again
stop

# Anything the UI isolate was held up 400 ms or more for after the scan,
# or a frame of half a second, is a freeze.
python3 - "$out/app.log" "$reading_from" >"$out/stalls.txt" <<'EOF2'
import re, sys, datetime
since = int(sys.argv[2])
for line in open(sys.argv[1], errors='replace'):
    m = re.match(r'\[stall (\S+)\] (.*?(\d+) ms.*)', line)
    if not m:
        continue
    t = datetime.datetime.fromisoformat(m.group(1)).timestamp()
    # Coming back to the library builds it once, a quarter second on
    # Xvfb's software drawing; a freeze is longer than that.
    worst = max(int(v) for v in re.findall(r'(\d+) ms', m.group(2)))
    if t >= since and (worst >= 500 or 'blocked' in m.group(2)):
        print(m.group(2))
EOF2
blocks=$(grep -c 'blocked\|Slow frame' "$out/stalls.txt" || true)
if [[ $blocks -eq 0 ]]; then
  ok "no hold-up of 400 ms or more while reading and back in the library"
else
  fail "$blocks hold-ups while reading:"
  head -20 "$out/stalls.txt"
fi
pages=$(sqlite3 "$db" "select count(*) from progress where page > 0")
[[ $pages -ge 3 ]] && ok "the reading reached $pages comics past their first page" || fail "only $pages comics read on: the keys did not reach the reader"

if command -v montage >/dev/null; then
  montage "$out"/0*.png -tile 2x -geometry 640x400+4+4 "$out/contact.png"
fi
[[ $failed -eq 0 ]] && echo PASS || { echo FAILED; exit 1; }
