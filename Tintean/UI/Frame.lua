-- The Tinteán window: our own frame, dusk colours, no Blizzard frame art (README, "The frame").
-- Made once at PLAYER_LOGIN, hidden; opening and closing it only shows and hides it, so both work in combat.
-- No protected frame is touched. Every game call goes through ns.try.
-- Tabs come from UI.registerTab (Model.lua); a tab's panel is a child frame handed to its `build(panel)`.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame = {}
UI.Frame = Frame

Frame.NAME = "TinteanFrame"
Frame.W, Frame.H = 640, 522 -- the header is 100 tall (was 38): 460 + 62
local TITLE_H, TABS_H, FOOT_H = 100, 36, 30 -- TITLE_H is the painted header's height
local TAB_ICON, TAB_ICON_W = { events = true, bulletins = true, roster = true }, 21 -- 15 px icon + 6 before the word
local HEAD_SCALE = 1.25 -- the header is drawn at 640 x 160 and cropped to 100 tall: 512 x 128 texels at 1.25

local C = UI.COLORS
local try = function(...) return ns.try(...) end

local function call(obj, method, ...)
  if type(obj) ~= "table" then return false end
  return try(obj[method], obj, ...)
end

local function color(c) return c[1], c[2], c[3], c[4] end

local function fill(parent, c, layer)
  local ok, t = try(parent.CreateTexture, parent, nil, layer or "BACKGROUND")
  if not ok or type(t) ~= "table" then return nil end
  call(t, "SetColorTexture", color(c))
  return t
end

-- A line of text in our font where it can be drawn, the game's own otherwise.
local function text(parent, size, c, which)
  local ok, fs = try(parent.CreateFontString, parent, nil, "OVERLAY")
  if not ok or type(fs) ~= "table" then return nil end
  local _, locale = try(GetLocale)
  local path = UI.ownFont(which or "body", locale)
  local set = path and select(2, call(fs, "SetFont", path, size, ""))
  if not set then call(fs, "SetFont", STANDARD_TEXT_FONT, size, "") end
  call(fs, "SetTextColor", color(c))
  call(fs, "SetJustifyH", "LEFT")
  return fs
end
Frame.text = text
Frame.call, Frame.color = call, color

-- Pure parts. The header's texture coordinates for a window `w` wide: the picture is cropped, never stretched, and a
-- window narrower than the picture shows less of its width, moved right so the fire stays clear of the name.
function Frame.headerCrop(w)
  return UI.Art.header((w - 2) / HEAD_SCALE, TITLE_H / HEAD_SCALE, 1)
end

-- The faction chip: its word and ink for the game's English faction name, nothing when the game doesn't say.
function Frame.chipFor(faction)
  if faction == "Horde" then return UI.TEXT.horde, C.hordeInk end
  if faction == "Alliance" then return UI.TEXT.alliance, C.allianceInk end
  return nil
end

-- A colour moved toward white (t > 0) or black (t < 0).
function Frame.mix(c, t)
  local target = t > 0 and 1 or 0
  t = math.abs(t)
  return { c[1] + (target - c[1]) * t, c[2] + (target - c[2]) * t, c[3] + (target - c[3]) * t, c[4] }
end

-- What a button looks like: lit has a gold edge and a step lighter; pressed is a step darker and sits a pixel lower.
-- look = { bg, edge }. Returns face colour, edge colour, label offset.
function Frame.feelColors(look, hot, down)
  if down then return Frame.mix(look.bg, -.3), look.edge, -1 end
  if hot then return Frame.mix(look.bg, .08), C.gold, 0 end
  return look.bg, look.edge, 0
end

local function guildName()
  local ok, g = try(function() return ns.Sync.guild() end)
  if ok and g and type(g.name) == "string" then return g.name end
  local ok2, name = try(GetGuildInfo, "player")
  if ok2 and type(name) == "string" and name ~= "" then return name end
  return ""
end

