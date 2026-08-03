#!/usr/bin/env bash
# Packages gen1recomp into a visionOS app.
#
# Usage: scripts/build_visionos.sh [--fetch] [--deps] [--device|--simulator]
#                                  [--release] [--install] [--launch]
#                                  [--version X.Y.Z] [--package-only]
#
#   --fetch          fetch the pinned LÖVE sources into mobile/visionos/love-src/
#   --deps           build the xros dependency slices (see mobile/visionos/deps/)
#   --device         build for the headset (default)
#   --simulator      build for the visionOS simulator (no signing needed)
#   --release        Release configuration
#   --install        install onto the paired Vision Pro after a --device build
#   --launch         launch after installing, bridging stdout to this terminal
#   --version X.Y.Z  stamp the engine version into game.love
#   --package-only   build game.love and stop; skip xcodegen and xcodebuild
#
# Prerequisites: macOS, Xcode 27+ (visionOS SDK), xcodegen (brew install xcodegen).
#
# Output: mobile/visionos/build/Products/<Config>-<sdk>/gen1recomp.app
#         dist/visionos/gen1recomp.ipa   (device builds)
#
# See mobile/visionos/README.md -- especially the DEVELOPER_DIR/PATH note, which
# is the most common way to build this against the wrong SDK without noticing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VISIONOS_DIR="$ROOT/mobile/visionos"
LOVE_SRC="$VISIONOS_DIR/love-src"
RESOURCES_DIR="$VISIONOS_DIR/resources"
LOVE_FILE="$RESOURCES_DIR/game.love"
BUILD_DIR="$VISIONOS_DIR/build"
DIST="$ROOT/dist/visionos"
PROJECT="$VISIONOS_DIR/gen1recomp-visionos.xcodeproj"

# The redirect, not tr, is what fails when the file is absent, so guard the
# file rather than the command.
if [ -f "$VISIONOS_DIR/LOVE_VERSION" ]; then
  LOVE_VERSION="$(tr -d '[:space:]' < "$VISIONOS_DIR/LOVE_VERSION")"
else
  LOVE_VERSION=12.0
fi
LOVE_SOURCE_REPO="https://github.com/love2d/love.git"
LOVE_SOURCE_REF="${LOVE_SOURCE_REF:-main}"
MANIFEST_BASE_URL="https://raw.githubusercontent.com/bryanthaboi/gen1recomp/dev"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- toolchain
# Setting DEVELOPER_DIR is NOT enough on its own. A normal developer PATH has
# /Applications/Xcode.app/Contents/Developer/usr/bin ahead of /usr/bin, and that
# xcodebuild uses its own bundle and ignores DEVELOPER_DIR entirely -- so you
# silently build against whatever SDK the release Xcode has. Prepending the
# selected toolchain's bin is what makes the choice stick; the assert below is
# what makes a wrong one loud instead of mysterious.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

FETCH=false; DEPS=false; DEVICE=true; RELEASE=false
INSTALL=false; LAUNCH=false; PACKAGE_ONLY=false
VERSION="${VERSION:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --fetch)        FETCH=true ;;
    --deps)         DEPS=true ;;
    --device)       DEVICE=true ;;
    --simulator)    DEVICE=false ;;
    --release)      RELEASE=true ;;
    --install)      INSTALL=true ;;
    --launch)       INSTALL=true; LAUNCH=true ;;
    --package-only) PACKAGE_ONLY=true ;;
    --version)      shift; VERSION="${1:-}" ;;
    -h|--help)      sed -n '2,26p' "$0"; exit 0 ;;
    *)              fail "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

$RELEASE && CONFIG=Release || CONFIG=Debug
$DEVICE  && SDK=xros        || SDK=xrsimulator

# Bundle-id resolution, most specific wins -- mirrors build_ios.sh's ladder.
# The per-team default exists because explicit App IDs are globally unique
# across all Apple accounts, so a fixed string would collide with anyone else
# building this.
BUNDLE_ID="${GEN1_VISIONOS_BUNDLE_ID:-}"
if [ -z "$BUNDLE_ID" ] && [ -f "$VISIONOS_DIR/bundle_id.local" ]; then
  BUNDLE_ID="$(tr -d '[:space:]' < "$VISIONOS_DIR/bundle_id.local")"
