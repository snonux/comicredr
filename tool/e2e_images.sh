#!/usr/bin/env bash
# End-to-end check of one-page image comics on the Linux build, over four
# Pepper&Carrot pages (David Revoy, CC BY 4.0) fetched from peppercarrot.com.
#
# It lays out a shelf with a JPEG, a PNG and a WebP one-pager beside a CBZ,
# and a folder holding only page images. Then:
#   - the library lists three image comics, the CBZ and one folder book, each
#     with a cover (checked with sqlite3);
#   - each image opened from the command line shows the page, guided view
#     steps through its panels, and its sidecar beside it gets the panels;
#   - ] from the JPEG opens the PNG beside it (same pixels as opening it);
#   - an image in the folder book opened directly is one page, not the book;
#   - `make install` into a scratch home lists the image types in the
#     launcher without making ComicRedr the default for them, whether or
#     not the system names a default image viewer.
#
#   COMICREDR_MODEL=comicredr-panels.onnx tool/e2e_images.sh
#
# E2E_SKIP_BUILD=1 reuses the release build already in build/.
# Needs: Xvfb, xdotool, ImageMagick (with WebP), python3, sqlite3, curl,
# desktop-file-utils, xdg-utils.
# Output: build/e2e-images/shot_*.png and build/e2e-images/contact.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/e2e-images
cache=build/e2e-images-src
rm -rf "$out" && mkdir -p "$out/Comics/Pages only" "$out/home" "$cache"
comics="$PWD/$out/Comics"
db="$PWD/$out/home/.local/share/org.snonux.comicredr/comicredr.sqlite"

base=https://www.peppercarrot.com/0_sources/ep06_The-Potion-Contest/low-res
for n in 01 03 05 07; do
  f="$cache/E06P$n.jpg"
  [[ -s "$f" ]] || curl -fsSL -o "$f" "$base/en_Pepper-and-Carrot_by-David-Revoy_E06P$n.jpg"
done
cp "$cache/E06P01.jpg" "$comics/Pepper Carrot 6 page 1.jpg"
convert "$cache/E06P03.jpg" "$comics/Pepper Carrot 6 page 3.png"
convert "$cache/E06P05.jpg" -quality 85 "$comics/Pepper Carrot 6 page 5.webp"
cp "$cache/E06P05.jpg" "$cache/E06P07.jpg" "$comics/Pages only/"
(cd "$cache" && python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); [z.write(f) for f in sys.argv[2:]]' \
  "$comics/Potion Contest.cbz" E06P05.jpg E06P07.jpg)
