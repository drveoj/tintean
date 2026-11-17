-- The moment store (formats/moments/README.md sections 2, 3 and 6; game.md section 11): what this account has noted and
-- not yet had acknowledged, in `db.moments[<guild key>][<roster key>] = { stream, seq, list, zones, flown, copied, dropped,
-- clock }`. Pure: callers pass the table and the clock. Nothing here reads the game.
-- Saved tables never hold Json.null (only `db.guilds` is frozen at logout): a missing map, zone or sub is nil here and
-- becomes null in Store.batch.
local _, ns = ...
ns = ns or {}
ns.Moments = ns.Moments or {}

local Json, Ids = ns.Json, ns.Ids
local null = Json.null

local Store = {}
ns.Moments.Store = Store

local DAY = 86400
Store.KEEP = 14 * DAY      -- older moments are dropped
Store.GAP = 3600           -- a `party` this long after the last moment begins a new local night
Store.NIGHT_CAP = 300      -- per local night
Store.NIGHT_SOFT = 250     -- past this only the plot kinds are noted
Store.CHAR_CAP = 1500
Store.ACCOUNT_CAP = 4000
Store.ZONES_CAP = 3000
Store.MAX_SEQ = 2147483647

Store.PLOT = {
  party = true, party_end = true, dungeon = true, dungeon_left = true, boss_pull = true, boss_kill = true,
  boss_wipe = true, level = true, death = true, revive = true, res = true, achievement = true, quest_done = true,
}

local function bump(counters, name, n)
  if counters then counters[name] = (counters[name] or 0) + (n or 1) end
end

