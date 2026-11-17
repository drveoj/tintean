-- Settings and the first-run steps, drawn from UI.Settings (the model): one sheet laid over the Events panel (as Plan an
-- event is) with a canvas of its own and the Events tab's drawing helpers. Also the /tintean commands. Sheets:
-- docs/mockups/addon/Settings.html, FirstRun.html, Slash.html; the look: addon-look/Empty.html (a scene per step).
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame, St, ET = UI.Frame, UI.Settings, UI.EventsTab
local C = UI.COLORS
local try, call = function(...) return ns.try(...) end, Frame.call
local K = ET.kit

local T = {}
UI.SettingsTab = T

local X, W = 16, 606
local cv = { pools = {} }
local mode, step -- "settings", "tour" or nil; the step shown

local render

local function applyMinimap()
  local b = UI.Button and UI.Button.frame
  if b then call(b, UI.minimapHidden() and "Hide" or "Show") end
end

local function close()
  mode = nil
  call(cv.scroll, "Hide")
end

local function finishTour()
  St.markTour(select(2, try(time)))
  close()
end

---------------------------------------------------------------------------------------------- drawing

local function toggle(t, y)
  K.button(X + 1, y, W - 2, 34, "", function() St.flip(t[1]); if t[1] == "minimap" then applyMinimap() end; render() end, {})
  local on = St.get(t[1])
  K.rect(X + 14, y + 9, 16, 16, on and C.sea or C.lineStrong, 3)
  K.rect(X + 15, y + 10, 14, 14, on and C.sea or C.ground, 4)
  -- Our own gold tick from ui.tga.
  local l, r, tp, bt = UI.Art.sprite("check")
  if on and l then K.pic(X + 12, y + 7, 20, 20, UI.Art.path(UI.Art.UI), { l, r, tp, bt }, 1, C.gold, { kind = "check", sub = 2 }) end
  K.text(t[2], X + 42, y + 8, { size = 14, color = C.title })
  return y + 34
end

local function drawSettings(env)
  local y = 8
  K.button(X, y, 76, 22, St.TEXT.back, close, { size = 13, align = "left" })
  K.chevron(X + 4, y + 11, -1, C.moss)
  y = K.heading(St.TEXT.notices, nil, y + 30)
  local top = y
  for _, t in ipairs(St.TOGGLES) do y = toggle(t, y) end
  K.panel(X, top, W, y - top)
  y = y + 8 + K.text(St.TEXT.waits, X, y + 8, { size = 12, color = C.muted, width = W }) + 8
  y = K.heading(St.TEXT.sharing, nil, y + 8)
  top = y
  y = toggle(St.SHARE, y)
  K.text(St.TEXT.shareNote, X + 42, y - 6, { size = 12, color = C.muted, width = W - 56 })
  y = y + 22
  y = toggle(St.MOMENTS, y)
  y = y + K.text(St.TEXT.momentsHelp, X + 42, y - 6, { size = 12, color = C.muted, width = W - 56 }) + 2
  K.panel(X, top, W, y - top)
  y = y + 8 + K.text(St.TEXT.chatFact, X, y + 8, { size = 12, color = C.muted, width = W }) + 8
  y = K.heading(St.TEXT.data, nil, y + 8)
  top = y
  K.text(St.TEXT.refills, X + 14, y + 12, { size = 13, color = C.body, width = W - 28 })
  local bx, by = X + 14, y + 40
  local function b(label, fn, o)
    local w = #label * 7 + 28
    K.button(bx, by, w, 28, label, fn, o or { bg = C.ground, edge = C.lineStrong, ink = C.body, size = 13 })
    bx = bx + w + 8
  end
  if UI.Paste and UI.Paste.open then b(St.TEXT.paste, function() close(); UI.Paste.open() end) end
  b(St.TEXT.tour, function() T.open("tour") end)
  b(St.TEXT.clear, function() St.clear(env.guild); Frame.refresh(true); render() end,
    { bg = C.ground, edge = C.flame, ink = C.flame, size = 13 })
  y = by + 40
  K.panel(X, top, W, y - top)
  return y + 12 + K.text(St.statusLine(), X, y + 12, { size = 12, color = C.muted, width = W }) + 8
end

local function drawTour(env)
  local s = St.step(step, env.guildName)
  local y = K.heading(s.title, nil, 8)
  K.text(s.count, X + W, y - 34, { size = 12, color = C.muted, right = true })
  local top = y
  K.scene(s.scene, X + 14, y + 14)
  local ty = y + 14
  for _, line in ipairs(s.body) do ty = ty + K.text(line, X + 158, ty, { size = 14, color = C.title, width = W - 172 }) + 8 end
  y = math.max(ty, y + 14 + 64) + 14
  K.panel(X, top, W, y - top)
  y = y + 12
  local actions = {
    next = function() step = step + 1; render() end,
    back = function() step = step - 1; render() end,
    skip = finishTour, done = finishTour,
    openSettings = function() finishTour(); T.open("settings") end,
  }
  local x = X
  for _, k in ipairs(s.buttons) do
    local w, primary = #St.TEXT[k] * 7 + 32, k == "next" or k == "done"
    K.button(x, y, w, 30, St.TEXT[k], actions[k], primary and { bg = C.sea, ink = C.title, size = 13 }
      or { bg = C.ground, edge = C.lineStrong, ink = C.body, size = 13 })
    x = x + w + 8
  end
  return y + 42
