#!/usr/bin/env bash
# Builds the third-party libraries liblove needs, for visionOS.
#
# Why this script exists at all: love2d/love-apple-dependencies ships no xros
# slices. Every LibraryIdentifier in its xcframeworks is ios-*, macos-* or a
# simulator variant, and a Mach-O built for one platform is rejected by the
# linker for another -- so there is nothing in that repo we can reuse. On top
# of that, OpenAL.framework (which the iOS build links from the SDK) does not
# exist in XROS.sdk at all, so the audio backend has to be built from source
# too. See mobile/visionos/README.md.
#
# Usage: mobile/visionos/deps/build_deps.sh [--clean] [--device-only] [name ...]
#
#   (no names)      build everything listed in ../DEPS_VERSIONS
#   name ...        build only these (e.g. "luajit openal")
#   --clean         discard build trees and outputs first
#   --device-only   skip the xrsimulator slice (faster; device builds only)
#
# Output: mobile/visionos/deps/<name>.xcframework   (gitignored)
#
# Sources are cloned into mobile/visionos/deps/src/ at the refs pinned in
# ../DEPS_VERSIONS. Bumping a ref there also invalidates the CI cache.

set -euo pipefail

DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VISIONOS_DIR="$(dirname "$DEPS_DIR")"
SRC_DIR="$DEPS_DIR/src"
BUILD_DIR="$DEPS_DIR/build"
VERSIONS="$VISIONOS_DIR/DEPS_VERSIONS"

# The deployment target. Kept at 26.0 deliberately: ar_accessory_tracking (the
# PSVR2 Sense pose provider) is API_AVAILABLE(visionos(26.0)), so nothing in
# this port needs 27. Raising it would cut off devices for no gain.
XROS_MIN=26.0

# --------------------------------------------------------------- toolchain
# DEVELOPER_DIR alone is NOT enough. Xcode.app/Contents/Developer/usr/bin is
# ahead of /usr/bin in a normal user PATH, so a bare `xcodebuild` resolves to
# whatever Xcode owns that directory -- which ignores DEVELOPER_DIR and
# silently builds against the wrong SDK. Prepending the selected toolchain's
# bin is what actually makes the choice stick.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

# LuaJIT's Makefile errors out without this even when TARGET_SYS is not Darwin,
# because the host-side buildvm is a macOS binary.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

CLEAN=false
DEVICE_ONLY=false
WANTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --clean)       CLEAN=true ;;
    --device-only) DEVICE_ONLY=true ;;
    -h|--help)     sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)            fail "unknown argument: $1" ;;
    *)             WANTED+=("$1") ;;
  esac
  shift
done

command -v xcrun >/dev/null 2>&1 || fail "xcrun not found; is Xcode installed?"
xcrun --sdk xros --show-sdk-path >/dev/null 2>&1 \
  || fail "no visionOS SDK under $DEVELOPER_DIR.
Set DEVELOPER_DIR to an Xcode that has one:
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer $0"

# Each slice is (sdk, triple, xcframework-library-identifier-hint).
SLICES=("xros:arm64-apple-xros${XROS_MIN}")
$DEVICE_ONLY || SLICES+=("xrsimulator:arm64-apple-xros${XROS_MIN}-simulator")

