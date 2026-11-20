-- What the frame and the minimap button say, and the registry of tabs. Pure: no widgets, callers pass the
-- guild table, `now` and the date function. The words are the README's strings table (docs/mockups/addon).
local _, ns = ...
ns = ns or {}

local UI = {}
ns.UI = UI

local Store = ns.Store
local DAY = 86400

-- Dusk (the website's tokens: guild.css, tokens.css), as r, g, b, a from 0 to 1.
local function hex(h, a) return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255, a or 1 } end
UI.COLORS = {
  ground = hex("0b2f3c"), surface = hex("10384a"), gold = hex("e2b566"), muted = hex("93b3b9"),
  body = hex("cfe3e6"), title = hex("fbf4e8"), ink = hex("f3eee2"),
  line = hex("f5ecd9", .11), lineStrong = hex("f5ecd9", .2), outer = hex("000000", .65),
  count = hex("9a2f1f"), countInk = hex("fbf4e8"), moss = hex("8fd3c7"),
  sea = hex("197f7c"), flame = hex("d98b3a"), sheet = hex("f5ecd9"), sheetInk = hex("1c2a30"),
  hordeInk = hex("ffb3a3"), allianceInk = hex("a9c8ff"), -- the faction chip over the header
  headBtn = hex("0b2f3c", .55), headEdge = hex("f5ecd9", .18), -- buttons over the painted header
}

UI.TEXT = {
  wordmark = "TINTEÁN", horde = "Horde", alliance = "Alliance", settings = "Settings", tour = "Tour", close = "Close",
  title = "Tinteán", open = "Click to open. Right-click for settings.", drag = "Drag to move it round the map.",
  noData = "Nothing from Tinteán yet.",
  noDataLine = "Events and bulletins arrive at login when the desktop app runs on this computer, or from a guildmate's addon while you're both online.",
  boss = "In a boss fight. Sending to guildmates waits until it ends.",
  noneAnywhere = "Nothing from tintean.net on this computer. No guildmate has sent anything this session.",
}

---------------------------------------------------------------------------------------------- tabs

-- Tabs are registered by key: UI.registerTab("events", { label, heading, order, count = fn(events, bulletins) -> n, build = fn(panel, ctx) }).
-- A later task gives `build` (called once, when the frame is made) and `refresh` (called each time the tab shows)
-- by registering the same key again. Officer and the others come the same way.
UI.tabs = {}

function UI.registerTab(key, def)
  def.key = key
  UI.tabs[key] = def
  if UI.onTabs then ns.try(UI.onTabs) end -- the window, if made, takes the new tab
end

-- No guild (M20.35): the game says there is none and the inbox read found none. Events stays, because its panel is the
-- one plain "not in a guild" panel; Bulletins and Roster have nothing to show, so their tabs go. Settings is a sheet over
-- the window, not a tab, so it stays. Copy and paste is a sheet too, reached from Settings and /tintean paste; it needs
-- the guild's name to import, so it stays as it is and says so in its own words (Paste.TEXT.noGuild).
local NEEDS_GUILD = { bulletins = true, roster = true }

function UI.noGuild()
  local _, name = ns.try(GetGuildInfo, "player")
  return type(name) ~= "string" or name == "", (ns.inbox or {}).state == "no_guild"
end

