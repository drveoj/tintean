-- What the Roster tab says. Pure: no widgets; callers pass env = { guild, now, date, members } (the tab reads the game's
-- roster into `members`, see R.member). The words are the README's strings table (docs/mockups/addon, Roster) and the look
-- README's strip. Names and zones come from the game and are escaped and bounded here, as in Events.lua.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Store = ns.Store
local R = {}
UI.Roster = R

local E = UI.Events
local bound, number = E.bound, UI.number

local function bodyOf(r) return type(r) == "table" and type(r.body) == "table" and r.body or {} end
local function live(r) return r ~= nil and not r.deleted end
local function fold(s) return (s:gsub("%-", " ")):lower() end

R.TEXT = {
  heading = "Roster", inGuild = "in the guild", onNow = "on now", inTintean = "in Tinteán", notYet = "not yet",
  filters = { { "all", "Everyone" }, { "on", "On now" }, { "in", "In Tinteán" }, { "not", "Not yet" } },
  note = "The game's guild window has invites and promotions.", open = "Open the guild window",
}

local function figure(n) return n == 0 and "None" or number(n) end

-- One row of the game's roster, as GetGuildRosterInfo and GetGuildRosterLastOnline give it (years, months, days and hours
-- since the character was last on, nil when it is on). Nothing without a name; `ago` is in seconds, about.
function R.member(name, rankName, rank, level, class, zone, online, classFile, years, months, days, hours)
  if type(name) ~= "string" or name == "" or type(rank) ~= "number" then return nil end
  local ago
  if online ~= true and type(years) == "number" then
    ago = (((years * 12) + (months or 0)) * 30 + (days or 0)) * 86400 + (hours or 0) * 3600
  end
  return { name = name, rankName = rankName, rank = rank, level = level, class = classFile or class, className = class,
    zone = zone, online = online == true, ago = ago }
end

-- "last on Tue" and its kin, from how long ago they were last on; nil when the game doesn't say.
function R.lastOn(ago, now, date)
  if type(ago) ~= "number" or type(now) ~= "number" then return nil end
  local ok, t = pcall(date, "*t", now)
  if not ok or type(t) ~= "table" then return nil end
  local midnight = now - (t.hour * 3600 + t.min * 60 + t.sec)
  local at = now - ago
  if at >= midnight then return "last on today" end
  if at >= midnight - 86400 then return "last on yesterday" end
  local ok2, s = pcall(date, at >= midnight - 6 * 86400 and "%a" or "%d %b", at)
  if not ok2 or type(s) ~= "string" then return nil end
  return "last on " .. (s:gsub("^0", ""))
end

-- Ranks the guild counts as officers: the guild master, then the website's settings (the `ranks` record), then any
-- roster record of that rank that says so.
local function officers(g)
  local flags = bodyOf(Store.current(g, "ranks", "ranks")).officer
  local out = { [0] = true }
  if type(flags) == "table" then for i = 1, 10 do if flags[i] == true then out[i - 1] = true end end end
  for _, r in pairs(g.records or {}) do
    local b = bodyOf(r)
    if r.kind == "roster" and live(r) and b.officer == true and type(b.rank) == "number" then out[b.rank] = true end
  end
  return out
end

R.officers = officers

-- The roster as the store holds it, for when the game's own isn't readable yet: no zone, no last-on.
local function fromStore(g)
  local out = {}
  for _, r in pairs(g.records or {}) do
    local b = bodyOf(r)
    if r.kind == "roster" and live(r) and type(b.first) == "string" and type(b.rank) == "number" then
      out[#out + 1] = { name = ns.Checks.rosterName(b), rankName = b.rankName, rank = b.rank, level = b.level,
        class = b.class, className = b.class, online = false }
    end
  end
  return out
end

-- The tab, with the chosen filter ("all", "on", "in", "not"): { strip, groups, total } where a group is
-- { label, meta, rows } and a row is { name, class, color, sub, status, tintean }.
function R.tab(env, filter)
  local g, now, date = env.guild, env.now, env.date
  local out = { strip = {}, groups = {}, total = 0 }
  if type(g) ~= "table" then return out end
  local people = {}
  for _, r in pairs(g.records or {}) do
    local b = bodyOf(r)
    if r.kind == "roster" and live(r) and type(b.first) == "string" then
      people[fold(ns.Checks.rosterName(b))] = type(b.person) == "string"
    end
  end
  local members = type(env.members) == "table" and #env.members > 0 and env.members or fromStore(g)
  local counts, on, inT = #members, 0, 0
  local rows, labels = {}, {}
  for _, m in ipairs(members) do
    local tin = people[fold(m.name)] == true
    if m.online then on = on + 1 end
    if tin then inT = inT + 1 end
    local keep = filter == "on" and m.online or filter == "in" and tin or filter == "not" and not tin
      or (filter ~= "on" and filter ~= "in" and filter ~= "not")
    if keep then
      local sub = { bound(m.className, 20) }
      if type(m.level) == "number" then sub[#sub + 1] = tostring(m.level) end
      if m.online and type(m.zone) == "string" and m.zone ~= "" then sub[#sub + 1] = bound(m.zone, 40) end
      local row = { name = bound(m.name, 40), class = m.class, color = E.classColor(m.class), tintean = tin,
        sub = table.concat(sub, " · "), status = m.online and "on now" or R.lastOn(m.ago, now, date) }
      rows[m.rank] = rows[m.rank] or {}
      table.insert(rows[m.rank], row)
      if type(m.rankName) == "string" and m.rankName ~= "" then labels[m.rank] = labels[m.rank] or bound(m.rankName, 40) end
    end
  end
  local officer, ranks = officers(g), {}
  for rank in pairs(rows) do ranks[#ranks + 1] = rank end
  table.sort(ranks)
  for _, rank in ipairs(ranks) do
    table.sort(rows[rank], function(a, b) return a.name < b.name end)
    out.groups[#out.groups + 1] = { label = labels[rank] or ("Rank " .. rank), rows = rows[rank],
      meta = officer[rank] and ("rank " .. rank .. " · officers") or nil }
  end
  out.total = counts
  if counts > 0 then
    out.strip = { { n = number(counts), l = R.TEXT.inGuild },
      { n = figure(on), l = R.TEXT.onNow, gold = on > 0 or nil }, { n = figure(inT), l = R.TEXT.inTintean },
      { n = figure(counts - inT), l = R.TEXT.notYet } }
  end
  return out
end
