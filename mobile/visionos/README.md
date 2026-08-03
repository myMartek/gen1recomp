# gen1recomp on visionOS

A fully immersive Apple Vision Pro build: the game's world is rendered in
stereo through CompositorServices instead of into a flat window, driven by
head tracking and PlayStation VR2 Sense controllers.

This directory is the visionOS sibling of `mobile/ios/`. It follows the same
shape — a pinned LÖVE source tree fetched on demand, a patch script that
injects native code into it, an overlay plist, and a build script — so if you
have worked on the iOS build, nothing here should surprise you.

---

## Read this first: three things that will waste your afternoon

### 1. `DEVELOPER_DIR` alone does not switch Xcode

visionOS needs Xcode 27 (beta at time of writing). Setting `DEVELOPER_DIR` is
**not sufficient**, because a normal developer's `PATH` contains

    /Applications/Xcode.app/Contents/Developer/usr/bin

*ahead of* `/usr/bin`. A bare `xcodebuild` therefore resolves to a binary
inside whichever Xcode owns that directory, and that binary uses its own
bundle and ignores `DEVELOPER_DIR` entirely:

```
$ DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -version
Xcode 26.6                 # wrong — PATH-resolved binary

$ DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer /usr/bin/xcodebuild -version
Xcode 27.0                 # correct — /usr/bin shim honours DEVELOPER_DIR
```

Every script here exports `DEVELOPER_DIR` **and** prepends
`$DEVELOPER_DIR/usr/bin` to `PATH`, then asserts the resulting version. If you
run tools by hand, do the same.

### 2. `love.system.getOS()` returns `"iOS"` on visionOS, on purpose

`TARGET_OS_IPHONE` is 1 on visionOS, so liblove defines `LOVE_IOS` and the OS
string stays `"iOS"`. We deliberately did **not** change this, because every
existing `getOS() == "iOS"` branch in the engine and in the voxel mod is
exactly the behaviour visionOS wants:

| site | what the iOS branch does | right for visionOS? |
|---|---|---|
| `conf.lua` | selects LÖVE 12.0 | yes |
| `ShadowMap.lua` | disables the shadow-map pass | yes (and revisit on M5) |
| `TerrainAtlas.lua`, `BattlePics.lua` | forces `dpiscale = 1` on canvases | yes |
| `Renderer.lua` | Metal canvas-origin handling | yes |

Changing the string would mean auditing and re-branching all of them for no
gain. **The discriminator for "this is the immersive visionOS build" is
`love.xr ~= nil`, never the OS string.** If you find yourself writing
`getOS() == "visionOS"`, you are on the wrong path.

### 3. `love-apple-dependencies` is useless here

Every `LibraryIdentifier` in that repo's xcframeworks is `ios-*`, `macos-*` or
a simulator variant. A Mach-O built for one platform is rejected by the linker
for another, so there is nothing to reuse — and `OpenAL.framework`, which the
iOS build links straight from the SDK, **does not exist in `XROS.sdk` at
all**. `deps/build_deps.sh` builds the whole set from source instead. Budget
about four minutes for a cold run.

---

## Building

```bash
# one-time: build the visionOS dependency slices (~4 min cold, cached after)
mobile/visionos/deps/build_deps.sh

# then
scripts/build_visionos.sh --fetch          # first run only: fetch LÖVE sources
scripts/build_visionos.sh --device --install --launch
```

`--flat` builds the non-immersive variant: an ordinary SDL3 window in the
Shared Space. It is not the goal of this port, but it exercises the entire
toolchain — dependencies, liblove, `game.love` packaging, signing, install,
ROM import — without any Metal or CompositorServices code involved, so it is
the right thing to reach for when a build breaks and you want to know whether
the problem is the immersive layer or something underneath it.

## Where this has got to

Working and verified in the simulator:

- All dependencies built for `xros` from source, reproducibly.
- LÖVE 12 on Metal, running **headless**: no window, no layer, every frame in
  an offscreen "virtual screen" texture.
