-- Warnings the server raised on a sign-up (formats/game.md section 9: needs_ack, ahead of the click; the
-- design calls one "the word"). The text comes from the desktop app's inbox, is shown only to the person it
-- is about, and never goes on the wire: what goes out is a new sign-up carrying `ack` (the refs shown).
-- Fixture: game/words.json. The strings a person reads are written by the screens (M20.14), not here.
local _, ns = ...
ns = ns or {}

local Words = {}
ns.Words = Words

local Store, Sync, Edit = ns.Store, ns.Sync, ns.Edit

local function wall()
  local ok, t = ns.try(time)
  return ok and type(t) == "number" and t or 0
end

local function refuse(reason) return "refused: " .. reason end

-- The guild, my roster record, and whether the inbox's person is me. Words and `ahead` are private to
-- the person: another character on this computer, with another person's handle, sees nothing.
local function mine(anyone)
  local g = Sync.guild()
  if not g then return nil end
  local me = Edit.me(g)
  if not me then return nil end
  if anyone then return g, me end
  local person = type(me.body) == "table" and me.body.person
  if type(person) ~= "string" or person ~= g.person then return nil end
  return g, me
end

local function refsOf(list)
  local refs = {}
  for i, w in ipairs(list) do refs[i] = w.ref end
  return refs
end

local function textsOf(list)
  local texts = {}
  for i, w in ipairs(list) do texts[i] = w.text end
  return texts
end

-- The entry of `words` that is still to be answered for this event: mine, not dismissed, the correction it
-- came with still the held version, and no newer edit of mine pending on the sign-up.
local function activeWord(g, me, eventId)
  local slot = Store.slot("signup", eventId .. ":" .. me.id)
  if g.pending[slot] then return nil end
  local held = g.records[slot]
  for _, w in ipairs(g.words or {}) do
    if w.event == eventId and w.roster == me.id and not (g.dismissed or {})[w.cid] and held and held.rev == w.rev then
      return w
    end
  end
end

-- The refusal notice for a needs_ack that came back with no words entry (a guildmate's app carried it).
-- It carries no text, so it needs no person check: it is about my own edit.
local function relayedNotice(g, me, eventId)
  local id = eventId .. ":" .. me.id
  if g.pending[Store.slot("signup", id)] then return nil end
  local held = g.records[Store.slot("signup", id)]
  for _, n in pairs(g.notices or {}) do
    if n.kind == "needs_ack_relayed" and n.id == id and held and held.rev == n.rev then return n end
  end
end

-- What to show on an event for the character logged in, or nil.
--   { cid, warnings = { { code, ref, text } }, refs, texts }  a refused sign-up's warnings (`cid` is the entry's),
--   { ahead = true, warnings, refs, texts }                   warnings the server would raise now,
--   { relayed = true, cid }                                   needs_ack with nothing to read: sign up on the website.
function Words.forEvent(eventId)
  local g, me = mine(true)
  if not g then return nil end
  local private = mine()
  local w = private and activeWord(g, me, eventId) or nil
  if w then
    return { cid = w.cid, warnings = w.warnings, refs = refsOf(w.warnings), texts = textsOf(w.warnings) }
  end
  for _, a in ipairs(private and g.ahead or {}) do
    if a.event == eventId and a.roster == me.id and #a.warnings > 0 then
      return { ahead = true, warnings = a.warnings, refs = refsOf(a.warnings), texts = textsOf(a.warnings) }
    end
  end
  local n = relayedNotice(g, me, eventId)
  if n then return { relayed = true, cid = n.cid } end
  return nil
end

-- Sign up (or change a sign-up) carrying the refs of the warnings I was shown ahead of the click. Only a "yes"
-- carries them: the warnings are about signing up, and a Maybe or Can't does not accept them.
function Words.signUp(eventId, status, extra)
  local e = {}
  for k, v in pairs(extra or {}) do e[k] = v end
  local shown = status == "yes" and e.ack == nil and Words.forEvent(eventId) or nil
  if shown and shown.ahead then e.ack = shown.refs end
  return Edit.signUp(eventId, status, e)
end

-- Sign up anyway: a new edit on top of the correction, the body from the entry, every shown ref acked.
function Words.signUpAnyway(eventId)
  local g, me = mine()
  if not g then return refuse("no_word") end
  local w = activeWord(g, me, eventId)
  if not w then return refuse("no_word") end
  local extra = { ack = refsOf(w.warnings) }
  if w.body.role ~= nil then extra.role = w.body.role end
  if w.body.note ~= nil then extra.note = w.body.note end
  return Edit.signUp(eventId, w.body.status, extra)
end

-- Not now changes nothing.
function Words.notNow(_eventId) return "kept" end

-- Dismiss: the entry's cid goes in the export's `dismissed`, so the app stops writing it.
function Words.dismiss(eventId)
  local g, me = mine()
  if not g then return refuse("no_word") end
  local w = activeWord(g, me, eventId)
  if not w then return refuse("no_word") end
  local t = wall()
  if t <= 0 then return refuse("no_clock") end -- no clock: nothing is written, so a stamp of nought can't be kept
  g.dismissed = g.dismissed or {}
  g.dismissed[w.cid] = t
  Sync.touch()
  return "dismissed"
end

return Words
