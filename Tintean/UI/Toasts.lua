-- What arrives while you play, drawn and said: one chat line per thing (your own chat frame only), and a toast for a
-- guildmate's new event or bulletin and for the 15-minute reminder. Toasts wait out combat, show ten seconds and have a
-- close button; the look is addon-look's (the place's painting or the flame, a gold bar on the left edge, 360 wide).
-- Nothing here posts to guild chat: that is the Events page's button (Post in guild chat). Model: UI.Arrivals.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame, A = UI.Frame, UI.Arrivals
local C = UI.COLORS
local try, call = function(...) return ns.try(...) end, Frame.call

local T = {}
UI.Toasts = T

local W, H, STEP, TOP, MAX, SHOWN_FOR = 360, 56, 64, 120, 3, 10
local queue, up, pool = {}, {}, {}
local reminded, arrivals = {}, {}
local loginAt, loginDone, beat = nil, false, 0

local function now()
  local ok, t = try(time)
  return ok and type(t) == "number" and t or 0
end

-- A line in the player's own chat frame, with the README's way to open (no link type is used until one is confirmed).
function T.say(text)
  ns.print(ns.tag .. " " .. text .. " " .. A.TEXT.openHint)
end

---------------------------------------------------------------------------------------------- the toast

local function mini(parent, w, h, label, fn, look)
  local b = Frame.button(parent, w, h, fn)
  if not b then return nil end
  b.edge, b.face = Frame.fill(b, C.line, "BACKGROUND"), Frame.fill(b, C.line, "BACKGROUND")
  call(b.edge, "SetAllPoints")
  call(b.face, "SetPoint", "TOPLEFT", 1, -1)
  call(b.face, "SetPoint", "BOTTOMRIGHT", -1, 1)
  call(b.face, "SetDrawLayer", "BACKGROUND", 1)
  Frame.feel(b)
  b.label = Frame.text(b, 12, look and C.body or C.muted)
  call(b.label, "SetPoint", "CENTER")
  call(b.label, "SetText", label)
  b.look = look
  b.anchor = { "CENTER", 0, 0 }
  if not look then call(b.edge, "Hide"); call(b.face, "Hide") end
  Frame.paint(b)
  return b
end

local function make()
  local ok, f = try(CreateFrame, "Frame", nil, UIParent)
  if not ok or type(f) ~= "table" then return nil end
  call(f, "SetSize", W, H)
  call(f, "SetFrameStrata", "HIGH")
  call(Frame.fill(f, C.outer, "BACKGROUND"), "SetAllPoints")
  local face = Frame.fill(f, C.surface, "BACKGROUND")
  call(face, "SetPoint", "TOPLEFT", 1, -1)
  call(face, "SetPoint", "BOTTOMRIGHT", -1, 1)
  call(face, "SetDrawLayer", "BACKGROUND", 1)
  local bar = Frame.fill(f, C.gold, "BACKGROUND") -- the gold bar on the left edge
  call(bar, "SetPoint", "TOPLEFT", 1, -1)
  call(bar, "SetPoint", "BOTTOMLEFT", 1, 1)
  call(bar, "SetWidth", 3)
  call(bar, "SetDrawLayer", "BACKGROUND", 2)
  f.frame = Frame.fill(f, C.lineStrong, "ARTWORK")
  call(f.frame, "SetSize", 38, 38)
  call(f.frame, "SetPoint", "LEFT", 13, 0)
  f.pic = Frame.fill(f, C.ground, "ARTWORK")
  call(f.pic, "SetSize", 36, 36)
  call(f.pic, "SetPoint", "LEFT", 14, 0)
  call(f.pic, "SetDrawLayer", "ARTWORK", 1)
  f.title, f.line = Frame.text(f, 14, C.title), Frame.text(f, 12, C.muted)
  for _, fs in ipairs({ f.title, f.line }) do
    call(fs, "SetWidth", 200)
    call(fs, "SetWordWrap", false)
  end
  call(f.title, "SetPoint", "TOPLEFT", 60, -11)
  call(f.line, "SetPoint", "TOPLEFT", 60, -32)
  f.open = mini(f, 56, 26, A.TEXT.open, function() T.open(f) end, { bg = C.ground, edge = C.lineStrong })
  call(f.open, "SetPoint", "RIGHT", -36, 0)
  f.close = mini(f, 24, 24, "×", function() T.close(f) end, nil)
  call(f.close, "SetPoint", "RIGHT", -8, 0)
  return f
end

