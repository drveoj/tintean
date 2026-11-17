-- The party moment and the gate for every other (formats/moments/README.md section 1 and 3; decisions.md, 2026-11-15, M23.2).
-- A moment is noted only while the switch is on, only for this character, and only while grouped with at least one guildmate.
-- `Party.build` is pure: the caller passes the game's calls (`env`). Names are never read in combat (a roster change there
-- marks the party dirty and it is read at PLAYER_REGEN_ENABLED); a value `issecretvalue` flags is counted in `unnamed`.
local _, ns = ...
ns = ns or {}
ns.Moments = ns.Moments or {}

local Ids, Json = ns.Ids, ns.Json
local Store, Clock = ns.Moments.Store, ns.Moments.Clock

local Party = {}
ns.Moments.Party = Party

Party.MAX_KEYS, Party.MAX_OTHERS = 40, 38

-- The roster key of a name the game gave, or nil when it is not a usable "First Second" key (same rules as the roster report).
local function keyOf(name)
  local key = Ids.rosterKey(name)
  if #key < 3 or #key > 64 or not key:find(" ", 1, true) or key:find("[:|]") then return nil end
  return key
end

-- env: grouped() -> bool; raid() -> bool; units() -> the other members' unit tokens; name(unit) -> the whole name;
-- guild(unit) -> true, false or nil (true makes a guildmate; false or nil defers to `roster`, which can still make one);
-- roster() -> a set of roster keys, or nil or empty when not known (then a member not reported true is counted in
-- `unnamed`, never named as an outsider); secret(v). `me` is this character's name.
-- Returns { keys, others, unnamed, raid }, or nil and why ("alone", "self").
function Party.build(env, me)
  if not env.grouped() then return nil, "alone" end
  local mine = type(me) == "string" and not env.secret(me) and keyOf(me) or nil
  if not mine then return nil, "self" end
  local keys, others, unnamed, seen = { mine }, {}, 0, { [mine] = true }
  local roster
  for _, unit in ipairs(env.units()) do
    local name = env.name(unit)
    local shown = type(name) == "string" and not env.secret(name) and Store.text(name, 64) or nil
    local key = shown and keyOf(shown) or nil
    local guild = env.guild(unit)
    local unknown = false
    -- UnitIsInMyGuild is true for a guildmate near us but false for one who is not in our group's zone or range, so a plain
    -- false never makes a roster-listed member an outsider: the roster is asked unless the game said true.
    if guild ~= true and key then
      if roster == nil then
        roster = env.roster()
        if type(roster) ~= "table" or next(roster) == nil then roster = false end
      end
      if roster and roster[key] == true then
        guild = true
      elseif not roster then
        unknown, guild = true, false -- no roster to check: not a stranger, just not known
      else
        guild = false
      end
    end
    if not shown or unknown then
      unnamed = unnamed + 1
    elseif guild then
      if not key then
        unnamed = unnamed + 1
      elseif not seen[key] and #keys < Party.MAX_KEYS then
        seen[key] = true
        keys[#keys + 1] = key
      end
    elseif not seen[shown] and #others < Party.MAX_OTHERS then
      seen[shown] = true
      others[#others + 1] = shown
    end
  end
  if #keys < 2 then return nil, "alone" end
  unnamed = math.min(unnamed, Party.MAX_OTHERS, Party.MAX_KEYS - #keys - #others)
  return { keys = keys, others = others, unnamed = math.max(0, unnamed), raid = env.raid() == true }
end

---------------------------------------------------------------------------------------------- the game

local function plain(v) return Clock.plain(v) end

local function call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local r = { pcall(fn, ...) }
  if not r[1] then return nil end
  return r[2]
end

function Party.gameEnv()
  return {
    grouped = function() return call(IsInGroup) == true end,
    raid = function() return call(IsInRaid) == true end,
    units = function()
      local n, units, raid = call(GetNumGroupMembers), {}, call(IsInRaid) == true
      if type(n) ~= "number" or not plain(n) then return units end
      for i = 1, raid and math.min(n, 40) or math.min(n - 1, 4) do
        local u = (raid and "raid" or "party") .. i
        if call(UnitExists, u) ~= false and not (raid and call(UnitIsUnit, u, "player") == true) then units[#units + 1] = u end
      end
      return units
    end,
    name = function(unit) return call(GetUnitName, unit, true) end,
    guild = function(unit)
      local v = call(UnitIsInMyGuild, unit)
      if type(v) == "boolean" and plain(v) then return v end
      return nil
    end,
    roster = function()
      local g = ns.Sync and ns.Sync.guild and ns.Sync.guild()
      local set = {}
      for _, m in ipairs(g and g.report and g.report.members or {}) do
        if type(m) == "table" and type(m.name) == "string" then set[Ids.rosterKey(m.name)] = true end
      end
      return set
    end,
    secret = function(v) return not plain(v) end,
  }
end

Party.state = { active = nil, sig = nil, dirty = false }
local state = Party.state

-- Whether anything may be noted: the switch (on unless saved off) and writable saved data.
function Party.enabled()
  local st = ns.state
  return st and st.db and not st.readOnly and type(st.db.settings) == "table" and st.db.settings.moments ~= false or false
end

-- This guild's key (the CRC of its name, as a string) and this character's roster key, or nil.
function Party.where()
  local gname = call(GetGuildInfo, "player")
  if type(gname) ~= "string" or gname == "" or not (ns.Receive and ns.Inbox) then return nil end
  local me = ns.Receive.myName()
  local ckey = me and keyOf(me)
  if not ckey then return nil end
  return tostring(ns.Inbox.key(gname)), ckey, me
end

-- The place and level a moment carries: map id, zone, subzone, level. Anything secret or missing is nil.
local function stamp()
  local map, zone, sub = nil, call(GetRealZoneText), call(GetSubZoneText)
  if type(C_Map) == "table" then map = call(C_Map.GetBestMapForUnit, "player") end
  local lvl = call(UnitLevel, "player")
  return { map = type(map) == "number" and plain(map) and map or nil, zone = plain(zone) and zone or nil,
    sub = plain(sub) and sub or nil, lvl = type(lvl) == "number" and plain(lvl) and lvl or nil }
end

-- The time, clock and place as they are now, for a moment that is held back and noted later (M23.3b: nothing is stored
-- during a boss encounter). `lvl` overrides the level read.
function Party.snapshot(lvl)
  local at, clock = Clock.now()
  local s = stamp()
  s.at, s.clock = at, clock
  if lvl then s.lvl = lvl end
  return s
end

local function put(kind, what, p, gkey, ckey, snap)
  if not gkey then gkey, ckey = Party.where() end
  if not gkey then return nil, "no_guild" end
  local at, clock = Clock.now()
  if snap then at, clock = snap.at, snap.clock end
  if not at then return nil, "no_clock" end
  local s = snap or stamp()
  local ok, seq, why = pcall(Store.note, ns.state.db, gkey, ckey,
    { at = at, kind = kind, p = p, map = s.map, zone = s.zone, sub = s.sub, lvl = s.lvl, what = what }, clock, ns.state.counters)
  if not ok then return nil, "error" end
  return seq, why
end

-- The gate for every moment but the party's own (the events, M23.3b): nothing unless the switch is on and a party with a
-- guildmate is in effect. Returns the seq, or nil and why.
function Party.note(kind, what, snap)
  if not Party.enabled() then return nil, "off" end
  if not state.active then return nil, "alone" end
  return put(kind, what or {}, state.active, nil, nil, snap)
end

-- Reads the group and notes a `party` (membership changed) or a `party_end` (the last guildmate left). Never in combat.
function Party.update(env)
  if not Party.enabled() then return end
  if ns.closed(InCombatLockdown) then state.dirty = true; return end
  state.dirty = false
  local gkey, _, me = Party.where()
  if not gkey then
    -- Left the guild or the game gives no name: the party in effect ends, under the keys it was noted with.
    if state.active then
      put("party_end", {}, state.active, state.gkey, state.ckey)
      state.active, state.sig = nil, nil
    end
    return
  end
  local p = Party.build(env or Party.gameEnv(), me)
  if not p then
    if state.active then
      put("party_end", {}, state.active)
      state.active, state.sig = nil, nil
    end
    return
  end
  local sig = table.concat(p.keys, "|") .. "#" .. table.concat(p.others, "|") .. "#" .. p.unnamed .. (p.raid and "r" or "")
  if state.active and sig == state.sig then return end
  local what = { keys = p.keys, others = Json.array(), unnamed = p.unnamed, raid = p.raid }
  for _, o in ipairs(p.others) do what.others[#what.others + 1] = o end
  local seq = put("party", what)
  if seq then
    state.active, state.sig, state.keys = seq, sig, p.keys
    state.gkey, state.ckey = gkey, select(2, Party.where())
    local Events = ns.Moments.Events
    if Events and Events.noteDungeon then ns.try(Events.noteDungeon) end
  end
end

-- The switch pressed off: held moments go and nothing more is noted. Pressed on: the group is read at once.
function Party.switched(on)
  local st = ns.state
  if not (st and st.db) then return end
  if not on then
    Store.clear(st.db)
    state.active, state.sig, state.dirty = nil, nil, false
  else
    ns.try(Party.update)
  end
end

Party.DELAY = 1

-- Roster events come in bursts: one read, a second after the first of them. Without C_Timer it reads at once.
function Party.later()
  if state.pending then return end
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    state.pending = true
    local ok = ns.try(C_Timer.After, Party.DELAY, function()
      state.pending = false
      ns.try(Party.update)
    end)
    if not ok then state.pending = false; ns.try(Party.update) end
  else
    ns.try(Party.update)
  end
end

local frame = type(CreateFrame) == "function" and CreateFrame("Frame") or nil
if frame then
  -- Each on its own, so a client without one still gets the others.
  for _, e in ipairs({ "PLAYER_LOGIN", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" }) do
    pcall(frame.RegisterEvent, frame, e)
  end
  frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
      if ns.state and ns.state.db then ns.try(Store.prune, ns.state.db, Clock.now() or 0, ns.state.counters) end
      ns.try(Party.update)
    elseif event == "PLAYER_REGEN_ENABLED" then
      if state.dirty then ns.try(Party.update) end
    else
      Party.later()
    end
  end)
end

-- /tintean check
function Party.lines()
  local st = ns.state
  if not (st and st.db) then return {} end
  if not Party.enabled() then return { ns.tag .. " moments: off." } end
  local s = Store.summary(st.db)
  if s.streams == 0 then return { ns.tag .. " moments: nothing noted." } end
  local clocks = {}
  for c in pairs(s.clocks) do clocks[#clocks + 1] = c end
  table.sort(clocks)
  local out = { string.format("%s moments: %d stream%s, %d held, %d dropped, clock %s.", ns.tag, s.streams,
    s.streams == 1 and "" or "s", s.held, s.dropped, table.concat(clocks, " and ")) }
  for gk, g in pairs(st.db.moments) do
    for ck, e in pairs(type(g) == "table" and g or {}) do
      if type(e) == "table" and type(e.list) == "table" then
        local parties = 0
        for _, m in ipairs(e.list) do if m.kind == "party" then parties = parties + 1 end end
        out[#out + 1] = string.format("%s moments %s/%s: stream %s, next seq %d, %d held (%d party), %d dropped.", ns.tag, gk, ck,
          e.stream, (e.seq or 0) + 1, #e.list, parties, e.dropped or 0)
      end
    end
  end
  return out
end

local baseCheck = ns.check
function ns.check()
  if baseCheck then ns.try(baseCheck) end
  for _, l in ipairs(Party.lines()) do ns.out(l) end
end

return Party
