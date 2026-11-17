-- Write a bulletin and the officers' tools on a bulletin's page, drawn from UI.Officers (the model). The sheet lies over the
-- Bulletins panel with a canvas of its own, as Plan an event does over Events. Creating, taking down and everything else go
-- through Edit like any edit; Post in guild chat is one line, from the click only. Sheet: docs/mockups/addon/Officer.html.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame, O, ET, BT, E = UI.Frame, UI.Officers, UI.EventsTab, UI.BulletinsTab, UI.Events
local C = UI.COLORS
local try, call, color = function(...) return ns.try(...) end, Frame.call, Frame.color
local K = ET.kit
local B = O.BTEXT

local T = {}
UI.BulletinOfficersTab = T

local X, W = 16, 606
local cv = { pools = {} }
local P = { form = nil, error = nil, told = {}, shut = {}, ask = nil } -- told, shut: words for a bulletin's page, kept while the window is open
local boxes = {}

local function now()
  local ok, t = try(time)
  return ok and type(t) == "number" and t or 0
end

local render

---------------------------------------------------------------------------------------------- the boxes

local ORDER = { "title", "text" }

local function box(key, max, multi)
  if boxes[key] then return boxes[key] end
  local ok, eb = try(CreateFrame, "EditBox", nil, cv.child)
  if not ok or type(eb) ~= "table" then return nil end
  local _, locale = try(GetLocale)
  local path = UI.ownFont("body", locale)
  if not (path and select(2, call(eb, "SetFont", path, 13, ""))) then call(eb, "SetFont", STANDARD_TEXT_FONT, 13, "") end
  call(eb, "SetAutoFocus", false)
  call(eb, "SetMaxLetters", max)
  call(eb, "SetMultiLine", multi == true)
  call(eb, "SetTextInsets", 8, 8, multi and 6 or 0, 0)
  call(eb, "SetTextColor", color(C.ink))
  call(Frame.fill(eb, C.lineStrong, "BACKGROUND"), "SetAllPoints")
  local inner = Frame.fill(eb, C.ground, "BACKGROUND")
  call(inner, "SetPoint", "TOPLEFT", 1, -1)
  call(inner, "SetPoint", "BOTTOMRIGHT", -1, 1)
  call(inner, "SetDrawLayer", "BACKGROUND", 1)
  local function done(self) call(self, "ClearFocus") end
  call(eb, "SetScript", "OnEscapePressed", done)
  if not multi then call(eb, "SetScript", "OnEnterPressed", done) end
  boxes[key] = eb
  return eb
end

local function put(key, x, y, w, h, max, value, multi)
  local eb = box(key, max, multi)
  if not eb then return end
  call(eb, "ClearAllPoints")
  call(eb, "SetPoint", "TOPLEFT", cv.child, "TOPLEFT", x, -y)
  call(eb, "SetSize", w, h)
  if cv.reset then call(eb, "SetText", value or "") end
  call(eb, "Show")
end

local function text(key)
  local _, s = call(boxes[key], "GetText")
  return type(s) == "string" and s or ""
end

-- What is typed goes into the form before anything else is done with it.
local function sync()
  local f = P.form
  if f and boxes.title and boxes.text then f.title, f.text = text("title"), text("text") end
end

local function close()
  sync()
  for _, k in ipairs(ORDER) do call(boxes[k], "ClearFocus"); call(boxes[k], "Hide") end
  P.form, P.error = nil, nil
  call(cv.scroll, "Hide")
  BT.draw()
end

---------------------------------------------------------------------------------------------- actions

local function post(env)
  sync()
  local f = P.form
  local problem = O.bulletinCheck(f, env)
  if problem then P.error = problem; render(); return end
  local ok, status
  if f.editing then
    ok, status = try(ns.Edit.editBulletin, f.editing, O.bulletinFields(f, env))
  else
    ok, status = try(ns.Edit.createBulletin, O.bulletinFields(f, env))
  end
  local why = O.outcome(ok, status)
  if why then P.error = why; render(); return end -- a refused edit is not stored: nothing changes
  if not f.editing then UI.statusNote = { text = E.TEXT.sent, untilAt = now() + 30 } end
  close()
  Frame.refresh(true)
end

