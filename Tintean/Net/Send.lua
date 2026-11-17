-- The send queue (formats/game.md section 5; fixture game/queue.json). Logical messages, each a list of chunks,
-- go out one chunk at a time to the GUILD addon channel through a token bucket, only while Gate is open.
--   Send.enqueue{ type, own, chunks | message, rebuild, settled, onSent, onDrop } -> entry, or nil, reason
-- Nothing here raises, and nothing leaves the queue stuck: a failing send or timer drops or retries, and a 5 s
-- backstop wakes the queue if a timer was lost. Callbacks run under ns.try.
local _, ns = ...
ns = ns or {}

local Send = {}
ns.Send = Send

Send.BUCKET = 6
Send.REFILL = 1.2
Send.POLL = { 2, 4, 8, 16, 30 }
Send.BACKOFF = { 2, 4, 8, 16, 30 }
Send.TTL = { hi = 60, want = 60, rec = 300, done = 300 }
Send.MAX_MESSAGES = 64
Send.MAX_CHUNKS = 512
Send.BACKSTOP = 5
Send.EPS = 1e-6
Send.RECENT = 600       -- own chunks remembered while their echo is awaited
Send.NAMES_MAX = 24     -- distinct non-Success results remembered

local EPS = Send.EPS

Send.queue = {}         -- entries: { type, prio, chunks, sent (chunks gone), at, seq, ... }
Send.counters = {}      -- reason -> count: expired rebuilt settled dropped_full lockdown throttled failed not_in_guild error
Send.stats = { sent = 0, echoed = 0 }
Send.results = {}       -- result name -> count, for everything but Success
Send.errors = {}        -- result names, each recorded once (the error ring)
Send.onDrop = nil       -- function(entry, reason): the specs watch drops here

local tokens, last = Send.BUCKET, nil
local pollStep, backoffStep = 1, 1
local pausedUntil, lockedUntil = 0, 0
local seq, gen = 0, 0
local running, again = false, false
local stepErrors = 0
Send.timerAt = nil
local awaiting, awaitingList = {}, {}

local function count(name) Send.counters[name] = (Send.counters[name] or 0) + 1 end

local function now()
  local ok, t = ns.try(GetTime)
  if ok and type(t) == "number" then
    Send.lastNow = t
    return t
  end
  return Send.lastNow or 0
end

local function priority(kind, own)
  if kind == "hi" or kind == "want" then return 1 end
  if kind == "chg" then return own and 1 or 2 end
  if kind == "rec" or kind == "done" then return 3 end
end

local function remainingChunks()
  local n = 0
  for _, m in ipairs(Send.queue) do n = n + #m.chunks - m.sent end
  return n
end

local function resultName(r)
  for name, v in pairs(Enum and Enum.SendAddonMessageResult or {}) do
    if v == r then return name end
  end
  return "Result " .. tostring(r)
end
Send.resultName = resultName

local function isSuccess(ok, res)
  if not ok or res == nil then return false end
  if res == true then return true end
  local success = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success
  return success ~= nil and res == success
end

-- Plain words for a recorded result name (the check window).
function Send.plain(name)
  if name == "error" then return "an addon error" end
  if name == "other" then return "other results" end
  local n = tostring(name):match("^Result (.+)$")
  if n then return "an unnamed result " .. n end
  return name
end

-- Entries in sending order: priority, then age.
local function before(a, b)
  if a.prio ~= b.prio then return a.prio < b.prio end
  return a.seq < b.seq
end

function Send.list()
  local out = {}
  for i, m in ipairs(Send.queue) do out[i] = m end
  table.sort(out, before)
  return out
end

local function front()
  local best
  for _, m in ipairs(Send.queue) do
    if not best or before(m, best) then best = m end
  end
  return best
end

local function remove(m)
  for i, q in ipairs(Send.queue) do
    if q == m then
      table.remove(Send.queue, i)
      break
    end
  end
  if #Send.queue == 0 then pollStep, backoffStep = 1, 1 end
end

-- `quiet`: the owner's onDrop is not called (the message was made again in its place).
local function drop(m, reason, quiet)
  remove(m)
  if Send.onDrop then ns.try(Send.onDrop, m, reason) end
  if m.onDrop and not quiet then ns.try(m.onDrop, m, reason) end
end

-- Takes a message out of the queue with no callbacks (its owner gave up).
function Send.cancel(m) remove(m) end

local function dropAll(reason)
  for _, m in ipairs(Send.list()) do drop(m, reason) end
end

-- `poll`: the wait is a step of the poll series, which moves on only when its timer fires.
local function schedule(delay, poll)
  gen = gen + 1
  local mine = gen
  Send.timerAt = now() + delay
  local ok = ns.try(function()
    return C_Timer.After(delay, function()
      if mine ~= gen then return end
      Send.timerAt = nil
      if poll then pollStep = pollStep + 1 end
      Send.run()
    end)
  end)
  if not ok then Send.timerAt = nil end -- the backstop finds it
end

local function refill(t)
  if last then tokens = math.min(Send.BUCKET, tokens + math.max(0, t - last) / Send.REFILL) end
  last = t
