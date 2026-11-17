-- The gate (formats/game.md section 5): when sending is allowed. Nothing is sent while the game holds addon
-- messages (chat lockdown, an instance, any combat, an Encounter or Chat restriction). Fails shut: a check that is
-- missing, raises or answers anything but exactly false counts as shut, and the reason says "unknown".
local _, ns = ...
ns = ns or {}

local Gate = {}
ns.Gate = Gate

local function restricted(kind)
  return function() return C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType[kind]) end
end

-- In the order they are asked; the first that is shut names the reason.
Gate.CHECKS = {
  { "lockdown", function() return C_ChatInfo.InChatMessagingLockdown() end },
  { "instance", function() return IsInInstance() end },
  { "combat", function() return InCombatLockdown() end },
  { "encounter", restricted("Encounter") },
  { "chat", restricted("Chat") },
}

-- The reason sending is shut ("lockdown", "instance", "combat", "encounter", "chat"), or nil when it is open.
-- A check that could not be read at all names "unknown" (still shut).
function Gate.reason()
  for _, check in ipairs(Gate.CHECKS) do
    local ok, v = ns.try(check[2])
    if not (ok and v == false) then return (ok and v == true) and check[1] or "unknown" end
  end
  return nil
end

-- Whether the Encounter restriction is on (a boss fight), asked on its own: reason() names whichever shut check
-- comes first, and an instance or combat check comes before it.
function Gate.encounter()
  local ok, v = ns.try(restricted("Encounter"))
  return ok and v == true
end

function Gate.shut() return Gate.reason() ~= nil end

-- Words for the check window.
Gate.WORDS = {
  lockdown = "the game's chat lockdown",
  instance = "an instance",
  combat = "combat",
  encounter = "a boss fight",
  chat = "a chat restriction",
  unknown = "the game holding addon messages",
}

-- "not sent: ..." endings for the debug echo.
Gate.NOT_SENT = {
  lockdown = "the game is holding addon messages.",
  instance = "you're in an instance.",
  combat = "you're in combat.",
  encounter = "you're in a boss fight.",
  chat = "the game is restricting chat.",
  unknown = "the game is holding addon messages.",
}

return Gate