-- Write a bulletin (a blank form), or Edit on a bulletin's page (the form filled from what is held).
local function open(id)
  local env = Frame.env()
  if not cv.child or not UI.OfficersTab.can(env) then return end
  local held = id and ns.Store.current(env.guild, "bulletin", id)
  if id and not held then return end
  P.ask = nil
  P.form, P.error = held and O.bulletinFromRecord(env, held) or O.newBulletin(env), nil
  P.choices = O.eventChoices(env.guild, env.now, env.date, P.form.event)
  cv.reset = true
  call(cv.scroll, "SetVerticalScroll", 0)
  call(cv.scroll, "Show")
  render()
end

-- Take it down: one edit, no confirm (a deletion is the format's tombstone). A refusal is told in plain words.
-- Take it down asks first: the link becomes a question with Take it down and Keep it, and nothing is sent until the first.
-- The question is dropped by Keep it, by another action, and when the window closes.
local function takeDown(p)
  P.ask = nil
  local ok, status = try(ns.Edit.takeDownBulletin, p.id)
  P.told[p.id] = (ok and O.refusal(status)) or (not ok and E.TEXT.refused) or nil
  Frame.refresh(true)
  BT.draw()
end

function T.ask(p) P.ask = p.id; P.told[p.id] = nil; BT.draw() end
function T.keep() P.ask = nil; BT.draw() end
function T.asking(id) return P.ask == id end
T.confirm = takeDown

-- Pin or Unpin: one edit of the bulletin's `pinned`; a refusal is told in plain words.
local function pin(p)
  P.ask = nil
  local ok, status = try(ns.Edit.editBulletin, p.id, { pinned = not p.pinned })
  P.told[p.id] = (ok and O.refusal(status)) or (not ok and E.TEXT.refused) or nil
  Frame.refresh(true)
  BT.draw()
end

-- Post in guild chat: one line, as the player, from this click only. During the chat lockdown (or if the game refuses
-- it) nothing is sent and the page says so; the button is never greyed.
local function postInChat(p)
  local line = UI.Arrivals.postBulletin(p)
  if not line then return end
  local ok, locked = try(function() return C_ChatInfo.InChatMessagingLockdown() end)
  local sent = false
  if not (ok and locked == true) then
    local send = type(C_ChatInfo) == "table" and C_ChatInfo.SendChatMessage or SendChatMessage
    sent = select(1, try(send, line, "GUILD"))
  end
  P.shut[p.id] = (not sent) or nil
  BT.draw()
end

---------------------------------------------------------------------------------------------- drawing

local function label(s, x, y) K.text(s, x, y, { size = 12, color = C.muted }) end

local function toggle(x, y, w, s, on, fn)
  K.button(x, y, w, 26, s, function() sync(); fn(); render() end,
    { bg = on and C.sea or C.ground, edge = on and C.sea or C.lineStrong, ink = C.title, size = 12, chosen = on })
end

local function draw(env)
  local f = P.form
  local x0, w = X + 14, W - 28
  local y = 8
  K.button(X, y, 90, 22, "Bulletins", close, { size = 13, align = "left" })
  K.chevron(X + 4, y + 11, -1, C.moss)
  y = K.heading(B.heading, nil, y + 30)
  local top = y
  y = y + 12
  label(O.TEXT.title, x0, y); put("title", x0, y + 18, w, 28, 80, f.title); y = y + 56
  label(B.text, x0, y); put("text", x0, y + 18, w, 120, 600, f.text, true); y = y + 144
  K.text(O.countLine(f.text), x0, y, { size = 12, color = #(f.text or "") > 600 and C.flame or C.muted }); y = y + 28
  toggle(x0, y, 170, B.pin, f.pinned, function() f.pinned = not f.pinned end); y = y + 36
  toggle(x0, y, 170, B.takeDown, f.down, function() f.down = not f.down end)
  if f.down then
    K.button(x0 + 178, y, 24, 26, "", function() sync(); O.shiftDay(f, env, -1); render() end, {})
    K.chevron(x0 + 187, y + 13, -1, C.moss)
    K.text(O.dayLabel(env.date, f.stamp), x0 + 242, y + 6, { size = 13, color = C.title, center = true, width = 80 })
    K.button(x0 + 282, y, 24, 26, "", function() sync(); O.shiftDay(f, env, 1); render() end, {})
    K.chevron(x0 + 291, y + 13, 1, C.moss)
  end
  y = y + 36
  local choices = P.choices or {}
  toggle(x0, y, 170, B.about, f.event ~= nil, function() O.toggleAbout(f, choices) end)
  if f.event then
    local chosen = O.TEXT.none
    for _, c in ipairs(choices) do if c.id == f.event then chosen = c.label end end
    K.button(x0 + 178, y, 24, 26, "", function() sync(); O.stepEvent(f, choices, -1); render() end, {})
    K.chevron(x0 + 187, y + 13, -1, C.moss)
    K.text(chosen, x0 + 210, y + 6, { size = 13, color = C.title, width = w - 250 })
    K.button(x0 + w - 28, y, 24, 26, "", function() sync(); O.stepEvent(f, choices, 1); render() end, {})
    K.chevron(x0 + w - 19, y + 13, 1, C.moss)
  end
  y = y + 40
  K.text(O.bulletinFoot(f, env), x0, y, { size = 12, color = C.muted }) -- the page foot as it will read
  y = y + 24
  if P.error then y = y + K.text(P.error, x0, y, { size = 13, color = C.flame, width = w }) + 6 end
  K.button(x0, y, 130, 30, B.post, function() post(Frame.env()) end, { bg = C.sea, ink = C.title, size = 13 })
  K.button(x0 + 138, y, 80, 30, B.cancel, close, { bg = C.ground, edge = C.lineStrong, ink = C.body, size = 13 })
  y = y + 42
  K.panel(X, top, W, y - top)
  y = y + 8
  return y + K.text(B.after, X, y, { size = 12, color = C.muted, width = W }) + 8
end

function render()
  if not cv.child or not P.form then return end
  local _, seen = call(cv.child, "IsVisible")
  if seen == false then return end
  ET.canvas(cv, function()
    K.begin()
    local y
    local ok = try(function() y = draw(Frame.env()) end)
    cv.reset = false
    K.finish(ok and y or 8)
  end)
end

---------------------------------------------------------------------------------------------- the sheet

local function build(panel)
  if cv.child or not panel then return end
  local ok, sf = try(CreateFrame, "ScrollFrame", nil, panel)
  if not ok or type(sf) ~= "table" then return end
  call(sf, "SetPoint", "TOPLEFT", panel, "TOPLEFT", 0, -4)
  call(sf, "SetPoint", "BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
  call(sf, "SetFrameLevel", 20)
  local ok2, child = try(CreateFrame, "Frame", nil, sf)
  if not ok2 or type(child) ~= "table" then return end
  call(child, "SetSize", Frame.W - 2, 400)
  local back = Frame.fill(sf, C.ground, "BACKGROUND") -- hides the list under the sheet
  call(back, "SetAllPoints")
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
  call(sf, "Hide")
  cv.scroll, cv.child = sf, child
end

-- The Bulletins tab's hooks.
BT.hooks.built = build

BT.hooks.after = function(env, y)
  if not UI.OfficersTab.can(env) then return y end
  K.button(X, y, 150, 28, B.heading, function() open() end, { bg = C.sea, ink = C.title, size = 13 })
  return y + 40
end

-- Inside a bulletin's page, under its foot: Edit, Pin or Unpin, Take it down and Post in guild chat as text links on one
-- line (as the sheet has them), and the words if one failed.
BT.hooks.tools = function(p, y, env)
  if not UI.OfficersTab.can(env) then return y end
  local x = X + 18
  local function link(s, ink, fn)
    local w = math.ceil(#s * 6.6) + 8
    K.button(x, y, w, 22, s, fn, { ink = ink, size = 12 })
    x = x + w + 12
  end
  link(B.edit, C.sheetInk, function() open(p.id) end)
  link(p.pinned and B.unpin or B.pinLink, C.sheetInk, function() pin(p) end)
  if P.ask == p.id then
    local w = math.ceil(#B.takeDownQ * 6.6) + 8
    K.text(B.takeDownQ, x, y + 4, { size = 12, color = C.sheetInk })
    x = x + w + 4
    link(B.takeDownLink, C.flame, function() T.confirm(p) end)
    link(B.keep, C.sheetInk, T.keep)
  else
    link(B.takeDownLink, C.flame, function() T.ask(p) end)
  end
  link(E.TEXT.post, C.sheetInk, function() postInChat(p) end)
  y = y + 28
  local A = UI.Arrivals.TEXT
  local said = P.told[p.id] or (P.shut[p.id] and (A.shut .. " " .. A.line)) or nil
  if said then y = y + K.text(said, X + 18, y, { size = 13, color = C.flame, width = W - 36 }) + 6 end
  return y
end

-- The window is closed: old words go.
local hidden = Frame.onHide
Frame.onHide = function() if hidden then hidden() end P.told, P.shut, P.ask = {}, {}, nil end

return T
