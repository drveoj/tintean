-- Settings, the first-run steps and the slash commands, as data. Pure: no widgets. Words are the README's strings table
-- (docs/mockups/addon, First run, Settings, /tintean); the few it lacks are marked "for Joe to read".
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local S = {}
UI.Settings = S

S.TEXT = {
  notices = "Notices", sharing = "Sharing", data = "This guild's data",
  waits = "Toasts wait until you're out of combat.",
  shareNote = "Your own sign-ups go to guildmates either way, so they reach the website.",
  chatFact = "Tinteán posts in guild chat only when you press Post in guild chat. The desktop app reads what you do here when you log out, and sends it to tintean.net.",
  refills = "Guildmates and the desktop app fill it again after a clear.",
  paste = "Copy and paste", tour = "Show the tour again", clear = "Clear this guild's data",
  step = "%d of 3", next = "Next", back = "Back", skip = "Skip", done = "Done", openSettings = "Open settings",
  yourGuild = "your guild's", -- for Joe to read: the step 1 sentence when the game gives no guild name
  helpHead = "Commands:",
  unknown = "Tinteán doesn't know \"/tintean %s\". Type /tintean help for the list.",
}

-- The toggles, in order. `share` is under Sharing; `minimap` is the opposite of the saved `hide`.
S.TOGGLES = {
  { "chatLine", "A line in chat when an event or bulletin arrives" },
  { "toast", "A toast for new events and bulletins" },
  { "loginReminder", "At login, say which events I haven't answered" },
  { "remind15", "Remind me 15 minutes before an event I'm in" },
  { "sound", "Play a sound with reminders" },
  { "minimap", "Show the minimap button" },
}
S.SHARE = { "share", "Pass Tinteán's records on to guildmates' addons" }
-- Words for the copy gate (decisions.md, 2026-11-15, M23.2, section 4).
S.MOMENTS = { "moments", "Note moments for tales" }
S.TEXT.momentsHelp = "Writes down what your character does while you're grouped with a guildmate. " ..
  "The website keeps the details for 60 days after the night, and a tale can be drafted again until then. " ..
  "Turning this off stops it and deletes what hasn't been sent yet."

local function saved()
  local st = ns.state
  local s = st and st.db and st.db.settings
  return type(s) == "table" and s or nil
end

-- Whether a toggle is on, as the rest of the addon reads it (a missing value is its default: on, but sound).
function S.get(key)
  local s = saved()
  if key == "minimap" then return not UI.minimapHidden() end
  if key == "share" then return not (s and s.share == false) end
  if key == "moments" then return not (s and s.moments == false) end
  return UI.Arrivals.on(key)
end

-- Sets a toggle in the account's settings; false when there is nowhere to save it.
function S.set(key, on)
  local s = saved()
  if not s then return false end
  if key == "minimap" then
    if type(s.minimap) ~= "table" then s.minimap = { angle = 225 } end
    s.minimap.hide = not on
  else
    s[key] = on == true
  end
  if key == "moments" then
    local P = ns.Moments and ns.Moments.Party
    if P then ns.try(P.switched, on == true) end
  end
  return true
end

function S.flip(key) return S.set(key, not S.get(key)) end

-- Clear this guild's data: the store's own clear, then a touch so the screens draw again. Pending edits stay.
function S.clear(guild)
  if type(guild) ~= "table" then return false end
  ns.Store.clear(guild)
  ns.Sync.touch()
  return true
end

function S.statusLine() return "Tinteán " .. ns.version .. ". /tintean check for a bug report." end

---------------------------------------------------------------------------------------------- first run

-- The three steps: heading, sentences, the picture on scenes.tga, the buttons (by key, left to right).
function S.step(n, guildName)
  local own = type(guildName) == "string" and guildName ~= "" and guildName .. "'s" or S.TEXT.yourGuild
  local steps = {
    { title = "Events and bulletins", scene = "campfire", buttons = { "next", "skip" },
      body = { "Click the flame on the minimap, or type /tintean, to see " .. own ..
        " events and bulletins and sign up for an event." } },
    { title = "The desktop app", scene = "map", buttons = { "back", "next", "skip" },
      body = { "With the desktop app running on this computer, new events and bulletins arrive when you log in. " ..
        "Without it, they come from guildmates' addons while you're both online.",
        "What you change here reaches the website when you, or a guildmate with the desktop app, log out." } },
    { title = "Sharing", scene = "tavern", buttons = { "back", "done", "openSettings" },
      body = { "Your sign-ups go to guildmates' addons. Tinteán posts in guild chat only when you press Post in guild chat." } },
  }
  local s = steps[n]
  if not s then return nil end
  s.n, s.count = n, string.format(S.TEXT.step, n)
  return s
end

-- The tour is due once: when it was never shown on this account.
function S.tourDue()
  local st = ns.state
  local t = st and st.db and st.db.tour
  return type(t) ~= "table" or (t.shown or 0) == 0
end

function S.markTour(now)
  local st = ns.state
  if not (st and st.db) then return false end
  st.db.tour = { shown = 1, at = type(now) == "number" and now or 0 }
  return true
end

---------------------------------------------------------------------------------------------- slash

S.TABS = { events = true, bulletins = true, roster = true }
S.HELP = {
  "/tintean: open the window", -- for Joe to read: the help lines, as the README's list with the command in front
  "/tintean events, bulletins, roster, settings: open that tab",
  "/tintean paste: copy and paste with the website",
  "/tintean minimap: show or hide the minimap button",
  "/tintean tour: the first-run tour again",
  "/tintean check: what to send with a bug report",
}

-- What a /tintean line asks for: { "open" }, { "tab", name }, { "settings" }, { "paste" }, { "minimap" }, { "tour" },
-- { "help" } or { "unknown", word }. ("check" and "debug" are the loader's own.)
function S.route(msg)
  local word = type(msg) == "string" and msg:match("^%s*(%S+)") or nil
  if not word then return { "open" } end
  word = word:lower()
  if S.TABS[word] then return { "tab", word } end
  if word == "settings" or word == "paste" or word == "minimap" or word == "tour" or word == "help" then return { word } end
  return { "unknown", word }
end

function S.unknown(word) return string.format(S.TEXT.unknown, word) end

return S
