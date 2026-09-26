#!/usr/bin/env bash
# End-to-end round trip of S3 sync (design plan section 13) between the
# Linux build (the laptop, under Xvfb) and the APK on a running Android
# emulator (the phone), through a one-node Garage on this machine
# (tool/garage_local.sh; the emulator reaches it at 10.0.2.2):
#
#  1. Laptop: reads a comic to page 4, marks it and a second comic with V
#     and uploads both with gu; the bucket gets comic, cover, sidecar and
#     manifest for each, the covers get the cloud badge.
#  2. Phone: S3 sync set up in its Settings by typing; the two comics show
#     up as on S3 only, with their covers. The comic is downloaded from its
#     page into the same folder under /sdcard/Comics, and opens on page 4,
#     where the laptop left it; the phone reads on to page 7 and goes back
#     to the library, which sends its sidecar up.
#  3. Laptop: opening the comic fetches the phone's newer sidecar and offers
#     the phone's place; taken, it reads on from page 7.
#  4. Laptop: gd on the second comic, "Delete here and from S3"; gU on the
#     first: the bucket is empty again and the comic stays on the laptop.
#
# Checks the bucket (through curl and sqlite3 on the sidecar in it), the
# laptop's index and the files on the phone, with screenshots of both.
#
#   tool/garage_local.sh start
#   tool/e2e_s3_android.sh build/app/outputs/flutter-apk/app-release.apk
#
# The APK should be built for x86_64 (make apk APK_ABI=android-arm64,android-x64);
# NO_MODEL=1 keeps the emulator responsive (the detector takes minutes a page
# there without KVM). Comics are JPEG: every PNG fails to decode on that
# emulator. E2E_SKIP_BUILD=1 reuses the Linux release build in build/.
# Needs: adb, Xvfb, xdotool, ImageMagick, sqlite3, curl, python3.
# Output: build/e2e-s3-android/*.png, a pass/fail line per check.
set -euo pipefail
cd "$(dirname "$0")/.."
apk=${1:-}
# CI runs every e2e script without arguments and has no emulator here.
if [[ -z $apk ]] || ! adb get-state >/dev/null 2>&1; then
  echo "SKIP needs an APK and a running emulator: tool/e2e_s3_android.sh app-release.apk"
  exit 0
fi
pkg=org.snonux.comicredr

