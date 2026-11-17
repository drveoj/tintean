-- The events that become moments (formats/moments/README.md section 3; docs/research/skald.md for which events the game
-- gives). Every moment goes through Party.note, so nothing is noted solo or with the switch off. Each event is registered on
-- its own inside pcall: one the client lacks is listed (`Events.missing`) and its kind is never noted. Handlers only record:
-- values the game flags secret are dropped, scans (skills, reputation) do not run in combat, nothing runs per frame, and
-- during a boss encounter moments are held (with their own time and place) and noted when it ends.
local _, ns = ...
ns = ns or {}
ns.Moments = ns.Moments or {}

local Clock, Store, Party = ns.Moments.Clock, ns.Moments.Store, ns.Moments.Party
local Ids = ns.Ids

local Events = {}
ns.Moments.Events = Events

Events.missing = {}   -- events the client would not register
Events.noted = {}     -- kind -> moments noted this session
Events.skipped = {}   -- why -> moments not noted this session (alone, off, night_soft, secret, ...)
Events.QUEUE_MAX = 60

local state = { enc = nil, queue = {}, dead = false, offer = nil, inst = nil, skills = nil, factions = nil, scanned = 0, skillScanned = 0, noted = nil,
  taxi = false, lastKill = nil }
Events.state = state

local H = {}
Events.handlers = H

local function call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local r = { pcall(fn, ...) }
  if not r[1] then return nil end
  return unpack(r, 2, 20)
end

local function num(v) return type(v) == "number" and Clock.plain(v) and v or nil end
local function str(v) return type(v) == "string" and Clock.plain(v) and Store.text(v) or nil end

local function tally(t, k) t[k] = (t[k] or 0) + 1 end
local function result(kind, seq, why)
  if seq then tally(Events.noted, kind) else tally(Events.skipped, why or "unknown") end
  return seq
end

