#!/usr/bin/env bash
# End-to-end check of uploading from the reader and of a comic that is on
# S3 already (design plan section 13), with two Linux installs under Xvfb
# sharing one bucket through a local Garage (tool/garage_local.sh):
#
#  - the laptop reads a comic to page 3 and presses gu in the reader: the
#    status line shows the upload's share while it goes up, through a
#    proxy that slows the bucket down so it can be seen (02_uploading*.png);
#    the comic, cover, sidecar and manifest land in the bucket;
#  - a second install holds the same comic under another file name, never
#    read there. It lists the shelf, and gu on its cover sends nothing (the
#    bucket's comic and manifest are untouched, still naming the laptop)
#    but takes the laptop's newer sidecar: its index is at page 3;
#  - it reads on to page 5 and presses gu in the reader again: its sidecar
#    is now the newer one and goes up.
#
#   tool/garage_local.sh start; tool/e2e_s3_reader.sh
#
# E2E_SKIP_BUILD=1 reuses the release build in build/. Needs: Xvfb,
# xdotool, ImageMagick, sqlite3, curl, Python 3.
# Output: build/e2e-s3-reader/*.png and a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."

eval "$(tool/garage_local.sh env)"
if ! curl -s -o /dev/null "$GARAGE_TEST_ENDPOINT"; then
  echo "SKIP no Garage at $GARAGE_TEST_ENDPOINT: tool/garage_local.sh start"
  exit 0
fi
prefix="comicredr-e2e-$(date +%s)"

top=$PWD
out=build/e2e-s3-reader
rm -rf "$out" && mkdir -p "$out/pages" "$out/laptop/Comics" "$out/desk/Comics"

# Eight pages to read and eight of noise, about 40 MB, so the upload lasts.
for ((i = 1; i <= 8; i++)); do
  convert -size 800x1200 xc:ivory -fill none -stroke black -strokewidth 8 \
    -draw 'rectangle 40,40 760,1160' -fill black -stroke none -pointsize 90 \
    -annotate +90+300 'Slow Boat' -pointsize 260 -annotate +250+800 "$i" -quality 85 "$out/pages/p$(printf %02d "$i").jpg"
done
for ((i = 9; i <= 16; i++)); do
  convert -size 1800x2700 xc:gray +noise Random -quality 95 "$out/pages/p$(printf %02d "$i").jpg"
done
python3 - "$out/pages" "$out/laptop/Comics/Slow Boat 1.cbz" <<'EOF'
import sys, zipfile, pathlib
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for f in sorted(pathlib.Path(sys.argv[1]).glob('*.jpg')):
        z.write(f, 'page' + f.name[1:])
EOF
cp "$out/laptop/Comics/Slow Boat 1.cbz" "$out/desk/Comics/copied under another name.cbz"
size=$(stat -c %s "$out/laptop/Comics/Slow Boat 1.cbz")
echo "comic: $size bytes"

# A proxy in front of Garage at about 3 MB/s, some ten seconds an upload. Requests are signed for the
# address the app talks to, and the proxy passes them on unchanged.
garage_port=${GARAGE_TEST_ENDPOINT##*:}
slow_port=$((garage_port + 97))
python3 - "$slow_port" "$garage_port" >"$out/proxy.log" 2>&1 <<'EOF' &
import asyncio, sys
listen, target = int(sys.argv[1]), int(sys.argv[2])
RATE = 3 * 1024 * 1024
async def pipe(r, w, slow):
    try:
        while data := await r.read(65536):
            w.write(data)
            await w.drain()
            if slow:
                await asyncio.sleep(len(data) / RATE)
    except Exception:
        pass
    finally:
        w.close()
async def handle(cr, cw):
    sr, sw = await asyncio.open_connection('127.0.0.1', target)
    await asyncio.gather(pipe(cr, sw, True), pipe(sr, cw, False))
async def main():
    server = await asyncio.start_server(handle, '127.0.0.1', listen)
    async with server:
        await server.serve_forever()
asyncio.run(main())
EOF
proxy=$!

failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "PASS $1: $2"; else echo "FAIL $1: $2, expected $3"; failed=1; fi
}
s3curl() {
  curl -sS -f --aws-sigv4 "aws:amz:${GARAGE_TEST_REGION:-garage}:s3" \
    --user "$GARAGE_TEST_ACCESS_KEY_ID:$GARAGE_TEST_SECRET_ACCESS_KEY" "$@"
}
listing() { s3curl "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET?list-type=2&prefix=$prefix/"; }
objects() { listing | grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g' || true; }
fetch() { s3curl -o "$2" "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET/$1"; }
etag() { s3curl -I "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET/$1" | tr -d '\r' | sed -n 's/^etag: *//Ip'; }
modified() { s3curl -I "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET/$1" | tr -d '\r' | sed -n 's/^last-modified: *//Ip'; }
written_at() { s3curl -I "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET/$1" | tr -d '\r' | sed -n 's/^x-amz-meta-written-at: *//Ip'; }
wait_for() { # wait_for seconds command...
  local until=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS < until)) || return 1
    sleep 1
  done
}

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb $proxy 2>/dev/null || true' EXIT
unset DBUS_SESSION_BUS_ADDRESS
sleep 1

