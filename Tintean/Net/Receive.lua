-- Receiving (formats/game.md section 6): CHAT_MSG_ADDON on prefix Tintean, channel GUILD, through
-- reassembly and decoding to a message table, handed to Receive.handlers[type](sender, message).
-- Messages wait while the player is in combat or an encounter (at most 200 and 256 KiB, as raw text; decoded when they are applied). Nothing here raises.
local _, ns = ...
ns = ns or {}

local Receive = {}
ns.Receive = Receive

Receive.PREFIX = "Tintean"
Receive.WAIT_MAX = 200         -- messages waiting out a fight
Receive.WAIT_BYTES = 262144    -- and the text they hold: 200 full messages would be 1.5 MB
Receive.WAIT_AGE = 600         -- seconds; game.md gives no number, so 10 minutes: older is a catch-up's work
Receive.SWEEP_EVERY = 5

Receive.counters = {}   -- reason -> count, for this session
Receive.handlers = {}   -- type -> function(sender, message); added by later tasks
Receive.mine = function() return nil end -- my Tintean guild slug, or nil
Receive.echoTap = nil   -- function(text): sees each chunk of my own messages (the debug echo)
Receive.waiting = {}    -- { sender, text (raw, reassembled), at }
Receive.waitBytes = 0

local function count(name)
  Receive.counters[name] = (Receive.counters[name] or 0) + 1
end

-- Every form my own name can take as a GUILD sender. On Forever it is "First Surname" (space, no realm):
-- UnitName gives the first name, UnitFullName the first name and the surname in the realm slot,
-- GetUnitName(unit, true) the whole of it. Other clients may send "Name-Realm".
local function myForms()
  local forms, seen = {}, {}
  local function add(f)
    if type(f) == "string" and f ~= "" and not seen[f] then
      seen[f] = true
      forms[#forms + 1] = f
    end
  end
  local _, whole = ns.try(GetUnitName, "player", true)
  add(whole)
  local ok, name, second = ns.try(UnitFullName, "player")
  if not ok or type(name) ~= "string" then
    ok, name = ns.try(UnitName, "player")
    second = nil
  end
  if ok then add(name) end
  if ok and type(name) == "string" and type(second) == "string" and second ~= "" then
    add(name .. " " .. second)
    add(name .. "-" .. second)
  end
  local _, realm = ns.try(GetNormalizedRealmName)
  if ok and type(name) == "string" and type(realm) == "string" and realm ~= "" then add(name .. "-" .. realm) end
  return forms
end

-- Byte-exact, or equal with spaces and hyphens swapped in either direction.
local function fold(s) return (s:gsub(" ", "-")) end

local function isSelf(sender)
  if type(sender) ~= "string" then return false end
  local folded = fold(sender)
  for _, f in ipairs(myForms()) do
    if sender == f or folded == fold(f) then return true end
  end
  return false
end

Receive.isSelf = isSelf
-- My name as the game gives it to guildmates ("First Surname" on Forever), or nil.
function Receive.myName() return myForms()[1] end

-- Letters masked, so a report can show the shape of a name and never the name.
local function mask(s)
  if type(s) ~= "string" then return tostring(s) end
  return (s:gsub("[\128-\255]", "x"):gsub("%l", "x"):gsub("%u", "X"))
end

Receive.stats = { received = 0, mine = 0 }

local function secret(v)
  local ok, s = ns.try(issecretvalue, v)
  return ok and s == true
end

-- In combat or an encounter nothing is applied (design section 7). Fails shut.
function Receive.busy()
  if ns.closed(InCombatLockdown) then return true end
  return ns.closed(function()
    return C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Encounter)
  end)
end

local function now()
  local ok, t = ns.try(GetTime)
  return ok and type(t) == "number" and t or 0
end

local function dispatch(sender, message)
  local fn = Receive.handlers[message.t]
  if fn then ns.try(fn, sender, message) end
