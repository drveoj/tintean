-- What Plan an event says and does. Pure: no widgets. Who may plan (the guild's officer ranks, as the website sets
-- them), the form's starting values, the checks before it is sent, and the edit it makes. Words are the README's
-- strings table (docs/mockups/addon, Officers); the few the table lacks are marked "for Joe to read".
-- Times are on the player's own clock: the guild's time zone is not carried into the game.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local O = {}
UI.Officers = O

local E, R = UI.Events, UI.Roster
local DAY = 86400

O.TEXT = {
  heading = "Plan an event", title = "Title", what = "What", where = "Where", day = "Day", how = "How long", size = "Size",
  wanted = "Wanted", plan = "The plan", create = "Create event", cancel = "Cancel",
  edit = "Edit event", save = "Save event", cancelEvent = "Cancel event", undo = "Undo", -- the Officers table's
  cancelledNow = "Guildmates online see it cancelled now.", -- the Officers table's
  starts = "Starts, your time", -- for Joe to read: the table's "Starts, the guild's time", but the game has only the player's clock
  none = "None", -- for Joe to read: Where when no place is chosen (the bulletin sheet's "None")
  after = "Guildmates with the addon see the event straight away. The website gets it at the next logout by anyone with the desktop app.",
  roles = { "tanks", "healers", "damage" },
  noTitle = "Give the event a title.", badTime = "Use a time like 20:00.", past = "That start has passed.",
  tooMany = "The roles add up to more than the group size.", -- the four for Joe to read
  notOfficer = "Only officers can change events.", -- the formats README's `forbidden`, as the Refused sheet has it
  notOnRoster = "Tinteán doesn't have this character on the roster yet.", -- for Joe to read
}

O.ACTIVITIES = {
  { "levelling", "Levelling" }, { "dungeon", "Dungeon" }, { "raid", "Raid" }, { "quest_chain", "Quest chain" },
  { "pvp", "PvP" }, { "profession", "Profession" }, { "social", "Social" }, { "other", "Other" },
}
O.SIZES = { { 5, "5" }, { 10, "10" }, { 20, "20" }, { false, "Any" } }
O.LENGTHS = { 60, 90, 120, 150, 180, 240, 300, 360 } -- minutes, as the How long steps run

local function bodyOf(r) return type(r) == "table" and type(r.body) == "table" and r.body or {} end

-- Who decided: "game" (the game's own answer is yes), "record" (the game could not answer, so the held records say yes)
-- or "no". `gameSays` is the game's answer for the logged-in player: true, false, or nil when it could not answer.
-- Rank index `rank` (nil when the game can't say) and `me`, the roster record, only matter when the game did not answer.
function O.officerSource(g, rank, me, gameSays)
  if type(g) ~= "table" then return "no" end
  if gameSays == true then return "game" end
  if gameSays == false or me == nil then return "no" end
  local held
  if rank == nil then held = bodyOf(me).officer == true else held = R.officers(g)[rank] == true end
  return held and "record" or "no"
end

-- May the player plan events: the game's answer when it has one, else the held records' (an officer rank).
function O.canPlan(g, rank, me, gameSays)
  return O.officerSource(g, rank, me, gameSays) ~= "no"
end

-- The /tintean check line on why Plan an event is or isn't offered. Same rule as canPlan; `rank` is nil when the game can't say.
O.CHECK = {
  line = "Officer: %s. Rank: %s. Officer ranks held: %s. Roster record: %s.", -- for Joe to read
  cantSay = "the game can't say",
  game = "yes (the game says so)", record = "yes (held record)", no = "no", -- for Joe to read
}
function O.officerLine(g, rank, me, gameSays)
  local held = {}
  if type(g) == "table" then
    for i in pairs(R.officers(g)) do held[#held + 1] = i end
    table.sort(held)
  end
  local list = #held > 0 and table.concat(held, ", ") or "none"
  return O.CHECK.line:format(O.CHECK[O.officerSource(g, rank, me, gameSays)], rank == nil and O.CHECK.cantSay or tostring(rank),
    list, me ~= nil and "found" or "not found")
end

-- "20:00" or "9:30" as hour, minute; nil otherwise.
function O.parseTime(s)
  if type(s) ~= "string" then return nil end
  local h, m = s:match("^%s*(%d%d?):(%d%d)%s*$")
  h, m = tonumber(h), tonumber(m)
  if not h or h > 23 or m > 59 then return nil end
  return h, m
end

-- The places the guild's events carry, { ref, name, slug } by name: the addon holds no list of the game's dungeons.
function O.places(g)
  local evs, seen, out = E.held(g), {}, {}
  for _, ev in ipairs(evs) do
    local p = bodyOf(ev).place
    if type(p) == "table" and type(p.ref) == "string" and type(p.name) == "string" and not seen[p.ref] then
      seen[p.ref] = true
      out[#out + 1] = { ref = p.ref, name = E.bound(p.name, 60) or "", slug = UI.Art.slugOf(p.name) }
    end
  end
  table.sort(out, function(a, b) if a.name ~= b.name then return a.name < b.name end return a.ref < b.ref end)
  return out
end

-- A form for `stamp` (any moment on the day; nil is tomorrow): a dungeon at 20:00 for two hours, nothing else chosen.
function O.new(env, stamp)
  return { title = "", activity = "dungeon", stamp = stamp or (env.now + DAY), time = "20:00", minutes = 120, size = false,
    want = { "", "", "" }, notes = "", place = 0 }
end

-- The places for editing `ev`: the guild's, with the event's own place among them when no other event carries it.
function O.placesFor(g, ev)
  local list = O.places(g)
  local p = bodyOf(ev).place
  if type(p) ~= "table" or type(p.ref) ~= "string" then return list end
  for _, x in ipairs(list) do if x.ref == p.ref then return list end end
  local name = E.bound(p.name, 60) or ""
  list[#list + 1] = { ref = p.ref, name = name, slug = UI.Art.slugOf(name) }
  table.sort(list, function(a, b) if a.name ~= b.name then return a.name < b.name end return a.ref < b.ref end)
  return list
end

-- A form holding what event `ev` says now (Edit event), with the places it chooses from. Saving it edits that event.
function O.fromEvent(env, ev, places)
  local b = bodyOf(ev)
  local form = O.new(env, type(b.starts) == "number" and b.starts or nil)
  form.editing, form.origStarts = ev.id, b.starts
  form.title = type(b.title) == "string" and b.title or ""
  if type(b.activity) == "string" then form.activity = b.activity end
  local ok, hm = pcall(env.date, "%H:%M", b.starts)
  if ok and type(hm) == "string" then form.time = hm end
  if type(b.minutes) == "number" and b.minutes > 0 then form.minutes = b.minutes end
  form.size = type(b.size) == "number" and b.size or false
  local want = type(b.want) == "table" and b.want or {}
  for i, k in ipairs({ "tank", "healer", "dps" }) do
    form.want[i] = type(want[k]) == "number" and tostring(want[k]) or ""
  end
  form.notes = type(b.notes) == "string" and b.notes or ""
  local ref = type(b.place) == "table" and b.place.ref
  for i, p in ipairs(places or {}) do if p.ref == ref then form.place = i end end
  return form
end

-- The form's day moved by n days; never before today.
function O.shiftDay(form, env, n)
  local s = form.stamp + n * DAY
  if s < env.now - 12 * 3600 then return end
  form.stamp = s
end

function O.dayLabel(date, stamp)
  local ok, s = pcall(date, "%a %d %b", stamp)
  return ok and type(s) == "string" and (s:gsub("^(%a+) 0", "%1 ")) or ""
end

-- "Two hours", "An hour and a half" is not in the table, so: "Two hours", "90 minutes", "One hour".
function O.lengthLabel(minutes)
  if minutes % 60 ~= 0 then return minutes .. " minutes" end
  local h = minutes / 60
  local w = UI.number(h)
  return w .. (h == 1 and " hour" or " hours")
end

-- Step How long along O.LENGTHS (dir 1 or -1), staying inside the list.
function O.stepLength(form, dir)
  local at = 1
  for i, m in ipairs(O.LENGTHS) do if m <= form.minutes then at = i end end
  form.minutes = O.LENGTHS[math.min(math.max(at + dir, 1), #O.LENGTHS)]
end

-- When the form starts, seconds since the epoch on the player's clock: the day's midnight plus the time typed. nil if
-- the time can't be read or the clock can't be read as a date.
function O.starts(form, date)
  local h, m = O.parseTime(form.time)
  if not h then return nil end
  local ok, t = pcall(date, "*t", form.stamp)
  if not ok or type(t) ~= "table" then return nil end
  return form.stamp - (t.hour * 3600 + t.min * 60 + t.sec) + h * 3600 + m * 60
end

local function wantNumbers(form)
  local out, sum, any = {}, 0, false
  for i, k in ipairs({ "tank", "healer", "dps" }) do
    local s = (form.want[i] or ""):match("^%s*(.-)%s*$")
    if s ~= "" then
      local n = tonumber(s)
      if not n or n % 1 ~= 0 or n < 0 or n > 40 then return nil end
      out[k], sum, any = n, sum + n, true
    end
  end
  return out, sum, any
end

-- nil when the form can be sent, else the line that says why not (the first problem).
function O.check(form, env)
  if (form.title or ""):match("^%s*$") then return O.TEXT.noTitle end
  local at = O.starts(form, env.date)
  if not at then return O.TEXT.badTime end
  if at < env.now and not (form.editing and at == form.origStarts) then return O.TEXT.past end -- an event under way can still be edited
  local w, sum = wantNumbers(form)
  if not w or (form.size and sum > form.size) then return O.TEXT.tooMany end
  return nil
end

-- The fields Edit.createEvent takes; nil when the form isn't good (O.check).
function O.fields(form, env, places)
  if O.check(form, env) then return nil end
  local null = ns.Json.null
  local f = { title = form.title:match("^%s*(.-)%s*$"), activity = form.activity, starts = O.starts(form, env.date),
    minutes = form.minutes }
  local edit = form.editing ~= nil -- an edit says what is cleared too: null where a new event leaves the field out
  if form.size then f.size = form.size elseif edit then f.size = null end
  local w, _, any = wantNumbers(form)
  if any then f.want = ns.Json.object({ tank = w.tank or null, healer = w.healer or null, dps = w.dps or null })
  elseif edit then f.want = null end
  local notes = (form.notes or ""):match("^%s*(.-)%s*$")
  if notes ~= "" then f.notes = notes elseif edit then f.notes = null end
  local p = places and places[form.place]
  if p then f.place = ns.Json.object({ ref = p.ref }) elseif edit then f.place = null end
  return f
end

-- The plain line for a refusal; nil for "sent" and "kept".
function O.refusal(status)
  if status == "sent" or status == "kept" then return nil end
  if status == "refused: not_officer" or status == "refused: forbidden" then return O.TEXT.notOfficer end
  if status == "refused: not_on_roster" then return O.TEXT.notOnRoster end
  return E.TEXT.refused
end

-- The plain line for the result of a call made through ns.try (ok, status); nil when the edit was taken.
function O.outcome(ok, status)
  if not ok then return E.TEXT.refused end
  return O.refusal(status)
end

---------------------------------------------------------------------------------------------- Write a bulletin

O.BTEXT = {
  heading = "Write a bulletin", post = "Post bulletin", cancel = "Cancel",
  takeDown = "Take it down on", takeDownLink = "Take it down", countOf = " of 600 characters", -- the Officers table's
  after = "Guildmates with the addon see it straight away. The website and Discord get it at the next logout by anyone with the desktop app.",
  noTitle = "Give the bulletin a title.", noText = "Write something under the title.",
  text = "Text", tooLong = "Keep it to 600 characters.", badDate = "That date has passed.", -- for Joe to read, with the two above
  edit = "Edit", unpin = "Unpin", about = "About an event", -- the Officers table's
  pin = "Pin it to the top", pinLink = "Pin", -- the Officers table's; "Pin": for Joe to read, the link that undoes Unpin
  takeDownQ = "Take this bulletin down?", keep = "Keep it", -- the question that replaces the Take it down link
}

-- A blank bulletin form; the date steps from a week ahead.
function O.newBulletin(env)
  return { title = "", text = "", pinned = false, down = false, stamp = env.now + 7 * DAY }
end

-- A form holding what bulletin `r` says now (Edit). Saving it edits that bulletin.
function O.bulletinFromRecord(env, r)
  local b = bodyOf(r)
  local f = O.newBulletin(env)
  f.editing = r.id
  f.title = type(b.title) == "string" and b.title or ""
  f.text = type(b.text) == "string" and b.text or ""
  f.pinned = b.pinned == true
  if type(b.expires) == "number" then
    f.down, f.stamp, f.origStamp, f.origExpires = true, b.expires, b.expires, b.expires
  end
  if type(b.event) == "string" then f.event = b.event end
  return f
end

function O.countLine(text) return #(text or "") .. O.BTEXT.countOf end

-- The guild's upcoming events a bulletin can be about, soonest first (at most 20); `keep` is the one it is about now,
-- listed even if it has gone. { id, title, starts, label }.
function O.eventChoices(g, now, date, keep)
  local out = {}
  for _, ev in ipairs(E.held(g)) do
    local b = bodyOf(ev)
    local group = b.group ~= nil and b.group ~= ns.Json.null
    if type(b.title) == "string" and type(b.starts) == "number" and not group
      and ((b.starts >= now and b.cancelled ~= true) or ev.id == keep) then
      local title = E.bound(b.title, 30) or ""
      out[#out + 1] = { id = ev.id, title = title, starts = b.starts, label = title .. ", " .. O.dayLabel(date, b.starts) }
    end
  end
  table.sort(out, function(a, c) if a.starts ~= c.starts then return a.starts < c.starts end return a.id < c.id end)
  while #out > 20 do table.remove(out) end
  return out
end

-- About an event on or off: on picks the soonest; nothing happens when there is none to pick.
function O.toggleAbout(form, choices)
  if form.event then form.event = nil elseif choices[1] then form.event = choices[1].id end
end

-- Step the chosen event along `choices` (dir 1 or -1), staying inside the list.
function O.stepEvent(form, choices, dir)
  local at = 1
  for i, c in ipairs(choices) do if c.id == form.event then at = i end end
  local pick = choices[math.min(math.max(at + dir, 1), #choices)]
  if pick then form.event = pick.id end
end

-- The page foot as it will read: "Pinned · you, Tue 10 Nov · up until Sun 22 Nov".
function O.bulletinFoot(form, env)
  local parts = {}
  if form.pinned then parts[#parts + 1] = "Pinned" end
  parts[#parts + 1] = "you, " .. O.dayLabel(env.date, env.now)
  if form.down then parts[#parts + 1] = "up until " .. O.dayLabel(env.date, form.stamp) end
  return table.concat(parts, " · ")
end

-- When "Take it down on" falls: the last minute of the chosen day on the player's clock; nil if it can't be read.
-- An edit that leaves the day alone keeps the time the bulletin already had.
function O.bulletinExpires(form, env)
  if form.origExpires and form.stamp == form.origStamp then return form.origExpires end
  local ok, t = pcall(env.date, "*t", form.stamp)
  if not ok or type(t) ~= "table" then return nil end
  return form.stamp - (t.hour * 3600 + t.min * 60 + t.sec) + DAY - 1
end

-- nil when the bulletin can be sent, else the line that says why not (the first problem).
function O.bulletinCheck(form, env)
  if (form.title or ""):match("^%s*$") then return O.BTEXT.noTitle end
  if (form.text or ""):match("^%s*$") then return O.BTEXT.noText end
  if #form.text > 600 then return O.BTEXT.tooLong end
  if form.down then
    local at = O.bulletinExpires(form, env)
    if not at or at <= env.now then return O.BTEXT.badDate end
  end
  return nil
end

-- The fields Edit.createBulletin takes (pipes dropped: the game reads them as codes); nil when the form isn't good.
function O.bulletinFields(form, env)
  if O.bulletinCheck(form, env) then return nil end
  local f = { title = form.title:gsub("|", ""):match("^%s*(.-)%s*$"), text = form.text:gsub("|", ""):match("^%s*(.-)%s*$"),
    pinned = form.pinned == true }
  local edit, null = form.editing ~= nil, ns.Json.null -- an edit says what is cleared too
  if form.down then f.expires = O.bulletinExpires(form, env) elseif edit then f.expires = null end
  if form.event then f.event = form.event elseif edit then f.event = null end
  return f
end

return O
