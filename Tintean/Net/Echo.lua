-- /tintean debug echo <n|z>: sends one message of n bytes (or a three-chunk compressed one) to my own
-- GUILD addon channel and says whether it came back intact and decoded. Uses the real send API directly,
-- through the send queue (Net/Send.lua) and the gate (Net/Gate.lua), like every other message.
local _, ns = ...
ns = ns or {}

local Echo = {}
ns.Echo = Echo

Echo.SPACING = 1.2
Echo.WAIT = 15
Echo.GIVE_UP = 60

local function line(text) ns.out(ns.tag .. " echo: " .. text) end
local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

local DROPPED = {
  not_in_guild = "you're not in a guild.",
  dropped_full = "the queue was full.",
  expired = "it expired.",
}

local function resultName(r)
  return ns.Send and ns.Send.resultName(r) or tostring(r)
end

local function padded(n)
  local base = ns.Json.encode({ p = 1, t = "hi", g = ns.Json.null, pad = "" })
  if n < #base + 1 then return nil, #base + 1 end
  return "J" .. ns.Json.encode({ p = 1, t = "hi", g = ns.Json.null, pad = string.rep("x", n - #base - 1) })
end

-- Characters a deflater cannot shrink much, so the compressed message has to be long.
local function randomPad(len)
  local t = {}
  for i = 1, len do
    local d = ns.Ids.random(0, 63)
    t[i] = ns.Wire.DIGITS:sub(d + 1, d + 1)
  end
  return table.concat(t)
end

local function threeChunkZ()
  local lo, hi = 2 * ns.Wire.DATA_MAX + 1, 3 * ns.Wire.DATA_MAX
  local len = 450
  for _ = 1, 12 do
    local text = ns.Wire.encode({ p = 1, t = "hi", g = ns.Json.null, pad = randomPad(len) }, "Z")
    if text and #text >= lo and #text <= hi then return text end
    if not text then return nil end
    len = math.max(1, len + math.floor(((lo + hi) / 2 - #text) * len / #text))
  end
end

local running

function Echo.run(args)
  args = (args or ""):lower()
  if running then return line("one is still going.") end
  local okGuild, inGuild = ns.try(IsInGuild)
  if not (okGuild and inGuild == true) then return line("you're not in a guild.") end
  if not ns.Receive.prefixOk then
    return line("the prefix isn't registered (" .. resultName(ns.Receive.prefixResult) .. ").")
  end
  local text
  if args == "z" then
    text = threeChunkZ()
    if not text then return line("couldn't build a compressed message.") end
  else
    local n = tonumber(args)
    if not n or n ~= math.floor(n) or n > ns.Wire.MAX_MESSAGE then
      return line("give a size up to " .. ns.Wire.MAX_MESSAGE .. ", or z.")
    end
    local why
    text, why = padded(n)
    if not text then return line("the smallest is " .. why .. " bytes.") end
  end
  local chunks = ns.Wire.split(text, ns.Ids.messageId())
  if not chunks then return line("that is too big to send.") end
  local shut = ns.Gate.reason()
  if shut then return line("not sent: " .. (ns.Gate.NOT_SENT[shut] or ns.Gate.NOT_SENT.unknown)) end

  local R = ns.Reassembly.new({ now = function() return select(2, ns.try(GetTime)) or 0 end })
  local id = chunks[1]:sub(2, 5)
  local finished = false
  local function finish(msg)
    if finished then return end
    finished = true
    running = false
    ns.Receive.echoTap = nil
    line(msg)
  end
  ns.Receive.echoTap = function(chunk)
    -- Only while an echo runs, and only chunks that carry its message id.
    if finished or not running or chunk:sub(1, 1) ~= "1" or chunk:sub(2, 5) ~= id then return end
    local whole = R:feed("echo", chunk, false)
    if not whole then return end
    local message, why = ns.Wire.decode(whole, nil)
    local size = plural(#text, "byte", "bytes") .. ", " .. plural(#chunks, "chunk", "chunks")
    if whole ~= text then
      finish("it came back changed (" .. size .. ").")
    elseif not message then
      finish("it came back intact but didn't decode (" .. tostring(why) .. ").")
    else
      finish("it came back intact and decoded (" .. size .. ").")
    end
  end
  running = true

  local function wait()
    local scheduled = ns.try(function()
      return C_Timer.After(Echo.WAIT, function()
        local got = 0
        for _, p in pairs(R.open) do got = got + p.got end
        finish(got .. " of " .. #chunks .. " came back in " .. Echo.WAIT .. " seconds.")
      end)
    end)
    if not scheduled then finish("sent, but couldn't wait for it to come back.") end
  end
  local entry, why = ns.Send.enqueue({
    type = "chg", own = true, chunks = chunks,
    onSent = function()
      line("sent " .. plural(#text, "byte", "bytes") .. " in " .. plural(#chunks, "chunk", "chunks") .. ".")
      wait()
    end,
    onDrop = function(m, reason)
      local words = DROPPED[reason] or ("the game refused it (" .. ns.Send.plain(reason) .. ").")
      finish("stopped at chunk " .. (m.sent + 1) .. " of " .. #chunks .. ": " .. words)
    end,
  })
  if not entry then
    return finish(why == "dropped_full" and "not sent: the queue is full." or "not sent: that message can't be sent.")
  end
  -- Held too long (the gate stayed shut): the echo gives up and takes its chunks out of the queue.
  ns.try(function()
    return C_Timer.After(Echo.GIVE_UP, function()
      if finished or entry.sent >= #chunks then return end
      ns.Send.cancel(entry)
      finish("it was held too long, so it wasn't sent.")
    end)
  end)
end

ns.registerDebug("echo", Echo.run)