fi

DEVICE_UDID="${GEN1_VISIONOS_DEVICE:-}"

# ------------------------------------------------------------- preflight
preflight() {
  command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found"
  local ver; ver="$(xcodebuild -version | head -1)"
  xcrun --sdk xros --show-sdk-path >/dev/null 2>&1 || fail \
"$ver (at $DEVELOPER_DIR) has no visionOS SDK.
Point DEVELOPER_DIR at an Xcode that does:
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer $0"
  say "toolchain: $ver, SDK $(xcrun --sdk xros --show-sdk-version)"
  command -v xcodegen >/dev/null 2>&1 || fail \
"xcodegen not found. Install it with:
  brew install xcodegen"
}

detect_team() {
  [ -n "${DEVELOPMENT_TEAM:-}" ] && { say "signing team: $DEVELOPMENT_TEAM (from environment)"; export DEVELOPMENT_TEAM; return 0; }
  if [ -f "$VISIONOS_DIR/team.local" ]; then
    DEVELOPMENT_TEAM="$(tr -d '[:space:]' < "$VISIONOS_DIR/team.local")"
    say "signing team: $DEVELOPMENT_TEAM (from mobile/visionos/team.local)"
    export DEVELOPMENT_TEAM; return 0
  fi

  # Prefer the team seen in INSTALLED PROVISIONING PROFILES over the one in a
  # signing certificate's common name. A keychain can easily hold certificates
  # for a team that Xcode has no account for -- and when it does, the build
  # fails with the deeply unhelpful "No Account for Team XXXX" rather than
  # anything pointing at the certificate. A profile, by contrast, only exists
  # locally because Xcode downloaded it for an account you actually have.
  local profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  if [ -d "$profiles" ]; then
    DEVELOPMENT_TEAM="$(
      for p in "$profiles"/*.mobileprovision; do
        [ -e "$p" ] || continue
        security cms -D -i "$p" 2>/dev/null \
          | plutil -extract TeamIdentifier.0 raw - 2>/dev/null
      done | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'
    )"
  fi

  # Fall back to the keychain if there are no profiles yet (a fresh machine,
  # where -allowProvisioningUpdates will create the first one).
  if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
    DEVELOPMENT_TEAM="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"Apple Develop\(ment\|er\).*(\([A-Z0-9]\{10\}\))".*/\2/p' | head -1)"
  fi

  [ -n "${DEVELOPMENT_TEAM:-}" ] || fail \
"could not work out a signing team.
A device build needs a paid Apple Developer team. Set one explicitly:
  DEVELOPMENT_TEAM=XXXXXXXXXX $0 --device
or pin it for this machine:
  echo XXXXXXXXXX > mobile/visionos/team.local"
  export DEVELOPMENT_TEAM
  say "signing team: $DEVELOPMENT_TEAM"
}

# ------------------------------------------------------------- fetch/patch
fetch_love() {
  if [ -d "$LOVE_SRC/src" ] && ! $FETCH; then
    say "love-src present; skipping fetch (delete $LOVE_SRC to refresh)"
    return 0
  fi
  if [ ! -d "$LOVE_SRC/.git" ]; then
    say "fetching LÖVE $LOVE_VERSION ($LOVE_SOURCE_REF)"
    rm -rf "$LOVE_SRC"
    git clone --depth 1 --branch "$LOVE_SOURCE_REF" "$LOVE_SOURCE_REPO" "$LOVE_SRC" 2>&1 | tail -1
  fi
  [ -d "$LOVE_SRC/src" ] || fail "no src/ under $LOVE_SRC after fetch"
}

