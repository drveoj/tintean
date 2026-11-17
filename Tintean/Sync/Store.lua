-- One guild's held records, pending edits and settled cids (formats/game.md sections 7 and 11).
-- A guild is the table SavedVariables keeps: records["kind|id"], pending["kind|id"], settled[cid] = time,
-- cursor, floor and top per kind. Pure: callers pass `now` and a counters table; nothing here reads
-- the clock or the game. Versions are compared only by Order's key.
local _, ns = ...
ns = ns or {}

local Store = {}
ns.Store = Store

local Json, Order = ns.Json, ns.Order
local null = Json.null

Store.KINDS = { "event", "signup", "bulletin", "roster", "ranks" }
Store.CAPS = { records = 5000, pending = 300, settled = 2000, guilds = 8, days = 30, tombstoneDays = 14 }
local DAY = 86400

local function bump(counters, name, n)
  if counters then counters[name] = (counters[name] or 0) + (n or 1) end
end

local function zeroCursor()
  local c = {}
  for _, k in ipairs(Store.KINDS) do c[k] = 0 end
  return c
end

-- `now` stamps lastOn so a guild just made is never the "least recently logged in".
function Store.new(name, now)
  return { name = name, lastOn = now or 0, epoch = 0, cursor = zeroCursor(), floor = {}, top = {}, records = {}, pending = {}, settled = {} }
end

function Store.slot(kind, id) return kind .. "|" .. id end

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end
Store.count = count

-- Whether a pending edit beats a server version (it wins only on the key).
local function pendingBeats(p, r)
  return Order.compare(Order.pendingKey(p), Order.serverKey(r)) > 0
end

-- The version shown for a record: the held pending edit if it beats the server version, else the server version.
function Store.current(guild, kind, id)
  local slot = Store.slot(kind, id)
  local r, p = guild.records[slot], guild.pending[slot]
  if r and p then return pendingBeats(p, r) and p or r end
  return p or r
end

