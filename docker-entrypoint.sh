#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
API_PORT=${API_PORT:-8080}
WEB_PORT=${WEB_PORT:-3000}
NODE_BIN=${NODE_BIN:-node}

cd "$ROOT"
PORT="$API_PORT" "$ROOT/server" &
API_PID=$!

cd "$ROOT/web"
HOSTNAME=${HOSTNAME:-0.0.0.0} PORT="$WEB_PORT" API_BASE_URL="http://127.0.0.1:$API_PORT" "$NODE_BIN" server.js &
WEB_PID=$!

shutdown() {
  trap - INT TERM
  kill -TERM "$API_PID" "$WEB_PID" 2>/dev/null || true
  wait "$API_PID" 2>/dev/null || true
  wait "$WEB_PID" 2>/dev/null || true
  exit 0
}

trap shutdown INT TERM

while kill -0 "$API_PID" 2>/dev/null && kill -0 "$WEB_PID" 2>/dev/null; do
  sleep 1
done

kill -TERM "$API_PID" "$WEB_PID" 2>/dev/null || true
wait "$API_PID" 2>/dev/null || true
wait "$WEB_PID" 2>/dev/null || true
exit 1
