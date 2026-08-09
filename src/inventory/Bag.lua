-- The bag defaults to 20 slots (BAG_ITEM_CAPACITY,
-- constants/menu_constants.asm), but mods may replace that limit through
-- Data.constants.bagSize.  A distinct item id occupies one slot regardless
-- of quantity; badges live in the inventory table but are not bag items.
-- save.bagOrder keeps acquisition order like wBagItems (SELECT can reorder
-- it).

local Bag = {}

local DEFAULT_CAPACITY = 20

-- `data` is injectable for the save editor and headless mod tests.  Normal
-- gameplay may omit it because the loader merges mods into the Data
-- singleton before any item can be added.  The fallback keeps old/stale
-- generated caches and isolated callers at the vanilla limit.
function Bag.capacity(data)
  data = data or require("src.core.Data")
  local configured = data and data.constants and data.constants.bagSize
  if type(configured) == "number" and configured >= 1 then
    return math.floor(configured)
  end
  return DEFAULT_CAPACITY
end

local function isBadge(id)
  return id:find("BADGE", 1, true) ~= nil
end

-- exported so item lists that share save.inventory (e.g. the PC deposit
-- menu) can exclude badges the same way the bag does
Bag.isBadge = isBadge

function Bag.slots(save)
  local n = 0
  for id in pairs(save.inventory) do
    if not isBadge(id) then n = n + 1 end
  end
  return n
end

-- Acquisition-ordered id list (wBagItems).  Rebuilt sorted once for
-- saves from before the order existed, then maintained incrementally.
function Bag.order(save)
  local order = save.bagOrder
  if not order then
    order = {}
    for id in pairs(save.inventory) do
      if not isBadge(id) then table.insert(order, id) end
    end
    table.sort(order)
    save.bagOrder = order
  end
  -- drop stale ids, append unknown ones (defensive against direct
  -- inventory writes)
  local seen = {}
  for i = #order, 1, -1 do
    local id = order[i]
    if not save.inventory[id] or seen[id] then
      table.remove(order, i)
    else
      seen[id] = true
    end
  end
  for id in pairs(save.inventory) do
    if not isBadge(id) and not seen[id] then table.insert(order, id) end
  end
  return order
end

-- Add qty of an item; returns false (and adds nothing) when a new slot
-- is needed and the bag is full, or when the stack would pass 99
-- (AddItemToInventory's per-slot quantity cap).
function Bag.add(save, id, qty, data)
  local inv = save.inventory
  if not inv[id] and not isBadge(id)
      and Bag.slots(save) >= Bag.capacity(data) then
    return false
  end
  if not isBadge(id) and (inv[id] or 0) + (qty or 1) > 99 then
    return false
  end
  local isNew = not inv[id]
  inv[id] = (inv[id] or 0) + (qty or 1)
  if isNew and not isBadge(id) then
    -- Bag.order APPENDS IT ITSELF. Its repair pass adds anything the
    -- inventory has and the order list does not, and the line above has just
    -- put this id in the inventory -- so inserting after calling it added the
    -- id twice. The next Bag.order dropped the duplicate again, which is why
    -- the game never showed one and anything reading save.bagOrder directly
    -- did.
    Bag.order(save)
  end
  return true
end

-- Remove qty (default 1); clears the slot and its order entry at zero.
function Bag.remove(save, id, qty)
  local inv = save.inventory
  inv[id] = (inv[id] or 0) - (qty or 1)
  if inv[id] <= 0 then
    inv[id] = nil
    local order = save.bagOrder
    if order then
      for i, oid in ipairs(order) do
        if oid == id then table.remove(order, i) break end
      end
    end
  end
end

return Bag
