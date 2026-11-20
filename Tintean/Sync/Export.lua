-- The export for the desktop app (formats/game.md section 13): Tintean.out.
-- One TN1: string per guild holding every pending edit, mine and relayed. Pure: callers pass `now`.
local _, ns = ...
ns = ns or {}

local Export = {}
ns.Export = Export

local Json, Order = ns.Json, ns.Order
local null = Json.null

-- The app reads more than a paste does: 262,144 characters and 4 MiB unpacked.
Export.LIMITS = { chars = 262144, bytes = 4194304 }

local KIND_ORDER = { event = 1, bulletin = 2, signup = 3, seen = 4, ranks = 5 }
-- What the server fills in, left out of the body.
local FILLED = { event = { counts = true }, signup = { name = true }, bulletin = { created = true, by = true }, seen = { person = true } }

-- README's change shape from a stored pending edit: internal fields (own, via, got, rebase, pending) are not copied.
local function shape(p)
  local body = p.body
  if type(body) == "table" and body ~= null and FILLED[p.kind] then
    local b = {}
    for k, v in pairs(body) do
      if not FILLED[p.kind][k] then b[k] = v end
    end
    body = b
  end
  local c = {
    cid = p.cid, id = p.id, kind = p.kind, base = p.base, prev = p.prev == nil and null or p.prev,
    author = p.author, at = p.at, deleted = p.deleted == true, body = body,
  }
  if p.ack ~= nil then c.ack = p.ack end
  if p.epoch ~= nil then c.epoch = p.epoch end
  return c
end