local function oldest(map, n, stampOf)
  local list = {}
  for k, v in pairs(map) do list[#list + 1] = { k = k, t = stampOf(v) or 0 } end
  table.sort(list, function(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return Order.compareBytes(a.k, b.k) < 0
  end)
  local out = {}
  for i = 1, n do out[i] = list[i].k end
  return out
end

-- Drops the oldest over `cap`, counts them, returns the dropped keys (or nil).
local function capBy(map, cap, stampOf, counters, counter)
  local over = count(map) - cap
  if over <= 0 then return nil end
  local gone = oldest(map, over, stampOf)
  for _, k in ipairs(gone) do map[k] = nil end
  bump(counters, counter, over)
  return gone
end

local function got(v) return v.got end
local function identity(t) return t end

-- The two small caps, applied wherever something is added.
local function capSmall(guild, counters)
  -- Over the pending cap, guildmates' edits go before my own (an own sign-up may be the only copy).
  capBy(guild.pending, Store.CAPS.pending, function(p) return (p.own and 1e12 or 0) + (p.got or 0) end, counters, "cap_pending")
  capBy(guild.settled, Store.CAPS.settled, identity, counters, "cap_settled")
end

local function settle(guild, cid, now) guild.settled[cid] = now end

local function sameVersion(a, b)
  return a.cid == b.cid and Json.encode(a.body == nil and null or a.body) == Json.encode(b.body == nil and null or b.body)
    and (a.deleted or false) == (b.deleted or false)
end

-- A server version (from the inbox, a paste, or a peer's transfer).
-- Returns a result: { status = "stored"|"duplicate"|"stale"|"conflict"|"invalid", dropped = { pending edits that lost },
-- tell = { character, reason } when a dropped edit's cid was the one the server refused }.
-- A server version whose id and rev I hold is never replaced by one with another cid or body (game.md section 7: keep mine, count conflict).
-- opts: src ("inbox"|"paste"|"peer").
function Store.applyServer(guild, rec, now, counters, src)
  local res = { dropped = {} }
  if type(rec) ~= "table" or type(rec.kind) ~= "string" or type(rec.id) ~= "string" or type(rec.cid) ~= "string"
      or type(rec.rev) ~= "number" or rec.rev ~= rec.rev then
    res.status = "invalid"
    return res
  end
  local slot = Store.slot(rec.kind, rec.id)
  local held = guild.records[slot]
  if held then
    if rec.rev == held.rev then
      if sameVersion(rec, held) then res.status = "duplicate" else bump(counters, "conflict"); res.status = "conflict" end
      return res
    end
    if rec.rev < held.rev then bump(counters, "stale"); res.status = "stale"; return res end
  end
  local stored = copy(rec)
  stored.refused = nil
  stored.src, stored.got = src or "peer", now
  guild.records[slot] = stored
  if (guild.top[rec.kind] or 0) < rec.rev then guild.top[rec.kind] = rec.rev end
  res.status = "stored"
  local p = guild.pending[slot]
  if p and not pendingBeats(p, stored) then
    guild.pending[slot] = nil
    settle(guild, p.cid, now)
    res.dropped[1] = p
    if rec.refused and rec.refused.cid == p.cid then
      res.tell = { character = p.author and p.author.name, reason = rec.refused.reason }
    end
    capSmall(guild, counters)
  end
  return res
end

-- A pending edit (made here or received in chg). Local checks come before this.
-- Returns "stored", "duplicate" (held or settled already) or "lost" (beaten by what is held; its cid settles).
-- opts: own (made here), via (the sender), counters.
function Store.applyPending(guild, change, now, opts)
  opts = opts or {}
  local slot = Store.slot(change.kind, change.id)
  local cid = change.cid
  local p, r = guild.pending[slot], guild.records[slot]
  if guild.settled[cid] or (p and p.cid == cid) then return "duplicate" end
  local stored = copy(change)
  stored.pending, stored.own, stored.via, stored.got = true, opts.own or nil, opts.via, now
  -- Epochs (game.md section 7): an edit made in another epoch than the one held is keyed by the rev held for its slot.
  stored.epoch = change.epoch or 0
  if opts.rebase ~= nil then
    stored.rebase = opts.rebase
  elseif stored.epoch ~= (guild.epoch or 0) then
    stored.rebase = r and r.rev or 0
  end
  local result = "stored"
  if r and not pendingBeats(stored, r) then
    settle(guild, cid, now)
    result = "lost"
  elseif p and Order.compare(Order.pendingKey(stored), Order.pendingKey(p)) <= 0 then
    settle(guild, cid, now)
    result = "lost"
  else
    if p then settle(guild, p.cid, now) end
    guild.pending[slot] = stored
  end
  capSmall(guild, opts.counters)
  return result
end

-- Every id that begins "<parent>:" belongs to that event or bulletin.
local function parentOf(id) return id:match("^([^:]+):") end

-- Drop sign-ups whose event is not held (live or tombstone) and seen records whose bulletin is not held live.
local function dropOrphans(recs)
  for slot, r in pairs(recs) do
    if r.kind == "signup" then
      if not recs["event|" .. tostring(parentOf(r.id))] then recs[slot] = nil end
    elseif r.kind == "seen" then
      local b = recs["bulletin|" .. tostring(parentOf(r.id))]
      if not b or b.deleted then recs[slot] = nil end
    end
  end
end

-- README's window rule and the caps (login, and after each inbox, transfer or paste).
-- Run it when a transfer is complete: a sign-up held before its event is dropped as an orphan.
-- Whether a held record has the field types prune reads. SavedVariables can be edited by hand.
local function sane(r)
  if type(r) ~= "table" or type(r.kind) ~= "string" or type(r.id) ~= "string" or type(r.rev) ~= "number"
      or (r.at ~= nil and type(r.at) ~= "number") then
    return false
  end
  local b = r.body
  if r.deleted or b == nil or b == null then return true end
  if type(b) ~= "table" then return false end
  if r.kind == "event" then
    return (b.starts == nil or type(b.starts) == "number") and (b.minutes == nil or type(b.minutes) == "number")
  elseif r.kind == "bulletin" then
    return b.expires == nil or b.expires == null or type(b.expires) == "number"
  end
  return true
end

function Store.prune(guild, now, counters)
  local recs = guild.records
  local drop = {}
  for slot, r in pairs(recs) do
    if not sane(r) then
      drop[slot] = true
      bump(counters, "bad_held")
    end
  end
  for slot in pairs(drop) do recs[slot] = nil end
  drop = {}
  for slot, r in pairs(recs) do
    local b = r.body
    if r.deleted then
      if (r.at or 0) < now - Store.CAPS.tombstoneDays * DAY then
        drop[slot] = true
        if (guild.floor[r.kind] or 0) < r.rev then guild.floor[r.kind] = r.rev end
      end
    elseif r.kind == "event" and b and b ~= null and b.starts and b.starts + (b.minutes or 0) * 60 < now - Store.CAPS.tombstoneDays * DAY then
      drop[slot] = true
    elseif r.kind == "bulletin" and b and b ~= null and b.expires and b.expires ~= null and b.expires <= now then
      drop[slot] = true
    end
  end
  for slot in pairs(drop) do recs[slot] = nil end
  dropOrphans(recs)
  for slot, p in pairs(guild.pending) do
    if (p.got or 0) < now - Store.CAPS.days * DAY then
      guild.pending[slot] = nil
      bump(counters, "expired")
    end
  end
  for cid, t in pairs(guild.settled) do
    if t < now - Store.CAPS.days * DAY then guild.settled[cid] = nil end
  end
  -- Small per-guild maps that only grow: entries stamped (a time, or a table with `at`) more than 30 days ago go.
  for field, counter in pairs({ dismissed = "expired_dismissed", seenHere = "expired_seen", notices = "expired_notices" }) do
    local map = guild[field]
    if type(map) == "table" then
      for k, v in pairs(map) do
        local t = type(v) == "table" and v.at or v
        if type(t) == "number" and t < now - Store.CAPS.days * DAY then
          map[k] = nil
          bump(counters, counter)
        end
      end
    end
  end
  capSmall(guild, counters)
  Store.capRecords(guild, counters)
end

-- Over the records cap: a live record evicted means my cursor for its kind no longer holds; start it again.
-- Also run while a transfer is coming in, as soon as the store passes the cap.
function Store.capRecords(guild, counters)
  local recs = guild.records
  if count(recs) <= Store.CAPS.records then return end
  local victims = {}
  for slot, r in pairs(recs) do victims[slot] = r end
  local gone = capBy(recs, Store.CAPS.records, got, counters, "cap_records")
  if gone then
    for _, slot in ipairs(gone) do
      local r = victims[slot]
      if not r.deleted and (guild.cursor[r.kind] or 0) > 0 then
        guild.cursor[r.kind] = 0
        bump(counters, "cursor_reset")
      end
    end
    dropOrphans(recs)
  end
end

-- At most 8 guilds: the least recently logged-in goes first; `current` (a key) is never the one to go.
function Store.pruneGuilds(guilds, counters, current)
  local over = count(guilds) - Store.CAPS.guilds
  if over <= 0 then return end
  local others = {}
  for k, g in pairs(guilds) do
    if k ~= current then others[k] = g end
  end
  local gone = oldest(others, math.min(over, count(others)), function(g) return g.lastOn end)
  for _, k in ipairs(gone) do guilds[k] = nil end
  bump(counters, "cap_guilds", #gone)
end

-- The highest rev held per kind (tombstones too), after records were dropped: what a digest calls `top`.
function Store.retop(guild)
  local top = {}
  for _, r in pairs(guild.records) do
    if r.kind ~= "seen" and (top[r.kind] or 0) < r.rev then top[r.kind] = r.rev end
  end
  guild.top = top
end

-- A new epoch from the server (an inbox or a paste whose epoch differs from the one held): every held server version goes,
-- of every kind, and so do settled and words; notices and pending edits stay. Returns the epoch that was held.
-- Call Store.rebase once the snapshot is applied. The notice is told only when an epoch was held before.
function Store.newEpoch(guild, epoch, now, counters, name)
  local was = guild.epoch or 0
  bump(counters, "epoch_dropped", count(guild.records))
  guild.records, guild.settled, guild.words = {}, {}, {}
  guild.cursor, guild.floor, guild.top = zeroCursor(), {}, {}
  guild.epoch = epoch
  if was ~= 0 then
    guild.notices = guild.notices or {}
    local shown = type(name) == "string" and #name <= 200 and name or guild.name
    guild.notices.epoch = { kind = "epoch", guild = shown, at = now }
  end
  return was
end

-- After a snapshot of epoch `guild.epoch` is held: a pending edit made in another epoch gets the rev now held for its slot
-- (or 0); one of this epoch has none.
function Store.rebase(guild)
  for slot, p in pairs(guild.pending) do
    p = copy(p) -- the table in hand may be shared with a copy kept in case the apply fails
    if (p.epoch or 0) ~= (guild.epoch or 0) then
      local r = guild.records[slot]
      p.rebase = r and r.rev or 0
    else
      p.rebase = nil
    end
    guild.pending[slot] = p
  end
end

-- After Store.rebase: an edit whose cid is the cid of the record held for its slot is the one the server took; it is
-- settled, and nothing is said about it.
function Store.settleTaken(guild, now)
  for slot, p in pairs(guild.pending) do
    local r = guild.records[slot]
    if r and r.cid == p.cid then
      guild.pending[slot] = nil
      guild.settled[p.cid] = now
    end
  end
end

-- Clear this guild's data: server versions, cursors, floors and settled go, and so do the source (`src`) and the inbox
-- last applied (`inbox`), so the client is a source of `none` again; pending edits stay.
function Store.clear(guild)
  guild.epoch = 0
  guild.src, guild.inbox = nil, nil
  guild.records, guild.settled = {}, {}
  guild.cursor, guild.floor, guild.top = zeroCursor(), {}, {}
end
