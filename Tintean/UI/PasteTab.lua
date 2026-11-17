-- Copy and paste, drawn from UI.Paste (the model): a sheet laid over the Events panel (as Settings is), reached from
-- Settings and /tintean paste, never a tab. Two single-line boxes: what goes to the website (read-only, selected for Ctrl+C)
-- and what comes from it (Ctrl+V, then Import). Sheet: docs/mockups/addon/Paste.html.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame, P, ET = UI.Frame, UI.Paste, UI.EventsTab
local C = UI.COLORS
local try, call, color = function(...) return ns.try(...) end, Frame.call, Frame.color
local K = ET.kit

local T = {}
UI.PasteTab = T

local X, W = 16, 606
local cv = { pools = {} }
local boxes = {}
local out, result, open -- the outgoing string; { ok, line } after Import; whether the sheet is up

local render

local function hideBoxes()
  for _, b in pairs(boxes) do
    call(b, "ClearFocus")
    call(b, "Hide")
  end
end

local function close()
  open, result = false, nil
  hideBoxes()
  call(cv.scroll, "Hide")
end

-- A box of one line; `fixed` (the outgoing string) puts the text back and selects it again after any edit.
local function box(key, fixed)
  if boxes[key] then return boxes[key] end
  local ok, eb = try(CreateFrame, "EditBox", nil, cv.child)
  if not ok or type(eb) ~= "table" then return nil end
  local _, locale = try(GetLocale)
  local path = UI.ownFont("body", locale)
  if not (path and select(2, call(eb, "SetFont", path, 12, ""))) then call(eb, "SetFont", STANDARD_TEXT_FONT, 12, "") end
  call(eb, "SetAutoFocus", false)
  call(eb, "SetMaxLetters", ns.Pack.MAX_CHARS + 1024) -- more than the codec reads: a longer paste is cut and refused as cut off
  call(eb, "SetTextInsets", 8, 8, 0, 0)
  call(eb, "SetTextColor", color(C.ink))
  call(Frame.fill(eb, C.lineStrong, "BACKGROUND"), "SetAllPoints")
  local inner = Frame.fill(eb, C.ground, "BACKGROUND")
  call(inner, "SetPoint", "TOPLEFT", 1, -1)
  call(inner, "SetPoint", "BOTTOMRIGHT", -1, 1)
  call(inner, "SetDrawLayer", "BACKGROUND", 1)
  call(eb, "SetScript", "OnEscapePressed", function(self) call(self, "ClearFocus") end)
  if fixed then
    call(eb, "SetScript", "OnTextChanged", function(self, byUser)
      if byUser and not boxes.busy and out and out.text then
        boxes.busy = true
        call(self, "SetText", out.text)
        call(self, "HighlightText")
        boxes.busy = false
      end
    end)
    call(eb, "SetScript", "OnEditFocusGained", function(self) call(self, "HighlightText") end)
  end
  boxes[key] = eb
  return eb
end

local function put(key, x, y, w, value, fixed)
  local eb = box(key, fixed)
  if not eb then return end
  call(eb, "ClearAllPoints")
  call(eb, "SetPoint", "TOPLEFT", cv.child, "TOPLEFT", x, -y)
  call(eb, "SetSize", w, 28)
  if cv.reset then
    boxes.busy = true
    call(eb, "SetText", value or "")
    boxes.busy = false
  end
  call(eb, "Show")
end

---------------------------------------------------------------------------------------------- the action

local function context()
  local env = Frame.env()
  local _, slug = try(function() return ns.Sync.slug() end)
  local _, me = try(ns.Receive.myName)
  local st = ns.state
  return { db = st and st.db, readOnly = st and st.readOnly, slug = slug, guildName = env.guildName,
    character = type(me) == "string" and me or nil, now = env.now, boss = env.boss, counters = st and st.counters,
    date = env.date }
end

local function doImport()
  local _, s = call(boxes.from, "GetText")
  local ok, good, line = try(P.import, s, context())
  result = ok and { ok = good, line = line } or { ok = false, line = P.TEXT.unreadable }
  if good then
    call(boxes.from, "SetText", "")
    call(boxes.from, "ClearFocus")
    ns.Sync.touch()
    Frame.refresh(true)
    local env = Frame.env()
    out = P.outgoing(ns.Sync.slug(), env.guild, ns.state and ns.state.db, env.now)
    cv.reset = true
  end
  render()
