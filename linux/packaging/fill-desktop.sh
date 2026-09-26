#!/bin/sh
# Fills in the launcher template on stdin for the install's bin folder $1,
# quoted the way the desktop entry spec wants, so a path with spaces (or
# & | \ $ ") still starts the app and appears under Open With.
#
#   fill-desktop.sh /home/me/.local/bin < org.snonux.comicredr.desktop.in
set -eu
bin="$1/comicredr"
# Exec: the program in double quotes, with " ` $ \ escaped inside them,
# then every \ doubled again, as in any desktop entry string.
EXEC=$(printf '%s' "$bin" | sed -e 's/[\\"`$]/\\&/g' -e 's/\\/\\\\/g')
EXEC="\"$EXEC\""
# TryExec is a plain string: only \ is doubled.
TRYEXEC=$(printf '%s' "$bin" | sed -e 's/\\/\\\\/g')
export EXEC TRYEXEC
awk '
  function put(line, tag, value,   i) {
    while ((i = index(line, tag)) > 0) line = substr(line, 1, i - 1) value substr(line, i + length(tag))
    return line
  }
  { print put(put($0, "@EXEC@", ENVIRON["EXEC"]), "@TRYEXEC@", ENVIRON["TRYEXEC"]) }
'