end

local function apply(sender, text)
  local message, why = ns.Wire.decode(text, Receive.mine())
  if not message then
    count(why)
    return
  end
  dispatch(sender, message)
end

-- Applies what waited, oldest first, once nothing is busy. Held text older than WAIT_AGE is dropped.
function Receive.flush()
  if #Receive.waiting == 0 or Receive.busy() then return end
  local list = Receive.waiting
  Receive.waiting, Receive.waitBytes = {}, 0
  local t = now()
  for _, w in ipairs(list) do
    if t - w.at > Receive.WAIT_AGE then
      count("expired")
    else
      apply(w.sender, w.text)
    end
  end
end

-- A completed message's raw text: waits (as text, decoded later) while busy, else applied after
-- anything that waited before it.
local function complete(sender, text)
  if Receive.busy() then
    local w = Receive.waiting
    w[#w + 1] = { sender = sender, text = text, at = now() }
    Receive.waitBytes = Receive.waitBytes + #text
    while #w > Receive.WAIT_MAX or Receive.waitBytes > Receive.WAIT_BYTES do
      Receive.waitBytes = Receive.waitBytes - #table.remove(w, 1).text
      count("dropped_full")
    end
    return
  end
  Receive.flush()
  apply(sender, text)
end

function Receive.onAddonMessage(prefix, text, channel, sender)
  if secret(prefix) or prefix ~= Receive.PREFIX then return end
  if secret(channel) or channel ~= "GUILD" then return end
  if secret(text) or secret(sender) then
    count("secret")
    return
  end
  if type(text) ~= "string" or type(sender) ~= "string" then return end
  local mine = isSelf(sender)
  local st = Receive.stats
  st.received = st.received + 1
  if mine then st.mine = st.mine + 1 end
  st.lastSender = mask(sender)
  local masked = {}
  for i, f in ipairs(myForms()) do masked[i] = mask(f) end
  st.lastForms = masked
  local whole = Receive.reassembly:feed(sender, text, false)
  if mine and ns.Send then ns.try(ns.Send.onEcho, text) end
  if mine and Receive.echoTap then ns.try(Receive.echoTap, text) end
  if whole then complete(sender, whole) end
end

Receive.reassembly = ns.Reassembly.new({
  now = function()
    local ok, t = ns.try(GetTime)
    return ok and t or 0
  end,
  isSelf = isSelf,
  counters = Receive.counters,
})

function Receive.reportLines()
  local st = Receive.stats
  local forms = st.lastForms and table.concat(st.lastForms, " | ") or "none"
  return { "Messages: " .. st.received .. " on the prefix, " .. st.mine .. " from me. Last sender looked like "
    .. (st.lastSender or "none") .. "; my forms: " .. forms .. "." }
end
ns.reportExtra = ns.reportExtra or {}
ns.reportExtra[#ns.reportExtra + 1] = Receive.reportLines

-- A registration that fails is recorded and sync stays off (game.md section 4).
do
  local ok, res = ns.try(C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix, Receive.PREFIX)
  local success = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success
  Receive.prefixOk = ok and (res == true or res == success)
  Receive.prefixResult = res
end

local frame = type(CreateFrame) == "function" and CreateFrame("Frame") or nil
if frame then
  frame:RegisterEvent("CHAT_MSG_ADDON")
  frame:RegisterEvent("PLAYER_REGEN_ENABLED")
  frame:RegisterEvent("ENCOUNTER_END")
  frame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
  frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
      ns.try(Receive.onAddonMessage, ...)
    else
      ns.try(Receive.flush)
    end
  end)
end

if C_Timer and C_Timer.NewTicker then
  ns.try(C_Timer.NewTicker, Receive.SWEEP_EVERY, function()
    Receive.reassembly:sweep()
    if #Receive.waiting > 0 then Receive.flush() end -- a restriction can lift with no event
  end)
end

return Receive
