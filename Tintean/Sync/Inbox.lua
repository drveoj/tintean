-- The inbox reader (formats/game.md sections 7 and 12). The desktop app writes Tintean_Inbox; the game runs it as
-- Lua and this reads the table it set. Nothing from it is ever run: no loadstring, no load, no setfenv.
--   Inbox.read(inbox, addonLoaded, guildName, now, opts) -> result { state, slug, entry, payload, at, rev, crc, ... }
--   Inbox.run(db, counters, inbox, addonLoaded, guildName, now, opts) -> result (the guild in `db` is replaced whole, or not at all)
-- States: absent, damaged, newer, never (the stub), too_large, other_guild, old, fresh. old and fresh are applied.
-- Store.prune runs here, once the whole payload is in, and nowhere in the middle of a read.
local _, ns = ...
ns = ns or {}

local Inbox = {}
ns.Inbox = Inbox

local Json, Store, Validate, Order, Pack, Crc32 = ns.Json, ns.Store, ns.Validate, ns.Order, ns.Pack, ns.Crc32
local null = Json.null
local floor = math.floor

Inbox.FORMAT = 1
Inbox.MAX_ENTRIES = 4         -- guilds in the file; further ones are not looked at
Inbox.MAX_RECORDS = 10000     -- records read from one payload (a payload is at most 1 MiB of JSON)
Inbox.MAX_WORDS = 50
Inbox.MAX_ACKS = 50
Inbox.MAX_AHEAD = 200
Inbox.OLD_DAYS = 3
Inbox.SLACK = 120             -- the forgery rule's allowance for one clock read at two moments
Inbox.MAX_RECORD_CHARS = 16384
local MAX_SAFE = 9007199254740991

local function bump(counters, name, n)
  if counters then counters[name] = (counters[name] or 0) + (n or 1) end
end

local function isInt(x) return type(x) == "number" and x == floor(x) and x >= 0 and x <= MAX_SAFE end
local function isObj(v) return type(v) == "table" and v ~= null and Json.isObject(v) end
local function isList(v) return type(v) == "table" and v ~= null and Json.isArray(v) end

-- The key a game guild is found by: the CRC-32 of its name with ASCII letters lower-cased and spaces trimmed.
function Inbox.key(name)
  name = (name or ""):gsub("[A-Z]", string.lower):match("^ *(.-) *$")
  return Crc32.of(name)
end

-- A plain sequence 1..n of at most `max` values, else nil.
local function sequence(t, max)
  if type(t) ~= "table" then return nil end
  local n = 0
  for k in pairs(t) do
    n = n + 1
    if n > max or type(k) ~= "number" or k ~= floor(k) or k < 1 then return nil end
  end
  for i = 1, n do
    if t[i] == nil then return nil end
  end
  return n
end

local function entryOk(e)
  return type(e) == "table" and type(e.slug) == "string" and #e.slug >= 1 and #e.slug <= 64
    and e.slug:find("^[a-z0-9%-]+$") ~= nil and isInt(e.key) and e.key <= 4294967295 and type(e.data) == "string"
end

local function done(state, extra)
  extra = extra or {}
  extra.state = state
  return extra
end

-- Which of fresh and old: the file's own age against three days, unless a guildmate has sent something newer.
-- Caveat: `peerNewer` is read when the file is read (at login, before any guildmate has spoken), so old stays old
-- for the session unless a later task re-evaluates it; a skipped (already applied) read is judged the same way.
local function ageState(at, now, peerNewer)
  if not peerNewer and now - at > Inbox.OLD_DAYS * 86400 then return "old" end
  return "fresh"
end

