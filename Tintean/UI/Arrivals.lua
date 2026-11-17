-- What arrives while you play, and what *Post in guild chat* sends. Pure: no widgets, no chat. Callers pass
-- env = { guild, now, date } (UI.Frame.env() has them) and say what is shown. Words are the README's strings table
-- (docs/mockups/addon, While playing); the few it lacks are marked "for Joe to read".
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Store = ns.Store
local A = {}
UI.Arrivals = A

local E = UI.Events
local DAY = 86400

A.FRESH = 900 -- a record counts as arriving only if its edit is this recent (a catch-up brings old ones)
A.REMIND_FROM, A.REMIND_TO = 13 * 60, 15 * 60 -- the reminder goes when an event is this far off (seconds left, over and up to)

A.TEXT = {
  open = "Open",
  openHint = "/tintean to open", -- the README's line without the game's addon link type, to confirm in game
  bulletinToast = "New bulletin: ", -- for Joe to read: the table has the new-event toast only
  someone = "A guildmate", -- for Joe to read: when the edit carries no name
  loginOne = "One event this week you haven't answered. It is ", -- for Joe to read: the table has the plural only
  shut = "The game isn't letting addons post in chat right now.", line = "Try again after the fight.", -- the States sheet
  signUp = "Sign up with /tintean or on tintean.net.",
  bulletinLine = "Bulletin: ", readIt = "Read it with /tintean or on tintean.net.", -- for Joe to read: the table has the event's line only
}

local ROLE = { tank = "tank", healer = "healer", dps = "damage" }

local function bodyOf(r) return type(r) == "table" and type(r.body) == "table" and r.body or {} end
local function live(r) return r ~= nil and not r.deleted end
local function guildEvent(b) return b.group == nil or b.group == ns.Json.null end
local function first(s) return type(s) == "string" and s:match("^(%S+)") or nil end
local function noZero(s) return (s:gsub("^(%a+) 0", "%1 ")) end

-- A setting of the account (defaults as SavedVars makes them; a missing table counts as the defaults).
function A.on(name)
  local st = ns.state
  local s = st and st.db and st.db.settings
  if type(s) ~= "table" or s[name] == nil then return name ~= "sound" end
  return s[name] == true
end

-- "Saturday 14 Nov": the day without a nought. nil if the clock can't say.
local function dayOf(date, t)
  local ok, s = pcall(date, "%A %d %b", t)
  return ok and type(s) == "string" and noZero(s) or nil
end
local function clockOf(date, t)
  local ok, s = pcall(date, "%H:%M", t)
  return ok and type(s) == "string" and s or nil
end

-- What a guildmate's new event or bulletin raises: { chat, toast = { kind, id, title, line, art } }, or nil when it
-- raises nothing: my own, a group's, cancelled, over, deleted, or not from the last few minutes.
function A.arrival(env, rec)
  local g, now, date = env.guild, env.now, env.date
  if type(g) ~= "table" or type(rec) ~= "table" or rec.deleted or type(rec.id) ~= "string" then return nil end
  local b = bodyOf(rec)
  if type(b.title) ~= "string" or type(rec.at) ~= "number" or rec.at < now - A.FRESH then return nil end
  local au = type(rec.author) == "table" and rec.author or {}
  for _, id in ipairs(UI.myIds(g)) do if au.roster == id then return nil end end
  local who = E.bound(first(au.name) or "", 40)
  if who == "" then who = A.TEXT.someone end
  local title = E.bound(b.title, 80)
  if rec.kind == "event" then
    if b.cancelled or not guildEvent(b) or type(b.starts) ~= "number" or b.starts < now then return nil end
    local day, hm = dayOf(date, b.starts), clockOf(date, b.starts)
    if not (day and hm) then return nil end
    return { kind = "event", title = title, chat = who .. " planned " .. title .. ", " .. day .. " at " .. hm .. ".",
      toast = { kind = "event", id = rec.id, title = "New event: " .. title, line = day .. ", " .. hm .. " · " .. who,
        art = UI.Art.slugOf(type(b.place) == "table" and b.place.name or nil) } }
  elseif rec.kind == "bulletin" then
    if type(b.expires) == "number" and b.expires <= now then return nil end
    return { kind = "bulletin", title = title, chat = "New bulletin from " .. who .. ": " .. title .. ".",
      toast = { kind = "bulletin", id = rec.id, title = A.TEXT.bulletinToast .. title, line = who } }
  end
  return nil
end

