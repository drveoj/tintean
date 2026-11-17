-- Local checks on an edit received from a guildmate (formats/game.md section 8; fixture game/relay.json).
-- Checks.run(guild, raw, ctx) -> { ok = true, change, unchecked } or { ok = false, reason }.
--   ctx.now   the clock in epoch seconds;   ctx.rank(name) -> the game roster's rank index for a name, or nil.
-- Reasons: unknown_kind, invalid, unknown_author, forbidden. (`flood` is the caller's: it needs the sender.)
-- Pure apart from Checks.gameRank, which reads the game's roster. Impersonation is the accepted trust model
-- (decisions.md, M19.10): these checks say what the game can say, not who really sent the edit.
local _, ns = ...
ns = ns or {}

local Checks = {}
ns.Checks = Checks

local Json, Validate = ns.Json, ns.Validate
local null = Json.null

local function live(r) return r ~= nil and not r.deleted end

local function anyLive(guild, kind)
  for _, r in pairs(guild.records) do
    if r.kind == kind and not r.deleted then return true end
  end
  return false
end

local function bodyOf(r)
  local b = r and r.body
  if type(b) == "table" and b ~= null then return b end
  return {}
end

-- Officer: the game's rank for the name, by my `ranks` record (or any roster record of that rank that says officer),
-- else the author's own roster record. Rank 0 always counts.
local function officer(guild, name, roster, ctx)
  local idx = ctx.rank and ctx.rank(name) or nil
  if idx ~= nil then
    -- The game's rank is known: it decides (the roster record's flag is only for when the game cannot say).
    if idx == 0 then return true end
    local ranks = guild.records["ranks|ranks"]
    local flags = live(ranks) and bodyOf(ranks).officer
    if type(flags) == "table" and flags[idx + 1] == true then return true end
    for _, r in pairs(guild.records) do
      if r ~= roster and r.kind == "roster" and not r.deleted and bodyOf(r).rank == idx and bodyOf(r).officer == true then return true end
    end
    return false
  end
  return bodyOf(roster).officer == true
end

-- Rules 2 to 5 on a change that has passed its shape check. Returns nil (fine), or a reason; the second result is
-- true when the edit could not be judged yet (no roster, or no event held at all) and is kept, marked unchecked.
-- The name a roster record gives its character: first, then second when it has one.
function Checks.rosterName(b)
  return b.first .. (type(b.second) == "string" and (" " .. b.second) or "")
end

function Checks.rules(guild, c, ctx)
  local kind, unchecked = c.kind, false
  if kind == "roster" then return "forbidden" end -- the roster comes from Blizzard (the server says read_only)
  -- 2. The author is a live roster record I hold, or a character the game's guild roster lists (under that name's key).
  local roster = guild.records["roster|" .. c.author.roster]
  if not live(roster) then
    local listed = ctx.rank and ns.Ids.rosterKey(c.author.name) == c.author.roster and ctx.rank(c.author.name) ~= nil
    if listed then
      roster = nil
    elseif anyLive(guild, "roster") then
      return "unknown_author"
    else
      unchecked = true
    end
  end
  -- The name that counts is the roster record's, not the one the edit gives for itself.
  local name = c.author.name
  if live(roster) then
    local b = bodyOf(roster)
    if type(b.first) == "string" then name = Checks.rosterName(b) end
    if name ~= c.author.name then return "forbidden" end
  end
  -- 3. Events, bulletins and rank names: an officer.
  if (kind == "event" or kind == "bulletin" or kind == "ranks") and not unchecked and not officer(guild, name, roster, ctx) then
    return "forbidden"
  end
  -- 4. Sign-ups and seen: as themself.
  if (kind == "signup" or kind == "seen") then
    local _, who = Validate.splitSignupId(c.id)
    if who ~= c.author.roster then return "forbidden" end
  end
  -- 5. Targets.
  if kind == "event" then
    local held = guild.records["event|" .. c.id]
    if (c.body ~= null and bodyOf(c).group ~= nil and bodyOf(c).group ~= null) or (live(held) and bodyOf(held).group ~= nil and bodyOf(held).group ~= null) then
      return "invalid"
    end
  elseif kind == "signup" then
    local event = Validate.splitSignupId(c.id)
    local ev = guild.records["event|" .. event]
    if ev == nil then
      if anyLive(guild, "event") then return "invalid" end
      return nil, true
    end
    local b = bodyOf(ev)
    if ev.deleted or (b.group ~= nil and b.group ~= null) then return "invalid" end
    if not c.deleted and (b.cancelled == true or (type(b.starts) == "number" and b.starts + (b.minutes or 0) * 60 < ctx.now)) then
      return "invalid"
    end
  elseif kind == "seen" then
    local bulletin = Validate.splitSignupId(c.id)
    -- A bulletin held only as a pending create (an officer's own, not yet taken by the server) counts as held.
    if not live(guild.records["bulletin|" .. bulletin]) and not live(guild.pending and guild.pending["bulletin|" .. bulletin]) then
      return "invalid"
    end
  end
  return nil, unchecked
end

function Checks.run(guild, raw, ctx)
  local res = Validate.check(raw, ctx.now)
  if res.skip then return { ok = false, reason = "unknown_kind" } end
  if not res.ok then return { ok = false, reason = "invalid" } end
  local reason, unchecked = Checks.rules(guild, res.change, ctx)
  if reason then return { ok = false, reason = reason } end
  return { ok = true, change = res.change, unchecked = unchecked }
end

---------------------------------------------------------------------------------------------- the game's roster

local function plain(v)
  local ok, s = ns.try(issecretvalue, v)
  return not (ok and s == true)
end

local function fold(s) return (s:gsub("%-", " ")) end

local cache, cacheAt = nil, -1e9
Checks.CACHE = 30 -- seconds: the roster is read at most this often (a full guild is a thousand calls)

-- The game roster's rank index (0 is the guild master) for a character, or nil. Names compare as the game gives
-- them ("First Surname"), with a hyphen and a space treated alike.
function Checks.gameRank(name)
  if type(name) ~= "string" then return nil end
  local okT, t = ns.try(GetTime)
  t = okT and type(t) == "number" and t or 0
  if not cache or t - cacheAt >= Checks.CACHE then
    cache, cacheAt = {}, t
    local ok, total = ns.try(GetNumGuildMembers)
    if ok and type(total) == "number" and plain(total) then
      for i = 1, math.min(total, 1000) do
        local ok2, n, _, idx = ns.try(GetGuildRosterInfo, i)
        if ok2 and type(n) == "string" and type(idx) == "number" and plain(n) and plain(idx) then
          cache[n], cache[fold(n)] = idx, idx
        end
      end
    end
  end
  return cache[name] or cache[fold(name)]
end

-- Forget the roster read (a guild change, and the specs).
function Checks.forget() cache, cacheAt = nil, -1e9 end

return Checks