file "$comics"/*.* | sed 's/^/  /'

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:96
Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT

start() {
  HOME="$PWD/$out/home" build/linux/x64/release/bundle/comicredr "$@" >>"$out/app.log" 2>&1 &
  app=$!
  sleep 5
  win=$(xdotool search --name ComicRedr | tail -1)
  xdotool windowactivate --sync "$win" mousemove 640 400 click 1 2>/dev/null || true
  sleep 0.5
}
stop() { kill "$app" 2>/dev/null; wait "$app" 2>/dev/null || true; app=; }
shot() { import -window root "$out/shot_$1.png"; }
key() { xdotool key "$@" 2>/dev/null; sleep 1; }
q() { python3 -c 'import sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchall(); print(" ".join("|".join(map(str,x)) for x in r))' "$@"; }
sql() { q "$db" "$1"; }
failed=0
check() { # check "what" actual expected
  if [[ "$2" == "$3" ]]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2, expected $3"; failed=1; fi
}
# The page area, above the status line whose title differs per book.
page_of() { convert "$out/shot_$1.png" -crop 1280x660+0+0 +repage "$out/crop_$1.png"; }
differ() { # pixels that differ between two shots' page areas
  page_of "$1"; page_of "$2"
  compare -metric AE "$out/crop_$1.png" "$out/crop_$2.png" /dev/null 2>&1 || true
}
# Panels detected on page 1, as the sidecar beside the image has them.
panels() { [[ -f "$1.crdb" ]] && q "$1.crdb" 'select count(*) from panels where page = 0' 2>/dev/null || echo none; }
wait_for() { for _ in $(seq 1 60); do "$@" && return 0; sleep 0.5; done; return 1; }

# 1. The library: three one-pagers, the CBZ and the folder book.
start --add-root "$comics"
for _ in $(seq 1 120); do
  [[ -f "$db" ]] && [[ "$(sql 'select count(*) from books' 2>/dev/null)" == 5 ]] && break
  sleep 0.5
done
sleep 3
key Tab; shot 01_library
check "books indexed" "$(sql 'select count(*) from books')" 5
check "formats" "$(sql 'select format, count(*) from books group by format order by format')" "cbz|1 folder|1 image|3"
check "one page each" "$(sql "select distinct page_count from books where format = 'image'")" 1
check "folder book pages" "$(sql "select page_count from books where format = 'folder'")" 2
check "covers" "$(ls "$out"/home/.cache/org.snonux.comicredr/covers/*.jpg 2>/dev/null | wc -l)" 5
python3 -c 'import sqlite3,sys; [print("  ", *r) for r in sqlite3.connect(sys.argv[1]).execute("select f.rel_path, b.format, b.page_count from books b join files f using (content_key) order by f.rel_path")]' "$db"
stop

# 2. Each one-pager opens, guided view steps its panels, its sidecar fills.
for img in "Pepper Carrot 6 page 1.jpg" "Pepper Carrot 6 page 3.png" "Pepper Carrot 6 page 5.webp"; do
  tag=$(echo "${img##* }" | tr . _)
  start "$comics/$img"
  shot "10_${tag}_page"
  key v; sleep 2; shot "11_${tag}_guided"
  key l; sleep 1; shot "12_${tag}_panel_2"
  stop
  check "$img: guided view moved the camera" "$( (( $(differ "10_${tag}_page" "12_${tag}_panel_2") > 10000 )) && echo yes || echo no)" yes
  wait_for test -f "$comics/$img.crdb" || true
  check "$img: panels in its sidecar" "$( (( $(panels "$comics/$img") > 1 )) 2>/dev/null && echo yes || echo "$(panels "$comics/$img")")" yes
done

# 3. ] from the JPEG opens the PNG beside it.
start "$comics/Pepper Carrot 6 page 3.png"; shot 20_png_direct; stop
start "$comics/Pepper Carrot 6 page 1.jpg"
key bracketright; sleep 2; shot 21_bracket_to_png
stop
check "] from the JPEG shows the PNG" "$(differ 20_png_direct 21_bracket_to_png)" 0

# 4. A page of the folder book opened alone is one page.
start "$comics/Pages only/E06P05.jpg"; shot 30_folder_page_alone
key l; sleep 1; shot 31_folder_page_next
stop
check "the next page key stays on a one-page comic" "$(differ 30_folder_page_alone 31_folder_page_next)" 0
check "its sidecar beside the image" "$(ls "$comics/Pages only/" | grep -c 'E06P05.jpg.crdb')" 1

# 5. The launcher offers ComicRedr for images, but not as their default:
# (a) the system names a default viewer, as Fedora's GNOME does; (b) it
# names none, where GNOME would take the newest launcher, so the install
# pins the viewer that was the default before it.
mkdir -p "$out/sys/applications"
printf '[Desktop Entry]\nType=Application\nName=Image Viewer\nExec=true %%U\nMimeType=image/png;image/jpeg;image/webp;\n' \
  >"$out/sys/applications/org.gnome.Loupe.desktop"
printf '[Desktop Entry]\nType=Application\nName=Files\nExec=true %%U\nMimeType=inode/directory;\n' \
  >"$out/sys/applications/org.gnome.Nautilus.desktop"
update-desktop-database -q "$out/sys/applications"
env_of() { echo HOME="$1" XDG_CURRENT_DESKTOP=GNOME XDG_DATA_HOME="$1/.local/share" XDG_CONFIG_HOME="$1/.config" XDG_DATA_DIRS="$PWD/$out/sys"; }
pick() { env $(env_of "$1") gio mime "$2" 2>/dev/null | sed -n 's/^Default application for .*: //p'; }
for case in a b; do
  home="$PWD/$out/install-home-$case"
  mkdir -p "$home/.local/share/applications" "$home/.config"
  if [[ $case == a ]]; then
    printf '[Default Applications]\nimage/png=org.gnome.Loupe.desktop\nimage/jpeg=org.gnome.Loupe.desktop\nimage/webp=org.gnome.Loupe.desktop\ninode/directory=org.gnome.Nautilus.desktop\n' \
      >"$out/sys/applications/gnome-mimeapps.list"
  else
    rm -f "$out/sys/applications/gnome-mimeapps.list"
  fi
  env $(env_of "$home") make --no-print-directory install >/dev/null
  desktop="$home/.local/share/applications/org.snonux.comicredr.desktop"
  check "$case: launcher validates" "$(desktop-file-validate "$desktop" && echo valid)" valid
  check "$case: launcher lists image types" "$(grep -o 'image/[a-z]*' "$desktop" | tr '\n' ' ')" "image/png image/jpeg image/webp "
  for t in image/png image/jpeg image/webp; do check "$case: default for $t" "$(pick "$home" "$t")" org.gnome.Loupe.desktop; done
  check "$case: default for folders" "$(pick "$home" inode/directory)" org.gnome.Nautilus.desktop
  check "$case: ComicRedr under Open With for folders" \
    "$(env $(env_of "$home") gio mime inode/directory 2>/dev/null | grep -c 'org.snonux.comicredr.desktop')" 2
  check "$case: default for application/x-cbz" "$(pick "$home" application/x-cbz)" org.snonux.comicredr.desktop
  check "$case: ComicRedr under Open With for PNG" \
    "$(env $(env_of "$home") gio mime image/png 2>/dev/null | grep -c 'org.snonux.comicredr.desktop')" 2
  if [[ $case == a ]]; then
    check "a: mimeapps.list left alone" "$(ls "$home/.config/mimeapps.list" 2>/dev/null | wc -l)" 0
  else
    echo "  b: $home/.config/mimeapps.list:"; sed 's/^/    /' "$home/.config/mimeapps.list"
  fi
done

montage -label '%t' "$out"/shot_*.png -tile 4x -geometry 480x338+4+14 "$out/contact.png"
if grep -v XGetInputFocus "$out/app.log" | grep -q 'Unhandled Exception\|\[ERROR'; then
  echo "Errors in $out/app.log:" && grep -v XGetInputFocus "$out/app.log" | grep 'Unhandled Exception\|\[ERROR'
  failed=1
fi
echo "Screenshots in $out/, overview in $out/contact.png"
exit $failed
