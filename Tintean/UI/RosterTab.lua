-- The Roster tab, drawn from UI.Roster (the model) with the Events tab's drawing helpers on a canvas of its own. The people
-- come from the game's own guild roster (read at most every ten seconds, refreshed when the tab opens); Tinteán's roster
-- records say who is in Tinteán and which ranks are officers. Sheet: docs/mockups/addon/Roster.html and
-- docs/mockups/addon-look/Others.html. Nothing here is sent: the game's guild window does invites and promotions.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame, R, ET = UI.Frame, UI.Roster, UI.EventsTab
local C = UI.COLORS
local try, call = function(...) return ns.try(...) end, Frame.call
local K = ET.kit

local T = {}
UI.RosterTab = T

local X, W, ROW = 16, 606, 44
local cv = { pools = {} }
local sig
local filter = "all"
local members, readAt, askedAt = nil, -1e9, -1e9

local function secret(v)
  local ok, s = try(issecretvalue, v)
  return ok and s == true
end

local function clock()
  local ok, t = try(GetTime)
  return ok and type(t) == "number" and t or 0
end

-- The game's roster, one call per row, at most every ten seconds; a new table each time, so a drawing can tell.
local function read()
  local t = clock()
  if members and t - readAt < 10 then return members end
  readAt = t
  local out = {}
  local ok, total = try(GetNumGuildMembers)
  if ok and type(total) == "number" and not secret(total) then
    for i = 1, math.min(total, 1000) do
      local ok2, name, rankName, rank, level, class, zone, _, _, online, _, file = try(GetGuildRosterInfo, i)
      if ok2 and not (secret(name) or secret(rank) or secret(rankName) or secret(class) or secret(zone) or secret(file)) then
        local y, m, d, h
        if online ~= true then
          local ok3, a, b, c, e = try(function() return _G.GetGuildRosterLastOnline(i) end)
          if ok3 and not (secret(a) or secret(b) or secret(c) or secret(e)) then y, m, d, h = a, b, c, e end
        end
        out[#out + 1] = R.member(name, rankName, rank, level, class, zone, online, file, y, m, d, h)
      end
    end
  end
  members = out
  return out
end

-- The game gives the roster only when asked, and rations it; once in twenty seconds is plenty.
local function ask(env)
  local t = clock()
  if env.boss or t - askedAt < 20 then return end
  askedAt = t
  try(function() _G.C_GuildInfo.GuildRoster() end)
end

local render

local function drawChips(y)
  local x = X
  for _, f in ipairs(R.TEXT.filters) do
    local on, w = filter == f[1], f[1] == "in" and 96 or 84
    K.button(x, y, w, 28, f[2], function() filter = f[1]; sig = nil; render() end,
      { bg = on and C.sea or C.ground, edge = on and C.sea or C.lineStrong, ink = C.title, size = 12, chosen = on })
    x = x + w + 6
  end
  return y + 40
end

local function drawRow(r, y)
  local nx, sz = X + 14, 32
  if K.classIcon(r.class, X + 14, y + (ROW - sz) / 2, sz) then nx = X + 14 + sz + 12 end
  K.text(r.name, nx, y + 6, { size = 14, color = r.color or C.title })
  if r.sub ~= "" then K.text(r.sub, nx, y + 24, { size = 12, color = C.muted }) end
  local cx, cw = X + W - 14 - 76, 76 -- the chip: in Tinteán (the sea's colour) or not yet (quiet)
  K.rect(cx, y + 12, cw, 20, r.tintean and C.sea or C.lineStrong, 3)
  K.rect(cx + 1, y + 13, cw - 2, 18, C.surface, 4)
  K.text(r.tintean and R.TEXT.inTintean or R.TEXT.notYet, cx + cw - 10, y + 15,
    { size = 11, color = r.tintean and C.title or C.muted, right = true })
  if r.status then
    K.text(r.status, cx - 12, y + 15, { size = 12, color = r.status == "on now" and C.gold or C.muted, right = true })
  end
  return y + ROW
end

local function draw(env)
  local t = R.tab(env, filter)
  local y = K.strip(t.strip, 8)
  y = K.heading(R.TEXT.heading, nil, y)
  y = drawChips(y)
  local top, yy = y, y + 1
  for _, g in ipairs(t.groups) do
    local _, lw = K.text(g.label, X + 14, yy + 6, { size = 10, color = C.gold })
    if g.meta then K.text(g.meta, X + 14 + lw + 10, yy + 5, { size = 11, color = C.muted }) end
    yy = yy + 24
    for _, r in ipairs(g.rows) do yy = drawRow(r, yy) end
  end
  if #t.groups > 0 then K.panel(X, top - 1, W, yy - top + 4) end
  y = yy + 10
  y = y + K.text(R.TEXT.note, X, y, { size = 12, color = C.muted, width = W }) + 6
  local _, lw = K.text(R.TEXT.open, X, y + 4, { size = 13, color = C.sea })
  K.chevron(X + lw + 10, y + 11, 1, C.sea)
  K.button(X, y, lw + 30, 24, "", function() try(function() _G.ToggleGuildFrame() end) end, {})
  return y + 40
end

-- A drawing depends on the guild's table, the store's touches, the minute, the window's width, the filter, the game's
-- roster as last read and the status note.
local function signature(env)
  return { env.guild, ns.Sync.rev, math.floor((env.now or 0) / 60), Frame.W, filter, members }
end

function render(quiet)
  if not cv.child then return end
  local _, seen = call(cv.child, "IsVisible")
  if seen == false then sig = nil; return end
  local env = Frame.env()
  ask(env)
  env.members = read()
  local s = signature(env)
  if quiet and sig then
    local same = true
    for i = 1, 6 do if s[i] ~= sig[i] then same = false end end
    if same then return end
  end
  sig = s
  ET.canvas(cv, function()
    K.begin()
    local y
    local ok = try(function() y = draw(env) end)
    if not ok then sig = nil end
    K.finish(ok and y or 8)
  end)
end
T.render = function() render(true) end

function T.build(panelFrame)
  local tab = Frame.tabs.roster
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
  render()
end

UI.registerTab("roster", { label = "Roster", heading = R.TEXT.heading, order = 30, build = T.build, refresh = T.render })

return T