$CLEAN && { say "cleaning"; rm -rf "$BUILD_DIR" "$DEPS_DIR"/*.xcframework; }
mkdir -p "$SRC_DIR" "$BUILD_DIR"

# --------------------------------------------------------------- sources
pin_url() { awk -v n="$1" '$1==n {print $2}' "$VERSIONS"; }
pin_ref() { awk -v n="$1" '$1==n {print $3}' "$VERSIONS"; }
pin_all() { awk '!/^#/ && NF {print $1}' "$VERSIONS"; }

fetch() {
  local name="$1" url ref dir
  url="$(pin_url "$name")"; ref="$(pin_ref "$name")"; dir="$SRC_DIR/$name"
  [ -n "$url" ] || fail "$name is not pinned in $VERSIONS"
  if [ -d "$dir/.git" ]; then
    # Already at the pinned ref? Leave it alone -- re-cloning openal-soft and
    # SDL on every run is minutes of nothing.
    if [ "$(git -C "$dir" describe --tags --always 2>/dev/null)" != "$ref" ] \
       && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$ref" ]; then
      say "$name: re-pinning to $ref"
      git -C "$dir" fetch --depth 1 origin "$ref" 2>&1 | tail -1
      git -C "$dir" checkout -q FETCH_HEAD
    fi
  else
    say "$name: cloning $ref"
    git clone --depth 1 --branch "$ref" "$url" "$dir" 2>&1 | tail -1
  fi
  apply_patches "$name"
}

# Any patches/<name>-*.patch, applied to the pinned source tree. Each one is a
# genuine upstream bug for visionOS, not a local hack -- keep them that way so
# they can be sent on and eventually deleted.
apply_patches() {
  local name="$1" dir="$SRC_DIR/$1" p
  shopt -s nullglob
  for p in "$DEPS_DIR/patches/$name"-*.patch; do
    # -N makes a re-run on an already-patched tree a no-op instead of a
    # failure, which matters because fetch() leaves the tree in place.
    if git -C "$dir" apply --check -p1 "$p" >/dev/null 2>&1; then
      say "$name: applying $(basename "$p")"
      git -C "$dir" apply -p1 "$p" || fail "$name: failed to apply $(basename "$p")"
    elif git -C "$dir" apply --check -R -p1 "$p" >/dev/null 2>&1; then
      : # already applied
    else
      fail "$name: $(basename "$p") neither applies nor is already applied.
The pinned ref in $VERSIONS probably moved. Rebase the patch."
    fi
  done
  shopt -u nullglob
}

# --------------------------------------------------------------- helpers
sdk_path() { xcrun --sdk "$1" --show-sdk-path; }

# Assemble the per-slice static libs (and headers) into one xcframework.
make_xcframework() {
  local name="$1"; shift          # remaining args: <libpath> <headersdir> pairs
  local out="$DEPS_DIR/$name.xcframework"
  rm -rf "$out"
  local args=()
  while [ $# -gt 0 ]; do
    args+=(-library "$1" -headers "$2"); shift 2
  done
  xcodebuild -create-xcframework "${args[@]}" -output "$out" >/dev/null \
    || fail "$name: -create-xcframework failed"
  say "$name -> $(basename "$out")"
  # A wrong-platform slice is the failure mode this whole script exists to
  # avoid, and -create-xcframework will happily package one. Say what landed.
  /usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$out/Info.plist" 2>/dev/null \
    | grep -E 'LibraryIdentifier|SupportedPlatform' | sed 's/^/    /' || true
}

# Verify a built object really targets visionOS. Cheap, and catches the case
# where a build system quietly ignored our flags and produced a macOS binary.
assert_platform() {
  local lib="$1" want="$2" tmp obj plat
  case "$lib" in
    *.dylib|*.so)
      plat="$(vtool -show-build-version "$lib" 2>/dev/null | awk '/platform/ {print $2}')"
      ;;
    *)
      tmp="$(mktemp -d)"
      obj="$(ar t "$lib" 2>/dev/null | grep -m1 '\.o$' || true)"
      [ -n "$obj" ] || { rm -rf "$tmp"; warn "$(basename "$lib"): no object to inspect"; return 0; }
      ( cd "$tmp" && ar x "$lib" "$obj" )
      plat="$(vtool -show-build-version "$tmp/$obj" 2>/dev/null | awk '/platform/ {print $2}')"
      rm -rf "$tmp"
      ;;
  esac
  [ "$plat" = "$want" ] \
    || fail "$(basename "$lib") is platform '$plat', expected '$want'.
The build system ignored the target triple. Do not ship this."
}

# =================================================================== luajit
# Cross-compiles with TARGET_SYS=iOS. That is correct rather than a hack:
# lj_arch.h:130 sets LJ_TARGET_IOS from TARGET_OS_IPHONE, which is 1 on
# visionOS, and the iOS branch is also what selects LJVM_MODE=machasm and
# turns the JIT off. There is no W^X exemption for third-party apps on
# visionOS, so an interpreter-only build is the only option anyway.
build_luajit() {
  fetch luajit
  local libs=()
  for slice in "${SLICES[@]}"; do
    local sdk="${slice%%:*}" triple="${slice##*:}"
    local work="$BUILD_DIR/luajit/$sdk"
    say "luajit: $triple"
    rm -rf "$work"; mkdir -p "$(dirname "$work")"
    cp -R "$SRC_DIR/luajit" "$work"
    local isdk crossbin
    isdk="$(sdk_path "$sdk")"
    crossbin="$(dirname "$(xcrun --sdk "$sdk" --find clang)")/"
    make -C "$work" -j"$(sysctl -n hw.ncpu)" \
      CC=clang \
      TARGET_SYS=iOS \
      CROSS="$crossbin" \
      TARGET_FLAGS="-isysroot $isdk -target $triple" \
      BUILDMODE=static >"$work/build.log" 2>&1 \
      || { tail -30 "$work/build.log"; fail "luajit: build failed for $triple"; }
    assert_platform "$work/src/libluajit.a" \
      "$([ "$sdk" = xros ] && echo VISIONOS || echo VISIONOSSIMULATOR)"
    # LÖVE includes <lua.h> etc. unprefixed; give the xcframework a flat
    # header dir rather than LuaJIT's src/ (which also holds .c and .h
    # internals we do not want on the include path).
    local hdr="$work/include"
    mkdir -p "$hdr"
    cp "$work/src/lua.h" "$work/src/lualib.h" "$work/src/lauxlib.h" \
       "$work/src/luaconf.h" "$work/src/luajit.h" "$hdr/"
    libs+=("$work/src/libluajit.a" "$hdr")
  done
  make_xcframework luajit "${libs[@]}"
}

# =================================================================== cmake
# Generic static-library build for the CMake-based dependencies.
#
#   cmake_dep <name> <libfile> <headers-spec> [extra -D args ...]
#
# <headers-spec> is one or more "src|dst" pairs, colon-separated, copied into
# a staging include dir; src is relative to the source tree unless it starts
# with "@", which means relative to the slice's build dir (for generated
# headers like ogg's config_types.h).
cmake_dep() {
  local name="$1" libfile="$2" headers="$3"; shift 3
  fetch "$name"
  local libs=()
  for slice in "${SLICES[@]}"; do
    local sdk="${slice%%:*}" triple="${slice##*:}"
    local work="$BUILD_DIR/$name/$sdk"
    local stage="$BUILD_DIR/_stage/$name/$sdk"
    local sysroot; sysroot="$(sdk_path "$sdk")"
    say "$name: $triple"
    rm -rf "$work" "$stage"; mkdir -p "$work" "$stage"
    # Every dep staged so far for this slice, so find_package() resolves
    # sibling deps (vorbis -> ogg, harfbuzz -> freetype) against our own
    # visionOS builds rather than whatever Homebrew has for the host.
    local prefixes=""
    if [ -d "$BUILD_DIR/_stage" ]; then
      for p in "$BUILD_DIR/_stage"/*/"$sdk"; do
        [ -d "$p" ] && prefixes="$prefixes;$p"
      done
    fi
    prefixes="${prefixes#;}"

    # CMAKE_SYSTEM_NAME=visionOS needs CMake >= 3.28; CMAKE_OSX_SYSROOT picks
    # device vs simulator. We pass the triple through the compiler flags too,
    # because several of these projects append to CMAKE_C_FLAGS in ways that
    # can drop the platform if it only came from the system name.
    cmake -S "$SRC_DIR/$name" -B "$work" \
      -DCMAKE_SYSTEM_NAME=visionOS \
      -DCMAKE_OSX_SYSROOT="$sysroot" \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$XROS_MIN" \
      -DCMAKE_C_FLAGS="-target $triple" \
      -DCMAKE_CXX_FLAGS="-target $triple" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_INSTALL_PREFIX="$stage" \
      -DCMAKE_PREFIX_PATH="$prefixes" \
      -DCMAKE_FIND_ROOT_PATH="$prefixes" \
      "$@" >"$work/configure.log" 2>&1 \
      || { tail -30 "$work/configure.log"; fail "$name: configure failed for $triple"; }

    cmake --build "$work" --config Release -j"$(sysctl -n hw.ncpu)" \
      >"$work/build.log" 2>&1 \
      || { tail -30 "$work/build.log"; fail "$name: build failed for $triple"; }

    cmake --install "$work" --config Release >"$work/install.log" 2>&1 \
      || { tail -20 "$work/install.log"; warn "$name: install failed; falling back to build tree"; }

    local lib
    lib="$(find "$stage" "$work" -name "$libfile" -type f 2>/dev/null | head -1)"
    [ -n "$lib" ] || { fail "$name: $libfile not produced under $work"; }
    assert_platform "$lib" \
      "$([ "$sdk" = xros ] && echo VISIONOS || echo VISIONOSSIMULATOR)"

    local hdr
    if [ "$headers" = "@stage" ]; then
      # The normal case now that we install: take exactly what the project
      # says its public headers are.
      hdr="$stage/include"
      [ -d "$hdr" ] || fail "$name: install produced no include/ under $stage"
    else
      hdr="$work/_include"
      rm -rf "$hdr"; mkdir -p "$hdr"
      local spec src dst base
      IFS=':' read -ra spec <<<"$headers"
      for pair in "${spec[@]}"; do
        src="${pair%%|*}"; dst="${pair##*|}"
        if [[ "$src" == @* ]]; then base="$work"; src="${src#@}"; else base="$SRC_DIR/$name"; fi
        mkdir -p "$hdr/$(dirname "$dst")"
        cp -R "$base/$src" "$hdr/$dst"
      done
    fi
    libs+=("$lib" "$hdr")
  done
  make_xcframework "$name" "${libs[@]}"
}

