-- Hellos and catch-up between addons (formats/game.md section 7; fixture game/catchup.json), and the pending-edit
-- exchange: `chg` (checked by Sync/Checks.lua before an edit is held), `pc` in `want` and `done`, and the pending-only
-- pull (fixtures game/relay.json, game/catchup.json case 3).
-- Everything a guildmate sends is untrusted: each field is checked, work and memory are bounded, nothing raises.
local _, ns = ...
ns = ns or {}

local Sync = {}
ns.Sync = Sync

local Json, Store, Digest, Inbox, Receive, Order = ns.Json, ns.Store, ns.Digest, ns.Inbox, ns.Receive, ns.Order
local Checks, Validate = ns.Checks, ns.Validate
local KINDS = Store.KINDS
local null = Json.null

Sync.K = {
  LOGIN_DELAY = 20, LOGIN_SPREAD = 10, RETRY = { 60, 180 }, PERIOD = 900, PERIOD_SPREAD = 60,
  REPLY_BASE = 1, PULL_BASE = 2, SPREAD_MAX = 20, HEARD_FOR = 1800, WANT_TIMEOUT = 20, UNRESPONSIVE = 300,
  ABANDON = 60, BATCH_BYTES = 6000, BATCH_STORED = 5700, WANT_RECORDS = 400, WAITING_MAX = 4, INC_MAX = 4, INC_RECORDS = 5000,
  INC_BATCHES = 1000, REC_PER_MESSAGE = 200, PAIR_WINDOW = 1800, WANTS_PER = 12, WANTS_WINDOW = 600,
  PEERS_MAX = 200, OUT_DEADLINE = 420, INFLIGHT = 600, SWEEP = 5, ATTEMPTS = 3, NOTICED_MAX = 200,
  CANCEL_GRACE = 15, REPLY_COOLDOWN = 30, HELLOS_PER = 8, HELLO_WINDOW = 600, ROUNDS = 10, SENDER_RECORDS = 5000,
  SENDER_WINDOW = 600, LOG_MAX = 500, DIGEST_TTL = 10, CANDIDATES_MAX = 8,
  PC_MAX = 100, PENDING_PER = 60, CHG_BYTES = 3000, CHG_PER_MESSAGE = 30, EDITS_PER = 60, EDITS_WINDOW = 600,
  RESEND = 60, RELAY_SPREAD = 5, RELAY_COOLDOWN = 30, RELAYED_MAX = 500, HI_RECENT = 60, HELD_PER_SENDER = 60,
  DONES_PER = 8, OVERHEARD_MAX = 100, OVERHEARD_FOR = 60,
}
local K = Sync.K

Sync.rand = function() return math.random() end -- the specs fix it; draws are taken in the order the rules say
Sync.counters = {}
Sync.stats = { hiSent = 0, hiHeard = 0, wantSent = 0, wantHeard = 0, wantAnswered = 0, recSent = 0, recsSent = 0,
  recIn = 0, recsIn = 0, transfers = 0, chgIn = 0 }
Sync.peers = {}      -- sender -> { at, hiAt, digest, fp, src, srcAt, v, bad (unresponsive until) }
Sync.noticed = {}    -- senders already shown the newer-version line this session
Sync.pairs = {}      -- sender "\0" kind -> when an inconsistent want went out
Sync.wantLog = {}    -- sender -> times of wants answered or queued for them
Sync.inc = {}        -- transfers coming in: key -> { sender, x, at, batches, nb, ids, recs, done }
Sync.waiting = {}    -- wants for me, waiting their turn: { sender, x, k }
Sync.learned = nil   -- a slug taken from a hello, while I hold nothing
Sync.candidates = {} -- slug -> { sender = true }: named by hellos that show no source of their own
Sync.hiLog = {}      -- sender -> times of hellos heard
Sync.recLog = {}     -- sender -> { t0, n }: records taken from them in this window
Sync.heardAt = nil
Sync.editLog = {}    -- sender -> { t0, n }: edits taken from them in this window (rule 6)
Sync.dropped = {}    -- sender -> { reason -> n }: edits the local checks refused
Sync.refusedLater = {} -- sender -> n: edits they relayed that the website later refused
Sync.sentAt = {}     -- cid -> when I last sent that pending edit in an exchange
Sync.overheard = {}  -- sender "\0" x -> when a want to someone else was heard (its pending-only done is then expected)
Sync.doneLog = {}    -- sender -> times of pending-only dones heard
Sync.relayed = {}    -- cid -> when a `chg` with it was last heard (cancels my planned relay of it)

local function count(name, n) Sync.counters[name] = (Sync.counters[name] or 0) + (n or 1) end

local function mono()
  local ok, t = ns.try(GetTime)
  return ok and type(t) == "number" and t or 0
end
local function wall()
  local ok, t = ns.try(time)
  return ok and type(t) == "number" and t or 0
end
local function after(delay, fn)
  if C_Timer and C_Timer.After then ns.try(C_Timer.After, delay, function() ns.try(fn) end) end
end
local function uniform(a, b)
  local d = Sync.rand()
  if type(d) ~= "number" or d ~= d then d = 0 end
  return a + math.max(0, math.min(1, d)) * (b - a)
end
local function int(x, max) return type(x) == "number" and x == math.floor(x) and x >= 0 and x <= (max or 9007199254740991) end
local function nameOk(s) return type(s) == "string" and #s >= 1 and #s <= 100 end
local function idOk(x) return type(x) == "string" and x:find("^[A-Za-z0-9_%-][A-Za-z0-9_%-][A-Za-z0-9_%-][A-Za-z0-9_%-]$") ~= nil end
local function isObj(t) return type(t) == "table" and t ~= null and not Json.isArray(t) end

local function online()
  local _, _, n = ns.try(GetNumGuildMembers) -- total, online (the third is online and mobile)
  if type(n) ~= "number" or n < 1 then return 1 end
  return n
end
local function spread() return math.min(K.SPREAD_MAX, online() / 10) end

local function sharing()
  local st = ns.state
  return not (st and st.db and st.db.settings and st.db.settings.share == false)
end
local function canSend() return Receive.prefixOk == true and ns.Send ~= nil end

---------------------------------------------------------------------------------------------- my guild

local function guildName()
  local ok, name = ns.try(GetGuildInfo, "player")
  if ok and type(name) == "string" and name ~= "" then return name end
end

-- My Tintean guild slug: the inbox's, else the guild held for this game guild, else one learned from a hello.
function Sync.slug()
  local inbox = ns.inbox
  if type(inbox) == "table" and type(inbox.slug) == "string" then return inbox.slug end
  local st, name = ns.state, guildName()
  if st and st.db and name then
    local key = Inbox.key(name)
    for slug, g in pairs(st.db.guilds) do
      if g.key == key then return slug end
    end
  end
  return Sync.learned
end
Receive.mine = Sync.slug

