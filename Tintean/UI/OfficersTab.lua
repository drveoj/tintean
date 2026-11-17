-- Plan an event, drawn from UI.Officers (the model): a sheet laid over the Events panel (so Back lands on the list) with a
-- canvas of its own and the Events tab's drawing helpers. Offered only to officer ranks: a button after the list, and a
-- click on an empty day of the month. Creating goes through Edit.createEvent like any edit. Sheet: docs/mockups/addon/Officer.html
-- and docs/mockups/addon-look/Others.html (the chosen place's painting beside Where).
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame, O, ET, E = UI.Frame, UI.Officers, UI.EventsTab, UI.Events
local C = UI.COLORS
local try, call, color = function(...) return ns.try(...) end, Frame.call, Frame.color
local K = ET.kit

local T = {}
UI.OfficersTab = T

local X, W = 16, 606
local cv = { pools = {} }
local P = { form = nil, places = {}, error = nil, undo = {}, told = {} } -- undo: events I cancelled while the window has been open
local boxes = {}

local function now()
  local ok, t = try(time)
  return ok and type(t) == "number" and t or 0
end

-- One plain boolean from the game, or nil (missing, erroring, secret or not a boolean).
local function plainBool(fn)
  local ok, v = try(fn)
  if not ok or type(v) ~= "boolean" then return nil end
  local okS, secret = try(issecretvalue, v)
  if okS and secret == true then return nil end
  return v
end

-- The game's own answer for the logged-in player, as its interface code asks it (guild leader, else guild officer):
-- true if either says yes; false if officer says no and leader does not say yes; nil when it can't answer.
function T.gameSays()
  local leader = plainBool(IsGuildLeader)
  if leader == true then return true end
  local info = C_GuildInfo
  if type(info) ~= "table" then return nil end
  return plainBool(info.IsGuildOfficer) -- true, false or nil
end

-- Am I an officer: the game's answer, else the held records' (my rank, the guild's officer ranks). Never an error.
-- No roster record is needed for the game's answer; making an edit still needs one, and says so when it is missing.
function T.can(env)
  local g = env and env.guild
  if type(g) ~= "table" then return false end
  local ok, me, name = try(ns.Edit.me, g)
  if not ok then me, name = nil, nil end
  local okR, rank = try(ns.Checks.gameRank, name)
  local ok2, can = try(O.canPlan, g, okR and rank or nil, me, T.gameSays())
  return ok2 and can == true
end

-- /tintean check: the same lookups as T.can, said in one line.
function T.checkLine()
  local g = ns.Sync and ns.Sync.guild and select(2, try(ns.Sync.guild))
  if type(g) ~= "table" then return nil end
  local _, me, name = try(ns.Edit.me, g)
  local okR, rank = try(ns.Checks.gameRank, name)
  local ok, line = try(O.officerLine, g, okR and rank or nil, me, T.gameSays())
  return ok and line or nil
end

local baseCheck = ns.check
function ns.check()
  if baseCheck then ns.try(baseCheck) end
  local line = T.checkLine()
  if line then ns.out(ns.tag .. " " .. line) end
end

local render

---------------------------------------------------------------------------------------------- the boxes

local ORDER = { "title", "time", "tank", "healer", "dps", "notes" }

local function box(key, max)
  if boxes[key] then return boxes[key] end
  local ok, eb = try(CreateFrame, "EditBox", nil, cv.child)
  if not ok or type(eb) ~= "table" then return nil end
  local _, locale = try(GetLocale)
  local path = UI.ownFont("body", locale)
  if not (path and select(2, call(eb, "SetFont", path, 13, ""))) then call(eb, "SetFont", STANDARD_TEXT_FONT, 13, "") end
  call(eb, "SetAutoFocus", false)
  call(eb, "SetMaxLetters", max)
  call(eb, "SetTextInsets", 8, 8, 0, 0)
  call(eb, "SetTextColor", color(C.ink))
  call(Frame.fill(eb, C.lineStrong, "BACKGROUND"), "SetAllPoints")
  local inner = Frame.fill(eb, C.ground, "BACKGROUND")
  call(inner, "SetPoint", "TOPLEFT", 1, -1)
  call(inner, "SetPoint", "BOTTOMRIGHT", -1, 1)
  call(inner, "SetDrawLayer", "BACKGROUND", 1)
  local function done(self) call(self, "ClearFocus") end
  call(eb, "SetScript", "OnEscapePressed", done)
  call(eb, "SetScript", "OnEnterPressed", done)
  boxes[key] = eb
  return eb
end

local function put(key, x, y, w, max, value)
  local eb = box(key, max)
  if not eb then return end
  call(eb, "ClearAllPoints")
  call(eb, "SetPoint", "TOPLEFT", cv.child, "TOPLEFT", x, -y)
  call(eb, "SetSize", w, 28)
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
  if not f or not cv.child then return end
  if boxes.title then
    f.title, f.time, f.notes = text("title"), text("time"), text("notes")
    f.want = { text("tank"), text("healer"), text("dps") }
  end
end

local function hideBoxes()
  for _, k in ipairs(ORDER) do
    call(boxes[k], "ClearFocus")
    call(boxes[k], "Hide")
  end
end

---------------------------------------------------------------------------------------------- actions

local function close()
  sync()
  hideBoxes()
  P.form, P.error = nil, nil
  call(cv.scroll, "Hide")
  ET.render()
end

local function create(env)
  sync()
  local f = P.form
  local problem = O.check(f, env)
  if problem then P.error = problem; render(); return end
  local ok, status
  if f.editing then
    ok, status = try(ns.Edit.editEvent, f.editing, O.fields(f, env, P.places))
  else
    ok, status = try(ns.Edit.createEvent, O.fields(f, env, P.places))
  end
  local why = O.outcome(ok, status)
  if why then P.error = why; render(); return end -- a refused edit is not stored: what was held stays
  if not f.editing then UI.statusNote = { text = E.TEXT.sent, untilAt = now() + 30 } end
  close()
  Frame.refresh(true)
end

-- Edit event: the same sheet, filled from what is held.
function T.edit(id)
  local env = Frame.env()
  if not cv.child or not T.can(env) then return end
  local ev = ns.Store.current(env.guild, "event", id)
  if not ev or ev.deleted then return end
  P.places = O.placesFor(env.guild, ev)
  P.form, P.error = O.fromEvent(env, ev, P.places), nil
  P.told[id] = nil
  cv.reset = true
  call(cv.scroll, "SetVerticalScroll", 0)
  call(cv.scroll, "Show")
  render()
end

-- Cancel event (no confirm) and Undo: one edit each; a refusal is told in plain words and nothing changes.
local function change(id, fn, cancelled)
  local ok, status = try(fn, id)
  local why = O.outcome(ok, status)
  P.told[id] = why
  if not why then P.undo[id] = cancelled or nil end
  Frame.refresh(true)
  ET.draw()
end

-- Opens the sheet for the day holding `stamp` (nil: tomorrow). Nothing happens unless I am an officer.
function T.open(stamp)
  local env = Frame.env()
  if not cv.child or not T.can(env) then return end
  P.form, P.error, P.places = O.new(env, stamp), nil, O.places(env.guild)
  cv.reset = true
  call(cv.scroll, "SetVerticalScroll", 0)
  call(cv.scroll, "Show")
  render()
end

---------------------------------------------------------------------------------------------- drawing

local function label(s, x, y) K.text(s, x, y, { size = 12, color = C.muted }) end

-- ‹ value › : two arrow buttons around text; returns nothing.
local function stepper(x, y, w, value, fn)
  K.button(x, y, 24, 28, "", function() sync(); fn(-1); render() end, {})
  K.chevron(x + 9, y + 14, -1, C.moss)
  K.button(x + w - 24, y, 24, 28, "", function() sync(); fn(1); render() end, {})
  K.chevron(x + w - 9, y + 14, 1, C.moss)
  K.text(value, x + w / 2, y + 6, { size = 13, color = C.title, center = true, width = w - 56 })
end

local function chips(x, y, list, chosen, pick)
  for _, c in ipairs(list) do
    local w = #c[2] * 6.4 + 22
    if x + w > X + W - 14 then x, y = X + 14, y + 32 end
    local on = chosen == c[1]
    K.button(x, y, w, 26, c[2], function() sync(); pick(c[1]); render() end,
      { bg = on and C.sea or C.ground, edge = on and C.sea or C.lineStrong, ink = C.title, size = 11, chosen = on })
    x = x + w + 6
  end
  return y + 34
end

local function draw(env)
  local f = P.form
  local y = 8
  K.button(X, y, 76, 22, E.TEXT.back, close, { size = 13, align = "left" })
  K.chevron(X + 4, y + 11, -1, C.moss)
  y = K.heading(f.editing and O.TEXT.edit or O.TEXT.heading, nil, y + 30)
  local top, x0, w = y, X + 14, W - 28
  y = y + 12
  label(O.TEXT.title, x0, y); put("title", x0, y + 18, w, 80, f.title); y = y + 56
  label(O.TEXT.what, x0, y)
  y = chips(x0, y + 18, O.ACTIVITIES, f.activity, function(k) f.activity = k end) + 8
  label(O.TEXT.where, x0, y)
  local p = P.places[f.place]
  stepper(x0 + 46, y + 18, 280, p and p.name or O.TEXT.none, function(d)
    f.place = (f.place + d) % (#P.places + 1)
  end)
  K.placePic(p and p.slug, x0, y + 20, 24)
  y = y + 56
  local cw = (w - 24) / 3
  label(O.TEXT.day, x0, y)
  stepper(x0, y + 18, cw, O.dayLabel(env.date, f.stamp), function(d) O.shiftDay(f, env, d) end)
  label(O.TEXT.starts, x0 + cw + 12, y); put("time", x0 + cw + 12, y + 18, cw, 5, f.time)
  label(O.TEXT.how, x0 + 2 * (cw + 12), y)
  stepper(x0 + 2 * (cw + 12), y + 18, cw, O.lengthLabel(f.minutes), function(d) O.stepLength(f, d) end)
  y = y + 56
  label(O.TEXT.size, x0, y)
  y = chips(x0, y + 18, O.SIZES, f.size, function(k) f.size = k end) + 8
  label(O.TEXT.wanted, x0, y)
  for i, k in ipairs({ "tank", "healer", "dps" }) do
    local bx = x0 + (i - 1) * 130
    put(k, bx, y + 18, 44, 2, f.want[i])
    K.text(O.TEXT.roles[i], bx + 52, y + 24, { size = 13, color = C.body })
  end
  y = y + 56
  label(O.TEXT.plan, x0, y); put("notes", x0, y + 18, w, 2000, f.notes); y = y + 56
  if P.error then y = y + K.text(P.error, x0, y, { size = 13, color = C.flame, width = w }) + 6 end
  K.button(x0, y, 120, 30, f.editing and O.TEXT.save or O.TEXT.create, function() create(Frame.env()) end, { bg = C.sea, ink = C.title, size = 13 })
  K.button(x0 + 128, y, 80, 30, O.TEXT.cancel, close, { bg = C.ground, edge = C.lineStrong, ink = C.body, size = 13 })
  y = y + 42
  K.panel(X, top, W, y - top)
  y = y + 8
  return y + K.text(O.TEXT.after, X, y, { size = 12, color = C.muted, width = W }) + 8
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

-- Built once the Events tab has its panel; hidden until asked for.
function T.build()
  local tab = Frame.tabs.events
  if not tab or not tab.panel or cv.child then return end
  local ok, sf = try(CreateFrame, "ScrollFrame", nil, tab.panel)
  if not ok or type(sf) ~= "table" then return end
  call(sf, "SetPoint", "TOPLEFT", tab.panel, "TOPLEFT", 0, -4)
  call(sf, "SetPoint", "BOTTOMRIGHT", tab.panel, "BOTTOMRIGHT", 0, 0)
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

-- The Events tab's hooks: the button after the list or the empty line, and a click on an empty day.
local function planButton(_, y, env)
  if not T.can(env) then return y end
  K.button(X, y, 130, 28, O.TEXT.heading, function() T.open(nil) end, { bg = C.sea, ink = C.title, size = 13 })
  return y + 40
end
ET.hooks.afterEmpty, ET.hooks.afterList, ET.hooks.planDay = planButton, planButton, function(stamp) T.open(stamp) end
ET.hooks.canPlan, ET.hooks.built = T.can, T.build

-- An open event's page, after Post in guild chat: Edit event and Cancel event, for officers. `x`, `y` is where the next button goes.
ET.hooks.openPage = function(p, x, y, env)
  if not T.can(env) then return y end
  K.button(x, y, 110, 28, O.TEXT.edit, function() T.edit(p.id) end, { bg = C.ground, edge = C.lineStrong, ink = C.body, size = 13 })
  K.button(x + 118, y, 120, 28, O.TEXT.cancelEvent, function() change(p.id, ns.Edit.cancelEvent, true) end,
    { bg = C.ground, edge = C.flame, ink = C.flame, size = 13 })
  if P.told[p.id] then
    return y + K.text(P.told[p.id], X, y + 36, { size = 13, color = C.flame, width = W }) + 4
  end
  return y
end

-- A cancelled event's page: Undo while the window has been open since I cancelled it; or the words if an Undo was refused.
ET.hooks.cancelledPage = function(p, y, env)
  if not T.can(env) then return y end
  if P.undo[p.id] then
    local h = K.text(O.TEXT.cancelledNow, X, y + 6, { size = 13, color = C.body, width = W - 90 })
    K.button(X + W - 80, y, 80, 28, O.TEXT.undo, function() change(p.id, ns.Edit.undoCancel, false) end,
      { bg = C.sea, ink = C.title, size = 13 })
    y = y + math.max(h + 6, 28) + 12
  end
  if P.told[p.id] then y = y + K.text(P.told[p.id], X, y, { size = 13, color = C.flame, width = W }) + 12 end
  return y
end

-- The window is closed: Undo is no longer offered, and old words go.
ET.hooks.hidden = function() P.undo, P.told = {}, {} end

return T