# LÖVE patches live in mobile/visionos/patches/love-*.patch. Unlike the iOS
# script, we do NOT patch love.xcodeproj -- XcodeGen owns the project, so the
# only thing to change here is source that genuinely does not compile for
# visionOS. Idempotent: an already-applied patch is a no-op, so re-running the
# build never fails on a tree left patched from last time.
patch_love() {
  local p applied=0
  shopt -s nullglob
  for p in "$VISIONOS_DIR/patches/love-"*.patch; do
    if git -C "$LOVE_SRC" apply --check -p1 "$p" >/dev/null 2>&1; then
      git -C "$LOVE_SRC" apply -p1 "$p" || fail "failed to apply $(basename "$p")"
      say "applied $(basename "$p")"
      applied=$((applied + 1))
    elif git -C "$LOVE_SRC" apply --check -R -p1 "$p" >/dev/null 2>&1; then
      applied=$((applied + 1))   # already applied
    else
      fail "$(basename "$p") neither applies nor is already applied.
LOVE_SOURCE_REF ($LOVE_SOURCE_REF) has probably moved. Rebase the patch."
    fi
  done
  shopt -u nullglob
  say "LÖVE patches: $applied applied or already present"
}

# ------------------------------------------------------------- packaging
# NOTE: manifest_paths / manifest_is_valid / ensure_manifests / pack_game_love
# below are line-for-line the same logic as scripts/build_ios.sh. They are
# duplicated rather than shared because factoring them into
# scripts/lib/love_package.sh touches build_ios.sh, and this port is trying to
# keep its diff against a fast-moving upstream purely additive. That refactor
# is worth doing as its own change.
manifest_paths() {
  python3 - "$ROOT/src/core/GameVersion.lua" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
print(" ".join(dict.fromkeys(re.findall(r'manifest\s*=\s*"([^"]+)"', src))))
PY
}

manifest_is_valid() {
  python3 - "$1" <<'PY'
import json, pathlib, sys
try:
    m = json.loads(pathlib.Path(sys.argv[1]).read_text())
except (OSError, ValueError):
    raise SystemExit(1)
sha = m.get("romSha1")
raise SystemExit(0 if isinstance(sha, str) and len(sha) == 40 else 1)
PY
}

ensure_manifests() {
  MANIFESTS="$(manifest_paths)"
  [ -n "$MANIFESTS" ] \
    || fail "could not read any manifest path out of src/core/GameVersion.lua"
  local rel staged
  for rel in $MANIFESTS; do
    if manifest_is_valid "$ROOT/$rel"; then continue; fi
    warn "$rel is missing or invalid; recovering it before packaging"
    staged="$(mktemp)"
    if git -C "$ROOT" show "HEAD:$rel" > "$staged" 2>/dev/null \
        && manifest_is_valid "$staged"; then
      mkdir -p "$ROOT/$(dirname "$rel")"
      mv "$staged" "$ROOT/$rel"
      say "restored $rel from this checkout's Git data"
      continue
    fi
    if command -v curl >/dev/null 2>&1 \
        && curl --fail --location --retry 2 --connect-timeout 15 \
            --output "$staged" "$MANIFEST_BASE_URL/$rel" \
        && manifest_is_valid "$staged"; then
      mkdir -p "$ROOT/$(dirname "$rel")"
      mv "$staged" "$ROOT/$rel"
      say "downloaded $rel from the project repository"
      continue
    fi
    rm -f "$staged"
    fail "$rel is unavailable: Git recovery failed and it could not be downloaded"
  done
  say "import manifests: $MANIFESTS"
}

