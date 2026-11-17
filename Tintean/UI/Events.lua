-- What the Events tab and an event's page say. Pure: no widgets; callers pass env = { guild, now, date, guildOffset? }
-- (UI.Frame.env() has the first three). The words are the README's strings table (docs/mockups/addon), and where
-- the table has no row for a state this file says so beside it. Text from guildmates is escaped and bounded here.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Store = ns.Store
local E = {}
UI.Events = E

local DAY = 86400
local esc, number = UI.esc, UI.number

local function bodyOf(r) return type(r) == "table" and type(r.body) == "table" and r.body or {} end
local function live(r) return r ~= nil and not r.deleted end
local function isGroup(b) return b.group ~= nil and b.group ~= ns.Json.null end
local function cap1(s) return (s:gsub("^%l", string.upper)) end
local function words(n) return number(n):lower() end

-- A guildmate's text, bounded to `n` bytes (never cutting a character in two) and escaped.
-- E.cut leaves it as written (for the note box, which is edited and sent back); E.bound is what a font string gets.
function E.cut(s, n)
  if type(s) ~= "string" then return nil end
  if #s > n then
    local cut = n
    while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    s = s:sub(1, cut)
  end
  return s
end
function E.bound(s, n)
  local t = E.cut(s, n)
  return t and esc(t)
end
local bound = E.bound

local function nameOf(r)
  local b = bodyOf(r)
  if type(b.first) ~= "string" then return nil end
  return bound(b.first .. (type(b.second) == "string" and (" " .. b.second) or ""), 60)
end
local function first(name) return type(name) == "string" and name:match("^(%S+)") or nil end

---------------------------------------------------------------------------------------------- the calendar

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }
E.DOW = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

-- Days since 1970-01-01 of a calendar day (proleptic Gregorian), and the weekday from it (Monday is 0).
local function civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
  return era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
end

local function ended(b, now)
  return type(b.starts) == "number" and b.starts + (type(b.minutes) == "number" and b.minutes or 0) * 60 < now
end