-- A name or place as the batch carries it: no |-codes, no control characters, at most `max` bytes cut on a character
-- boundary; nil when nothing is left or it is not a string.
function Store.text(s, max)
  if type(s) ~= "string" then return nil end
  s = s:gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|", "")
  s = s:gsub("[%z\1-\31\127]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  max = max or 80
  if #s > max then
    s = s:sub(1, max)
    while #s > 0 and s:byte(#s) >= 128 and s:byte(#s) < 192 do s = s:sub(1, -2) end -- cut inside a character
    if #s > 0 and s:byte(#s) >= 192 then s = s:sub(1, -2) end
    s = s:gsub("%s+$", "")
  end
  if s == "" then return nil end
  return s
end

local function isEntry(e)
  return type(e) == "table" and type(e.stream) == "string" and #e.stream == 16 and type(e.seq) == "number"
    and type(e.list) == "table"
end

-- The moments table for a guild and character; with `create`, made when missing.
function Store.entry(db, gkey, ckey, create)
  if type(db.moments) ~= "table" then
    if not create then return nil end
    db.moments = {}
  end
  gkey = tostring(gkey)
  local g = db.moments[gkey]
  if type(g) ~= "table" then
    if not create then return nil end
    g = {}
    db.moments[gkey] = g
  end
  local e = g[ckey]
  if not isEntry(e) then
    if not create then return nil end
    e = { stream = Ids.cid(), seq = 0, list = {}, zones = {}, flown = false, copied = {}, dropped = 0, clock = "server" }
    g[ckey] = e
  end
  return e
end

-- The local nights of a list, as { from, to } index spans: a `party` 60 minutes or more after the previous moment begins one.
function Store.nights(list)
  local spans, prev = {}, nil
  for i, m in ipairs(list) do
    if not prev or (m.kind == "party" and m.at - prev >= Store.GAP) then
      spans[#spans + 1] = { from = i, to = i }
    else
      spans[#spans].to = i
    end
    prev = m.at
  end
  return spans
end

local function dropSpan(e, span, counters)
  local n = span.to - span.from + 1
  for _ = 1, n do table.remove(e.list, span.from) end
  e.dropped = (e.dropped or 0) + n
  bump(counters, "moments_dropped", n)
end

-- A plain copy (no metatables).
function Store.copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = Store.copy(x) end
  return c
end

Store.WHAT_FIELDS, Store.WHAT_NODES, Store.WHAT_DEPTH = 12, 200, 2

-- `what` as it is kept: plain values only (no functions, no secret-looking or non-finite numbers), at most 12 fields, lists
-- and maps nested at most 2 deep, at most 200 values in all, every string through Store.text (an empty one is left out).
-- Returns the clean copy, or nil when it does not fit.
function Store.cleanWhat(what)
  if type(what) ~= "table" then return nil end
  local nodes, fields = 0, 0
  local function clean(v, depth)
    nodes = nodes + 1
    if nodes > Store.WHAT_NODES then return nil, true end
    local t = type(v)
    if t == "string" then return Store.text(v, 80) end
    if t == "boolean" then return v end
    if t == "number" then
      if v ~= v or v == math.huge or v == -math.huge then return nil, true end
      return v
    end
    if t ~= "table" or depth >= Store.WHAT_DEPTH then return nil, true end
    local out = {}
    for k, x in pairs(v) do
      if type(k) ~= "string" and type(k) ~= "number" then return nil, true end
      local c, bad = clean(x, depth + 1)
      if bad then return nil, true end
      if type(k) == "string" then k = Store.text(k, 40) end
      if k == nil then return nil, true end
      out[k] = c
    end
    return out
  end
  local out = {}
  for k, v in pairs(what) do
    fields = fields + 1
    if fields > Store.WHAT_FIELDS or type(k) ~= "string" then return nil end
    local c, bad = clean(v, 0)
    if bad then return nil end
    out[k] = c
  end
  return out
end

-- Notes one moment: m = { at, kind, p, map, zone, sub, lvl, what }, `clock` "server" or "local". A `party` has no `p`
-- (it is its own seq). Returns its seq, or nil and why ("night_full", "night_soft", "bad", "orphan", "seq").
function Store.note(db, gkey, ckey, m, clock, counters)
  if type(m) ~= "table" or type(m.kind) ~= "string" or not m.kind:find("^[a-z_]+$") or #m.kind > 24
    or type(m.at) ~= "number" or m.at ~= math.floor(m.at) or m.at < 1
    or type(m.lvl) ~= "number" or m.lvl < 1 or m.lvl > 255 or m.lvl ~= math.floor(m.lvl) or type(m.what) ~= "table" then
    return nil, "bad"
  end
  if m.kind ~= "party" and type(m.p) ~= "number" then return nil, "orphan" end
  local what = Store.cleanWhat(m.what)
  if not what then
    bump(counters, "moments_refused")
    return nil, "bad"
  end
  local e = Store.entry(db, gkey, ckey, true)
  if e.seq >= Store.MAX_SEQ then return nil, "seq" end
  local list = e.list
  local spans = Store.nights(list)
  local last, count = list[#list], 0
  local fresh = m.kind == "party" and (not last or m.at - last.at >= Store.GAP)
  if not fresh and #spans > 0 then count = spans[#spans].to - spans[#spans].from + 1 end
  local why = (count >= Store.NIGHT_CAP and "night_full") or (count >= Store.NIGHT_SOFT and not Store.PLOT[m.kind] and "night_soft") or nil
  if why then
    e.dropped = (e.dropped or 0) + 1
    bump(counters, "moments_refused")
    return nil, why
  end
  e.seq = e.seq + 1
  if #list == 0 then e.clock = clock or "server" elseif e.clock ~= clock then e.clock = "local" end
  list[#list + 1] = { seq = e.seq, at = m.at, kind = m.kind, p = m.kind == "party" and e.seq or m.p,
    map = type(m.map) == "number" and m.map or nil, zone = Store.text(m.zone), sub = Store.text(m.sub), lvl = m.lvl, what = what }
  Store.enforce(db, counters)
  return e.seq
end

-- Every held moment of every stream: the oldest local night goes first over a cap (per character, then per account),
-- and it is counted.
function Store.enforce(db, counters)
  local total, entries = 0, {}
  for _, g in pairs(type(db.moments) == "table" and db.moments or {}) do
    for _, e in pairs(type(g) == "table" and g or {}) do
      if isEntry(e) then
        if #e.list > Store.CHAR_CAP then
          local spans = Store.nights(e.list)
          while #e.list > Store.CHAR_CAP and #spans > 1 do
            dropSpan(e, spans[1], counters)
            spans = Store.nights(e.list)
          end
        end
        total = total + #e.list
        entries[#entries + 1] = e
      end
    end
  end
  while total > Store.ACCOUNT_CAP do
    local oldest, at, span
    for _, e in ipairs(entries) do
      local spans = Store.nights(e.list)
      if #spans > 1 and (not at or e.list[1].at < at) then oldest, at, span = e, e.list[1].at, spans[1] end
    end
    if not oldest then break end
    total = total - (span.to - span.from + 1)
    dropSpan(oldest, span, counters)
  end
end

-- `acks` as the inbox and the web snapshot give them: { { stream, acked }, ... }. Drops seq <= acked from the stream
-- it names. Returns how many moments went.
function Store.ack(db, acks, counters)
  local n = 0
  if type(acks) ~= "table" or type(db.moments) ~= "table" then return 0 end
  for _, a in ipairs(acks) do
    local acked = type(a) == "table" and type(a.acked) == "number" and a.acked
    -- Not finite, negative, or above any seq this stream issued: ignored (a seq above ours was never ours to drop).
    if type(a) == "table" and type(a.stream) == "string" and acked and acked == acked and acked >= 0
        and acked < math.huge then
      acked = math.floor(acked)
      for _, g in pairs(db.moments) do
        for _, e in pairs(type(g) == "table" and g or {}) do
          if isEntry(e) and e.stream == a.stream and acked <= e.seq then
            local keep = {}
            for _, m in ipairs(e.list) do
              if m.seq > acked then keep[#keep + 1] = m else n = n + 1 end
            end
            e.list = keep
          end
        end
      end
    end
  end
  bump(counters, "moments_acked", n)
  return n
end

-- At login and after each inbox read: shape repair, the switch, age, caps, first-entry memory.
function Store.prune(db, now, counters)
  if type(db.settings) == "table" and db.settings.moments == false then db.moments = {}; return end
  if type(db.moments) ~= "table" then db.moments = {}; return end
  for gk, g in pairs(db.moments) do
    if type(g) ~= "table" then
      db.moments[gk] = nil
    else
      for ck, e in pairs(g) do
        if not isEntry(e) then
          g[ck] = nil
          bump(counters, "moments_damaged")
        else
          local keep = {}
          for _, m in ipairs(e.list) do
            if type(m) == "table" and type(m.at) == "number" and type(m.seq) == "number" then
              if m.at >= now - Store.KEEP then keep[#keep + 1] = m else e.dropped = (e.dropped or 0) + 1 end
            end
          end
          e.list = keep
          if type(e.zones) ~= "table" then e.zones = {} end
          if type(e.copied) ~= "table" then e.copied = {} end
          for first in pairs(e.copied) do -- a mark for a night that has gone
            if type(first) ~= "number" or not e.list[1] or first < e.list[1].seq then e.copied[first] = nil end
          end
          local n = 0
          for k in pairs(e.zones) do
            n = n + 1
            if n > Store.ZONES_CAP then e.zones[k] = nil end
          end
        end
      end
    end
  end
  Store.enforce(db, counters)
end

-- Turning the switch off: nothing held stays.
function Store.clear(db) db.moments = {} end

-- `what` fields the format says are null when the game gave nothing (saved data holds nil).
Store.NULLABLE = { quest_accepted = { "line" }, quest_done = { "line" }, bg = { "result" }, res = { "from", "to", "other" } }

-- The batch for one character's entry (README section 2), every held moment.
-- `opts.list` is a chosen part of the held list (whole local nights, for a paste) and `opts.more` the nights left out;
-- `from` is still the lowest seq held, so the server sees what is missing.
function Store.batch(e, ckey, opts)
  local list = Json.array()
  for _, m in ipairs(opts and opts.list or e.list) do
    -- Saved data loses the array marker (an empty list would encode as {}), so lists are marked again here.
    local what = m.what
    if type(what) == "table" then
      what = Store.copy(what)
      for _, f in ipairs({ "keys", "others" }) do
        if type(what[f]) == "table" then what[f] = Json.array(what[f]) end
      end
      for _, f in ipairs(Store.NULLABLE[m.kind] or {}) do
        if what[f] == nil then what[f] = null end
      end
    end
    list[#list + 1] = { seq = m.seq, at = m.at, kind = m.kind, p = m.p, map = m.map or null, zone = m.zone or null,
      sub = m.sub or null, lvl = m.lvl, what = what }
  end
  return { v = 1, stream = e.stream, char = ckey, clock = e.clock or "server", from = e.list[1] and e.list[1].seq or e.seq + 1,
    more = opts and opts.more or 0, dropped = e.dropped or 0, list = list }
end

-- Totals for /tintean check: streams, held, dropped, and the clocks in use.
function Store.summary(db)
  local s = { streams = 0, held = 0, dropped = 0, clocks = {} }
  for _, g in pairs(type(db.moments) == "table" and db.moments or {}) do
    for _, e in pairs(type(g) == "table" and g or {}) do
      if isEntry(e) then
        s.streams, s.held, s.dropped = s.streams + 1, s.held + #e.list, s.dropped + (e.dropped or 0)
        s.clocks[e.clock or "server"] = true
      end
    end
  end
  return s
end

return Store
