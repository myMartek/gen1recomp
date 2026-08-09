-- The demo world: what the app has to show when it has no cartridge.
--
-- WHY THIS EXISTS
--
-- The app ships no game data and may not, so without a cartridge there is a
-- launcher and nothing behind it -- which is also what an App Store reviewer
-- sees. tools/make-demo-rom (in the wrapper repository) builds a file whose
-- only content is its own identity; the importer recognises it by SHA-1 and
-- turns this on instead of decoding anything (RomImporter.installDemo).
--
-- So nothing here is derived from a cartridge, and nothing here is the game.
-- It is a small diorama drawn from numbers in this file: a shore, a path, a
-- few trees and a house, and somebody walking around in it. Enough to show
-- what the presentation does -- blocks with height, standing in a room around
-- you once the immersive space is open -- without pretending to be the thing
-- it cannot be.
--
-- It draws with primitives only. No image, no font file, no generated data:
-- every one of those would either come out of a cartridge or need an asset
-- that the demo has no business dragging into the bundle.

local DemoWorld = {}

-- The map. One character per tile, and the legend is the whole terrain system:
--   .  grass        ~  water        #  path
--   T  tree         H  house        r  roof
local MAP = {
  "~~~~~~~~~~~~~~~~~~~~",
  "~~~~................",
  "~~~.....T....T......",
  "~~......#####.......",
  "~.....T.#...#..T....",
  "~.......#.HH#.......",
  "~..T....#.rr#....T..",
  "~.......#####.......",
  "~....T......#....T..",
  "~...........#.......",
  "~......T....#..T....",
  "~...........#.......",
  "~~..................",
  "~~~~~~~~~~~~~~~~~~~~",
}

-- height, top colour, side colour. The side is the same hue darkened rather
-- than a second choice, so a block reads as one object lit from one side.
local TERRAIN = {
  ["."] = { height = 0.35, top = { 0.42, 0.72, 0.36 } },
  ["#"] = { height = 0.30, top = { 0.80, 0.72, 0.52 } },
  ["~"] = { height = 0.10, top = { 0.29, 0.53, 0.78 }, water = true },
  ["T"] = { height = 1.60, top = { 0.20, 0.52, 0.26 }, trunk = true },
  ["H"] = { height = 1.30, top = { 0.88, 0.85, 0.78 } },
  ["r"] = { height = 1.70, top = { 0.72, 0.31, 0.26 } },
}

local TILE_W, TILE_H = 34, 17   -- the isometric footprint of one tile
local LIFT = 22                 -- pixels per unit of height

-- Where the walker goes: a loop down the path and back along the shore, in
-- tile coordinates. Deliberately a fixed round trip -- a demo nobody is
-- holding a controller for still has to keep moving.
local ROUTE = {
  { 8, 3 }, { 8, 7 }, { 12, 7 }, { 12, 11 }, { 8, 11 }, { 4, 11 },
  { 4, 5 }, { 8, 5 }, { 8, 3 },
}

local function tileAt(col, row)
  local line = MAP[row]
  if not line then return "." end
  return line:sub(col, col) ~= "" and line:sub(col, col) or "."
end

local function terrainAt(col, row)
  return TERRAIN[tileAt(col, row)] or TERRAIN["."]
end

-- Screen position of a tile centre. The camera is fixed: the whole point is a
-- diorama sitting still in front of you while your head moves, and a camera
-- that also moved would fight that.
local function project(self, col, row, height)
  local x = self.originX + (col - row) * TILE_W * 0.5
  local y = self.originY + (col + row) * TILE_H * 0.5 - (height or 0) * LIFT
  return x, y
end

local function shade(colour, factor)
  return { colour[1] * factor, colour[2] * factor, colour[3] * factor }
end

function DemoWorld:load()
  self.time = 0
  self.leg = 1          -- which segment of ROUTE we are on
  self.legProgress = 0
  self.width, self.height = love.graphics.getDimensions()
  self:layout()
  -- Nearest-neighbour everywhere else in this project; the demo draws no
  -- textures at all, so there is nothing to filter and nothing to set.
end

function DemoWorld:layout()
  local rows = #MAP
  local cols = #MAP[1]
  -- Centre the board: the isometric projection is widest across the diagonal,
  -- and its vertical extent includes the tallest block's lift.
  self.originX = self.width * 0.5 + (rows - cols) * TILE_W * 0.25
  self.originY = self.height * 0.5 - (cols + rows) * TILE_H * 0.25 + 40
end

function DemoWorld:resize(w, h)
  self.width, self.height = w, h
  self:layout()
end

