-- The shape check for one change (formats/README.md; a port of the server's
-- app/src/lib/sync/validate.ts). Pure. Checks names the field and never the value.
--   Validate.check(raw, now) ->
--     { ok = true, change = <normalised> }
--   | { ok = false, field = "body.title", cid = <cid or nil>, ref = { kind, id, base } or nil }
--   | { skip = true, cid = <cid or nil> }        (an unknown kind: ignored and counted by the caller)
-- Values come from Json.decode: null is Json.null, absent is nil.
local _, ns = ...
ns = ns or {}

local Validate = {}
ns.Validate = Validate

local Json = ns.Json
local null = Json.null
local sfind, sbyte, srep, sgsub = string.find, string.byte, string.rep, string.gsub
local floor = math.floor

Validate.WINDOW_DAYS = 14
Validate.MAX_CHANGE_CHARS = 16384
Validate.MAX_DEPTH = 8
Validate.ACTIVITIES = { levelling = true, dungeon = true, raid = true, quest_chain = true, pvp = true,
  profession = true, social = true, other = true }

local HEX = "[0-9a-f]"
local UUID = "^" .. srep(HEX, 8) .. "%-" .. srep(HEX, 4) .. "%-" .. srep(HEX, 4) .. "%-" .. srep(HEX, 4) .. "%-" .. srep(HEX, 12) .. "$"
local UUID_PART = srep(HEX, 8) .. "%-" .. srep(HEX, 4) .. "%-" .. srep(HEX, 4) .. "%-" .. srep(HEX, 4) .. "%-" .. srep(HEX, 12)
-- "<event or bulletin id>:<roster key>": a roster key never holds a colon, so the ":c:" and ":p:" forms do not match.
local SIGNUP_ID = "^(" .. UUID_PART .. "):(.+)$"

local function isUuid(v) return type(v) == "string" and sfind(v, UUID) ~= nil end
-- The roster key's shape (formats/README.md, Roster keys): 2 to 64 bytes, no byte up to the space except single spaces
-- between words, no ":" or "|", no ASCII capital. Bytes above 127 are the game's own UTF-8 and pass.
local function isRosterKey(v)
  return type(v) == "string" and #v >= 2 and #v <= 64 and not sfind(v, "[%z\1-\31:|A-Z]")
    and not sfind(v, "^ ") and not sfind(v, " $") and not sfind(v, "  ")
end
local function isCid(v) return type(v) == "string" and #v >= 8 and #v <= 40 and sfind(v, "^[A-Za-z0-9_%-]+$") ~= nil end
local function isWarningRef(v) return type(v) == "string" and #v == 16 and sfind(v, "^[A-Za-z0-9_%-]+$") ~= nil end

local function isArray(v)
  if type(v) ~= "table" or v == null then return false end
  return Json.isArray(v) or (not Json.isObject(v) and v[1] ~= nil)
end
local function isObj(v) return type(v) == "table" and v ~= null and not isArray(v) end
local function isInt(v) return type(v) == "number" and v == floor(v) and v > -math.huge and v < math.huge end
local function isSec(v) return isInt(v) and v >= 0 and v <= 9999999999 end
local function has(o, k) return o[k] ~= nil end

-- Characters, not bytes (UTF-8: skip continuation bytes).
local function len(s)
  local n = 0
  for i = 1, #s do
    local b = sbyte(s, i)
    if b < 128 or b >= 192 then n = n + 1 end
  end
  return n
end

local function hasControl(s)
  for i = 1, #s do
    local b = sbyte(s, i)
    if b <= 8 or (b >= 11 and b <= 31) or b == 127 then return true end
  end
  return false
end

-- Trim: the set JS .trim() removes, found by a linear scan from each end (no patterns, no locale).
local WS3 = { ["\225\154\128"] = true, ["\226\128\168"] = true, ["\226\128\169"] = true, ["\226\128\175"] = true,
  ["\226\129\159"] = true, ["\227\128\128"] = true, ["\239\187\191"] = true }
for b = 0x80, 0x8A do WS3["\226\128" .. string.char(b)] = true end
local ssub = string.sub

local function isAsciiWs(b) return b == 32 or (b >= 9 and b <= 13) end

-- Length of a whitespace character starting at byte i, or 0.
local function wsAt(s, i)
  local b = sbyte(s, i)
  if isAsciiWs(b) then return 1 end
  if b == 194 and sbyte(s, i + 1) == 160 then return 2 end
  if b >= 225 and WS3[ssub(s, i, i + 2)] then return 3 end
  return 0
