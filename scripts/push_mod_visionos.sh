#!/usr/bin/env bash
# Pushes a mod checkout (or a ROM, or a .sav) straight into the installed
# visionOS app's data container, without rebuilding or reinstalling anything.
#
# Usage: scripts/push_mod_visionos.sh [--rom FILE] [--file FILE] [--launch] [MOD_DIR]
#
#   MOD_DIR        a mod checkout to push, e.g. ../DramaticShapeVoxelMod
#                  (its manifest.json "id" decides the destination folder)
#   --rom FILE     push a .gb/.gbc into Documents/ for the importer to pick up
#   --file FILE    push any file into Documents/ (mod .zip, .sav, ...)
#   --launch       relaunch the app afterwards with its stdout on this terminal
#
# Why this exists: iterating on 41k lines of Lua through a full xcodebuild
# cycle is intolerable, and the mod is deliberately NOT fused into game.love
# (a mod in the read-only bundle cannot be deleted by the in-game mod manager
# and reappears on every launch). devicectl writes into the same save directory
# the mod manager already scans, so a changed .lua is live in seconds.
#
# There is no Finder-over-USB path to a Vision Pro, which is also why this is
# the ergonomic way to get a ROM onto the device.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

BUNDLE_ID="${GEN1_VISIONOS_BUNDLE_ID:-com.gen1recomp.xr}"
# Must match conf.lua's t.identity -- that is what LÖVE appends to the app's
# Documents dir to form the save directory.
IDENTITY="${POKEPORT_IDENTITY:-pokemon-love2d}"

MOD_DIR=""; ROM=""; EXTRA=""; LAUNCH=false
while [ $# -gt 0 ]; do
  case "$1" in
    --rom)    shift; ROM="${1:-}" ;;
    --file)   shift; EXTRA="${1:-}" ;;
    --launch) LAUNCH=true ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *)        MOD_DIR="$1" ;;
  esac
  shift
done

DEVICE="${GEN1_VISIONOS_DEVICE:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun devicectl list devices -j /dev/stdout 2>/dev/null | python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)["result"]["devices"]
except Exception:
    raise SystemExit(0)
def rank(d):
    return 0 if d.get("connectionProperties", {}).get("tunnelState") == "connected" else 1
cands = [d for d in devices
         if d.get("hardwareProperties", {}).get("platform") == "visionOS"
         and d.get("hardwareProperties", {}).get("reality") == "physical"]
if cands:
    print(sorted(cands, key=rank)[0]["identifier"])
')"
fi
[ -n "$DEVICE" ] || fail "no paired Apple Vision Pro found (set GEN1_VISIONOS_DEVICE)"

push() {
  local src="$1" dst="$2"
  say "$(basename "$src") -> $dst"
  xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "$src" --destination "$dst" >/dev/null \
    || fail "copy failed. Is the app installed and the headset awake?"
}

if [ -n "$MOD_DIR" ]; then
  [ -f "$MOD_DIR/manifest.json" ] || fail "$MOD_DIR has no manifest.json"
  MOD_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$MOD_DIR/manifest.json")"
  [ -n "$MOD_ID" ] || fail "could not read the mod id out of $MOD_DIR/manifest.json"
  push "$MOD_DIR" "Documents/$IDENTITY/mods/$MOD_ID"
fi

# The ROM and any loose file land in Documents/, where GRBootstrap's
# activation sweep moves them into the save dir on the next foreground --
# the same path the iOS build already uses. Nothing here ever enters the repo.
[ -n "$ROM" ]   && { [ -f "$ROM" ]   || fail "no such file: $ROM";   push "$ROM" "Documents/"; }
[ -n "$EXTRA" ] && { [ -f "$EXTRA" ] || fail "no such file: $EXTRA"; push "$EXTRA" "Documents/"; }

[ -n "$MOD_DIR$ROM$EXTRA" ] || fail "nothing to push (try --help)"

if $LAUNCH; then
  say "relaunching $BUNDLE_ID (ctrl-C detaches; the app keeps running)"
  xcrun devicectl device process launch --device "$DEVICE" \
    --terminate-existing --console "$BUNDLE_ID"
fi

say "done"