-- `known(slug, at, crc, len)` may answer true when this very file was applied already (idempotence): the payload is
-- not decoded again. Names and numbers in the payload must agree with the file around it, or the whole entry is damaged.
function Inbox.read(inbox, addonLoaded, guildName, now, opts, known)
  opts = opts or {}
  if inbox == nil then
    return done(addonLoaded and "damaged" or "absent")
  end
  if type(inbox) ~= "table" then return done("damaged") end
  if not isInt(inbox.v) then return done("damaged") end
  if inbox.v > Inbox.FORMAT then return done("newer") end
  if not isInt(inbox.at) then return done("damaged") end
  if inbox.at == 0 then return done("never") end
  if inbox.at > now + Inbox.SLACK then return done("damaged") end
  local n = sequence(inbox.guilds, 64)
  if not n then return done("damaged") end

  local want = Inbox.key(guildName)
  local entry
  for i = 1, math.min(n, Inbox.MAX_ENTRIES) do
    local e = inbox.guilds[i]
    if type(e) == "table" and e.key == want then
      if not entryOk(e) then return done("damaged") end
      entry = e
      break
    end
  end
  if not entry then return done("other_guild", { at = inbox.at }) end

  local state = ageState(inbox.at, now, opts.peerNewer)
  local base = { slug = entry.slug, at = inbox.at, key = entry.key, len = #entry.data }
  -- The cap is on the characters after the prefix: say too_large before any work on them.
  if #entry.data > Pack.MAX_CHARS + #Pack.PREFIX then return done("too_large", base) end
  base.crc = Crc32.hex(entry.data)
  if known and known(entry.slug, inbox.at, base.crc, base.len) then
    base.skipped, base.state = true, state
    return base
  end
  local payload, code = Pack.unpackInbox(entry.data)
  if not payload then
    return done(code == "newer" and "newer" or (code == "too_large" and "too_large" or "damaged"), base)
  end
  if payload.t ~= "inbox" or payload.guild ~= entry.slug then return done("damaged", base) end
  if not isInt(payload.rev) or not isInt(payload.floor) or not isInt(payload.at) then return done("damaged", base) end
  -- The payload's own guild name must hash to the key it was found under, and its numbers must be possible.
  if type(payload.name) ~= "string" or Inbox.key(payload.name) ~= want then return done("damaged", base) end
  if payload.floor > payload.rev or payload.at > inbox.at + Inbox.SLACK then return done("damaged", base) end
  if payload.person ~= nil and not (type(payload.person) == "string" and #payload.person <= 32
      and payload.person:find("^[A-Za-z0-9_%-]+$")) then
    return done("damaged", base)
  end
  if payload.leftOut ~= nil and not isList(payload.leftOut) then return done("damaged", base) end
  if payload.epoch ~= nil and not (isInt(payload.epoch) and payload.epoch >= 0) then return done("damaged", base) end
  for i = 1, math.min(#payload.records, Inbox.MAX_RECORDS) do
    local r = payload.records[i]
    if type(r) == "table" and type(r.rev) == "number" and r.rev > payload.rev then return done("damaged", base) end
  end
  base.state, base.payload, base.rev = state, payload, payload.rev
  return base
end

local HEX = "[0-9a-f]"
local SEEN_BY_PERSON = "^(" .. HEX:rep(8) .. "%-" .. HEX:rep(4) .. "%-" .. HEX:rep(4) .. "%-" .. HEX:rep(4) .. "%-" .. HEX:rep(12)
  .. "):p:(" .. ("[A-Za-z0-9]"):rep(12) .. ")$"
local SIGNUP_BY_CHARACTER = "^(" .. HEX:rep(8) .. "%-" .. HEX:rep(4) .. "%-" .. HEX:rep(4) .. "%-" .. HEX:rep(4) .. "%-" .. HEX:rep(12)
  .. "):c:(" .. HEX:rep(8) .. "%-" .. HEX:rep(4) .. "%-" .. HEX:rep(4) .. "%-" .. HEX:rep(4) .. "%-" .. HEX:rep(12) .. ")$"

local V = Validate.is
local function intIn(x, lo, hi) return V.int(x) and x >= lo and x <= hi end
local function nullable(x, check) return x == nil or x == null or check(x) end
local function shortText(x, max, min) return type(x) == "string" and #x <= max * 4 and Validate.text(x, max, min or 0) ~= nil end
local function nameOk(x) return type(x) == "string" and #x <= 320 and Validate.len(x) <= 80 and not Validate.hasControl(x) end

-- Server-side bodies are wider than a game change's (group events, counts, a roster's fields, ranks' officer ticks, the
-- person form of seen); each is checked for type and bound here, never for the pacing or rank rules (the server's job).
local BODY = {}

function BODY.event(b)
  if not shortText(b.title, 80, 1) then return false end
  if type(b.activity) ~= "string" or not Validate.ACTIVITIES[b.activity] then return false end
  if not V.sec(b.starts) or not intIn(b.minutes, 1, 10080) then return false end
  if not nullable(b.size, function(x) return intIn(x, 1, 40) end) then return false end
  if not nullable(b.want, function(w)
        if not V.obj(w) then return false end
        for _, r in ipairs({ "tank", "healer", "dps" }) do
          if not nullable(w[r], function(x) return intIn(x, 0, 40) end) then return false end
        end
        return true
      end) then
    return false
  end
  if not nullable(b.notes, function(x) return shortText(x, 2000) end) then return false end
  if b.cancelled ~= nil and type(b.cancelled) ~= "boolean" then return false end
  if not nullable(b.place, function(p) return V.obj(p) and V.uuid(p.ref) and nullable(p.name, nameOk) end) then return false end
  if not nullable(b.group, function(g)
        return V.obj(g) and type(g.slug) == "string" and #g.slug <= 64 and nullable(g.name, nameOk)
      end) then
    return false
  end
  if not nullable(b.counts, function(c)
        if not V.obj(c) then return false end
        local n = 0
        for k, x in pairs(c) do
          n = n + 1
          if n > 10 or type(k) ~= "string" or #k > 16 or not intIn(x, 0, 1000000) then return false end
        end
        return true
      end) then
    return false
  end
  return true
end

local function statusFields(b)
  if b.status ~= "yes" and b.status ~= "no" and b.status ~= "maybe" then return false end
  if not nullable(b.role, function(x) return x == "tank" or x == "healer" or x == "dps" end) then return false end
  return nullable(b.note, function(x) return shortText(x, 200) end)
end

function BODY.signup(b, id)
  local event, roster = Validate.splitSignupId(id)
  if not event then event = id:match(SIGNUP_BY_CHARACTER) end
  if b.event ~= event then return false end
  if roster then
    if b.roster ~= roster then return false end
  elseif b.roster ~= nil and b.roster ~= null then
    return false
  end
  if not nullable(b.name, nameOk) then return false end
  return statusFields(b)
end

function BODY.bulletin(b)
  if not shortText(b.title, 80, 1) or not shortText(b.text, 600) then return false end
  if not nullable(b.event, V.uuid) then return false end
  if b.pinned ~= nil and type(b.pinned) ~= "boolean" then return false end
  return nullable(b.expires, V.sec)
end

function BODY.roster(b)
  if not shortText(b.first, 80, 1) or not shortText(b.second, 80) then return false end
  if not intIn(b.rank, 0, 9) or type(b.officer) ~= "boolean" then return false end
  if not nullable(b.rankName, function(x) return shortText(x, 40) end) then return false end
  if not nullable(b.level, function(x) return intIn(x, 0, 100) end) then return false end
  if not nullable(b.class, function(x) return shortText(x, 40) end) then return false end
  return nullable(b.person, function(x) return type(x) == "string" and #x <= 32 and x:find("^[A-Za-z0-9_%-]+$") ~= nil end)
end

function BODY.seen(b, id)
  local bulletin, handle = id:match(SEEN_BY_PERSON)
  if bulletin then
    return b.bulletin == bulletin and b.person == handle and (b.roster == nil or b.roster == null)
  end
  local bl, roster = Validate.splitSignupId(id)
  return b.bulletin == bl and b.roster == roster and (b.person == nil or b.person == null)
end

function BODY.ranks(b)
  if not V.array(b.names) or #b.names < 1 or #b.names > 10 then return false end
  for i = 1, #b.names do
    if not nullable(b.names[i], function(x) return shortText(x, 40, 1) end) then return false end
  end
  if b.officer ~= nil then
    if not V.array(b.officer) or #b.officer > 10 then return false end
    for i = 1, #b.officer do
      if type(b.officer[i]) ~= "boolean" then return false end
    end
  end
  return true
end

-- A server version as the inbox gives it. Returns the clean record, or nil and "skip" (unknown kind) or "bad".
local function checkRecord(raw)
  if not isObj(raw) or type(raw.kind) ~= "string" then return nil, "bad" end
  if not Validate.KINDS[raw.kind] then return nil, "skip" end
  local kind, id = raw.kind, raw.id
  local idOk = Validate.idOk(kind, id)
  if not idOk and type(id) == "string" then
    if kind == "seen" then idOk = id:find(SEEN_BY_PERSON) ~= nil
    elseif kind == "signup" then idOk = id:find(SIGNUP_BY_CHARACTER) ~= nil end
  end
  if not idOk or not V.cid(raw.cid) then return nil, "bad" end
  if not intIn(raw.rev, 1, MAX_SAFE) or not V.sec(raw.at) or type(raw.deleted) ~= "boolean" then return nil, "bad" end
  local author = raw.author
  if author == nil then author = null end
  if author ~= null and not (V.obj(author) and V.rosterKey(author.roster) and nameOk(author.name)) then return nil, "bad" end
  local body = raw.body
  if raw.deleted then
    if body ~= nil and body ~= null then return nil, "bad" end
    body = null
  elseif not isObj(body) or not BODY[kind](body, id) then
    return nil, "bad"
  end
  local rec = { id = id, kind = kind, rev = raw.rev, cid = raw.cid, author = author, at = raw.at, deleted = raw.deleted, body = body }
  local r = raw.refused
  if isObj(r) and V.cid(r.cid) and type(r.reason) == "string" and #r.reason <= 40 then
    rec.refused = { cid = r.cid, reason = r.reason }
  end
  local json = Json.encode(rec)
  if not json or #json > Inbox.MAX_RECORD_CHARS then return nil, "bad" end
  return rec
end

Inbox.checkRecord = checkRecord -- Sync checks a peer's server-shaped records with the same rules

local function cleanWarnings(list)
  if not isList(list) then return nil end
  local out = Json.array({})
  for i = 1, #list do
    if #out >= 10 then break end
    local w = list[i]
    if isObj(w) and type(w.code) == "string" and #w.code <= 40 and w.code:find("^[a-z_]+$") and V.warningRef(w.ref)
        and type(w.text) == "string" and #w.text <= 4000 and Validate.len(w.text) <= 1000 then
      out[#out + 1] = { code = w.code, ref = w.ref, text = w.text }
    end
  end
  return out
end

local function cleanWords(list, counters)
  local out = {}
  if not isList(list) then return out end
  for i = 1, #list do
    if #out >= Inbox.MAX_WORDS then
      bump(counters, "over_cap_words")
      break
    end
    local w = list[i]
    local warnings = isObj(w) and cleanWarnings(w.warnings)
    local ok = warnings and V.cid(w.cid) and type(w.id) == "string" and Validate.idOk("signup", w.id)
      and isObj(w.body) and statusFields(w.body) and isInt(w.rev) and isInt(w.refusedAt)
    if ok then
      local event, roster = Validate.splitSignupId(w.id)
      ok = w.event == event and w.roster == roster
    end
    if ok then
      out[#out + 1] = { cid = w.cid, id = w.id, event = w.event, roster = w.roster, rev = w.rev,
        refusedAt = w.refusedAt, body = { status = w.body.status, role = w.body.role, note = w.body.note }, warnings = warnings }
    else
      bump(counters, "bad_word")
    end
  end
  return out
end

local function cleanAhead(list, counters)
  local out = {}
  if not isList(list) then return out end
  for i = 1, #list do
    if #out >= Inbox.MAX_AHEAD then
      bump(counters, "over_cap_ahead")
      break
    end
    local a = list[i]
    local warnings = isObj(a) and cleanWarnings(a.warnings)
    if warnings and V.uuid(a.event) and V.rosterKey(a.roster) then
      out[#out + 1] = { event = a.event, roster = a.roster, warnings = warnings }
    else
      bump(counters, "bad_ahead")
    end
  end
  return out
end

local function shallow(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- The guild's table with its maps copied one level: a failure while applying leaves the original as it was.
local function workingCopy(g)
  local w = shallow(g)
  for _, f in ipairs({ "records", "pending", "settled", "cursor", "floor", "top", "notices", "dismissed", "seenHere" }) do
    w[f] = shallow(g[f] or {})
  end
  return w
end

-- A pending edit that lost: its cid is settled by Store; tell the person why (a word, a refusal, or "changed first").
local function noticeFor(guild, p, tell, now)
  if not p.own then return end
  local took = guild.records[Store.slot(p.kind, p.id)]
  if took and took.cid == p.cid then return end -- the server took it: nothing lost
  local word
  for _, w in ipairs(guild.words or {}) do
    if w.cid == p.cid then word = w end
  end
  local n
  if word then
    n = { kind = "word", cid = p.cid, event = word.event }
  elseif tell and tell.reason == "needs_ack" then -- a guildmate's app carried it: nothing to read (game.md section 9)
    local event = Validate.splitSignupId(p.id)
    local held = guild.records[Store.slot(p.kind, p.id)]
    n = { kind = "needs_ack_relayed", cid = p.cid, id = p.id, event = event, rev = held and held.rev,
      reason = tell.reason, character = tell.character }
  elseif tell then
    n = { kind = "refused", cid = p.cid, id = p.id, reason = tell.reason, character = tell.character }
  else
    n = { kind = "changed", cid = p.cid, id = p.id }
  end
  n.at = now
  guild.notices[p.cid] = n
end

Inbox.noticeFor = noticeFor -- Sync tells a person their edit lost to a guildmate's record, as an inbox does

local function recompute(guild)
  for _, k in ipairs(Store.KINDS) do guild.top[k] = 0 end
  for _, r in pairs(guild.records) do
    if r.kind ~= "seen" and (guild.top[r.kind] or 0) < r.rev then guild.top[r.kind] = r.rev end
  end
end

-- Game.md section 7, "The inbox against peers". `res` gets counts.
local function applyPayload(guild, payload, entry, meta, now, counters)
  local fetch, top = payload.at, payload.rev
  local left = {}
  for _, k in ipairs(isList(payload.leftOut) and payload.leftOut or {}) do
    if type(k) == "string" then left[k] = true end
  end
  -- A new epoch (game.md section 7): what the server held is another history. Every server version goes; the pending edits
  -- are set aside while the snapshot is applied, then kept, each keyed by the rev now held for its slot.
  local stashed
  if payload.epoch ~= nil and payload.epoch ~= (guild.epoch or 0) then
    Store.newEpoch(guild, payload.epoch, now, counters, payload.name)
    stashed = {}
    for slot, p in pairs(guild.pending) do
      stashed[slot] = p
      guild.pending[slot] = nil
    end
  end
  guild.words = cleanWords(payload.words, counters)
  guild.ahead = cleanAhead(payload.ahead, counters)

  local accepted, inInbox = {}, {}
  local list = payload.records
  for i = 1, #list do
    if i > Inbox.MAX_RECORDS then
      bump(counters, "inbox_over_cap", #list - Inbox.MAX_RECORDS)
      break
    end
    local rec, why = checkRecord(list[i])
    if rec then
      -- The same id twice in one payload: the highest rev is the one kept (the first, on a tie).
      local slot = Store.slot(rec.kind, rec.id)
      local at = inInbox[slot]
      if not at then
        accepted[#accepted + 1] = rec
        inInbox[slot] = #accepted
      else
        bump(counters, "duplicate_record")
        if rec.rev > accepted[at].rev then accepted[at] = rec end
      end
    elseif why == "skip" then
      bump(counters, "unknown_kind")
    else
      bump(counters, "bad_record")
    end
  end

  -- Rules 2 and 3: what the inbox does not have, at or below its rev, goes; a peer's version above it that was
  -- received before the snapshot began cannot be the server's.
  for slot, held in pairs(guild.records) do
    if not left[held.kind] then
      if held.rev > top then
        if held.src == "peer" and (held.got or 0) < fetch - Inbox.SLACK then
          guild.records[slot] = nil
          bump(counters, "forged")
        end
      elseif not inInbox[slot] then
        guild.records[slot] = nil
        bump(counters, "dropped_window")
      end
    end
  end

  -- Rule 1: the inbox replaces what is held, unless that is a peer's higher version received after the snapshot began.
  for _, rec in ipairs(accepted) do
    local slot = Store.slot(rec.kind, rec.id)
    local held = guild.records[slot]
    if held and held.src == "peer" and held.rev > top then
      bump(counters, "kept_peer")
    else
      if held then
        if held.cid ~= rec.cid or held.rev ~= rec.rev then bump(counters, "replaced") end
        guild.records[slot] = nil
      end
      local res = Store.applyServer(guild, rec, now, counters, "inbox")
      for _, p in ipairs(res.dropped) do noticeFor(guild, p, res.tell, now) end
    end
  end

  if stashed then
    for slot, p in pairs(stashed) do guild.pending[slot] = p end
    Store.rebase(guild)
    Store.settleTaken(guild, now)
  end

  -- Rule 4: pending edits are kept, then set against what is held by the key (a kept peer version can beat one).
  for slot, p in pairs(guild.pending) do
    local r = guild.records[slot]
    if r and Order.compare(Order.pendingKey(p), Order.serverKey(r)) <= 0 then
      guild.pending[slot] = nil
      guild.settled[p.cid] = now
      noticeFor(guild, p, nil, now)
    end
  end

  -- Rule 5.
  for _, k in ipairs(Store.KINDS) do
    if not left[k] then guild.cursor[k] = top end
    guild.floor[k] = payload.floor
  end
  guild.key, guild.lastOn, guild.person = entry.key, now, payload.person
  guild.src = "inbox" -- the file now supplies this guild's data; a paste before it no longer describes it
  if type(payload.name) == "string" and #payload.name <= 200 then guild.name = payload.name end
  guild.inbox = { at = meta.at, rev = top, crc = meta.crc, len = meta.len }
  -- The payload is whole: now, and only now, the window rule and the caps.
  Store.prune(guild, now, counters)
  recompute(guild)
end

-- The payload's `moments` ([ { stream, acked } ], at most 50: formats/moments/README.md section 6) drop what the server
-- has kept. A damaged field is ignored; it never fails the read. Also used for the website's snapshot (a paste).
function Inbox.ackMoments(db, acks, counters)
  local M = ns.Moments and ns.Moments.Store
  if not M or type(acks) ~= "table" or acks == null then return 0 end
  local list = {}
  for i = 1, math.min(#acks, Inbox.MAX_ACKS) do list[i] = acks[i] end
  local ok, n = pcall(M.ack, db, list, counters)
  return ok and n or 0
end

-- db.guilds[slug] is replaced by a fully applied copy, or left alone when the file was applied before, is older than
-- the one applied, is for a different guild key than the one held, or is not fresh.
function Inbox.run(db, counters, inbox, addonLoaded, guildName, now, opts)
  -- Held and not cleared since: Clear zeroes the cursors, and then any file may refill the guild.
  local function applied(g)
    return g ~= nil and type(g.inbox) == "table" and type(g.inbox.rev) == "number"
      and (g.cursor and g.cursor.event or 0) >= g.inbox.rev
  end
  local function known(slug, at, crc, len)
    local g = db.guilds[slug]
    return applied(g) and g.inbox.at == at and g.inbox.crc == crc and g.inbox.len == len
  end
  local res = Inbox.read(inbox, addonLoaded, guildName, now, opts, known)
  local held = res.slug and db.guilds[res.slug]
  if held and held.key ~= nil and res.key ~= nil and held.key ~= res.key then
    res.state, res.payload = "damaged", nil
    return res
  end
  if not res.payload then
    if res.skipped then res.rev = held.inbox.rev end
    return res
  end
  -- A stale file of another epoch than the one a peer gave me is not applied (decisions.md M28.1 point 8): it would put the
  -- old epoch back at every login. A fresh file of any epoch still replaces it: the server is the authority.
  if res.state == "old" and held and held.src == "peer" and res.payload.epoch ~= nil
      and res.payload.epoch ~= (held.epoch or 0) then
    res.payload, res.rev = nil, nil
    bump(counters, "inbox_stale_epoch")
    return res
  end
  -- A payload of another epoch is another history: its rev and age are not compared with the one applied (invariant 7).
  local sameEpoch = res.payload.epoch == nil or res.payload.epoch == (held and held.epoch or 0)
  if sameEpoch and applied(held) and (res.at < held.inbox.at or res.payload.rev < held.inbox.rev) then
    res.state, res.payload, res.rev = "older", nil, nil
    bump(counters, "inbox_older")
    return res
  end
  local guild = workingCopy(held or Store.new(guildName, now))
  applyPayload(guild, res.payload, { key = res.key }, res, now, counters)
  db.guilds[res.slug] = guild
  Inbox.ackMoments(db, res.payload.moments, counters)
  res.payload = nil -- decoded once, not kept
  Store.pruneGuilds(db.guilds, counters, res.slug)
  return res
end

------------------------------------------------------------------------------------------------------------------
-- In game: read once the guild is known, and say what happened in /tintean check.

-- The words after "Tinteán: inbox"; a few states are whole lines.
Inbox.WORDS = {
  fresh = "fresh", old = "old", damaged = "damaged", newer = "newer", absent = "not installed",
  too_large = "too large", unread = "not read yet", older = "older than the one already read",
}
Inbox.LINES = {
  never = "Tinteán: inbox empty, no data from the app yet.",
  no_guild = "Tinteán: inbox not read, you are not in a guild.",
  other_guild = "Tinteán: the inbox has nothing for this guild.",
}

local function inboxLoaded()
  local ok, loaded = ns.try(function() return C_AddOns.IsAddOnLoaded("Tintean_Inbox") end)
  if ok then return loaded == true end
  return type(Tintean_Inbox) == "table"
end

local function readNow(guildName)
  local st = ns.state
  if not st or not st.db then return end
  local _, t0 = ns.try(debugprofilestop)
  local now = time()
  local ok, res = ns.try(Inbox.run, st.db, st.counters, Tintean_Inbox, inboxLoaded(), guildName, now, { peerNewer = ns.peerNewer })
  local _, t1 = ns.try(debugprofilestop)
  if not ok then
    res = { state = "damaged", error = tostring(res):sub(1, 200) }
    bump(st.counters, "inbox_error")
  end
  res.ms = (type(t0) == "number" and type(t1) == "number") and floor(t1 - t0 + 0.5) or 0
  res.guild = guildName
  ns.inbox = res
  -- A roster or event that has come may settle edits kept unchecked.
  if ns.Sync then
    ns.try(ns.Sync.recheck)
    ns.try(ns.Sync.touch)
  end
end

local TRIES = 15

-- Waits for the guild name and for the saved data to be ready; either may come a little after login.
local function attempt(n)
  local st = ns.state
  local _, guildName = ns.try(GetGuildInfo, "player")
  if st and st.db and type(guildName) == "string" and guildName ~= "" then
    readNow(guildName)
  elseif n < TRIES and C_Timer then
    C_Timer.After(2, function() ns.try(attempt, n + 1) end)
  elseif st and st.db then
    ns.inbox = { state = "no_guild" }
  end
end
Inbox.attempt = attempt

-- /tintean check. Later tasks add their own lines after this one.
function ns.check()
  local r = ns.inbox or { state = "unread" }
  if Inbox.LINES[r.state] then
    ns.out(Inbox.LINES[r.state])
    return
  end
  local line = ns.tag .. " inbox " .. (Inbox.WORDS[r.state] or tostring(r.state))
  if r.rev then line = line .. ", rev " .. r.rev end
  if r.ms and r.rev then line = line .. ", read in " .. r.ms .. " ms" end
  ns.out(line .. ".")
  if r.at and r.at > 0 then
    local _, stamp = ns.try(date, "%Y-%m-%d %H:%M", r.at)
    if stamp then ns.out(ns.tag .. " inbox file written " .. stamp .. ".") end
  end
end

if type(CreateFrame) == "function" then
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("PLAYER_LOGIN")
  frame:SetScript("OnEvent", function() ns.try(attempt, 1) end)
end
