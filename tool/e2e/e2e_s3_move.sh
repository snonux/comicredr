#!/usr/bin/env bash
# End-to-end check that S3 sync follows a comic moved after it went up,
# with two Linux installs under Xvfb sharing one bucket through a local
# Garage (tool/garage_local.sh):
#
#  - the laptop opens Golden Age/Weird Comics 4.cbz and presses gu in the
#    reader: the bucket's manifest names Golden Age;
#  - with the app closed the comic is moved and renamed in the shell to
#    Read/Weird 4.cbz (its hidden sidecar left behind, as a file manager
#    showing no hidden files would). At the next start the manifest names
#    Read/Weird 4.cbz, the comic is not sent again, nothing waits;
#  - in the library, gm moves it on to Done: the manifest follows at once;
#  - a second install (the desk) lists the shelf: the comic is in Done,
#    and gD downloads it into its Done folder, at the laptop's page;
#  - the laptop starts again and leaves the bucket as it is.
#
#   tool/garage_local.sh start; tool/e2e/e2e_s3_move.sh
#
# E2E_SKIP_BUILD=1 reuses the release build in build/. Needs: Xvfb,
# xdotool, ImageMagick, sqlite3, curl, Python 3, a C compiler, X11 headers.
# Output: build/e2e-s3-move/*.png and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/../.."

eval "$(tool/garage_local.sh env)"
if ! curl -s -o /dev/null "$GARAGE_TEST_ENDPOINT"; then
  echo "SKIP no Garage at $GARAGE_TEST_ENDPOINT: tool/garage_local.sh start"
  exit 0
fi
prefix="comicredr-e2e-move-$(date +%s)"

top=$PWD
out=build/e2e-s3-move
rm -rf "$out" && mkdir -p "$out/pages" "$out/laptop/Comics/Golden Age" "$out/laptop/Comics/Read" \
  "$out/laptop/Comics/Done" "$out/desk/Comics"
for ((i = 1; i <= 6; i++)); do
  convert -size 800x1200 xc:ivory -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,1160' -fill black -stroke none -pointsize 90 \
    -annotate +90+300 'Weird Comics' -pointsize 260 -annotate +250+800 "$i" -quality 85 \
    "$out/pages/p$(printf %02d "$i").jpg"
done
python3 - "$out/pages" "$out/laptop/Comics/Golden Age/Weird Comics 4.cbz" <<'EOF'
import sys, zipfile, pathlib
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for f in sorted(pathlib.Path(sys.argv[1]).glob('*.jpg')):
        z.write(f, 'page' + f.name[1:])
EOF

failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "PASS $1: $2"; else echo "FAIL $1: $2, expected $3"; failed=1; fi
}
s3curl() {
  curl -sS -f --aws-sigv4 "aws:amz:${GARAGE_TEST_REGION:-garage}:s3" \
    --user "$GARAGE_TEST_ACCESS_KEY_ID:$GARAGE_TEST_SECRET_ACCESS_KEY" "$@"
}
fetch() { s3curl -o "$2" "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET/$1"; }
head_of() { s3curl -I "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET/$1" | tr -d '\r'; }
etag() { head_of "$1" | sed -n 's/^etag: *//Ip'; }
modified() { head_of "$1" | sed -n 's/^last-modified: *//Ip'; }
# Where the bucket's manifest puts the comic, folder/file name.
place() {
  fetch "$o/manifest.json" "$out/manifest.json" 2>/dev/null || { echo none; return; }
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print((m["folder"] + "/" if m["folder"] else "") + m["file_name"])' \
    "$out/manifest.json"
}
wait_for() { # wait_for seconds command...
  local until=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS < until)) || return 1
    sleep 1
  done
}

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
cc -o "$out/close_window" tool/e2e/close_window.c -lX11
export DISPLAY=:93
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
# A bus address that is not there, not an unset one: unset, D-Bus falls
# back to $XDG_RUNTIME_DIR/bus, a desktop's real session bus, and the test
# secret would be saved over the real one in the keyring of whoever runs this.
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/comicredr-no-session-bus
for _ in $(seq 1 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "FAIL  Xvfb did not come up on $DISPLAY"; exit 1; }

