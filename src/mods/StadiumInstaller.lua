-- Building the Pokémon Stadium battle models from the LAUNCHER, with no game.
--
-- The reader that turns a Pokémon Stadium cartridge into the mod's model packs
-- lives in the mod (DramaticShapeVoxelMod/lib/StadiumInstall.lua and the five
-- files under it). The mod's own trigger waits until the player is standing in
-- the overworld -- which on this build means starting a new game and sitting
-- through the intro before a cartridge that has been sitting in the folder for
-- ten minutes is looked at. In a headset, where the launcher is a real window
-- and the import button is in it, that is the wrong moment by a wide margin.
--
-- It does not have to be that moment. Not one of the six modules touches
-- src.core.Game: they read bytes through love.filesystem and write packs back.
-- Everything they need from the mod loader is `V.require` and a log -- so this
-- hands them exactly that and calls them where they stand.
--
-- What this is NOT is a second reader. The mod stays the authority on the ROM
-- format, the pack format and the marker; if that code changes, this changes
-- with it for free, because it loads the mod's own files off disk rather than
-- knowing anything about what they do.

local Logger = require("src.core.Logger")

local StadiumInstaller = {}

local MOD_ID = "DRAMATIC_SHAPE"
-- love.filesystem searches the save directory, which is where LauncherMods
-- unpacks a mod (see LauncherMods.installZip), so this one relative path
-- reaches an installed mod without knowing which of the two roots it is in.
local LIB = "mods/" .. MOD_ID .. "/lib/"

local V, install
local running = false

-- The mod calls its log both ways -- `log:warn(fmt, ...)` in most places and
-- `log.warn(fmt, ...)` in two -- so this takes either. A diagnostic must never
-- be the reason a build fails, which is why the formatting is guarded and the
-- unformatted string is still worth printing when it goes wrong.
local function logfn(level)
  return function(a, ...)
    local fmt, n, args
    if type(a) == "table" then           -- called with a colon
      fmt, n, args = (...), select("#", ...) - 1, { select(2, ...) }
    else
      fmt, n, args = a, select("#", ...), { ... }
    end
    local ok, msg = pcall(string.format, tostring(fmt), unpack(args, 1, n))
    Logger[level]("stadium: %s", ok and msg or tostring(fmt))
  end
end

-- The slice of the mod namespace the six build modules ask for. Built once
-- and kept, so the modules they require of each other are the same instances.
local function namespace()
  if V then return V end
  local cache = {}
  V = {
    mod = {
      id = MOD_ID,
      log = { info = logfn("info"), warn = logfn("warn"),
              error = logfn("error"), debug = logfn("info") },
    },
  }
  function V.require(name)
    local hit = cache[name]
    if hit ~= nil then return hit end
    local chunk, err = love.filesystem.load(LIB .. name .. ".lua")
    if not chunk then error(err or ("stadium: cannot load " .. name), 0) end
    local module = chunk(V)
    cache[name] = module
    return module
  end
  return V
end

local function installer()
  if install then return install end
  local ok, mod = pcall(function() return namespace().require("StadiumInstall") end)
  if not ok then
    Logger.warn("stadium: the mod's installer would not load: %s", tostring(mod))
    return nil
  end
  install = mod
  return install
end

-- Whether the mod is unpacked where its files can be read at all. False on a
-- build with the mod disabled or not yet installed, which is not an error --
-- there is simply nothing to offer.
function StadiumInstaller.present()
  local info = love.filesystem.getInfo(LIB .. "StadiumInstall.lua", "file")
  return info ~= nil
end

-- Whether there is a cartridge to build from and no current set of packs.
function StadiumInstaller.pending()
  local m = installer()
  if not m then return false end
  local ok, pending = pcall(m.pending)
  return (ok and pending) and true or false
end

function StadiumInstaller.ready()
  local m = installer()
  if not m then return false end
  local ok, ready = pcall(m.available)
  return (ok and ready) and true or false
end

-- Start a build. Returns false and a message when there is nothing to build
-- from or the mod refused the cartridge.
function StadiumInstaller.begin()
  if running then return true end
  local m = installer()
  if not m then return false, "The mod is not installed." end
  local ok, err = pcall(m.begin)
  if not ok then return false, tostring(err) end
  if err == false then return false, "No cartridge to build from." end
  running = true
  Logger.info("stadium: building the battle models from the launcher")
  return true
end

-- One update's worth of work.
--
-- Stepped against a TIME budget rather than a fixed count: the mod's own
-- screen steps once a frame because it is drawing a progress bar at sixty of
-- them, and this is a window that may be publishing at a tenth of that. A
-- budget keeps the build near its ten seconds either way, while still handing
-- the frame back often enough that the launcher stays alive.
local BUDGET = 0.030

function StadiumInstaller.pump()
  if not running then return end
  local m = installer()
  if not m then running = false return end
  local deadline = love.timer.getTime() + BUDGET
  repeat
    local ok, more = pcall(m.step)
    if not ok then
      Logger.warn("stadium: the build stopped: %s", tostring(more))
      running = false
      return
    end
    if not more then
      running = false
      Logger.info("stadium: the models are built")
      return
    end
  until love.timer.getTime() >= deadline
end

-- What the window draws: the state, and how far along it is. nil when there is
-- nothing to say, which is every frame outside a build.
function StadiumInstaller.progress()
  if not running then return nil end
  local m = installer()
  local status = m and m.status
  if type(status) ~= "table" then return { state = "working" } end
  return {
    state = status.state or "working",
    done = status.done or 0,
    total = status.total or m.COUNT or 0,
    error = status.error,
  }
end

return StadiumInstaller
