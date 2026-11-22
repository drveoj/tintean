-- What the Bulletins tab says. Pure: no widgets; callers pass env = { guild, now, date } (UI.Frame.env() has them).
-- The words are the README's strings table (docs/mockups/addon, Bulletins) and the look README's strip. Text from
-- guildmates is escaped and bounded here, as in Events.lua.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Store = ns.Store
local B = {}
UI.Bulletins = B

local E = UI.Events
local bound, number = E.bound, UI.number

local function bodyOf(r) return type(r) == "table" and type(r.body) == "table" and r.body or {} end
local function live(r) return r ~= nil and not r.deleted end

B.TEXT = {
  empty = "No bulletins up.", seen = "Seen", seenAfter = "You've seen this",
  upNow = "up now", notSeen = "not seen", -- the strip's words (addon-look README)
}

-- "Tue 10 Nov": the day without a leading nought.
local function day(date, t)
  if type(t) ~= "number" then return nil end
  local ok, s = pcall(date, "%a %d %b", t)
  return ok and type(s) == "string" and (s:gsub("^(%a+) 0", "%1 ")) or nil
end

local function figure(n) return n == 0 and "None" or number(n) end

-- When it was first posted: the current version's `created`, else the held server version's, else the
-- smallest `at` held for the id (server version and pending edit).
function B.created(g, r)
  local c = bodyOf(r).created
  if type(c) == "number" then return c end
  local slot = Store.slot("bulletin", r.id)
  local held, pend = g.records and g.records[slot], g.pending and g.pending[slot]
  c = bodyOf(held).created
  if type(c) == "number" then return c end
  local least
  for _, v in ipairs({ held or false, pend or false }) do
    if v and type(v.at) == "number" and (not least or v.at < least) then least = v.at end
  end
  return least or (type(r.at) == "number" and r.at or 0)
end

-- The first writer's name (`by`): the current version's, else the held server version's; nil when neither has one.
local function firstWriter(g, r)
  local by = bodyOf(r).by
  if type(by) ~= "string" then
    local held = g.records and g.records[Store.slot("bulletin", r.id)]
    by = bodyOf(held).by
  end
  return E.first(by)
end

-- Every live bulletin held (pending edits included), unexpired, pinned first and then newest.
function B.held(g, now)
  local ids, list = {}, {}
  for _, map in ipairs({ g.records or {}, g.pending or {} }) do
    for slot in pairs(map) do
      local id = slot:match("^bulletin|(.+)$")
      if id then ids[id] = true end
    end
  end
  for id in pairs(ids) do
    local r = Store.current(g, "bulletin", id)
    local b = bodyOf(r)
    if live(r) and type(b.title) == "string" and not (type(b.expires) == "number" and b.expires <= now) then list[#list + 1] = r end
  end
  local stamp = {}
  for _, r in ipairs(list) do stamp[r] = B.created(g, r) end
  table.sort(list, function(a, c)
    local pa, pc = bodyOf(a).pinned == true, bodyOf(c).pinned == true
    if pa ~= pc then return pa end
    local ta, tc = stamp[a], stamp[c]
    if ta ~= tc then return ta > tc end
    return a.id < c.id
  end)
  return list
end

-- The foot (first writer and first-posted date): "Pinned · Brannoc, Tue 10 Nov · up until Sun 22 Nov", each part only when there is something to say.
local function foot(g, r, b, date)
  local parts = {}
  if b.pinned == true then parts[#parts + 1] = "Pinned" end
  -- The first writer and the first-posted date; a record without `by` (held from before) names its latest author.
  local who = firstWriter(g, r)
  local when
  if who then when = day(date, B.created(g, r))
  else
    who = E.first(type(r.author) == "table" and r.author.name or nil)
    when = day(date, r.at)
  end
  if who and when then parts[#parts + 1] = bound(who, 40) .. ", " .. when
  elseif who or when then parts[#parts + 1] = who and bound(who, 40) or when end
  local upTo = type(b.expires) == "number" and day(date, b.expires) or nil
  if upTo then parts[#parts + 1] = "up until " .. upTo end
  return table.concat(parts, " · ")
end

-- The tab: { pages, strip }. A page is { id, title, text, foot, state, event = { id, title, art } }, where state is
-- "unseen" (the button), "seen" ("You've seen this") or nil (a character not on the roster can't mark anything seen).
function B.tab(env)
  local g, now, date = env.guild, env.now, env.date
  local out = { pages = {}, strip = {} }
  if type(g) ~= "table" then return out end
  local ids, person = UI.myIds(g)
  local unseen = 0
  for _, r in ipairs(B.held(g, now)) do
    local b = bodyOf(r)
    local p = { id = r.id, title = bound(b.title, 80) or "", text = bound(b.text, 600) or "", foot = foot(g, r, b, date), pinned = b.pinned == true }
    if #ids > 0 then
      p.state = UI.hasSeen(g, r.id, ids, person) and "seen" or "unseen"
      if p.state == "unseen" then unseen = unseen + 1 end
    end
    if type(b.event) == "string" then
      local ev = Store.current(g, "event", b.event)
      local eb = bodyOf(ev)
      if live(ev) and type(eb.title) == "string" then
        p.event = { id = b.event, title = bound(eb.title, 80), art = UI.Art.slugOfPlace(eb.place) }
      end
    end
    out.pages[#out.pages + 1] = p
  end
  if #out.pages > 0 then
    out.strip[1] = { n = figure(#out.pages), l = B.TEXT.upNow }
    if #ids > 0 then out.strip[2] = { n = figure(unseen), l = B.TEXT.notSeen, dot = unseen > 0 or nil } end
  end
  return out
end
