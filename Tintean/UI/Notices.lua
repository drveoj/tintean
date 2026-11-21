-- The Refused and States sheets (docs/mockups/addon): what a refused sign-up, a word, an old or unreadable inbox, another
-- guild or no guild say. Pure: no widgets, callers pass the guild table, `now` and the date function. The words are the
-- README's strings tables; the few it lacks are marked "for Joe to read".
local _, ns = ...
ns = ns or {}

local UI, Store = ns.UI, ns.Store
local E = UI.Events
local N = {}
UI.Notices = N

N.TEXT = {
  dropped = "The game has dropped it.",
  epochTitle = "Tinteán's records for %s were started again on the website.",
  epochLine = "What the game held was replaced. Changes you made here and haven't sent yet are kept, and the website will take or turn down each one.",
  cancelled = "the event was cancelled", -- for Joe to read: the sheet names who ("Brannoc cancelled the event"); the notice doesn't carry it
  yours = "Your sign-up", -- for Joe to read: the sheet's "Drveoj Gugivulg's sign-up" where no name is held
  officers = "Only officers can change events.",
  wordChat = "A word about your sign-up for ",
  oldLine = "Nothing newer has come from the desktop app or a guildmate since. Start the desktop app and log in again to bring it up to date.",
  newer = "The desktop app wrote data for a newer Tinteán.",
  newerLine = "Update the addon from the desktop app or CurseForge, then log in again. Until then you see what guildmates send.",
  unreadable = "The desktop app's file couldn't be read.",
  unreadableLine = "Tinteán is using what guildmates send. /tintean check says more.",
  waiting = "Waiting for the game's guild details.",
  open = "Open the event", -- the sheet's "Open the event →": the arrow is not drawn (the fonts have none)
  noGuild = "Tinteán's events and bulletins come from your guild. Log in on a character in one.",
  notInGuild = " isn't in a guild.", -- after the character's name
  thisCharacter = "This character", -- for Joe to read: where the game gives no name
}

local STATUS = { yes = "In", maybe = "Maybe", no = "Can't" }
local ROLE = { tank = "tank", healer = "healer", dps = "damage" }
local function bodyOf(r) return type(r) == "table" and type(r.body) == "table" and r.body or {} end
local function live(r) return r ~= nil and not r.deleted end

local function titleOf(g, eventId)
  local ev = eventId and Store.current(g, "event", eventId)
  local t = live(ev) and bodyOf(ev).title
  return type(t) == "string" and t ~= "" and UI.esc(E.bound(t, 80)) or "an event"
end

local function nameOf(g, rosterId)
  local b = rosterId and bodyOf(Store.current(g, "roster", rosterId)) or {}
  if type(b.first) ~= "string" then return nil end
  return UI.esc(E.bound(b.first .. (type(b.second) == "string" and (" " .. b.second) or ""), 60))
end

