-- Chunk reassembly (formats/game.md section 6, steps 1 to 4). Every chunk is a stranger's: memory and
-- work are bounded at each step and nothing here raises.
--   Reassembly.new{ now = fn -> seconds, isSelf = fn(sender) -> bool, counters = table }
--   r:feed(sender, chunk, secret) -> the completed message's text, or nil
--   r:sweep()                     drop partials with no chunk for more than 45 s; call every 5 s
-- A sender table over its cap forgets the stalest idle sender, never refusing the newcomer.
-- Counters bumped: secret echo flood newer bad_chunk dup_chunk lost_chunk.
local _, ns = ...
ns = ns or {}

local Reassembly = {}
ns.Reassembly = Reassembly
Reassembly.__index = Reassembly

Reassembly.STALE = 45          -- seconds without a chunk
Reassembly.RATE = 120          -- chunks a minute from one sender
Reassembly.RATE_WINDOW = 60
Reassembly.PER_SENDER = 8      -- open messages
Reassembly.MAX_OPEN = 64
Reassembly.MAX_BYTES = 131072  -- data held in all open messages
Reassembly.DONE_KEPT = 256     -- completed messages remembered, for late duplicates
Reassembly.MAX_SENDERS = 512   -- senders with rate state

local concat = table.concat

function Reassembly.new(opts)
  opts = opts or {}
  return setmetatable({
    now = opts.now or function() return 0 end,
    isSelf = opts.isSelf or function() return false end,
    counters = opts.counters or {},
    open = {},        -- key -> partial
    nOpen = 0,
    bytes = 0,
    seq = 0,
    perSender = {},   -- sender -> open count
    rate = {},        -- sender -> { head, tail, [i] = time }
    nRate = 0,
    done = {}, doneRing = {}, doneNext = 1,
  }, Reassembly)
end

function Reassembly:count(name)
  self.counters[name] = (self.counters[name] or 0) + 1
end

local function drop(self, p, name)
  self.open[p.key] = nil
  self.nOpen = self.nOpen - 1
  self.bytes = self.bytes - p.bytes
  local n = (self.perSender[p.sender] or 1) - 1
  self.perSender[p.sender] = n > 0 and n or nil
  if name then self:count(name) end
end

local function oldest(self, sender)
  local best
  for _, p in pairs(self.open) do
    if (not sender or p.sender == sender) and (not best or p.seq < best.seq) then best = p end
  end
  return best
end

-- Chunks a minute: a sliding list of at most RATE stamps per sender.
local function underRate(self, sender, now)
  local q = self.rate[sender]
  if not q then
    if self.nRate >= Reassembly.MAX_SENDERS then
      -- Make room by forgetting the stalest sender with nothing open (at most 64 have).
      local stalest, when
      for name, other in pairs(self.rate) do
        local last = other.tail >= other.head and other[other.tail] or -math.huge
        if not self.perSender[name] and (not when or last < when) then stalest, when = name, last end
      end
      if not stalest then return false end
      self.rate[stalest] = nil
      self.nRate = self.nRate - 1
    end
    q = { head = 1, tail = 0 }
    self.rate[sender] = q
    self.nRate = self.nRate + 1
  end
  while q.head <= q.tail and q[q.head] <= now - Reassembly.RATE_WINDOW do
    q[q.head] = nil
    q.head = q.head + 1
  end
  if q.tail - q.head + 1 >= Reassembly.RATE then return false end
  q.tail = q.tail + 1
  q[q.tail] = now
  return true
end

local function remember(self, key)
  local old = self.doneRing[self.doneNext]
  if old then self.done[old] = nil end
  self.doneRing[self.doneNext] = key
  self.done[key] = true
  self.doneNext = self.doneNext % Reassembly.DONE_KEPT + 1
end

local function expire(self, now)
  for _, p in pairs(self.open) do
    if now - p.last > Reassembly.STALE then drop(self, p, "lost_chunk") end
  end
end

function Reassembly:sweep()
  local now = self.now()
  expire(self, now)
  for sender, q in pairs(self.rate) do
    while q.head <= q.tail and q[q.head] <= now - Reassembly.RATE_WINDOW do
      q[q.head] = nil
      q.head = q.head + 1
    end
    if q.head > q.tail and not self.perSender[sender] then
      self.rate[sender] = nil
      self.nRate = self.nRate - 1
    end
  end
end

function Reassembly:feed(sender, chunk, secret)
  if secret or type(sender) ~= "string" or type(chunk) ~= "string" then
    self:count("secret")
    return nil
  end
  if self.isSelf(sender) then
    self:count("echo")
    return nil
  end
  local now = self.now()
  expire(self, now)
  if not underRate(self, sender, now) then
    self:count("flood")
    return nil
  end
  local h, why = ns.Wire.parseChunk(chunk)
  if not h then
    self:count(why)
    return nil
  end
  local key = sender .. "\0" .. h.id
  if self.done[key] then
    self:count("dup_chunk")
    return nil
  end
  local p = self.open[key]
  if p then
    if p.total ~= h.total then
      drop(self, p, "bad_chunk")
      return nil
    end
    if p.parts[h.index] then
      self:count("dup_chunk")
      return nil
    end
  else
    -- Make room before opening: this sender's oldest, then the oldest overall.
    while (self.perSender[sender] or 0) >= Reassembly.PER_SENDER do
      local o = oldest(self, sender)
      if not o then break end
      drop(self, o, "lost_chunk")
    end
    while self.nOpen >= Reassembly.MAX_OPEN do
      local o = oldest(self)
      if not o then break end
      drop(self, o, "lost_chunk")
    end
    self.seq = self.seq + 1
    p = { key = key, sender = sender, total = h.total, got = 0, parts = {}, bytes = 0, seq = self.seq, last = now }
    self.open[key] = p
    self.nOpen = self.nOpen + 1
    self.perSender[sender] = (self.perSender[sender] or 0) + 1
  end
  while self.bytes + #h.data > Reassembly.MAX_BYTES do
    local o = oldest(self)
    if not o or o == p then break end
    drop(self, o, "lost_chunk")
  end
  if self.bytes + #h.data > Reassembly.MAX_BYTES then
    drop(self, p, "lost_chunk")
    return nil
  end
  p.parts[h.index] = h.data
  p.got = p.got + 1
  p.bytes = p.bytes + #h.data
  p.last = now
  self.bytes = self.bytes + #h.data
  if p.got < p.total then return nil end
  local text = concat(p.parts, "", 0, p.total - 1)
  drop(self, p)
  remember(self, key)
  return text
end

return Reassembly
