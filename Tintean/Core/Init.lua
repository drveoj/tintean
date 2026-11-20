-- Tintean: the addon table, the version and the /tintean command.
-- No network, no chat posting, no hooks; every game call goes through ns.try.
local _, ns = ...
ns = ns or {}

ns.version = "0.1.2"
ns.tag = "Tinteán:"

-- Call fn(...) so that a missing function or an error cannot reach the player.
-- Returns ok, then whatever fn returned.
function ns.try(fn, ...)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

-- A gate check that fails shut: true unless fn ran and answered exactly false.
-- A missing function, an error or a non-boolean answer all count as shut.
function ns.closed(fn, ...)
  local ok, v = ns.try(fn, ...)
  return not (ok and v == false)
end

function ns.print(text)
  ns.try(print, tostring(text))
end

-- Everything the debug commands say: printed to chat, kept in a ring of the last
-- 50 lines for /tintean debug report, and gathered so the command's lines open in
-- the copy window together.
ns.RING_MAX = 50
ns.ring = {}
ns.pending = nil

function ns.out(text)
  text = tostring(text)
  ns.print(text)
  local ring = ns.ring
  ring[#ring + 1] = text
  if #ring > ns.RING_MAX then table.remove(ring, 1) end
  if ns.pending then ns.pending[#ns.pending + 1] = text end
end

local function buildDate()
  local _, ver, num = ns.try(GetBuildInfo)
  return tostring(ver or "?") .. " (" .. tostring(num or "?") .. ")"
end

function ns.reportText()
  local _, stamp = ns.try(date, "%Y-%m-%d %H:%M:%S")
  local lines = { "Tinteán " .. ns.version .. ", game " .. buildDate() .. ", " .. tostring(stamp or "?") }
  for _, l in ipairs(ns.ring) do lines[#lines + 1] = l end
  for _, fn in ipairs(ns.reportExtra or {}) do
    local ok, extra = ns.try(fn)
    if ok and type(extra) == "table" then
      for _, l in ipairs(extra) do lines[#lines + 1] = tostring(l) end
    end
  end
  return table.concat(lines, "\n")
end

-- Later tasks add commands under /tintean debug <name>.
ns.debugCommands = {}

function ns.registerDebug(name, fn)
  ns.debugCommands[name] = fn
end

local function runDebug(rest)
  local name, args = rest:match("^(%S+)%s*(.-)%s*$")
  local fn = name and ns.debugCommands[name]
  if fn then
    ns.pending = {}
    local ok, err = ns.try(fn, args)
    local lines = ns.pending
    ns.pending = nil
    if #lines > 0 and ns.CopyBox then ns.try(ns.CopyBox.show, "Check", table.concat(lines, "\n")) end
    if not ok then
      ns.lastDebugError = err -- for tests; never printed
      ns.print(ns.tag .. " debug " .. name .. " failed.")
    end
  end
end

function ns.handleSlash(msg)
  msg = (msg or ""):match("^%s*(.-)%s*$")
  local word, rest = msg:match("^(%S+)%s*(.*)$")
  if word and word:lower() == "debug" then
    runDebug(rest)
    return
  end
  if word and word:lower() == "check" and ns.check then
    ns.try(ns.check)
    return
  end
  if ns.slash and ns.slash(msg) then return end
  if msg == "" and ns.UI and ns.UI.Frame and ns.UI.Frame.show() then return end
  ns.print(ns.tag .. " " .. ns.version .. ".")
end

SLASH_TINTEAN1 = "/tintean"
if type(SlashCmdList) == "table" then
  SlashCmdList["TINTEAN"] = ns.handleSlash
end

-- /tintean debug report: everything the debug commands printed this session, in one block.
ns.registerDebug("report", function()
  if ns.CopyBox then ns.CopyBox.show("Check", ns.reportText()) end
end)