- A SwiftUI shell that switches between a flat window and a fully immersive
  space **at runtime**, closes the window while immersed, brings it back by
  any route out (including a Digital Crown press), and remembers the mode
  across launches.
- ARKit head tracking with per-eye view and projection matrices, drawing the
  virtual screen as a **world-locked panel**.
- `metal::Texture` can adopt a texture it did not create — compiled, not yet
  exercised.

So the game is visible in VR, but as a flat panel. The voxel mod is not
running yet.

### The next step, and the decision it turns on

To get real stereo, the mod's existing per-eye path (`VoxelScene.render`'s
`eyes` argument, `VRRig`, `Mat4.fovProjection`) has to draw into the
CompositorServices drawables. That needs a `love.xr` Lua module exposing
`beginFrame` / `views` / `eyeCanvas` / `submitFrame`.

The real question is **who drives the frame loop**. Today `GRImmersiveRenderer`
owns it on its own thread and LÖVE runs independently. For per-eye rendering
that has to invert: LÖVE's frame must happen *inside* a CompositorServices
frame, so that the eye matrices it renders with are the ones the frame is
submitted against. Anything else renders with stale head pose.

That means Lua calls `love.xr.beginFrame()`, which blocks until the compositor
is ready — i.e. the Swift render loop goes away and the layer renderer is
handed to LÖVE's thread instead. It is a clean change but not a small one, and
it replaces something that currently works, so it wants doing deliberately
rather than at the end of a long session.

## Testing without the headset

The simulator is worth using even though it cannot show stereo: launching on a
real Vision Pro requires it to be **awake and worn**, so an unattended
`devicectl device process launch` just hangs. The simulator has no such
constraint, and in practice it has caught more than the device build did.

```bash
mobile/visionos/deps/build_deps.sh          # once
scripts/build_visionos.sh --simulator

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
for rt,ds in json.load(sys.stdin)["devices"].items():
    if "xrOS" in rt:
        print(next(d["udid"] for d in ds if d["isAvailable"])); break')
xcrun simctl boot "$UDID"
xcrun simctl install "$UDID" mobile/visionos/build/Products/Debug-xrsimulator/gen1recomp.app
xcrun simctl launch --console-pty "$UDID" com.gen1recomp.xr
```

What the simulator gives you:

- **stdout**, so LÖVE's `print()` and `src/core/Logger.lua` are visible.
- **Crash reports** in `~/Library/Logs/DiagnosticReports/gen1recomp-*.ips`,
  with a symbolicated backtrace — this is how the openal semaphore abort was
  found.
- **lldb.** `xcrun simctl launch --wait-for-debugger` prints the pid; attach
  with `xcrun lldb -p <pid>` and `breakpoint set --name __cxa_throw` to catch
  the exact throw site of an exception that escapes a `noexcept` boundary.
- **Environment variables**, via the `SIMCTL_CHILD_` prefix — e.g.
  `SIMCTL_CHILD_ALSOFT_LOGLEVEL=3` for openal-soft's own diagnostics, or
  `SIMCTL_CHILD_ALSOFT_DRIVERS=null` to take the audio backend out of the
  picture.
- **The system log**, which is where the interesting non-stdout facts live:
  `xcrun simctl spawn "$UDID" log show --last 3m --predicate 'process == "gen1recomp"' --style compact`
  shows Metal/IOSurface setup, RealityKit compositing, and the
  GameController framework enumerating connected devices.

- **Screenshots that really do show the app**: `xcrun simctl io <udid>
  screenshot out.png` composites the app's window into the simulated room. If
  you get a picture of the room with no window in it, that is a genuine
  finding, not a limitation of the tool — build the throwaway SwiftUI
  hello-world below to prove the difference before believing anything else.

What it does not give you: stereo, hand tracking, or PSVR2 Sense support.
Those need the headset.

### When the app runs but shows nothing

Worth its own note, because it happened and nothing logged an error. A
`UIApplicationSceneManifest` in Info.plist switches UIKit to the scene-based
lifecycle. SDL3 owns `@main` in the flat build and creates its window through
the legacy `UIApplicationDelegate` path, so with a manifest present its
`UIWindow` is never attached to a window scene: the process runs, LÖVE boots,
Metal allocates a surface, and there is simply no window. That is why the flat
and immersive builds carry different plists.