end

-- Length of a whitespace character ending at byte j (not before byte lo), or 0.
local function wsEnd(s, j, lo)
  if isAsciiWs(sbyte(s, j)) then return 1 end
  if j - 1 >= lo and sbyte(s, j - 1) == 194 and sbyte(s, j) == 160 then return 2 end
  if j - 2 >= lo and WS3[ssub(s, j - 2, j)] then return 3 end
  return 0
end

local function trim(s)
  local i, j = 1, #s
  while i <= j do
    local n = wsAt(s, i)
    if n == 0 then break end
    i = i + n
  end
  while j >= i do
    local n = wsEnd(s, j, i)
    if n == 0 then break end
    j = j - n
  end
  return ssub(s, i, j)
end
Validate.trim = trim

-- Trimmed text of min..max characters, no control characters other than newline and tab; else nil.
local function text(v, max, min)
  if type(v) ~= "string" then return nil end
  local t = trim((sgsub(v, "\r\n", "\n")))
  if hasControl(t) then return nil end
  local n = len(t)
  if n >= (min or 0) and n <= max then return t end
  return nil
end

-- Size of v as JSON in UTF-16 units (an astral character is 2), without refusing anything:
-- a float or NaN in a key that is ignored only counts. Stops early once past `limit`.
local function jsonSize(v, limit)
  local total = 0
  local function add(n) total = total + n end
  local function str(s)
    add(2)
    for i = 1, #s do
      local b = sbyte(s, i)
      if b == 34 or b == 92 or b == 8 or b == 9 or b == 10 or b == 12 or b == 13 then add(2)
      elseif b < 32 then add(6)
      elseif b < 128 or (b >= 192 and b < 240) then add(1)
      elseif b >= 240 then add(2) end
    end
  end
  local function walk(x)
    if total > limit then return end
    local t = type(x)
    if x == null or x == nil then add(4)
    elseif t == "string" then str(x)
    elseif t == "number" then add(#tostring(x))
    elseif t == "boolean" then add(x and 4 or 5)
    elseif t == "table" then
      if isArray(x) then
        add(2)
        for k = 1, #x do add(1); walk(x[k]) end
      else
        add(2)
        for k, y in pairs(x) do add(2); str(tostring(k)); walk(y) end
      end
    end
  end
  walk(v)
  return total
end

-- Whether v nests deeper than max (stops looking at max).
local function deeper(v, max)
  if type(v) ~= "table" or v == null then return false end
  if max <= 0 then return true end
  for _, x in pairs(v) do
    if deeper(x, max - 1) then return true end
  end
  return false
end

function Validate.cidOf(raw)
  if isObj(raw) and isCid(raw.cid) then return raw.cid end
  return nil
end

local KINDS = { event = true, signup = true, bulletin = true, roster = true, seen = true, ranks = true }
Validate.KINDS = KINDS

function Validate.idOk(kind, id)
  if type(id) ~= "string" then return false end
  if kind == "signup" or kind == "seen" then return Validate.splitSignupId(id) ~= nil end
  if kind == "ranks" then return id == "ranks" end
  if kind == "roster" then return isRosterKey(id) end
  return sfind(id, UUID) ~= nil
end

-- "<event or bulletin id>:<roster key>" -> event, roster (or nil).
function Validate.splitSignupId(id)
  local a, b = id:match(SIGNUP_ID)
  if a and isRosterKey(b) then return a, b end
  return nil
end

local function bad(field) return nil, field end

local function eventBody(b, create, now)
  local out = {}
  if create then
    for _, k in ipairs({ "title", "activity", "starts", "minutes" }) do
      if b[k] == nil or b[k] == null then return bad("body." .. k) end
    end
  end
  if has(b, "title") then
    local t = text(b.title, 80, 1)
    if t == nil then return bad("body.title") end
    out.title = t
  end
  if has(b, "activity") then
    if type(b.activity) ~= "string" or not Validate.ACTIVITIES[b.activity] then return bad("body.activity") end
    out.activity = b.activity
  end
  if has(b, "starts") then
    if not isSec(b.starts) then return bad("body.starts") end
    out.starts = b.starts
  end
  if has(b, "minutes") then
    if not isInt(b.minutes) or b.minutes < 15 or b.minutes > 720 then return bad("body.minutes") end
    out.minutes = b.minutes
  end
  if has(b, "size") then
    if b.size ~= null and b.size ~= 5 and b.size ~= 10 and b.size ~= 20 then return bad("body.size") end
    out.size = b.size
  end
  if has(b, "want") then
    local w = b.want
    if w ~= null then
      if not isObj(w) then return bad("body.want") end
      local n = {}
      for _, r in ipairs({ "tank", "healer", "dps" }) do
        local v = w[r]
        if v == nil then v = null end
        if v ~= null and (not isInt(v) or v < 0 or v > 40) then return bad("body.want") end
        n[r] = v
      end
      out.want = Json.object(n)
    else
      out.want = null
    end
  end
  if has(b, "notes") then
    if b.notes == null then
      out.notes = null
    else
      local t = text(b.notes, 2000, 0)
      if t == nil then return bad("body.notes") end
      out.notes = t ~= "" and t or null
    end
  end
  if has(b, "cancelled") then
    if type(b.cancelled) ~= "boolean" then return bad("body.cancelled") end
    out.cancelled = b.cancelled
  end
  if has(b, "place") then
    local p = b.place
    if p ~= null and not (isObj(p) and isUuid(p.ref)) then return bad("body.place") end
    out.place = p == null and null or Json.object({ ref = p.ref })
  end
  -- A group's event is made on the web, never in game.
  if has(b, "group") and b.group ~= null then return bad("body.group") end
  if out.want and out.want ~= null and out.size and out.size ~= null then
    local sum = 0
    for _, r in ipairs({ "tank", "healer", "dps" }) do
      local v = out.want[r]
      if v ~= null then sum = sum + v end
    end
    if sum > out.size then return bad("body.want") end
  end
  -- The window: an event that ended more than 14 days ago is not synced at all.
  if out.starts ~= nil and out.starts + (out.minutes or 0) * 60 < now - Validate.WINDOW_DAYS * 86400 then
    return bad("body.starts")
  end
  return out
end

local function signupBody(b, create, id)
  local event, roster = Validate.splitSignupId(id)
  local out = {}
  if create then
    for _, k in ipairs({ "event", "roster", "status" }) do
      if not has(b, k) then return bad("body." .. k) end
    end
  end
  if has(b, "event") then
    if b.event ~= event then return bad("body.event") end
    out.event = b.event
  end
  if has(b, "roster") then
    if b.roster ~= roster then return bad("body.roster") end
    out.roster = b.roster
  end
  if has(b, "status") then
    if b.status ~= "yes" and b.status ~= "no" and b.status ~= "maybe" then return bad("body.status") end
    out.status = b.status
  end
  if has(b, "role") then
    if b.role ~= null and b.role ~= "tank" and b.role ~= "healer" and b.role ~= "dps" then return bad("body.role") end
    out.role = b.role
  end
  if has(b, "note") then
    if b.note == null then
      out.note = null
    else
      local t = text(b.note, 200, 0)
      if t == nil then return bad("body.note") end
      out.note = t ~= "" and t or null
    end
  end
  return out
end

local function seenBody(b, id)
  local bulletin, roster = Validate.splitSignupId(id)
  if b.bulletin ~= bulletin then return bad("body.bulletin") end
  if b.roster ~= roster then return bad("body.roster") end
  return { bulletin = b.bulletin, roster = b.roster }
end

-- The game's rank names in rank order: one to ten, each 1 to 40 characters or null.
local function ranksBody(b, create)
  if has(b, "officer") then return bad("body.officer") end
  if not has(b, "names") then
    if create then return bad("body.names") end
    return {}
  end
  local n = b.names
  if not isArray(n) or #n < 1 or #n > 10 then return bad("body.names") end
  local names = {}
  for i = 1, #n do
    local x = n[i]
    if x == null then
      names[i] = null
    else
      local t = text(x, 40, 1)
      if t == nil then return bad("body.names") end
      names[i] = t
    end
  end
  return { names = Json.array(names) }
end

local function bulletinBody(b, create, now)
  local out = {}
  if create then
    for _, k in ipairs({ "title", "text" }) do
      if not has(b, k) then return bad("body." .. k) end
    end
  end
  if has(b, "title") then
    local t = text(b.title, 80, 1)
    if t == nil then return bad("body.title") end
    out.title = t
  end
  if has(b, "text") then
    local t = text(b.text, 600, 1)
    if t == nil then return bad("body.text") end
    out.text = t
  end
  if has(b, "event") then
    if b.event ~= null and not isUuid(b.event) then return bad("body.event") end
    out.event = b.event
  end
  if has(b, "pinned") then
    if type(b.pinned) ~= "boolean" then return bad("body.pinned") end
    out.pinned = b.pinned
  end
  if has(b, "expires") then
    if b.expires ~= null and (not isSec(b.expires) or b.expires <= now) then return bad("body.expires") end
    out.expires = b.expires
  end
  return out
end

-- `now` is the clock in whole epoch seconds. Step 1 (unknown kind) comes first, then step 2 (shape).
function Validate.check(raw, now)
  local cid = Validate.cidOf(raw)
  if not isObj(raw) then return { ok = false, field = "change" } end
  local kind
  if type(raw.kind) == "string" and not KINDS[raw.kind] then return { skip = true, cid = cid } end
  if type(raw.kind) == "string" then kind = raw.kind end
  local base = (isInt(raw.base) and raw.base >= 0 and raw.base <= 9007199254740991) and raw.base or nil
  local idGood = kind ~= nil and Validate.idOk(kind, raw.id)
  local function fail(field)
    return { ok = false, field = field, cid = cid,
      ref = (kind and idGood) and { kind = kind, id = raw.id, base = base } or nil }
  end

  if cid == nil then return fail("cid") end
  if kind == nil then return fail("kind") end
  if not idGood then return fail("id") end
  if base == nil then return fail("base") end
  -- A seen is a create only (a deletion too: it is base above 0 as well).
  if kind == "seen" and base ~= 0 then return fail("base") end
  local create = base == 0
  local prev = null
  if create then
    if raw.prev ~= nil and raw.prev ~= null then return fail("prev") end
  else
    if not isCid(raw.prev) then return fail("prev") end
    prev = raw.prev
  end
  -- M28: optional; a whole number from 0 (the epoch the client held).
  local epoch
  if has(raw, "epoch") then
    if not isInt(raw.epoch) or raw.epoch < 0 or raw.epoch > 9007199254740991 then return fail("epoch") end
    epoch = raw.epoch
  end
  local a = raw.author
  if not isObj(a) then return fail("author") end
  if not isRosterKey(a.roster) then return fail("author.roster") end
  if type(a.name) ~= "string" or len(a.name) > 80 or hasControl(a.name) then return fail("author.name") end
  if not isSec(raw.at) then return fail("at") end
  if type(raw.deleted) ~= "boolean" then return fail("deleted") end
  if create and raw.deleted then return fail("deleted") end
  -- The guild's rank names are never deleted.
  if kind == "ranks" and raw.deleted then return fail("deleted") end
  if raw.deleted then
    if raw.body ~= nil and raw.body ~= null then return fail("body") end
  elseif not isObj(raw.body) then
    return fail("body")
  end
  if deeper(raw, Validate.MAX_DEPTH) then return fail("body") end
  if jsonSize(raw, Validate.MAX_CHANGE_CHARS) > Validate.MAX_CHANGE_CHARS then return fail("body") end

  local body = null
  if not raw.deleted then
    local b = raw.body
    local r, field
    if kind == "event" then r, field = eventBody(b, create, now)
    elseif kind == "signup" then r, field = signupBody(b, create, raw.id)
    elseif kind == "bulletin" then r, field = bulletinBody(b, create, now)
    elseif kind == "seen" then r, field = seenBody(b, raw.id)
    elseif kind == "ranks" then r, field = ranksBody(b, create)
    else r = b end
    if r == nil then return fail(field) end
    body = r
  end
  local ack
  if kind == "signup" and has(raw, "ack") then
    local k = raw.ack
    if not isArray(k) or #k < 1 or #k > 10 then return fail("ack") end
    for i = 1, #k do
      if not isWarningRef(k[i]) then return fail("ack") end
    end
    ack = k
  end
  local change = {
    cid = cid, id = raw.id, kind = kind, base = base, prev = prev, epoch = epoch,
    author = { roster = a.roster, name = trim(a.name) },
    at = raw.at, deleted = raw.deleted, body = body, ack = ack,
  }
  return { ok = true, change = change }
end

-- The checks above, for the inbox reader's server-record shapes (Sync/Inbox.lua).
Validate.is = { uuid = isUuid, rosterKey = isRosterKey, cid = isCid, warningRef = isWarningRef, obj = isObj, array = isArray, int = isInt, sec = isSec }
Validate.text, Validate.len, Validate.hasControl = text, len, hasControl
