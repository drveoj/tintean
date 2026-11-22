-- Where things are on the look textures (Media/header.tga, places.tga, scenes.tga, ui.tga). Pure: no widgets.
-- Every function returns left, right, top, bottom as 0..1 fractions for SetTexCoord. Layout is written out in
-- Media/README.md and made by addon/tools/make-look-textures.mjs; change them together.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Art = {}
UI.Art = Art

Art.PATH = "Interface\\AddOns\\Tintean\\Media\\"
Art.HEADER = { file = "header", w = 512, h = 128 }
Art.PLACES = { file = "places", w = 256, h = 512, cell = 48, perRow = 5 }
Art.SCENES = { file = "scenes", w = 256, h = 128, cellW = 128, cellH = 64 }
Art.UI = { file = "ui", w = 128, h = 64 }

-- Place cells, row by row, five to a row: index (0-based) is the position. Keys are the place slugs the app uses.
Art.PLACE_SLUGS = {
  "ragefire", "wailing-caverns", "deadmines", "shadowfang", "blackfathom",
  "stockade", "gnomeregan", "razorfen-kraul", "scarlet-monastery", "razorfen-downs",
  "uldaman", "zul-farrak", "maraudon", "sunken-temple", "blackrock-depths",
  "blackrock-spire", "dire-maul", "scholomance", "stratholme", "molten-core", "onyxia",
  "hall-of-thanes", "ruins-of-lordaeron", "excavation-site", "city-of-dalaran", "drowned-city",
  "krol-dok-stronghold", "alcaz-prison", "blackmaw-hold", "shapers-terrace", "barrow-deeps", "hyjal-summit",
  "campfire",
}
Art.NO_PLACE = "campfire" -- the cell drawn for a place with no painting, and for an event with no place
local placeCell = {}
for i, slug in ipairs(Art.PLACE_SLUGS) do placeCell[slug] = i - 1 end

-- The place names an event carries (formats/README.md: place = { ref, name }), in the same order as PLACE_SLUGS
-- (no name for the campfire). An event's `ref` is a random id the server made for the content row, so it says nothing
-- about which painting to draw; the name is the only key on the wire.
local PLACE_NAMES = {
  "Ragefire Chasm", "Wailing Caverns", "The Deadmines", "Shadowfang Keep", "Blackfathom Deeps",
  "The Stockade", "Gnomeregan", "Razorfen Kraul", "Scarlet Monastery", "Razorfen Downs",
  "Uldaman", "Zul'Farrak", "Maraudon", "The Temple of Atal'Hakkar", "Blackrock Depths",
  "Blackrock Spire", "Dire Maul", "Scholomance", "Stratholme", "Molten Core", "Onyxia's Lair",
  "Hall of Thanes", "Ruins of Lordaeron", "Excavation Site", "City of Dalaran", "The Drowned City",
  "Krol'dok Stronghold", "Alcaz Prison", "Blackmaw Hold", "Shaper's Terrace", "The Barrow Deeps", "Hyjal Summit",
}
local function plain(s) return (s:lower():gsub("^the ", ""):gsub("[^%w]", "")) end
local slugOfName = {}
for i, name in ipairs(PLACE_NAMES) do slugOfName[plain(name)] = Art.PLACE_SLUGS[i] end

-- The slug of a place from its name ("The Deadmines" or "Deadmines"), or nil when we have no painting for it.
function Art.slugOf(name)
  if type(name) ~= "string" then return nil end
  return slugOfName[plain(name)]
end

-- The slug of an event's `place` ({ ref, name } or nil), or nil when there is no place or no painting of it.
function Art.slugOfPlace(place)
  return Art.slugOf(type(place) == "table" and place.name or nil)
end

Art.SCENE_NAMES = { "campfire", "map", "book", "tavern" } -- cells 0..3, left to right, top row then bottom
local sceneCell = {}
for i, name in ipairs(Art.SCENE_NAMES) do sceneCell[name] = i - 1 end

-- Sprites on ui.tga: { x, y, w, h } in pixels.
Art.SPRITES = {
  ring = { 0, 0, 32, 32 }, disc = { 32, 0, 32, 32 }, pin = { 64, 0, 8, 8 },
  events = { 0, 32, 16, 16 }, bulletins = { 16, 32, 16, 16 }, roster = { 32, 32, 16, 16 },
  tank = { 48, 32, 16, 16 }, healer = { 64, 32, 16, 16 }, damage = { 80, 32, 16, 16 },
  check = { 96, 0, 32, 32 },
}

local function rect(sheet, x, y, w, h)
  return x / sheet.w, (x + w) / sheet.w, y / sheet.h, (y + h) / sheet.h
end

-- The whole header, or its middle `shown` pixels of height (the window crops it, never stretches it).
-- `shift` (0..1) moves a narrower crop sideways: 0 is the left edge, 1 the right.
function Art.header(width, height, shift)
  local H = Art.HEADER
  width, height = math.min(width or H.w, H.w), math.min(height or H.h, H.h)
  local x = (H.w - width) * math.max(0, math.min(1, shift or 1))
  local y = (H.h - height) / 2
  return rect(H, x, y, width, height)
end

-- A place's painting; the campfire's for a nil or unknown slug, so a frame is never blank. The one place that decides.
function Art.place(slug)
  local i, P = placeCell[slug] or placeCell[Art.NO_PLACE], Art.PLACES
  return rect(P, (i % P.perRow) * P.cell, math.floor(i / P.perRow) * P.cell, P.cell, P.cell)
end

function Art.scene(name)
  local i, S = sceneCell[name], Art.SCENES
  if not i then return nil end
  local perRow = S.w / S.cellW
  return rect(S, (i % perRow) * S.cellW, math.floor(i / perRow) * S.cellH, S.cellW, S.cellH)
end

function Art.sprite(name)
  local s = Art.SPRITES[name]
  if not s then return nil end
  return rect(Art.UI, s[1], s[2], s[3], s[4])
end

-- The texture path as SetTexture takes it (no extension).
function Art.path(sheet) return Art.PATH .. sheet.file end
