#!/bin/sh
# Starts the Herdr Island daemon if it is not running, then forwards an optional command
# (toggle, open, close, settings, cycle-mode, mode:notch|menubar|both|auto, reload) to it.
DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$HOME/.local/state/herdr-island"
PID_FILE="$STATE/daemon.pid"
mkdir -p "$STATE"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  [ -n "$1" ] && "$DIR/herdr-island" "$1"
  exit 0
fi

[ -x "$DIR/herdr-island" ] || { echo "herdr-island is not built; run: swiftc -O src/*.swift -o bin/herdr-island" >&2; exit 1; }
nohup "$DIR/herdr-island" "$@" >>"$STATE/daemon.log" 2>&1 &
exit 0
