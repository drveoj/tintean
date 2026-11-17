-- Random ids (formats/game.md section 3). Never a counter, never reused.
-- Ids.random(lo, hi) is math.random unless a test swaps it for a list of draws.
local _, ns = ...
ns = ns or {}

local Ids = {}
ns.Ids = Ids

local DIGITS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local HEX = "0123456789abcdef"
local ssub, concat = string.sub, table.concat

-- The game reseeds math.random itself; mixing in the clocks once at load is a second source,
-- so two clients (or two loads in one second) don't share a sequence.
local function seed()
  local n = 0
  local clocks = { time, GetTime, debugprofilestop }
  for i = 1, 3 do
    if clocks[i] then
      local ok, v = pcall(clocks[i])
      if ok and type(v) == "number" then n = n + math.floor(v * 1000) * (i * 2 + 1) end
    end
  end
  pcall(math.randomseed, n % 2147483647)
  return n
end
Ids.seeded = seed()

Ids.DIGITS = DIGITS

function Ids.random(lo, hi) return math.random(lo, hi) end

local function chars(n)
  local t = {}
  for i = 1, n do
    local d = Ids.random(0, 63)
    t[i] = ssub(DIGITS, d + 1, d + 1)
  end
  return concat(t)
end

-- 16 characters; drawn again if it starts with "srv-" (the server's).
function Ids.cid()
  local s = chars(16)
  while ssub(s, 1, 4) == "srv-" do s = chars(16) end
  return s
end

-- 4 characters, unique only among a sender's messages still being reassembled.
function Ids.messageId() return chars(4) end

-- A uuid v4 in lower case: 32 draws of 0..15, the 13th digit 4, the 17th 8 + draw % 4.
function Ids.uuid()
  local d = {}
  for i = 1, 32 do d[i] = Ids.random(0, 15) end
  d[13] = 4
  d[17] = 8 + d[17] % 4
  local t = {}
  for i = 1, 32 do t[i] = ssub(HEX, d[i] + 1, d[i] + 1) end
  local s = concat(t)
  return ssub(s, 1, 8) .. "-" .. ssub(s, 9, 12) .. "-" .. ssub(s, 13, 16) .. "-" .. ssub(s, 17, 20) .. "-" .. ssub(s, 21, 32)
end

-- The roster key, a roster record's id on the wire (formats/README.md, Roster keys; formats/records/keys.json): the game's
-- "First Second" with hyphens as spaces, runs of spaces as one, the ends trimmed and ASCII A-Z lower-cased; nothing else changes
-- (an accented capital stays as it is). `second` may be nil or empty. The server computes the same string from its row.
function Ids.rosterKey(first, second)
  local s = tostring(first or "")
  if second ~= nil and second ~= "" then s = s .. " " .. tostring(second) end
  s = s:gsub("%-", " "):gsub(" +", " "):gsub("^ ", ""):gsub(" $", "")
  return (s:gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end))
end
