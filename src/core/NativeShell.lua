-- NativeShell: the launcher, when the launcher is not ours to draw.
--
-- On visionOS the player is in a headset, and a 160x144 arcade panel rendered
-- into a floating quad is a worse way to pick a game than a window the system
-- already knows how to place, focus and read aloud. So the SwiftUI shell draws
-- the launcher there, and this stands in its place on the Lua side.
--
-- WHAT IT IS NOT is a second launcher. src/import/RomImporter.lua stays the
-- authority on which games are importable and ready, and src/mods/LauncherMods
-- on what mods exist and which are on; both are asked, neither is
-- reimplemented. Duplicating "is this ROM imported" in Swift would mean two
-- answers to one question, and they would drift the first time the cache
-- layout moved.
--
-- The transport is two small JSON files in the save directory rather than a C
-- bridge, and that is deliberate:
--
--   * Both sides already have the save directory -- Lua through
--     love.filesystem, Swift through the app container. Nothing new has to be
--     linked, and nothing new can go wrong at load time.
--   * A bridge would have to be called from the native thread while LOVE is
--     mid-frame on its own. Every C entry point that reads Lua state needs a
--     lock or a queue; a file needs neither, because each side only ever reads
--     what the other has finished writing.
--   * It is inspectable. `devicectl device copy from` prints the launcher's
--     entire state, which is worth a great deal on a device with no debugger
--     attached.
--
-- The cost is latency (one poll interval, below) and a small write when
-- something changes. For a menu, neither matters.

local Json = require("src.link.Json")
local Logger = require("src.core.Logger")

local NativeShell = {}

-- What Lua publishes for the shell to draw.
local STATE_FILE = "native_shell.json"
-- What the shell asks Lua to do. Consumed (deleted) once applied, so a command
-- is acted on exactly once however long the shell takes to notice.
local COMMAND_FILE = "native_shell_cmd.json"

-- The games the launcher offers, in its column order.
local VERSIONS = { "red", "blue", "yellow" }
local TITLES = { red = "Pokémon Red", blue = "Pokémon Blue", yellow = "Pokémon Yellow" }

-- Polled rather than watched: love.filesystem has no change notification, and
-- at a tenth of a second a button press feels immediate while costing one
-- stat() per tick.
local POLL_INTERVAL = 0.1

local bootGame = nil
local timer = 0
local lastPublished = nil
-- The file the last export produced, for the window to hand to a share sheet.
local exportFile = nil

-- ---------------------------------------------------------------- settings
--
-- The subset of OPTIONS that means anything before a game exists.
--
-- src/ui/OptionsMenu.lua's rows are descriptors over a loaded `game`
-- (g.save.options), so they cannot be driven from here. What CAN be is the
-- arithmetic behind them: Performance.cycle, FrameCap.cycle, GameSpeed.cycle
-- and PaletteFX's mode list are pure functions of the value, and every one of
-- these settings lives in the global options file that SaveData.loadOptions
-- already reads.
--
-- So the choice lists are DERIVED, not copied: cycle() is walked until it
-- returns to where it started, which means adding a performance tier or an
-- fps step upstream shows up here with no change. Only the two ladders whose
-- tables are local to OptionsMenu (text speed, and the 0-7 volumes) are
-- written out, and those are three and eight values that have not moved since
-- the ROM.
--
-- Battle-shape rows (BATTLE LAYOUT/SIZE/BG, UI LAYOUT, VOID FILL) and the
-- video rows are deliberately absent: they are about a flat window, and this
-- build has none.
local SETTINGS