function UI.tabList()
  local list = {}
  local none, said = UI.noGuild()
  none = none and said
  for _, t in pairs(UI.tabs) do
    if not (none and NEEDS_GUILD[t.key]) and (not t.visible or t.visible()) then list[#list + 1] = t end
  end
  table.sort(list, function(a, b)
    if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end
    return a.key < b.key
  end)
  return list
end

UI.registerTab("events", { label = "Events", heading = "Coming up", order = 10, count = function(events) return events end })
UI.registerTab("bulletins", { label = "Bulletins", heading = "Up now", order = 20, count = function(_, bulletins) return bulletins end })
UI.registerTab("roster", { label = "Roster", heading = "Roster", order = 30 })

---------------------------------------------------------------------------------------------- the count

local function live(r) return r ~= nil and not r.deleted end
local function expired(b, now) return type(b.expires) == "number" and b.expires <= now end
local function bodyOf(r) return type(r) == "table" and type(r.body) == "table" and r.body or {} end

-- My roster ids: the character logged in and any other on my roster with the same person.
function UI.myIds(g)
  local ids = {}
  if not (ns.Edit and ns.Edit.me) then return ids end
  local ok, me = ns.try(ns.Edit.me, g)
  if not (ok and me) then return ids end
  ids[#ids + 1] = me.id
  local person = bodyOf(me).person
  if type(person) == "string" then
    for _, r in pairs(g.records) do
      if r.kind == "roster" and not r.deleted and r.id ~= me.id and bodyOf(r).person == person then ids[#ids + 1] = r.id end
    end
  end
  return ids, person
end

-- A guild event I could sign up for: live, the guild's own (no group), not cancelled.
local function open(r)
  local b = bodyOf(r)
  return r.kind == "event" and live(r) and not b.cancelled and (b.group == nil or b.group == ns.Json.null)
end

local function answered(g, eventId, ids)
  for _, id in ipairs(ids) do
    if live(Store.current(g, "signup", eventId .. ":" .. id)) then return true end
  end
  return false
end

local function seen(g, bulletinId, ids, person)
  for _, id in ipairs(ids) do
    if live(Store.current(g, "seen", bulletinId .. ":" .. id)) then return true end
  end
  return person ~= nil and live(Store.current(g, "seen", bulletinId .. ":p:" .. person))
end

UI.hasSeen = seen -- (guild, bulletin id, my roster ids, my person handle): the same test the red count uses

-- Events in the next seven days with no answer from any of my characters, bulletins I have not seen,
-- then the next guild event and my answer to it ("in" or nil).
function UI.count(g, now)
  local events, bulletins, nextEv = 0, 0, nil
  if type(g) ~= "table" or type(g.records) ~= "table" then return 0, 0 end
  local ids, person = UI.myIds(g)
  for _, r in pairs(g.records) do
    local b = bodyOf(r)
    if open(r) and type(b.starts) == "number" and b.starts >= now then
      if b.starts < now + 7 * DAY and #ids > 0 and not answered(g, r.id, ids) then events = events + 1 end
      if not nextEv or b.starts < nextEv.body.starts then nextEv = r end
    elseif not (UI.Bulletins and UI.Bulletins.held) and r.kind == "bulletin" and live(r) and not expired(b, now) and #ids > 0
      and not seen(g, r.id, ids, person) then
      bulletins = bulletins + 1
    end
  end
  -- The bulletins the tab lists (the current version of each, held or still pending), so the red count and the tab agree.
  if UI.Bulletins and UI.Bulletins.held and #ids > 0 then
    for _, r in ipairs(UI.Bulletins.held(g, now)) do
      if not seen(g, r.id, ids, person) then bulletins = bulletins + 1 end
    end
  end
  return events, bulletins, nextEv, ids
end

-- What the live store says now (the guild held for this game guild).
function UI.waiting()
  local ok, g = ns.try(function() return ns.Sync.guild() end)
  if not (ok and g) then return 0, 0 end
  local ok2, e, b = ns.try(UI.count, g, time())
  if not ok2 then return 0, 0 end
  return e, b
end

function UI.countText(n)
  if type(n) ~= "number" or n < 1 then return nil end
  return n > 9 and "9+" or tostring(n)
end

---------------------------------------------------------------------------------------------- words

local WORDS = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten" }
local function number(n) return WORDS[n] or tostring(n) end
UI.number = number

-- Text a guildmate wrote, safe to hand to a font string or the tooltip: a pipe starts a colour or link code there.
function UI.esc(s)
  if type(s) ~= "string" then return nil end
  return (s:gsub("|", "||"))
end
local esc = UI.esc
local function titleOf(t) return (t ~= "" and esc(t)) or "an event" end

local function clock(date, t) return date("%H:%M", t) end
local function dayName(date, t) return date("%A", t) end
local function short(date, t) return (date("%a %d %b, %H:%M", t):gsub("^(%a+ )0", "%1")) end

-- "at 18:02 today" or "on Tue 10 Nov, 21:14".
local function when(date, t, now)
  if date("%Y-%m-%d", t) == date("%Y-%m-%d", now) then return "at " .. clock(date, t) .. " today" end
  return "on " .. short(date, t)
end

-- The status line at the foot of the frame. env: guild, peer ({ name, at } of the last guildmate heard),
-- boss (true in an encounter), now, date.
function UI.statusLine(env)
  if env.boss then return UI.TEXT.boss end
  local note = env.note -- a line for a short while after an action ({ text, untilAt }), set by the screens
  if type(note) == "table" and type(note.text) == "string" and type(note.untilAt) == "number" and note.untilAt > env.now then
    return note.text
  end
  local at = type(env.guild) == "table" and type(env.guild.inbox) == "table" and env.guild.inbox.at or nil
  local peer = env.peer
  if type(peer) ~= "table" or type(peer.name) ~= "string" or type(peer.at) ~= "number" then peer = nil end
  if at and at > 0 then
    local s = "From tintean.net " .. when(env.date, at, env.now) .. "."
    if peer then s = s .. " Last from a guildmate: " .. esc(peer.name) .. ", " .. clock(env.date, peer.at) .. "." end
    return s
  end
  if peer then return "From guildmates only this session. Last: " .. esc(peer.name) .. ", " .. clock(env.date, peer.at) .. "." end
  return UI.TEXT.noneAnywhere
end

-- The minimap tooltip as lines: { text, kind } where kind is "title", "dim", "plain", "hint" or "gap".
function UI.tooltip(env)
  local g, now, date = env.guild, env.now, env.date
  local lines = { { UI.TEXT.title, "title" } }
  if env.guildName then lines[#lines + 1] = { esc(env.guildName) or "", "dim" } end
  lines[#lines + 1] = { "", "gap" }
  local at = type(g) == "table" and type(g.inbox) == "table" and g.inbox.at or nil
  local events, bulletins, nextEv, ids = 0, 0, nil, {}
  if type(g) == "table" then events, bulletins, nextEv, ids = UI.count(g, now) end
  local has = at or (type(g) == "table" and next(g.records or {}) ~= nil) or env.peer
  if events + bulletins > 0 then
    if events > 0 then
      lines[#lines + 1] = { number(events) .. (events == 1 and " event" or " events") .. " this week you haven't answered.", "plain" }
    end
    if bulletins > 0 then
      lines[#lines + 1] = { number(bulletins) .. (bulletins == 1 and " bulletin" or " bulletins") .. " you haven't seen.", "plain" }
    end
    if at then
      lines[#lines + 1] = { "", "gap" }
      lines[#lines + 1] = { "From tintean.net " .. when(date, at, now) .. ".", "dim" }
    end
    lines[#lines + 1] = { "", "gap" }
    lines[#lines + 1] = { UI.TEXT.open, "hint" }
    lines[#lines + 1] = { UI.TEXT.drag, "hint" }
    return lines
  end
  if not has then
    lines[#lines + 1] = { UI.TEXT.noData, "plain" }
  else
    local s = "Nothing waiting."
    if nextEv then
      s = s .. " Next: " .. titleOf(nextEv.body.title) .. ", " .. dayName(date, nextEv.body.starts) .. " " .. clock(date, nextEv.body.starts) .. "."
      local st = nil
      for _, id in ipairs(ids) do
        local sg = Store.current(g, "signup", nextEv.id .. ":" .. id)
        if live(sg) then st = bodyOf(sg).status end
      end
      if st == "in" then s = s .. " You're in." end
    end
    lines[#lines + 1] = { s, "plain" }
  end
  lines[#lines + 1] = { "", "gap" }
  lines[#lines + 1] = { UI.TEXT.open, "hint" }
  return lines
end

---------------------------------------------------------------------------------------------- saved places

local POINTS = { CENTER = true, TOP = true, BOTTOM = true, LEFT = true, RIGHT = true, TOPLEFT = true, TOPRIGHT = true,
  BOTTOMLEFT = true, BOTTOMRIGHT = true }

local function settings()
  local st = ns.state
  return st and st.db and st.db.settings or nil
end

-- The frame's saved place: { point, x, y }, or nil when none (or what is saved is not a place).
function UI.loadPosition()
  local s = settings()
  local w = s and s.window
  if type(w) ~= "table" or not POINTS[w.point] or type(w.x) ~= "number" or type(w.y) ~= "number" then return nil end
  if w.x ~= w.x or w.y ~= w.y or math.abs(w.x) > 10000 or math.abs(w.y) > 10000 then return nil end
  return w
end

function UI.savePosition(point, x, y)
  local s = settings()
  if not s or not POINTS[point] or type(x) ~= "number" or type(y) ~= "number" then return false end
  s.window = { point = point, x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
  return true
end

-- Where the minimap button sits: an angle in degrees round the rim; the offset from the minimap's centre.
local function finite(a) return type(a) == "number" and a == a and a ~= math.huge and a ~= -math.huge end

function UI.loadAngle()
  local s = settings()
  local m = s and s.minimap
  local a = type(m) == "table" and m.angle
  if not finite(a) then return 225 end
  return a % 360
end

function UI.saveAngle(angle)
  local s = settings()
  if not s or not finite(angle) then return false end
  if type(s.minimap) ~= "table" then s.minimap = { hide = false } end
  s.minimap.angle = math.floor(angle % 360 + 0.5)
  return true
end

-- The angle of a point (dx, dy from the centre; y up), in degrees from east, anticlockwise.
function UI.angleOf(dx, dy) return math.deg(math.atan2(dy, dx)) % 360 end
function UI.rim(angle, radius)
  local r = math.rad(angle)
  return math.cos(r) * radius, math.sin(r) * radius
end

function UI.minimapHidden()
  local s = settings()
  return s and type(s.minimap) == "table" and s.minimap.hide == true or false
end

---------------------------------------------------------------------------------------------- fonts

-- Our two fonts (README decision 3), made from the website's woff2 files (OFL, licences beside them), are drawn
-- only where the client's language is Latin script. Frame.text falls back to the game's font if SetFont fails.
local FONTS = "Interface\\AddOns\\Tintean\\Media\\Fonts\\"
UI.FILES = { body = FONTS .. "SourceSans3-Regular.ttf", display = FONTS .. "CormorantGaramond-SemiBold.ttf" }
UI.LATIN = { enUS = true, enGB = true, deDE = true, frFR = true, esES = true, esMX = true, ptBR = true, itIT = true }

function UI.ownFont(which, locale)
  if not UI.LATIN[locale or ""] then return nil end
  return UI.FILES[which]
end