-- The chat lines for what arrived together (A.arrival's answers, in order): a lone event keeps its own line, two events
-- are named in one ("Two new events since you were last on: X and Y."), three or more become a count. Bulletins keep
-- their own lines, after the events'. The count line is for Joe to read: the sheet names two and says "a count" after.
function A.batch(list)
  local events, out = {}, {}
  for _, a in ipairs(list) do
    if a.kind == "event" then events[#events + 1] = a else out[#out + 1] = a.chat end
  end
  local lines = {}
  if #events == 1 then
    lines[1] = events[1].chat
  elseif #events == 2 then
    lines[1] = "Two new events since you were last on: " .. events[1].title .. " and " .. events[2].title .. "."
  elseif #events > 2 then
    lines[1] = UI.number(#events) .. " new events since you were last on."
  end
  for _, l in ipairs(out) do lines[#lines + 1] = l end
  return lines
end

-- The character of mine that is in for the event: { first name, role word } or nil.
local function mineIn(g, eventId, ids)
  for _, id in ipairs(ids) do
    local s = Store.current(g, "signup", eventId .. ":" .. id)
    if live(s) and bodyOf(s).status == "yes" then
      local name = first(bodyOf(Store.current(g, "roster", id)).first)
      return name and E.bound(name, 40) or "?", ROLE[bodyOf(s).role]
    end
  end
  return nil
end

-- Events I'm in that are 15 minutes off and not yet in `done` (a set the caller keeps, keyed id:starts):
-- { { key, id, chat, toast } } in start order.
function A.reminders(env, done)
  local g, now, date = env.guild, env.now, env.date
  local out = {}
  if type(g) ~= "table" or type(g.records) ~= "table" then return out end
  local ids = UI.myIds(g)
  if #ids == 0 then return out end
  for _, r in pairs(g.records) do
    local b = bodyOf(r)
    if r.kind == "event" and live(r) and not b.cancelled and guildEvent(b) and type(b.starts) == "number"
        and type(b.title) == "string" then
      local left, key = b.starts - now, r.id .. ":" .. b.starts
      if left > A.REMIND_FROM and left <= A.REMIND_TO and not done[key] then
        local name, role = mineIn(g, r.id, ids)
        local hm = clockOf(date, b.starts)
        if name and hm then
          local as = name .. (role and (", " .. role) or "")
          local title = E.bound(b.title, 80)
          out[#out + 1] = { key = key, id = r.id, starts = b.starts,
            chat = title .. " starts in 15 minutes, at " .. hm .. ". You're in as " .. as .. ".",
            toast = { kind = "event", id = r.id, title = title .. " in 15 minutes", line = hm .. " · you're in as " .. as,
              art = UI.Art.slugOf(type(b.place) == "table" and b.place.name or nil) } }
        end
      end
    end
  end
  table.sort(out, function(a, c) if a.starts ~= c.starts then return a.starts < c.starts end return a.id < c.id end)
  return out
end

-- The login line for events this week with no answer from any of my characters: nil when there are none.
function A.login(env)
  local g, now, date = env.guild, env.now, env.date
  if type(g) ~= "table" or type(g.records) ~= "table" then return nil end
  local ids = UI.myIds(g)
  if #ids == 0 then return nil end
  local n, nextEv = 0, nil
  for _, r in pairs(g.records) do
    local b = bodyOf(r)
    if r.kind == "event" and live(r) and not b.cancelled and guildEvent(b) and type(b.starts) == "number"
        and type(b.title) == "string" and b.starts >= now and b.starts < now + 7 * DAY then
      local answered = false
      for _, id in ipairs(ids) do if live(Store.current(g, "signup", r.id .. ":" .. id)) then answered = true end end
      if not answered then
        n = n + 1
        if not nextEv or b.starts < nextEv.body.starts then nextEv = r end
      end
    end
  end
  if n == 0 then return nil end
  local ok, day = pcall(date, "%A", nextEv.body.starts)
  local hm = clockOf(date, nextEv.body.starts)
  if not (ok and hm) then return nil end
  local where = E.bound(nextEv.body.title, 80) .. ", " .. day .. " at " .. hm .. "."
  if n == 1 then return A.TEXT.loginOne .. where end
  return UI.number(n) .. " events this week you haven't answered. The next is " .. where
end

-- The one line *Post in guild chat* sends for an open event's page `p` (E.page's answer, with its start), or nil.
-- Pipes are dropped: the game reads them as codes, and the line goes out as the player.
function A.post(p, date)
  if type(p) ~= "table" or p.state ~= "open" or type(p.starts) ~= "number" or type(p.who) ~= "table" or not p.who.meta then
    return nil
  end
  local ok, when = pcall(date, "%a %d %b %H:%M", p.starts)
  if not ok or type(when) ~= "string" then return nil end
  local s = p.title .. ", " .. noZero(when) .. ": " .. p.who.meta
  if type(p.who.summary) == "string" then
    local short = p.who.summary:gsub("%.$", ""):gsub("^%u", string.lower)
    s = s .. ", " .. short
  end
  local line = (s .. ". " .. A.TEXT.signUp):gsub("|", "")
  return line
end

-- The one line *Post in guild chat* sends for a bulletin's page `p` (B.tab's answer), or nil. The sheet has no line for
-- a bulletin: this is the event's, in the same voice (for Joe to read).
function A.postBulletin(p)
  if type(p) ~= "table" or type(p.title) ~= "string" or p.title == "" then return nil end
  local title = p.title:gsub("|", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if title == "" then return nil end
  return A.TEXT.bulletinLine .. title:gsub("%.$", "") .. ". " .. A.TEXT.readIt
end

return A
