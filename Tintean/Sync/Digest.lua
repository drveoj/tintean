-- The digest (formats/game.md section 7; fixture game/digest.json). Pure: nothing here reads the game.
--   d[kind] = { cursor, floor, top, count, crc }   count and crc over live server versions with rev <= cursor
--   pd      = { count, crc }                        over my pending cids
-- Digest.build(guild) -> { d, pd };  Digest.parse(d, pd) -> a peer's digest or nil;  Digest.compare(mine, theirs).
local _, ns = ...
ns = ns or {}

local Digest = {}
ns.Digest = Digest

local Json, Store, Order, Crc32 = ns.Json, ns.Store, ns.Order, ns.Crc32
local KINDS = Store.KINDS
local MAX_INT = 9007199254740991
local ZERO_CRC = "00000000"

local function bytesLess(a, b) return Order.compareBytes(a, b) < 0 end

local function over(lines)
  table.sort(lines, bytesLess)
  return #lines, Crc32.hex(table.concat(lines))
end

-- A guild is the table Store keeps; nil gives the digest of nothing.
function Digest.build(guild)
  local lines, top, floor, cursor = {}, {}, {}, {}
  for _, k in ipairs(KINDS) do lines[k] = {} end
  if guild then
    for _, r in pairs(guild.records) do
      local l = lines[r.kind]
      if l then
        if (top[r.kind] or 0) < r.rev then top[r.kind] = r.rev end
        if not r.deleted and r.rev <= (guild.cursor[r.kind] or 0) then l[#l + 1] = r.id .. " " .. r.rev .. "\n" end
      end
    end
    cursor, floor = guild.cursor or cursor, guild.floor or floor
  end
  local d = {}
  for _, k in ipairs(KINDS) do
    local n, crc = over(lines[k])
    d[k] = { cursor[k] or 0, floor[k] or 0, top[k] or 0, n, crc }
  end
  local cids = {}
  if guild then
    for _, p in pairs(guild.pending) do
      if not p.unchecked then cids[#cids + 1] = p.cid .. "\n" end -- an unchecked edit is not offered
    end
  end
  local n, crc = over(cids)
  return { d = d, pd = { n, crc } }
end

local function int(x) return type(x) == "number" and x == math.floor(x) and x >= 0 and x <= MAX_INT end
local function crc(x) return type(x) == "string" and x:find("^%x%x%x%x%x%x%x%x$") ~= nil and x == x:lower() end

-- A peer's d and pd as received (either may be missing: zeros). Kinds I don't know are ignored.
-- Returns { d = ..., pd = ... }, or nil, "bad_digest".
function Digest.parse(d, pd)
  local out = { d = {}, pd = { 0, ZERO_CRC } }
  for _, k in ipairs(KINDS) do out.d[k] = { 0, 0, 0, 0, ZERO_CRC } end
  if d ~= nil and d ~= Json.null then
    if type(d) ~= "table" or Json.isArray(d) then return nil, "bad_digest" end
    for _, k in ipairs(KINDS) do
      local e = d[k]
      if e ~= nil then
        if type(e) ~= "table" or #e ~= 5 or not (int(e[1]) and int(e[2]) and int(e[3]) and int(e[4]) and crc(e[5])) then
          return nil, "bad_digest"
        end
        out.d[k] = { e[1], e[2], e[3], e[4], e[5] }
      end
    end
  end
  if pd ~= nil and pd ~= Json.null then
    if type(pd) ~= "table" or #pd ~= 2 or not int(pd[1]) or not crc(pd[2]) then return nil, "bad_digest" end
    out.pd = { pd[1], pd[2] }
  end
  return out
end

-- Per kind, mine against theirs. Cursors equal and count or crc different is inconsistent, and only that;
-- otherwise the higher cursor is ahead, and on equal cursors the higher top (a relayed record above it).
-- A top above a lower cursor counts for nothing: whoever has the higher cursor can fill that gap.
function Digest.compare(mine, theirs)
  local r = { ahead = {}, behind = {}, inconsistent = {}, pendingDiffer = false }
  for _, k in ipairs(KINDS) do
    local a, b = mine.d[k], theirs.d[k]
    if a[1] == b[1] and (a[4] ~= b[4] or a[5] ~= b[5]) then
      r.inconsistent[#r.inconsistent + 1] = k
    else
      if a[1] > b[1] or (a[1] == b[1] and a[3] > b[3]) then r.ahead[#r.ahead + 1] = k end
      if b[1] > a[1] or (a[1] == b[1] and b[3] > a[3]) then r.behind[#r.behind + 1] = k end
    end
  end
  r.pendingDiffer = mine.pd[1] ~= theirs.pd[1] or mine.pd[2] ~= theirs.pd[2]
  return r
end

-- One string for "the same digest" (heard hello against mine).
function Digest.fingerprint(x)
  local t = {}
  for _, k in ipairs(KINDS) do t[#t + 1] = table.concat(x.d[k], ",") end
  return table.concat(t, ";") .. "|" .. x.pd[1] .. "," .. x.pd[2]
end

return Digest
