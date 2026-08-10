-- deutsch: a translation of the game into Deutsch.
--
-- Nothing here is translated yet.  Every table under lang/ starts with
-- empty strings; fill one in and it takes effect on the next boot, and
-- anything still empty keeps rendering in English.  That means a
-- half-finished translation is always playable, so you can ship early and
-- fill the long tail in later.
--
-- Read TRANSLATING.md before the first edit; the font is the part people
-- get wrong.
return function(mod)
  -- mod:read is the supported way into your own directory; the catalogs are
  -- plain Lua tables, so read and run them rather than require()ing them.
  local function catalog(name)
    local rel = "lang/" .. name .. ".lua"
    local body = mod:read(rel)
    if not body then return {} end
    local chunk, err = loadstring(body, rel)
    if not chunk then
      mod.log:warn("%s has a syntax error: %s", rel, tostring(err))
      return {}
    end
    local ok, table_ = pcall(chunk)
    if not ok or type(table_) ~= "table" then
      mod.log:warn("%s did not return a table: %s", rel, tostring(table_))
      return {}
    end
    return table_
  end

  -- An empty value means "not translated yet", never "translate to blank".
  local function each(name, apply)
    local n = 0
    for key, value in pairs(catalog(name)) do
      if type(value) == "string" and value ~= "" then
        apply(key, value)
        n = n + 1
      end
    end
    return n
  end

  -- ---- glyphs -------------------------------------------------------
  -- Register the sheet BEFORE anything asks for a glyph on it.  base is
  -- the first code the page owns; 0x100 and up is free space above the
  -- vanilla pages, so a new alphabet never collides with them.
  for id, page in pairs(catalog("font")) do
    -- THROUGH mod:path, or the sheet is never found.
    --
    -- Font.load hands the image straight to the asset loader, and that
    -- loader only rewrites paths into the derived cache -- everything else is
    -- resolved against the GAME's directory, where a mod's own file does not
    -- exist. The load sits inside a pcall, so the page is skipped in silence
    -- and every glyph on it draws as a blank. Which is exactly what German
    -- looked like: the right words with holes where the umlauts belong.
    -- A DECLARED PAGE WITH NO SHEET IS WORSE THAN NO PAGE AT ALL.
    --
    -- Font.load loads a page's image inside a pcall and skips it in silence
    -- when that fails, and every glyph on the missing page then draws as a
    -- blank -- the right words with holes where the umlauts belong. The sheet
    -- is cut from a cartridge and therefore never ships in the repository, so
    -- a fresh clone legitimately has none. Say so once and leave the page
    -- unregistered, which falls back to English instead of to gaps.
    local relative = type(page) == "table" and page.image or nil
    if type(relative) == "string" and not mod:read(relative) then
      mod.log:warn("glyph page '%s': no sheet at %s. Run "
                   .. "tools/de_font_from_rom.py against your own cartridge; "
                   .. "until then this language draws in English.", id, relative)
    else
      if type(relative) == "string" then
        page.image = mod.path .. "/" .. relative
      end
      mod.content.font:register(id, page)
    end
  end
  -- charmap: which byte sequence draws which code
  for seq, code in pairs(catalog("charmap")) do
    mod.content.font:register("charmap:" .. seq, { seq = seq, code = code })
  end

  -- ---- text ---------------------------------------------------------
  local counts = {}
  counts.dialogue = each("dialogue", function(id, value)
    mod.content.text:override(id, value)
  end)
  counts.strings = each("strings", function(source, value)
    mod.content.strings:override(source, value)
  end)
  -- The same registry, from a second catalog: the menu labels, read out of a
  -- cartridge by tools/de_menus_from_rom.py.
  --
  -- A file of its own rather than more lines in strings.lua, because the two
  -- have different owners. strings.lua is this project's own translation of
  -- text the ENGINE writes and lives in the public repository; this one is
  -- cartridge content and does not. Keeping them apart is what lets the port
  -- gitignore one without losing the other, and it is why the port ships with
  -- this file absent -- an absent catalog reads as empty and falls through to
  -- English, which is exactly right for a clone that has no cartridge.
  --
  -- After strings.lua, so the cartridge wins where both have an opinion.
  counts.menus = each("strings_rom", function(source, value)
    mod.content.strings:override(source, value)
  end)
  counts.species = each("species_names", function(id, value)
    mod.content.pokemon:patch(id, { name = value })
  end)
  counts.moves = each("move_names", function(id, value)
    mod.content.moves:patch(id, { name = value })
  end)
  counts.items = each("item_names", function(id, value)
    mod.content.items:patch(id, { name = value })
  end)
  counts.trainers = each("trainer_names", function(id, value)
    mod.content.trainers:patch(id, { name = value })
  end)
  counts.statuses = each("status_labels", function(id, value)
    mod.content.statuses:patch(id, { label = value })
  end)

  -- ---- name entry ---------------------------------------------------
  -- The naming screen's letter grid.  Leave lang/naming.lua returning nil
  -- to keep the English alphabet.
  local grid = catalog("naming")
  if grid.upper then
    mod.hooks:on("ui.naming.grid", function(base, ctx)
      local want = ctx.lower and grid.lower or grid.upper
      return want or base
    end)
  end

  mod.events:on("game.ready", function()
    local total = 0
    for _, n in pairs(counts) do total = total + n end
    mod.log:info("Deutsch: %d strings translated", total)
  end)
end
