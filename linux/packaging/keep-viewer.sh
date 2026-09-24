#!/bin/sh
# Keeps the image viewer you had as the default for PNG, JPEG and WebP, and
# the file manager for folders. ComicRedr lists those types only so it
# shows under Open With; but where no
# mimeapps.list names a default, GNOME picks the first app it finds, and a
# launcher in ~/.local comes first. So the install saves the defaults before
# it adds the launcher and, for any type that moved to ComicRedr, sets the
# old one back with `gio mime`, as if you had picked it once yourself.
#
#   keep-viewer.sh save FILE APPSDIR      before installing
#   keep-viewer.sh restore FILE APPSDIR   after
#
# Does nothing without gio, or when APPSDIR, where the launcher goes, is
# not in your home: a system-wide install leaves every user's choice alone.
set -eu
command -v gio >/dev/null || exit 0
case $3 in "$HOME"/*) ;; *) exit 0 ;; esac
types="image/png image/jpeg image/webp inode/directory"
default() { gio mime "$1" 2>/dev/null | sed -n 's/^Default application for .*: //p'; }
case $1 in
  save)
    : >"$2"
    for t in $types; do echo "$t $(default "$t")" >>"$2"; done ;;
  restore)
    [ -f "$2" ] || exit 0
    while read -r t app; do
      if [ -n "$app" ] && [ "$app" != org.snonux.comicredr.desktop ] && [ "$(default "$t")" = org.snonux.comicredr.desktop ]; then
        gio mime "$t" "$app" >/dev/null 2>&1 || true
      fi
    done <"$2"
    rm -f "$2" ;;
esac
