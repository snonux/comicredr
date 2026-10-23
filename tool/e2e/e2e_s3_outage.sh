#!/usr/bin/env bash
# A real reader session against an HTTP 502 fixture: a failure during
# reading is reported once, page turns and another upload keep queuing
# locally without reconnecting, and restart reconnects then pauses again.
# E2E_SKIP_BUILD=1 reuses the release build. No Garage or credentials.
set -euo pipefail
cd "$(dirname "$0")/../.."

top=$PWD
out="$top/build/e2e-s3-outage"
rm -rf "$out"
mkdir -p "$out/home/Comics" "$out/pages"
for i in 1 2 3 4 5; do
  convert -size 800x1200 xc:ivory -fill black -pointsize 90 \
    -annotate +100+400 "Outage page $i" "$out/pages/$i.jpg"
done
python3 - "$out" <<'PY'
import pathlib, sys, zipfile
out = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(out / 'home/Comics/Outage 1.cbz', 'w') as book:
    for page in sorted((out / 'pages').glob('*.jpg')):
        book.write(page, page.name)
PY

# The server lists an empty shelf until down is created, then every
# request gets the HTML Bad Gateway body that a reverse proxy returns.
python3 - "$out" >"$out/server.log" 2>&1 <<'PY' &
import http.server, pathlib, sys
out = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def handle_call(self):
        with (out / 'requests').open('a') as log:
            log.write(self.command + ' ' + self.path + '\n')
        if (out / 'down').exists():
            body = b'<html><body>Bad Gateway</body></html>'
            self.send_response(502)
            self.send_header('Content-Type', 'text/html')
        else:
            body = b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>comics</Name><IsTruncated>false</IsTruncated></ListBucketResult>'
            self.send_response(200)
            self.send_header('Content-Type', 'application/xml')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)
    do_GET = do_HEAD = do_PUT = do_DELETE = handle_call
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(out / 'port').write_text(str(server.server_port))
server.serve_forever()
PY
server=$!
app=
xvfb=
trap 'kill $app $xvfb $server 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
  [[ -f "$out/port" ]] && break
  sleep 0.1
done
port=$(<"$out/port")

[[ -n "${E2E_SKIP_BUILD:-}" ]] || flutter build linux --release
export DISPLAY=:89
Xvfb "$DISPLAY" -screen 0 1280x900x24 >"$out/xvfb.log" 2>&1 &
xvfb=$!
for _ in $(seq 1 100); do
  xdotool getdisplaygeometry >/dev/null 2>&1 && break
  sleep 0.1
done
xdotool getdisplaygeometry >/dev/null 2>&1
home="$out/home"
db="$home/Comics/.comicredr/comicredr.sqlite"
sql() { sqlite3 -batch -noheader -cmd '.timeout 5000' "$db" "$1"; }
key() { xdotool key "$@"; sleep 1; }
start() {
  env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/comicredr-no-session-bus \
    COMICREDR_MODEL=none HOME="$home" GDK_BACKEND=x11 \
    "$top/build/linux/x64/release/bundle/comicredr" "$@" \
    >>"$out/app.log" 2>&1 &
  app=$!
  wait_for 40 focus_window
  sleep 2
}
stop() { kill "$app"; wait "$app" 2>/dev/null || true; app=; }
check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS $1: $2"
  else
    echo "FAIL $1: $2, expected $3"
    exit 1
  fi
}
wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    (( SECONDS < deadline )) || return 1
    sleep 0.5
  done
}
focus_window() {
  win=$(xdotool search --onlyvisible --name ComicRedr | tail -1) || return 1
  [[ -n "$win" ]] && xdotool windowfocus "$win" 2>/dev/null
}
indexed() { [[ "$(sql 'select count(*) from files' 2>/dev/null)" == 1 ]]; }
opened() { [[ "$(sql 'select count(*) from progress' 2>/dev/null)" == 1 ]]; }
connected() { [[ -f "$out/requests" ]] && (( $(requests) > 0 )); }
reconnected() { (( $(requests) > first )); }
setting() {
  sql "insert or replace into settings values ('$1', '\"$2\"')"
}
requests() { wc -l <"$out/requests"; }

start --add-root "$home/Comics"
wait_for 40 indexed || true
check 'comic scanned' "$(sql 'select count(*) from files')" 1
stop
setting s3.endpoint "http://127.0.0.1:$port"
setting s3.region garage
setting s3.bucket comics
setting s3.accessKey test
mkdir -p "$home/.config/comicredr"
(umask 077 && printf %s test >"$home/.config/comicredr/s3-secret")
start "$home/Comics/Outage 1.cbz"
wait_for 40 connected
wait_for 40 opened
check 'connected at start' "$(( $(requests) > 0 ))" 1
key Right
# S3 goes down with the comic open. gu queues the upload and hits 502.
touch "$out/down"
key g u
sleep 2
first=$(requests)
check 'outage reached the server' "$(( first > 1 ))" 1
check 'upload queued' "$(sql 'select count(*) from s3_books where pending is not null')" 1
import -window root "$out/01_outage.png"
key Right
key g u
key Right
# This passes the old 30-second retry boundary and several 10-second
# sidecar push delays. The fixture sees no more calls.
sleep 34
check 'no retry during page turns or repeated upload' "$(requests)" "$first"
check 'reader saved page 4 locally' "$(sql 'select page from progress')" 3
key Escape
sleep 2
check 'closing the reader also respects the pause' "$(requests)" "$first"
import -window root "$out/02_saved.png"
stop
start "$home/Comics/Outage 1.cbz"
wait_for 40 reconnected
sleep 3
# Startup can begin both a shelf refresh and the open comic's check
# before either reports the outage. Verify the new attempt happens and
# then stays paused, rather than assuming exactly one HTTP request.
restarted=$(requests)
check 'restart reconnects' "$((restarted > first))" 1
key Right
sleep 12
check 'restart pauses again during reading' "$(requests)" "$restarted"
check 'restart keeps queued work' "$(sql 'select count(*) from s3_books where pending is not null')" 1
import -window root "$out/03_restart.png"
stop
echo 'ALL PASSED'