build_ogg() {
  cmake_dep ogg libogg.a @stage -DINSTALL_DOCS=OFF -DBUILD_TESTING=OFF
}

build_vorbis() {
  # Depends on ogg, resolved from the staged xros build via CMAKE_PREFIX_PATH.
  build_ogg_if_missing
  cmake_dep vorbis libvorbis.a @stage -DINSTALL_DOCS=OFF -DBUILD_TESTING=OFF
}

build_freetype() {
  # No HarfBuzz/Brotli/PNG/BZip2/zlib back-references. LÖVE only needs glyph
  # rasterisation, and each optional dep would otherwise need its own xros
  # slice. Note this is also what breaks the freetype<->harfbuzz cycle: we
  # build freetype first without harfbuzz, then harfbuzz against it.
  cmake_dep freetype libfreetype.a @stage \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
    -DFT_DISABLE_PNG=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_ZLIB=ON
}

build_harfbuzz() {
  build_freetype_if_missing
  cmake_dep harfbuzz libharfbuzz.a @stage \
    -DHB_HAVE_FREETYPE=ON -DHB_HAVE_CORETEXT=OFF \
    -DHB_HAVE_GLIB=OFF -DHB_HAVE_ICU=OFF -DHB_BUILD_TESTS=OFF \
    -DHB_BUILD_SUBSET=OFF -DHB_BUILD_UTILS=OFF
}

