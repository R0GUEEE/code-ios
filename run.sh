#!/bin/sh
# Boot the prototype workbench.  Usage: ./run.sh [--selftest] [--no-coi]
set -e
cd "$(dirname "$0")"
ROOT=node_modules/vscode-web/dist
EXT=$PWD/extensions
WS=$PWD/demo-workspace
PORT=${PORT:-8920}

# never leave a stale listener behind (a dead server holding the port silently
# swallows every request and makes the bridge look broken)
pkill -9 -f "tools/server.py" 2>/dev/null || true
sleep 1

exec python3 tools/server.py \
  --root "$ROOT" \
  --port "$PORT" \
  --allow "$PWD" \
  --ext "$EXT" \
  --folder "$WS" \
  "$@"
