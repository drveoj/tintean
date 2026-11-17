-- The Bulletins tab, drawn from UI.Bulletins (the model) with the Events tab's drawing helpers on a canvas of its own.
-- Pages are parchment (what is written), the strip and heading are dusk. Reading a bulletin is *Seen*, which goes through
-- Edit.seen like any other edit; the red counts follow it at once. Sheet: docs/mockups/addon/Bulletins.html and
-- docs/mockups/addon-look/Others.html.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame, B, ET = UI.Frame, UI.Bulletins, UI.EventsTab
local C = UI.COLORS
local try, call = function(...) return ns.try(...) end, Frame.call
local K = ET.kit

local T = {}
UI.BulletinsTab = T
T.hooks = {} -- the officers' (BulletinOfficersTab.lua): tools(p, y, env), after(env, y), built(panel)

local X, W = 16, 606
local cv = { pools = {} }
local sig

local function now()
  local ok, t = try(time)
  return ok and type(t) == "number" and t or 0
end

local render

-- A refusal that only says "you had already" is no refusal; any other is the Events tab's plain line.
local function markSeen(id)
  local ok, res = try(ns.Edit.seen, id)
  if not (ok and (res == "sent" or res == "kept" or res == "refused: already_seen")) then
    UI.statusNote = { text = UI.Events.TEXT.refused, untilAt = now() + 30 }
  end
  Frame.refresh(true)
  render()
end

local function drawPage(p, y)
  local ink = C.sheetInk
  local top, yy = y, y + 12
  yy = yy + K.text(p.title, X + 18, yy, { size = 19, color = ink, font = "display", width = W - 36 }) + 4
  if p.text ~= "" then yy = yy + K.text(p.text, X + 18, yy, { size = 14, color = ink, width = W - 36 }) + 10 end
  local _, fw = K.text(p.foot, X + 18, yy + 5, { size = 12, color = K.dim(ink, .75) })
  if p.event then
    local lx = X + 18 + fw + 18
    K.placePic(p.event.art, lx, yy + 3, 20)
    local _, lw = K.text(p.event.title, lx + 28, yy + 5, { size = 13, color = C.sea })
    K.chevron(lx + 28 + lw + 10, yy + 12, 1, C.sea)
    K.button(lx, yy, lw + 52, 24, "", function() ET.open(p.event.id) end, {})
  end
  if p.state == "unseen" then
    K.button(X + W - 18 - 70, yy - 1, 70, 26, B.TEXT.seen, function() markSeen(p.id) end,
      { bg = C.sheet, edge = K.dim(ink, .25), ink = ink, size = 12 })
  elseif p.state == "seen" then
    K.text(B.TEXT.seenAfter, X + W - 18, yy + 5, { size = 12, color = K.dim(ink, .75), right = true })
  end
  yy = yy + 34
  if T.hooks.tools then yy = T.hooks.tools(p, yy, Frame.env()) or yy end -- an officer's Take it down and Post in guild chat
  K.rect(X, top, W, yy - top, C.sheet, 1)
  return yy + 10
end

local function draw(env)
  local t = B.tab(env)
  local y = K.strip(t.strip, 8)
  y = K.heading("Up now", nil, y)
  local after = T.hooks.after or function(_, yy) return yy end -- Write a bulletin, for an officer
  if #t.pages == 0 then
    K.scene("book", X, y)
    return after(env, y + math.max(K.text(B.TEXT.empty, X + 144, y + 4, { size = 14, width = W - 144 }) + 4, 64) + 12) or y
  end
  for _, p in ipairs(t.pages) do y = drawPage(p, y) end
  return after(env, y) or y
end

-- A drawing depends on the guild's table, the store's touches, the minute, the window's width and the status note.
local function signature(env)
  return { env.guild, ns.Sync.rev, math.floor((env.now or 0) / 60), Frame.W, UI.statusNote and UI.statusNote.text }
end

-- Every action draws again (render()); the tab's own refresh (every few seconds) draws only if something has changed.
function render(quiet)
  if not cv.child then return end
  local _, seen = call(cv.child, "IsVisible") -- nothing is drawn where it can't be seen (M20.15)
  if seen == false then sig = nil; return end
  local env = Frame.env()
  local s = signature(env)
  if quiet and sig then
    local same = true
    for i = 1, 5 do if s[i] ~= sig[i] then same = false end end
    if same then return end
  end
  sig = s
  ET.canvas(cv, function()
    K.begin()
    local y
    local ok = try(function() y = draw(env) end)
    if not ok then sig = nil end -- try again at the next refresh
    K.finish(ok and y or 8)
  end)
end
T.render = function() render(true) end
T.draw = function() render() end -- after an officer's action: draw again at once

function T.build(panelFrame)
  local tab = Frame.tabs.bulletins
  if tab then call(tab.head, "Hide"); call(tab.hr, "Hide") end -- the heading is drawn with the content
  local ok, sf = try(CreateFrame, "ScrollFrame", nil, panelFrame)
  if not ok or type(sf) ~= "table" then return end
  call(sf, "SetPoint", "TOPLEFT", panelFrame, "TOPLEFT", 0, -4)
  call(sf, "SetPoint", "BOTTOMRIGHT", panelFrame, "BOTTOMRIGHT", 0, 0)
  local ok2, child = try(CreateFrame, "Frame", nil, sf)
  if not ok2 or type(child) ~= "table" then return end
  call(child, "SetSize", Frame.W - 2, 400)
  call(sf, "SetScrollChild", child)
  call(sf, "EnableMouseWheel", true)
  call(sf, "SetScript", "OnMouseWheel", function(self, delta)
    local _, cur = call(self, "GetVerticalScroll")
    local _, ch = call(child, "GetHeight")
    local _, sh = call(self, "GetHeight")
    local top = math.max((type(ch) == "number" and ch or 0) - (type(sh) == "number" and sh or 0), 0)
    call(self, "SetVerticalScroll", math.min(math.max((type(cur) == "number" and cur or 0) - delta * 40, 0), top))
  end)
  cv.scroll, cv.child = sf, child
  if T.hooks.built then try(T.hooks.built, panelFrame) end -- the officers' sheet goes over this panel
  render()
end

UI.registerTab("bulletins", { label = "Bulletins", heading = "Up now", order = 20, build = T.build, refresh = T.render,
  count = function(_, bulletins) return bulletins end })

return T