-- The inputs of the status line and the tooltip, read from what the addon holds now.
function Frame.env()
  local ok, g = try(function() return ns.Sync.guild() end)
  local _, now = try(time)
  local peer = ns.lastPeer
  local _, boss = try(function() return ns.Gate.encounter() end)
  local _, _, online = try(GetNumGuildMembers) -- total, online
  local _, player = try(UnitName, "player")
  return { guild = ok and g or nil, guildName = guildName(), peer = peer, now = now or 0, date = date,
    inbox = ns.inbox, player = player, boss = boss == true, note = UI.statusNote, online = type(online) == "number" and online or nil }
end

-- The red count: a round disc (the white disc on ui.tga tinted C.count; a plain colour rectangle where that fails)
-- with the number over it. Used by the tab badges and the minimap button. Starts hidden.
function Frame.badge(parent, size)
  local b = { }
  local ok, f = try(CreateFrame, "Frame", nil, parent)
  if not ok or type(f) ~= "table" then return b end
  call(f, "SetSize", size, size)
  local bg
  local okT, t = try(f.CreateTexture, f, nil, "ARTWORK")
  if okT and type(t) == "table" then
    local l, r, tp, bt = UI.Art.sprite("disc")
    local drawn = call(t, "SetTexture", UI.Art.path(UI.Art.UI))
      and call(t, "SetTexCoord", l, r, tp, bt)
      and call(t, "SetVertexColor", color(C.count))
    if drawn then bg = t else call(t, "SetColorTexture", color(C.count)); bg = t end
  else
    bg = fill(f, C.count, "ARTWORK")
  end
  call(bg, "SetAllPoints")
  local fs = text(f, 11, C.countInk)
  call(fs, "SetPoint", "CENTER", 0, 0)
  call(fs, "SetJustifyH", "CENTER")
  b.frame, b.fs = f, fs
  -- text set while the frame is hidden is drawn blank: give it again each time the frame is shown
  call(f, "SetScript", "OnShow", function() if b.s then call(b.fs, "SetText", b.s) end end)
  call(f, "Hide")
  return b
end

-- Shows n on a badge, or hides it for none. Shown first, then the text.
function Frame.setBadge(b, n)
  local s = UI.countText(n)
  if not b.frame then return end
  if s then
    b.s = s
    call(b.frame, "Show")
    call(b.fs, "SetText", s)
  else
    b.s = nil
    call(b.frame, "Hide")
  end
end

-- Draws a button in its state. Needs b.edge and b.face (coloured rectangles), optionally b.under, b.label, b.anchor.
function Frame.paint(b)
  local look = b.look
  local dy = 0
  if look then
    local face, edge
    face, edge, dy = Frame.feelColors(look, b.hot, b.down)
    call(b.face, "SetColorTexture", color(face))
    call(b.edge, "SetColorTexture", color(edge))
  end
  call(b.under, look and look.chosen and "Show" or "Hide")
  local a = b.anchor
  if a and b.label then
    call(b.label, "ClearAllPoints")
    call(b.label, "SetPoint", a[1], a[2], a[3] + dy)
  end
end

-- Makes a button answer the pointer. Scripts are set once; state lives on the button.
function Frame.feel(b)
  local function set(k, v) return function() b[k] = v; if k == "hot" and not v then b.down = false end; Frame.paint(b) end end
  call(b, "SetScript", "OnEnter", set("hot", true))
  call(b, "SetScript", "OnLeave", set("hot", false))
  call(b, "SetScript", "OnMouseDown", set("down", true))
  call(b, "SetScript", "OnMouseUp", set("down", false))
end

local function button(parent, w, h, onClick)
  local ok, b = try(CreateFrame, "Button", nil, parent)
  if not ok or type(b) ~= "table" then return nil end
  call(b, "SetSize", w, h)
  call(b, "RegisterForClicks", "LeftButtonUp")
  call(b, "SetScript", "OnClick", function() try(onClick) end)
  return b
end

Frame.fill, Frame.button = fill, button

-- After a drag: the frame's centre against the screen's, saved as an offset from the middle.
local function savePlace(f)
  local ok, x, y = try(f.GetCenter, f)
  local ok2, ux, uy = try(UIParent.GetCenter, UIParent)
  if ok and ok2 and type(x) == "number" and type(ux) == "number" then
    UI.savePosition("CENTER", x - ux, y - uy)
  end
