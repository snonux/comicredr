#!/usr/bin/env bash
# Smoke run of the APK on a running Android emulator (adb connected): puts a
# comic in /sdcard/Comics, installs the app with All files access granted,
# starts it, and checks it is still running with no crash in the log after
# the library has scanned; then opens the first cover with a tap and checks
# again. Screenshots and the log go to build/android-smoke/.
#
#   tool/ci_android_smoke.sh app-release.apk book.cbz
#
# The ONNX Runtime plugin ships no x86_64 library, so on an x86_64
# emulator the app detects panels with classic CV; the detector itself is
# not exercised here.
set -euo pipefail
cd "$(dirname "$0")/.."
apk=${1:?usage: tool/ci_android_smoke.sh app.apk book.cbz}
book=${2:?usage: tool/ci_android_smoke.sh app.apk book.cbz}
app=org.snonux.comicredr
out=build/android-smoke
rm -rf "$out" && mkdir -p "$out"

adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'
adb logcat -c
adb shell mkdir -p /sdcard/Comics
adb push "$book" /sdcard/Comics/ >/dev/null
adb install -r "$apk"
adb shell appops set --uid "$app" MANAGE_EXTERNAL_STORAGE allow
adb shell am start -W -n "$app/.MainActivity"

failed=0
shot() { adb exec-out screencap -p >"$out/$1.png"; }
check_alive() {
  if adb shell pidof "$app" >/dev/null; then echo "PASS $1: running"; else echo "FAIL $1: not running"; failed=1; fi
  adb logcat -d >"$out/logcat.txt"
  if grep -E "FATAL EXCEPTION|Unhandled Exception|E/flutter" "$out/logcat.txt"; then
    echo "FAIL $1: errors in the log"; failed=1
  else
    echo "PASS $1: no errors in the log"
  fi
}

sleep 30
shot 01_library
check_alive "library"
# The first cover sits top left in the library grid on a phone screen.
read -r w h < <(adb shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)
adb shell input tap $((w / 6)) $((h / 4))
sleep 15
shot 02_tapped
adb shell input tap $((w * 9 / 10)) $((h / 2))
sleep 5
shot 03_next
check_alive "reader"
exit $failed
