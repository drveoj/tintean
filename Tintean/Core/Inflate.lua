-- Raw deflate decoder (RFC 1951): stored, fixed and dynamic Huffman blocks, written
-- from the published description. Plain arithmetic, no game API.
-- Inflate.inflate(data, cap) -> string, or nil, reason
--   reason "too_big": the output would pass `cap` bytes (stops there; never builds more)
--   reason "bad_deflate": cut short, or not valid deflate.
-- Errors are returned, never thrown.
local _, ns = ...
ns = ns or {}

local Inflate = {}
ns.Inflate = Inflate

Inflate.DEFAULT_CAP = 1048576
-- Work limits: the output cap does not bound the time a stream of many tiny dynamic blocks
-- costs (each builds decoding tables), so a stream may hold this many dynamic blocks, and
-- these many table entries built in all. Real zlib level-9 data of 1 MiB uses a small part.
Inflate.MAX_DYNAMIC_BLOCKS = 256
Inflate.TABLE_BUDGET = 4194304 -- 2^22

local sbyte, schar, concat = string.byte, string.char, table.concat
local unpack, floor = unpack, math.floor

local pow2 = {}
for i = 0, 31 do pow2[i] = 2 ^ i end

local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- A decoding table for lengths[first .. first+count-1]: tab[next maxlen bits, first bit lowest]
-- = symbol * 16 + code length. Returns tab, maxlen; nil if the code is over-subscribed or, as
-- in zlib, incomplete (except a lone code of length 1 in a length or distance tree, and no
-- codes at all). `isCl`: the code-length code, which must be complete.
local function build(lengths, first, count, isCl)
  local cnt = { [0] = 0 }
  for l = 1, 15 do cnt[l] = 0 end
  local maxlen = 0
  for i = first, first + count - 1 do
    local l = lengths[i]
    if l > 0 then
      cnt[l] = cnt[l] + 1
      if l > maxlen then maxlen = l end
    end
  end
  local left = 1
  for l = 1, 15 do
    left = left * 2 - cnt[l]
    if left < 0 then return nil end
  end
  if left > 0 and maxlen > 0 and (isCl or maxlen ~= 1) then return nil end
  local nextc, code = {}, 0
  for l = 1, 15 do
    code = (code + cnt[l - 1]) * 2
    nextc[l] = code
  end
  local tab, size = {}, pow2[maxlen]
  for i = first, first + count - 1 do
    local l = lengths[i]
    if l > 0 then
      local c = nextc[l]
      nextc[l] = c + 1
      local r = 0
      for _ = 1, l do
        r = r * 2 + c % 2
        c = floor(c / 2)
      end
      local entry = (i - first) * 16 + l
      for k = r, size - 1, pow2[l] do tab[k] = entry end
    end
  end
  return tab, maxlen
end

local fixed -- built on first use: { lt, lm, dt, dm }
local function fixedTables()
  if not fixed then
    local ll = {}
    for i = 1, 144 do ll[i] = 8 end
    for i = 145, 256 do ll[i] = 9 end
    for i = 257, 280 do ll[i] = 7 end
    for i = 281, 288 do ll[i] = 8 end
    local dl = {}
    for i = 1, 32 do dl[i] = 5 end -- 30 and 31 are never valid; decoding one is refused
    local lt, lm = build(ll, 1, 288)
    local dt, dm = build(dl, 1, 32)
    fixed = { lt, lm, dt, dm }
  end
  return fixed
end

local function bad() error("bad_deflate", 0) end
local function big() error("too_big", 0) end