end

local function place(f)
  call(f, "ClearAllPoints")
  local pos = UI.loadPosition()
  if pos then call(f, "SetPoint", pos.point, UIParent, pos.point, pos.x, pos.y)
  else call(f, "SetPoint", "CENTER", UIParent, "CENTER", 0, 0) end
end

local function select_(key)
  if Frame.onSelect then try(Frame.onSelect, key) end -- a tab lets go of the keyboard when another is chosen
  Frame.current = key
  for k, t in pairs(Frame.tabs or {}) do
    local on = k == key
    call(t.panel, on and "Show" or "Hide")
    call(t.rule, "SetColorTexture", color(C.gold))
    call(t.rule, on and "Show" or "Hide")
    call(t.icon, "SetVertexColor", color(on and C.title or C.body))
    call(t.label, "SetTextColor", color(on and C.title or C.body))
  end
  local def = UI.tabs[key]
  if def and def.refresh then try(def.refresh, Frame.tabs[key].panel) end
end

-- Makes the button and panel for a tab that has none yet; later registrations of the same key bring a `build`.
local function makeTab(f, def)
  local key = def.key
  local t = {}
  local b = button(f, 90, TABS_H, function() select_(key) end)
  t.button = b
  if TAB_ICON[key] and UI.Art.sprite(key) then
    t.icon = select(2, try(b.CreateTexture, b, nil, "ARTWORK"))
    call(t.icon, "SetTexture", UI.Art.path(UI.Art.UI))
    call(t.icon, "SetTexCoord", UI.Art.sprite(key))
    call(t.icon, "SetSize", 15, 15)
    call(t.icon, "SetPoint", "LEFT", 12, 0)
    call(t.icon, "SetVertexColor", color(C.body))
  end
  t.iconW = t.icon and TAB_ICON_W or 0
  t.label = text(b, 14, C.body)
  call(t.label, "SetPoint", "LEFT", 12 + t.iconW, 0)
  call(t.label, "SetText", def.label)
  local _, w = try(t.label.GetStringWidth, t.label)
  t.textW = type(w) == "number" and w or 60
  t.badge = Frame.badge(b, 18)
  call(t.badge.frame, "SetPoint", "LEFT", b, "LEFT", 12 + t.iconW + t.textW + 6, 0)
  t.rule = fill(b, C.gold, "OVERLAY")
  call(t.rule, "SetPoint", "BOTTOMLEFT", 0, 0)
  call(t.rule, "SetPoint", "BOTTOMRIGHT", 0, 0)
  call(t.rule, "SetHeight", 2)
  call(t.rule, "Hide")
  -- lit: a quieter gold under the word until the tab is chosen
  call(b, "SetScript", "OnEnter", function()
    if Frame.current ~= key then call(t.rule, "SetColorTexture", C.gold[1], C.gold[2], C.gold[3], .45); call(t.rule, "Show") end
  end)
  call(b, "SetScript", "OnLeave", function()
    if Frame.current ~= key then call(t.rule, "Hide") end
  end)
  local ok2, panel = try(CreateFrame, "Frame", nil, f)
  if ok2 and type(panel) == "table" then
    call(panel, "SetPoint", "TOPLEFT", f, "TOPLEFT", 1, -(TITLE_H + TABS_H + 2))
    call(panel, "SetPoint", "BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, FOOT_H + 2)
    call(panel, "Hide")
    local head = text(panel, 20, C.title, "display")
    call(head, "SetPoint", "TOPLEFT", 16, -14)
    local hr = fill(panel, C.gold, "ARTWORK")
    call(hr, "SetPoint", "TOPLEFT", 16, -42)
    call(hr, "SetSize", 28, 2)
    t.panel, t.head, t.hr = panel, head, hr
  end
  return t
end

-- Brings the tab strip in line with the registry: new tabs made, tabs shown or hidden by their `visible()`,
-- and a tab registered again takes its new heading and `build`. Cheap when nothing changed.
function Frame.syncTabs()
  local f = Frame.frame
  if not f then return end
  for key, def in pairs(UI.tabs) do
    local t = Frame.tabs[key]
    if not t then
      t = makeTab(f, def)
      Frame.tabs[key] = t
    end
    if t.def ~= def then
      t.def = def
      call(t.head, "SetText", def.heading or def.label)
      call(t.label, "SetText", def.label)
    end
    if def.build and t.built ~= def.build and t.panel then
      t.built = def.build
      try(def.build, t.panel)
    end
  end
  local list = UI.tabList()
  local sig, left, shown = {}, 8, {}
  for _, def in ipairs(list) do
    local t = Frame.tabs[def.key]
    sig[#sig + 1] = def.key
    shown[def.key] = true
    local width = 12 + t.iconW + t.textW + 12 + (def.count and 24 or 0)
    call(t.button, "SetWidth", width)
    call(t.button, "ClearAllPoints")
    call(t.button, "SetPoint", "TOPLEFT", f, "TOPLEFT", left, -(TITLE_H + 1))
    call(t.button, Frame.sheet and "Hide" or "Show") -- a sheet replaces the tab strip with its own header
    left = left + width + 2
  end
  for key, t in pairs(Frame.tabs) do
    if not shown[key] then
      call(t.button, "Hide")
      call(t.panel, "Hide")
    end
  end
  local joined = table.concat(sig, ",")
  local changed = Frame.layout ~= joined
  Frame.layout = joined
  if Frame.current and not shown[Frame.current] then
    Frame.current = nil
    if list[1] then select_(list[1].key) end
  end
  return changed
end
UI.onTabs = function() Frame.syncTabs() end

-- The sheet header that stands in the tab strip's band: "‹ Back", the title with the gold rule under it, and a count
-- at the right. The chevron is two lines, as the close X is drawn. Starts hidden; Frame.setSheet fills and shows it.
function Frame.buildBand(f)
  local top = -(TITLE_H + 1)
  local back = button(f, 76, TABS_H, function() if Frame.sheet and Frame.sheet.back then try(Frame.sheet.back) end end)
  call(back, "SetPoint", "TOPLEFT", f, "TOPLEFT", 8, top)
  local label = text(back, 13, C.moss)
  call(label, "SetPoint", "LEFT", 14, 0)
  for _, sign in ipairs({ 1, -1 }) do
    local line = fill(back, C.moss, "ARTWORK")
    call(line, "SetSize", 6, 2)
    call(line, "SetPoint", "CENTER", back, "LEFT", 6 + 2.1, -sign * 2.1)
    call(line, "SetRotation", math.rad(45) * sign)
  end
  local title = text(f, 16, C.title, "display")
  local count = text(f, 12, C.muted)
  call(count, "SetPoint", "RIGHT", f, "TOPRIGHT", -16, top - TABS_H / 2)
  local rule = fill(f, C.gold, "OVERLAY")
  call(rule, "SetHeight", 2)
  f.band = { back = back, label = label, title = title, count = count, rule = rule }
  Frame.setSheet(Frame.sheet)
end

-- A sheet laid over the open tab ({ title, count, backLabel, back, close }) or none (nil). While one is open the tabs
-- and their red counts are hidden (the minimap button keeps its own), the header shows instead. No `back`: no Back.
function Frame.setSheet(sheet)
  Frame.sheet = sheet
  local b = Frame.frame and Frame.frame.band
  if not b then return end
  Frame.syncTabs()
  local on, left = sheet ~= nil, sheet and sheet.back and 96 or 16
  call(b.back, on and sheet.back and "Show" or "Hide")
  call(b.label, "SetText", sheet and sheet.backLabel or "")
  call(b.title, "SetText", sheet and sheet.title or "")
  call(b.count, "SetText", sheet and sheet.count or "")
  call(b.title, "ClearAllPoints")
  call(b.title, "SetPoint", "LEFT", Frame.frame, "TOPLEFT", left, -(TITLE_H + 1 + TABS_H / 2))
  local _, w = try(b.title.GetStringWidth, b.title)
  call(b.rule, "ClearAllPoints")
  call(b.rule, "SetPoint", "BOTTOMLEFT", Frame.frame, "TOPLEFT", left, -(TITLE_H + TABS_H))
  call(b.rule, "SetWidth", type(w) == "number" and w > 0 and w or 40)
  for _, k in ipairs({ "title", "count", "rule" }) do call(b[k], on and "Show" or "Hide") end
end

function Frame.build()
  if Frame.frame then return Frame.frame end
  local ok, f = try(CreateFrame, "Frame", Frame.NAME, UIParent, "BackdropTemplate")
  if not ok or type(f) ~= "table" then return nil end
  Frame.frame, Frame.tabs = f, {}
  call(f, "SetSize", Frame.W, Frame.H)
  call(f, "SetFrameStrata", "HIGH")
  call(f, "SetMovable", true)
  call(f, "SetClampedToScreen", true)
  call(f, "EnableMouse", true)
  call(f, "RegisterForDrag", "LeftButton")
  call(f, "SetScript", "OnDragStart", function(self) call(self, "StartMoving") end)
  call(f, "SetScript", "OnHide", function() if Frame.onHide then try(Frame.onHide) end end) -- Escape hides it too
  -- If anything other than Frame.show ever shows the window, the tab still draws (the signature skips a repeat)
  call(f, "SetScript", "OnShow", function() if Frame.refreshTab then try(Frame.refreshTab) end end)
  call(f, "SetScript", "OnDragStop", function(self)
    call(self, "StopMovingOrSizing")
    try(savePlace, self)
  end)
  call(f, "SetBackdrop", { bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  call(f, "SetBackdropColor", color(C.ground))
  call(f, "SetBackdropBorderColor", color(C.lineStrong))
  -- the dark outer line, so it holds against a bright world
  local outer = fill(f, C.outer, "BACKGROUND")
  call(outer, "SetPoint", "TOPLEFT", -1, 1)
  call(outer, "SetPoint", "BOTTOMRIGHT", 1, -1)
  call(outer, "SetDrawLayer", "BACKGROUND", -8)
  place(f)
  call(f, "Hide")

  -- the painted header: the picture cropped to the window (never stretched), the mark and the word over it
  local bar = fill(f, C.surface, "BACKGROUND")
  call(bar, "SetPoint", "TOPLEFT", 1, -1)
  call(bar, "SetPoint", "TOPRIGHT", -1, -1)
  call(bar, "SetHeight", TITLE_H)
  local pic = select(2, try(f.CreateTexture, f, nil, "ARTWORK"))
  call(pic, "SetDrawLayer", "ARTWORK", -1)
  call(pic, "SetTexture", UI.Art.path(UI.Art.HEADER))
  call(pic, "SetTexCoord", Frame.headerCrop(Frame.W))
  call(pic, "SetPoint", "TOPLEFT", 1, -1)
  call(pic, "SetPoint", "TOPRIGHT", -1, -1)
  call(pic, "SetHeight", TITLE_H)
  local rule = fill(f, C.line, "BORDER")
  call(rule, "SetPoint", "TOPLEFT", 1, -(TITLE_H + 1))
  call(rule, "SetPoint", "TOPRIGHT", -1, -(TITLE_H + 1))
  call(rule, "SetHeight", 1)
  -- the mark, 24 px (brand/README.md); the dusk colours it is drawn in
  local mark = select(2, try(f.CreateTexture, f, nil, "ARTWORK"))
  call(mark, "SetTexture", "Interface\\AddOns\\Tintean\\mark")
  call(mark, "SetSize", 24, 24)
  call(mark, "SetPoint", "LEFT", f, "TOPLEFT", 12, -20)
  local wm = text(f, 14, C.body, "display")
  call(wm, "SetPoint", "LEFT", mark, "RIGHT", 10, 0)
  call(wm, "SetText", UI.TEXT.wordmark)
  call(wm, "SetShadowOffset", 1, -1)
  call(wm, "SetShadowColor", 0, 0, 0, .6)
  -- the guild's name at the bottom, large, with the faction chip beside it
  f.guild = text(f, 26, C.title, "display")
  call(f.guild, "SetPoint", "BOTTOMLEFT", f, "TOPLEFT", 14, -(TITLE_H - 10))
  call(f.guild, "SetWidth", 380)
  call(f.guild, "SetWordWrap", false)
  call(f.guild, "SetShadowOffset", 1, -1)
  call(f.guild, "SetShadowColor", 0, 0, 0, .6)
  local okc, chip = try(CreateFrame, "Frame", nil, f)
  if okc and type(chip) == "table" then
    call(chip, "SetSize", 60, 20)
    call(chip, "SetPoint", "BOTTOMLEFT", f.guild, "BOTTOMRIGHT", 10, 3)
    call(fill(chip, C.headEdge, "BACKGROUND"), "SetAllPoints")
    local face = fill(chip, C.headBtn, "BACKGROUND")
    call(face, "SetPoint", "TOPLEFT", 1, -1)
    call(face, "SetPoint", "BOTTOMRIGHT", -1, 1)
    call(face, "SetDrawLayer", "BACKGROUND", 1)
    f.chipText = text(chip, 10, C.muted)
    call(f.chipText, "SetPoint", "CENTER")
    call(f.chipText, "SetJustifyH", "CENTER")
    call(chip, "Hide")
    f.chip = chip
  end

  local function headButton(w, fn)
    local b = button(f, w, 28, fn)
    if not b then return nil end
    b.edge, b.face = fill(b, C.headEdge, "BACKGROUND"), fill(b, C.headBtn, "BACKGROUND")
    call(b.edge, "SetAllPoints")
    call(b.face, "SetPoint", "TOPLEFT", 1, -1)
    call(b.face, "SetPoint", "BOTTOMRIGHT", -1, 1)
    call(b.face, "SetDrawLayer", "BACKGROUND", 1)
    b.look = { bg = C.headBtn, edge = C.headEdge }
    Frame.feel(b)
    return b
  end
  local x = headButton(28, function() Frame.hide() end)
  call(x, "SetPoint", "RIGHT", f, "TOPRIGHT", -7, -20)
  for _, rot in ipairs({ math.rad(45), math.rad(-45) }) do
    local line = fill(x, C.body, "ARTWORK")
    call(line, "SetSize", 14, 2)
    call(line, "SetPoint", "CENTER")
    call(line, "SetRotation", rot)
  end
  f.close = x
  local gear = headButton(62, function()
    local sh = Frame.sheet -- Settings while it is open: the button acts as Back
    if sh and sh.back and sh.title == UI.TEXT.settings then try(sh.back) else Frame.show("settings") end
  end)
  call(gear, "SetPoint", "RIGHT", x, "LEFT", -4, 0)
  local gl = text(gear, 12, C.body)
  call(gl, "SetPoint", "CENTER")
  call(gl, "SetText", UI.TEXT.settings)
  if gear then gear.label, gear.anchor = gl, { "CENTER", 0, 0 } end
  f.gear = gear

  -- the gold rule turned at each corner: an angle, no dot (Joe, 14 Nov)
  local function corner(point, sx, sy)
    for _, size in ipairs({ { 14, 1 }, { 1, 14 } }) do
      local line = fill(f, { C.gold[1], C.gold[2], C.gold[3], .85 }, "OVERLAY")
      call(line, "SetSize", size[1], size[2])
      call(line, "SetPoint", point, f, point, 3 * sx, 3 * sy)
    end
  end
  corner("TOPLEFT", 1, -1); corner("TOPRIGHT", -1, -1); corner("BOTTOMLEFT", 1, 1); corner("BOTTOMRIGHT", -1, 1)

  -- foot: the status line
  local foot = fill(f, C.surface, "BACKGROUND")
  call(foot, "SetPoint", "BOTTOMLEFT", 1, 1)
  call(foot, "SetPoint", "BOTTOMRIGHT", -1, 1)
  call(foot, "SetHeight", FOOT_H)
  local frule = fill(f, C.line, "BORDER")
  call(frule, "SetPoint", "BOTTOMLEFT", 1, FOOT_H + 1)
  call(frule, "SetPoint", "BOTTOMRIGHT", -1, FOOT_H + 1)
  call(frule, "SetHeight", 1)
  f.status = text(f, 12, C.muted)
  call(f.status, "SetPoint", "LEFT", f, "BOTTOMLEFT", 14, FOOT_H / 2 + 1)
  call(f.status, "SetWidth", Frame.W - 28)
  call(f.status, "SetWordWrap", false)

  -- tabs and their panels
  local trule = fill(f, C.line, "BORDER")
  call(trule, "SetPoint", "TOPLEFT", 1, -(TITLE_H + TABS_H + 1))
  call(trule, "SetPoint", "TOPRIGHT", -1, -(TITLE_H + TABS_H + 1))
  call(trule, "SetHeight", 1)
  Frame.buildBand(f)
  Frame.syncTabs()

  if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, Frame.NAME) end
  Frame.refresh(true)
  return f
end

-- The status line, the guild's name and the red counts, from what the addon holds now. What is waiting is
-- worked out once and fed to the tab badges and the minimap's. A shut window is not drawn into unless `force`.
function Frame.refresh(force)
  local f = Frame.frame
  if not f then return end
  local events, bulletins = UI.waiting()
  if force or Frame.isShown() then
    Frame.syncTabs()
    local env = Frame.env()
    call(f.guild, "SetText", UI.esc(env.guildName) or "")
    local _, gw = try(f.guild.GetStringWidth, f.guild)
    if type(gw) == "number" and gw > 0 then call(f.guild, "SetWidth", math.min(gw + 2, 380)) end
    local _, faction = try(UnitFactionGroup, "player")
    local word, ink = Frame.chipFor(faction)
    if word and env.guildName ~= "" then
      call(f.chipText, "SetText", word)
      call(f.chipText, "SetTextColor", color(ink))
      call(f.chip, "Show")
    else
      call(f.chip, "Hide")
    end
    call(f.status, "SetText", UI.statusLine(env))
    for key, t in pairs(Frame.tabs or {}) do
      local def = UI.tabs[key]
      local n = def and def.count and select(2, try(def.count, events, bulletins)) or nil
      Frame.setBadge(t.badge, n)
    end
  end
  if Frame.onRefresh then try(Frame.onRefresh, events, bulletins) end
end

function Frame.isShown()
  return Frame.frame ~= nil and select(2, call(Frame.frame, "IsShown")) == true
end

-- Opens on `key` (a registered tab; anything else keeps the tab it was on, else the first).
function Frame.show(key)
  local f = Frame.build()
  if not f then return false end
  local sheet = key == "settings" and key or nil -- not a tab: the sheet laid over the one that is open
  if not (key and Frame.tabs[key]) then key = Frame.current or (UI.tabList()[1] or {}).key
  elseif Frame.sheet then try(Frame.sheet.close) end -- a tab was asked for: its sheet gives way
  call(f, "Show") -- shown first: text is set only where it can be seen (the header, status line, tabs, EventsTab render)
  Frame.refresh(true)
  if key then select_(key) end
  if sheet and UI.openSheet then try(UI.openSheet, sheet) end
  return true
end

function Frame.hide()
  if Frame.onHide then try(Frame.onHide) end
  call(Frame.frame, "Hide")
end

function Frame.toggle(key)
  if Frame.isShown() then Frame.hide() else Frame.show(key) end
end

-- Every five seconds; not at all in combat, where nothing here needs to be right.
function Frame.tick()
  local ok, inCombat = try(InCombatLockdown)
  if ok and inCombat then return end
  try(Frame.refresh)
  if Frame.isShown() then try(Frame.refreshTab) end
end

-- The open tab draws itself again from what the addon holds (a sign-up from a guildmate, a clock moving on).
function Frame.refreshTab()
  local t = Frame.current and Frame.tabs[Frame.current]
  local def = Frame.current and UI.tabs[Frame.current]
  if t and def and def.refresh and t.panel then try(def.refresh, t.panel) end
end

if type(CreateFrame) == "function" then
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("PLAYER_LOGIN")
  ev:SetScript("OnEvent", function()
    try(Frame.build)
    -- the counts and the status line follow the store; nothing is drawn while the window is shut but the button
    if C_Timer and C_Timer.NewTicker then try(C_Timer.NewTicker, 5, Frame.tick) end
  end)
end