end

function render()
  if not cv.child or not mode then return end
  local _, seen = call(cv.child, "IsVisible")
  if seen == false then return end
  ET.canvas(cv, function()
    K.begin()
    local y
    local ok = try(function() y = (mode == "tour" and drawTour or drawSettings)(Frame.env()) end)
    K.finish(ok and y or 8)
  end)
end

-- Opens the sheet ("settings" or "tour") over the Events panel.
function T.open(which)
  if not cv.child then return false end
  mode, step = which, 1
  call(cv.scroll, "SetVerticalScroll", 0)
  call(cv.scroll, "Show")
  render()
  return true
end

function T.build()
  local tab = Frame.tabs.events
  if not tab or not tab.panel or cv.child then return end
  local ok, sf = try(CreateFrame, "ScrollFrame", nil, Frame.frame)
  if not ok or type(sf) ~= "table" then return end
  call(sf, "SetPoint", "TOPLEFT", tab.panel, "TOPLEFT", 0, -4)
  call(sf, "SetPoint", "BOTTOMRIGHT", tab.panel, "BOTTOMRIGHT", 0, 0)
  call(sf, "SetFrameLevel", 30)
  local ok2, child = try(CreateFrame, "Frame", nil, sf)
  if not ok2 or type(child) ~= "table" then return end
  call(child, "SetSize", Frame.W - 2, 400)
  call(Frame.fill(sf, C.ground, "BACKGROUND"), "SetAllPoints") -- hides the tab under the sheet
  call(sf, "SetScrollChild", child)
  call(sf, "EnableMouse", true)
  call(sf, "EnableMouseWheel", true)
  call(sf, "SetScript", "OnMouseWheel", function(self, delta)
    local _, cur = call(self, "GetVerticalScroll")
    local _, ch = call(child, "GetHeight")
    local _, sh = call(self, "GetHeight")
    local top = math.max((type(ch) == "number" and ch or 0) - (type(sh) == "number" and sh or 0), 0)
    call(self, "SetVerticalScroll", math.min(math.max((type(cur) == "number" and cur or 0) - delta * 40, 0), top))
  end)
  call(sf, "SetScript", "OnHide", function() mode = nil; call(sf, "Hide") end) -- the window shut: the sheet is not still open
  call(sf, "Hide")
  cv.scroll, cv.child = sf, child
end
ET.hooks.built = (function(prior)
  return function() if prior then try(prior) end; T.build() end
end)(ET.hooks.built)

-- The window on `tab`, or on the sheet ("settings"), as Frame.show(key) asks.
UI.openSheet = function(which) return T.open(which) end

---------------------------------------------------------------------------------------------- commands

local function say(s) ns.print(s) end

-- Handles a /tintean line the loader doesn't own. True when it did something.
function ns.slash(msg)
  local r = St.route(msg)
  local k = r[1]
  if k == "open" then return Frame.show()
  elseif k == "tab" then return Frame.show(r[2])
  elseif k == "settings" then return Frame.show("settings")
  elseif k == "tour" then Frame.show(); return T.open("tour")
  elseif k == "minimap" then
    St.flip("minimap")
    applyMinimap()
    return true
  elseif k == "paste" then
    if UI.Paste and UI.Paste.open then UI.Paste.open(); return true end
  elseif k == "help" then
    say(ns.tag .. " " .. ns.version .. ". " .. St.TEXT.helpHead)
    for _, l in ipairs(St.HELP) do say(l) end
    return true
  end
  say(St.unknown(r[2] or "paste"))
  return true
end

-- Once, ten seconds after the first login with the addon, never in combat (retried every ten seconds until it can).
local function attempt()
  if not St.tourDue() then return end
  local ok, inCombat = try(InCombatLockdown)
  if (ok and inCombat) or not (ns.state and ns.state.db) then
    if C_Timer and C_Timer.After then C_Timer.After(10, function() try(attempt) end) end
    return
  end
  if Frame.show() then T.open("tour") end
end
T.attempt = attempt

if type(CreateFrame) == "function" then
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("PLAYER_LOGIN")
  ev:SetScript("OnEvent", function()
    if C_Timer and C_Timer.After then C_Timer.After(10, function() try(attempt) end) end
  end)
end

return T
