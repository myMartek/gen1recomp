-- The save editor, with a native face.
--
-- On visionOS the editor's own window is the wrong shape twice over: it is
-- laid out for a mouse on a monitor, and it would arrive as a picture of a
-- tool floating on a quad rather than as a window the system can place, focus
-- and read aloud. So SwiftUI draws it -- and this is what SwiftUI draws FROM.
--
-- WHAT IS NOT HERE IS THE POINT. No rule about what a legal save is lives in
-- this file, and none lives in Swift either. tools/save-editor/Ops.lua is the
-- only thing allowed to change a save (its own README makes that a rule the
-- tests assert), and every command below lands on one of its verbs with the
-- arguments it already takes. The Gen-1 stat formulas, the XP curves, the
-- badge/item tables, the arming of destructive verbs, the "save validates
-- clean" check -- all of it stays where it is and answers to both faces.
--
-- Two files, like src/core/NativeShell.lua and for the same reasons:
--
--   native_editor.json      what the editor holds, written on change
--   native_shell_cmd.json   commands, shared with the shell (ed.* actions)
--
-- The shell keeps running while this is up. It is what publishes `editing`,
-- which is how the window knows to show the editor at all.

local Logger = require("src.core.Logger")
local Json = require("src.link.Json")

local NativeEditor = {}

local STATE_FILE = "native_editor.json"
local PUBLISH_INTERVAL = 0.1

local App, Ops = nil, nil
local lastPublished = nil
local timer = 0

-- What the UI is looking at. Kept here rather than in the editor's own State
-- because it is about the SwiftUI list on screen, not about the save: how far
-- a list is scrolled is not something the file has an opinion on.
local view = {
  -- Which tab the window shows. Held here rather than only in SwiftUI so the
  -- editor can be opened ON a tab, and so a scripted run can walk all of them
  -- -- a face whose state only exists inside itself cannot be driven or
  -- checked from outside.
  tab = "party",
  itemQuery = "",
  eventQuery = "",
  mapQuery = "",
  page = 0,
}

local PAGE = 200

-- ------------------------------------------------------------------ open

function NativeEditor.attach(app)
  App = app
  Ops = require("Ops")
  lastPublished = nil
  timer = 0
  view.itemQuery, view.eventQuery, view.mapQuery, view.page = "", "", "", 0
  view.tab = "party"
end

function NativeEditor.detach()
  App, Ops = nil, nil
  lastPublished = nil
  pcall(love.filesystem.remove, STATE_FILE)
end

function NativeEditor.attached() return App ~= nil end

-- ------------------------------------------------------------- snapshot

local function state()
  return App and App.getState and App.getState() or nil
end

-- Json.encode cannot tell an empty array from an empty object, and Swift's
-- decoder can: `[]` written as `{}` fails to decode as a list. Empty lists are
-- therefore left OUT, and the Swift side reads a missing key as empty.
local function list(t)
  if t == nil or #t == 0 then return nil end
  return t
end

local function monSnapshot(mon, index)
  if type(mon) ~= "table" then return nil end
  local moves = {}
  for i = 1, 4 do
    local m = mon.moves and mon.moves[i]
    moves[i] = { slot = i, id = m and m.id or "", pp = m and m.pp or 0 }
  end
  local dvs = mon.dvs or {}
  local stats = mon.stats or {}
  return {
    index = index,
    species = mon.species or "",
    nickname = mon.nickname or "",
    level = mon.level or 1,
    hp = mon.hp or 0,
    ot = mon.ot or "",
    exp = mon.exp or 0,
    moves = moves,
    dvs = { hp = dvs.hp or 0, attack = dvs.attack or 0, defense = dvs.defense or 0,
            speed = dvs.speed or 0, special = dvs.special or 0 },
    stats = { hp = stats.hp or 0, attack = stats.attack or 0,
              defense = stats.defense or 0, speed = stats.speed or 0,
              special = stats.special or 0 },
  }
end

local function matches(name, query)
  if query == nil or query == "" then return true end
  return name:upper():find(query:upper(), 1, true) ~= nil
end

-- A page of a long list, with the total so the UI can say "200 of 1143".
local function page(ids, query)
  local hits, total = {}, 0
  for _, id in ipairs(ids) do
    if matches(id, query) then
      total = total + 1
      if total > view.page and #hits < PAGE then hits[#hits + 1] = id end
    end
  end
  return hits, total