home= comics=
db() { echo "$home/.local/share/org.snonux.comicredr/comicredr.sqlite"; }
sql() { sqlite3 -batch -noheader -cmd ".timeout 10000" "$(db)" "$1"; }
use() { home="$top/$out/$1/home"; comics="$top/$out/$1/Comics"; mkdir -p "$home"; }
start() {
  # No XDG folders of whoever runs this, so the app reads and writes only
  # under the home given; GDK_BACKEND keeps a Wayland desktop out of it.
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    HOME="$home" GDK_BACKEND=x11 "$top/build/linux/x64/release/bundle/comicredr" --add-root "$comics" "$@" \
    >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 8
  win=$(xdotool search --name '^ComicRedr$' | tail -1)
  xdotool mousemove 640 400; sleep 0.5
}
stop() {
  "$out/close_window" "$win"
  for _ in $(seq 1 40); do kill -0 "$app" 2>/dev/null || { app=; return 0; }; sleep 0.25; done
  kill "$app"; wait "$app" 2>/dev/null || true; app=
}
shot() { import -window root "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
setting() { sql "insert or replace into settings values ('$1', '\"$2\"')"; }
set_up() { # scan once, then the bucket's settings
  start
  wait_for 60 test "$(sql 'select count(*) from roots' 2>/dev/null)" = 1 || true
  stop
  setting s3.endpoint "$GARAGE_TEST_ENDPOINT"
  setting s3.region "${GARAGE_TEST_REGION:-garage}"
  setting s3.bucket "$GARAGE_TEST_BUCKET"
  setting s3.prefix "$prefix/"
  setting s3.accessKey "$GARAGE_TEST_ACCESS_KEY_ID"
  mkdir -p "$home/.config/comicredr"
  (umask 077 && printf %s "$GARAGE_TEST_SECRET_ACCESS_KEY" >"$home/.config/comicredr/s3-secret")
}

# --- The laptop: open the comic, read to page 3, gu in the reader.
use laptop
set_up
key_=$(sql "select content_key from files")
o="$prefix/books/$key_"
start "$comics/Golden Age/Weird Comics 4.cbz"
key Right; key Right
wait_for 10 test "$(sql "select page from progress where content_key = '$key_'")" = 2 || true
key g u
wait_for 60 test "$(sql "select count(*) from s3_books where pending is null")" = 1 || true
shot 01_uploaded
check "laptop: uploaded from Golden Age" "$(place)" "Golden Age/Weird Comics 4.cbz"
check "laptop: its place noted" "$(sql "select place from s3_books")" "Golden Age/Weird Comics 4.cbz"
stop
comic_tag=$(etag "$o/comic.cbz")
comic_at=$(modified "$o/comic.cbz")

# --- Moved and renamed in the shell while the app is closed.
mv "$comics/Golden Age/Weird Comics 4.cbz" "$comics/Read/Weird 4.cbz"
sleep 1.1
start
wait_for 60 test "$(place)" = "Read/Weird 4.cbz" || true
shot 02_after_shell_move
check "shell move: the manifest follows" "$(place)" "Read/Weird 4.cbz"
check "shell move: the index has it in Read" "$(sql "select rel_path from files")" "Read/Weird 4.cbz"
check "shell move: nothing waits" "$(sql "select count(*) from s3_books where pending is not null")" 0
check "shell move: the comic was not sent again" "$(etag "$o/comic.cbz") $(modified "$o/comic.cbz")" \
  "$comic_tag $comic_at"

# --- gm in the library: the Folders tab, into Comics, into Read (empty
# folders are not shown, so it is the only one), then the move picker with
# "done" typed.
key Tab; key f; key Return
key l; key Return; key Return; sleep 1
shot 03_in_read
key g m; sleep 2
xdotool type --delay 80 done; sleep 1
shot 04_move_picker
key Return
wait_for 30 test "$(place)" = "Done/Weird 4.cbz" || true
shot 05_after_gm
check "gm: the comic is in Done" "$(test -f "$comics/Done/Weird 4.cbz" && echo yes)" yes
check "gm: the manifest follows" "$(place)" "Done/Weird 4.cbz"
check "gm: the uploader is still named" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uploaded_by"])' "$out/manifest.json")" \
  "$(sql "select json_extract(value, '$') from settings where key = 'device.name'")"
check "gm: the comic was not sent again" "$(etag "$o/comic.cbz") $(modified "$o/comic.cbz")" "$comic_tag $comic_at"
stop
manifest_at=$(modified "$o/manifest.json")

# --- The desk: lists the shelf, the comic in Done; gD downloads it there.
use desk
set_up
setting device.name desk
start
wait_for 30 test "$(sql "select count(*) from s3_books" 2>/dev/null)" = 1 || true
check "desk: the shelf names Done" \
  "$(sql "select json_extract(manifest, '$.folder') || '/' || json_extract(manifest, '$.file_name') from s3_books")" \
  "Done/Weird 4.cbz"
# The Books tab (Tab, B, Enter in the sidebar), its first cover.
key Tab; key b; key Return; key Home
shot 06_desk_books
key g D
wait_for 30 test -f "$comics/Done/Weird 4.cbz" || true
sleep 2
shot 07_desk_downloaded
check "desk: downloaded into Done" "$(test -f "$comics/Done/Weird 4.cbz" && echo yes)" yes
check "desk: the same comic" "$(sql "select content_key from files")" "$key_"
check "desk: at the laptop's page" "$(sql "select page from progress where content_key = '$key_'")" 2
check "desk: its place noted" "$(sql "select place from s3_books")" "Done/Weird 4.cbz"
stop

# --- The laptop again: nothing moved there, the bucket stays as it is.
use laptop
start
sleep 5
stop
check "laptop restart: the manifest untouched" "$(modified "$o/manifest.json")" "$manifest_at"

[[ $failed == 0 ]] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
