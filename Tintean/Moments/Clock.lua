-- The clock moments are stamped with (formats/moments/README.md, section 2): the realm's GetServerTime(), the same for every
-- player, so two players' notes of one night agree. Where the call is missing or gives nothing usable, time() is used and
-- the batch says "local". Every call is guarded.
local _, ns = ...
ns = ns or {}
ns.Moments = ns.Moments or {}

local Clock = {}
ns.Moments.Clock = Clock

local function whole(v)
  return type(v) == "number" and v == math.floor(v) and v > 0 and v < 4294967296
end

-- Whether a value from the game can be read: false for one `issecretvalue` flags.
function Clock.plain(v)
  if v == nil then return false end
  if type(issecretvalue) ~= "function" then return true end
  local ok, s = pcall(issecretvalue, v)
  return ok and s ~= true
end

-- Returns epoch seconds and "server" or "local"; nil when neither clock answers.
function Clock.now()
  local ok, v = ns.try(GetServerTime)
  if ok and Clock.plain(v) and whole(v) then return v, "server" end
  ok, v = ns.try(time)
  if ok and whole(v) then return v, "local" end
  return nil
end

return Clock
