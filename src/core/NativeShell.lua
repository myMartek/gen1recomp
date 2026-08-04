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

  return { games = games, mods = mods, ready = true }
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
    Logger.info(("native shell: booting %s"):format(version))
    NativeShell.active = false
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

function NativeShell.update(dt)
  if not NativeShell.active then return end
  timer = timer + (dt or 0)
  if timer < POLL_INTERVAL then return end
  timer = 0

  local cmd = takeCommand()
  if cmd then applyCommand(cmd) end
  -- After the command, so a toggle is reflected in the same tick it lands.
  if NativeShell.active then publish() end
end

-- Nothing to draw. The window is the launcher, and the virtual screen behind
-- this is whatever LOVE last put there -- which the shell does not show while
-- the launcher is up.
function NativeShell.draw() end

return NativeShell