-- The notices in the order they came, newest first.
local function sorted(g, kinds)
  local out = {}
  for cid, n in pairs(type(g) == "table" and type(g.notices) == "table" and g.notices or {}) do
    if type(n) == "table" and kinds[n.kind] then out[#out + 1] = { cid = cid, n = n } end
  end
  table.sort(out, function(a, b)
    if (a.n.at or 0) ~= (b.n.at or 0) then return (a.n.at or 0) > (b.n.at or 0) end
    return a.cid < b.cid
  end)
  return out
end

local REFUSALS = { refused = true, changed = true, epoch = true }

-- The notices on Events, one per sign-up or edit the server did not take: { cid, event, title, line }.
function N.refusals(g, date)
  local out = {}
  for _, it in ipairs(sorted(g, REFUSALS)) do
    local n = it.n
    if n.kind == "epoch" then
      local gname = type(n.guild) == "string" and n.guild ~= "" and UI.esc(E.bound(n.guild, 80)) or "your guild"
      out[#out + 1] = { cid = it.cid, title = string.format(N.TEXT.epochTitle, gname), line = N.TEXT.epochLine }
    else
    local eventId, rosterId = ns.Validate.splitSignupId(type(n.id) == "string" and n.id or "")
    eventId = eventId or n.id
    local title = titleOf(g, eventId)
    local who = nameOf(g, rosterId)
    local mine = who and (who .. "'s sign-up") or N.TEXT.yours
    local item
    local ev0 = Store.current(g, "event", eventId)
    local gname = type(bodyOf(ev0).group) == "table" and E.bound(bodyOf(ev0).group.name, 60) or nil
    if n.kind == "changed" then
      local held = Store.currentIn(g, n.web, "signup", n.id)
      local b = bodyOf(held)
      if live(held) and STATUS[b.status] then
        local now = STATUS[b.status] .. (ROLE[b.role] and (", " .. ROLE[b.role]) or "") .. "."
        local author = n.web and b.status == "no" and type(held.author) == "table" and held.author.roster or nil
        local mover, moved = E.first(nameOf(g, author)), E.first(who)
        if author and author ~= rosterId and mover and moved and UI.isMine(g, author) then
          item = { title = string.format(E.TEXT.movedLine, moved, mover) } -- without both names it stays the generic line
        elseif n.web then
          item = { title = "Your sign-up for " .. title .. " was changed on tintean.net. Here is what it says now.", line = now }
        else
          item = { title = "Someone changed " .. (who and (who .. "'s") or "your") .. " sign-up for " .. title .. " first. It now says:",
            line = now }
        end
      end
    elseif n.reason == "forbidden" and gname then
      item = { title = "Not signed up for " .. title .. ". Only " .. gname .. "'s people can sign up for it." }
    elseif n.reason == "invalid" then
      item = { title = mine .. " for " .. title .. " couldn't be saved: " .. N.TEXT.cancelled .. ".", line = N.TEXT.dropped }
    elseif n.reason == "unknown_author" then
      item = { title = E.TEXT.unlisted[1], line = E.TEXT.unlisted[2] }
    elseif n.reason == "forbidden" then
      item = { title = N.TEXT.officers, line = "Your edit to " .. title
        .. " is undone. If you've just been promoted in the game, try again after the next sync." }
    else
      local ev = Store.current(g, "event", eventId)
      local ok, day = pcall(date, "%A", bodyOf(ev).starts)
      item = { title = E.TEXT.refused, line = (who or N.TEXT.yours) .. ", for " .. title
        .. ((live(ev) and ok and type(day) == "string") and (" on " .. day) or "") .. "." }
    end
    if item then
      item.cid, item.event = it.cid, eventId
      out[#out + 1] = item
    end
    end
  end
  return out
end

-- Dismissing a notice drops it from the guild's table.
function N.dismiss(g, cid)
  if type(g) == "table" and type(g.notices) == "table" then g.notices[cid] = nil end
end

-- The chat lines for notices not yet told (a sign-up not taken, a word), each once: marked `told` as they are returned.
-- Only about sign-ups; an officer's refused edit has the notice on Events and no line.
function N.chat(g, _now, allowed)
  local out = {}
  if allowed == false then return out end
  for _, it in ipairs(sorted(g, { refused = true, word = true, needs_ack_relayed = true })) do
    local n = it.n
    if not n.told then
      local eventId = n.kind == "refused" and ns.Validate.splitSignupId(type(n.id) == "string" and n.id or "") or n.event
      if type(eventId) == "string" then
        n.told = true
        local title = titleOf(g, eventId)
        out[#out + 1] = n.kind == "refused" and ("Your sign-up for " .. title .. " wasn't taken.") or (N.TEXT.wordChat .. title .. ".")
      end
    end
  end
  return out
end

-- "Tue 10 Nov, 21:14"
local function stamp(date, t)
  local ok, s = pcall(date, "%a %d %b, %H:%M", t)
  return ok and type(s) == "string" and (s:gsub("^(%a+) 0", "%1 ")) or nil
end

-- What the inbox and the game's guild details say, as { panel = { title, line } | nil, notices = { { key, title, line } } }.
-- env: guild, guildName, player, inbox (ns.inbox, what the last read of Tintean_Inbox found), now, date.
function N.state(env)
  local g, inbox, name = env.guild, type(env.inbox) == "table" and env.inbox or {}, env.guildName
  local out = { notices = {} }
  if type(name) ~= "string" or name == "" then
    if inbox.state == "no_guild" then
      local who = type(env.player) == "string" and env.player ~= "" and UI.esc(env.player) or N.TEXT.thisCharacter
      out.panel = { title = who .. N.TEXT.notInGuild, line = N.TEXT.noGuild }
    else
      out.panel = { title = N.TEXT.waiting }
    end
    return out
  end
  local empty = type(g) ~= "table" or (next(g.records or {}) == nil and not (type(g.inbox) == "table" and g.inbox.at))
  local gname = UI.esc(name)
  if inbox.state == "other_guild" and empty then
    out.panel = { title = "Nothing for " .. gname .. ".", -- for Joe to read: the sheet names the desktop app's guild, which the inbox does not
      line = "The desktop app on this computer has data for another guild, and no one in " .. gname .. " has sent any. If "
        .. gname .. " isn't on Tinteán yet, an officer can add it on tintean.net." }
  end
  local add = function(key, title, line) out.notices[#out.notices + 1] = { key = key, title = title, line = line } end
  if inbox.state == "old" and type(inbox.at) == "number" and stamp(env.date, inbox.at) then
    add("old", "This is from " .. stamp(env.date, inbox.at) .. ".", N.TEXT.oldLine)
  elseif inbox.state == "newer" then
    add("newer", N.TEXT.newer, N.TEXT.newerLine)
  elseif inbox.state == "damaged" then
    add("damaged", N.TEXT.unreadable, N.TEXT.unreadableLine)
  end
  return out
end

return N