local function layout()
  for i, f in ipairs(up) do
    call(f, "ClearAllPoints")
    call(f, "SetPoint", "TOP", UIParent, "TOP", 0, -(TOP + (i - 1) * STEP))
  end
end

function T.close(f)
  for i, g in ipairs(up) do
    if g == f then table.remove(up, i); break end
  end
  call(f, "Hide")
  pool[#pool + 1] = f
  layout()
end

function T.open(f)
  local t = f.toast
  T.close(f)
  if t and t.kind == "event" and UI.EventsTab and UI.EventsTab.open then
    try(UI.EventsTab.open, t.id)
  elseif t then
    try(Frame.show, "bulletins")
  end
end

local function show(t)
  local f = table.remove(pool) or make()
  if not f then return end
  f.toast, f.until_ = t, now() + SHOWN_FOR
  call(f.title, "SetText", t.title)
  call(f.line, "SetText", t.line)
  local l, r, tp, b = nil, nil, nil, nil
  if t.art then l, r, tp, b = UI.Art.place(t.art) end
  if l then -- the place's painting
    call(f.pic, "SetTexture", UI.Art.path(UI.Art.PLACES))
    call(f.pic, "SetTexCoord", l, r, tp, b)
  else -- the flame
    call(f.pic, "SetTexture", "Interface\\AddOns\\Tintean\\mark")
    call(f.pic, "SetTexCoord", 0, 1, 0, 1)
  end
  up[#up + 1] = f
  layout()
  call(f, "Show")
end

-- Toasts that wait, in order. A toast is { kind, id, title, line, art }.
function T.add(t)
  if #queue < 20 then queue[#queue + 1] = t end
  T.pump()
end

-- Out of combat (a doubt counts as combat): shows what waits, up to three at once, and takes down what has had ten seconds.
function T.pump()
  local t = now()
  for i = #up, 1, -1 do
    if up[i].until_ <= t then T.close(up[i]) end
  end
  if ns.closed(InCombatLockdown) then return end
  local shown = 0
  while #queue > 0 and #up < MAX do show(table.remove(queue, 1)); shown = shown + 1 end
  if shown > 0 and A.on("sound") then T.chime() end -- once for the burst, not once per toast
end

-- One short built-in game sound (the chime of Blizzard's own toasts). Silent if the game has no such sound or call.
function T.chime()
  if type(PlaySound) ~= "function" or type(SOUNDKIT) ~= "table" then return end
  local id = SOUNDKIT.UI_BNET_TOAST
  if type(id) == "number" then try(PlaySound, id) end
end

---------------------------------------------------------------------------------------------- what raises them

-- Sync calls this once for an event or bulletin first held from a guildmate (their live edit or the website's record).
function T.arrived(g, rec)
  local env = Frame.env()
  env.guild = g
  local a = A.arrival(env, rec)
  if not a then return end
  if A.on("chatLine") then arrivals[#arrivals + 1] = a end -- said at the next tick, so a catch-up becomes one line
  if A.on("toast") then T.add(a.toast) end
end

-- What arrived since the last tick, said (several events as one line), then the refusals and words not yet told.
function T.flush()
  if #arrivals > 0 then
    local list = arrivals
    arrivals = {}
    for _, l in ipairs(A.batch(list)) do T.say(l) end
  end
  local env = Frame.env()
  if type(env.guild) == "table" and not ns.closed(InCombatLockdown) then
    for _, l in ipairs(UI.Notices.chat(env.guild, env.now, A.on("chatLine"))) do T.say(l) end
  end
end

-- Every second: toasts; every fifth, the 15-minute reminders; once, ten seconds in, the login line.
function T.tick()
  T.pump()
  T.flush()
  beat = beat + 1
  if beat % 5 ~= 0 then return end
  local env = Frame.env()
  if type(env.guild) ~= "table" then return end
  if A.on("remind15") then
    for _, r in ipairs(A.reminders(env, reminded)) do
      reminded[r.key] = true
      T.say(r.chat)
      if A.on("toast") then T.add(r.toast) end
    end
  end
  if not loginDone and loginAt and env.now >= loginAt and next(env.guild.records or {}) ~= nil and not ns.closed(InCombatLockdown) then
    loginDone = true
    local line = A.on("loginReminder") and A.login(env) or nil
    if line then T.say(line) end
  end
end

ns.arrived = function(...) return try(T.arrived, ...) end

if type(CreateFrame) == "function" then
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("PLAYER_LOGIN")
  ev:SetScript("OnEvent", function()
    loginAt = now() + 10
    if C_Timer and C_Timer.NewTicker then try(C_Timer.NewTicker, 1, function() try(T.tick) end) end
  end)
end

return T