-- The guild table; with `create`, made when I hold none yet (a newcomer's first records).
function Sync.guild(create)
  local st, slug = ns.state, Sync.slug()
  if not (st and st.db and slug) then return nil end
  local g = st.db.guilds[slug]
  if not g and create then
    local name = guildName()
    local key = name and Inbox.key(name) or nil
    for other, o in pairs(st.db.guilds) do
      if key and o.key == key and other ~= slug then
        count("guild_key_clash")
        return nil
      end
    end
    g = Store.new(name or slug, wall())
    g.key = key
    st.db.guilds[slug] = g
    Store.pruneGuilds(st.db.guilds, Sync.counters, slug)
  end
  return g, slug
end

-- Cached a few seconds and until something here changes the store (Sync.touch); a new guild table also starts it again.
-- Sync.rev counts the touches: a screen that has drawn from the store can tell, cheaply, whether it has changed since.
Sync.rev = 0
function Sync.touch() Sync.digestAt = nil; Sync.rev = Sync.rev + 1 end
local function myDigest()
  local g = Sync.guild()
  local c = Sync.digestCache
  if c and c.g == g and Sync.digestAt and mono() - Sync.digestAt < K.DIGEST_TTL then return c.d end
  local d = Digest.build(g)
  Sync.digestCache, Sync.digestAt = { g = g, d = d }, mono()
  return d
end

local function srcOf(g)
  if g and (g.src == "paste" or g.src == "inbox" or g.src == "peer") then return g.src, (g.inbox and g.inbox.at) or 0 end
  if g and g.inbox then return "inbox", g.inbox.at or 0 end
  if g then
    for _, k in ipairs(KINDS) do
      if (g.cursor[k] or 0) > 0 then return "peer", 0 end
    end
  end
  return "none", 0
end

-- My source as the epoch-taking decision sees it (game.md section 7; decisions.md M28.1 point 8): an applied inbox whose
-- fetch time is older than Inbox.OLD_DAYS (the inbox is `old`) counts as a peer's, so a guildmate who stopped running the
-- desktop app is not held on a stale epoch for ever. A paste has no age rule and stays protected. Not what my hello says.
-- It ignores `peerNewer` (Inbox.read's exception; dormant, nothing sets ns.peerNewer): that flag is read once at login, before
-- any hello, so it says nothing about this inbox's age now. Same test as Inbox's `old`: strictly more than OLD_DAYS.
local function epochSrcOf(g)
  local src = srcOf(g)
  if src == "inbox" and g and g.inbox and wall() - (g.inbox.at or 0) > Inbox.OLD_DAYS * 86400 then
    return "peer"
  end
  return src
end

-- The epoch I hold for my guild (0: none), and the one a peer's message names (absent is 0; nil when it is not a whole number).
local function myEpoch()
  local g = Sync.guild()
  return g and g.epoch or 0
end

local function epochOf(m)
  if m.e == nil then return 0 end
  if int(m.e) then return m.e end
  return nil
end

---------------------------------------------------------------------------------------------- hellos

local function helloMessage(reply)
  local g, slug = Sync.guild()
  local dig = Digest.build(g)
  local src, at = srcOf(g)
  return { p = 1, t = "hi", g = slug or null, v = ns.version, pmax = 1, caps = Json.array({ "J", "Z" }), src = src, at = at,
    e = g and g.epoch or 0, d = dig.d, pd = dig.pd, r = reply and 1 or 0 }
end

function Sync.sendHello(reply)
  if not canSend() then return count("sync_off") end
  for _, m in ipairs(ns.Send.queue) do
    if m.type == "hi" and m.sent == 0 then return end -- one waiting already; it is rebuilt when it goes
  end
  ns.Send.enqueue({ type = "hi", message = helloMessage(reply),
    rebuild = function() return ns.Send.pack(helloMessage(reply)) end,
    onSent = function() Sync.stats.hiSent, Sync.hiSentAt = Sync.stats.hiSent + 1, mono() end })
end

local function periodic()
  after(uniform(0, K.PERIOD_SPREAD), function()
    local fp, skip = Digest.fingerprint(myDigest()), false
    for _, p in pairs(Sync.peers) do
      if p.hiAt and mono() - p.hiAt <= K.PERIOD and p.fp == fp and p.epoch == myEpoch() then skip = true end
    end
    if not skip then Sync.sendHello(false) end
    after(K.PERIOD, periodic)
  end)
end

local function login(n)
  if not guildName() then
    if n < 15 then after(2, function() login(n + 1) end) end
    return
  end
  after(K.LOGIN_DELAY + uniform(0, K.LOGIN_SPREAD), function()
    local t0 = mono()
    Sync.sendHello(false)
    for _, d in ipairs(K.RETRY) do
      after(d, function()
        if (Sync.heardAt or -1) < t0 then Sync.sendHello(false) end
      end)
    end
    after(K.PERIOD, periodic)
  end)
end

---------------------------------------------------------------------------------------------- pending edits

-- What goes on the wire for a held pending edit: README's change, the whole body I store, `ack` kept.
local function wire(p)
  local c = { cid = p.cid, id = p.id, kind = p.kind, base = p.base, prev = p.prev == nil and null or p.prev,
    author = p.author, at = p.at, deleted = p.deleted == true, body = p.body == nil and null or p.body }
  if p.ack ~= nil then c.ack = p.ack end
  if p.epoch ~= nil then c.epoch = p.epoch end
  return c
end

local function prefixOf(cid) return cid:sub(1, 10) end

-- The prefixes of my pending cids, sorted, at most PC_MAX (carried by `want` and `done`).
local function pcList(g)
  local list = {}
  for _, p in pairs(g and g.pending or {}) do
    if not p.unchecked then list[#list + 1] = prefixOf(p.cid) end -- an unchecked edit is not offered, so it is not listed
  end
  table.sort(list, function(a, b) return Order.compareBytes(a, b) < 0 end)
  while #list > K.PC_MAX do table.remove(list) end
  return Json.array(list)
end

-- A guildmate's list as received: a set of prefixes, or nil when it is missing or damaged.
local function pcSet(list)
  if type(list) ~= "table" or not Json.isArray(list) or #list > K.PC_MAX then return nil end
  local set = {}
  for i = 1, #list do
    if type(list[i]) ~= "string" or #list[i] > 10 then return nil end
    set[list[i]] = true
  end
  return set
end

-- My checked pending edits that `listed` lacks and that I have not sent in the last minute: newest first, at most
-- PENDING_PER. An edit still waiting for its roster is not passed on (it has not been checked).
local function owed(g, listed, t)
  local list = {}
  for _, p in pairs(g.pending) do
    local sent = Sync.sentAt[p.cid]
    if not p.unchecked and not listed[prefixOf(p.cid)] and not (sent and t - sent < K.RESEND) then list[#list + 1] = p end
  end
  table.sort(list, function(a, b)
    if (a.got or 0) ~= (b.got or 0) then return (a.got or 0) > (b.got or 0) end
    return Order.compareBytes(a.cid, b.cid) < 0
  end)
  while #list > K.PENDING_PER do table.remove(list) end
  return list
end

-- True once none of these cids is pending any more: the queue then skips the message (`settled`).
local function nonePending(cids)
  return function()
    local g = Sync.guild()
    if not g then return true end
    for _, p in pairs(g.pending) do
      if cids[p.cid] then return false end
    end
    return true
  end
end

-- `chg` messages for these held edits, about CHG_BYTES of JSON each. `own`: my own edit, just made (priority 1).
local function sendChg(list, own)
  if not canSend() or #list == 0 then return false end
  local _, slug = Sync.guild()
  local batch, cids, size, t = {}, {}, 0, mono()
  local queued = false
  local function flush()
    if #batch == 0 then return end
    local msg = { p = 1, t = "chg", g = slug or null, c = Json.array(batch) }
    if ns.Send.enqueue({ type = "chg", own = own, message = msg, settled = nonePending(cids) }) then
      queued = true
      for cid in pairs(cids) do Sync.sentAt[cid] = t end
    else
      count("chg_not_queued")
    end
    batch, cids, size = {}, {}, 0
  end
  for _, p in ipairs(list) do
    local w = wire(p)
    local json = Json.encode(w)
    if json then
      if #batch > 0 and size + #json > K.CHG_BYTES then flush() end
      batch[#batch + 1], cids[p.cid], size = w, true, size + #json
    end
  end
  flush()
  return queued
end

-- An edit made here goes to the guild once, at once (the caller has stored it as pending first).
-- Returns whether anything was queued.
function Sync.sendOwn(p) return sendChg({ p }, true) end

-- A `done` lists the source's pending edits. Anyone holding checked edits it lacks sends them after U(0, 5) seconds,
-- minus any that someone else's `chg` carried in the meantime; one such relay at a time, 30 seconds apart.
local function afterPc(listed)
  local g = Sync.guild()
  if Sync.relaySlot or not g or not sharing() or not canSend() then return end
  if Sync.lastRelay and mono() - Sync.lastRelay < K.RELAY_COOLDOWN then return end
  local t0 = mono()
  if #owed(g, listed, t0) == 0 then return end
  Sync.relaySlot = true
  after(uniform(0, K.RELAY_SPREAD), function()
    Sync.relaySlot = nil
    local g2, list = Sync.guild(), {}
    if not g2 then return end
    for _, p in ipairs(owed(g2, listed, mono())) do
      if not (Sync.relayed[p.cid] and Sync.relayed[p.cid] >= t0) then list[#list + 1] = p end
    end
    if #list > 0 then
      Sync.lastRelay = mono()
      sendChg(list, false)
    end
  end)
end

---------------------------------------------------------------------------------------------- who to ask

local function fresh(p) return mono() - p.at <= K.HEARD_FOR and p.epoch == myEpoch() end

local function remember(name, p)
  Sync.peers[name] = p
  local n, oldest, oname = 0, nil, nil
  for k, o in pairs(Sync.peers) do
    n = n + 1
    if not oldest or o.at < oldest then oldest, oname = o.at, k end
  end
  if n > K.PEERS_MAX then Sync.peers[oname] = nil end
end

-- Most cursor on the kinds I need, then an inbox source, then the newest inbox time, then the name as bytes.
local function bestSource(mine)
  local t, list, needed = mono(), {}, {}
  for name, p in pairs(Sync.peers) do
    if fresh(p) and (p.bad or 0) <= t then
      local behind = Digest.compare(mine, p.digest).behind
      if #behind > 0 then
        list[#list + 1] = { name = name, p = p }
        for _, k in ipairs(behind) do needed[k] = true end
      end
    end
  end
  for _, c in ipairs(list) do
    c.score = 0
    for k in pairs(needed) do c.score = c.score + c.p.digest.d[k][1] end
  end
  table.sort(list, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    local ai, bi = a.p.src == "inbox" and 1 or 0, b.p.src == "inbox" and 1 or 0
    if ai ~= bi then return ai > bi end
    if a.p.srcAt ~= b.p.srcAt then return a.p.srcAt > b.p.srcAt end
    return Order.compareBytes(a.name, b.name) < 0
  end)
  return list[1] and list[1].name, list[1] and list[1].p
end

local function sendWant(to, k, attempt, round)
  if not canSend() then return end
  local _, slug = Sync.guild()
  local x = ns.Ids.messageId()
  local inflight = { to = to, x = x, k = k, at = mono(), attempt = attempt or 1, round = round or 1 }
  Sync.inflight = inflight
  local msg = { p = 1, t = "want", g = slug or null, to = to, x = x, k = k, e = myEpoch() }
  local pc = pcList(Sync.guild())
  if #pc > 0 then msg.pc = pc end
  local e = ns.Send.enqueue({ type = "want", message = msg,
    onSent = function()
      Sync.stats.wantSent = Sync.stats.wantSent + 1
      after(K.WANT_TIMEOUT, function()
        if Sync.inflight ~= inflight or inflight.answered then return end
        Sync.inflight = nil
        local p = Sync.peers[to]
        if p then p.bad = mono() + K.UNRESPONSIVE end
        count("want_unanswered")
        if inflight.attempt < K.ATTEMPTS then Sync.scheduleWant(nil, inflight.attempt + 1) end
      end)
    end,
    onDrop = function() if Sync.inflight == inflight then Sync.inflight = nil end end })
  if not e and Sync.inflight == inflight then Sync.inflight = nil end
end

local function fireWant(slot)
  if not slot.live then return end
  -- Someone's want to a source I could ask holds mine back a little, in case its answer reaches me first.
  if slot.waitUntil and mono() < slot.waitUntil - 1e-6 then
    local wait = slot.waitUntil - mono()
    slot.waitUntil = nil
    return after(wait, function() fireWant(slot) end)
  end
  Sync.wantSlot = nil
  if Sync.inflight then return end
  if slot.forced then
    local f, t = slot.forced, mono()
    for kind in pairs(f.k) do Sync.pairs[f.to .. "\0" .. kind] = t end
    return sendWant(f.to, f.k, slot.attempt, f.round)
  end
  local mine = myDigest()
  local name, p = bestSource(mine)
  if not name then return end
  local k = {}
  for _, kind in ipairs(Digest.compare(mine, p.digest).behind) do k[kind] = mine.d[kind][1] end
  sendWant(name, k, slot.attempt)
end

-- One wanted pull at a time, after U(2, 2 + min(20, online / 10)) seconds. `forced`: { to, k } for an inconsistent kind.
function Sync.scheduleWant(forced, attempt)
  if Sync.wantSlot or Sync.inflight or not canSend() then return end
  local slot = { live = true, forced = forced, attempt = attempt }
  Sync.wantSlot = slot
  after(uniform(K.PULL_BASE, K.PULL_BASE + spread()), function() fireWant(slot) end)
end

-- Whether a transfer from `sourceName` that starts after `from` would serve what I need from that source.
local function serves(from, sourceName)
  local p = Sync.peers[sourceName]
  if not p or not fresh(p) then return false end
  local mine = myDigest()
  local behind = Digest.compare(mine, p.digest).behind
  if #behind == 0 then return false end
  for _, kind in ipairs(behind) do
    if from[kind] == nil or from[kind] > mine.d[kind][1] then return false end
  end
  return true
end

-- Someone else's want to that source: mine waits up to 15 seconds for its answer, once. Only a batch that
-- has arrived cancels it (a want alone could be a forgery).
local function holdForAnswer(from, sourceName)
  local slot = Sync.wantSlot
  if not slot or not slot.live or slot.forced or slot.held or not serves(from, sourceName) then return end
  slot.held, slot.waitUntil = true, mono() + K.CANCEL_GRACE
  count("want_held")
end

-- A rec or done batch has arrived from `sourceName` and serves me too: mine is cancelled.
local function cancelIfServed(from, sourceName)
  local slot = Sync.wantSlot
  if not slot or not slot.live or slot.forced or not serves(from, sourceName) then return end
  slot.live, Sync.wantSlot = false, nil
  count("want_cancelled")
end

local function scheduleReply(ahead)
  if Sync.replySlot or not canSend() then return end
  if Sync.lastReply and mono() - Sync.lastReply < K.REPLY_COOLDOWN then return count("reply_cooldown") end
  local slot = { live = true, ahead = ahead }
  Sync.replySlot = slot
  local delay = uniform(K.REPLY_BASE, K.REPLY_BASE + spread())
  local g = Sync.guild()
  if g and g.inbox and (g.inbox.at or 0) > wall() - 86400 then delay = delay / 2 end
  after(delay, function()
    if not slot.live then return end
    Sync.replySlot, Sync.lastReply = nil, mono()
    Sync.sendHello(true)
  end)
end

-- A reply-hello at least as far along on every kind I'd have told them about makes mine unnecessary.
local function cancelReply(theirs, mine)
  local slot = Sync.replySlot
  if not slot or not slot.live then return end
  for _, kind in ipairs(slot.ahead) do
    if theirs.d[kind][1] < mine.d[kind][1] or theirs.d[kind][3] < mine.d[kind][3] then return end
  end
  if theirs.pd[1] ~= mine.pd[1] or theirs.pd[2] ~= mine.pd[2] then return end -- and it has my pending digest
  slot.live, Sync.replySlot = false, nil
  count("reply_cancelled")
end

---------------------------------------------------------------------------------------------- hearing

local function parseVersion(v)
  if type(v) ~= "string" or #v < 1 or #v > 16 or not v:find("^[0-9.]+$") then return nil end
  local parts = {}
  for n in v:gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
  if #parts == 0 then return nil end
  return parts
end
local function newerThan(a, b)
  for i = 1, math.max(#a, #b) do
    local x, y = a[i] or 0, b[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

-- What I write: only the forms I know, whatever a guildmate reads (a new form is used only when all peers list it).
function Sync.sendEncodings() return { "J", "Z" } end

-- The one place the download sentence is decided (M31.6): only where no app is keeping this copy current. An unread or
-- missing state can't be told yet, so it gets no sentence.
local DOWNLOAD_LINE = "Get it at tintean.net/download."
local NEEDS_DOWNLOAD = { absent = true, never = true, old = true, damaged = true, newer = true }
function Sync.newerNotice(first, v, inboxState)
  local text = first .. " has a newer Tinteán (" .. v .. "). Some of what " .. first .. " sends is left out until you update."
  if NEEDS_DOWNLOAD[inboxState] then text = text .. " " .. DOWNLOAD_LINE end
  return text
end

local function noticeNewer(sender, v)
  local n = 0
  for _ in pairs(Sync.noticed) do n = n + 1 end
  if Sync.noticed[sender] or n >= K.NOTICED_MAX then return false end
  Sync.noticed[sender] = true
  local first = ns.Text.clean(sender:match("^[^%s%-]+") or sender, 40)
  ns.print(ns.tag .. " " .. Sync.newerNotice(first, v, (ns.inbox or {}).state))
  return true
end

local H = {}
local function guard(name, fn)
  return function(sender, m)
    local ok, err = ns.try(fn, sender, m)
    if not ok then
      count("handler_error")
      Sync.lastError = name .. ": " .. tostring(err):sub(1, 200)
    end
  end
end

local SRC = { inbox = true, paste = true, peer = true, none = true }

local function logSize(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

-- At most HELLOS_PER hellos from one sender in HELLO_WINDOW; false when over (or the table of senders is full).
local function underHelloRate(sender)
  local t, log = mono(), Sync.hiLog[sender]
  if not log then
    if logSize(Sync.hiLog) >= K.LOG_MAX then return false end
    log = {}
    Sync.hiLog[sender] = log
  end
  for i = #log, 1, -1 do
    if t - log[i] > K.HELLO_WINDOW then table.remove(log, i) end
  end
  if #log >= K.HELLOS_PER then return false end
  log[#log + 1] = t
  return true
end

-- A slug from a hello is taken while I hold none, only when that hello shows a real source (a digest, a source
-- other than "none", and some cursor above 0) or two different senders name the same one.
local takeEpoch

local function learnSlug(sender, m, dig)
  local slug = m.g
  if Sync.slug() or type(slug) ~= "string" or #slug > 64 or not slug:find("^[a-z0-9%-]+$") then return end
  local real = m.d ~= nil and SRC[m.src] and m.src ~= "none"
  if real then
    real = false
    for _, kind in ipairs(KINDS) do
      if dig.d[kind][1] > 0 then real = true end
    end
  end
  if real then
    Sync.learned, Sync.candidates = slug, {}
    return
  end
  local c = Sync.candidates[slug]
  if not c then
    if logSize(Sync.candidates) >= K.CANDIDATES_MAX then return end
    c = {}
    Sync.candidates[slug] = c
  end
  if logSize(c) < 4 then c[sender] = true end
  if logSize(c) >= 2 then Sync.learned, Sync.candidates = slug, {} end
end
function H.hi(sender, m)
  if not nameOk(sender) or Receive.isSelf(sender) then return end
  Sync.heardAt = mono()
  if not underHelloRate(sender) then return count("hello_rate") end
  Sync.stats.hiHeard = Sync.stats.hiHeard + 1
  local dig = Digest.parse(m.d, m.pd)
  if not dig then return count("bad_hi") end
  local v = parseVersion(m.v)
  local reply = m.r == 1
  local theirs = epochOf(m)
  if not theirs then return count("bad_hi") end
  learnSlug(sender, m, dig)
  if v and newerThan(v, parseVersion(ns.version) or { 0 }) then noticeNewer(sender, m.v) end
  -- Another epoch (game.md section 7): digests are compared only within one. A client with no server's state takes a higher
  -- epoch from a hello whose source is an inbox or a paste; any other hello of another epoch starts nothing.
  if theirs ~= myEpoch() then
    local g = Sync.guild()
    local mySrc = epochSrcOf(g)
    if not (theirs > myEpoch() and (mySrc == "none" or mySrc == "peer") and (m.src == "inbox" or m.src == "paste")
        and takeEpoch(theirs)) then
      Sync.peers[sender] = nil
      return count("other_epoch")
    end
  end
  remember(sender, { epoch = theirs, at = mono(), hiAt = mono(), digest = dig, fp = Digest.fingerprint(dig), v = v and m.v or nil,
    src = SRC[m.src] and m.src or "none", srcAt = int(m.at) and m.at or 0, pmax = int(m.pmax, 1000) and m.pmax or 1,
    bad = Sync.peers[sender] and Sync.peers[sender].bad })
  local mine = myDigest()
  local cmp = Digest.compare(mine, dig)
  if reply then
    cancelReply(dig, mine)
    -- A reply to my hello shows pending differing and nobody ahead: ask that replier for pending edits only.
    if cmp.pendingDiffer and #cmp.behind == 0 and Sync.hiSentAt and mono() - Sync.hiSentAt <= K.HI_RECENT then
      Sync.scheduleWant({ to = sender, k = {} })
    end
  elseif (#cmp.ahead > 0 or cmp.pendingDiffer) and sharing() then
    scheduleReply(cmp.ahead)
  end
  -- Inconsistent: the lower name asks, for that kind from 0, at most once a pair and kind in 30 minutes.
  local me = Receive.myName()
  if #cmp.inconsistent > 0 and me and Order.compareBytes(me, sender) < 0 then
    local k, t = {}, mono()
    for _, kind in ipairs(cmp.inconsistent) do
      local at = Sync.pairs[sender .. "\0" .. kind]
      if not at or t - at >= K.PAIR_WINDOW then k[kind] = 0 end
    end
    if next(k) then Sync.scheduleWant({ to = sender, k = k }) end
  end
  if #cmp.behind > 0 then Sync.scheduleWant(nil) end
end

-- Take a higher epoch heard from a peer whose state came from a server: the same drop and rebase as a new epoch from the
-- inbox (Store.newEpoch, Store.rebase); the pull follows as usual. False when there is no guild table to hold it.
takeEpoch = function(epoch)
  local g = Sync.guild(true)
  if not g then return false end
  -- What is tied to the old store goes: a transfer going out, wants waiting, one coming in, my own pull and reply.
  if Sync.out and Sync.abortOut then Sync.abortOut(Sync.out, "epoch") end
  Sync.waiting, Sync.inc, Sync.inflight = {}, {}, nil
  if Sync.wantSlot then Sync.wantSlot.live, Sync.wantSlot = false, nil end
  if Sync.replySlot then Sync.replySlot.live, Sync.replySlot = false, nil end
  Store.newEpoch(g, epoch, wall(), Sync.counters)
  g.src = "peer" -- this epoch came from a peer: a stale inbox of another epoch is refused (Inbox.run)
  Store.rebase(g)
  Store.retop(g)
  Sync.touch()
  count("epoch_taken")
  return true
end

local function parseK(k)
  if not isObj(k) then return nil end
  local out = {}
  for _, kind in ipairs(KINDS) do
    if k[kind] ~= nil then
      if not int(k[kind]) then return nil end
      out[kind] = k[kind]
    end
  end
  return out
end

-- Whether a transfer already running starts at or below this want's cursors (it will serve it too).
local function served(k)
  local out = Sync.out
  if not out then return false end
  local any = false
  for kind, want in pairs(k) do
    local covered = false
    for _, pl in ipairs(out.plan) do
      if pl.kind == kind then
        covered = true
        if pl.from > want then return false end
      end
    end
    if not covered then return false end -- a kind the running plan does not carry is not served
    any = true
  end
  return any
end

local startOut

function H.want(sender, m)
  if not nameOk(sender) or not nameOk(m.to) or not idOk(m.x) then return count("bad_want") end
  local k = m.k == nil and {} or parseK(m.k) -- no `k`: a pending-only pull
  if not k then return count("bad_want") end
  local theirs = epochOf(m)
  if not theirs then return count("bad_want") end
  Sync.heardAt = mono()
  if theirs ~= myEpoch() then return count("other_epoch") end
  if not Receive.isSelf(m.to) then
    if next(k) == nil then Sync.noteOverheard(m.to, m.x) end
    return holdForAnswer(k, m.to)
  end
  Sync.stats.wantHeard = Sync.stats.wantHeard + 1
  if not sharing() then return count("share_off") end
  if not Sync.guild() or not canSend() then return count("want_ignored") end
  if not Sync.wantLog[sender] and logSize(Sync.wantLog) >= K.LOG_MAX then return count("want_rate") end
  local t, log = mono(), Sync.wantLog[sender] or {}
  for i = #log, 1, -1 do
    if t - log[i] > K.WANTS_WINDOW then table.remove(log, i) end
  end
  if #log >= K.WANTS_PER then return count("want_rate") end
  if (Sync.out and Sync.out.requester == sender) then return count("want_busy") end
  for _, w in ipairs(Sync.waiting) do
    if w.sender == sender then return count("want_busy") end
  end
  local listed, g = pcSet(m.pc) or {}, Sync.guild()
  if next(k) == nil then
    -- Pending only: my edits they lack, then a `done` that lists mine.
    log[#log + 1] = t
    Sync.wantLog[sender] = log
    sendChg(owed(g, listed, t), false)
    local _, slug = Sync.guild()
    local done = { p = 1, t = "done", g = slug or null, x = m.x, n = 0, e = myEpoch() }
    if #pcList(g) > 0 then done.pc = pcList(g) end
    return ns.Send.enqueue({ type = "done", message = done })
  end
  if served(k) then return count("want_served") end
  log[#log + 1] = t
  Sync.wantLog[sender] = log
  sendChg(owed(g, listed, t), false) -- ahead of the records in the queue (priority 2 before 3)
  if Sync.out then
    Sync.waiting[#Sync.waiting + 1] = { sender = sender, x = m.x, k = k }
    if #Sync.waiting > K.WAITING_MAX then
      table.remove(Sync.waiting, 1)
      count("want_dropped")
    end
    return
  end
  startOut(sender, m.x, k)
end

---------------------------------------------------------------------------------------------- edits from guildmates

local function noteDrop(sender, reason)
  count("chg_" .. reason)
  local by = Sync.dropped[sender]
  if not by and logSize(Sync.dropped) < K.LOG_MAX then
    by = {}
    Sync.dropped[sender] = by
  end
  if by then by[reason] = (by[reason] or 0) + 1 end
  return reason
end

-- Rule 6: at most EDITS_PER edits from one sender in EDITS_WINDOW.
local function underEditRate(sender)
  local t, log = mono(), Sync.editLog[sender]
  if not log then
    if logSize(Sync.editLog) >= K.LOG_MAX then return false end
    log = {}
    Sync.editLog[sender] = log
  end
  for i = #log, 1, -1 do
    if t - log[i] > K.EDITS_WINDOW then table.remove(log, i) end
  end
  if #log >= K.EDITS_PER then return false end
  log[#log + 1] = t
  return true
end

-- One edit from a guildmate's `chg`: known, rate, local checks, then held. Returns what happened: "stored",
-- "duplicate", "settled", "lost", or the reason it was dropped (invalid, unknown_kind, unknown_author, forbidden, flood).
function Sync.take(sender, raw, t)
  local g, cid = Sync.guild(), Validate.cidOf(raw)
  -- A cid counts as heard (so my planned relay of it is skipped) only once it is stored or recognised.
  local function heard()
    if not cid then return end
    if Sync.relayed[cid] == nil then
      Sync.relayedN = (Sync.relayedN or 0) + 1
      if Sync.relayedN > K.RELAYED_MAX then Sync.relayed, Sync.relayedN = {}, 1 end
    end
    Sync.relayed[cid] = mono()
  end
  if cid then
    if g and g.settled[cid] then
      heard()
      return "settled"
    end
    for _, p in pairs(g and g.pending or {}) do
      if p.cid == cid then
        heard()
        return "duplicate"
      end
    end
  end
  if not underEditRate(sender) then return noteDrop(sender, "flood") end
  local res = Checks.run(g or { records = {}, pending = {}, settled = {} }, raw, { now = t, rank = Checks.gameRank })
  if not res.ok then return noteDrop(sender, res.reason) end
  g = g or Sync.guild(true)
  if not g then
    count("no_guild")
    return "no_guild"
  end
  g.notices = g.notices or {}
  local slot = Store.slot(res.change.kind, res.change.id)
  local before = g.pending[slot]
  if not before then
    local held = 0
    for _, p in pairs(g.pending) do
      if p.via == sender and not p.own then held = held + 1 end
    end
    if held >= K.HELD_PER_SENDER then return noteDrop(sender, "flood") end -- one guildmate cannot fill the store
  end
  local isNew = before == nil and g.records[slot] == nil
  local status = Store.applyPending(g, res.change, t, { via = sender, counters = Sync.counters })
  if status == "stored" or status == "duplicate" then heard() end
  if status == "stored" then
    if isNew and ns.arrived then ns.arrived(g, res.change) end -- an event or bulletin first heard of (the UI decides what it raises)
    ns.lastPeer = { name = sender, at = t } -- for the status line
    if res.unchecked then g.pending[slot].unchecked = true end
    if before and g.pending[slot] ~= before then Inbox.noticeFor(g, before, nil, t) end -- my edit lost to theirs
    Sync.stats.chgIn = Sync.stats.chgIn + 1
  elseif status == "lost" then
    count("chg_lost")
  end
  return status
end

-- A want meant for someone else, heard: its pending-only `done` is then one I expect.
function Sync.noteOverheard(to, x)
  if type(to) ~= "string" or type(x) ~= "string" then return end
  local t, n = mono(), 0
  for key, at in pairs(Sync.overheard) do
    if t - at > K.OVERHEARD_FOR then Sync.overheard[key] = nil else n = n + 1 end
  end
  if n < K.OVERHEARD_MAX then Sync.overheard[to .. "\0" .. x] = t end
end

local function underDoneRate(sender)
  local t, log = mono(), Sync.doneLog[sender]
  if not log then
    if logSize(Sync.doneLog) >= K.LOG_MAX then return false end
    log = {}
    Sync.doneLog[sender] = log
  end
  for i = #log, 1, -1 do
    if t - log[i] > K.HELLO_WINDOW then table.remove(log, i) end
  end
  if #log >= K.DONES_PER then return false end
  log[#log + 1] = t
  return true
end

function H.chg(sender, m)
  if not nameOk(sender) or Receive.isSelf(sender) then return end
  if type(m.c) ~= "table" or not Json.isArray(m.c) then return count("bad_chg") end
  Sync.heardAt = mono()
  local t = wall()
  for i = 1, math.min(#m.c, K.CHG_PER_MESSAGE) do ns.try(Sync.take, sender, m.c[i], t) end
  if #m.c > K.CHG_PER_MESSAGE then count("chg_over") end
  Sync.touch()
end

-- Edits kept unchecked (no roster or event held when they came) are judged again once records arrive.
function Sync.recheck()
  local g = Sync.guild()
  if not g then return end
  local ctx, changed = { now = wall(), rank = Checks.gameRank }, false
  for slot, p in pairs(g.pending) do
    if p.unchecked then
      local reason, unchecked = Checks.rules(g, p, ctx)
      if reason then
        g.pending[slot] = nil
        g.settled[p.cid] = wall() -- so a relay that comes later is recognised, not judged and counted again
        noteDrop(p.via or "unknown", reason)
        changed = true
      elseif not unchecked then
        p.unchecked, changed = nil, true
      end
    end
  end
  if changed then Sync.touch() end
end

---------------------------------------------------------------------------------------------- answering

local function nextWaiting()
  while not Sync.out and #Sync.waiting > 0 do
    local w = table.remove(Sync.waiting, 1)
    startOut(w.sender, w.x, w.k)
  end
end

local function abortOut(t, reason)
  if t.dead then return end
  t.dead = true
  if t.entry then ns.Send.cancel(t.entry) end
  if Sync.out == t then Sync.out = nil end
  count("transfer_aborted")
  Sync.lastAbort = tostring(reason)
  nextWaiting()
end

Sync.abortOut = abortOut

local function finishOut(t)
  if t.dead then return end
  t.dead = true
  Sync.stats.wantAnswered = Sync.stats.wantAnswered + 1
  if Sync.out == t then Sync.out = nil end
  nextWaiting()
end

-- What goes on the wire for a held version: README's record, without what only this client keeps.
local function shape(r)
  return { id = r.id, kind = r.kind, rev = r.rev, cid = r.cid, author = r.author == nil and null or r.author, at = r.at,
    deleted = r.deleted == true, body = r.body == nil and null or r.body }
end

local function byRev(a, b)
  if a.rev ~= b.rev then return a.rev < b.rev end
  return Order.compareBytes(a.id, b.id) < 0
end

local stepOut

local function sendOut(t, msg, last, chunks)
  local e = ns.Send.enqueue({ type = msg.t, message = msg, chunks = chunks,
    onSent = function() if last then finishOut(t) else stepOut(t) end end,
    onDrop = function(_, reason) abortOut(t, reason) end })
  if e then t.entry = e else abortOut(t, "not_queued") end
end

local function fromOf(t)
  local from = {}
  for _, pl in ipairs(t.plan) do from[pl.kind] = pl.from end
  return from
end

-- One batch or the closing `done` per step; the next batch is made when the last one has gone, so a requester
-- never has more than a few messages of mine queued.
function stepOut(t)
  if Sync.out ~= t or t.dead then return end
  local _, slug = Sync.guild()
  -- 6,000 bytes of JSON when the game deflates (about nine chunks); with only our stored blocks (no compression)
  -- 5,700, so the base64 still fits the 32 chunks of one message.
  local codec = ns.Codec and ns.Codec.status
  local limit = t.limit or (((codec and codec.useGameWrite) and K.BATCH_BYTES or K.BATCH_STORED) - 120)
  local batch, size = {}, 0
  local before = { pi = t.pi, sent = t.sent, i = {}, last = {} }
  for n, pl in ipairs(t.plan) do before.i[n], before.last[n] = pl.i, pl.last end
  while t.pi <= #t.plan do
    local pl = t.plan[t.pi]
    if t.sent >= K.WANT_RECORDS and not (pl.full and pl.i > 1) then
      t.more = true
      break
    end
    local rec = pl.recs[pl.i]
    if not rec then
      t.to[pl.kind] = math.max(pl.cursor, pl.want)
      if pl.full then t.full[pl.kind] = true end
      t.pi = t.pi + 1
    else
      local json = Json.encode(shape(rec))
      if not json or #json > limit then
        count("record_too_big")
        pl.i, pl.last = pl.i + 1, rec.rev
      elseif size + #json + 1 > limit and #batch > 0 then
        break
      else
        batch[#batch + 1] = shape(rec)
        size, pl.i, pl.last, t.sent = size + #json + 1, pl.i + 1, rec.rev, t.sent + 1
      end
    end
  end
  if #batch > 0 then
    local msg = { p = 1, t = "rec", g = slug or null, x = t.x, from = fromOf(t), n = t.batches + 1, e = t.e, r = Json.array(batch) }
    local chunks, why = ns.Send.pack(msg)
    if not chunks and why == "too_big" and #batch > 1 then
      -- It does not fit 32 chunks (the game's deflate did less than hoped): the same records again, in a smaller batch.
      t.pi, t.sent = before.pi, before.sent
      for n, pl in ipairs(t.plan) do pl.i, pl.last = before.i[n], before.last[n] end
      t.limit = math.floor(limit * 0.6)
      count("batch_shrunk")
      return stepOut(t)
    end
    t.batches = t.batches + 1
    Sync.stats.recSent = Sync.stats.recSent + 1
    Sync.stats.recsSent = Sync.stats.recsSent + #batch
    return sendOut(t, msg, false, chunks)
  end
  -- A kind cut at 400 records is vouched for only as far as it went, and never beyond my own cursor.
  local cut = t.more and t.plan[t.pi]
  if cut and cut.i > 1 and not cut.full and (cut.last or 0) > cut.from then t.to[cut.kind] = math.min(cut.last, cut.cursor) end
  local from, to, f, fullKinds = {}, {}, {}, {}
  for _, pl in ipairs(t.plan) do
    if t.full[pl.kind] then fullKinds[#fullKinds + 1] = pl.kind end
    if t.to[pl.kind] then from[pl.kind], to[pl.kind], f[pl.kind] = pl.from, t.to[pl.kind], pl.floor end
  end
  local msg = { p = 1, t = "done", g = slug or null, x = t.x, from = from, to = to, f = f, n = t.batches, full = Json.array(fullKinds), e = t.e }
  if t.more then msg.more = true end
  local pc = pcList(Sync.guild())
  if #pc > 0 then msg.pc = pc end
  sendOut(t, msg, true)
end

function startOut(sender, x, k)
  local g = Sync.guild()
  if not g then return end
  local top = {}
  for _, r in pairs(g.records) do
    if r.kind ~= "seen" and (top[r.kind] or 0) < r.rev then top[r.kind] = r.rev end
  end
  local plan = {}
  for _, kind in ipairs(KINDS) do
    local want = k[kind]
    local cursor, floor = g.cursor[kind] or 0, g.floor[kind] or 0
    if want ~= nil and (cursor > want or (top[kind] or 0) > want) then
      -- From 0, or from below my floor: I can't say what was deleted, so the kind goes whole (live records only).
      local full = want == 0 or want < floor
      local recs = {}
      for _, r in pairs(g.records) do
        if r.kind == kind and ((full and not r.deleted) or (not full and r.rev > want)) then recs[#recs + 1] = r end
      end
      table.sort(recs, byRev)
      plan[#plan + 1] = { kind = kind, full = full, want = want, from = full and 0 or want, cursor = cursor, floor = floor,
        recs = recs, i = 1 }
    end
  end
  if #plan == 0 then return count("want_ignored") end
  local t = { e = myEpoch(), requester = sender, x = x, plan = plan, pi = 1, sent = 0, batches = 0, more = false, full = {}, to = {},
    dead = false, deadline = mono() + K.OUT_DEADLINE }
  Sync.out = t
  stepOut(t)
end

---------------------------------------------------------------------------------------------- receiving a transfer

-- One transfer in from each sender at most, four in all (the oldest goes); heard or asked for, it is the same.
local function incFor(sender, x)
  local key = sender .. "\0" .. x
  local inc = Sync.inc[key]
  if inc then return inc end
  for k, o in pairs(Sync.inc) do
    if o.sender == sender then Sync.inc[k] = nil end
  end
  local n, oldest, okey = 0, nil, nil
  for k, o in pairs(Sync.inc) do
    n = n + 1
    if not oldest or o.at < oldest then oldest, okey = o.at, k end
  end
  if n >= K.INC_MAX then Sync.inc[okey] = nil end
  inc = { sender = sender, x = x, at = mono(), batches = {}, nb = 0, ids = {}, recs = 0, key = key }
  Sync.inc[key] = inc
  return inc
end

local function answered(sender, x)
  local f = Sync.inflight
  if f and f.to == sender and f.x == x then f.answered = true end
end

-- My digest for one kind as it would be with `victims` gone and the cursor at `to`.
local function digestWithout(g, kind, to, victims)
  local view = {}
  for slot, r in pairs(g.records) do
    if r.kind == kind and not victims[slot] then view[slot] = r end
  end
  return Digest.build({ records = view, cursor = { [kind] = to }, floor = {}, pending = {} }).d[kind]
end

-- All batches and `done` are in. Per kind: `to` is held to the cursor the source advertised in its hello; a kind
-- sent whole needs at least one batch and drops what the source did not send; and nothing moves unless my kind
-- then has the count and crc the source advertised (a forged hello or `done` cannot move my cursor or drop my
-- records). The window rule and the caps run only now: a sign-up held before its event arrived would be an orphan.
local function finish(inc)
  local d = inc.done
  Sync.inc[inc.key] = nil
  local g, peer = Sync.guild(), Sync.peers[inc.sender]
  if not g or not peer then return count("done_unknown") end
  if peer.epoch ~= myEpoch() then return count("other_epoch") end
  local moved = false
  for _, kind in ipairs(KINDS) do
    local to, from = d.to[kind], d.from[kind]
    local adv = peer.digest.d[kind]
    local cursor = g.cursor[kind] or 0
    if to and from and cursor >= from then
      to = math.min(to, adv[1])
      local whole = d.full[kind]
      if whole and (inc.nb == 0 or to ~= adv[1]) then
        count("done_refused")
      elseif whole or to > cursor then
        local victims = {}
        if whole and to >= cursor then
          local sent = inc.ids[kind] or {}
          for slot, r in pairs(g.records) do
            if r.kind == kind and r.rev <= to and not sent[r.id] then victims[slot] = true end
          end
        end
        local fine = true
        if to == adv[1] then
          local mine = digestWithout(g, kind, to, victims)
          fine = mine[4] == adv[4] and mine[5] == adv[5]
        end
        if not fine then
          count("digest_mismatch")
        else
          for slot in pairs(victims) do
            g.records[slot] = nil
            count("dropped_whole")
          end
          if whole and d.f[kind] then g.floor[kind] = math.max(g.floor[kind] or 0, math.min(d.f[kind], to)) end
          if to > cursor then
            g.cursor[kind] = to
            moved = true
          end
        end
      end
    end
  end
  Store.retop(g)
  Store.prune(g, wall(), Sync.counters)
  Sync.touch()
  Sync.stats.transfers = Sync.stats.transfers + 1
  local f = Sync.inflight
  if f and f.to == inc.sender and f.x == inc.x then
    Sync.inflight = nil
    if d.more and moved and f.round < K.ROUNDS then
      -- Asked again from where the cursors are now, if the source is still ahead.
      local mine = myDigest()
      local k = {}
      for _, kind in ipairs(Digest.compare(mine, peer.digest).behind) do k[kind] = mine.d[kind][1] end
      if next(k) then Sync.scheduleWant({ to = inc.sender, k = k, round = f.round + 1 }) end
    end
  end
end

local function tryFinish(inc)
  local d = inc.done
  if not d or inc.nb < d.n then return end
  for i = 1, d.n do
    if not inc.batches[i] then return end
  end
  finish(inc)
end

-- At most SENDER_RECORDS records from one sender in SENDER_WINDOW, across transfers.
local function underRecordRate(sender, n)
  local t, log = mono(), Sync.recLog[sender]
  if not log then
    if logSize(Sync.recLog) >= K.LOG_MAX then return false end
    log = { t0 = t, n = 0 }
    Sync.recLog[sender] = log
  end
  if t - log.t0 > K.SENDER_WINDOW then log.t0, log.n = t, 0 end
  if log.n + n > K.SENDER_RECORDS then return false end
  log.n = log.n + n
  return true
end

function H.rec(sender, m)
  if not nameOk(sender) or not idOk(m.x) or not int(m.n, K.INC_BATCHES) or m.n < 1 then return count("bad_rec") end
  if not isObj(m.from) or type(m.r) ~= "table" or not Json.isArray(m.r) or #m.r > K.REC_PER_MESSAGE then return count("bad_rec") end
  Sync.heardAt = mono()
  local theirs = epochOf(m)
  if not theirs then return count("bad_rec") end
  if theirs ~= myEpoch() then return count("other_epoch") end
  if not underRecordRate(sender, #m.r) then return count("rec_rate") end
  answered(sender, m.x)
  local inc = incFor(sender, m.x)
  if inc.batches[m.n] then return count("dup_batch") end
  inc.at, inc.batches[m.n], inc.nb = mono(), true, inc.nb + 1
  Sync.stats.recIn = Sync.stats.recIn + 1
  local t, g = wall(), Sync.guild()
  for i = 1, #m.r do
    if inc.recs >= K.INC_RECORDS then
      Sync.inc[inc.key] = nil
      return count("transfer_over")
    end
    inc.recs = inc.recs + 1
    local rec = Inbox.checkRecord(m.r[i])
    if not rec then
      count("bad_record")
    elseif rec.kind == "seen" then
      count("seen_in_transfer")
    else
      -- A guild table is made only for a record that passed the checks.
      g = g or Sync.guild(true)
      if not g then return count("no_guild") end
      g.notices = g.notices or {}
      local slot = Store.slot(rec.kind, rec.id)
      local isNew = g.records[slot] == nil and g.pending[slot] == nil
      local res = Store.applyServer(g, rec, t, Sync.counters, "peer")
      if res.status == "stored" then
        ns.lastPeer = { name = inc.sender, at = t }
        if isNew and ns.arrived then ns.arrived(g, rec) end
      end
      for _, p in ipairs(res.dropped) do
        Inbox.noticeFor(g, p, res.tell, t)
        -- A guildmate's relayed edit that the website refused: counted against whoever passed it on.
        if p.via and not p.own and rec.refused and rec.refused.cid == p.cid then
          Sync.refusedLater[p.via] = (Sync.refusedLater[p.via] or 0) + 1
        end
      end
      inc.ids[rec.kind] = inc.ids[rec.kind] or {}
      inc.ids[rec.kind][rec.id] = true
      if res.status == "stored" then Sync.stats.recsIn = Sync.stats.recsIn + 1 end
    end
  end
  if g then
    Sync.touch()
    if Store.count(g.records) > Store.CAPS.records then Store.capRecords(g, Sync.counters) end
    ns.try(Sync.recheck) -- a roster or event that has come may settle edits that were kept unchecked
  end
  local from = parseK(m.from)
  if from then cancelIfServed(from, sender) end
  tryFinish(inc)
end

local function parseKinds(list)
  if type(list) ~= "table" or not Json.isArray(list) or #list > 16 then return nil end
  local out = {}
  for _, kind in ipairs(list) do
    if type(kind) == "string" then out[kind] = true end
  end
  return out
end

-- A `done` is taken only for my own want (to that sender, with that id), or for a transfer I have heard at least one
-- batch of from that sender.
function H.done(sender, m)
  if not nameOk(sender) or not idOk(m.x) or not int(m.n, K.INC_BATCHES) then return count("bad_done") end
  local listed = pcSet(m.pc)
  if m.pc ~= nil and not listed then return count("bad_done") end -- more than 100 prefixes, or damaged
  local theirs = epochOf(m)
  if not theirs then return count("bad_done") end
  if theirs ~= myEpoch() then return count("other_epoch") end
  if m.from == nil and m.to == nil and m.n == 0 then
    -- The close of a pending-only pull: only for my own want, or one I overheard, and not too often from one sender.
    Sync.heardAt = mono()
    local mine = Sync.inflight
    local mineOk = mine and mine.to == sender and mine.x == m.x
    if not mineOk and not Sync.overheard[sender .. "\0" .. m.x] then return count("done_unknown") end
    if not underDoneRate(sender) then return count("done_rate") end
    if mineOk then
      answered(sender, m.x)
      Sync.inflight = nil
    end
    if listed then ns.try(afterPc, listed) end
    return
  end
  local from, to, f, full = parseK(m.from), parseK(m.to), parseK(m.f), parseKinds(m.full)
  if not (from and to and f and full) then return count("bad_done") end
  Sync.heardAt = mono()
  local mine = Sync.inflight
  local inc = Sync.inc[sender .. "\0" .. m.x]
  if not ((mine and mine.to == sender and mine.x == m.x) or (inc and inc.nb >= 1)) then return count("done_unknown") end
  if not Sync.guild() then return count("no_guild") end
  answered(sender, m.x)
  inc = inc or incFor(sender, m.x)
  inc.at = mono()
  inc.done = { from = from, to = to, f = f, full = full, n = m.n, more = m.more == true }
  cancelIfServed(from, sender)
  tryFinish(inc)
  if listed then ns.try(afterPc, listed) end -- after the transfer is settled: nothing here may stop it
end

Receive.handlers.hi = guard("hi", H.hi)
Receive.handlers.want = guard("want", H.want)
Receive.handlers.rec = guard("rec", H.rec)
Receive.handlers.done = guard("done", H.done)
Receive.handlers.chg = guard("chg", H.chg)

---------------------------------------------------------------------------------------------- housekeeping

-- Every few seconds: transfers with no batch for 60 s are given up (what came is kept), and so is a request that
-- was never answered; old peers and counters go.
function Sync.sweep()
  local t = mono()
  for key, inc in pairs(Sync.inc) do
    if t - inc.at > K.ABANDON then
      Sync.inc[key] = nil
      count("transfer_abandoned")
      local f = Sync.inflight
      if f and f.to == inc.sender then Sync.inflight = nil end
      if Sync.peers[inc.sender] then Sync.peers[inc.sender].bad = t + K.UNRESPONSIVE end
    end
  end
  if Sync.out and t > Sync.out.deadline then abortOut(Sync.out, "deadline") end
  if Sync.inflight and t - Sync.inflight.at > K.INFLIGHT then Sync.inflight = nil end
  for name, p in pairs(Sync.peers) do
    if t - p.at > K.HEARD_FOR and (p.bad or 0) <= t then Sync.peers[name] = nil end
  end
  for key, at in pairs(Sync.pairs) do
    if t - at > K.PAIR_WINDOW then Sync.pairs[key] = nil end
  end
  for name, log in pairs(Sync.wantLog) do
    if #log == 0 or t - log[#log] > K.WANTS_WINDOW then Sync.wantLog[name] = nil end
  end
  for name, log in pairs(Sync.hiLog) do
    if #log == 0 or t - log[#log] > K.HELLO_WINDOW then Sync.hiLog[name] = nil end
  end
  for name, log in pairs(Sync.recLog) do
    if t - log.t0 > K.SENDER_WINDOW then Sync.recLog[name] = nil end
  end
  for name, log in pairs(Sync.editLog) do
    if #log == 0 or t - log[#log] > K.EDITS_WINDOW then Sync.editLog[name] = nil end
  end
  for cid, at in pairs(Sync.sentAt) do
    if t - at > K.RESEND then Sync.sentAt[cid] = nil end
  end
end

---------------------------------------------------------------------------------------------- /tintean check

local KIND_WORDS = { event = "events", signup = "sign-ups", bulletin = "bulletins", roster = "roster", ranks = "rank names" }
local IGNORED = {
  bad_hi = "damaged hellos", bad_want = "damaged requests", bad_rec = "damaged batches", bad_done = "damaged endings",
  bad_record = "damaged records", want_rate = "requests that came too often", want_busy = "repeat requests",
  share_off = "requests while sharing is off", handler_error = "faults", transfer_over = "transfers that ran too long",
  hello_rate = "hellos that came too often", done_rate = "endings that came too often", rec_rate = "batches that came too often",
  digest_mismatch = "transfers that did not add up", done_unknown = "endings with no transfer",
  bad_chg = "damaged edit messages", chg_over = "edit messages with too many edits",
  other_epoch = "messages from another epoch",
}
-- Edits dropped by the local checks (game.md section 8), by reason.
local CHECK_WORDS = {
  chg_invalid = "not valid", chg_unknown_kind = "of a kind this version does not know",
  chg_unknown_author = "from someone not on the roster", chg_forbidden = "not allowed for that rank or person",
  chg_flood = "over the limit for one guildmate", chg_lost = "already out of date",
}

local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

function Sync.reportLines()
  local st, lines = Sync.stats, {}
  lines[1] = ns.tag .. " hellos: " .. st.hiSent .. " sent, " .. st.hiHeard .. " heard."
  lines[2] = ns.tag .. " requests for records: " .. st.wantSent .. " sent, " .. st.wantHeard .. " received, "
    .. st.wantAnswered .. " answered."
  lines[3] = ns.tag .. " " .. plural(st.recsIn, "record", "records") .. " taken from guildmates in "
    .. plural(st.recIn, "batch", "batches") .. ", " .. st.recsSent .. " sent in " .. plural(st.recSent, "batch", "batches") .. "."
  local g, parts = Sync.guild(), {}
  for _, kind in ipairs(KINDS) do parts[#parts + 1] = KIND_WORDS[kind] .. " " .. (g and g.cursor[kind] or 0) end
  lines[4] = ns.tag .. " held to rev: " .. table.concat(parts, ", ") .. "."
  lines[5] = ns.tag .. " guildmates online by the game's count: " .. online() .. "."
  local epochDropped = (ns.state and ns.state.counters and ns.state.counters.epoch_dropped or 0) + (Sync.counters.epoch_dropped or 0)
  lines[#lines + 1] = ns.tag .. " epoch " .. (g and g.epoch or 0) .. (epochDropped > 0 and (", " .. plural(epochDropped, "held version", "held versions")
    .. " dropped by a new epoch") or "") .. "."
  local names, total = {}, 0
  for name, label in pairs(IGNORED) do
    local n = Sync.counters[name] or 0
    if n > 0 then
      total = total + n
      names[#names + 1] = label .. " " .. n
    end
  end
  table.sort(names)
  if total > 0 then lines[#lines + 1] = ns.tag .. " ignored from guildmates: " .. table.concat(names, ", ") .. "." end
  local all, mine, unchecked = 0, 0, 0
  for _, p in pairs(g and g.pending or {}) do
    all = all + 1
    if p.own then mine = mine + 1 end
    if p.unchecked then unchecked = unchecked + 1 end
  end
  lines[#lines + 1] = ns.tag .. " pending edits: " .. all .. " (" .. mine .. " made here, " .. (all - mine) .. " from guildmates)"
    .. (unchecked > 0 and (", " .. unchecked .. " not checked yet") or "") .. "."
  local db = ns.state and ns.state.db
  local m = g and g.mine
  lines[#lines + 1] = ns.tag .. " saved data schema " .. (db and db.schema or 0) .. "."
  lines[#lines + 1] = ns.tag .. " group sign-ups held: " .. (m and Store.count(m.records) or 0) .. ", group events open to you: "
    .. (m and #m.may or 0) .. "."
  local badMine = ns.state and ns.state.counters and ns.state.counters.bad_mine or 0
  if badMine > 0 then lines[#lines + 1] = ns.tag .. " damaged rows ignored in your group sign-ups: " .. badMine .. "." end
  local words, dropped = {}, 0
  for name, label in pairs(CHECK_WORDS) do
    local n = Sync.counters[name] or 0
    if n > 0 then
      dropped = dropped + n
      words[#words + 1] = n .. " " .. label
    end
  end
  table.sort(words)
  if dropped > 0 then lines[#lines + 1] = ns.tag .. " edits dropped by the checks: " .. table.concat(words, ", ") .. "." end
  local later = 0
  for _, n in pairs(Sync.refusedLater) do later = later + n end
  if later > 0 then lines[#lines + 1] = ns.tag .. " edits passed on by guildmates that the website refused: " .. later .. "." end
  return lines
end

local baseCheck = ns.check
function ns.check()
  if baseCheck then ns.try(baseCheck) end
  for _, l in ipairs(Sync.reportLines()) do ns.out(l) end
end

-- /tintean debug hello: say a hello now, for the in-game checks.
ns.registerDebug("hello", function()
  Sync.sendHello(false)
  ns.out(ns.tag .. " hello: queued.")
end)

local frame = type(CreateFrame) == "function" and CreateFrame("Frame") or nil
if frame then
  frame:RegisterEvent("PLAYER_LOGIN")
  frame:SetScript("OnEvent", function() ns.try(login, 1) end)
end
if C_Timer and C_Timer.NewTicker then ns.try(C_Timer.NewTicker, K.SWEEP, function() ns.try(Sync.sweep) end) end

return Sync