The cheapest way to tell "broken app" from "broken environment" is a
throwaway app that cannot be wrong:

```swift
import SwiftUI
@main struct HelloApp: App {
    var body: some Scene { WindowGroup { Color.red.frame(width: 900, height: 500) } }
}
```

If that shows and yours does not, the problem is your app.

A quick way to bisect a startup failure without rebuilding: patch `conf.lua`
inside the packed `game.love` and re-install. `t.modules.audio = false` is how
the openal crash was confirmed to be audio in about a minute.

## Dependencies

Pinned in [`DEPS_VERSIONS`](DEPS_VERSIONS); the hash of that file is also the
CI cache key for `deps/`.

| library | why | notes |
|---|---|---|
| LuaJIT | LÖVE's Lua; the voxel mod is LuaJIT-flavoured and uses `ffi` | Built with `TARGET_SYS=iOS`. That is correct rather than a workaround: `lj_arch.h:130` derives `LJ_TARGET_IOS` from `TARGET_OS_IPHONE`, and the iOS branch is what selects `LJVM_MODE=machasm` and disables the JIT. There is no W^X exemption for third-party apps on visionOS, so interpreter-only is the only option regardless. |
| openal-soft | `OpenAL.framework` is absent from `XROS.sdk` | Built **shared** and embedded. openal-soft is LGPL-2.1; static-linking it into a signed bundle would incur a section-6 relinking obligation. A swappable dynamic framework satisfies the licence the same way LÖVE already does on Windows and Linux. |
| SDL3 | events, timer, joystick, mouse, touch (and the window, in `--flat`) | OpenGL/GLES/Vulkan explicitly disabled — GLES headers in `XROS.sdk` are all `API_UNAVAILABLE(visionos)`, and SDL's autodetection will otherwise enable a renderer that only fails at link time. |
| FreeType | `love.graphics.newFont` | HarfBuzz/Brotli/PNG/BZip2/zlib back-references disabled; that is also what breaks the FreeType↔HarfBuzz cycle. |
| HarfBuzz | text shaping | built against our FreeType slice |
| ogg, vorbis | audio decoding | |

Two dependencies need source patches, both in `deps/patches/` and both genuine
upstream visionOS bugs rather than local hacks — they are written to be
sendable upstream and deleted afterwards. Both have the same root cause:
`TARGET_OS_IOS` is **0** on visionOS (only `TARGET_OS_IPHONE` is 1), so guards
written as "iOS or tvOS, else desktop macOS" silently take the macOS branch.

Nothing built here is committed. Beyond size, committing third-party binaries
would pull in a per-library `THIRD_PARTY_NOTICES` obligation that building
from source avoids entirely.

## The ROM

This build contains no ROM and no generated game data, and none may ever be
committed — see the guards in the repo's `.gitignore`. Supply your own
legally-obtained Game Boy cartridge dump. There is no Finder-over-USB path to
a Vision Pro, so the ergonomic route is to push it into the app's data
container:

```bash
xcrun devicectl device copy to --device "$DEV" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source ~/roms/pokemon-red.gb --destination Documents/
```

`GRBootstrap.m` sweeps `.gb/.gbc/.zip/.sav` out of `Documents/` on the next
activation and `src/import/RomImporter.lua` verifies its SHA-1, exactly as on
iOS. The in-app file importer works too.

## Logs

```bash
# the app's stdout — LÖVE's print() and src/core/Logger.lua land here
xcrun devicectl device process launch --device "$DEV" \
  --terminate-existing --console "$BUNDLE_ID"

# system-side: Metal validation, CompositorServices state, ARKit auth denials
log stream --device-name 'Apple Vision Pro M5' \
  --predicate 'subsystem == "com.gen1recomp.xr"' --level debug
```

`devicectl` has no log-stream subcommand; `log stream` or Console.app is the
only route to OSLog.
