-- Edits made here, as the character logged in (formats/game.md section 9; fixture game/relay.json).
-- Every function returns a status the screen can word: "sent", "kept", or "refused: <reason>".
--   sent: stored as my pending edit and queued to go to the guild.
--   kept: stored as my pending edit but nothing was queued (cannot send now, or the queue refused it); the
--         edit stays pending and goes out with the next exchange.
-- Reasons: note (a group's sign-up note over 120 letters), no_guild, not_on_roster, not_officer, forbidden (the author's name is not the roster's), not_held,
-- group_event, cancelled (an edit of a cancelled event other than a reopen), ended (a reopen after the end), already_seen, pending_create (a create the server has not taken yet cannot be
-- taken down), invalid, and the store's own word when it will not keep the edit (duplicate, lost).
-- An edit is made on what is held (base, prev), stored as my pending edit, and sent once in `chg`.
-- Warnings (needs_ack) are in Words.lua; the screens that call these are M20.14 on.
local _, ns = ...
ns = ns or {}

local Edit = {}
ns.Edit = Edit

local Json, Store, Validate, Sync, Checks = ns.Json, ns.Store, ns.Validate, ns.Sync, ns.Checks
local null = Json.null

local function wall()
  local ok, t = ns.try(time)
  return ok and type(t) == "number" and t or 0
end

local function refuse(reason) return "refused: " .. reason end

local function fold(s) return (tostring(s):gsub("%-", " ")) end

local function bodyOf(r)
  local b = r and r.body
  if type(b) == "table" and b ~= null then return b end
  return {}
end

-- The roster record of the character logged in, and the name as the roster gives it. When no held record matches but the
-- game's guild roster lists me, a stand-in: id is the roster key, body gives the name as the game does, no person handle
-- (`standIn` is true on it). Callers use `id` and `body` only.
function Edit.me(g)
  local mine = ns.Receive.myName()
  if type(mine) ~= "string" then return nil end
  for _, r in pairs(g.records) do
    local b = r.body
    if r.kind == "roster" and not r.deleted and type(b) == "table" and type(b.first) == "string" then
      local name = Checks.rosterName(b)
      if fold(name) == fold(mine) then return r, name end
    end
  end
  local key = ns.Ids.rosterKey(mine)
  if key:find(" ", 1, true) and Checks.gameRank(mine) ~= nil then
    return { kind = "roster", id = key, standIn = true, body = { first = mine } }, mine
  end
  return nil
end

-- The text for a pending edit of mine that lost to a guildmate's or the server's. `what` is the thing
-- that changed (an event's title, "the rank names"); a screen shows it with what is held now.
function Edit.loserText(what)
  return "Someone changed " .. tostring(what) .. " first. Here is what it says now."
end

-- A copy of the held body without what the server fills in (`created` and `by` stay), then `fields` laid over it (null clears a field).
local function merged(cur, fields)
  local out = {}
  for k, v in pairs(bodyOf(cur)) do
    if k ~= "counts" and k ~= "name" then out[k] = v end
  end
  for k, v in pairs(fields or {}) do out[k] = v end
  return out
end

local function live(r) return r ~= nil and not r.deleted end

local function ended(b, now)
  return type(b.starts) == "number" and b.starts + (type(b.minutes) == "number" and b.minutes or 0) * 60 < now
end

-- The edit itself. Returns "sent", "kept" or "refused: <reason>".
-- `group`: a sign-up on a group's event. It is kept in `mine` and never sent to guildmates (decisions.md M33.12, 11.3): the
-- desktop app (or the paste) takes it up from the export, and the server's own checks are the rules, so Checks.rules is skipped.
local function make(g, me, name, kind, id, body, deleted, ack, group)
  local now = wall()
  local cur = Store.currentIn(g, group, kind, id)
  local base, prev = 0, null
  local epoch, rebase = g.epoch or 0, nil
  if cur and cur.pending then
    base, prev = cur.base, cur.cid
    epoch, rebase = cur.epoch or 0, cur.rebase -- an edit on a pending edit inherits its epoch and rebase
    if base == 0 then -- still a create: README wants no prev, and a create cannot be a deletion
      if deleted then return refuse("pending_create") end
      prev = null
    end
    -- Two edits in one second: the later must still beat the earlier by the key, which breaks a tie by cid.
    if type(cur.at) == "number" and now <= cur.at then now = cur.at + 1 end
  elseif cur then
    base, prev = cur.rev, cur.cid
    if base == 0 then prev = null end -- the server's rev 0 (a sign-up with no head yet): taken as a create
  end
  local change = { cid = ns.Ids.cid(), id = id, kind = kind, base = base, prev = prev,
    author = { roster = me.id, name = name }, at = now, deleted = deleted, body = deleted and null or body, ack = ack,
    epoch = epoch }
  local res = Validate.check(change, now)
  if not res.ok then return refuse("invalid") end
  if name ~= Checks.rosterName(bodyOf(me)) then return refuse("forbidden") end
  local why = not group and Checks.rules(g, res.change, { now = now, rank = Checks.gameRank }) or nil
  if why == "forbidden" then
    return refuse((kind == "event" or kind == "bulletin" or kind == "ranks") and "not_officer" or "invalid")
  elseif why == "unknown_author" then
    return refuse("not_on_roster")
  elseif why then
    return refuse("invalid")
  end
  local opts = { own = true, counters = Sync.counters, rebase = rebase }
  local status = group and Store.applyMinePending(g, res.change, now, opts) or Store.applyPending(g, res.change, now, opts)
  if status ~= "stored" then return refuse(tostring(status)) end
  Sync.touch()
  if group then return "kept" end
  return Sync.sendOwn(g.pending[Store.slot(kind, id)]) and "sent" or "kept"
end

-- The guild and me, or a refusal.
local function start()
  local g = Sync.guild()
  if not g then return nil, nil, nil, refuse("no_guild") end
  local me, name = Edit.me(g)
  if not me then return nil, nil, nil, refuse("not_on_roster") end
  return g, me, name
end

-- A guild event I may act on: held, live and the guild's own. Returns the record or a refusal.
local function ownEvent(g, id, groupOk)
  local ev = Store.current(g, "event", id)
  if not live(ev) then return nil, refuse("not_held") end
  local grp = bodyOf(ev).group
  if grp ~= nil and grp ~= null and not groupOk then return nil, refuse("group_event") end
  return ev
end

Edit.GROUP_NOTE = 120

-- Sign up (or change a sign-up) as me. `extra`: role, note, and `ack` (the refs of warnings shown, Words.lua).
-- A group's event takes it only from a character `mine.may` lists, with a note of at most 120 letters ("refused: note").
function Edit.signUp(eventId, status, extra)
  local g, me, name, no = start()
  if no then return no end
  local ev, bad = ownEvent(g, eventId, Store.mayOf(g, eventId, me.id))
  if bad then return bad end
  local b = bodyOf(ev)
  local group = b.group ~= nil and b.group ~= null
  if group and type(extra) == "table" and type(extra.note) == "string" and ns.Text.letters(extra.note) > Edit.GROUP_NOTE then
    return refuse("note")
  end
  if b.cancelled == true then return refuse("cancelled") end
  if ended(b, wall()) then return refuse("ended") end
  local id = eventId .. ":" .. me.id
  local fields = { event = eventId, roster = me.id, status = status }
  local ack
  for k, v in pairs(extra or {}) do
    if k == "ack" then ack = (type(v) == "table" and #v > 0) and v or nil else fields[k] = v end
  end
  -- A held "<event>:c:<character>" sign-up is for a member with no roster row (README); I have one, so it is
  -- someone else's record and is not looked for here.
  local cur = Store.currentIn(g, group, "signup", id)
  local body = merged(live(cur) and cur or nil, fields)
  if body.note == nil then body.note = null end -- README: the sign-up's fields are always all there
  return make(g, me, name, "signup", id, body, false, ack, group)
end

-- Mark a bulletin seen, as me (a create only: once seen, it stays).
function Edit.seen(bulletinId)
  local g, me, name, no = start()
  if no then return no end
  if not live(Store.current(g, "bulletin", bulletinId)) then return refuse("not_held") end
  local id = bulletinId .. ":" .. me.id
  if live(Store.current(g, "seen", id)) then return refuse("already_seen") end
  -- The server holds a person's seen as "<bulletin>:p:<handle>" once the roster row has a person (README):
  -- the same fact as mine, so it counts.
  local person = bodyOf(me).person
  if type(person) == "string" and live(Store.current(g, "seen", bulletinId .. ":p:" .. person)) then
    return refuse("already_seen")
  end
  return make(g, me, name, "seen", id, { bulletin = bulletinId, roster = me.id }, false)
end

-- Create an event: `fields` gives title, activity, starts and minutes (README), and any others. Returns the status and the id.
function Edit.createEvent(fields)
  local g, me, name, no = start()
  if no then return no end
  local id = ns.Ids.uuid()
  return make(g, me, name, "event", id, merged(nil, fields), false), id
end

-- Change some fields of an event (null clears one).
function Edit.editEvent(id, fields)
  local g, me, name, no = start()
  if no then return no end
  local ev, bad = ownEvent(g, id)
  if bad then return bad end
  if bodyOf(ev).cancelled == true then
    -- A held cancelled event takes only a reopen (README, Cancelling and reopening): {cancelled = false} and nothing else,
    -- and not after the event would have ended (by this clock; the server's decides in the end).
    local only = type(fields) == "table" and fields.cancelled == false
    for k in pairs(fields or {}) do if k ~= "cancelled" then only = false end end
    if not only then return refuse("cancelled") end
    local b = bodyOf(ev)
    -- `<=` is deliberate: the server reopens only while now < starts + duration, so at the end second it refuses (invalid,
    -- body.cancelled). Do not change it to `<`.
    if type(b.starts) == "number" and b.starts + (type(b.minutes) == "number" and b.minutes or 0) * 60 <= wall() then
      return refuse("ended")
    end
  end
  return make(g, me, name, "event", id, merged(ev, fields), false)
end

function Edit.cancelEvent(id) return Edit.editEvent(id, { cancelled = true }) end

-- Reopen sends the whole held body with `cancelled = false`, on top of the cancelling edit. Undo (just cancelled, not yet
-- pulled) is the same edit: a new one on the cancelling one, never a deletion of it.
function Edit.reopenEvent(id) return Edit.editEvent(id, { cancelled = false }) end
Edit.undoCancel = Edit.reopenEvent

-- The game has no way to delete an event: the site does that (a cancelled event only).

function Edit.createBulletin(fields)
  local g, me, name, no = start()
  if no then return no end
  local id = ns.Ids.uuid()
  return make(g, me, name, "bulletin", id, merged(nil, fields), false), id
end

function Edit.editBulletin(id, fields)
  local g, me, name, no = start()
  if no then return no end
  local b = Store.current(g, "bulletin", id)
  if not live(b) then return refuse("not_held") end
  return make(g, me, name, "bulletin", id, merged(b, fields), false)
end

function Edit.takeDownBulletin(id)
  local g, me, name, no = start()
  if no then return no end
  if not live(Store.current(g, "bulletin", id)) then return refuse("not_held") end
  return make(g, me, name, "bulletin", id, nil, true)
end

---------------------------------------------------------------------------------------------- rank names

-- The game's rank names in rank order (nil where the game gives none), or nil when it cannot say.
local function gameRanks()
  local ok, n = ns.try(GuildControlGetNumRanks)
  if not ok or type(n) ~= "number" or n < 1 then return nil end
  local names = {}
  for i = 1, math.min(n, 10) do
    local ok2, s = ns.try(GuildControlGetRankName, i)
    if ok2 and type(s) == "string" then
      local secret, v = ns.try(issecretvalue, s)
      if not (secret and v == true) and s ~= "" then names[i] = s end
    end
  end
  return names, math.min(n, 10)
end

-- One edit with `names` when the game's differ from what is held (or pending). Returns the status, or nil
-- when nothing needed saying.
function Edit.syncRanks()
  local g, me, name, no = start()
  if no then return no end
  local names, n = gameRanks()
  if not names then return nil end
  local held = bodyOf(Store.current(g, "ranks", "ranks")).names
  local differ = false
  local out = {}
  for i = 1, n do
    local h = type(held) == "table" and held[i] or nil
    if h == null then h = nil end
    out[i] = names[i] == nil and null or names[i]
    if names[i] ~= nil and names[i] ~= h then differ = true end
  end
  if not differ then return nil end
  return make(g, me, name, "ranks", "ranks", { names = Json.array(out) }, false)
end

Edit.RANKS_DELAY = 60
Edit.ranksDone = false

-- Once per session, for an officer: not an officer's addon makes no edit (and says nothing). It waits until the
-- guild, my roster record and the game's rank count are all there, trying again 30 s apart a few times.
Edit.RANKS_RETRY, Edit.RANKS_TRIES = 30, 4

function Edit.ranksOnce(attempt)
  if Edit.ranksDone then return nil end
  local g = Sync.guild()
  if not g or not Edit.me(g) or not gameRanks() then
    attempt = (attempt or 1)
    if attempt < Edit.RANKS_TRIES and C_Timer and C_Timer.After then
      ns.try(C_Timer.After, Edit.RANKS_RETRY, function() ns.try(Edit.ranksOnce, attempt + 1) end)
    end
    return nil
  end
  Edit.ranksDone = true
  local status = Edit.syncRanks()
  if status == refuse("not_officer") then return nil end
  return status
end

local frame = type(CreateFrame) == "function" and CreateFrame("Frame") or nil
if frame then
  frame:RegisterEvent("PLAYER_LOGIN")
  frame:SetScript("OnEvent", function()
    if C_Timer and C_Timer.After then
      ns.try(C_Timer.After, Edit.RANKS_DELAY, function() ns.try(Edit.ranksOnce) end)
    end
  end)
end

return Edit