-- The walker's position, in tile coordinates, interpolated along the route.
function DemoWorld:walker()
  local from = ROUTE[self.leg]
  local to = ROUTE[self.leg + 1] or ROUTE[1]
  local t = self.legProgress
  return from[1] + (to[1] - from[1]) * t,
         from[2] + (to[2] - from[2]) * t
end

function DemoWorld:update(dt)
  self.time = self.time + dt

  local w, h = love.graphics.getDimensions()
  if w ~= self.width or h ~= self.height then self:resize(w, h) end

  -- Two and a half tiles a second: slow enough to read as walking, fast
  -- enough that the loop closes while somebody is still looking.
  local from = ROUTE[self.leg]
  local to = ROUTE[self.leg + 1] or ROUTE[1]
  local distance = math.max(1e-3,
    math.abs(to[1] - from[1]) + math.abs(to[2] - from[2]))
  self.legProgress = self.legProgress + dt * 2.5 / distance
  while self.legProgress >= 1 do
    self.legProgress = self.legProgress - 1
    self.leg = self.leg + 1
    if self.leg >= #ROUTE then self.leg = 1 end
  end
end

function DemoWorld:drawBlock(col, row, terrain)
  local height = terrain.height
  if terrain.water then
    -- A slow swell, a quarter of a block deep. The phase runs along the
    -- diagonal so the whole shore does not rise and fall as one sheet.
    height = height + math.sin(self.time * 1.6 + (col + row) * 0.55) * 0.05
  end

  local x, y = project(self, col, row, height)
  local hw, hh = TILE_W * 0.5, TILE_H * 0.5

  local top = terrain.top
  -- The two visible sides, drawn first so the top face lands on them.
  local depth = height * LIFT + TILE_H
  love.graphics.setColor(shade(top, 0.62))
  love.graphics.polygon("fill", x - hw, y, x, y + hh,
                                x, y + hh + depth, x - hw, y + depth)
  love.graphics.setColor(shade(top, 0.78))
  love.graphics.polygon("fill", x + hw, y, x, y + hh,
                                x, y + hh + depth, x + hw, y + depth)
  love.graphics.setColor(top)
  love.graphics.polygon("fill", x, y - hh, x + hw, y, x, y + hh, x - hw, y)

  if terrain.trunk then
    -- A tree is a canopy on a stem rather than one tall green block, which at
    -- this size is the difference between a tree and a hedge.
    local tx, ty = project(self, col, row, 0.35)
    love.graphics.setColor(0.34, 0.24, 0.16)
    love.graphics.rectangle("fill", tx - 3, ty, 6, (height - 0.35) * LIFT)
  end
end

function DemoWorld:drawWalker()
  local col, row = self:walker()
  local ground = terrainAt(math.floor(col + 0.5), math.floor(row + 0.5)).height
  local bob = math.abs(math.sin(self.time * 6)) * 3
  local x, y = project(self, col, row, ground)

  love.graphics.setColor(0, 0, 0, 0.25)
  love.graphics.ellipse("fill", x, y + 2, 9, 4.5)

  love.graphics.setColor(0.94, 0.36, 0.30)
  love.graphics.rectangle("fill", x - 5, y - 20 - bob, 10, 14, 3, 3)
  love.graphics.setColor(0.98, 0.86, 0.72)
  love.graphics.circle("fill", x, y - 24 - bob, 5.5)
end

function DemoWorld:draw()
  local w, h = self.width, self.height

  -- Sky, and a horizon that is a shade of the water so the board sits in
  -- something rather than floating on a flat fill.
  love.graphics.clear(0.35, 0.55, 0.78)
  love.graphics.setColor(0.62, 0.76, 0.88)
  love.graphics.rectangle("fill", 0, 0, w, h * 0.45)

  -- Back to front: this projection has no depth buffer, and painting in map
  -- order is exactly the order that resolves it.
  for row = 1, #MAP do
    for col = 1, #MAP[row] do
      self:drawBlock(col, row, terrainAt(col, row))
    end
  end
  self:drawWalker()

  self:drawCaption()
  love.graphics.setColor(1, 1, 1)
end

function DemoWorld:drawCaption()
  local w = self.width
  local font = love.graphics.getFont()
  local lines = {
    "DEMO",
    "This is the app's own demo world.",
    "It needs no cartridge, and it is not the game.",
    "Import your own Red, Blue or Yellow to play.",
  }

  local pad = 14
  local lineHeight = font:getHeight() * 1.35
  local boxH = pad * 2 + lineHeight * #lines
  love.graphics.setColor(0, 0, 0, 0.45)
  love.graphics.rectangle("fill", 0, 0, w, boxH)

  love.graphics.setColor(1, 1, 1)
  for i, line in ipairs(lines) do
    love.graphics.print(line, pad, pad + lineHeight * (i - 1))
  end
end

return DemoWorld