-- Every pending edit of a guild, in kind order, then by `at`, then cid as bytes.
function Export.changes(guild)
  local list = {}
  for _, p in pairs(guild.pending) do list[#list + 1] = p end
  -- The person's own group sign-ups wait in `mine.pending` and go up the same way (decisions.md M33.12, 11.3).
  for _, p in pairs(guild.mine and guild.mine.pending or {}) do list[#list + 1] = p end
  table.sort(list, function(a, b)
    local ka, kb = KIND_ORDER[a.kind] or 9, KIND_ORDER[b.kind] or 9
    if ka ~= kb then return ka < kb end
    if (a.at or 0) ~= (b.at or 0) then return (a.at or 0) < (b.at or 0) end
    return Order.compareBytes(a.cid, b.cid) < 0
  end)
  local out = Json.array()
  for i, p in ipairs(list) do out[i] = shape(p) end
  return out
end

-- The moments held for a guild by this account: { { ckey, e }, ... } by character, only those holding something, and none
-- when the switch is off (formats/moments/README.md section 6).
function Export.heldMoments(db, guild)
  local M = ns.Moments and ns.Moments.Store
  if not (M and type(db) == "table" and type(db.moments) == "table" and type(guild) == "table") then return {} end
  if type(db.settings) == "table" and db.settings.moments == false then return {} end
  local gkey = guild.key or (guild.name and ns.Inbox.key(guild.name))
  local g = gkey and db.moments[tostring(gkey)]
  local held = {}
  for ckey, e in pairs(type(g) == "table" and g or {}) do
    if type(ckey) == "string" and type(e) == "table" and type(e.list) == "table" and e.list[1]
        and type(e.stream) == "string" then
      local sound = true
      for _, m in ipairs(e.list) do -- a damaged list is left out whole, never half sent
        if type(m) ~= "table" or type(m.seq) ~= "number" or type(m.at) ~= "number" or type(m.kind) ~= "string" then
          sound = false
          break
        end
      end
      if sound then held[#held + 1] = { ckey = ckey, e = e } end
    end
  end
  table.sort(held, function(a, b) return Order.compareBytes(a.ckey, b.ckey) < 0 end)
  return held
end

-- Local nights newest first, those not yet copied before those already copied (README section 6).
local function nightsOf(held)
  local M, c = ns.Moments.Store, {}
  for hi, h in ipairs(held) do -- (the spans are kept on the held entry for `batches`)
    h.spans = M.nights(h.e.list)
    local marks = type(h.e.copied) == "table" and h.e.copied or {}
    for si, span in ipairs(h.spans) do
      c[#c + 1] = { hi = hi, si = si, span = span, newest = h.e.list[span.to].at,
        first = h.e.list[span.from].seq, copied = marks[h.e.list[span.from].seq] ~= nil }
    end
  end
  table.sort(c, function(a, b)
    if a.copied ~= b.copied then return not a.copied end
    if a.newest ~= b.newest then return a.newest > b.newest end
    if a.hi ~= b.hi then return a.hi < b.hi end
    return a.first < b.first
  end)
  return c
end

-- The batches for the nights of `cands` marked in `pick` ({ [index] = true }): whole nights in seq order, `more` the
-- nights of that character left out. Batches with nothing in them are not sent.
local function batches(held, cands, pick)
  local M, chosen = ns.Moments.Store, {}
  for i, c in ipairs(cands) do
    if pick[i] then
      chosen[c.hi] = chosen[c.hi] or {}
      chosen[c.hi][c.si] = true
    end
  end
  local out, count = Json.array(), 0
  for hi, h in ipairs(held) do
    local sel = chosen[hi]
    if sel then
      local list, nights = {}, 0
      for si, span in ipairs(h.spans) do
        if sel[si] then
          nights = nights + 1
          for j = span.from, span.to do list[#list + 1] = h.e.list[j] end
        end
      end
      count = count + #list
      out[#out + 1] = M.batch(h.e, h.ckey, { list = list, more = #h.spans - nights })
    end
  end
  return out, count
end

-- The guild's changes payload (README, with by, inbox and dismissed added).
-- `opts.noRoster` leaves the roster report out and says so in `leftOut` (what goes first when a string is over its limit).
-- `opts.moments` is the list of batches carried; `opts.noMoments` says they were left out, whole or in part (`leftOut` then
-- starts with "moments", before "roster").
function Export.payload(key, guild, opts)
  local dismissed = {}
  for cid in pairs(guild.dismissed or {}) do dismissed[#dismissed + 1] = cid end
  table.sort(dismissed, function(a, b) return Order.compareBytes(a, b) < 0 end)
  local p = { v = 1, t = "changes", guild = key, changes = Export.changes(guild), dismissed = Json.array(dismissed) }
  local by = guild.by
  if type(by) == "table" and by.roster and by.name then p.by = { roster = by.roster, name = by.name } end
  local inbox = guild.inbox
  if type(inbox) == "table" then p.inbox = { at = inbox.at or 0, rev = inbox.rev or 0, epoch = guild.epoch or 0 } end
  local left = {}
  if opts and opts.noMoments then left[#left + 1] = "moments" end
  if type(guild.report) == "table" then
    if opts and opts.noRoster then left[#left + 1] = "roster" else p.roster = guild.report end
  end
  if #left > 0 then p.leftOut = Json.array(left) end
  if opts and opts.moments and #opts.moments > 0 then p.moments = opts.moments end
  return p
end

-- The packed string for a guild. Over `limits`: nights of moments are left out first (the newest, uncopied ones are kept as
-- many as fit; whole nights only), then all the moments, then the roster report; `leftOut` says what went.
-- Results: the string (or nil and a code), true when the roster was left out, and `info` for the moments:
-- { held = nights held, sent = nights in the string, moments = moments in it, marks = { { e, first }, ... } }.
-- `opts.db` is the saved data the moments are read from; with none, none are carried.
-- The nights chosen last time for a guild, kept while what they depend on has not changed (the tab opens often; a search
-- repacks the string once per night). The cached choice is only tried first: if the string is now too big the search runs again.
local chosenBefore = setmetatable({}, { __mode = "k" })

local function signature(guild, held, limits)
  local parts = { limits and limits.chars or 0, type(guild.report) == "table" and guild.report.at or 0,
    guild.inbox and guild.inbox.rev or 0 }
  local pending = 0
  for _ in pairs(guild.pending or {}) do pending = pending + 1 end
  for _ in pairs(guild.mine and guild.mine.pending or {}) do pending = pending + 1 end
  parts[#parts + 1] = pending
  for _, h in ipairs(held) do
    local marks = 0
    for _ in pairs(type(h.e.copied) == "table" and h.e.copied or {}) do marks = marks + 1 end
    parts[#parts + 1] = h.ckey .. ":" .. h.e.stream .. ":" .. h.e.list[#h.e.list].seq .. ":" .. #h.e.list .. ":" .. marks
  end
  return table.concat(parts, "|")
end

function Export.pack(key, guild, limits, opts)
  local held = Export.heldMoments(opts and opts.db, guild)
  local cands = #held > 0 and nightsOf(held) or {}
  local info = { held = #cands, sent = 0, moments = 0, marks = {} }
  local pack = ns.Pack.pack
  local function count(pick)
    local n = 0
    for i = 1, #cands do if pick[i] then n = n + 1 end end
    return n
  end
  local function done(pick, s, noRoster)
    info.sent = count(pick)
    for i, c in ipairs(cands) do
      if pick[i] then info.marks[#info.marks + 1] = { e = held[c.hi].e, first = c.first } end
    end
    local _, n = batches(held, cands, pick)
    info.moments = n
    if #cands > 0 then
      local ids = {}
      for i, c in ipairs(cands) do if pick[i] then ids[held[c.hi].ckey .. ":" .. c.first] = true end end
      chosenBefore[guild] = { sig = signature(guild, held, limits), ids = ids, noRoster = noRoster }
    end
    return s, nil, noRoster, info
  end
  local function payload(pick, noRoster)
    return Export.payload(key, guild, { moments = count(pick) > 0 and batches(held, cands, pick) or nil,
      noMoments = count(pick) < #cands, noRoster = noRoster })
  end
  local all = {}
  for i = 1, #cands do all[i] = true end
  local s, code = pack(payload(all, false), limits)
  if s then return done(all, s, false) end
  if code ~= "too_large" then return s, code, false, info end
  local before = #cands > 0 and chosenBefore[guild]
  if before and before.sig == signature(guild, held, limits) then
    local pick = {}
    for i, c in ipairs(cands) do pick[i] = before.ids[held[c.hi].ckey .. ":" .. c.first] end
    local t = pack(payload(pick, before.noRoster), limits)
    if t then return done(pick, t, before.noRoster) end
  end
  -- Greedy beside the roster report: a night too big on its own is skipped (and counted in `more`), and later ones are
  -- still tried, so one oversized night never blocks the rest.
  local pick, bs = {}, nil
  for i = 1, #cands do
    pick[i] = true
    local t = pack(payload(pick, false), limits)
    if t then bs = t else pick[i] = nil end
  end
  if bs then return done(pick, bs, false) end
  if #cands > 0 then
    s, code = pack(payload({}, false), limits)
    if s then return done({}, s, false) end
  end
  if code == "too_large" and type(guild.report) == "table" then
    s, code = pack(payload({}, true), limits)
    if s then return done({}, s, true) end
  end
  return s, code, false, info
end

-- Tintean.out for every guild held. Returns out, and { [key] = code } for a guild that could not be packed
-- (it is left out; the app then keeps what it last read for it).
function Export.build(db, now, addon)
  local out = { v = 1, at = now, addon = addon, guilds = {} }
  local failed
  for key, guild in pairs(db.guilds or {}) do
    local ok, s, code = pcall(function() return Export.pack(key, guild, Export.LIMITS, { db = db }) end)
    if not ok then -- the moments on their own: a damaged store never costs the guild's changes
      ok, s, code = pcall(function() return Export.pack(key, guild, Export.LIMITS) end)
      if not ok then s, code = nil, "error" end
    end
    if s then
      out.guilds[key] = s
    else
      failed = failed or {}
      failed[key] = code
    end
  end
  return out, failed
end