-- Notes a moment now, or holds it while a boss encounter is open. `lvl` overrides the level read.
function Events.emit(kind, what, lvl)
  if not (Party.enabled() and Party.state.active) then return result(kind, nil, "alone") end
  if state.enc then
    if #state.queue >= Events.QUEUE_MAX then return result(kind, nil, "queue_full") end
    state.queue[#state.queue + 1] = { kind = kind, what = what, snap = Party.snapshot(lvl) }
    return nil
  end
  local seq, why = Party.note(kind, what, lvl and Party.snapshot(lvl) or nil)
  return result(kind, seq, why)
end

local function flush()
  local q = state.queue
  state.queue = {}
  for _, m in ipairs(q) do result(m.kind, Party.note(m.kind, m.what, m.snap)) end
end

local function selfKey() return (select(2, Party.where())) end

-- A name the game gave -> the roster key of that member of the party, or nil and the name to show.
local function who(name)
  local shown = str(name)
  if not shown then return nil, nil end
  local r = Ids.rosterKey(shown)
  for _, k in ipairs(Party.state.keys or {}) do
    if k == r or k:sub(1, #r + 1) == r .. " " then return k end -- the game may give the first name only
  end
  return nil, shown
end

local function inCombat() return ns.closed(InCombatLockdown) end

---------------------------------------------------------------------------------------------- the person

function H.PLAYER_LEVEL_UP(level)
  level = num(level)
  if level then Events.emit("level", { level = level }, level) end
end

local function questWhat(id)
  id = num(id)
  if not id then return nil end
  local line
  if type(C_QuestLine) == "table" then
    local info = call(C_QuestLine.GetQuestLineInfo, id)
    if type(info) == "table" then
      local lid, lname = num(info.questLineID), str(info.questLineName)
      if lid and lname then line = { id = lid, name = lname } end
    end
  end
  return { quest = id, title = type(C_QuestLog) == "table" and str(call(C_QuestLog.GetTitleForQuestID, id)) or nil, line = line }
end

-- Mainline gives the quest id; the older shape gives the log index first.
function H.QUEST_ACCEPTED(a, b)
  local what = questWhat(num(b) or a)
  if what then Events.emit("quest_accepted", what) end
end

function H.QUEST_TURNED_IN(id)
  local what = questWhat(id)
  if what then Events.emit("quest_done", what) end
end

function H.PLAYER_DEAD()
  state.dead, state.offer = true, nil
  Events.emit("death", {})
end

Events.REVIVE_WAIT = 0.5

-- A resurrection offered (while dead) in the last minute is the one accepted when the player comes back to life.
local function finishRevive()
  local how = state.how
  state.reviving, state.how = false, nil
  if not state.dead then return end
  state.dead = false
  local offer, at = state.offer, Clock.now()
  state.offer = nil
  if offer and at and at - offer.at <= 60 then
    how = "res"
    Events.emit("res", { from = offer.key, to = selfKey(), other = offer.other })
  end
  Events.emit("revive", { how = how })
end

-- PLAYER_ALIVE and PLAYER_UNGHOST may come in either order for a corpse run, so the first waits a moment for the
-- other; "corpse" wins over "spirit".
local function revived(how)
  if not state.dead then return end
  if state.reviving then
    if how == "corpse" then state.how = "corpse" end
    return
  end
  state.reviving, state.how = true, how
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    if not ns.try(C_Timer.After, Events.REVIVE_WAIT, function() ns.try(finishRevive) end) then finishRevive() end
  else
    finishRevive()
  end
end

function H.PLAYER_UNGHOST() revived("corpse") end

-- PLAYER_ALIVE also fires on the way to a ghost; only a living player has come back.
function H.PLAYER_ALIVE()
  if call(UnitIsDeadOrGhost, "player") ~= false then return end
  revived("spirit")
end

function H.RESURRECT_REQUEST(name)
  local at = Clock.now()
  if not at or not state.dead then return end
  local key, shown = who(name)
  state.offer = { at = at, key = key, other = shown }
end

-- Resurrection spells by id (Resurrection, Redemption, Ancestral Spirit, Revive, Rebirth, Raise Ally): the ones this
-- client turns out to have are for the in-game check to show. Reads the target's name only out of combat.
Events.RES_SPELLS = { [2006] = true, [7328] = true, [2008] = true, [50769] = true, [20484] = true, [61999] = true }

function H.UNIT_SPELLCAST_SUCCEEDED(unit, _, spell)
  if unit ~= "player" or not Events.RES_SPELLS[num(spell)] then return end
  if inCombat() or call(UnitIsPlayer, "target") ~= true then return end
  local key, shown = who(call(GetUnitName, "target", true))
  if not (key or shown) then return end -- no one readable to name: nothing is noted
  Events.emit("res", { from = selfKey(), to = key, other = shown })
end

---------------------------------------------------------------------------------------------- places

-- A running count per zones table (counted once, then kept), so the cap costs nothing on the common path. When over the
-- cap, arbitrary old keys go, never the ones for the place the player is in.
local counts = setmetatable({}, { __mode = "k" })
local function remember(zones, key, keep1, keep2)
  if zones[key] then return end
  if not counts[zones] then
    local n = 0
    for _ in pairs(zones) do n = n + 1 end
    counts[zones] = n
  end
  zones[key] = true
  counts[zones] = counts[zones] + 1
  if counts[zones] <= Store.ZONES_CAP then return end
  for k in pairs(zones) do
    if counts[zones] <= Store.ZONES_CAP then break end
    if k ~= keep1 and k ~= keep2 then
      zones[k] = nil
      counts[zones] = counts[zones] - 1
    end
  end
end

-- The first time this character is in a zone or subzone while grouped (what it is grouped for is remembered, so a
-- place seen alone is still new the first time it is seen in a group).
local function zoneCheck()
  if not (Party.enabled() and Party.state.active) then return end
  local gkey, ckey = Party.where()
  if not gkey then return end
  local s = Party.snapshot()
  local base = s.map or s.zone
  if not base then return end
  local e = Store.entry(ns.state.db, gkey, ckey, true)
  local zk, sk = "z:" .. base, s.sub and ("s:" .. base .. ":" .. s.sub) or nil
  local first
  if not e.zones[zk] then
    first = "zone"
  elseif sk and not e.zones[sk] then
    first = "sub"
  end
  if not first then return end
  remember(e.zones, zk, zk, sk)
  if sk then remember(e.zones, sk, zk, sk) end
  Events.emit("zone", { first = first })
end

-- The instance the player is in is noted once, as soon as a party is in effect (also when the party began after the
-- player went in). A reload inside one, or going in alone, is not an entry; `noted` is the instance a dungeon was noted for.
function Events.noteDungeon()
  local i = state.inst
  if not i or state.noted == i.id or not (Party.enabled() and Party.state.active) then return end
  state.noted = i.id
  Events.emit("dungeon", { inst = i.id, name = i.name, type = i.type, diff = i.diff })
end

local function instanceCheck(reload)
  local name, itype, diff, _, _, _, _, id = call(GetInstanceInfo)
  itype, id = str(itype), num(id)
  local here = id and ({ party = 1, raid = 1, pvp = 1, arena = 1, scenario = 1 })[itype] and id or nil
  local was = state.inst
  if here ~= (was and was.id) then
    state.inst = here and { id = here, name = str(name), type = itype, diff = num(diff) } or nil
    if was and state.noted == was.id then
      state.noted = nil
      Events.emit("dungeon_left", { inst = was.id })
    end
    if here and reload then state.noted = here end
  end
  Events.noteDungeon()
end

function H.PLAYER_ENTERING_WORLD(initial, reload)
  if state.enc then state.enc = nil; flush() end -- an encounter cannot outlive a loading screen
  instanceCheck(initial == true or reload == true)
  zoneCheck()
end
H.ZONE_CHANGED_NEW_AREA, H.ZONE_CHANGED, H.ZONE_CHANGED_INDOORS = zoneCheck, zoneCheck, zoneCheck

function H.HEARTHSTONE_BOUND()
  local place = str(call(GetBindLocation))
  if place then Events.emit("hearth", { place = place }) end
end

-- Landing from a taxi: control is lost with the taxi flag a moment later, and comes back on landing.
function H.PLAYER_CONTROL_LOST()
  local function check() if call(UnitOnTaxi, "player") == true then state.taxi = true end end
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then ns.try(C_Timer.After, 1, check) else check() end
end

function H.PLAYER_CONTROL_GAINED()
  if not state.taxi or call(UnitOnTaxi, "player") == true then return end
  state.taxi = false
  local gkey, ckey = Party.where()
  local e = gkey and Store.entry(ns.state.db, gkey, ckey, true)
  if not e then return end
  local first = not e.flown
  if Events.emit("flight", { first = first }) then e.flown = true end
end

---------------------------------------------------------------------------------------------- things earned

function H.ACHIEVEMENT_EARNED(id, already)
  id = num(id)
  if not id or already == true then return end
  local name = str(select(2, call(GetAchievementInfo, id)) or nil)
  Events.emit("achievement", { id = id, name = name })
end

function H.NEW_MOUNT_ADDED(id)
  id = num(id)
  if not id or type(C_MountJournal) ~= "table" then return end
  Events.emit("mount", { id = id, name = str(call(C_MountJournal.GetMountInfoByID, id)) })
end

function H.NEW_PET_ADDED(guid)
  if type(C_PetJournal) ~= "table" or not Clock.plain(guid) then return end
  local species, _, _, _, _, _, _, name = call(C_PetJournal.GetPetInfoByPetID, guid)
  species = num(species)
  if species then Events.emit("pet", { id = species, name = str(name) }) end
end

-- Item links in loot lines: own loot of quality 3 (rare) and above, everywhere.
function H.CHAT_MSG_LOOT(text, _, _, _, _, _, _, _, _, _, _, guid)
  if not (Clock.plain(text) and type(text) == "string") then return tally(Events.skipped, "secret") end
  if not Clock.plain(guid) or guid == nil or guid ~= call(UnitGUID, "player") then return end
  local link = text:match("|Hitem:[^|]+|h%[.-%]|h")
  local id = link and tonumber(link:match("|Hitem:(%d+)"))
  if not id then return end
  local q = num(call(C_Item and C_Item.GetItemQualityByID, id)) or num(select(3, call(GetItemInfo, link)) or nil)
  if not q or q < 3 then return end
  Events.emit("loot", { item = id, name = str(link:match("%[(.-)%]")), q = math.min(q, 7), n = tonumber(text:match("x(%d+)%.?$")) or 1 })
end

-- Profession and skill ranks, by the older skill-line calls where the client has them: a rank reaching a multiple of
-- 25 or its maximum. The first read only remembers. Never in combat.
-- True when a scan may run now (and marks it); a switch that is off clears the baselines.
local function mayScan(field)
  if not Party.enabled() then
    state.skills, state.factions = nil, nil
    return false
  end
  local at = call(GetTime)
  if inCombat() or not num(at) or at - state[field] < 5 then return false end
  state[field] = at
  return true
end

function H.SKILL_LINES_CHANGED()
  if type(GetNumSkillLines) ~= "function" or not mayScan("skillScanned") then return end
  local n = num(call(GetNumSkillLines))
  if not n then return end
  local now, seen = {}, state.skills
  for i = 1, math.min(n, 80) do
    local name, header, _, rank, _, _, max = call(GetSkillLineInfo, i)
    name, rank, max = str(name), num(rank), num(max)
    if name and header ~= true and rank and max and max > 0 then
      now[name] = rank
      local was = seen and seen[name]
      if was and rank > was and (rank == max or math.floor(rank / 25) > math.floor(was / 25)) then
        Events.emit("skill", { name = name, rank = rank, max = max })
      end
    end
  end
  state.skills = now
end

-- Reputation: a faction's standing going up a level, not every point. Both the classic and the newer call shapes.
local function factionAt(i)
  if type(C_Reputation) == "table" and type(C_Reputation.GetFactionDataByIndex) == "function" then
    local d = call(C_Reputation.GetFactionDataByIndex, i)
    if type(d) == "table" then return str(d.name), num(d.factionID), num(d.reaction) end
    return nil
  end
  local name, _, standing, _, _, _, _, _, header, _, hasRep, _, _, id = call(GetFactionInfo, i)
  if header == true and hasRep ~= true then return nil end
  return str(name), num(id), num(standing)
end

function H.UPDATE_FACTION()
  if not mayScan("scanned") then return end
  local n = num(call(type(C_Reputation) == "table" and C_Reputation.GetNumFactions or GetNumFactions))
  if not n then return end
  local now, seen = {}, state.factions
  for i = 1, math.min(n, 150) do
    local name, id, standing = factionAt(i)
    if name and id and standing then
      now[id] = standing
      if seen and seen[id] and standing > seen[id] then
        Events.emit("rep", { id = id, faction = name, standing = math.min(standing, 8) })
      end
    end
  end
  state.factions = now
end

-- A battleground ending: the winning side is 0 (Horde) or 1 (Alliance).
function H.PVP_MATCH_COMPLETE(winner)
  local mine = call(UnitFactionGroup, "player")
  winner = num(winner)
  local outcome
  if winner and Clock.plain(mine) then
    outcome = (({ Horde = 0, Alliance = 1 })[mine] == winner) and "win" or "loss"
  end
  local name = str(call(GetRealZoneText))
  if name then Events.emit("bg", { name = name, result = outcome }) end
end

---------------------------------------------------------------------------------------------- bosses

-- Pulls of this boss and difficulty in the local night held (this one is not yet counted).
local function pullsBefore(enc, diff)
  local gkey, ckey = Party.where()
  local e = gkey and Store.entry(ns.state.db, gkey, ckey)
  if not e then return 0 end
  local spans = Store.nights(e.list)
  local last, n = spans[#spans], 0
  for i = last and last.from or 1, last and last.to or 0 do
    local m = e.list[i]
    if m.kind == "boss_pull" and m.what.enc == enc and m.what.diff == diff then n = n + 1 end
  end
  return n
end

local function groupSize(v) return num(v) or num(call(GetNumGroupMembers)) end

function H.ENCOUNTER_START(enc, name, diff, size)
  enc, diff = num(enc), num(diff)
  if not (enc and diff) then return tally(Events.skipped, "secret") end
  local what = { enc = enc, name = str(name), diff = diff, size = groupSize(size) }
  local tries = pullsBefore(enc, diff) + 1
  state.enc = what
  what = { enc = enc, name = what.name, diff = diff, size = what.size, try = tries }
  Events.emit("boss_pull", what)
end

function H.ENCOUNTER_END(enc, name, diff, size, success)
  enc, diff = num(enc), num(diff)
  local ok = num(success)
  if enc and diff and ok then
    local what = { enc = enc, name = str(name), diff = diff, size = groupSize(size) }
    if ok == 1 then state.lastKill = { enc = enc, at = Clock.now() } end
    Events.emit(ok == 1 and "boss_kill" or "boss_wipe", what)
  else
    tally(Events.skipped, "secret")
  end
  state.enc = nil
  flush()
end

-- A kill with no encounter open (and not just seen by ENCOUNTER_END) is noted here.
function H.BOSS_KILL(enc, name)
  enc = num(enc)
  if not enc or state.enc then return end
  local at, last = Clock.now(), state.lastKill
  if last and last.enc == enc and at and last.at and at - last.at < 60 then return end
  local _, _, diff = call(GetInstanceInfo)
  diff = num(diff)
  if not diff then return end
  Events.emit("boss_kill", { enc = enc, name = str(name), diff = diff, size = groupSize() })
end

---------------------------------------------------------------------------------------------- registering

-- Registers each event on its own; an event the frame will not take is listed in Events.missing.
function Events.register(frame, list)
  for _, e in ipairs(list) do
    if not pcall(frame.RegisterEvent, frame, e) then Events.missing[#Events.missing + 1] = e end
  end
end

Events.LIST = {
  "PLAYER_LEVEL_UP", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "PLAYER_DEAD", "PLAYER_UNGHOST", "PLAYER_ALIVE",
  "RESURRECT_REQUEST", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
  "HEARTHSTONE_BOUND", "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED", "ACHIEVEMENT_EARNED", "NEW_MOUNT_ADDED",
  "NEW_PET_ADDED","CHAT_MSG_LOOT", "SKILL_LINES_CHANGED", "UPDATE_FACTION", "PVP_MATCH_COMPLETE",
  "ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL",
}

function Events.dispatch(event, ...)
  local h = H[event]
  if h then ns.try(h, ...) end
end

local frame = type(CreateFrame) == "function" and CreateFrame("Frame") or nil
if frame then
  Events.register(frame, Events.LIST)
  -- Only the player's own casts, asked for as such so the game does not call this for other units.
  if not (type(frame.RegisterUnitEvent) == "function" and pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_SUCCEEDED", "player")) then
    Events.missing[#Events.missing + 1] = "UNIT_SPELLCAST_SUCCEEDED"
  end
  frame:SetScript("OnEvent", function(_, event, ...) Events.dispatch(event, ...) end)
end

---------------------------------------------------------------------------------------------- /tintean check

local function sorted(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

function Events.lines()
  local out = {}
  local held = {}
  for _, g in pairs(ns.state and ns.state.db and type(ns.state.db.moments) == "table" and ns.state.db.moments or {}) do
    for _, e in pairs(type(g) == "table" and g or {}) do
      for _, m in ipairs(type(e) == "table" and type(e.list) == "table" and e.list or {}) do held[m.kind] = (held[m.kind] or 0) + 1 end
    end
  end
  local function join(t)
    local parts = {}
    for _, k in ipairs(sorted(t)) do parts[#parts + 1] = k .. " " .. t[k] end
    return #parts > 0 and table.concat(parts, ", ") or "none"
  end
  out[#out + 1] = ns.tag .. " moments held by kind: " .. join(held) .. "."
  out[#out + 1] = ns.tag .. " moments noted this session: " .. join(Events.noted) .. "."
  out[#out + 1] = ns.tag .. " moments not noted this session: " .. join(Events.skipped) .. "."
  out[#out + 1] = ns.tag .. " events the client lacked: " .. (#Events.missing > 0 and table.concat(Events.missing, ", ") or "none") .. "."
  return out
end

local baseCheck = ns.check
function ns.check()
  if baseCheck then ns.try(baseCheck) end
  for _, l in ipairs(Events.lines()) do ns.out(l) end
end

return Events