end

local function step(from)
  local t = from
  refill(t)
  -- Unstarted messages past their TTL go (a hello is made again in its place); settled edits are skipped.
  for _, m in ipairs(Send.list()) do
    if m.sent == 0 then
      local ttl = Send.TTL[m.type]
      if ttl and t - m.at > ttl then
        count("expired")
        local fresh = m.rebuild and select(2, ns.try(m.rebuild))
        local remade = type(fresh) == "table" and #fresh > 0
        drop(m, "expired", remade)
        if remade then
          local e = Send.enqueue({ type = m.type, own = m.own, chunks = fresh, rebuild = m.rebuild, settled = m.settled,
            onSent = m.onSent, onDrop = m.onDrop, name = (m.name or "") .. "+", seq = m.seq })
          if e then count("rebuilt") end
        end
      elseif m.settled then
        local ok, done = ns.try(m.settled)
        if ok and done == true then
          count("settled")
          drop(m, "settled")
        end
      end
    end
  end
  while true do
    local m = front()
    if not m then return end
    local okGuild, inGuild = ns.try(IsInGuild)
    -- Not in a guild by my own look: hold (TTLs and caps bound it); only the game's NotInGuild clears.
    if Send.gateShut() or (okGuild and inGuild == false) then
      return schedule(Send.POLL[math.min(pollStep, #Send.POLL)], true)
    end
    if t + EPS < lockedUntil then return schedule(lockedUntil - t) end
    if t + EPS < pausedUntil then return schedule(pausedUntil - t) end
    if tokens < 1 - EPS then return schedule((1 - tokens) * Send.REFILL) end
    local chunk = m.chunks[m.sent + 1]
    local ok, res = ns.try(function() return C_ChatInfo.SendAddonMessage(ns.Receive.PREFIX, chunk, "GUILD") end)
    local R = Enum and Enum.SendAddonMessageResult or {}
    local function is(v) return ok and res ~= nil and v ~= nil and res == v end
    if isSuccess(ok, res) then
      tokens = tokens - 1
      pollStep, backoffStep = 1, 1
      m.sent = m.sent + 1
      Send.stats.sent = Send.stats.sent + 1
      Send.expectEcho(chunk)
      if m.sent >= #m.chunks then
        remove(m)
        if m.onSent then ns.try(m.onSent, m) end
      end
    elseif is(R.AddonMessageThrottle) or is(R.ChannelThrottle) then
      count("throttled")
      tokens = 0
      local wait = Send.BACKOFF[math.min(backoffStep, #Send.BACKOFF)]
      backoffStep = backoffStep + 1
      pausedUntil = t + wait
      return schedule(wait)
    elseif is(R.AddOnMessageLockdown) then
      count("lockdown")
      local wait = Send.POLL[math.min(pollStep, #Send.POLL)]
      lockedUntil = t + wait
      return schedule(wait, true)
    elseif is(R.NotInGuild) then
      count("not_in_guild")
      return dropAll("not_in_guild")
    else
      local name = ok and resultName(res) or "error"
      Send.record(name)
      count(ok and "failed" or "error")
      drop(m, name)
    end
  end
end

-- Records a result other than Success: counted by name, and named once in the error ring.
function Send.record(name)
  if Send.results[name] == nil then
    local n = 0
    for _ in pairs(Send.results) do n = n + 1 end
    if n >= Send.NAMES_MAX then name = "other" end
  end
  Send.results[name] = (Send.results[name] or 0) + 1
  if Send.results[name] == 1 then
    Send.errors[#Send.errors + 1] = name
    if #Send.errors > 20 then table.remove(Send.errors, 1) end
  end
end

-- Looks at the queue now. Safe to call from anywhere, any time.
function Send.run()
  if running then
    again = true
    return
  end
  running = true
  for _ = 1, 8 do
    again = false
    local ok = ns.try(function() step(now()) end)
    if ok then
      stepErrors = 0
    else
      count("error")
      stepErrors = stepErrors + 1
      if stepErrors >= 5 then
        stepErrors = 0
        local m = front()
        if m then
          Send.record("error")
          drop(m, "error")
        end
      end
      schedule(Send.POLL[math.min(math.max(stepErrors, 1), #Send.POLL)])
    end
    if not again then break end
  end
  running = false
end

-- A game event that can open the gate: look again at once, whatever the poll was waiting for.
function Send.kick()
  lockedUntil = 0
  Send.run()
end

function Send.gateShut()
  if ns.Gate then return ns.Gate.shut() end
  return true
end

-- Chunks of a message table, or nil, reason.
function Send.pack(message)
  local text, why = ns.Wire.encode(message)
  if not text then return nil, why end
  return ns.Wire.split(text, ns.Ids.messageId())
end

local function valid(chunks)
  if type(chunks) ~= "table" or #chunks < 1 or #chunks > ns.Wire.MAX_CHUNKS then return false end
  for i = 1, #chunks do
    if type(chunks[i]) ~= "string" or #chunks[i] > ns.Wire.CHUNK_MAX then return false end
  end
  return true
end

-- Queues a message. `own` marks my own edit (priority 1; a relayed `chg` is priority 2).
-- `rebuild()` returns fresh chunks for a stale hello; `settled()` is true when an edit is no longer pending.
function Send.enqueue(spec)
  if type(spec) ~= "table" then return nil, "bad_spec" end
  local prio = priority(spec.type, spec.own)
  if not prio then return nil, "bad_type" end
  local chunks = spec.chunks
  if not chunks and spec.message then
    local why
    chunks, why = Send.pack(spec.message)
    if not chunks then return nil, why end
  end
  if not valid(chunks) then return nil, "bad_chunks" end
  seq = seq + 1
  local m = { type = spec.type, own = spec.own, prio = prio, chunks = chunks, sent = 0, at = now(),
    seq = spec.seq or seq, rebuild = spec.rebuild, settled = spec.settled, onSent = spec.onSent,
    onDrop = spec.onDrop, name = spec.name }
  Send.queue[#Send.queue + 1] = m
  -- Over a cap: the newest unstarted message of the lowest priority present goes, before anything is sent.
  while #Send.queue > Send.MAX_MESSAGES or remainingChunks() > Send.MAX_CHUNKS do
    local worst
    for _, q in ipairs(Send.queue) do
      if q.sent == 0 and (not worst or q.prio > worst.prio or (q.prio == worst.prio and q.seq > worst.seq)) then
        worst = q
      end
    end
    if not worst then break end
    count("dropped_full")
    drop(worst, "dropped_full")
    if worst == m then return nil, "dropped_full" end
  end
  Send.run()
  return m
end

-- Own chunks seen coming back, for the check's "echoed".
function Send.expectEcho(chunk)
  if awaiting[chunk] then return end
  awaiting[chunk] = true
  awaitingList[#awaitingList + 1] = chunk
  if #awaitingList > Send.RECENT then awaiting[table.remove(awaitingList, 1)] = nil end
end

function Send.onEcho(text)
  if awaiting[text] then
    awaiting[text] = nil
    for i = #awaitingList, 1, -1 do
      if awaitingList[i] == text then
        table.remove(awaitingList, i)
        break
      end
    end
    Send.stats.echoed = Send.stats.echoed + 1
  end
end

function Send.held() return #Send.queue end

-- /tintean check lines (mockup Slash.html: "This session", "Held", and the results by name).
function Send.reportLines()
  local st = Send.stats
  local lines = { ns.tag .. " this session: sent " .. st.sent .. " chunks, echoed " .. st.echoed .. ", throttled "
    .. (Send.counters.throttled or 0) .. "." }
  local held = #Send.queue
  if held == 0 then
    lines[#lines + 1] = ns.tag .. " held: nothing."
  else
    local why = ns.Gate and ns.Gate.reason()
    local text = ns.tag .. " held: " .. held .. (held == 1 and " message" or " messages")
    if why then text = text .. ", waiting out " .. (ns.Gate.WORDS[why] or why) end
    lines[#lines + 1] = text .. "."
  end
  local names = {}
  for name, n in pairs(Send.results) do names[#names + 1] = Send.plain(name) .. " " .. n end
  table.sort(names)
  lines[#lines + 1] = ns.tag .. " results other than Success: " .. (#names > 0 and table.concat(names, ", ") or "none") .. "."
  return lines
end

local baseCheck = ns.check
function ns.check()
  if baseCheck then ns.try(baseCheck) end
  for _, l in ipairs(Send.reportLines()) do ns.out(l) end
end

-- /tintean debug send <n>: n small real-shaped messages (an own `chg` with no edits), for the in-game checks.
local function debugSend(args)
  local n = tonumber((args or ""):match("^%s*(%d+)%s*$"))
  if not n or n < 1 or n > Send.MAX_MESSAGES then
    return ns.out(ns.tag .. " send: give a number from 1 to " .. Send.MAX_MESSAGES .. ".")
  end
  local queued = 0
  for _ = 1, n do
    local e = Send.enqueue({ type = "chg", own = true,
      message = { p = 1, t = "chg", g = ns.Json.null, c = {} } })
    if e then queued = queued + 1 end
  end
  ns.out(ns.tag .. " send: queued " .. queued .. " of " .. n .. ".")
end
ns.registerDebug("send", debugSend)

local frame = type(CreateFrame) == "function" and CreateFrame("Frame") or nil
if frame then
  for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_END", "ADDON_RESTRICTION_STATE_CHANGED" }) do
    frame:RegisterEvent(e)
  end
  frame:SetScript("OnEvent", function() ns.try(Send.kick) end)
end

-- The backstop: a timer that failed to schedule, or was lost, must not leave messages waiting for ever.
if C_Timer and C_Timer.NewTicker then
  ns.try(C_Timer.NewTicker, Send.BACKSTOP, function()
    if #Send.queue > 0 and (Send.timerAt == nil or now() > Send.timerAt + Send.BACKSTOP) then Send.run() end
  end)
end

return Send