pack_game_love() {
  say "packing game.love"
  mkdir -p "$RESOURCES_DIR"
  rm -f "$LOVE_FILE"
  # Same payload as scripts/build.sh / build_ios.sh, and deliberately NO fused
  # mods: a mod inside game.love sits in the read-only app bundle, so the mod
  # manager's Delete cannot remove it and it comes back every launch. Mods
  # install as .zips at runtime instead -- see scripts/push_mod_visionos.sh for
  # the fast on-device loop.
  # shellcheck disable=SC2086  # MANIFESTS is a deliberate word list
  (cd "$ROOT" && zip -q -9 -r "$LOVE_FILE" \
    main.lua conf.lua src data assets tools/save-editor \
    $MANIFESTS \
    -x '*.DS_Store' -x '*/.git/*' -x '*/.DS_Store' \
    -x 'data/generated/*' -x 'assets/generated/*')
  # >/dev/null rather than grep -q: -q exits on first match, unzip dies of
  # SIGPIPE, and pipefail turns that into a nondeterministic failure.
  if unzip -Z1 "$LOVE_FILE" \
      | grep -E '^(data|assets)/generated/[^/]+|^(data|assets)/generated/.+/' >/dev/null; then
    fail "game.love unexpectedly contains generated ROM data"
  fi
  local archive_entries required
  archive_entries="$(unzip -Z1 "$LOVE_FILE")"
  # shellcheck disable=SC2086
  for required in src/update/Boot.lua tools/save-editor/App.lua \
                  tools/save-editor/Kit.lua tools/save-editor/panels/Party.lua \
                  $MANIFESTS; do
    printf '%s\n' "$archive_entries" | grep -qx "$required" \
      || fail "game.love is missing $required"
  done
  say "game.love: $(du -h "$LOVE_FILE" | cut -f1)"

  if printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    say "stamping engine version $VERSION into game.love"
    local stamp_dir version_re
    stamp_dir="$(mktemp -d)"
    mkdir -p "$stamp_dir/src/core"
    sed -E "s/(engine[[:space:]]*=[[:space:]]*\")([^\"]*)(\")/\1$VERSION\3/" \
      "$ROOT/src/core/Version.lua" > "$stamp_dir/src/core/Version.lua"
    (cd "$stamp_dir" && zip -q "$LOVE_FILE" src/core/Version.lua)
    version_re="$(printf '%s' "$VERSION" | sed 's/\./\\./g')"
    unzip -p "$LOVE_FILE" src/core/Version.lua \
      | grep -Eq "engine[[:space:]]*=[[:space:]]*\"$version_re\"" \
      || fail "version stamp failed: game.love does not report engine $VERSION"
    rm -rf "$stamp_dir"
  fi
}

# ------------------------------------------------------------- build
generate_project() {
  say "generating Xcode project from mobile/visionos/project.yml"
  (cd "$VISIONOS_DIR" && xcodegen generate --spec project.yml >/dev/null) \
    || fail "xcodegen failed"
}

run_xcodebuild() {
  local args=(
    -project "$PROJECT"
    -scheme gen1recomp
    -configuration "$CONFIG"
    -sdk "$SDK"
    SYMROOT="$BUILD_DIR/Products"
    OBJROOT="$BUILD_DIR/Intermediates"
    ONLY_ACTIVE_ARCH=NO
  )
  [ -n "$BUNDLE_ID" ] && args+=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
  [ -n "$VERSION" ]   && args+=(MARKETING_VERSION="$VERSION")

  if $DEVICE; then
    detect_team
    # Concrete device only when we are about to install onto it; a generic
    # destination keeps the build working when the headset is asleep.
    if $INSTALL && [ -n "$DEVICE_UDID" ]; then
      args+=(-destination "platform=visionOS,id=$DEVICE_UDID")
    else
      args+=(-destination 'generic/platform=visionOS')
    fi
    args+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic
           -allowProvisioningUpdates)
  else
    args+=(-destination 'generic/platform=visionOS Simulator'
           CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-)
  fi

  say "xcodebuild ($CONFIG / $SDK)"
  local log="$BUILD_DIR/xcodebuild.log"
  mkdir -p "$BUILD_DIR"
  if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "${args[@]}" 2>&1 | tee "$log" | xcbeautify --quiet || true
  else
    xcodebuild "${args[@]}" > "$log" 2>&1 || true
  fi
  APP="$(find "$BUILD_DIR/Products/$CONFIG-$SDK" -maxdepth 1 -name 'gen1recomp.app' 2>/dev/null | head -1)"
  [ -n "$APP" ] || {
    grep -E "\berror:|ld: " "$log" | sort -u | head -20 >&2
    fail "build failed; full log at $log"
  }
  say "built $APP"
}

