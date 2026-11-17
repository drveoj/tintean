-- Which deflate to use. At load, a self-test (formats/game.md section 2, game/codec.json "selfTest")
-- finds out whether the game's C_EncodingUtil Deflate method is raw deflate (RFC 1951):
--   reading: DecompressString of known raw deflate bytes must give the known text;
--   writing: CompressString's output must be raw (our Inflate reads it, and it is not
--            zlib- or gzip-framed) and the game must read it back.
-- Each direction that passes uses the game's; the other uses ours. Messages from other
-- players always inflate with ours (Codec.inflate(data, cap, true)): the game's has a
-- 100 MB output limit and no way to stop early.
local _, ns = ...
ns = ns or {}

local Codec = {}
ns.Codec = Codec

local SAMPLE = "tintean self-test 1"
-- The same sample as game/codec.json's deflateB64 "K8nMK0lNzFMoTs1J0y1JLS5RMAQA", as bytes.
local KNOWN = string.char(43, 201, 204, 43, 73, 77, 204, 83, 40, 78, 205, 73, 211, 45, 73, 45, 46, 81, 48, 4, 0)

local sbyte = string.byte

local function gameCompress(s)
  return C_EncodingUtil.CompressString(s, Enum.CompressionMethod.Deflate)
end

local function gameDecompress(s)
  return C_EncodingUtil.DecompressString(s, Enum.CompressionMethod.Deflate)
end

local function framing(out)
  local a, b = sbyte(out, 1, 2)
  if a == 0x1f and b == 0x8b then return "gzip" end
  if a and b and a % 16 == 8 and (a * 256 + b) % 31 == 0 then return "zlib" end
  return "unknown"
end

-- Runs the test and stores the answer in Codec.status. Called at load; specs call it again.
-- status: { readRaw, writeRaw, readsOwn (the game reads back what it wrote),
--            framing = "raw"|"zlib"|"gzip"|"unknown"|"none", useGameRead, useGameWrite }
function Codec.selfTest()
  local st = { readRaw = false, writeRaw = false, readsOwn = false, framing = "none" }

  local ok, got = ns.try(gameDecompress, KNOWN)
  st.readRaw = ok and got == SAMPLE

  local ok2, comp = ns.try(gameCompress, SAMPLE)
  if ok2 and type(comp) == "string" then
    if ns.Inflate.inflate(comp, 4096) == SAMPLE then
      -- Raw is decided by our Inflate alone; whether the game reads it back is reported apart.
      st.framing = "raw"
      st.writeRaw = true
      local ok3, back = ns.try(gameDecompress, comp)
      st.readsOwn = ok3 and back == SAMPLE
    else
      st.framing = framing(comp)
    end
  end

  st.useGameRead = st.readRaw
  st.useGameWrite = st.writeRaw
  Codec.status = st
  return st
end

-- Inflate `data` (raw deflate) to at most `cap` bytes: string, or nil, "too_big" | "bad_deflate".
-- `wire`: the bytes came from another player; ours only.
function Codec.inflate(data, cap, wire)
  cap = cap or ns.Inflate.DEFAULT_CAP
  local st = Codec.status
  if not wire and st and st.useGameRead then
    local ok, res = ns.try(gameDecompress, data)
    if ok and type(res) == "string" then
      if #res > cap then return nil, "too_big" end
      return res
    end
  end
  return ns.Inflate.inflate(data, cap)
end

-- Raw deflate of `s`: the game's if it is raw and our Inflate reads this very output back to `s`,
-- else stored blocks of ours.
function Codec.deflate(s)
  local st = Codec.status
  if st and st.useGameWrite then
    local ok, res = ns.try(gameCompress, s)
    if ok and type(res) == "string" and ns.Inflate.inflate(res, #s) == s then return res end
  end
  return ns.Deflate.stored(s)
end

Codec.selfTest()

local function yesNo(b) return b and "yes" or "no" end

local FRAMING_WORDS = {
  raw = "",
  zlib = " (it adds zlib framing)",
  gzip = " (it adds gzip framing)",
  unknown = " (its output isn't deflate)",
  none = " (it didn't answer)",
}

ns.registerDebug("codec", function()
  local st = Codec.status or Codec.selfTest()
  local writes = yesNo(st.writeRaw)
  if not st.writeRaw then writes = writes .. (FRAMING_WORDS[st.framing] or "")
  elseif not st.readsOwn then writes = writes .. " (but it can't read that back)" end
  ns.out(ns.tag .. " the game writes raw deflate: " .. writes
    .. ". The game reads raw deflate: " .. yesNo(st.readRaw) .. ".")
  ns.out(ns.tag .. " reading with " .. (st.useGameRead and "the game's" or "its own")
    .. ", writing with " .. (st.useGameWrite and "the game's" or "its own") .. ".")
end)
