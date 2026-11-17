-- The addon's own JSON (formats/game.md section 2). Pure Lua 5.1, no game API.
-- Json.decode(s) -> value, or nil, reason ("bad_json", "too_deep", "too_big")
-- Json.encode(v) -> string, or nil, reason ("not_integer", "too_deep", "too_big", "bad_value")
local _, ns = ...
ns = ns or {}

local Json = {}
ns.Json = Json

local MAX_DEPTH = 16
local MAX_BYTES = 1048576
local MAX_INT = 9007199254740992 -- 2^53

local sbyte, schar, sfind, ssub, sformat = string.byte, string.char, string.find, string.sub, string.format
local concat, sort = table.concat, table.sort

-- null survives as a sentinel; arrays and objects carry a marker so that
-- [] and {} come back out as they went in.
Json.null = setmetatable({}, { __tostring = function() return "null" end })
local ARRAY = { __name = "json array" }
local OBJECT = { __name = "json object" }

function Json.array(t) return setmetatable(t or {}, ARRAY) end
function Json.object(t) return setmetatable(t or {}, OBJECT) end
function Json.isArray(t) return getmetatable(t) == ARRAY end
function Json.isObject(t) return getmetatable(t) == OBJECT end

Json.MAX_DEPTH = MAX_DEPTH
Json.MAX_BYTES = MAX_BYTES

---------------------------------------------------------------- encode

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
for i = 0, 31 do
  local c = schar(i)
  if not ESC[c] then ESC[c] = sformat("\\u%04x", i) end
end

-- Strict byte-wise order (not strcoll, which follows the locale).
local function byteLess(a, b)
  if a == b then return false end
  local n = #a < #b and #a or #b
  for i = 1, n do
    local x, y = sbyte(a, i), sbyte(b, i)
    if x ~= y then return x < y end
  end
  return #a < #b
end

local function encodeString(s)
  return '"' .. s:gsub('[%z\1-\31"\\]', function(c) return ESC[c] or c end) .. '"'
end

local function fail(reason) error({ reason = reason }, 0) end