-- Every live event record held (pending edits included), as a list.
local function events(g)
  local out = {}
  local function add(slot) local id = slot:match("^event|(.+)$"); if id then out[id] = true end end
  for slot in pairs(g.records or {}) do add(slot) end
  for slot in pairs(g.pending or {}) do add(slot) end
  local list = {}
  for id in pairs(out) do
    local r = Store.current(g, "event", id)
    if live(r) and type(bodyOf(r).starts) == "number" then list[#list + 1] = r end
  end
  table.sort(list, function(a, b)
    if a.body.starts ~= b.body.starts then return a.body.starts < b.body.starts end
    return a.id < b.id
  end)
  return list
end

-- The sign-ups held, by event: eventId -> list of { id, body }.
local function signups(g)
  local ids, by = {}, {}
  for _, map in ipairs({ g.records or {}, g.pending or {} }) do
    for slot in pairs(map) do
      local id = slot:match("^signup|(.+)$")
      if id then ids[id] = true end
    end
  end
  for id in pairs(ids) do
    local r = Store.current(g, "signup", id)
    local b = bodyOf(r)
    if live(r) and type(b.event) == "string" then
      by[b.event] = by[b.event] or {}
      table.insert(by[b.event], { id = id, body = b })
    end
  end
  return by
end

-- The events and the sign-ups held, worked out once so a screen can hand them to E.month and E.list.
function E.held(g)
  if type(g) ~= "table" then return {}, {} end
  return events(g), signups(g)
end

-- Guild events in the next seven days that none of my characters has answered (the same rule as UI.count).
local function unanswered(ev, ids, now, list)
  local b = bodyOf(ev)
  if isGroup(b) or b.cancelled or b.starts < now or b.starts >= now + 7 * DAY or #ids == 0 then return false end
  for _, s in ipairs(list or {}) do
    for _, id in ipairs(ids) do
      if s.id == ev.id .. ":" .. id then return false end
    end
  end
  return true
end

-- The month `shift` months from today's: { title, prev, next, cells = { { day, out, today, dots, red, past, ids, at } } }.
-- ids are the day's events (a cell with none is not a button); `at` is when the first starts, for the day's heading.
-- dots are "sea" (the guild's), "flame" (a group's own) and "ring" (cancelled).
-- `evs` and `by` (E.held) are worked out here when not given. nil when the clock can't be read as a date.
function E.month(env, shift, evs, by)
  local g, now, date = env.guild, env.now, env.date
  local t = date("*t", now)
  if type(t) ~= "table" then return nil end
  local idx = t.year * 12 + (t.month - 1) + (shift or 0)
  local y, m = math.floor(idx / 12), idx % 12 + 1
  local firstDay = civil(y, m, 1)
  local lead = (firstDay + 3) % 7
  local len = civil(m == 12 and y + 1 or y, m % 12 + 1, 1) - firstDay
  local prevLen = firstDay - civil(m == 1 and y - 1 or y, (m + 10) % 12 + 1, 1)
  local marks = {}
  local ids = UI.myIds(g)
  if not evs then evs, by = E.held(g) end
  for _, ev in ipairs(evs) do
    pcall(function() -- one bad record leaves its own day alone, not the month
      local b = ev.body
      local et = date("*t", b.starts)
      if type(et) == "table" and et.year == y and et.month == m then
        local k = marks[et.day] or { dots = {}, over = true, ids = {} }
        marks[et.day] = k
        k.ids[#k.ids + 1] = ev.id
        k.at = k.at or b.starts
        local dot = b.cancelled and "ring" or (isGroup(b) and "flame" or "sea")
        local has = false
        for _, d in ipairs(k.dots) do if d == dot then has = true end end
        if not has then k.dots[#k.dots + 1] = dot end
        if unanswered(ev, ids, now, (by or {})[ev.id]) then k.red = true end
        if not ended(b, now) then k.over = false end
      end
    end)
  end
  local today = civil(t.year, t.month, t.day)
  local cells = {}
  for i = 1, lead do cells[#cells + 1] = { day = prevLen - lead + i, out = true } end
  for d = 1, len do
    local k = marks[d] or {}
    cells[#cells + 1] = { day = d, today = (t.year == y and t.month == m and t.day == d) or nil,
      dots = k.dots or {}, red = k.red, past = k.over or nil, ids = k.ids or {}, at = k.at,
      stamp = now + (firstDay + d - 1 - today) * DAY } -- a moment on that day by the player's clock (Plan an event's)
  end
  local n = 0
  while #cells % 7 ~= 0 do n = n + 1; cells[#cells + 1] = { day = n, out = true } end
  return { title = MONTHS[m], prev = MONTHS[(m + 10) % 12 + 1], next = MONTHS[m % 12 + 1], cells = cells }
end

---------------------------------------------------------------------------------------------- the list

local STATUS = { yes = "in", maybe = "maybe", no = "can't" }
local ACT = { levelling = "Levelling", dungeon = "Dungeon", raid = "Raid", quest_chain = "Quest chain", pvp = "PvP",
  profession = "Profession", social = "Social", other = "Other" }
-- The activity in a row's sub-line: none for a dungeon (the usual) or "other"; PvP keeps its capitals.
local ROW_ACT = { levelling = "levelling", raid = "raid", quest_chain = "quest chain", pvp = "PvP", profession = "profession",
  social = "social" }
local ROLE_WORD ={ tank = "tank", healer = "healer", dps = "damage" }
local SHORT = { tank = { "a tank", "tanks" }, healer = { "a healer", "healers" }, dps = { "a damage dealer", "damage dealers" } }
local ORDER = { "tank", "healer", "dps" }

local function tally(list)
  local c = { yes = 0, maybe = 0, no = 0, role = { tank = 0, healer = 0, dps = 0 } }
  for _, s in ipairs(list or {}) do
    local st = s.body.status
    if c[st] then c[st] = c[st] + 1 end
    if st == "yes" then
      local r = s.body.role
      if c.role[r] == nil then r = "dps" end
      c.role[r] = c.role[r] + 1
    end
  end
  return c
end

-- The roles still short against what the organiser wants: { { role, n } } in tank, healer, damage order.
local function shortOf(b, c)
  local out = {}
  local want = type(b.want) == "table" and b.want or {}
  for _, r in ipairs(ORDER) do
    if type(want[r]) == "number" and want[r] > c.role[r] then out[#out + 1] = { role = r, n = want[r] - c.role[r] } end
  end
  return out
end

-- "a healer short" / "two tanks short". The table has only "a healer short"; the others follow its pattern.
local function shortText(s)
  return s.n == 1 and (SHORT[s.role][1] .. " short") or (words(s.n) .. " " .. SHORT[s.role][2] .. " short")
end

-- "four of five", "six in" or "nobody yet".
local function countText(b, c)
  if c.yes == 0 then return "nobody yet" end
  if type(b.size) == "number" then return words(c.yes) .. " of " .. words(b.size) end
  return words(c.yes) .. " in"
end

local function mine(g, ids, meId, eventId)
  local st, role
  for _, id in ipairs(ids) do
    local r = Store.current(g, "signup", eventId .. ":" .. id)
    if live(r) and (st == nil or id == meId) then st, role = bodyOf(r).status, bodyOf(r).role end
  end
  return st, role
end

local function dayParts(date, t)
  local d, h = date("%a %d", t), date("%H:%M", t)
  if type(d) ~= "string" or type(h) ~= "string" then return nil end
  return (d:gsub("^(%a+) 0", "%1 ")), h
end

local function row(env, ev, by, ids)
  local b = ev.body
  local c = tally(by[ev.id])
  local r = { id = ev.id, title = bound(b.title, 80) or "an event", group = isGroup(b) or nil, cancelled = b.cancelled or nil,
    over = ended(b, env.now) or nil, starts = b.starts, art = UI.Art.slugOf(type(b.place) == "table" and b.place.name or nil),
    short = bound(b.title, 22) }
  r.day, r.time = dayParts(env.date, b.starts)
  if not r.day then return nil end
  local parts
  if b.cancelled then
    local who = first(type(ev.author) == "table" and ev.author.name)
    r.sub = who and (bound(who, 40) .. " cancelled it") or nil -- no row in the table without a name: the sub line is left out
    r.status = "cancelled"
  elseif isGroup(b) then
    local yes = type(b.counts) == "table" and tonumber(b.counts.yes) or 0
    r.sub = (bound(b.group.name, 60) or "") .. "'s own · " .. (yes > 0 and (words(yes) .. " in") or "nobody yet")
  else
    parts = { "The guild" }
    if ROW_ACT[b.activity] then parts[#parts + 1] = ROW_ACT[b.activity] end
    parts[#parts + 1] = countText(b, c)
    local short = shortOf(b, c)[1]
    if short and c.yes > 0 then parts[#parts + 1] = shortText(short) end
    r.sub = table.concat(parts, " · ")
    local st = mine(env.guild, ids, ids[1], ev.id)
    if st then r.status = STATUS[st]
    elseif unanswered(ev, ids, env.now, by[ev.id]) then r.status, r.red = "not yet", true end
  end
  return r
end

-- { coming = rows, earlier = rows (the last fourteen days, newest first), toAnswer = n }.
-- Coming up is cut at E.MAX_COMING rows, the last being "N more" (a row with `more` set and no id).
-- `evs` and `by` (E.held) are worked out here when not given. One record that can't be read is left out.
E.MAX_COMING = 50
function E.list(env, evs, by)
  local g, now = env.guild, env.now
  local out = { coming = {}, earlier = {}, toAnswer = 0 }
  if type(g) ~= "table" then return out end
  local ids = UI.myIds(g)
  if not evs then evs, by = E.held(g) end
  local left = 0
  for _, ev in ipairs(evs) do
    pcall(function()
      local b = ev.body
      local coming = not ended(b, now)
      if not coming and b.starts < now - 14 * DAY then return end
      local r = row(env, ev, by, ids)
      if not r then return end
      if coming then
        if #out.coming < E.MAX_COMING then out.coming[#out.coming + 1] = r else left = left + 1 end
        if r.red then out.toAnswer = out.toAnswer + 1 end
      else
        table.insert(out.earlier, 1, r)
      end
    end)
  end
  if left > 0 then out.coming[#out.coming + 1] = { more = true, title = cap1(words(left)) .. " more" } end
  return out
end

-- The rows for one day's events (the ids from a month cell), whatever their age; one that can't be read is left out.
function E.dayRows(env, ids, evs, by)
  local out = {}
  local g = env.guild
  if type(g) ~= "table" or type(ids) ~= "table" then return out end
  local want = {}
  for _, id in ipairs(ids) do want[id] = true end
  local mine_ = UI.myIds(g)
  if not evs then evs, by = E.held(g) end
  for _, ev in ipairs(evs) do
    if want[ev.id] then
      pcall(function()
        local r = row(env, ev, by or {}, mine_)
        if r then out[#out + 1] = r end
      end)
    end
  end
  return out
end

-- A figure in words up to ten, digits above, with a capital: "Two", "None", "17".
local function figure(n) return n == 0 and "None" or cap1(words(n)) end

-- The strip of figures at the top of Events (README words table, addon-look): { { n, l, gold?, dot? } }. Empty when no
-- event is ahead (the panel's own line says it). `list` is E.list's answer; env.online is the game's count of guildmates on.
function E.strip(env, list)
  local out = {}
  if type(list) ~= "table" or #list.coming == 0 then return out end
  local week, nxt = 0, nil
  for _, r in ipairs(list.coming) do
    if not r.more and not r.cancelled then
      nxt = nxt or r
      if r.starts < env.now + 7 * DAY then week = week + 1 end
    end
  end
  out[1] = { n = figure(list.toAnswer), l = "to answer this week", dot = list.toAnswer > 0 or nil }
  out[2] = { n = figure(week), l = week == 1 and "event this week" or "events this week" }
  if nxt then
    local ok, at = pcall(env.date, "%a %H:%M", nxt.starts)
    if ok and type(at) == "string" then out[#out + 1] = { n = at, l = "next: " .. nxt.short, gold = true } end
  end
  if type(env.online) == "number" and env.online >= 0 then
    out[#out + 1] = { n = figure(env.online), l = env.online == 1 and "guildmate on now" or "guildmates on now" }
  end
  return out
end

-- Pixels: the painting on a row, on a page, and the class icon for you, in rows, and in a group's stack.
E.SIZE = { row = 36, page = 48, me = 44, who = 32, stack = 26 }

E.TEXT = {
  empty = "No events planned. Saturday's looking empty.",
  under = "These are Tinteán's events, not the game calendar's.",
  allEvents = "All events", -- beside the day's date while a day of the month strip is chosen; added in M20.23, for Joe to read
  calendar = "Open the game calendar", earlier = "Earlier events", back = "Events", -- the table's "← Events": the arrow is drawn by the tab (the fonts have no arrow glyph)
  -- The Refused sheet's two lines, for a character that isn't on the roster (`unknown_author`). The sheets have no
  -- "not on the roster" state on the page itself, so the page borrows these under Your sign-up.
  unlisted = { "That character isn't on the guild's roster.",
    "Tinteán gets the roster from Blizzard, which can be an hour behind someone new. Sign up again later." },
  post = "Post in guild chat", -- the table's button
  yourSignup = "Your sign-up", whosIn = "Who's in", plan = "The plan", nobody = "Nobody yet.",
  word = "A word about your sign-up", ask = "Sign up anyway?", signUp = "Sign up", notNow = "Not now",
  refused = "Tinteán didn't accept that change.", -- the formats README's words for a reason it doesn't know; used for any local refusal
  over = "This event is over, so no more sign-ups.",
  sent = "Your sign-up is with guildmates online. The website gets it at the next logout by anyone with the desktop app.",
  pills = { { "yes", "I'm in" }, { "maybe", "Maybe" }, { "no", "Can't" } },
  roles = { tank = "Tank", healer = "Healer", dps = "Damage" },
}

---------------------------------------------------------------------------------------------- an event's page

-- Roles by class (formats/README.md, Roles): classes compare in lower case.
local CAN = { warrior = { "tank", "dps" }, paladin = { "tank", "healer", "dps" }, druid = { "tank", "healer", "dps" },
  priest = { "healer", "dps" }, shaman = { "healer", "dps" }, hunter = { "dps" }, rogue = { "dps" }, mage = { "dps" }, warlock = { "dps" } }
function E.rolesOf(class)
  return CAN[type(class) == "string" and class:lower() or ""] or { "tank", "healer", "dps" }
end

-- The game's class colours (r, g, b).
local CLASS = { druid = "ff7d0a", hunter = "abd473", mage = "69ccf0", paladin = "f58cba", priest = "ffffff", rogue = "fff569",
  shaman = "0070de", warlock = "9482c9", warrior = "c79c6e" }
function E.classColor(class)
  local h = CLASS[type(class) == "string" and class:lower() or ""]
  if not h then return nil end
  return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255, 1 }
end

-- The game's class icons: one sheet, the cell for each class in CLASS_ICON_TCOORDS (the client's own table, passed in so
-- this stays pure). Returns { file, coords = { l, r, t, b } } or nil when the class or the table isn't known.
E.CLASS_SHEET = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
function E.classIcon(class, tcoords)
  if type(class) ~= "string" or type(tcoords) ~= "table" then return nil end
  local c = tcoords[class:upper():gsub("%s", "")]
  if type(c) ~= "table" then return nil end
  for i = 1, 4 do if type(c[i]) ~= "number" then return nil end end
  return { file = E.CLASS_SHEET, coords = { c[1], c[2], c[3], c[4] } }
end

local function classLine(r)
  local b = bodyOf(r)
  local parts = {}
  if type(b.class) == "string" then parts[1] = bound(b.class, 20) end
  if type(b.level) == "number" then parts[#parts + 1] = tostring(b.level) end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

local function fullDate(date, t, utc) return (date((utc and "!" or "") .. "%A %d %B", t):gsub("^(%a+) 0(%d) ", "%1 %2 ")) end

-- "Saturday 14 November": the heading while one day of the month strip is chosen. nil when the clock can't be read.
function E.dayText(env, at)
  if type(at) ~= "number" then return nil end
  local ok, s = pcall(fullDate, env.date, at)
  return ok and type(s) == "string" and s or nil
end

-- "Saturday 14 November, 20:00 for the guild · 19:00 for you" where the clocks differ, else the one time.
-- env.guildOffset is the guild's seconds east of UTC; nothing in the inbox or the records holds it yet, so it is
-- nil today and the time is the player's own.
function E.whenText(env, starts)
  local date = env.date
  local mineText = fullDate(date, starts) .. ", " .. date("%H:%M", starts)
  if type(env.guildOffset) ~= "number" then return mineText end
  local theirs = fullDate(date, starts + env.guildOffset, true) .. ", " .. date("!%H:%M", starts + env.guildOffset)
  if theirs == mineText then return mineText end
  return theirs .. " for the guild · " .. date("%H:%M", starts) .. " for you"
end

local function metaLine(b, ev)
  if isGroup(b) then return (ACT[b.activity] or "Event") .. " · " .. (bound(b.group.name, 60) or "") end
  local parts = { ACT[b.activity] or "Event" }
  if type(b.size) == "number" then parts[#parts + 1] = words(b.size) .. (b.size == 1 and " player" or " players") end
  if type(b.minutes) == "number" and b.minutes > 0 then
    parts[#parts + 1] = b.minutes % 60 == 0 and (words(b.minutes / 60) .. (b.minutes == 60 and " hour" or " hours")) or (b.minutes .. " minutes")
  end
  local by = type(ev.author) == "table" and bound(ev.author.name, 60)
  if by then parts[#parts + 1] = "planned by " .. by end
  return table.concat(parts, " · ")
end

local function groupLine(b)
  local c = type(b.counts) == "table" and b.counts or {}
  local yes, maybe = tonumber(c.yes) or 0, tonumber(c.maybe) or 0
  -- The sheet says "its four members"; the records carry only the answers, so the member count is left out.
  local s = "Sign-up is with its members, on the website."
  local ins = yes > 0 and (cap1(words(yes)) .. (yes == 1 and " is in" or " are in")) or nil
  local maybes = maybe > 0 and (maybe == 1 and "one's a maybe" or (words(maybe) .. " are maybes")) or nil
  if ins and maybes then return s .. " " .. ins .. " and " .. maybes .. "." end
  if ins then return s .. " " .. ins .. "." end
  if maybes then return s .. " " .. cap1(maybes) .. "." end
  return s
end

-- The page for one event. `pick` is the role chosen on the page, if any. Returns nil when the event isn't held.
local function pageOf(env, eventId, pick)
  local g, now, date = env.guild, env.now, env.date
  if type(g) ~= "table" then return nil end
  local ev = Store.current(g, "event", eventId)
  if not live(ev) or type(bodyOf(ev).starts) ~= "number" then return nil end
  local b = ev.body
  local ids = UI.myIds(g)
  local meId = ids[1]
  local list = signups(g)[eventId] or {}
  local c = tally(list)
  local p = { id = eventId, starts = b.starts, title = bound(b.title, 80) or "an event", when = E.whenText(env, b.starts), meta = metaLine(b, ev),
    art = UI.Art.slugOf(type(b.place) == "table" and b.place.name or nil) }
  if isGroup(b) then
    p.state = "group"
    p.banner = { (bound(b.group.name, 60) or "") .. "'s own event.", groupLine(b) }
    return p
  end
  local who = first(type(ev.author) == "table" and ev.author.name)
  p.organiser = who and bound(who, 40) or nil
  if b.cancelled then
    p.state, p.faded = "cancelled", true
    local mineCancel = type(ev.author) == "table" and ev.author.roster == meId
    local day = (date("%a %d %b", type(ev.at) == "number" and ev.at or now):gsub("^(%a+) 0", "%1 "))
    p.banner = { mineCancel and "You cancelled this event." or (who and (bound(who, 40) .. " cancelled this event on " .. day .. ".") or "This event was cancelled.") }
  elseif ended(b, now) then
    p.state = "over"
    p.banner = { E.TEXT.over }
  else
    p.state = "open"
  end

  -- who's in
  local w = { groups = {}, figs = {} }
  p.who = w
  if not b.cancelled then w.meta = countText(b, c)
  elseif c.yes > 0 then w.meta = words(c.yes) .. ", when it was on" end
  local want = type(b.want) == "table" and b.want or {}
  for _, r in ipairs(ORDER) do
    if type(want[r]) == "number" then
      w.figs[#w.figs + 1] = { n = c.role[r] .. " of " .. want[r], l = ROLE_WORD[r] == "damage" and "damage" or (ROLE_WORD[r] .. "s"), icon = r == "dps" and "damage" or r }
    end
  end
  local by = { tank = {}, healer = {}, dps = {}, maybe = {}, no = {} }
  for _, s in ipairs(list) do
    local rr = Store.current(g, "roster", tostring(s.body.roster))
    local nm = nameOf(rr) or bound(s.body.name, 60) or "?"
    local cls = bodyOf(rr).class
    local note = bound(s.body.note, 200)
    local entry = { name = nm, color = E.classColor(cls), class = type(cls) == "string" and cls or nil }
    local st, role = s.body.status, s.body.role
    if st == "yes" then
      entry.status, entry.sub = "in", classLine(rr)
      table.insert(by[ROLE_WORD[role] and role or "dps"], entry)
    elseif st == "maybe" then
      entry.status = "maybe"
      entry.sub = (ROLE_WORD[role] or "") .. ((ROLE_WORD[role] and note) and " · " or "") .. (note or "")
      if entry.sub == "" then entry.sub = nil end
      table.insert(by.maybe, entry)
    elseif st == "no" then
      entry.status = "can't"
      table.insert(by.no, entry)
    end
  end
  for _, k in ipairs({ "tank", "healer", "dps", "maybe", "no" }) do
    table.sort(by[k], function(x, y) return x.name < y.name end)
    local label = k == "no" and "Can't" or (k == "maybe" and "Maybe" or E.TEXT.roles[k])
    local roleGroup = ROLE_WORD[k] ~= nil
    if #by[k] > 0 or (roleGroup and (tonumber(want[k]) or 0) > 0) then w.groups[#w.groups + 1] = { label = label, rows = by[k] } end
  end
  if p.state == "open" then
    local out = {}
    local short = shortOf(b, c)
    if #short > 0 then out[1] = cap1(shortText(short[1])) .. "." end
    local answered = {}
    for _, s in ipairs(list) do
      local rr = Store.current(g, "roster", tostring(s.body.roster))
      answered[bodyOf(rr).person or tostring(s.body.roster)] = true
    end
    local missing, counted = 0, {}
    for slot, r in pairs(g.records) do
      if slot:match("^roster|") and not r.deleted then
        local key = bodyOf(r).person or r.id
        if not answered[key] and not counted[key] then counted[key], missing = true, missing + 1 end
      end
    end
    if missing > 0 then w.figs[#w.figs + 1] = { n = figure(missing), l = "not answered" } end -- the strip says it, so the sentence is dropped
    w.summary = #out > 0 and table.concat(out, " ") or nil
  end
  if type(b.notes) == "string" and b.notes ~= "" then p.plan = bound(b.notes, 2000) end
  if p.state ~= "open" then return p end
  if not meId then -- the character I'm on isn't on the roster yet: the page reads, with no pills, and says why
    p.unlisted = E.TEXT.unlisted
    return p
  end

  -- my sign-up
  local meRec = Store.current(g, "roster", tostring(meId))
  local myName = nameOf(meRec) or "?"
  local myFirst = first(myName) or myName
  local roles = E.rolesOf(bodyOf(meRec).class)
  -- the answer of the character I'm on (an alt's has its own line below)
  local mySignup = Store.current(g, "signup", eventId .. ":" .. tostring(meId))
  local st = live(mySignup) and bodyOf(mySignup).status or nil
  local role = live(mySignup) and bodyOf(mySignup).role or nil
  local chosen = pick or role
  local fits = false
  for _, r in ipairs(roles) do if r == chosen then fits = true end end
  if not fits then chosen = roles[1] end
  p.me = { name = myName, first = myFirst, line = classLine(meRec), color = E.classColor(bodyOf(meRec).class), class = type(bodyOf(meRec).class) == "string" and bodyOf(meRec).class or nil, roles = roles, role = chosen,
    status = st, pending = (mySignup and mySignup.pending) or nil }
  -- value is for a font string (pipes doubled); text is as written, for the edit box only, so a pipe doesn't double on each round trip
  local held = live(mySignup) and bodyOf(mySignup).note or nil
  p.note = { value = bound(held, 200), text = E.cut(held, 200),
    hint = "A note" .. (p.organiser and (" for " .. p.organiser) or "") .. ", if you like" } -- "A note, if you like" has no row in the table
  local lines, altIn = {}, nil
  for i = 2, #ids do
    local altRec = Store.current(g, "roster", ids[i])
    local altName = nameOf(altRec)
    local s = Store.current(g, "signup", eventId .. ":" .. ids[i])
    if altName and live(s) and bodyOf(s).status == "yes" then
      lines[#lines + 1] = altName .. " is in" .. (ROLE_WORD[bodyOf(s).role] and (", " .. ROLE_WORD[bodyOf(s).role]) or "") .. "."
      altIn = altIn or { name = altName, first = first(altName) or altName, key = ids[i] }
    elseif altName and not live(s) then
      lines[#lines + 1] = altName .. " hasn't answered. Log in as " .. (first(altName) or altName) .. " to sign up with that character."
    end -- an alt's maybe or can't has no line in the table
  end
  if st == "yes" then
    table.insert(lines, 1, "You're in as " .. myName .. (ROLE_WORD[role] and (", " .. ROLE_WORD[role]) or "") .. ".")
  elseif st == nil and #lines == 0 then
    lines[1] = myFirst .. " isn't signed up yet."
  end
  p.lines = lines
  if altIn and st ~= "yes" then
    p.notice = { key = eventId .. ":" .. altIn.key, title = altIn.name .. " is in already.",
      line = "Sign " .. myFirst .. " up as well and both your characters are down for it. To move the sign-up, log in as "
        .. altIn.first .. " and press Can't there." }
  end
  return p
end

-- The page for one event, or nil when it isn't held or can't be read (a date the clock can't turn into words).
function E.page(env, eventId, pick)
  local ok, p = pcall(pageOf, env, eventId, pick)
  return ok and p or nil
end

-- A word (Words.forEvent's answer) as lines. nil for nothing to say.
function E.word(w, title)
  if type(w) ~= "table" then return nil end
  if w.relayed then
    return { relayed = true, lines = { "Your sign-up for " .. title .. " comes with a pacing warning. Sign up again from your own computer, or on the website, to read it.",
      "Without the desktop app, sign up on the website." } }
  end
  local texts = {}
  for i, t in ipairs(w.texts or {}) do if i <= 4 then texts[i] = bound(t, 600) or "" end end
  if #texts == 0 then return nil end
  return { heading = E.TEXT.word, texts = texts, ahead = w.ahead, dismissable = w.cid ~= nil }
end

return E