eval "$(tool/garage_local.sh env)"
port=${GARAGE_TEST_ENDPOINT##*:}
prefix="comicredr-e2e-$(date +%s)"
phone_endpoint="http://10.0.2.2:$port"

top=$PWD
out=build/e2e-s3-android
rm -rf "$out" && mkdir -p "$out/pages" "$out/home/Comics/Golden Age"
home="$top/$out/home"

# Two JPEG comics with the page number large on each page.
book() { # book path title pages
  rm -f "$out"/pages/*
  local i
  for ((i = 1; i <= $3; i++)); do
    convert -size 800x1200 xc:ivory -fill none -stroke black -strokewidth 8 \
      -draw 'rectangle 40,40 760,1160' -fill black -stroke none -pointsize 90 \
      -annotate +90+300 "$2" -pointsize 260 -annotate +250+800 "$i" -quality 85 "$out/pages/p$(printf %02d "$i").jpg"
  done
  python3 - "$out/pages" "$1" <<'EOF'
import sys, zipfile, pathlib
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    for f in sorted(pathlib.Path(sys.argv[1]).glob('*.jpg')):
        z.write(f, 'page' + f.name[1:])
EOF
}
book "$home/Comics/Golden Age/Round Trip 1.cbz" 'Round Trip' 8
book "$home/Comics/Second 1.cbz" 'Second' 3

failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "PASS $1: $2"; else echo "FAIL $1: $2, expected $3"; failed=1; fi
}

# ---------------------------------------------------------------- bucket
objects() { # every key under the run's prefix
  curl -sS --aws-sigv4 "aws:amz:${GARAGE_TEST_REGION:-garage}:s3" \
    --user "$GARAGE_TEST_ACCESS_KEY_ID:$GARAGE_TEST_SECRET_ACCESS_KEY" \
    "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET?list-type=2&prefix=$prefix/" |
    grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g' || true
}
fetch() { # fetch key file
  curl -sS -f --aws-sigv4 "aws:amz:${GARAGE_TEST_REGION:-garage}:s3" \
    --user "$GARAGE_TEST_ACCESS_KEY_ID:$GARAGE_TEST_SECRET_ACCESS_KEY" \
    -o "$2" "$GARAGE_TEST_ENDPOINT/$GARAGE_TEST_BUCKET/$1"
}
wait_for() { # wait_for seconds command...: until the command succeeds
  local until=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS < until)) || return 1
    sleep 2
  done
}
manifests() { objects | grep -c '/manifest.json$' || true; }

# ---------------------------------------------------------------- laptop
[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:95
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
# No D-Bus session, so no keyring: the secret key is in its private file.
unset DBUS_SESSION_BUS_ADDRESS
db="$home/Comics/.comicredr/comicredr.sqlite"
sql() { sqlite3 -batch -noheader "$db" "$1"; }
start() {
  HOME="$home" "$top/build/linux/x64/release/bundle/comicredr" >>"$top/$out/app.log" 2>&1 &
  app=$!
  sleep 7
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$top/$out/$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 0.9; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 1.2; }
key_of() { sql "select content_key from files where rel_path = '$1'"; }

# The first start makes the index; S3 sync is set up in it and the secret
# key's file as the settings dialog would (tool/e2e_s3_settings.sh drives
# that dialog itself).
start
wait_for 60 test "$(sql 'select count(*) from files' 2>/dev/null)" = 2
stop
setting() { sql "insert or replace into settings values ('$1', '\"$2\"')"; }
setting s3.endpoint "$GARAGE_TEST_ENDPOINT"
setting s3.region "${GARAGE_TEST_REGION:-garage}"
setting s3.bucket "$GARAGE_TEST_BUCKET"
setting s3.prefix "$prefix/"
setting s3.accessKey "$GARAGE_TEST_ACCESS_KEY_ID"
mkdir -p "$home/.config/comicredr"
(umask 077 && printf %s "$GARAGE_TEST_SECRET_ACCESS_KEY" >"$home/.config/comicredr/s3-secret")
round=$(key_of 'Golden Age/Round Trip 1.cbz')
second=$(key_of 'Second 1.cbz')
laptop_device=$(sql "select json_extract(value, '$') from settings where key = 'device.id'")

start
click 640 450
# The Books tab; the first cover is Round Trip. Read it to page 4.
key Tab
key l
key Return
sleep 3
key Right; key Right; key Right
sleep 2
shot 01_laptop_page4
key Escape
sleep 1
check "laptop: read to page 4" "$(sql "select page from progress where content_key = '$round'")" 3

# 1. Both covers marked with V, uploaded with gu.
key V; key V
shot 02_laptop_marked
key g u
wait_for 60 test "$(manifests)" = 2 || true
sleep 2
shot 03_laptop_uploaded
check "bucket: two manifests" "$(manifests)" 2
for k in "$round" "$second"; do
  for f in comic.cbz cover.jpg sidecar.crdb manifest.json; do
    check "bucket: $f of $(sql "select rel_path from files where content_key = '$k'")" \
      "$(objects | grep -c "^$prefix/books/$k/$f\$")" 1
  done
done
check "laptop: both in step with S3" "$(sql "select count(*) from s3_books where pending is null")" 2
fetch "$prefix/books/$round/manifest.json" "$out/manifest.json"
check "manifest: the folder" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["folder"])' "$out/manifest.json")" 'Golden Age'
fetch "$prefix/books/$round/sidecar.crdb" "$out/sidecar-1.crdb"
check "bucket sidecar: the laptop's page" \
  "$(sqlite3 "$out/sidecar-1.crdb" "select page from progress where device = '$laptop_device'")" 3
stop
if [[ -n ${LAPTOP_ONLY:-} ]]; then
  [[ $failed == 0 ]] && echo "LAPTOP PART PASSED" || { echo "SOME FAILED"; exit 1; }
  exit 0
fi

# ----------------------------------------------------------------- phone
adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'
adb shell settings put global hide_error_dialogs 1
adb uninstall "$pkg" >/dev/null 2>&1 || true
adb shell rm -rf /sdcard/Comics
adb shell mkdir -p /sdcard/Comics
adb install -r "$apk" >/dev/null
adb shell appops set --uid "$pkg" MANAGE_EXTERNAL_STORAGE allow
adb logcat -c
adb shell am start -W -n "$pkg/.MainActivity" >/dev/null
pshot() { adb exec-out screencap -p >"$out/$1.png"; }
tap() { adb shell input tap "$1" "$2"; sleep "${3:-3}"; }
pkey() { adb shell input keyevent "$@"; sleep 1; }
read -r W H < <(adb shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)
# Flutter's semantics reach uiautomator: taps find their target by its
# label, so no coordinates depend on the screen.
ui_dump() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb shell cat /sdcard/ui.xml | tr '<' '\n'; }
ui_find() { # bounds of the first node whose text or label matches $1 (an ERE)
  ui_dump | grep -E "(text|content-desc)=\"$1\"" | head -1 |
    sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p'
}
uitap() { # uitap LABEL [wait] [scroll]: taps it, scrolling down to find it when asked
  local b='' x1 y1 x2 y2
  for _ in $(seq 1 15); do
    b=$(ui_find "$1") && [[ -n $b ]] && break
    [[ -n ${3:-} ]] && adb shell input swipe $((W / 2)) $((H * 2 / 3)) $((W / 2)) $((H / 3)) 400
    sleep 2
  done
  [[ -n $b ]] || { echo "not on screen: $1" >&2; pshot "missing_$(date +%s)"; return 1; }
  read -r x1 y1 x2 y2 <<<"$b"
  tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2)) "${2:-3}"
}
sleep 30
pshot 04_phone_empty

# Settings (the gear in the header), scrolled down to "Set up S3 sync…".
uitap Settings 3
uitap 'Set up S3 sync…' 3 scroll
pshot 05_phone_s3_dialog
# The address has the focus; Tab walks the fields in order.
dels=$(printf 'KEYCODE_DEL %.0s' $(seq 40))
for f in "$phone_endpoint" "${GARAGE_TEST_REGION:-garage}" "$GARAGE_TEST_BUCKET" "$prefix/" \
  "$GARAGE_TEST_ACCESS_KEY_ID" "$GARAGE_TEST_SECRET_ACCESS_KEY"; do
  adb shell input keyevent KEYCODE_MOVE_END $dels
  adb shell input text "$f"
  adb shell input keyevent KEYCODE_TAB
done
uitap 'Test connection' 2
wait_for 30 test -n "$(ui_find 'Connected to[^"]*')" || true
pshot 06_phone_tested
check "phone: the connection test passes" "$(ui_find 'Connected to[^"]*' | wc -w)" 4
uitap Save 3
uitap Close 20
pshot 07_phone_shelf

# 2. The comic's page (a tap on its cover), then Download.
uitap 'Books[^"]*' 3
uitap 'Round Trip[^"]*' 5
pshot 08_phone_detail
uitap 'Download[^"]*' 5
wait_for 120 adb shell test -f "'/sdcard/Comics/Golden Age/Round Trip 1.cbz'" || true
sleep 10
pshot 09_phone_downloaded
check "phone: downloaded into its folder" \
  "$(adb shell sha256sum "'/sdcard/Comics/Golden Age/Round Trip 1.cbz'" | cut -d' ' -f1)" \
  "$(sha256sum "$home/Comics/Golden Age/Round Trip 1.cbz" | cut -d' ' -f1)"
check "phone: its sidecar came with it" \
  "$(adb shell test -f "'/sdcard/Comics/Golden Age/.Round Trip 1.cbz.crdb'" && echo yes || echo no)" yes
check "phone: the other comic is not downloaded" "$(adb shell test -e /sdcard/Comics/Second\\ 1.cbz && echo yes || echo no)" no
# Read: it opens where the laptop left it; three taps on the right edge on.
uitap '(Continue reading|Read)' 15
pshot 10_phone_resumed
for _ in 1 2 3; do tap $((W - 20)) $((H / 2)) 6; done
pshot 11_phone_page7
pkey KEYCODE_BACK
sleep 20
pshot 12_phone_back

sidecar_page() { # the page a device other than the laptop has in the bucket's sidecar
  fetch "$prefix/books/$round/sidecar.crdb" "$out/sidecar-2.crdb" &&
    sqlite3 "$out/sidecar-2.crdb" "select page from progress where device != '$laptop_device'"
}
wait_for 90 test "$(sidecar_page)" = 6 || true
check "bucket sidecar: the phone read on to page 7" "$(sidecar_page)" 6
check "bucket sidecar: the laptop's page kept" \
  "$(sqlite3 "$out/sidecar-2.crdb" "select page from progress where device = '$laptop_device'")" 3
adb logcat -d >"$out/logcat.txt"
check "phone: no errors in the log" "$(grep -cE 'FATAL EXCEPTION|Unhandled Exception' "$out/logcat.txt" || true)" 0

# ---------------------------------------------------------- laptop again
# 3. Opening the comic brings the phone's sidecar and offers its place.
start
click 640 450
key Tab
key g g
key Return
sleep 4
shot 15_laptop_offer
key Return
sleep 4
shot 16_laptop_page7
key Escape
sleep 2
check "laptop: carried on from the phone" "$(sql "select page from progress where content_key = '$round'")" 6

# 4. gd on the second comic: here and from S3. gU on the first: from S3 only.
key g g
key l
key g d
sleep 1
shot 17_laptop_delete
key Tab; key Tab; key Return
sleep 5
check "laptop: the second comic deleted" "$(test -e "$home/Comics/Second 1.cbz" && echo yes || echo no)" no
wait_for 30 test "$(objects | grep -c "/$second/" || true)" = 0 || true
check "bucket: the second comic gone" "$(objects | grep -c "/$second/" || true)" 0
key g g
key g U
sleep 1
shot 18_laptop_remove
key Tab; key Return
wait_for 30 test -z "$(objects)" || true
shot 19_laptop_removed
check "bucket: empty again" "$(objects | wc -l)" 0
check "laptop: the comic stays" "$(test -f "$home/Comics/Golden Age/Round Trip 1.cbz" && echo yes || echo no)" yes
check "laptop: no longer on S3" "$(sql "select count(*) from s3_books")" 0
stop

montage "$out"/[01]*.png -tile 4x -geometry 480x360+4+4 "$out/contact.png" 2>/dev/null || true
[[ $failed == 0 ]] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
