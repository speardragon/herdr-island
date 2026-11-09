#!/bin/sh
# One-line install for the Herdr desktop app: fetches the source into a fixed folder, then
# runs bin/install-launch-agent.sh from it (build, `backend = "app"`, LaunchAgent).
# Running it again updates the folder and the island.
#
#   curl -fsSL https://raw.githubusercontent.com/speardragon/herdr-island/main/bin/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/speardragon/herdr-island/main/bin/install.sh | sh -s -- --uninstall
#
# HERDR_ISLAND_DIR (default ~/.local/share/herdr-island) and HERDR_ISLAND_REPO override where
# the source lives and where it comes from. The LaunchAgent runs the island from that folder,
# so leave it in place.
set -eu

DEST="${HERDR_ISLAND_DIR:-$HOME/.local/share/herdr-island}"
REPO="${HERDR_ISLAND_REPO:-https://github.com/speardragon/herdr-island.git}"
INSTALLER="bin/install-launch-agent.sh"

say() { printf '%s\n' "$*"; }
die() { printf 'herdr-island: %s\n' "$*" >&2; exit 1; }

# Clones on the first run; later runs move the folder to the newest main.
fetch() {
  if [ ! -e "$DEST" ]; then
    say "Downloading herdr-island into $DEST …"
    mkdir -p "$(dirname "$DEST")"
    git clone --quiet --depth 1 "$REPO" "$DEST" || die "git clone $REPO failed"
    return
  fi
  [ -d "$DEST/.git" ] || die "$DEST exists but is not a herdr-island checkout; move it away or set HERDR_ISLAND_DIR"
  [ -z "$(git -C "$DEST" status --porcelain)" ] || die "$DEST has local changes; commit or discard them, then run this again"
  say "Updating $DEST …"
  git -C "$DEST" fetch --quiet --depth 1 "$REPO" main || die "git fetch $REPO failed"
  git -C "$DEST" reset --quiet --hard FETCH_HEAD
}

main() {
  [ "$(uname -s)" = Darwin ] || die "macOS only"
  # Without the Command Line Tools, `git` opens an install dialog instead of failing.
  xcode-select -p >/dev/null 2>&1 || die "install Xcode Command Line Tools first: xcode-select --install"
  case "${1:-}" in
    --uninstall)
      [ -x "$DEST/$INSTALLER" ] || die "nothing to uninstall: $DEST/$INSTALLER not found"
      ;;
    "") fetch ;;
    *) die "usage: install.sh [--uninstall]" ;;
  esac
  # Under `curl | sh` stdin is this script: keep the installer off it.
  exec "$DEST/$INSTALLER" "$@" </dev/null
}

main "$@"