build_sdl3() {
  # LÖVE 12 uses SDL3 for events, timer, joystick, mouse, touch and (on the
  # flat build) the window. The immersive build still wants everything except
  # video, so this is not optional.
  #
  # SDL_UNIX_CONSOLE_BUILD is off and the Apple backends stay on; the pieces
  # that have no visionOS equivalent (OpenGL, Vulkan surface creation) are
  # disabled explicitly rather than left to autodetection, because SDL's
  # configure happily enables an OpenGL renderer whose headers are marked
  # API_UNAVAILABLE(visionos) and only fails at link time.
  cmake_dep sdl3 libSDL3.a @stage \
    -DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF -DSDL_VULKAN=OFF -DSDL_RENDER_VULKAN=OFF
}

build_openal() {
  # OpenAL.framework is absent from XROS.sdk (it exists in iPhoneOS.sdk), so
  # unlike the iOS build this must come from source.
  #
  # Built SHARED on purpose. openal-soft is LGPL-2.1: statically linking it
  # into a signed, provisioned .app would put us under the section-6
  # relinking obligation, which is genuinely awkward for a sandboxed bundle.
  # A dynamic framework the user can swap satisfies the same obligation the
  # way LÖVE already does on Windows and Linux. It gets an Embed Frameworks
  # phase in mobile/visionos/project.yml.
  # The glob picks the real versioned file rather than the libopenal.dylib
  # symlink beside it; its install_name is already @rpath/libopenal.1.dylib,
  # which is what the app's Embed Frameworks phase needs.
  cmake_dep openal 'libopenal.*.dylib' @stage \
    -DBUILD_SHARED_LIBS=ON \
    -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
    -DALSOFT_INSTALL_EXAMPLES=OFF -DALSOFT_INSTALL_UTILS=OFF \
    -DALSOFT_BACKEND_COREAUDIO=ON -DALSOFT_REQUIRE_COREAUDIO=ON
}

# Small guards so `build_deps.sh vorbis` alone still works.
build_ogg_if_missing()      { [ -d "$DEPS_DIR/ogg.xcframework" ]      || build_ogg; }
build_freetype_if_missing() { [ -d "$DEPS_DIR/freetype.xcframework" ] || build_freetype; }

# =================================================================== main
# Order matters: dependents come after what they link against, so the staged
# prefixes exist when find_package() runs.
BUILDERS_AVAILABLE="luajit ogg vorbis freetype harfbuzz sdl3 openal"

build_one() {
  local name="$1"
  case " $BUILDERS_AVAILABLE " in
    *" $name "*) "build_$name" ;;
    *) warn "$name: no builder implemented yet -- skipping"; return 0 ;;
  esac
}

if [ ${#WANTED[@]} -eq 0 ]; then
  while read -r n; do WANTED+=("$n"); done < <(pin_all)
fi

for n in "${WANTED[@]}"; do build_one "$n"; done

say "done. xcframeworks in $DEPS_DIR"
ls -1d "$DEPS_DIR"/*.xcframework 2>/dev/null | sed 's/^/    /' || warn "nothing built"
