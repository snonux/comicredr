#!/bin/sh
# Installs ComicRedr from the release tarball, per user and without sudo:
#
#   ./install.sh                 into ~/.local
#   ./install.sh /usr/local      system-wide (run with sudo)
#   ./install.sh --uninstall [PREFIX]
#
# Reading progress, sidecars and the library index are never touched.
set -eu

APP_ID=org.snonux.comicredr
here=$(cd "$(dirname "$0")" && pwd)
uninstall=
if [ "${1:-}" = --uninstall ]; then
  uninstall=1
  shift
fi
PREFIX=${1:-$HOME/.local}
# Absolute, or the bin symlink and the launcher would point nowhere.
case $PREFIX in
  /*) ;;
  *) mkdir -p "$PREFIX" && PREFIX=$(cd "$PREFIX" && pwd) ;;
esac
BINDIR=$PREFIX/bin
LIBDIR=$PREFIX/lib/comicredr
APPSDIR=$PREFIX/share/applications
ICONDIR=$PREFIX/share/icons/hicolor

rm -rf "$LIBDIR"
rm -f "$BINDIR/comicredr" "$APPSDIR/$APP_ID.desktop" "$ICONDIR/scalable/apps/$APP_ID.svg"
for png in "$here"/packaging/icons/*.png; do
  s=$(basename "$png" .png)
  rm -f "$ICONDIR/${s}x$s/apps/$APP_ID.png"
done

defaults=$(mktemp)
[ -n "$uninstall" ] || "$here/packaging/keep-viewer.sh" save "$defaults" "$APPSDIR"

if [ -z "$uninstall" ]; then
  mkdir -p "$LIBDIR" "$BINDIR" "$APPSDIR" "$ICONDIR/scalable/apps"
  cp -a "$here/bundle/." "$LIBDIR/"
  ln -sfn "$LIBDIR/comicredr" "$BINDIR/comicredr"
  "$here/packaging/fill-desktop.sh" "$BINDIR" < "$here/packaging/$APP_ID.desktop.in" > "$APPSDIR/$APP_ID.desktop"
  cp "$here/packaging/$APP_ID.svg" "$ICONDIR/scalable/apps/"
  for png in "$here"/packaging/icons/*.png; do
    s=$(basename "$png" .png)
    mkdir -p "$ICONDIR/${s}x$s/apps"
    cp "$png" "$ICONDIR/${s}x$s/apps/$APP_ID.png"
  done
fi

# Let GNOME pick up the launcher and icon straight away.
if command -v update-desktop-database >/dev/null; then update-desktop-database -q "$APPSDIR" || true; fi
if [ -f "$ICONDIR/icon-theme.cache" ]; then gtk-update-icon-cache -qtf "$ICONDIR" || true
elif [ -d "$ICONDIR" ]; then touch "$ICONDIR"; fi
[ -n "$uninstall" ] || "$here/packaging/keep-viewer.sh" restore "$defaults" "$APPSDIR"
rm -f "$defaults"

if [ -n "$uninstall" ]; then
  echo "Uninstalled. Your reading progress in ~/Comics/.comicredr or ~/.local/share/$APP_ID is kept."
else
  echo "Installed. ComicRedr is in the app grid; $BINDIR/comicredr starts it from a shell."
fi