local function isSequence(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true, n
end

local encodeValue

local function encodeNumber(n)
  if n ~= n or n < -MAX_INT or n > MAX_INT or n % 1 ~= 0 then fail("not_integer") end
  return sformat("%.0f", n)
end

encodeValue = function(v, depth, out)
  local tv = type(v)
  if v == Json.null then
    out[#out + 1] = "null"
  elseif tv == "string" then
    out[#out + 1] = encodeString(v)
  elseif tv == "number" then
    out[#out + 1] = encodeNumber(v)
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "table" then
    if depth > MAX_DEPTH then fail("too_deep") end
    local asArray = getmetatable(v) == ARRAY
    local n
    if not asArray and getmetatable(v) ~= OBJECT then
      local seq
      seq, n = isSequence(v)
      asArray = seq and n > 0
    end
    if asArray then
      n = #v
      out[#out + 1] = "["
      for i = 1, n do
        if i > 1 then out[#out + 1] = "," end
        encodeValue(v[i], depth + 1, out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= "string" then fail("bad_value") end
        keys[#keys + 1] = k
      end
      sort(keys, byteLess)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(k) .. ":"
        encodeValue(v[k], depth + 1, out)
      end
      out[#out + 1] = "}"
    end
  else
    fail("bad_value")
  end
end

function Json.encode(v)
  local out = {}
  local ok, err = pcall(encodeValue, v, 1, out)
  if not ok then
    if type(err) == "table" then return nil, err.reason end
    return nil, "bad_value"
  end
  local s = concat(out)
  if #s > MAX_BYTES then return nil, "too_big" end
  return s
end

---------------------------------------------------------------- decode

local function utf8Char(cp)
  if cp < 0x80 then return schar(cp) end
  if cp < 0x800 then return schar(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  if cp < 0x10000 then
    return schar(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return schar(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
    0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- true when s is well-formed UTF-8 (no overlongs, no surrogates, at most U+10FFFF)
local function validUtf8(s)
  if not sfind(s, "[\128-\255]") then return true end
  local i, n = 1, #s
  while i <= n do
    local c = sbyte(s, i)
    if c < 0x80 then
      i = i + 1
    else
      local len, min
      if c >= 0xC2 and c <= 0xDF then len, min = 2, 0x80
      elseif c >= 0xE0 and c <= 0xEF then len, min = 3, 0x800
      elseif c >= 0xF0 and c <= 0xF4 then len, min = 4, 0x10000
      else return false end
      if i + len - 1 > n then return false end
      local cp = c % (len == 2 and 32 or len == 3 and 16 or 8)
      for j = 1, len - 1 do
        local b = sbyte(s, i + j)
        if b < 0x80 or b > 0xBF then return false end
        cp = cp * 64 + (b - 0x80)
      end
      if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return false end
      i = i + len
    end
  end
  return true
end

local function skip(s, i)
  local _, e = sfind(s, "^[ \t\r\n]*", i)
  return e + 1
end

local decodeValue

local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
  n = "\n", r = "\r", t = "\t" }

local function decodeString(s, i)
  -- s:sub(i, i) is the opening quote
  local parts = {}
  local pos = i + 1
  while true do
    local a, b = sfind(s, '^[^"\\%z\1-\31]+', pos)
    if a then
      parts[#parts + 1] = ssub(s, a, b)
      pos = b + 1
    end
    local c = ssub(s, pos, pos)
    if c == '"' then
      local str = concat(parts)
      if not validUtf8(str) then fail("bad_json") end
      return str, pos + 1
    elseif c == "\\" then
      local e = ssub(s, pos + 1, pos + 1)
      if simple[e] then
        parts[#parts + 1] = simple[e]
        pos = pos + 2
      elseif e == "u" then
        local hex = s:match("^%x%x%x%x", pos + 2)
        if not hex then fail("bad_json") end
        local cp = tonumber(hex, 16)
        pos = pos + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          local lo = s:match("^\\u(%x%x%x%x)", pos)
          lo = lo and tonumber(lo, 16)
          if not lo or lo < 0xDC00 or lo > 0xDFFF then fail("bad_json") end
          cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
          pos = pos + 6
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          fail("bad_json")
        end
        parts[#parts + 1] = utf8Char(cp)
      else
        fail("bad_json")
      end
    else
      fail("bad_json") -- end of input or a raw control character
    end
  end
end

local function decodeNumber(s, i)
  local sign, int, rest = s:match("^(-?)(%d+)()", i)
  if not int then fail("bad_json") end
  if #int > 1 and ssub(int, 1, 1) == "0" then fail("bad_json") end
  local j = rest
  local isInt = true
  local frac = s:match("^%.%d+", j)
  if frac then j = j + #frac; isInt = false
  elseif ssub(s, j, j) == "." then fail("bad_json") end
  local exp = s:match("^[eE][+-]?%d+", j)
  if exp then j = j + #exp; isInt = false
  elseif sfind(ssub(s, j, j), "^[eE]") then fail("bad_json") end
  local n = tonumber(ssub(s, i, j - 1))
  if not n then fail("bad_json") end
  -- an integer literal beyond 2^53 loses its tail as a double; keep it out of range
  if isInt and (#int > 16 or (#int == 16 and int > "9007199254740992")) then
    n = sign == "-" and -(MAX_INT + 2) or MAX_INT + 2
  end
  return n, j
end

local function decodeLiteral(s, i)
  if ssub(s, i, i + 3) == "true" then return true, i + 4 end
  if ssub(s, i, i + 4) == "false" then return false, i + 5 end
  if ssub(s, i, i + 3) == "null" then return Json.null, i + 4 end
  fail("bad_json")
end

decodeValue = function(s, i, depth)
  i = skip(s, i)
  local c = ssub(s, i, i)
  if c == "{" then
    if depth > MAX_DEPTH then fail("too_deep") end
    local obj = Json.object()
    i = skip(s, i + 1)
    if ssub(s, i, i) == "}" then return obj, i + 1 end
    while true do
      if ssub(s, i, i) ~= '"' then fail("bad_json") end
      local k
      k, i = decodeString(s, i)
      i = skip(s, i)
      if ssub(s, i, i) ~= ":" then fail("bad_json") end
      local v
      v, i = decodeValue(s, i + 1, depth + 1)
      obj[k] = v
      i = skip(s, i)
      local d = ssub(s, i, i)
      if d == "}" then return obj, i + 1 end
      if d ~= "," then fail("bad_json") end
      i = skip(s, i + 1)
    end
  elseif c == "[" then
    if depth > MAX_DEPTH then fail("too_deep") end
    local arr = Json.array()
    i = skip(s, i + 1)
    if ssub(s, i, i) == "]" then return arr, i + 1 end
    while true do
      local v
      v, i = decodeValue(s, i, depth + 1)
      arr[#arr + 1] = v
      i = skip(s, i)
      local d = ssub(s, i, i)
      if d == "]" then return arr, i + 1 end
      if d ~= "," then fail("bad_json") end
      i = i + 1
    end
  elseif c == '"' then
    return decodeString(s, i)
  elseif c == "-" or sfind(c, "^%d") then
    return decodeNumber(s, i)
  else
    return decodeLiteral(s, i)
  end
end

local function decodeAll(s)
  local v, i = decodeValue(s, 1, 1)
  i = skip(s, i)
  if i <= #s then fail("bad_json") end
  return v
end

function Json.decode(s)
  if type(s) ~= "string" then return nil, "bad_json" end
  if #s > MAX_BYTES then return nil, "too_big" end
  local ok, v = pcall(decodeAll, s)
  if not ok then
    if type(v) == "table" then return nil, v.reason end
    return nil, "bad_json"
  end
  return v
end

return Json
