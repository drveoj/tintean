-- The wire: chunks and envelopes (formats/game.md sections 4 and 10). Pure apart from the game's base64.
--   chunk   "1" <id 4> <index 1> <total 1> <data>, at most 250 bytes, at most 32 to a message
--   message "J" <JSON>  or  "Z" <base64(raw deflate(JSON))>, the JSON at most 65,536 bytes
--   envelope { p = 1, t = <type>, g = <slug or null>, ... }
-- Everything here reads untrusted text: nothing raises, every refusal is a reason code.
local _, ns = ...
ns = ns or {}

local Wire = {}
ns.Wire = Wire

Wire.CHUNK_MAX = 250
Wire.HEADER = 7
Wire.DATA_MAX = 243
Wire.MAX_CHUNKS = 32
Wire.MAX_MESSAGE = Wire.DATA_MAX * Wire.MAX_CHUNKS -- 7,776
Wire.PLAIN_MAX = 200
-- game.md section 4 says 65,536 after inflating. A message is at most 7,776 bytes on the wire and the biggest a
-- sender builds is a 6,000-byte `rec` batch (section 7) plus its envelope, so receivers read at most 16 KiB of JSON:
-- about 2.7 times what an honest sender makes, and a forged bomb costs a quarter of what 64 KiB would.
Wire.JSON_MAX = 16384
Wire.PROTOCOL = 1
Wire.TYPES = { hi = true, want = true, rec = true, done = true, chg = true }

local DIGITS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
Wire.DIGITS = DIGITS
local POS = {}
for i = 1, #DIGITS do POS[DIGITS:sub(i, i)] = i - 1 end

local ssub, sbyte, sfind = string.sub, string.byte, string.find

local function base64encode(s)
  local ok, out = ns.try(function() return C_EncodingUtil.EncodeBase64(s) end)
  if ok and type(out) == "string" then return out end
end

local function base64decode(s)
  -- Canonical only; the game's decoder is not asked to judge anything else.
  if #s == 0 or #s % 4 ~= 0 or not sfind(s, "^[A-Za-z0-9+/]+=?=?$") then return nil end
  local ok, out = ns.try(function() return C_EncodingUtil.DecodeBase64(s) end)
  if ok and type(out) == "string" then return out end
end

-- A message from a table: "J" + JSON when the JSON is ASCII and at most 200 bytes, else "Z".
-- `form` ("J" or "Z") forces one, for tests and the debug echo. Returns text, or nil, reason.
function Wire.encode(message, form)
  local json, why = ns.Json.encode(message)
  if not json then return nil, why or "bad_json" end
  if not form then
    form = (#json <= Wire.PLAIN_MAX and not sfind(json, "[\128-\255]")) and "J" or "Z"
  end
  if form == "J" then return "J" .. json end
  local packed = base64encode(ns.Codec.deflate(json))
  if not packed then return nil, "bad_encoding" end
  return "Z" .. packed
end

-- A message's text from a received one: table, or nil, reason.
-- `mine`: my Tintean guild slug, or nil when I hold none.
function Wire.decode(text, mine)
  if type(text) ~= "string" or text == "" then return nil, "bad_envelope" end
  local form, body = ssub(text, 1, 1), ssub(text, 2)
  local json
  if form == "J" then
    if #body > Wire.JSON_MAX then return nil, "too_big" end
    json = body
  elseif form == "Z" then
    local bytes = base64decode(body)
    if not bytes then return nil, "bad_encoding" end
    local out, why = ns.Codec.inflate(bytes, Wire.JSON_MAX, true)
    if not out then return nil, why == "too_big" and "too_big" or "bad_encoding" end
    json = out
  else
    return nil, "unknown_encoding"
  end
  local m, why = ns.Json.decode(json)
  if m == nil then return nil, why == "too_big" and "too_big" or "bad_json" end
  if type(m) ~= "table" or ns.Json.isArray(m) or m == ns.Json.null then return nil, "bad_envelope" end
  local p, t, g = m.p, m.t, m.g
  if type(p) ~= "number" or p ~= math.floor(p) or p < 1 or type(t) ~= "string" then return nil, "bad_envelope" end
  if p > Wire.PROTOCOL then return nil, "newer" end
  if g ~= nil and g ~= ns.Json.null and type(g) ~= "string" then return nil, "bad_envelope" end
  if type(g) == "string" and mine and g ~= mine then return nil, "other_guild" end
  if not Wire.TYPES[t] then return nil, "unknown_type" end
  return m
end

-- Cuts a message's text into chunks with message id `id` (four digit characters).
-- Returns the list, or nil, "too_big" | "bad_id".
function Wire.split(text, id)
  if type(id) ~= "string" or not sfind(id, "^[A-Za-z0-9_%-][A-Za-z0-9_%-][A-Za-z0-9_%-][A-Za-z0-9_%-]$") then
    return nil, "bad_id"
  end
  local n = #text
  if n > Wire.MAX_MESSAGE then return nil, "too_big" end
  local count = math.max(1, math.ceil(n / Wire.DATA_MAX))
  local total = ssub(DIGITS, count + 1, count + 1) -- the digit at position `count` (A = 0): one chunk is "B"
  local out = {}
  for i = 1, count do
    local data = ssub(text, (i - 1) * Wire.DATA_MAX + 1, i * Wire.DATA_MAX)
    out[i] = "1" .. id .. ssub(DIGITS, i, i) .. total .. data
  end
  return out
end

-- A chunk's parts: { id, index, total, data } (index 0-based, total 1 to 32), or nil, "newer" | "bad_chunk".
function Wire.parseChunk(chunk)
  if type(chunk) ~= "string" or #chunk < Wire.HEADER then return nil, "bad_chunk" end
  if #chunk > Wire.CHUNK_MAX then return nil, "bad_chunk" end
  local first = sbyte(chunk, 1)
  if first ~= 49 then -- "1"
    if first > 49 and first <= 57 then return nil, "newer" end
    return nil, "bad_chunk"
  end
  local id = ssub(chunk, 2, 5)
  if not sfind(id, "^[A-Za-z0-9_%-]+$") then return nil, "bad_chunk" end
  local index, total = POS[ssub(chunk, 6, 6)], POS[ssub(chunk, 7, 7)]
  if not index or not total or total < 1 or total > Wire.MAX_CHUNKS or index >= total then return nil, "bad_chunk" end
  return { id = id, index = index, total = total, data = ssub(chunk, 8) }
end

return Wire
