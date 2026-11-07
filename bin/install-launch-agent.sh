#!/bin/sh
# For the Herdr desktop app, which has no plugin hooks to start the island: builds it,
# points it at the app (`[connection] backend = "app"`) and registers a LaunchAgent that
# starts it at login and again after a crash (`herdr-island quit` keeps it stopped).
#
#   bin/install-launch-agent.sh              install, or update after `git pull`
#   bin/install-launch-agent.sh --uninstall  remove the LaunchAgent (the build and config stay)
set -eu

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/herdr-island"
LABEL="com.speardragon.herdr-island"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/.local/state/herdr-island"
CONFIG="$HOME/.config/herdr/plugins/config/speardragon.herdr-island/config.toml"
DOMAIN="gui/$(id -u)"

say() { printf '%s\n' "$*"; }
die() { printf 'herdr-island: %s\n' "$*" >&2; exit 1; }
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Builds beside the binary and swaps it in, so a running island keeps its own copy.
build() {
  command -v swiftc >/dev/null 2>&1 || die "swiftc not found; install Xcode Command Line Tools: xcode-select --install"
  say "Building $BIN …"
  swiftc -O -suppress-warnings "$DIR"/src/*.swift -o "$BIN.new" || { rm -f "$BIN.new"; die "build failed"; }
  mv -f "$BIN.new" "$BIN"
}

# Adds `backend = "app"` unless config.toml already has a [connection] section.
configure() {
  mkdir -p "$(dirname "$CONFIG")"
  if ! grep -q '^\[connection\]' "$CONFIG" 2>/dev/null; then
    printf '\n[connection]\nbackend = "app"\n' >>"$CONFIG"
    say "Set backend = \"app\" in $CONFIG"
  elif grep -Eq '^backend[[:space:]]*=[[:space:]]*"app"' "$CONFIG"; then
    say "backend is already \"app\" in $CONFIG"
  else
    say "Note: $CONFIG sets its own backend; set backend = \"app\" there to follow the Herdr app."
  fi
}

# launchd starts the island with a bare PATH, so remember where this shell finds hc.
# Prints its path (or nothing); notes go to stderr.
core_bin() {
  core="$(command -v hc 2>/dev/null || command -v herdr-core 2>/dev/null || true)"
  [ -n "$core" ] || say "Note: hc (herdr-core) is not on PATH; the island also looks in ~/.local/bin and Homebrew." >&2
  open -Ra Herdr 2>/dev/null || say "Note: the Herdr app was not found; install it before using the app backend." >&2
  printf '%s' "$core"
}

# Stops the LaunchAgent's island, and one started by hand or by a herdr TUI plugin hook.
stop_island() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pid="$(cat "$STATE/daemon.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
  "$BIN" quit
  tries=0
  while kill -0 "$pid" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -le 50 ] || die "the running island (pid $pid) did not quit"
    sleep 0.1
  done
}

write_plist() {
  core="$1"
  env=""
  if [ -n "$core" ]; then
    env="
	<key>EnvironmentVariables</key>
	<dict>
		<key>HERDR_CORE_BIN</key>
		<string>$(xml "$core")</string>
	</dict>"
  fi
  mkdir -p "$(dirname "$PLIST")" "$STATE"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml "$BIN")</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$(xml "$STATE/daemon.log")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$STATE/daemon.log")</string>$env
</dict>
</plist>
EOF
  plutil -lint -s "$PLIST" || die "wrote an invalid $PLIST"
}

start() {
  launchctl bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap failed"
  tries=0
  until launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running'; do
    tries=$((tries + 1))
    [ "$tries" -le 50 ] || die "the LaunchAgent did not start; see $STATE/daemon.log"
    sleep 0.1
  done
  say "Started $LABEL (log: $STATE/daemon.log)"
  say "Restart: launchctl kickstart -k $DOMAIN/$LABEL"
  say "Remove:  $0 --uninstall"
}

uninstall() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  say "Removed $PLIST; the island is stopped. The build and config.toml stay."
}

[ "$(uname -s)" = Darwin ] || die "macOS only"
case "${1:-}" in
  --uninstall) uninstall ;;
  "")
    build
    configure
    core="$(core_bin)"
    stop_island
    write_plist "$core"
    start
    ;;
  *) die "usage: $0 [--uninstall]" ;;
esac
