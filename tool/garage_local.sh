#!/usr/bin/env bash
# A one-node Garage on localhost for testing S3 sync (design plan section 13).
#
#   tool/garage_local.sh start   # download Garage once, start it, make a bucket and a key
#   tool/garage_local.sh env     # print GARAGE_TEST_* for it: eval "$(tool/garage_local.sh env)"
#   tool/garage_local.sh stop    # switch the "home cluster" off; start again brings it back, data kept
#   tool/garage_local.sh wipe    # stop and delete its data
#
# The key is made up for this local node only. The tests in packages/comic_sync and
# tool/e2e_s3_settings.sh read GARAGE_TEST_*; set them to a real bucket instead to test against one.
set -euo pipefail

VERSION=${GARAGE_VERSION:-v2.1.0}
DIR=${GARAGE_DIR:-$HOME/.cache/comicredr-garage}
BIN=$DIR/garage-$VERSION
CONF=$DIR/garage.toml
PORT=${GARAGE_PORT:-3900}
BUCKET=comicredr-test
KEY_ID=GK0123456789abcdef01234567
SECRET=5d1f8c3a9e7b24c6a0f3e8d2b7c19a4e6f0d3b8a2c5e9f1a7d4b0c6e3f8a2d95

garage() { "$BIN" -c "$CONF" "$@"; }

fetch() {
  [ -x "$BIN" ] && return
  mkdir -p "$DIR"
  local arch
  arch=$(uname -m)
  curl -fsSL -o "$BIN.part" "https://garagehq.deuxfleurs.fr/_releases/$VERSION/$arch-unknown-linux-musl/garage"
  chmod +x "$BIN.part"
  mv "$BIN.part" "$BIN"
}

configure() {
  [ -f "$CONF" ] && return
  mkdir -p "$DIR/meta" "$DIR/data"
  cat >"$CONF" <<EOF
metadata_dir = "$DIR/meta"
data_dir = "$DIR/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "127.0.0.1:$((PORT + 1))"
rpc_public_addr = "127.0.0.1:$((PORT + 1))"
rpc_secret = "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:$PORT"
root_domain = ".s3.garage.localhost"

[admin]
api_bind_addr = "127.0.0.1:$((PORT + 3))"
EOF
}

running() { [ -f "$DIR/pid" ] && kill -0 "$(cat "$DIR/pid")" 2>/dev/null; }

start() {
  fetch
  configure
  if ! running; then
    "$BIN" -c "$CONF" server >"$DIR/server.log" 2>&1 &
    echo $! >"$DIR/pid"
  fi
  for _ in $(seq 50); do
    garage status >/dev/null 2>&1 && break
    sleep 0.2
  done
  if [ ! -f "$DIR/ready" ]; then
    local node
    node=$(garage node id -q | cut -d@ -f1)
    garage layout assign -z local -c 1G "$node" >/dev/null
    garage layout apply --version 1 >/dev/null
    garage key import --yes -n comicredr-test "$KEY_ID" "$SECRET" >/dev/null
    garage bucket create "$BUCKET" >/dev/null
    garage bucket allow --read --write --owner "$BUCKET" --key "$KEY_ID" >/dev/null
    touch "$DIR/ready"
  fi
  # The S3 port answers once the layout is live.
  for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.2
  done
  echo "Garage $VERSION on http://127.0.0.1:$PORT, bucket $BUCKET"
}

stop() {
  if running; then
    kill "$(cat "$DIR/pid")"
    for _ in $(seq 50); do running || break; sleep 0.1; done
  fi
  rm -f "$DIR/pid"
}

case ${1:-} in
  start) start ;;
  stop) stop ;;
  wipe) stop; rm -rf "$DIR/meta" "$DIR/data" "$CONF" "$DIR/ready" ;;
  env)
    echo "export GARAGE_TEST_ENDPOINT=http://127.0.0.1:$PORT"
    echo "export GARAGE_TEST_REGION=garage"
    echo "export GARAGE_TEST_BUCKET=$BUCKET"
    echo "export GARAGE_TEST_ACCESS_KEY_ID=$KEY_ID"
    echo "export GARAGE_TEST_SECRET_ACCESS_KEY=$SECRET"
    ;;
  garage) shift; garage "$@" ;;
  *) echo "usage: $0 start|stop|wipe|env|garage ARGS" >&2; exit 2 ;;
esac