# A build that silently lost a patch or a framework is worse than one that
# fails, so assert on the artefact rather than trusting the exit code. Same
# reasoning as build_ios.sh's verify_native_bridge.
verify_app() {
  local bin="$APP/gen1recomp"
  [ -f "$bin" ] || fail "no executable inside $APP"
  local plat
  plat="$(vtool -show-build-version "$bin" 2>/dev/null | awk '/platform/ {print $2}')"
  case "$plat" in
    VISIONOS|VISIONOSSIMULATOR) ;;
    *) fail "$bin is platform '$plat' -- wrong SDK. Re-read the DEVELOPER_DIR note in mobile/visionos/README.md." ;;
  esac
  [ -f "$APP/game.love" ] || fail "game.love did not make it into the bundle"
  [ -d "$APP/Frameworks" ] || warn "no embedded Frameworks dir -- openal-soft should be in there"

  # Assert the Info.plist keys that make this an immersive visionOS app rather
  # than a window. Worth checking explicitly: XcodeGen's `info:` block
  # *generates* a plist at the path you give it, so pointing it at the
  # hand-written overlay silently replaced it -- and an app with no scene
  # manifest builds, installs and signs perfectly, then simply never opens its
  # immersive space. The build passing is not evidence that this survived.
  local k
  for k in UIApplicationSceneManifest GCSupportedGameControllers \
           NSWorldSensingUsageDescription NSAccessoryTrackingUsageDescription \
           NSHandsTrackingUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$k" "$APP/Info.plist" >/dev/null 2>&1 \
      || fail "$k missing from the built Info.plist.
mobile/visionos/overlays/love-visionos.plist did not reach the bundle -- check
INFOPLIST_FILE in mobile/visionos/project.yml."
  done
  /usr/libexec/PlistBuddy -c \
    'Print :UIApplicationSceneManifest:UISceneConfigurations:UISceneSessionRoleImmersiveSpaceApplication' \
    "$APP/Info.plist" >/dev/null 2>&1 \
    || fail "the bundle declares no immersive space scene role"

  say "verified: $plat, game.love present, immersive scene manifest intact"
}

resolve_device() {
  [ -n "$DEVICE_UDID" ] && return 0
  # Parse the JSON rather than the table: the human-readable columns are
  # whitespace-aligned and a device name containing spaces ("Apple Vision Pro
  # M5") shifts every positional field.
  DEVICE_UDID="$(xcrun devicectl list devices -j /dev/stdout 2>/dev/null | python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)["result"]["devices"]
except Exception:
    raise SystemExit(0)
# hardwareProperties.reality is the field that separates a real headset from
# the simulators, which share the same platform string. Prefer one that is
# actually connected -- several simulators and past pairings linger in this
# list forever.
def rank(d):
    conn = d.get("connectionProperties", {}).get("tunnelState") == "connected"
    return (0 if conn else 1)
cands = [d for d in devices
         if d.get("hardwareProperties", {}).get("platform") == "visionOS"
         and d.get("hardwareProperties", {}).get("reality") == "physical"]
if cands:
    print(sorted(cands, key=rank)[0]["identifier"])
')"
  [ -n "$DEVICE_UDID" ] || fail \
"no paired Apple Vision Pro found. Pair it in Xcode, or set one explicitly:
  GEN1_VISIONOS_DEVICE=<udid> $0 --install"
}

install_to_device() {
  resolve_device
  say "installing onto $DEVICE_UDID"
  xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" \
    || fail "install failed"
  if $LAUNCH; then
    local id; id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
    say "launching $id (--console: LÖVE's print() lands here; ctrl-C to detach)"
    xcrun devicectl device process launch --device "$DEVICE_UDID" \
      --terminate-existing --console "$id"
  fi
}

# =================================================================== main
preflight
$DEPS && "$VISIONOS_DIR/deps/build_deps.sh"
[ -d "$VISIONOS_DIR/deps/include" ] || fail \
"no dependency slices built yet. Run:
  mobile/visionos/deps/build_deps.sh"

fetch_love
patch_love
ensure_manifests
pack_game_love

if $PACKAGE_ONLY; then
  say "package-only: game.love ready at $LOVE_FILE"
  exit 0
fi

generate_project
run_xcodebuild
verify_app

if $DEVICE && $INSTALL; then
  install_to_device
fi

say "done"