local function cycleChoices(cycle, labelFor, start)
  local seen, out = {}, {}
  local v = start
  -- Bounded: a cycle that never returns to its start is a bug upstream, and
  -- this should degrade to a short list rather than hang the launcher.
  for _ = 1, 32 do
    local key = tostring(v)
    if seen[key] then break end
    seen[key] = true
    out[#out + 1] = { value = v, label = tostring(labelFor(v)) }
    local ok, nextV = pcall(cycle, v, 1)
    if not ok then break end
    v = nextV
  end
  -- A cycle's order is wherever the walk started -- fpsCap came out as
  -- 60, 75, ... 160, 30, 40, 50, which is right for Left/Right stepping and
  -- wrong for a menu someone reads top to bottom. Purely numeric ladders sort;
  -- named ones (AUTO/HIGH/BALANCED/LOW) keep the engine's order, which is
  -- meaningful.
  local allNumbers = #out > 0
  for _, c in ipairs(out) do
    if type(c.value) ~= "number" then allNumbers = false break end
  end
  if allNumbers then
    table.sort(out, function(a, b) return a.value < b.value end)
  end
  return out
end

local function buildSettings()
  if SETTINGS then return SETTINGS end
  local ok, built = pcall(function()
    local Performance = require("src.core.Performance")
    local FrameCap = require("src.core.FrameCap")
    local GameSpeed = require("src.core.GameSpeed")
    local PaletteFX = require("src.render.PaletteFX")

    local vols = {}
    for i = 0, 7 do vols[#vols + 1] = { value = i, label = tostring(i) } end

    local colors = {}
    for _, m in ipairs(PaletteFX.MODES) do
      colors[#colors + 1] = { value = m, label = tostring(PaletteFX.modeLabel(m)) }
    end

    -- ON A HEADSET THERE IS ONE SETTING.
    --
    -- The rest of this list is about a flat window on a desk -- text speed,
    -- battle style, palettes, frame caps -- and none of it is a decision
    -- anybody wants to make while wearing a headset. What IS a decision is
    -- where you stand: inside the world or above it. That is the voxel
    -- pipeline's ladder, so the row reads and writes it directly rather than
    -- a key of its own, and the in-game menu shows the same thing.
    --
    -- The mod itself has no row anywhere: on this build it is not optional.
    if love.xr then
      local Voxel = { FULL = 1, FIRST = 6 }   -- see lib/VoxelState ANGLE_LABELS
      return {
        {
          id = "display", label = "View", default = Voxel.FIRST,
          choices = {
            { value = Voxel.FIRST, label = "First Person" },
            { value = Voxel.FULL,  label = "Third Person" },
          },
          get = function(options)
            local p = options.pipelines
            return (p and p.voxel) or Voxel.FIRST
          end,
          set = function(options, value)
            options.pipelines = options.pipelines or {}
            options.pipelines.voxel = value
            -- AND ON THE LIVE GAME, not only in the file.
            --
            -- Pipeline levels are read once, when a game loads. Written only
            -- to disk, this row changed nothing anybody could see until the
            -- next boot -- which is exactly what "I cannot really switch"
            -- looks like from the launcher, where the game is sitting paused
            -- behind the window rather than gone.
            pcall(function()
              require("src.render.Pipelines").setLevel("voxel", value)
            end)
          end,
        },
      }
    end

    return {
      { id = "textSpeed", label = "Text speed", default = 3, choices = {
          { value = 1, label = "Fast" },
          { value = 3, label = "Medium" },
          { value = 5, label = "Slow" } } },
      { id = "animations", label = "Battle animation", default = true, choices = {
          { value = true, label = "On" }, { value = false, label = "Off" } } },
      { id = "battleStyle", label = "Battle style", default = "shift", choices = {
          { value = "shift", label = "Shift" }, { value = "set", label = "Set" } } },
      { id = "colors", label = "Colors", default = "gbc", choices = colors },
      { id = "musicVol", label = "Music volume", default = 7, choices = vols },
      { id = "sfxVol", label = "Sound volume", default = 7, choices = vols },
      { id = "performance", label = "Performance", default = "auto",
        choices = cycleChoices(Performance.cycle, Performance.label, "auto") },
      { id = "fpsCap", label = "Max FPS", default = 60,
        choices = cycleChoices(FrameCap.cycle, FrameCap.label, 60) },
      { id = "speed", label = "Game speed", default = 1,
        choices = cycleChoices(GameSpeed.cycle, GameSpeed.levelLabel, 1) },
    }
  end)
  SETTINGS = ok and built or {}
  return SETTINGS
end

local function settingsSnapshot()
  local SaveData = require("src.core.SaveData")
  local okO, options = pcall(SaveData.loadOptions)
  options = okO and options or {}
  local out = {}
  for _, s in ipairs(buildSettings()) do
    local v = s.get and s.get(options) or options[s.id]
    if v == nil then v = s.default end
    out[#out + 1] = {
      id = s.id, label = s.label, value = v, choices = s.choices,
    }
  end
  return out
end

-- ---------------------------------------------------------------- publishing

local function snapshot()
  local RomImporter = require("src.import.RomImporter")
  local LauncherMods = require("src.mods.LauncherMods")

  local SaveData = require("src.core.SaveData")

  local games = {}
  for _, v in ipairs(VERSIONS) do
    local ready = false
    -- pcall: a half-written cache should grey a card out, not take the
    -- launcher down with it.
    local ok, result = pcall(RomImporter.isReady, v)
    if ok then ready = result == true end

    -- The same save rows the Lua launcher lists under each column, and from
    -- the same call -- SaveData.listSlots already returns the player name,
    -- badge count, play time and dex count the old panel prints. Read only
    -- for a version whose ROM is in: listSlots on an unimported game would
    -- register empty slots for a game that cannot be played.
    local slots = {}
    local active = nil
    if ready then
      local okS, list = pcall(SaveData.listSlots, v)
      if okS and type(list) == "table" then
        for _, s in ipairs(list) do
          local m = s.meta or {}
          slots[#slots + 1] = {
            -- Where it lives on disk. The window exports by handing this file
            -- to the system's own share sheet, so nothing has to be copied,
            -- re-encoded or kept in step -- and an import is the same file
            -- coming back.
            path = (select(2, pcall(SaveData.slotDiskPath, v, s.id))),
            id = s.id,
            label = s.label,
            name = s.name,
            exists = s.exists == true,
            badges = m.badges,
            timeText = m.timeText,
            dexCount = m.dexCount,
          }
        end
      end
      local okA, a = pcall(SaveData.activeSlot, v)
      if okA then active = a end
    end

    games[#games + 1] = {
      id = v, title = TITLES[v] or v, ready = ready,
      slots = slots, activeSlot = active,
    }
  end

  local mods = {}
  local okM, list = pcall(LauncherMods.list)
  if okM and type(list) == "table" then
    for _, m in ipairs(list) do
      mods[#mods + 1] = {
        id = m.id,
        name = m.name,
        version = m.version,
        badge = m.badge,
        description = m.description,
        enabled = m.enabled == true,
        status = m.status,
        statusDetail = m.statusDetail,
        experimental = m.experimental == true,
      }
    end
  end

  -- NO MOD LIST ON A HEADSET. The launcher hides the whole section when it is
  -- empty, and on this build the mod is not something to switch off -- the
  -- port IS the mod. A toggle that must never be touched is worse than no
  -- toggle: it invites the one press that empties the world.
  if love.xr then mods = {} end

  return { games = games, mods = mods, settings = settingsSnapshot(),
           exportFile = exportFile,
           ready = true }
end

local function publish()
  local ok, encoded = pcall(function() return Json.encode(snapshot()) end)
  if not ok or not encoded then return end
  -- Only on change. The shell polls this file, and rewriting an identical
  -- snapshot ten times a second would churn the container for nothing.
  if encoded == lastPublished then return end
  lastPublished = encoded
  pcall(love.filesystem.write, STATE_FILE, encoded)
end

-- ---------------------------------------------------------------- commands

local function applyCommand(cmd)
  local LauncherMods = require("src.mods.LauncherMods")

  if cmd.action == "setMod" and type(cmd.id) == "string" then
    pcall(LauncherMods.setEnabled, cmd.id, cmd.enabled == true)
    -- Force the next publish: the enable-state the shell drew is now stale.
    lastPublished = nil
    return
  end

  -- Which save the chosen game will continue from. Set before booting rather
  -- than passed to it: SaveData.setActiveSlot is what the title screen's
  -- CONTINUE already reads, so this is the same choice the player would have
  -- made in the game, made a screen earlier.
  if cmd.action == "setSlot" and type(cmd.version) == "string" then
    local SaveData = require("src.core.SaveData")
    pcall(SaveData.setActiveSlot, cmd.version, cmd.slot)
    lastPublished = nil
    return
  end

  if cmd.action == "newSlot" and type(cmd.version) == "string" then
    local SaveData = require("src.core.SaveData")
    local ok, id = pcall(SaveData.createSlot, cmd.version)
    if ok and id then pcall(SaveData.setActiveSlot, cmd.version, id) end
    lastPublished = nil
    return
  end

  -- A settings row. Written straight into the global options file, which is
  -- where every one of these already lives -- the in-game OPTIONS menu reads
  -- and writes the same keys, so a value set here is the value it shows.
  if cmd.action == "setOption" and type(cmd.id) == "string" then
    local SaveData = require("src.core.SaveData")
    local okO, options = pcall(SaveData.loadOptions)
    if okO and type(options) == "table" then
      local row = nil
      for _, r in ipairs(buildSettings()) do
        if r.id == cmd.id then row = r end
      end
      if row and row.set then row.set(options, cmd.value)
      else options[cmd.id] = cmd.value end
      pcall(SaveData.saveOptions, options)
      Logger.info("native shell: setOption %s = %s -> stored %s",
                  tostring(cmd.id), tostring(cmd.value),
                  tostring(row and row.get and row.get(options) or options[cmd.id]))
    end
    lastPublished = nil
    return
  end

  -- The debug gate, opened by ten presses on one save slot (GRShell). Kept in
  -- the mod's own options so it survives the boot into the game, which is
  -- where the menus it unhides actually live.
  if cmd.action == "setDebug" then
    local SaveData = require("src.core.SaveData")
    local okO, options = pcall(SaveData.loadOptions)
    if okO and type(options) == "table" then
      options.modOptions = options.modOptions or {}
      local m = options.modOptions.DRAMATIC_SHAPE or {}
      m.debug = cmd.on and true or false
      options.modOptions.DRAMATIC_SHAPE = m
      pcall(SaveData.saveOptions, options)
    end
    lastPublished = nil
    return
  end

  -- Immersion ended (the Crown, our own button, or the system). The launcher
  -- stands back up so the window has something to be; the game is left where
  -- it is and simply not updated, and a later boot loads it afresh.
  -- Deleting a save is the one command here that destroys something, so it
  -- does nothing clever: the engine's own deleteSlot, which unregisters the
  -- slot and removes its file. The window asks first.
  if cmd.action == "deleteSlot" and type(cmd.version) == "string" then
    local SaveData = require("src.core.SaveData")
    pcall(SaveData.deleteSlot, cmd.version, cmd.id)
    lastPublished = nil
    return
  end

  -- An import arrives as a file the window has already written into the save
  -- directory under a name of its choosing; this makes a slot for it and
  -- moves it into the place that slot expects.
  if cmd.action == "importSlot" and type(cmd.version) == "string"
     and type(cmd.file) == "string" then
    local SaveData = require("src.core.SaveData")
    local okC, slotId = pcall(SaveData.createSlot, cmd.version)
    Logger.info("native shell: import %s file=%s slot=%s",
                tostring(cmd.version), tostring(cmd.file), tostring(slotId))
    if okC and slotId then
      local ok, data = pcall(love.filesystem.read, cmd.file)
      Logger.info("native shell: import read=%s bytes=%s",
                  tostring(ok), tostring(data and #data))
      if ok and data then
        -- A VANILLA .sav COMES BACK THROUGH THE CONVERTER.
        --
        -- That is what export hands out and what an editor gives back, so it
        -- is the shape to expect: 32768 bytes of SRAM, decoded into a save
        -- table and written as a slot. Anything else is taken for one of our
        -- own slot files and written through unchanged, which is what a
        -- straight copy between two installs is.
        local okW = pcall(function()
          local SaveConvert = require("src.save_convert.SaveConvert")
          local save = SaveConvert.importSav(data, nil, cmd.version)
          if save then
            assert(SaveData.writeSlot(cmd.version, slotId, save))
          else
            local dest = SaveData.slotDiskPath(cmd.version, slotId)
            local fh = dest and io.open(dest, "wb")
            if not fh then error("no destination", 0) end
            fh:write(data)
            fh:close()
          end
        end)
        Logger.info("native shell: import wrote=%s", tostring(okW))
        if not okW then pcall(SaveData.deleteSlot, cmd.version, slotId) end
      end
    end
    pcall(love.filesystem.remove, cmd.file)
    lastPublished = nil
    return
  end

  -- EXPORT AS A REAL BATTERY SAVE, not as our own slot file.
  --
  -- There is no save editor in this project, and there does not need to be:
  -- SaveConvert already speaks the vanilla 32768-byte Gen 1 SRAM image in
  -- both directions, and every editor ever written for Red and Blue speaks
  -- that. Handing out slotN.lua would hand out something only this program
  -- can read; handing out a .sav puts the player's own save in front of the
  -- tools they already have -- and importSlot takes it back.
  if cmd.action == "exportSlot" and type(cmd.version) == "string" then
    local SaveData = require("src.core.SaveData")
    local SaveConvert = require("src.save_convert.SaveConvert")
    exportFile = nil
    pcall(function()
      if cmd.id then SaveData.setActiveSlot(cmd.version, cmd.id) end
      local save = SaveData.load(cmd.version)
      if not save then error("no save", 0) end
      local bytes = SaveConvert.exportSav(save, cmd.version)
      if not bytes then error("convert failed", 0) end
      local name = ("export_%s_%s.sav"):format(cmd.version, cmd.id or "slot")
      assert(love.filesystem.write(name, bytes))
      exportFile = love.filesystem.getSaveDirectory() .. "/" .. name
    end)
    lastPublished = nil
    return
  end

  if cmd.action == "toLauncher" then
    -- SILENCE WHILE THE WORLD IS CLOSED.
    --
    -- The game is paused, not stopped, and a paused game with its music still
    -- running is a room you have left that is still playing. Restored on the
    -- way back in from the options file, so whatever the player set is what
    -- returns.
    pcall(function() require("src.core.Music").setVolumeLevel(0) end)
    pcall(function() require("src.core.Sound").setVolumeLevel(0) end)
    NativeShell.active = true
    lastPublished = nil
    publish()
    return
  end

  if cmd.action == "boot" then
    local version = cmd.version
    -- An unknown or missing version boots Red rather than nothing: the shell
    -- should never send one, and a launcher that silently does nothing is the
    -- worst of the available failures.
    local known = false
    for _, v in ipairs(VERSIONS) do
      if v == version then known = true end
    end
    if not known then version = "red" end
    -- ALREADY LOADED? Then this is a way back IN, not a boot.
    --
    -- The launcher is reachable mid-game now (the Crown lands there), so
    -- START can arrive with a game sitting in memory. Loading it a second
    -- time re-registers everything a mod registered the first time and the
    -- registry refuses -- "statuses already registered: BRN" -- which takes
    -- the app down for a button that was only meant to resume. Standing the
    -- shell down is the whole job: the update loop hands the frame back and
    -- the game carries on where it paused, with whatever the player just
    -- changed in the settings already applied.
    if NativeShell.booted then
      Logger.info("native shell: resuming, already loaded")
      local okO, opts = pcall(require("src.core.SaveData").loadOptions)
      if okO then
        pcall(function() require("src.core.Music").applyOptions(opts) end)
        pcall(function() require("src.core.Sound").applyOptions(opts) end)
      end
      NativeShell.active = false
      return
    end
    Logger.info(("native shell: booting %s"):format(version))
    NativeShell.active = false
    NativeShell.booted = true
    if bootGame then bootGame(version) end
    return
  end
end

local function takeCommand()
  if not love.filesystem.getInfo(COMMAND_FILE) then return nil end
  local ok, raw = pcall(love.filesystem.read, COMMAND_FILE)
  -- Removed BEFORE it is acted on, not after. A command that crashes while
  -- being applied would otherwise be retried every tick forever.
  pcall(love.filesystem.remove, COMMAND_FILE)
  if not ok or not raw or raw == "" then return nil end
  local okD, decoded = pcall(Json.decode, raw)
  if not okD or type(decoded) ~= "table" then return nil end
  return decoded
end

-- ---------------------------------------------------------------- lifecycle

-- Whether this build should hand the launcher to a native shell.
--
-- Keyed on love.xr rather than an OS string, for the reason spelled out in
-- mobile/visionos/README.md: love.system.getOS() deliberately still answers
-- "iOS" on visionOS so every existing iOS branch keeps working, so it cannot
-- tell the two apart. love.xr exists only in the visionOS build.
function NativeShell.applies()
  return love.xr ~= nil
end

function NativeShell.begin(boot)
  bootGame = boot
  NativeShell.active = true
  -- A stale command from the last run must not boot the game before the
  -- player has chosen anything.
  pcall(love.filesystem.remove, COMMAND_FILE)
  publish()
  Logger.info("native shell: launcher handed to the visionOS window")
end

-- Read every frame, ACTIVE OR NOT.
--
-- This used to return immediately once a game had booted, which made the
-- command channel one-way: the window could still send, and nobody was
-- listening. That is why the launcher's View picker snapped back -- the
-- command never arrived, the optimistic UI moved, and the next snapshot put
-- it back -- and why the Crown's way home could not work at all, since the
-- message that stands the launcher up is itself a command.
--
-- Publishing still only happens while the launcher is up; what runs here for
-- a booted game is one file existence check per poll interval.
function NativeShell.update(dt)
  timer = timer + (dt or 0)
  if timer < POLL_INTERVAL then return end
  timer = 0

  local cmd = takeCommand()
  -- WITH A GAME RUNNING, only the commands that mean anything then.
  --
  -- Booting is the dangerous one: Game:load() a second time re-registers
  -- everything a mod registered the first time, and the registry rightly
  -- refuses ("statuses already registered: BRN"). Before this channel stayed
  -- open past the launcher a stale boot command could not reach anybody; now
  -- it can, so it is turned away here rather than left to fail loudly.
  -- With a game running the launcher is not showing, so the rows it would
  -- act on are not on screen either -- only the commands that mean something
  -- from the window get through. `boot` is deliberately among them: after the
  -- Crown it is how the player goes back in, and it resumes rather than
  -- loading again (see below).
  if cmd and not NativeShell.active then
    local allowed = cmd.action == "toLauncher" or cmd.action == "setOption"
                    or cmd.action == "setDebug" or cmd.action == "boot"
    if not allowed then cmd = nil end
  end
  if cmd then applyCommand(cmd) end
  -- After the command, so a toggle is reflected in the same tick it lands.
  if NativeShell.active then publish() end
end

-- Nothing to draw. The window is the launcher, and the virtual screen behind
-- this is whatever LOVE last put there -- which the shell does not show while
-- the launcher is up.
function NativeShell.draw() end

return NativeShell