end

---------------------------------------------------------------------------------------------- drawing

local function draw()
  local y = 8
  K.button(X, y, 76, 22, UI.Settings.TEXT.back, close, { size = 13, align = "left" })
  K.chevron(X + 4, y + 11, -1, C.moss)
  y = K.heading(P.TEXT.title, nil, y + 30)

  local top = y
  K.text(P.TEXT.from, X + 14, y + 10, { size = 14, color = C.title })
  y = y + 34 + K.text(P.TEXT.fromHelp, X + 14, y + 34, { size = 13, color = C.body, width = W - 28 })
  put("from", X + 14, y + 8, W - 28 - 96)
  K.button(X + W - 14 - 88, y + 8, 88, 28, P.TEXT.import, doImport, { bg = C.sea, ink = C.title, size = 13 })
  y = y + 44
  if result then
    y = y + K.text(result.line, X + 14, y, { size = 13, color = result.ok and C.moss or C.flame, width = W - 28 }) + 8
  end
  K.panel(X, top, W, y - top)

  y = K.heading(P.TEXT.forSite, nil, y + 14)
  top = y
  y = y + 10 + K.text(out.line, X + 14, y + 10, { size = 13, color = C.body, width = W - 28 })
  if out.text then
    put("out", X + 14, y + 8, W - 28, out.text, true)
    y = y + 44
  else
    call(boxes.out, "Hide")
    y = y + 12
  end
  K.panel(X, top, W, y - top)
  return y + 12 + K.text(P.TEXT.app, X, y + 12, { size = 12, color = C.muted, width = W }) + 8
end

function render()
  if not cv.child or not open then return end
  local _, seen = call(cv.child, "IsVisible")
  if seen == false then return end
  ET.canvas(cv, function()
    K.begin()
    local y
    local ok = try(function() y = draw() end)
    cv.reset = false
    K.finish(ok and y or 8)
  end)
end

-- Opens the sheet over the Events panel, the website's copy box empty and what is held for the site selected.
function T.open()
  if not cv.child then return false end
  local env = Frame.env()
  open, result = true, nil
  out = P.outgoing(env.guild and ns.Sync.slug() or nil, env.guild, ns.state and ns.state.db, env.now)
  cv.reset = true
  call(cv.scroll, "SetVerticalScroll", 0)
  call(cv.scroll, "Show")
  render()
  if out.text then
    call(boxes.out, "SetFocus")
    call(boxes.out, "HighlightText")
  end
  return true
end

function T.build()
  local tab = Frame.tabs.events
  if not tab or not tab.panel or cv.child then return end
  local ok, sf = try(CreateFrame, "ScrollFrame", nil, Frame.frame)
  if not ok or type(sf) ~= "table" then return end
  call(sf, "SetPoint", "TOPLEFT", tab.panel, "TOPLEFT", 0, -4)
  call(sf, "SetPoint", "BOTTOMRIGHT", tab.panel, "BOTTOMRIGHT", 0, 0)
  call(sf, "SetFrameLevel", 40)
  local ok2, child = try(CreateFrame, "Frame", nil, sf)
  if not ok2 or type(child) ~= "table" then return end
  call(child, "SetSize", Frame.W - 2, 400)
  call(Frame.fill(sf, C.ground, "BACKGROUND"), "SetAllPoints") -- hides the tab under the sheet
  call(sf, "SetScrollChild", child)
  call(sf, "EnableMouse", true)
  call(sf, "SetScript", "OnHide", function() open = false; hideBoxes(); call(sf, "Hide") end)
  call(sf, "Hide")
  cv.scroll, cv.child = sf, child
end
ET.hooks.built = (function(prior)
  return function() if prior then try(prior) end; T.build() end
end)(ET.hooks.built)

-- /tintean paste and the Settings button: the window opens (on the tab it was on) and the sheet goes over it.
P.open = function()
  if not Frame.show() then return false end
  return T.open()
end

return T
