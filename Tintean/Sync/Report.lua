-- The roster report (formats/README.md, The roster report; game.md section 13): what the game's guild roster says,
-- read by this character and kept as the guild's latest in `guilds[slug].report`, for the desktop app and the paste.
-- Report.build is pure: the caller passes the calls (`env`) and the clock. Only name, rank, level, class, last online
-- and GUID are read; zone, status, notes and achievements are never touched.
local _, ns = ...
ns = ns or {}

local Report = {}
ns.Report = Report

local Json, Ids = ns.Json, ns.Ids
local null = Json.null

Report.CAP = 1000
Report.MIN_READ = 60   -- seconds between reads (decisions.md: re-read at most every 60 s)
Report.MIN_ASK = 20    -- seconds between GuildRoster() requests: the game has its own throttle, this stays well clear
Report.WAIT = 10       -- read anyway this long after asking, if the game's update never came
Report.SLOW = 600      -- seconds: the slow timer's period
Report.KEEP_WHOLE = 3600 -- a partial read does not replace a whole one younger than this

local DAY = 86400

-- "First Second" as the report carries it. A "-Realm" suffix is dropped only when it is this client's own realm name
-- (Forever has none; "Anne Smith-Jones" is a name) and what precedes it already holds a space. Nil for anything with a
-- control character, a key that is too long, or no real space: a one-word name, hyphenated or not ("Smith-Jones").
local function cleanName(name, realm)
  if type(name) ~= "string" then return nil end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name:find("[%z\1-\31]") then return nil end
  if type(realm) == "string" and realm ~= "" then
    local head, tail = name:match("^(.*)%-([^%- ]+)$")
    if head and head:find(" ", 1, true) and tail:lower() == realm:lower() then name = head end
  end
  if not name:find(" ", 1, true) then return nil end
  local key = Ids.rosterKey(name)
  if #key < 3 or #key > 64 or not key:find(" ", 1, true) or key:find("[:|]") then return nil end
  return name, key
end

-- The last-online years, months, days and hours the game gives for an offline member, as epoch seconds before `at`.
local function lastOn(at, y, m, d, h)
  for _, v in ipairs({ y, m, d, h }) do
    if v ~= nil and (type(v) ~= "number" or v < 0 or v > 1000 or v ~= v or v ~= math.floor(v)) then return null end
  end
  if y == nil and m == nil and d == nil and h == nil then return null end
  local n =((y or 0) * 365 + (m or 0) * 30 + (d or 0)) * DAY + (h or 0) * 3600
  return math.max(0, at - n)
end

