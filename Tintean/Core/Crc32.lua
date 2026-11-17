-- CRC-32 (the usual zlib one: polynomial 0xEDB88320, reflected), table-driven over
-- the game's `bit` library. Crc32.of(s) -> integer 0 .. 2^32-1; Crc32.hex(s) -> 8 lower-case hex digits.
local _, ns = ...
ns = ns or {}

local Crc32 = {}
ns.Crc32 = Crc32

local bit = bit
local bxor, band, rshift = bit.bxor, bit.band, bit.rshift
local sbyte = string.byte
local TWO32 = 4294967296

local POLY = -306674912 -- 0xEDB88320 as a signed 32-bit value
local tbl

local function build()
  tbl = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if band(c, 1) == 1 then c = bxor(rshift(c, 1), POLY) else c = rshift(c, 1) end
    end
    tbl[i] = c
  end
end

function Crc32.of(s)
  if not tbl then build() end
  local crc = -1
  local n = #s
  local i = 1
  while i <= n do
    local last = i + 4095
    if last > n then last = n end
    local bytes = { sbyte(s, i, last) }
    for k = 1, #bytes do
      crc = bxor(tbl[band(bxor(crc, bytes[k]), 255)], rshift(crc, 8))
    end
    i = last + 1
  end
  return bxor(crc, -1) % TWO32
end

function Crc32.hex(s)
  return string.format("%08x", Crc32.of(s))
end
