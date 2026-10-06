# Installing Gen1 Vision on Apple Vision Pro

Gen1 Vision is the Apple Vision Pro build of this fork of [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp), a native LÖVE recreation of Poke Red, Blue and Yellow: the engine and map behaviour are hand-written Lua, and the game data and graphics are decoded from a ROM you supply. On visionOS, LÖVE 12 runs on Metal behind a native SwiftUI launcher, and the game renders through Compositor Services in a fully immersive space. This guide covers the `visionos-foveation` branch; [mobile/visionos/README.md](mobile/visionos/README.md) has the details.

## What you need

- A Mac with Xcode 27 or later (for the visionOS SDK), `xcodegen` (`brew install xcodegen`), CMake and Python 3
- A paid Apple Developer team to sign with; the script says a device build needs one
- Apple Vision Pro on visionOS 26.0 or later
- A Bluetooth game controller. Without the separate voxel mod described under *Notes*, hand gestures don't control the game.
- Your own US Poke Red, Blue or Yellow ROM (`.gb` / `.gbc`)

## Your game files

Nothing from the game is in this repository or the app. The importer reads your ROM, verifies it and builds the game's data from it. Only the canonical 1 MiB US ROMs are accepted, checked by SHA-1:

- Red: `ea9bcae617fdf159b045185467ae58b2e4a48b9a`
- Blue: `d7037c83e1ae5b39bde3c30787637ba1d4c48ce2`
- Yellow: `cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1`

1. Put your ROM somewhere the visionOS file picker can reach.
2. Open Gen1 Vision. In the launcher, choose **Import ROM…** on that game's row and pick the file. The app copies it into the game's save folder, where the engine verifies and decodes it.
3. Once the game is ready, choose **Play in VR**.

## Install

There's no prebuilt app or public TestFlight link; build it from source as below.

## Build from source

Start from a checkout of the `visionos-foveation` branch. The scripts use the Xcode at `/Applications/Xcode-beta.app` unless you set `DEVELOPER_DIR`, so point that at an Xcode 27 or later with the visionOS SDK, for example:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

 The README's first note explains why the scripts also put that Xcode's tools first on `PATH`.

1. Build the visionOS dependency slices once (about four minutes cold, cached after that):

   ```bash
   mobile/visionos/deps/build_deps.sh
   ```

2. Choose a bundle identifier of your own, since the immersive target ships with `de.martek.gen1vision`. Set it for the build, or save it in `mobile/visionos/bundle_id.local`:

   ```bash
   export GEN1_VISIONOS_BUNDLE_ID=com.example.yourname.gen1vision
   ```

3. Build the immersive app. The first run fetches the LÖVE sources; after that, build, install it on your paired Vision Pro and launch it:

   ```bash
   scripts/build_visionos.sh --immersive --fetch
   scripts/build_visionos.sh --immersive --device --install --launch
   ```

   The script works out your signing team from your installed provisioning profiles or signing certificates; set `DEVELOPMENT_TEAM`, or save it in `mobile/visionos/team.local`, to choose one. It installs on the paired Vision Pro it finds, or on the one you name in `GEN1_VISIONOS_DEVICE`. `--launch` streams the app's output to your terminal, and the headset has to be awake and worn for the launch to go through; without it, open Gen1 Vision from the Home View.

Without `--immersive`, the script builds Pocket Sim 2D instead: the game in an ordinary window in the Shared Space. The README describes it as a check of the toolchain rather than the goal of the port.

## Notes

- Play with a game controller. The app's Controls help also lists hand and table gestures; those come from the voxel mod.
- The two 3D views the launcher's View row switches between, standing in the world (First Person) or seeing it as a model on a table (Third Person), come from a separate voxel mod that this repository doesn't include. `build_visionos.sh` packs it into the app when a checkout of it sits next to this one as `../DramaticShapeVoxelMod`, and skips it otherwise; without it, the game shows on a world-locked panel in the immersive space. The launcher's optional Pokémon Stadium import builds battle models for that mod.
- The launcher also keeps each game's saves: start a new one, import one, edit it in the save editor, or delete it.
