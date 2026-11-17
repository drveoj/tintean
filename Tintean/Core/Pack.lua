-- "TN1:" paste strings (formats/README.md, Paste strings):
--   TN1: + base64 of ( raw deflate of the UTF-8 JSON, then the CRC-32 of those deflate bytes, 4 bytes big-endian ).
-- At most 65,536 characters after the prefix and 1 MiB of JSON; whitespace inside is ignored.
-- Pack.unpack(text) -> payload, or nil, code, words      (code: truncated, too_large, wrong_prefix, invalid, newer)
-- Pack.pack(payload) -> string, or nil, code, words       (code: too_large, invalid)
local _, ns = ...
ns = ns or {}

local Pack = {}
ns.Pack = Pack

Pack.PREFIX = "TN1:"
Pack.MAX_CHARS = 65536
Pack.MAX_BYTES = 1048576

local floor, schar, sbyte = math.floor, string.char, string.byte

Pack.WORDS = {
  truncated = "That string is cut off or changed. Copy it again from the website, all of it.",
  too_large = "That string is too big to read.",
  wrong_prefix = "That string isn't from Tinteán.",
  invalid = "That string unpacked, but Tinteán can't read it.",
  newer = "That string is from a newer Tinteán. Update the addon, then try again.",
}

local function fail(code) return nil, code, Pack.WORDS[code] end

local function base64decode(s)
  local ok, out = ns.try(function() return C_EncodingUtil.DecodeBase64(s) end)
  if ok and type(out) == "string" then return out end
end

local function base64encode(s)
  local ok, out = ns.try(function() return C_EncodingUtil.EncodeBase64(s) end)
  if ok and type(out) == "string" then return out end
end

local function isInt(x) return type(x) == "number" and x == floor(x) end

local function unpackAny(text, allowInbox)
  if type(text) ~= "string" then return fail("wrong_prefix") end
  -- Cheap refusal before copying or stripping huge text (whitespace is allowed, but not 4 times the limit).
  if #text > 4 * Pack.MAX_CHARS then
    if not (text:find("^%s*TN1:") or text:find("^\239\187\191%s*TN1:")) then return fail("wrong_prefix") end
    return fail("too_large")
  end
  text = text:gsub("^\239\187\191", ""):gsub("^%s+", "")
  if text:sub(1, #Pack.PREFIX) ~= Pack.PREFIX then return fail("wrong_prefix") end
  local body = text:sub(#Pack.PREFIX + 1):gsub("%s+", "")
  if #body > Pack.MAX_CHARS then return fail("too_large") end
  if body == "" or #body % 4 ~= 0 or not body:find("^[A-Za-z0-9+/]+=?=?$") then return fail("truncated") end

  local bytes = base64decode(body)
  if not bytes then return fail("truncated") end
  if #bytes < 5 then return fail("truncated") end
  local packed = bytes:sub(1, -5)
  local a, b, c, d = sbyte(bytes, -4, -1)
  if ((a * 256 + b) * 256 + c) * 256 + d ~= ns.Crc32.of(packed) then return fail("truncated") end

  local json, why = ns.Codec.inflate(packed, Pack.MAX_BYTES, false)
  if not json then return fail(why == "too_big" and "too_large" or "truncated") end

  local v, jwhy = ns.Json.decode(json)
  if v == nil then return fail(jwhy == "too_big" and "too_large" or "invalid") end
  if not ns.Json.isObject(v) then return fail("invalid") end
  if not isInt(v.v) or v.v < 1 then return fail("invalid") end
  if v.v > 1 then return fail("newer") end
  if type(v.guild) ~= "string" then return fail("invalid") end
  if v.t == "changes" and ns.Json.isArray(v.changes) then return v end
  if v.t == "records" and ns.Json.isArray(v.records) then return v end
  if allowInbox and v.t == "inbox" and ns.Json.isArray(v.records) then return v end
  return fail("invalid")
end

-- A pasted string never may be an inbox payload.
function Pack.unpack(text) return unpackAny(text, false) end

-- The inbox reader's: the same packing, and t = "inbox" is the payload.
function Pack.unpackInbox(text) return unpackAny(text, true) end

-- `limits` ({ chars, bytes }) is for the export to the desktop app (formats/game.md section 13), which reads more than a paste.
function Pack.pack(payload, limits)
  local maxChars = limits and limits.chars or Pack.MAX_CHARS
  local maxBytes = limits and limits.bytes or Pack.MAX_BYTES
  local json = ns.Json.encode(payload)
  if not json then return fail("invalid") end
  if #json > maxBytes then return fail("too_large") end
  local packed = ns.Codec.deflate(json)
  local crc = ns.Crc32.of(packed)
  local tail = schar(floor(crc / 16777216) % 256, floor(crc / 65536) % 256, floor(crc / 256) % 256, crc % 256)
  local b64 = base64encode(packed .. tail)
  if not b64 then return fail("invalid") end
  if #b64 > maxChars then return fail("too_large") end
  return Pack.PREFIX .. b64
end

local function plural(n, one, many)
  return n .. " " .. (n == 1 and one or many)
end

-- /tintean debug paste <string>.
ns.registerDebug("paste", function(args)
  local text = args
  if type(text) ~= "string" or text == "" then
    ns.out(ns.tag .. " no string. Add one after the command.")
    return
  end
  local _, t0 = ns.try(debugprofilestop)
  local payload, _, words = Pack.unpack(text)
  local _, t1 = ns.try(debugprofilestop)
  local ms = (type(t0) == "number" and type(t1) == "number") and floor(t1 - t0 + 0.5) or 0
  if payload then
    local list = payload.t == "records" and payload.records or payload.changes
    local noun = payload.t == "records" and plural(#list, "record", "records") or plural(#list, "change", "changes")
    ns.out(ns.tag .. " read " .. noun .. " in " .. ms .. " ms.")
  else
    ns.out(ns.tag .. " " .. words .. " (" .. ms .. " ms)")
  end
end)