-- env: total() -> the game's member count; row(i) -> name, rankIndex, level, classFile, isOnline, guid;
-- last(i) -> years, months, days, hours; secret(v) -> true for a value the game won't let us read.
-- `me` is this character's name. `opts`: settled (the roster arrived after our own request, so it is not a half-loaded
-- one: without it the report is never whole), held (the guild's held report, for the size check). Also env.realm().
-- Returns the report, or nil and a reason ("empty", "not_listed").
function Report.build(env, now, me, opts)
  opts = opts or {}
  local total, numOnline = env.total()
  local realm = env.realm and env.realm() or nil
  local plain = function(v) return v ~= nil and not env.secret(v) end
  local complete = type(total) == "number" and plain(total) and total == math.floor(total) and total >= 0
  if not complete then total = 0 end
  local count = math.min(total, Report.CAP)
  local members, seen, rank0 = Json.array(), {}, false
  local clean = complete and total <= Report.CAP
  for i = 1, count do
    local ok, name, rank, level, class, online, guid = pcall(env.row, i)
    local good = false
    if ok then
      local shown, key = nil, nil
      if plain(name) then shown, key = cleanName(name, realm) end
      if shown and not seen[key] and plain(rank) and type(rank) == "number" and rank >= 0 and rank <= 9 and rank == math.floor(rank)
        and plain(level) and type(level) == "number" and level >= 1 and level <= 255 and level == math.floor(level)
        and plain(class) and type(class) == "string" and #class <= 32 and class:find("^[%a_]+$") then
        good = true
        seen[key] = true
        local on = null
        if plain(online) and online == true then
          on = now
        elseif plain(online) and online == false then
          local lok, y, m, d, h = pcall(env.last, i)
          if lok and plain(y) and (m == nil or plain(m)) and (d == nil or plain(d)) and (h == nil or plain(h)) then
            on = lastOn(now, y, m, d, h)
          end
        end
        local g = null
        if plain(guid) and type(guid) == "string" and #guid <= 40 and guid:find("^[%w%-]+$") then g = guid end
        members[#members + 1] = { name = shown, rank = rank, level = level, class = class:lower(), lastOn = on, guid = g }
        if rank == 0 then rank0 = true end
      end
    end
    if not good then clean = false end
  end
  if total == 0 and #members == 0 then clean = false end
  local whole = clean and #members == total and total >= 2 and rank0 and opts.settled == true
  -- An officer's whole report makes the server mark everyone it omits as left, so a roster that may be short is partial:
  -- one smaller than half the last whole report remembered (unless that is a week old), or where everyone listed is online
  -- (offline members are probably hidden by Show Offline Members).
  if whole and Report.shrunk(opts.held, count, now) then whole = false end
  if whole then
    local offline = false
    for _, m in ipairs(members) do
      if m.lastOn ~= null and m.lastOn ~= now then offline = true end
    end
    if not offline then whole = false end
  end
  if whole and total > 1 and type(numOnline) == "number" and plain(numOnline) and numOnline == total then whole = false end
  -- `by` must be one of the report's own members; a read that doesn't list this character is not kept.
  local _, by = cleanName(me, realm)
  if not by then return nil, "empty" end
  if not seen[by] then return nil, "not_listed" end
  return { at = now, by = by, whole = whole == true, count = count, members = members }
end

-- The game's own calls, each guarded: a missing or failing one gives nothing, never an error.
function Report.gameEnv()
  local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return unpack(r, 2, 20)
  end
  return {
    total = function() return call(GetNumGuildMembers) end, -- total, online
    realm = function() return call(GetNormalizedRealmName) end,
    -- 1 name, 3 rankIndex, 4 level, 9 isOnline, 11 classFileName, 17 guid
    row = function(i)
      local name, _, rank, level, _, _, _, _, online, _, class, _, _, _, _, _, guid = call(GetGuildRosterInfo, i)
      return name, rank, level, class, online, guid
    end,
    last = function(i) return call(GetGuildRosterLastOnline, i) end,
    secret = function(v)
      if type(issecretvalue) ~= "function" then return false end
      local ok, s = pcall(issecretvalue, v)
      return ok and s == true
    end,
  }
end

-- Whether `count` is under half the remembered whole report's count (`held` = { count, at }), which is under a week old.
function Report.shrunk(held, count, now)
  return type(held) == "table" and type(held.count) == "number" and type(held.at) == "number"
    and now - held.at <= 7 * DAY and count * 2 < held.count
end

-- The memory of the last whole report in the guild's saved data (g.wholeCount, g.wholeAt), or nil. Saved data from before
-- these fields falls back to the held report if that is whole.
function Report.memory(g)
  if type(g) ~= "table" then return nil end
  if type(g.wholeCount) == "number" and type(g.wholeAt) == "number" then return { count = g.wholeCount, at = g.wholeAt } end
  local r = g.report
  if type(r) == "table" and r.whole == true and type(r.count) == "number" and type(r.at) == "number" then
    return { count = r.count, at = r.at }
  end
  return nil
end

-- Whether a new read should replace the held report: never one under half the remembered whole count (while that is
-- under a week old), whatever its `whole` flag, and a partial one never replaces a whole one younger than KEEP_WHOLE.
function Report.better(old, new, mem)
  if mem == nil and type(old) == "table" and old.whole then mem = { count = old.count, at = old.at } end
  if Report.shrunk(mem, new.count, new.at) then return false end
  if type(old) ~= "table" then return true end
  if not new.whole and old.whole and new.at - (old.at or 0) < Report.KEEP_WHOLE then return false end
  return true
end

---------------------------------------------------------------------------------------------- the game

local state = { readAt = nil, askedAt = nil, waiting = false, deferred = false }
Report.state = state

local function wall()
  local ok, t = ns.try(time)
  return ok and type(t) == "number" and t or 0
end

-- Reads the roster now (no throttle) into the guild's table. `settled`: the roster is known to be one the game sent after
-- our request (only then can the report be whole). Returns the report, or nil and a reason.
function Report.read(env, settled)
  local st, Sync = ns.state, ns.Sync
  if not (st and st.db and not st.readOnly and Sync and ns.Receive) then return nil, "off" end
  local g = Sync.guild(true)
  if not g then return nil, "no_guild" end
  local now = wall()
  local mem = Report.memory(g)
  local ok, rep, why = pcall(Report.build, env or Report.gameEnv(), now, ns.Receive.myName(), { settled = settled == true, held = mem })
  if not ok then return nil, "error" end
  if not rep then return nil, why end
  state.readAt = now
  if Report.better(g.report, rep, mem) then
    g.report = rep
    if rep.whole then g.wholeAt, g.wholeCount = rep.at, rep.count end
    local mine = ns.Receive.myName()
    if type(mine) == "string" then g.by = { roster = rep.by, name = mine } end
  end
  return g.report
end

local function inCombat() return ns.closed(InCombatLockdown) end

-- Asks the game for a fresh roster, at most every MIN_ASK seconds; the read follows on GUILD_ROSTER_UPDATE, or after WAIT.
function Report.ask()
  local now = wall()
  if state.askedAt and now - state.askedAt < Report.MIN_ASK then return false end
  if type(C_GuildInfo) ~= "table" or type(C_GuildInfo.GuildRoster) ~= "function" then return false end
  if type(IsInGuild) == "function" then
    local ok, inGuild = ns.try(IsInGuild)
    if ok and not inGuild then return false end
  end
  state.askedAt, state.waiting, state.sawUpdate = now, true, false
  ns.try(C_GuildInfo.GuildRoster)
  if C_Timer and C_Timer.After then
    ns.try(C_Timer.After, Report.WAIT, function()
      if state.waiting then ns.try(Report.update, true) end
    end)
  end
  return true
end

-- A read, if one is due: not in combat (it waits for the end of it), and not more often than MIN_READ unless `force`.
function Report.update(force)
  if inCombat() then state.deferred = true; return end
  local now = wall()
  if not force and not state.waiting and state.readAt and now - state.readAt < Report.MIN_READ then return end
  -- Only a GUILD_ROSTER_UPDATE seen after our own request makes the roster settled (the handler sets sawUpdate); the
  -- startup update and the WAIT read, even one deferred by combat, do not.
  if state.sawUpdate then state.settled, state.sawUpdate = true, false end
  state.waiting, state.deferred = false, false
  Report.read(nil, state.settled == true)
end

-- At PLAYER_LOGOUT, before the export is built: whatever the game holds now, whole only if it settled earlier this session.
function Report.logout()
  Report.read(nil, state.settled == true)
end

local function login(n)
  local ok, name = ns.try(GetGuildInfo, "player")
  if not (ok and type(name) == "string" and name ~= "") then
    if n < 15 and C_Timer and C_Timer.After then ns.try(C_Timer.After, 2, function() login(n + 1) end) end
    return
  end
  Report.ask()
end

local frame = type(CreateFrame) == "function" and CreateFrame("Frame") or nil
if frame then
  frame:RegisterEvent("PLAYER_LOGIN")
  frame:RegisterEvent("GUILD_ROSTER_UPDATE")
  frame:RegisterEvent("PLAYER_REGEN_ENABLED")
  frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
      ns.try(login, 1)
    elseif event == "GUILD_ROSTER_UPDATE" then
      if state.waiting then state.sawUpdate = true end
      ns.try(Report.update, false)
    elseif state.deferred then
      ns.try(Report.update, false)
    end
  end)
end
if C_Timer and C_Timer.NewTicker then ns.try(C_Timer.NewTicker, Report.SLOW, function() ns.try(Report.ask) end) end

-- /tintean check: the report this character holds for its guild.
local baseCheck = ns.check
function ns.check()
  if baseCheck then ns.try(baseCheck) end
  for _, l in ipairs(Report.lines()) do ns.out(l) end
end

function Report.lines()
  local g = ns.Sync and ns.Sync.guild and ns.Sync.guild()
  local r = g and g.report
  if type(r) ~= "table" then return { ns.tag .. " roster report: none yet." } end
  local withGuid, offline = 0, 0
  for _, m in ipairs(r.members or {}) do
    if m.guid ~= nil and m.guid ~= null then withGuid = withGuid + 1 end
    if m.lastOn ~= nil and m.lastOn ~= null then offline = offline + 1 end
  end
  return { string.format("%s roster report: whole %s, %d of %d members, %d with a guid, %d with a last-online time, read %ds ago.",
    ns.tag, r.whole and "yes" or "no", #(r.members or {}), r.count or 0, withGuid, offline, math.max(0, wall() - (r.at or 0))) }
end

return Report