home=
db() { echo "$home/Comics/.comicredr/comicredr.sqlite"; }
sql() { sqlite3 -batch -noheader "$(db)" "$1"; }
use() { home="$top/$out/$1"; }
start() {
  HOME="$home" "$top/build/linux/x64/release/bundle/comicredr" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 7
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
setting() { sql "insert or replace into settings values ('$1', '\"$2\"')"; }
set_up() { # scan once, then the bucket's settings through the slow proxy
  start
  wait_for 60 test "$(sql 'select count(*) from files' 2>/dev/null)" = 1
  stop
  setting s3.endpoint "http://127.0.0.1:$slow_port"
  setting s3.region "${GARAGE_TEST_REGION:-garage}"
  setting s3.bucket "$GARAGE_TEST_BUCKET"
  setting s3.prefix "$prefix/"
  setting s3.accessKey "$GARAGE_TEST_ACCESS_KEY_ID"
  mkdir -p "$home/.config/comicredr"
  (umask 077 && printf %s "$GARAGE_TEST_SECRET_ACCESS_KEY" >"$home/.config/comicredr/s3-secret")
}
cover() { click 190 200; }
open_first() { cover; key Return; sleep 3; }
# The status line's strip, to tell apart what it says.
strip() { convert "$top/$out/$1.png" -crop 900x48+0+672 +repage -colorspace gray -format %# info:; }

# --- The laptop: read to page 3, gu in the reader.
use laptop
set_up
key_=$(sql "select content_key from files")
laptop_name=$(sql "select json_extract(value, '$') from settings where key = 'device.name'")
start
open_first
key Right; key Right
wait_for 10 test "$(sql "select page from progress where content_key = '$key_'")" = 2 || true
check "laptop: on page 3" "$(sql "select page from progress where content_key = '$key_'")" 2
shot 01_before_upload
idle=$(strip 01_before_upload)
xdotool key g u
# The notice covers the status line for its first four seconds.
sleep 5
seen=()
for n in 1 2 3; do
  shot "02_uploading$n"
  seen+=("$(strip "02_uploading$n")")
  sleep 1
done
o="$prefix/books/$key_"
wait_for 90 test -n "$(objects | grep "^$o/manifest.json$")" || true
sleep 2
shot 03_uploaded
distinct=$(printf '%s\n' "${seen[@]}" | sort -u | grep -vc "^$idle$" || true)
check "reader: the status line changed while uploading (share shown)" "$((distinct >= 2))" 1
check "reader: the status line is back to normal after" "$(strip 03_uploaded)" "$(strip 01_before_upload)"
for f in comic.cbz cover.jpg sidecar.crdb manifest.json; do
  check "bucket: $f" "$(objects | grep -c "^$o/$f\$")" 1
done
check "laptop: in step with S3" "$(sql "select count(*) from s3_books where pending is null")" 1
stop
comic_tag=$(etag "$o/comic.cbz")
comic_at=$(modified "$o/comic.cbz")
manifest_at=$(modified "$o/manifest.json")
laptop_written=$(written_at "$o/sidecar.crdb")

# --- The desk: the same comic under another name, gu on its cover.
use desk
set_up
setting device.name desk
check "desk: the same content key" "$(sql "select content_key from files")" "$key_"
sleep 1
start
wait_for 30 test "$(sql "select count(*) from s3_books" 2>/dev/null)" = 1 || true
check "desk: found on the shelf at start" "$(sql "select count(*) from s3_books")" 1
cover
xdotool key g u
wait_for 60 test "$(sql "select count(*) from s3_books where pending is null and sidecar_at = $laptop_written")" = 1 || true
sleep 1
shot 04_desk_synced
check "desk: the laptop's sidecar came in" "$(sql "select sidecar_at from s3_books")" "$laptop_written"
check "desk: at the laptop's page" "$(sql "select page from progress where content_key = '$key_'")" 2
check "bucket: the comic was not sent again" "$(etag "$o/comic.cbz") $(modified "$o/comic.cbz")" "$comic_tag $comic_at"
check "bucket: the manifest was not rewritten" "$(modified "$o/manifest.json")" "$manifest_at"
fetch "$o/manifest.json" "$out/manifest.json"
check "manifest: still names the laptop" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uploaded_by"])' "$out/manifest.json")" "$laptop_name"

# --- The desk reads on and presses gu in the reader: its sidecar goes up.
sleep 1.1
open_first
key Right; key Right
wait_for 10 test "$(sql "select page from progress where content_key = '$key_'")" = 4 || true
check "desk: on page 5" "$(sql "select page from progress where content_key = '$key_'")" 4
xdotool key g u
wait_for 60 test "$(written_at "$o/sidecar.crdb")" != "$laptop_written" || true
sleep 1
shot 05_desk_pushed
fetch "$o/sidecar.crdb" "$out/sidecar.crdb"
desk_device=$(sql "select json_extract(value, '$') from settings where key = 'device.id'")
check "bucket sidecar: the desk's page" \
  "$(sqlite3 "$out/sidecar.crdb" "select page from progress where device = '$desk_device'")" 4
check "bucket: the comic still not sent again" "$(etag "$o/comic.cbz") $(modified "$o/comic.cbz")" "$comic_tag $comic_at"
stop

[[ $failed == 0 ]] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