local function run(data, cap)
  local len = #data
  local pos, buf, cnt, pad = 1, 0, 0, 0 -- buf holds cnt bits, `pad` of them past the end of data
  local out, n = {}, 0
  local dynamic, budget = 0, Inflate.TABLE_BUDGET

  local function need(k)
    while cnt < k do
      local b = sbyte(data, pos)
      if b then pos = pos + 1 else pad = pad + 8; b = 0 end
      buf = buf + b * pow2[cnt]
      cnt = cnt + 8
    end
  end

  local function take(k)
    if k == 0 then return 0 end
    need(k)
    if cnt - k < pad then bad() end
    local v = buf % pow2[k]
    buf = (buf - v) / pow2[k]
    cnt = cnt - k
    return v
  end

  local function decode(tab, maxlen)
    need(maxlen)
    local e = tab[buf % pow2[maxlen]]
    if not e then bad() end
    local l = e % 16
    if cnt - l < pad then bad() end
    buf = floor(buf / pow2[l])
    cnt = cnt - l
    return (e - l) / 16
  end

  local final
  repeat
    final = take(1)
    local typ = take(2)
    if typ == 0 then
      -- Back to the byte boundary, then LEN, NLEN and the bytes themselves.
      local real = cnt - pad
      pos = pos - floor(real / 8)
      buf, cnt, pad = 0, 0, 0
      if pos + 3 > len then bad() end
      local a, b, c, d = sbyte(data, pos, pos + 3)
      local l = a + b * 256
      if l + c + d * 256 ~= 65535 then bad() end
      pos = pos + 4
      if pos + l - 1 > len then bad() end
      if n + l > cap then big() end
      local i = pos
      local stop = pos + l - 1
      while i <= stop do
        local last = i + 4095
        if last > stop then last = stop end
        local bytes = { sbyte(data, i, last) }
        for k = 1, #bytes do out[n + k] = bytes[k] end
        n = n + #bytes
        i = last + 1
      end
      pos = pos + l
    elseif typ == 3 then
      bad()
    else
      local lt, lm, dt, dm
      if typ == 1 then
        local f = fixedTables()
        lt, lm, dt, dm = f[1], f[2], f[3], f[4]
      else
        dynamic = dynamic + 1
        if dynamic > Inflate.MAX_DYNAMIC_BLOCKS then bad() end
        local hlit = take(5) + 257
        local hdist = take(5) + 1
        local hclen = take(4) + 4
        if hlit > 286 or hdist > 30 then bad() end
        local cl = {}
        for i = 1, 19 do cl[i] = 0 end
        for i = 1, hclen do cl[ORDER[i] + 1] = take(3) end
        local ct, cm = build(cl, 1, 19, true)
        if not ct then bad() end
        local lengths, i, total = {}, 1, hlit + hdist
        while i <= total do
          local sym = decode(ct, cm)
          if sym < 16 then
            lengths[i] = sym
            i = i + 1
          else
            local prev, rep = 0
            if sym == 16 then
              if i == 1 then bad() end
              prev = lengths[i - 1]
              rep = 3 + take(2)
            elseif sym == 17 then
              rep = 3 + take(3)
            else
              rep = 11 + take(7)
            end
            if i + rep - 1 > total then bad() end
            for _ = 1, rep do
              lengths[i] = prev
              i = i + 1
            end
          end
        end
        if lengths[257] == 0 then bad() end
        lt, lm = build(lengths, 1, hlit)
        dt, dm = build(lengths, hlit + 1, hdist)
        if not lt or not dt then bad() end
        budget = budget - pow2[lm] - pow2[dm] - total
        if budget < 0 then bad() end
      end
      while true do
        local sym = decode(lt, lm)
        if sym < 256 then
          n = n + 1
          if n > cap then big() end
          out[n] = sym
        elseif sym == 256 then
          break
        else
          sym = sym - 256
          if sym > 29 then bad() end
          local length = LBASE[sym] + take(LEXT[sym])
          local ds = decode(dt, dm) + 1
          if ds > 30 then bad() end
          local dist = DBASE[ds] + take(DEXT[ds])
          if dist > n then bad() end
          if n + length > cap then big() end
          for k = 1, length do out[n + k] = out[n + k - dist] end
          n = n + length
        end
      end
    end
  until final == 1

  local parts = {}
  for i = 1, n, 4096 do
    local last = i + 4095
    if last > n then last = n end
    parts[#parts + 1] = schar(unpack(out, i, last))
  end
  return concat(parts)
end

function Inflate.inflate(data, cap)
  if type(data) ~= "string" then return nil, "bad_deflate" end
  local ok, res = pcall(run, data, cap or Inflate.DEFAULT_CAP)
  if ok then return res end
  if res == "too_big" then return nil, "too_big" end
  return nil, "bad_deflate"
end
