-- The saved data, `Tintean` (formats/game.md section 11): loading, migration, read-only mode, damage,
-- the error ring and what is done at logout. The only module that touches the table the game saves.
-- Pure but for the event frame at the bottom: callers pass `now`.
local addonName, ns = ...
ns = ns or {}

local SV = {}
ns.SavedVars = SV

local Json, Store = ns.Json, ns.Store
local null = Json.null

SV.SCHEMA = 5
SV.PROTO = 1
SV.ERROR_RING = 50
-- MIGRATIONS[n](db) turns a schema n-1 table into schema n.
SV.MIGRATIONS = {}

-- 2: the roster comes from the game (M25), so ids that were the server's uuids are gone. Held server data (records, what
-- was settled, the cursors) is dropped and comes again from the next exchange; a pending edit made under a uuid roster id
-- is dropped (it could never be accepted); settings, notices and the rest stay. Sees frozen data.
local function uuidRoster(p)
  local a = type(p) == "table" and p.author
  return type(a) == "table" and type(a.roster) == "string" and a.roster:find("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil
end
SV.MIGRATIONS[2] = function(db)
  for _, g in pairs(type(db.guilds) == "table" and db.guilds or {}) do
    if type(g) == "table" then
      for _, f in ipairs({ "records", "settled", "cursor", "floor", "top", "words", "ahead" }) do
        if type(g[f]) == "table" then g[f] = {} end
      end
      if type(g.pending) == "table" then
        for slot, p in pairs(g.pending) do
          if uuidRoster(p) then g.pending[slot] = nil end
        end
      end
    end
  end
end

-- 3: moments (formats/moments/README.md): the switch, on by default, and the store. Nothing else changes.
SV.MIGRATIONS[3] = function(db)
  if type(db.settings) ~= "table" then db.settings = {} end
  if db.settings.moments == nil then db.settings.moments = true end
  if type(db.moments) ~= "table" then db.moments = {} end
end

-- 4: epochs (game.md section 7). Every guild and every pending edit gets epoch 0; nothing else changes.
SV.MIGRATIONS[4] = function(db)
  for _, g in pairs(type(db.guilds) == "table" and db.guilds or {}) do
    if type(g) == "table" then
      g.epoch = 0
      if type(g.pending) == "table" then
        for _, p in pairs(g.pending) do
          if type(p) == "table" then p.epoch = 0 end
        end
      end
    end
  end
end

-- 5: `mine` (decisions.md M33.12, 11.3): each guild gets an empty store of the person's own sign-ups on their groups' events.
-- Nothing else changes.
SV.MIGRATIONS[5] = function(db)
  for _, g in pairs(type(db.guilds) == "table" and db.guilds or {}) do
    if type(g) == "table" and g.mine == nil then g.mine = { rev = 0, records = {}, pending = {}, may = {} } end
  end
end

SV.NOTICE = {
  title = "Your saved data is from a newer Tinteán.",
  line = "Update the addon, then reload. Until you do, Tinteán saves nothing. You still receive what guildmates send.",
}
SV.MIGRATION_NOTICE = {
  title = "Tinteán could not update your saved data.",
  line = "It saves nothing this session. You still receive what guildmates send.",
}
SV.DAMAGED_NOTICE = { title = "Tinteán could not read your saved data, so it started again." }

local function bump(counters, name, n) counters[name] = (counters[name] or 0) + (n or 1) end

local function isInt(x) return type(x) == "number" and x == math.floor(x) and x > -9007199254740992 and x < 9007199254740992 end

local function defaultSettings()
  return { chatLine = true, toast = true, loginReminder = true, remind15 = true, sound = false,
    minimap = { hide = false, angle = 225 }, share = true, moments = true }
end

local function fresh()
  return { schema = SV.SCHEMA, settings = defaultSettings(), tour = { shown = 0, at = 0 }, guilds = {}, moments = {},
    diag = { errors = {}, last = {} } }
end

local function deepCopy(v)
  if type(v) ~= "table" or v == null then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = deepCopy(x) end
  return c
end

-- The game cannot save the Json.null sentinel (it would come back as an empty table), so at logout it becomes
-- { [0] = true } and at load it becomes the sentinel again. The marker's key is the number 0: Json.decode only
-- makes string keys (and arrays from 1), so no body from the wire, a paste or the inbox can look like it.
-- Migrations run before thaw: they see frozen data.
local function walk(t, fn, depth)
  if depth > 24 then return end
  for k, v in pairs(t) do
    if type(v) == "table" then
      local r = fn(v)
      if r ~= nil then t[k] = r else walk(v, fn, depth + 1) end
    end
  end
end
local function freezeOne(v) if v == null then return { [0] = true } end end
local function thawOne(v)
  if v[0] ~= true then return nil end
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  if n == 1 then return null end
end

-- Works on a copy and swaps it in only when it is whole.
function SV.freeze(db)
  if not db.guilds then return end
  local g = deepCopy(db.guilds)
  walk(g, freezeOne, 0)
  db.guilds = g
end

-- Arrays lose their marker in the file (an empty one would come back as an object): put it back where the shapes have one.
local function remark(e)
  if type(e.ack) == "table" and e.ack ~= null and not Json.isArray(e.ack) then Json.array(e.ack) end
  local b = e.body
  if type(b) == "table" and b ~= null and type(b.names) == "table" and b.names ~= null and not Json.isArray(b.names) then
    Json.array(b.names)
  end
end

local function remarkAll(t)
  if type(t) ~= "table" then return end
  for _, e in pairs(t) do
    if type(e) == "table" then remark(e) end
  end
end

function SV.thaw(db)
  if not db.guilds then return end
  walk(db.guilds, thawOne, 0)
  for _, g in pairs(db.guilds) do
    if type(g) == "table" then
      for _, f in ipairs({ "records", "pending" }) do remarkAll(g[f]) end
      if type(g.mine) == "table" then remarkAll(g.mine.pending) end
    end
  end
end

local TABLE_FIELDS = { "records", "pending", "settled", "cursor", "floor", "top", "dismissed", "seenHere", "notices", "words", "ahead" }

local function whole(x) return type(x) == "number" and x >= 0 and x == math.floor(x) and x < math.huge end

-- A pending edit without a cid or a time is dropped; a non-whole epoch becomes the guild's, a non-whole rebase goes.
local function repairPending(pending, epoch, counters)
  for slot, p in pairs(pending) do
    if type(p.cid) ~= "string" or type(p.at) ~= "number" then
      pending[slot] = nil
      bump(counters, "pending_damaged")
    else
      if p.epoch ~= nil and not whole(p.epoch) then p.epoch = epoch end
      if p.rebase ~= nil and not whole(p.rebase) then p.rebase = nil end
    end
  end
end

-- Whether a guild's table has the shape Store works with; fills what is missing.
local function repairGuild(key, g, counters)
  if type(key) ~= "string" or type(g) ~= "table" then return nil end
  if g.name ~= nil and type(g.name) ~= "string" then return nil end
  if g.inbox ~= nil and type(g.inbox) ~= "table" then return nil end
  if g.report ~= nil and type(g.report) ~= "table" then g.report = nil end -- the roster report is read again
  for _, f in ipairs(TABLE_FIELDS) do
    if g[f] ~= nil and type(g[f]) ~= "table" then return nil end
  end
  for _, f in ipairs({ "records", "pending" }) do
    for _, v in pairs(g[f] or {}) do
      if type(v) ~= "table" then return nil end
    end
  end
  for _, v in pairs(g.settled or {}) do
    if type(v) ~= "number" then return nil end
  end
  if not whole(g.epoch) then g.epoch = 0 end
  repairPending(g.pending or {}, g.epoch, counters)
  if type(g.mine) ~= "table" then g.mine = nil end -- Store.new supplies an empty one below; the guild and its pending stay
  if g.mine ~= nil then -- a damaged part of `mine` is made empty; the rest of the guild is not lost for it
    local m = g.mine
    for _, f in ipairs({ "records", "pending", "may" }) do
      if type(m[f]) ~= "table" then m[f] = {} end
    end
    if not whole(m.rev) then m.rev = 0 end
    for _, f in ipairs({ "records", "pending" }) do
      for slot, v in pairs(m[f]) do
        if type(v) ~= "table" then m[f][slot] = nil end
      end
    end
    repairPending(m.pending, g.epoch, counters)
  end
  local base = Store.new(g.name or key, 0)
  for k, v in pairs(base) do
    if g[k] == nil then g[k] = v end
  end
  for _, kind in ipairs(Store.KINDS) do
    if type(g.cursor[kind]) ~= "number" then g.cursor[kind] = 0 end
  end
  return g
end

-- Runs the migrations from `schema` up to ours on a copy; returns the migrated table, or nil on a failed step.
function SV.migrate(db, migrations)
  local work = deepCopy(db)
  for n = (db.schema or 0) + 1, SV.SCHEMA do
    local step = migrations[n]
    if type(step) ~= "function" then return nil end
    local ok = pcall(step, work)
    if not ok then return nil end
    work.schema = n
  end
  return work
end

-- Everything that changes the data happens on a copy, so `before` is never touched.
local function prepare(before, counters, now, migrations)
  local db = deepCopy(before)
  if db.schema < SV.SCHEMA then
    db = SV.migrate(db, migrations or SV.MIGRATIONS)
    if not db then return nil end
  end
  local d = fresh()
  for k, v in pairs(d) do
    if type(db[k]) ~= type(v) then db[k] = v end
  end
  for k, v in pairs(d.settings) do
    if db.settings[k] == nil then db.settings[k] = deepCopy(v) end
  end
  if type(db.diag.errors) ~= "table" then db.diag.errors = {} end
  if type(db.diag.last) ~= "table" then db.diag.last = {} end
  local guilds = {}
  for key, g in pairs(db.guilds) do
    guilds[key] = repairGuild(key, g, counters)
    if guilds[key] == nil then bump(counters, "guild_damaged") end
  end
  db.guilds = guilds
  SV.thaw(db)
  SV.pruneAll(db, now, counters)
  return db
end

-- `before` is the table the game hands over at ADDON_LOADED (nil: none).
-- Returns a state: { db, readOnly, damaged, counters, notice }. `before` is never modified. Unless readOnly,
-- db is a working copy to assign to the global; when readOnly the global stays as the game gave it.
function SV.load(before, now, migrations)
  local st = { counters = {}, readOnly = false }
  if before == nil then
    st.db = fresh()
  elseif type(before) ~= "table" or not isInt(before.schema) or before.schema < 1 then
    st.db, st.damaged, st.notice = fresh(), { at = now }, SV.DAMAGED_NOTICE
    st.db.damaged = st.damaged
  elseif before.schema > SV.SCHEMA then
    st.db, st.readOnly, st.notice = fresh(), true, SV.NOTICE
  else
    local ok, db = pcall(prepare, before, st.counters, now, migrations)
    if ok and db then
      st.db = db
    else
      st.counters = {}
      st.db, st.readOnly, st.notice = fresh(), true, SV.MIGRATION_NOTICE
    end
  end
  return st
end

-- Prune every guild and the guild cap. Only after an inbox read, a paste, a completed transfer, and at login:
-- never in the middle of a transfer (Store.prune drops sign-ups whose event has not arrived yet).
function SV.pruneAll(db, now, counters, current)
  for _, g in pairs(db.guilds) do Store.prune(g, now, counters) end
  Store.pruneGuilds(db.guilds, counters, current)
  local M = ns.Moments
  if M and M.Store then pcall(M.Store.prune, db, now, counters) end
end

function SV.logError(db, now, where, msg)
  local ring = db.diag.errors
  ring[#ring + 1] = { at = now, where = where, msg = tostring(msg):sub(1, 300) }
  while #ring > SV.ERROR_RING do table.remove(ring, 1) end
end

-- At PLAYER_LOGOUT. Read-only mode writes nothing. A failure keeps the previous `out` and never stops logout.
-- opts.build replaces Export.build (tests).
function SV.logout(st, now, addon, opts)
  if st.readOnly then return end
  local db = st.db
  if st.damaged and not st.damagedLogged then
    st.damagedLogged = true
    SV.logError(db, st.damaged.at, "load", "saved data was damaged and was started again")
  end
  local build = opts and opts.build or ns.Export.build
  local ok, out, failed = pcall(build, db, now, addon)
  if ok and type(out) == "table" then
    db.out = out
    for key, code in pairs(failed or {}) do SV.logError(db, now, "export", key .. ": " .. tostring(code)) end
  else
    SV.logError(db, now, "export", out)
  end
  db.written = { at = now, addon = addon, proto = SV.PROTO }
  db.diag.last = deepCopy(st.counters)
  local fok, why = pcall(SV.freeze, db)
  if not fok then SV.logError(db, now, "freeze", why) end
end

if type(CreateFrame) == "function" then
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("ADDON_LOADED")
  frame:RegisterEvent("PLAYER_LOGOUT")
  frame:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" and name == addonName then
      local ok, st = ns.try(SV.load, Tintean, time())
      if not ok then st = { db = fresh(), readOnly = true, counters = {} } end
      ns.state = st
      if not st.readOnly then Tintean = st.db end
      if st.notice then
        ns.print(ns.tag .. " " .. st.notice.title .. (st.notice.line and (" " .. st.notice.line) or ""))
      end
    elseif event == "PLAYER_LOGOUT" and ns.state then
      if ns.Report then ns.try(ns.Report.logout) end -- the game's roster as it stands, before the export is built
      ns.try(SV.logout, ns.state, time(), ns.version)
    end
  end)
end
