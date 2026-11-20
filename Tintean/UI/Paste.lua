-- Copy and paste, the fallback for a guild with nobody running the desktop app: what goes out (held edits as a TN1: string)
-- and what comes in (the website's records string, replacing the held copy). Pure: no widgets. Words are the README's strings
-- table (docs/mockups/addon, Paste); the few it lacks are marked "for Joe to read". A pasted string is untrusted: the
-- codec bounds and validates it, each record is checked as the inbox's are, and nothing in it is ever run.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local P = {}
UI.Paste = P

P.TEXT = {
  title = "Copy and paste", from = "From the website", forSite = "For the website",
  fromHelp = "On the guild's page, press Copy for the game, then paste here with Ctrl+V.",
  import = "Import",
  many = "%s changes made in game that the website doesn't have yet. Press Ctrl+C, then paste them on the guild's page under Paste from the game.",
  one = "One change made in game that the website doesn't have yet. Press Ctrl+C, then paste it on the guild's page under Paste from the game.", -- for Joe to read
  rosterOnly = "The guild roster as the game shows it. Press Ctrl+C, then paste it on the guild's page under Paste from the game.", -- for Joe to read
  rosterTooBig = "The guild roster is too big to paste. The desktop app sends it.", -- for Joe to read
  momentsOnly = "What your character did while grouped with guildmates. Press Ctrl+C, then paste it on the guild's page under Paste from the game.", -- for Joe to read
  rosterAndMoments = "The guild roster as the game shows it, and what your character did while grouped with guildmates. Press Ctrl+C, then paste them on the guild's page under Paste from the game.", -- for Joe to read
  momentsNone ="The moments from your recent nights didn't fit. The desktop app sends them.", -- for Joe to read
  momentsOneLeft = "The moments from one night didn't fit. Copy again after pasting to send them.", -- for Joe to read
  momentsLeft = "The moments from %s nights didn't fit. Copy again after pasting to send them.", -- for Joe to read
  app = "The desktop app does this for you at each login and logout.",
  nothing = "Nothing to send. The website has everything made in game.",
  imported = "Imported the website's copy from %s today.",
  wrongGuild = "That string is for %s. %s is in %s.",
  truncated = "That string is cut off. Copy it again from the website, all of it.",
  notTintean = "That string isn't from Tinteán.",
  newer = "That string is from a newer Tinteán. Update the addon, then try again.",
  tooLarge = "That string is too big to read.", -- for Joe to read
  unreadable = "That string unpacked, but Tinteán can't read it.", -- for Joe to read
  fromGame = "That string is from the game. Press Copy for the game on the guild's page, then paste that.", -- for Joe to read
  empty = "Paste the string from the website first.", -- for Joe to read
  tooMany = "There are too many changes to paste. The desktop app sends them.", -- for Joe to read
  noGuild = "Tinteán can't tell which guild this is. Log in with a guild character, then try again.", -- for Joe to read
  boss = "Not during a boss fight. Try again when it's over.", -- for Joe to read
  cannotSave = "Tinteán can't save changes right now.", -- for Joe to read
}

-- Pack's code for each refusal, in the README's words.
local BY_CODE = {
  truncated = "truncated", wrong_prefix = "notTintean", newer = "newer", too_large = "tooLarge", invalid = "unreadable",
}

local function bump(counters, name)
  if counters then counters[name] = (counters[name] or 0) + 1 end
end

-- A name from a string we don't trust, for a line of text: no control characters, bounded.
local function shown(s)
  if type(s) ~= "string" or s == "" then return "another guild" end
  s = s:gsub("%c", ""):sub(1, 60)
  return UI.esc and UI.esc(s) or s
end

---------------------------------------------------------------------------------------------- out

-- The string of the held edits for the website: { count, text, line }. text is nil when there is nothing to send or the
-- string is over the paste limit (line says which); line is the sentence under the heading.
-- `db` (the saved data) and `now` let the string carry the moments noted in game; the nights it carries are marked copied.
function P.outgoing(slug, guild, db, now, limits)
  local n = 0
  for _ in pairs(type(guild) == "table" and guild.pending or {}) do n = n + 1 end
  for _ in pairs(type(guild) == "table" and type(guild.mine) == "table" and guild.mine.pending or {}) do n = n + 1 end
  local report = type(guild) == "table" and type(guild.report) == "table"
  local held = #ns.Export.heldMoments(db, guild) > 0
  if n == 0 and not report and not held then return { count = 0, line = P.TEXT.nothing } end
  local ok, s, _, dropped, info = pcall(function() return ns.Export.pack(slug, guild, limits, { db = db }) end)
  if not ok then s = nil end
  if type(s) ~= "string" then return { count = n, line = n == 0 and P.TEXT.nothing or P.TEXT.tooMany } end
  local sent = info and info.sent or 0
  if n == 0 and sent == 0 then -- nothing but the roster and moments could go, and neither did
    if dropped then
      return { count = 0, line = held and (P.TEXT.rosterTooBig .. " " .. P.TEXT.momentsNone) or P.TEXT.rosterTooBig }
    end
    if not report then return { count = 0, line = P.TEXT.momentsNone } end
  end
  local line
  if n > 0 then
    line = n == 1 and P.TEXT.one or string.format(P.TEXT.many, UI.number(n))
  elseif report and not dropped and sent > 0 then
    line = P.TEXT.rosterAndMoments
  elseif report and not dropped then
    line = P.TEXT.rosterOnly
  else
    line = P.TEXT.momentsOnly .. (dropped and (" " .. P.TEXT.rosterTooBig) or "")
  end
  if info and info.held > info.sent then -- some nights did not fit
    local left = info.held - info.sent
    if info.sent == 0 then
      line = line .. " " .. P.TEXT.momentsNone
    else
      line = line .. " " .. (left == 1 and P.TEXT.momentsOneLeft or string.format(P.TEXT.momentsLeft, UI.number(left)))
    end
  end
  if info and now then
    for _, m in ipairs(info.marks) do
      if type(m.e.copied) ~= "table" then m.e.copied = {} end
      m.e.copied[m.first] = now
    end
  end
  return { count = n, text = s, line = line, moments = info and info.moments or 0 }
end

---------------------------------------------------------------------------------------------- in

local function shallow(t)
  local c = {}
  for k, v in pairs(t or {}) do c[k] = v end
  return c
end

-- Applies the website's snapshot to a copy of the guild and swaps it in only when all of it went well.
local function apply(db, slug, payload, ctx)
  local Store, Inbox, Order = ns.Store, ns.Inbox, ns.Order
  local held = db.guilds[slug]
  local g = held and shallow(held) or Store.new(ctx.guildName, ctx.now)
  if not held then g.key = Inbox.key(ctx.guildName) end
  for _, f in ipairs({ "records", "pending", "settled", "cursor", "floor", "top", "notices", "dismissed" }) do
    g[f] = shallow(g[f])
  end
  -- A new epoch (game.md section 7), as for the inbox: the held server versions go, edits not yet up are kept and rebased.
  local newEpoch = payload.epoch ~= nil and payload.epoch ~= (g.epoch or 0)
  local stashed
  if newEpoch then
    Store.newEpoch(g, payload.epoch, ctx.now, ctx.counters, payload.name)
    stashed = {}
    for slot, p in pairs(g.pending) do
      stashed[slot] = p
      g.pending[slot] = nil
    end
  end
  local left = {}
  for _, k in ipairs(type(payload.leftOut) == "table" and payload.leftOut or {}) do
    if type(k) == "string" then left[k] = true end
  end

  -- What the website holds: each record checked as the inbox's are; a repeat keeps its highest rev.
  local accepted, at = {}, {}
  for i = 1, math.min(#payload.records, Inbox.MAX_RECORDS) do
    local rec = Inbox.checkRecord(payload.records[i])
    if rec then
      local slot = Store.slot(rec.kind, rec.id)
      if not at[slot] then
        accepted[#accepted + 1], at[slot] = rec, #accepted + 1
      elseif rec.rev > accepted[at[slot]].rev then
        accepted[at[slot]] = rec
      end
    else
      bump(ctx.counters, "paste_bad_record")
    end
  end

  -- It replaces the held copy: a version the string doesn't have goes, kinds it left out stay, and a version above the
  -- string's own rev (a guildmate's newer one) is kept.
  for slot, h in pairs(g.records) do
    if not left[h.kind] and h.rev <= payload.rev and not at[slot] then g.records[slot] = nil end
  end
  for _, rec in ipairs(accepted) do
    local slot = Store.slot(rec.kind, rec.id)
    local h = g.records[slot]
    if h and h.rev > payload.rev then
      bump(ctx.counters, "paste_kept_newer")
    else
      g.records[slot] = nil
      local res = Store.applyServer(g, rec, ctx.now, ctx.counters, "paste")
      for _, p in ipairs(res.dropped) do Inbox.noticeFor(g, p, res.tell, ctx.now) end
    end
  end

  if stashed then
    for slot, p in pairs(stashed) do g.pending[slot] = p end
    Store.rebase(g)
    Store.settleTaken(g, ctx.now)
  end

  -- Edits not yet up are kept, unless what is held now already outranks them.
  for slot, p in pairs(g.pending) do
    local r = g.records[slot]
    if r and Order.compare(Order.pendingKey(p), Order.serverKey(r)) <= 0 then
      g.pending[slot] = nil
      g.settled[p.cid] = ctx.now
      Inbox.noticeFor(g, p, nil, ctx.now)
    end
  end

  for _, k in ipairs(Store.KINDS) do
    if not left[k] then g.cursor[k] = payload.rev end
    g.floor[k] = payload.rev
  end
  Inbox.applyMine(g, payload, ctx.counters, true, ctx.now)
  g.src, g.lastOn = "paste", ctx.now
  Store.prune(g, ctx.now, ctx.counters)
  Store.retop(g)
  db.guilds[slug] = g
  Store.pruneGuilds(db.guilds, ctx.counters, slug)
end

-- ctx: { db, slug (the guild held for this game guild, or nil), guildName, character, now, boss, counters, date }.
-- Returns ok, the line to show. Nothing changes unless ok.
function P.import(text, ctx)
  local T = P.TEXT
  if type(text) ~= "string" or not text:find("%S") then return false, T.empty end
  if ctx.boss then return false, T.boss end
  if type(ctx.db) ~= "table" or type(ctx.db.guilds) ~= "table" or ctx.readOnly then return false, T.cannotSave end
  if type(ctx.guildName) ~= "string" or ctx.guildName == "" then return false, T.noGuild end
  local payload, code = ns.Pack.unpack(text)
  if not payload then return false, T[BY_CODE[code] or "unreadable"] end
  if payload.t == "changes" then return false, T.fromGame end
  local slug = payload.guild
  if payload.t ~= "records" or payload.full ~= true or type(payload.rev) ~= "number" or payload.rev ~= math.floor(payload.rev) or payload.rev < 0
      or #slug > 64 or not slug:find("^[a-z0-9][a-z0-9-]*$")
      or (payload.epoch ~= nil and (type(payload.epoch) ~= "number" or payload.epoch < 0 or payload.epoch ~= math.floor(payload.epoch))) then
    return false, T.unreadable
  end
  if ctx.slug and ctx.slug ~= slug then
    return false, string.format(T.wrongGuild, shown(payload.name or slug), ctx.character or "You", shown(ctx.guildName))
  end
  local ok = pcall(apply, ctx.db, slug, payload, ctx)
  if not ok then return false, T.unreadable end
  ns.Inbox.ackMoments(ctx.db, payload.moments, ctx.counters) -- what the website kept of the moments
  return true, string.format(T.imported, ctx.date("%H:%M", ctx.now))
end

return P