end

local function partySection(S)
  local mons = {}
  for i, mon in ipairs(S.save.party or {}) do
    mons[#mons + 1] = monSnapshot(mon, i)
  end
  return mons
end

local function bagSection(S)
  local rows = {}
  for _, id in ipairs(S.save.bagOrder or {}) do
    local n = (S.save.inventory or {})[id]
    if n then rows[#rows + 1] = { id = id, count = n } end
  end
  -- Anything the order list has not caught up with still has to be editable,
  -- or an item added by a mod is invisible and undeletable.
  for id, n in pairs(S.save.inventory or {}) do
    local seen = false
    for _, r in ipairs(rows) do if r.id == id then seen = true end end
    if not seen then rows[#rows + 1] = { id = id, count = n } end
  end
  return rows
end

local function pcSection(S)
  local rows = {}
  for _, id in ipairs(Ops.pcOrder(S)) do
    rows[#rows + 1] = { id = id, count = Ops.pcItems(S)[id] }
  end
  return rows
end

local function badgeSection(S)
  local rows = {}
  for _, id in ipairs(Ops.badgeIds(S)) do
    rows[#rows + 1] = { id = id, on = (S.save.inventory or {})[id] and true or false }
  end
  return rows
end

local function boxSection(S)
  local boxes = Ops.boxes(S)
  local slots = {}
  local current = boxes[S.selectedBox] or {}
  for i, mon in ipairs(current) do
    slots[#slots + 1] = monSnapshot(mon, i)
  end
  return { count = #boxes, selected = S.selectedBox, slot = S.selectedBoxSlot,
           mons = list(slots) }
end

local function dexSection(S)
  local dex = Ops.dex(S)
  local seen, owned = Ops.dexCounts(S)
  local rows = {}
  local ids, total = page(S.cat.species, view.itemQuery)
  for _, id in ipairs(ids) do
    rows[#rows + 1] = { id = id,
                        seen = (dex.seen or {})[id] and true or false,
                        owned = (dex.owned or {})[id] and true or false }
  end
  return { seen = seen, owned = owned, total = total, rows = list(rows) }
end

local function eventSection(S)
  local names, total = page(S.events or {}, view.eventQuery)
  local rows = {}
  for _, name in ipairs(names) do
    rows[#rows + 1] = { name = name, on = (S.save.flags or {})[name] and true or false }
  end
  return { total = total, rows = list(rows) }
end

-- The map tab's three verbs all read S.mapId and S.mapClickCell -- the panel
-- version sets them by clicking a rendered map, and here a picker and two
-- number fields do the same job. View state, not save state, which is why
-- they are set directly rather than through Ops: Ops owns the save.
local function mapSection(S)
  local ids = {}
  for id in pairs((S.data and S.data.maps) or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  local shown, total = page(ids, view.mapQuery)
  local cell = S.mapClickCell
  local player = S.save.player or {}
  local lo, lh = S.save.lastOutdoor, S.save.lastHeal
  return {
    selected = S.mapId or "",
    cellX = cell and cell.cx or 0,
    cellY = cell and cell.cy or 0,
    total = total,
    rows = list(shown),
    playerAt = ("%s (%d,%d)"):format(tostring(player.map or "?"),
                                     player.x or 0, player.y or 0),
    lastOutdoor = lo and ("%s (%d,%d)"):format(tostring(lo.id), lo.x or 0, lo.y or 0) or "",
    lastHeal = lh and ("%s (%d,%d)"):format(tostring(lh.map), lh.x or 0, lh.y or 0) or "",
  }
end

local function snapshot()
  local S = state()
  if not S or not S.save then return nil end

  local ok, out = pcall(function()
    return {
      ready = true,
      tab = view.tab,
      path = S.path or "",
      version = S.version or "",
      slot = S.slotId or "",
      dirty = S.dirty == true,
      status = S.status or "",
      armed = S.armed or "",
      valid = S.validation == nil or S.validation.ok ~= false,
      player = (S.save.player and S.save.player.name) or "",
      rival = (S.save.player and S.save.player.rival) or "",
      nameMax = Ops.NAME_MAX,
      money = S.save.money or 0,
      moneyMax = Ops.MONEY_MAX,
      selectedParty = S.selectedParty or 1,
      party = list(partySection(S)),
      partyMax = 6,
      box = boxSection(S),
      bag = list(bagSection(S)),
      pc = list(pcSection(S)),
      badges = list(badgeSection(S)),
      dex = dexSection(S),
      events = eventSection(S),
      -- The catalogues the pickers offer. Filtered by the same query the
      -- lists use, so one text field drives both sides of an ADD row.
      itemCatalog = list((page(S.cat.items, view.itemQuery))),
      speciesCatalog = list((page(S.cat.species, view.itemQuery))),
      moveCatalog = list((page(S.cat.moves, view.itemQuery))),
      map = mapSection(S),
      queries = { item = view.itemQuery, event = view.eventQuery, map = view.mapQuery },
      page = view.page,
    }
  end)
  if not ok then
    Logger.info("native editor: snapshot failed: " .. tostring(out))
    return nil
  end
  return out
end

local function publish()
  local snap = snapshot()
  if not snap then return end
  local ok, encoded = pcall(function() return Json.encode(snap) end)
  if not ok or not encoded then return end
  if encoded == lastPublished then return end
  lastPublished = encoded
  pcall(love.filesystem.write, STATE_FILE, encoded)
end

NativeEditor.publish = publish

function NativeEditor.update(dt)
  if not App then return end
  timer = timer + (dt or 0)
  if timer < PUBLISH_INTERVAL then return end
  timer = 0
  publish()
end

-- ------------------------------------------------------------- commands
--
-- One table, one line per verb, and every line lands in Ops. A dispatcher
-- with no logic in it is the whole design: anything that needed a decision
-- here would be a rule with two homes.

local function num(v, fallback) return tonumber(v) or fallback end
local function str(v) return type(v) == "string" and v or nil end

local VERBS = {
  -- file
  save    = function(S) App.save() end,
  reload  = function(S) App.reload() end,
  -- App.close arms on unsaved edits and commits on the second call, which is
  -- the same two-step the editor's own Close button has. SwiftUI shows the
  -- armed state from the snapshot rather than inventing a dialog of its own.
  close   = function(S)
    App.close()
    -- Nothing draws here, so the close has to be finished on the spot.
    if App.finishClose then App.finishClose() end
  end,

  -- party
  selectParty = function(S, c) Ops.selectParty(S, num(c.index, 1)) end,
  partyAdd    = function(S) Ops.partyAdd(S) end,
  partyRemove = function(S) Ops.partyRemove(S) end,
  partyMove   = function(S, c) Ops.partyMove(S, num(c.delta, 0)) end,

  -- the inspected mon
  setLevel    = function(S, c) Ops.setLevel(S, S.editingMon, num(c.level, 1)) end,
  setSpecies  = function(S, c) Ops.setSpecies(S, S.editingMon, str(c.id)) end,
  stepSpecies = function(S, c) Ops.stepSpecies(S, S.editingMon, num(c.delta, 0)) end,
  setDv       = function(S, c) Ops.setDv(S, S.editingMon, str(c.key), num(c.value, 0)) end,
  cycleMove   = function(S, c) Ops.cycleMove(S, S.editingMon, num(c.slot, 1)) end,
  clearMove   = function(S, c) Ops.clearMove(S, S.editingMon, num(c.slot, 1)) end,
  resetMoves  = function(S) Ops.resetMoves(S, S.editingMon) end,
  healMon     = function(S) Ops.healMon(S, S.editingMon) end,

  -- boxes
  selectBox     = function(S, c) Ops.selectBox(S, num(c.index, 1)) end,
  stepBox       = function(S, c) Ops.stepBox(S, num(c.delta, 0)) end,
  selectBoxSlot = function(S, c) Ops.selectBoxSlot(S, num(c.index, 1)) end,
  boxAdd        = function(S) Ops.boxAdd(S) end,
  withdraw      = function(S) Ops.withdraw(S) end,
  deposit       = function(S) Ops.deposit(S) end,
  release       = function(S) Ops.release(S) end,

  -- money and things
  setPlayerName = function(S, c) Ops.setPlayerName(S, str(c.value)) end,
  setRivalName  = function(S, c) Ops.setRivalName(S, str(c.value)) end,
  addMoney  = function(S, c) Ops.addMoney(S, num(c.delta, 0)) end,
  maxMoney  = function(S) Ops.maxMoney(S) end,
  addToBag  = function(S, c) Ops.addToBag(S, str(c.id)) end,
  bagAdjust = function(S, c) Ops.bagAdjust(S, str(c.id), num(c.delta, 0)) end,
  bagDrop   = function(S, c) Ops.bagDrop(S, str(c.id)) end,
  addToPc   = function(S, c) Ops.addToPc(S, str(c.id)) end,
  pcAdjust  = function(S, c) Ops.pcAdjust(S, str(c.id), num(c.delta, 0)) end,
  pcDrop    = function(S, c) Ops.pcDrop(S, str(c.id)) end,
  toggleBadge = function(S, c) Ops.toggleBadge(S, str(c.id)) end,

  -- events
  setFlag    = function(S, c) Ops.setFlag(S, str(c.name), c.on == true) end,
  setToggle  = function(S, c) Ops.setToggle(S, str(c.map), str(c.name), c.on == true) end,
  clearTable = function(S, c) Ops.clearTable(S, str(c.key), str(c.label) or str(c.key)) end,

  -- dex
  dexSeen   = function(S, c) Ops.dexSeen(S, str(c.id), c.on == true) end,
  dexOwned  = function(S, c) Ops.dexOwned(S, str(c.id), c.on == true) end,
  dexStamp  = function(S) Ops.dexStamp(S) end,
  dexSeeAll = function(S) Ops.dexSeeAll(S) end,
  dexOwnAll = function(S) Ops.dexOwnAll(S) end,
  dexClear  = function(S) Ops.dexClear(S) end,

  -- where the player is
  selectMap = function(S, c) S.mapId = str(c.id) end,
  setCell   = function(S, c)
    S.mapClickCell = { cx = num(c.x, 0), cy = num(c.y, 0) }
  end,
  setPlayerHere  = function(S) Ops.setPlayerHere(S) end,
  -- setLastOutdoor wants a LOADED map, not the raw definition table: it reads
  -- map.def.tileset and map.def.connections before it will accept one. The
  -- editor's own map panel loads it the same way (MapLoader.load), and handing
  -- over S.data.maps[id] instead simply threw -- which showed up as a button
  -- that did nothing and said nothing.
  setLastOutdoor = function(S)
    if not S.mapId then return Ops.say(S, "Pick a map first") end
    local ok, map = pcall(require("src.world.MapLoader").load, S.data, S.mapId)
    if not ok or not map then return Ops.say(S, "That map could not be loaded") end
    Ops.setLastOutdoor(S, map)
  end,
  setLastHeal    = function(S) Ops.setLastHeal(S) end,

  -- what the UI is looking at: view state, no save touched
  tab = function(S, c) view.tab = str(c.tab) or "party" end,
  query = function(S, c)
    if c.item  ~= nil then view.itemQuery  = str(c.item)  or "" end
    if c.event ~= nil then view.eventQuery = str(c.event) or "" end
    if c.map   ~= nil then view.mapQuery   = str(c.map)   or "" end
    view.page = 0
  end,
  page = function(S, c) view.page = math.max(0, num(c.page, 0)) end,
}

--- Returns true when the command was for the editor (whether or not it did
--- anything), so the shell knows not to look at it again.
function NativeEditor.command(cmd)
  local action = type(cmd) == "table" and cmd.action or nil
  if type(action) ~= "string" or action:sub(1, 3) ~= "ed." then return false end
  if not App then return true end
  local verb = VERBS[action:sub(4)]
  if not verb then
    Logger.info("native editor: unknown verb " .. action)
    return true
  end
  local S = state()
  if not S then return true end
  local ok, err = pcall(verb, S, cmd)
  if not ok then Logger.info("native editor: " .. action .. " failed: " .. tostring(err)) end
  -- The next publish has to go out even when the snapshot is byte-identical:
  -- Ops.say refuses without changing anything, and the refusal is the status
  -- line the player needs to see.
  lastPublished = nil
  publish()
  return true
end

return NativeEditor
