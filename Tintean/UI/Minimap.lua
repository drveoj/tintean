-- The button on the minimap's rim (docs/mockups/addon/Minimap.html): left-click opens the window, right-click
-- opens settings, drag moves it round the rim. The tooltip is the game's own (GameTooltip).
-- The count is a square: no mask file is named, because a mask the game lacks would hide the
-- texture and nothing in Lua can tell. Round is a follow-up once a shipped mask is checked in game.
-- Made at PLAYER_LOGIN, a child of Minimap; unless the saved setting hides it.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame = UI.Frame
local Button = {}
UI.Button = Button

local C = UI.COLORS
local try = function(...) return ns.try(...) end
local function call(obj, method, ...)
  if type(obj) ~= "table" then return false end
  return try(obj[method], obj, ...)
end

local KIND = { title = C.title, dim = C.muted, plain = C.ink, hint = C.moss }

-- The tooltip's lines, added to `tip` (the button's, or the one a launcher's host passes).
local function addLines(tip)
  for _, l in ipairs(UI.tooltip(Frame.env())) do
    local c = KIND[l[2]] or C.ink
    call(tip, "AddLine", l[1] == "" and " " or l[1], c[1], c[2], c[3], true)
  end
end

local function showTip(self)
  if not GameTooltip then return end
  call(GameTooltip, "SetOwner", self, "ANCHOR_LEFT")
  addLines(GameTooltip)
  call(GameTooltip, "Show")
end

-- On a left-click: Events, or Bulletins when only a bulletin waits.
function Button.click(btn)
  if btn == "RightButton" then
    Frame.show("settings")
    return
  end
  local events, bulletins = UI.waiting()
  Frame.toggle(events == 0 and bulletins > 0 and "bulletins" or "events")
end

-- Puts the button at `angle` degrees round the rim.
function Button.place(angle)
  local b = Button.frame
  if not b then return end
  local _, w = try(Minimap.GetWidth, Minimap)
  local x, y = UI.rim(angle, (type(w) == "number" and w or 140) / 2 + 4)
  call(b, "ClearAllPoints")
  call(b, "SetPoint", "CENTER", Minimap, "CENTER", x, y)
end

local function dragging()
  local _, cx, cy = try(Minimap.GetCenter, Minimap)
  local _, mx, my = try(GetCursorPosition)
  local _, scale = try(Minimap.GetEffectiveScale, Minimap)
  if type(cx) ~= "number" or type(mx) ~= "number" or type(scale) ~= "number" or scale == 0 then return end
  local angle = UI.angleOf(mx / scale - cx, my / scale - cy)
  Button.angle = angle
  Button.place(angle)
end

function Button.build()
  if Button.frame or not Minimap then return Button.frame end
  local ok, b = try(CreateFrame, "Button", "TinteanMinimapButton", Minimap)
  if not ok or type(b) ~= "table" then return nil end
  Button.frame = b
  call(b, "SetSize", 32, 32)
  call(b, "SetFrameStrata", "MEDIUM")
  call(b, "SetFrameLevel", 8)
  call(b, "RegisterForClicks", "LeftButtonUp", "RightButtonUp")
  call(b, "RegisterForDrag", "LeftButton")
  -- the mark on its own round ground (brand/minimap-32.png, shipped as a TGA)
  -- The picture is the button's normal texture and `b.icon`, the two places a minimap-button collector looks for
  -- one. A collector that finds neither falls back to the first letter of the button's name.
  local path = "Interface\\AddOns\\Tintean\\minimap"
  call(b, "SetNormalTexture", path)
  local art = select(2, call(b, "GetNormalTexture"))
  if type(art) ~= "table" then
    art = select(2, try(b.CreateTexture, b, nil, "ARTWORK"))
    call(art, "SetTexture", path)
  end
  call(art, "SetAllPoints")
  b.icon, b.Icon = art, art
  -- a gold ring of our own over the edge (a drawn TGA, so no Blizzard art and no mask)
  local edge = select(2, try(b.CreateTexture, b, nil, "OVERLAY"))
  call(edge, "SetTexture", "Interface\\AddOns\\Tintean\\minimap-ring")
  call(edge, "SetAllPoints")
  Button.dot = Frame.badge(b, 18)
  if Button.dot.frame then
    call(Button.dot.frame, "SetPoint", "CENTER", b, "TOPRIGHT", -2, -2)
    call(Button.dot.frame, "SetFrameLevel", 10)
  end
  call(b, "SetScript", "OnClick", function(_, btn) try(Button.click, btn) end)
  call(b, "SetScript", "OnEnter", function(self) try(showTip, self) end)
  call(b, "SetScript", "OnLeave", function() if GameTooltip then call(GameTooltip, "Hide") end end)
  call(b, "SetScript", "OnDragStart", function(self)
    if GameTooltip then call(GameTooltip, "Hide") end
    call(self, "SetScript", "OnUpdate", function() try(dragging) end)
  end)
  call(b, "SetScript", "OnDragStop", function(self)
    call(self, "SetScript", "OnUpdate", nil)
    if Button.angle then UI.saveAngle(Button.angle) end
  end)
  Button.place(UI.loadAngle())
  if UI.minimapHidden() then call(b, "Hide") end
  Frame.onRefresh = Button.refresh
  Button.refresh()
  return b
end

-- The red count: events to answer this week plus bulletins not seen.
function Button.refresh(events, bulletins)
  if not Button.dot then return end
  if not events then events, bulletins = UI.waiting() end
  Frame.setBadge(Button.dot, events + bulletins)
end

-- A launcher for the addons that list launchers (a minimap-button collector reads `icon` from it), registered through
-- the embedded LibDataBroker-1.1 (Libs/). Still guarded: if LibStub or the library is missing, nothing happens.
-- Draws nothing: the button above is the only one.
function Button.launcher()
  local lib = _G.LibStub
  if not lib then return nil end
  local ok, ldb = try(function() return lib("LibDataBroker-1.1", true) end) -- LibStub is a callable table
  if not (ok and type(ldb) == "table") then return nil end
  local ok2, obj = try(ldb.NewDataObject, ldb, "Tintean", {
    type = "launcher",
    text = UI.TEXT.wordmark,
    icon = "Interface\\AddOns\\Tintean\\minimap",
    OnClick = function(_, btn) try(Button.click, btn) end,
    OnTooltipShow = function(tip) try(addLines, tip) end,
  })
  Button.object = ok2 and obj or nil
  return Button.object
end

if type(CreateFrame) == "function" then
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("PLAYER_LOGIN")
  ev:SetScript("OnEvent", function() try(Button.build); try(Button.launcher) end)
end
