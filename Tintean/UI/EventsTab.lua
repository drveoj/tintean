-- The Events tab and an event's page, drawn from UI.Events (the model). Our own widgets only: textures, font strings,
-- plain buttons, one edit box and a scroll frame; no Blizzard frame art, no protected frame, every call through ns.try.
-- Everything is drawn again from what the addon holds after each action (a sign-up shows at once, pending or not),
-- on a small pool of widgets so nothing piles up. Sheets: docs/mockups/addon/Events.html and Event.html.
local _, ns = ...
ns = ns or {}

local UI = ns.UI
local Frame, E = UI.Frame, UI.Events
local C = UI.COLORS
local try, call, color = function(...) return ns.try(...) end, Frame.call, Frame.color

local T = {}
UI.EventsTab = T

local X, W, ROW = 16, 606, 46 -- the left margin, the content's width, a list row's height
local NARROW = 480            -- the frame is 640 wide and not resizable today; a narrower one drops the month, as the sheet says

-- M20.17 puts the officers' *Plan an event* here: hooks.afterEmpty(cv, y, env) and hooks.afterList(cv, y, env) draw and return the new y.
T.hooks = {}
-- What the page remembers while the window is open: the open event, the month shown, the role chosen, what was dismissed.
-- `day` is the day of the shown month whose events are the only ones listed (nil: the whole list).
local S = { shift = 0, earlier = false, role = {}, closed = {}, away = {}, said = {}, shut = {} }
T.state = S

local function dim(c, f) return { c[1], c[2], c[3], (c[4] or 1) * f } end
local function guess(s, size) return #(s or "") * size * 0.5 end

---------------------------------------------------------------------------------------------- the canvas

local cv = { pools = {} }

local function take(kind, make)
  local p = cv.pools[kind]
  if not p then p = { n = 0, items = {}, made = 0 }; cv.pools[kind] = p end
  p.n = p.n + 1
  if p.n > p.made then p.items[p.n], p.made = make(), p.n end
  return p.items[p.n]
end

local function rect(x, y, w, h, c, sub)
  local t = take("fill", function() return Frame.fill(cv.child, C.line, "BACKGROUND") end)
  if not t then return end
  call(t, "ClearAllPoints")
  call(t, "SetPoint", "TOPLEFT", cv.child, "TOPLEFT", x, -y)
  call(t, "SetSize", w, h)
  call(t, "SetColorTexture", color(c))
  call(t, "SetDrawLayer", "BACKGROUND", sub or 0)
  call(t, "Show")
end

-- The panel recipe: one surface, one line.
local function panel(x, y, w, h, face)
  rect(x, y, w, h, C.lineStrong, 0)
  rect(x + 1, y + 1, w - 2, h - 2, face or C.surface, 1)
end

---------------------------------------------------------------------------------------------- pictures
-- The game's own art, named by path (nothing of Blizzard's is shipped). Each is drawn only when the client gave a path
-- for it; a picture that can't be placed is left out and the text stays where it was.

-- A texture of the game's at (x, y), above the panels. coords = { l, r, t, b } or none (the whole picture). True once drawn.
-- tint = { r, g, b } colours it (the white shapes of ui.tga); o = { kind, make, sub }: a pool of its own, what to do to a new
-- texture, and its layer. Returns true and the texture once drawn.
local function pic(x, y, w, h, file, coords, ink, tint, o)
  if file == nil then return false end
  o = o or {}
  local t = take(o.kind or "pic", function()
    local made = Frame.fill(cv.child, C.line, "ARTWORK")
    if made and o.make then o.make(made) end
    return made
  end)
  if not t then return false end
  call(t, "ClearAllPoints")
  call(t, "SetPoint", "TOPLEFT", cv.child, "TOPLEFT", x, -y)
  call(t, "SetSize", w, h)
  call(t, "SetColorTexture", 0, 0, 0, 0) -- clears what the pool's last use left
  call(t, "SetTexture", file)
  if coords then call(t, "SetTexCoord", coords[1], coords[2], coords[3], coords[4]) else call(t, "SetTexCoord", 0, 1, 0, 1) end
  local tr = tint or { 1, 1, 1 }
  call(t, "SetVertexColor", tr[1], tr[2], tr[3], ink or 1)
  call(t, "SetDrawLayer", "ARTWORK", o.sub or 1)
  call(t, "Show")
  return true, t
end

-- A sprite of ui.tga (a role icon), tinted.
local function sprite(name, x, y, size, tint)
  local l, r, t, b = UI.Art.sprite(name)
  if l then pic(x, y, size, size, UI.Art.path(UI.Art.UI), { l, r, t, b }, 1, tint, { kind = "spr", sub = 3 }) end
end

-- A framed place painting; Art.place gives the campfire when there is no place (or none we have a painting of). The flame
-- mark is only for a sheet that fails to load.
local function placePic(slug, x, y, size)
  rect(x - 1, y - 1, size + 2, size + 2, C.lineStrong, 2)
  local l, r, t, b = UI.Art.place(slug)
  if pic(x, y, size, size, UI.Art.path(UI.Art.PLACES), { l, r, t, b }, 1, nil, { kind = "place" }) then return end
  rect(x, y, size, size, C.ground, 3)
  pic(x + size * .2, y + size * .2, size * .6, size * .6, "Interface\\AddOns\\Tintean\\mark", nil, 1, nil, { kind = "flame" })
end

-- Each round icon's texture gets a mask of the disc on ui.tga; a client without masks leaves `masked` false and the
-- icon is drawn square with a class-colour edge instead (decided per texture, at run time, never an error).
local function giveMask(t)
  local ok, m = try(cv.child.CreateMaskTexture, cv.child)
  if not ok or type(m) ~= "table" then return end
  local l, r, tp, b = UI.Art.sprite("disc")
  call(m, "SetTexture", UI.Art.path(UI.Art.UI))
  call(m, "SetTexCoord", l, r, tp, b)
  call(m, "SetAllPoints", t)
  t.masked = call(t, "AddMaskTexture", m) and true or false
end

-- The class icon beside a name, round in a ring of the class colour. True when drawn.
local function classIcon(class, x, y, size, ink)
  local ok, tc = try(function() return _G.CLASS_ICON_TCOORDS end)
  local icon = ok and E.classIcon(class, tc) or nil
  if not icon then return false end
  local col = E.classColor(class) or C.muted
  local drawn, t = pic(x, y, size, size, icon.file, icon.coords, ink, nil, { kind = "mpic", make = giveMask })
  if not drawn then return false end
  if t.masked then
    local l, r, tp, b = UI.Art.sprite("ring")
    pic(x, y, size, size, UI.Art.path(UI.Art.UI), { l, r, tp, b }, ink, col, { kind = "ring", sub = 2 })
  else
    rect(x - 2, y - 2, size + 4, size + 4, dim(col, ink or 1), 2)
  end
  return true
end

-- A framed 128 x 64 scene of scenes.tga ("campfire", "map", "book", "tavern"); the frame alone when the sheet is missing.
local function scene(name, x, y)
  rect(x - 1, y - 1, 130, 66, C.lineStrong, 2)
  local l, r, t, b = UI.Art.scene(name)
  if not (l and pic(x, y, 128, 64, UI.Art.path(UI.Art.SCENES), { l, r, t, b }, 1, nil, { kind = "scene" })) then
    rect(x, y, 128, 64, C.ground, 3)
  end
end

-- A small chevron (two thin lines, as the close X is drawn: our fonts have no arrow glyphs) whose point is at (ax, cy).
-- dir -1 points left, 1 points right. Eight pixels tall, in `c`.
local function chevron(ax, cy, dir, c)
  for _, sign in ipairs({ 1, -1 }) do
    local t = take("chev", function() return Frame.fill(cv.child, C.line, "ARTWORK") end)
    if t then
      call(t, "ClearAllPoints")
      call(t, "SetSize", 6, 2)
      call(t, "SetPoint", "CENTER", cv.child, "TOPLEFT", ax - dir * 2.1, -(cy - sign * 2.1))
      call(t, "SetRotation", math.rad(45) * sign * -dir)
      call(t, "SetColorTexture", color(c))
      call(t, "SetDrawLayer", "ARTWORK", 2)
      call(t, "Show")
    end
  end
end

-- Text at (x, y): returns its height and width. o: size, color, font ("display"), width (wraps), right, center.
local function text(s, x, y, o)
  o = o or {}
  local size = o.size or 14
  local fs = take("t" .. size .. (o.font or ""), function() return Frame.text(cv.child, size, C.body, o.font) end)
  call(fs, "ClearAllPoints")
  call(fs, "SetPoint", o.right and "TOPRIGHT" or "TOPLEFT", cv.child, "TOPLEFT", x, -y)
  call(fs, "SetWidth", o.width or 0)
  call(fs, "SetWordWrap", o.width ~= nil)
  call(fs, "SetJustifyH", o.center and "CENTER" or (o.right and "RIGHT" or "LEFT"))
  call(fs, "SetTextColor", color(o.color or C.body))
  call(fs, "SetText", s)
  call(fs, "Show")
  local _, h = call(fs, "GetStringHeight")
  local _, w = call(fs, "GetStringWidth")
  return type(h) == "number" and h or size * 1.3 * math.max(1, math.ceil(guess(s, size) / (o.width or 1e9))),
    type(w) == "number" and w or guess(s, size)
end

-- A plain button. o: bg (a fill; none = a link or a hit area), edge, ink, size. Returns nothing; `fn` runs on click.
local function button(x, y, w, h, label, fn, o)
  o = o or {}
  local b = take("btn" .. (o.size or 13), function() -- a button's label is made at one size, so they are pooled by size
    local self
    self = Frame.button(cv.child, 10, 10, function() if self and self.fn then self.fn() end end)
    if self then
      self.edge, self.face = Frame.fill(self, C.line, "BACKGROUND"), Frame.fill(self, C.line, "BACKGROUND")
      call(self.edge, "SetAllPoints")
      call(self.face, "SetPoint", "TOPLEFT", 1, -1)
      call(self.face, "SetPoint", "BOTTOMRIGHT", -1, 1)
      call(self.face, "SetDrawLayer", "BACKGROUND", 1)
      self.under = Frame.fill(self, C.gold, "OVERLAY") -- the chosen pill's gold underline
      call(self.under, "SetPoint", "BOTTOMLEFT", 1, 1)
      call(self.under, "SetPoint", "BOTTOMRIGHT", -1, 1)
      call(self.under, "SetHeight", 2)
      self.ico = Frame.fill(self, C.line, "OVERLAY") -- a role icon at the left (o.icon = { sprite, tint })
      call(self.ico, "SetSize", 12, 12)
      call(self.ico, "SetPoint", "LEFT", 7, 0)
      Frame.feel(self)
      self.label = Frame.text(self, o.size or 13, C.body)
      call(self.label, "SetPoint", "CENTER")
      call(self.label, "SetJustifyH", "CENTER")
    end
    return self
  end)
  if type(b) ~= "table" then return end
  b.fn = fn
  call(b, "ClearAllPoints")
  call(b, "SetPoint", "TOPLEFT", cv.child, "TOPLEFT", x, -y)
  call(b, "SetSize", w, h)
  call(b.edge, o.bg and "Show" or "Hide")
  call(b.face, o.bg and "Show" or "Hide")
  local l, r, t, bt = nil, nil, nil, nil
  if o.icon then l, r, t, bt = UI.Art.sprite(o.icon[1]) end
  if l then
    call(b.ico, "SetTexture", UI.Art.path(UI.Art.UI))
    call(b.ico, "SetTexCoord", l, r, t, bt)
    call(b.ico, "SetVertexColor", o.icon[2][1], o.icon[2][2], o.icon[2][3], 1)
    call(b.ico, "Show")
  else
    call(b.ico, "Hide")
  end
  b.hot, b.down = false, false -- a pooled button may have been left lit
  b.look = o.bg and { bg = o.bg, edge = o.edge or o.bg, chosen = o.chosen } or nil
  -- o.align "left" or "right": the label sits against that edge (14 px in) instead of centred, for a link with a chevron beside it
  local at = o.align == "left" and "LEFT" or (o.align == "right" and "RIGHT" or "CENTER")
  b.anchor = { at, at == "LEFT" and 14 or (at == "RIGHT" and -14 or 0), o.dy or 0 } -- o.dy: the label sits this far up
  call(b.label, "SetJustifyH", at)
  call(b.label, "SetTextColor", color(o.ink or C.moss))
  call(b.label, "SetText", label or "")
  Frame.paint(b)
  call(b, "Show")
end

local function begin()
  for _, p in pairs(cv.pools) do p.n = 0 end
  cv.noteUsed = false -- only the sign-up section turns this on
end

-- A box with the keyboard keeps it only while it is on screen; leaving it, hiding the tab or the window lets go.
local function blur() call(cv.note, "ClearFocus") end

local function finish(y)
  for _, p in pairs(cv.pools) do
    for i = p.n + 1, p.made do call(p.items[i], "Hide") end
  end
  if not cv.noteUsed then -- a page that is not the sign-up section, a group's own event, a fall back to the list
    blur()
    call(cv.note, "Hide")
  end
  call(cv.child, "SetHeight", y + 16)
end

-- A heading with its gold rule and, at the right, the meta.
local function heading(title, meta, y)
  text(title, X, y, { size = 20, color = C.title, font = "display" })
  rect(X, y + 30, 28, 2, C.gold, 2)
  if meta then text(meta, X + W, y + 8, { size = 12, color = C.muted, right = true }) end
  return y + 42
end

-- The strip of figures: one panel, cells split by the line, a figure in Cormorant over its words. Two by two in a narrow window.
local function strip(cells, y)
  local n = #cells
  if n == 0 then return y end
  local per = Frame.W >= NARROW and n or math.min(n, 2)
  local lines, ch = math.ceil(n / per), 52
  local cw = W / per
  panel(X, y, W, lines * ch)
  for i, c in ipairs(cells) do
    local col, ln = (i - 1) % per, math.floor((i - 1) / per)
    local cx, cy = X + col * cw, y + ln * ch
    if col > 0 then rect(cx, cy + 1, 1, ch - 2, C.line, 2) end
    if col == 0 and ln > 0 then rect(X + 1, cy, W - 2, 1, C.line, 2) end
    text(c.n, cx + 12, cy + 6, { size = 22, font = "display", color = c.gold and C.gold or C.title })
    local lx = cx + 12
    if c.dot then rect(lx, cy + 35, 6, 6, C.count, 4); lx = lx + 10 end
    if c.icon then sprite(c.icon, lx, cy + 32, 12, C.muted); lx = lx + 16 end
    text(c.l, lx, cy + 31, { size = 12, color = C.muted })
  end
  return y + lines * ch + 12
end

---------------------------------------------------------------------------------------------- the note

local function noteBox()
  if cv.note then return cv.note end
  local ok, eb = try(CreateFrame, "EditBox", nil, cv.child)
  if not ok or type(eb) ~= "table" then return nil end
  local _, locale = try(GetLocale)
  local path = UI.ownFont("body", locale)
  if not (path and select(2, call(eb, "SetFont", path, 13, ""))) then call(eb, "SetFont", STANDARD_TEXT_FONT, 13, "") end
  call(eb, "SetAutoFocus", false)
  call(eb, "SetMaxLetters", 200)
  call(eb, "SetTextInsets", 8, 8, 0, 0)
  call(eb, "SetTextColor", color(C.ink))
  call(Frame.fill(eb, C.lineStrong, "BACKGROUND"), "SetAllPoints")
  local inner = Frame.fill(eb, C.ground, "BACKGROUND")
  call(inner, "SetPoint", "TOPLEFT", 1, -1)
  call(inner, "SetPoint", "BOTTOMRIGHT", -1, 1)
  call(inner, "SetDrawLayer", "BACKGROUND", 1)
  eb.hint = Frame.text(eb, 13, C.muted)
  call(eb.hint, "SetPoint", "LEFT", 8, 0)
  local function done(self) call(self, "ClearFocus") end
  call(eb, "SetScript", "OnEscapePressed", done)
  call(eb, "SetScript", "OnEnterPressed", done)
  call(eb, "SetScript", "OnTextChanged", function(self)
    local _, s = call(self, "GetText")
    call(eb.hint, (type(s) == "string" and s ~= "") and "Hide" or "Show")
  end)
  cv.note = eb
  return eb
end

local function noteText()
  local _, s = call(cv.note, "GetText")
  if type(s) ~= "string" then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---------------------------------------------------------------------------------------------- actions

local render

local function now()
  local ok, t = try(time)
  return ok and type(t) == "number" and t or 0
end

local function leave()
  blur()
  S.page, S.away, S.said, S.shut = nil, {}, {}, {}
  UI.statusNote = nil
  call(cv.scroll, "SetVerticalScroll", 0)
  render()
end

local function openEvent(id)
  blur()
  S.page = id
  call(cv.scroll, "SetVerticalScroll", 0)
  render()
end
T.open = function(id) blur(); S.page = id; if Frame.show("events") then render() end end

-- After an edit: the page shows what is held now (a pending sign-up is held), and the status line says where it has got to.
local function after(id, ok, res, group)
  if ok and (res == "sent" or res == "kept") then
    S.said[id] = nil
    if res == "sent" then UI.statusNote = { text = E.TEXT.sent, untilAt = now() + 30 }
    elseif group then UI.statusNote = { text = E.TEXT.sentGroup, untilAt = now() + 30 } end
  else
    S.said[id] = res == "refused: note" and E.TEXT.noteLong or E.TEXT.refused
  end
  Frame.refresh(true)
  render()
end

local function signUp(p, status)
  local note = noteText()
  local extra = { role = p.me.role, note = note ~= "" and note or ns.Json.null }
  local ok, res = try(ns.Words.signUp, p.id, status, extra)
  after(p.id, ok, res, p.groupEvent)
end

local function signUpAnyway(p, word)
  local ok, res
  if word.ahead then -- the warnings are the ones the server would raise: a plain sign-up carries their refs
    local note = noteText()
    ok, res = try(ns.Words.signUp, p.id, "yes", { role = p.me.role, note = note ~= "" and note or ns.Json.null })
  else
    ok, res = try(ns.Words.signUpAnyway, p.id)
  end
  after(p.id, ok, res, p.groupEvent)
end

-- *Post in guild chat*: one line, as the player, from this click only. During the chat lockdown (or if the game
-- refuses it) nothing is sent and the page says so; the button is never greyed.
local function postInChat(p)
  local line = UI.Arrivals.post(p, date)
  if not line then return end
  local ok, locked = try(function() return C_ChatInfo.InChatMessagingLockdown() end)
  local sent = false
  if not (ok and locked == true) then
    local send = type(C_ChatInfo) == "table" and C_ChatInfo.SendChatMessage or SendChatMessage
    sent = select(1, try(send, line, "GUILD"))
  end
  S.shut[p.id] = (not sent) or nil
  render()
end

-- Dismiss writes the clock into the export; with no clock it is left alone (M20.13b).
local function dismissWord(p)
  if now() > 0 then try(ns.Words.dismiss, p.id) end
  render()
end

---------------------------------------------------------------------------------------------- the list

local STATUS_INK = { ["in"] = "moss", maybe = "gold" }

local function drawMonth(env, y, evs, by)
  local m = E.month(env, S.shift, evs, by)
  if not m then return y end
  local cw, ch = (W - 24 - 24) / 7, 26
  local rows = #m.cells / 7
  local canPlan = T.hooks.canPlan and T.hooks.planDay and T.hooks.canPlan(env) or false
  local h = 34 + 16 + rows * (ch + 3) + 8
  panel(X, y, W, h)
  -- the sheet's "← October" and "December →": the arrows are drawn
  button(X + 8, y + 6, 110, 24, m.prev, function() S.shift, S.day = math.max(S.shift - 1, -12), nil; render() end, { size = 13, align = "left" })
  chevron(X + 12, y + 18, -1, C.moss)
  text(m.title, X + W / 2, y + 8, { size = 17, color = C.title, font = "display", center = true, width = 200 })
  button(X + W - 118, y + 6, 110, 24, m.next, function() S.shift, S.day = math.min(S.shift + 1, 12), nil; render() end, { size = 13, align = "right" })
  chevron(X + W - 12, y + 18, 1, C.moss)
  for i, d in ipairs(E.DOW) do
    text(d, X + 12 + (i - 1) * (cw + 4), y + 36, { size = 10, color = C.muted, center = true, width = cw })
  end
  for i, cell in ipairs(m.cells) do
    local col, row = (i - 1) % 7, math.floor((i - 1) / 7)
    local cx, cy = X + 12 + col * (cw + 4), y + 52 + row * (ch + 3)
    local chosen = not cell.out and S.day == cell.day
    if chosen then
      rect(cx, cy, cw, ch, C.moss, 0)
      rect(cx + 1, cy + 1, cw - 2, ch - 2, cell.today and C.ground or C.surface, 1)
    elseif not cell.out then
      if cell.today then panel(cx, cy, cw, ch, C.ground) else rect(cx, cy, cw, ch, C.line, 1) end
    end
    local ink = cell.out and dim(C.muted, .5) or (cell.today and C.gold) or (cell.past and C.muted) or C.body
    local ids = cell.ids or {}
    if #ids > 0 then -- a day with events is a button, its number the label; a day with none is only drawn
      local d = cell.day
      button(cx, cy, cw, ch, tostring(d), function()
        if #ids == 1 then openEvent(ids[1]) else S.day = d; render() end
      end, { size = 13, ink = ink, dy = 4 })
    elseif cell.stamp and cell.stamp > env.now - 12 * 3600 and canPlan then -- an officer's click on an empty day plans an event for it
      button(cx, cy, cw, ch, tostring(cell.day), function() T.hooks.planDay(cell.stamp) end, { size = 13, ink = ink, dy = 4 })
    else
      text(tostring(cell.day), cx, cy + 3, { size = 13, color = ink, center = true, width = cw })
    end
    local n = #(cell.dots or {})
    for k, dot in ipairs(cell.dots or {}) do
      local dx, dy = cx + cw / 2 - (n * 7 - 2) / 2 + (k - 1) * 7, cy + ch - 8
      if dot == "ring" then rect(dx, dy, 5, 5, C.muted, 2); rect(dx + 1, dy + 1, 3, 3, C.ground, 3)
      else rect(dx, dy, 5, 5, dot == "flame" and C.flame or C.moss, 2) end
    end
    if cell.red then rect(cx + cw - 9, cy + 3, 6, 6, C.count, 4) end
  end
  return y + h + 16, m
end

-- The chosen day's cell of the month drawn, if it still has events; otherwise the choice is dropped.
local function chosenCell(m)
  for _, cell in ipairs(m and m.cells or {}) do
    if not cell.out and cell.day == S.day and #(cell.ids or {}) > 0 then return cell end
  end
  S.day = nil
end

local function drawRows(rows, y)
  panel(X, y, W, #rows * ROW + 2)
  for i, r in ipairs(rows) do
    local ry = y + 1 + (i - 1) * ROW
    if i > 1 then rect(X + 1, ry, W - 2, 1, C.line, 2) end
    local faded = r.cancelled or r.over
    if r.more then -- "N more": a line, not an event
      text(r.title, X + 14, ry + 15, { size = 13, color = C.muted })
    else
      placePic(r.art, X + 14, ry + 5, E.SIZE.row)
      local tx = X + 14 + E.SIZE.row + 12
      text(r.title, tx, ry + 7, { size = 14, color = faded and C.muted or C.title })
      if r.sub then text(r.sub, tx, ry + 26, { size = 12, color = C.muted }) end
      text(r.day, X + W - 14, ry + 5, { size = 16, color = faded and C.muted or C.title, font = "display", right = true })
      text(r.time, X + W - 14, ry + 25, { size = 12, color = C.muted, right = true })
      if r.status then
        local c = C[STATUS_INK[r.status] or "muted"]
        local _, w = text(r.status, X + W - 90, ry + 15, { size = 12, color = c, right = true })
        if r.red then rect(X + W - 90 - w - 12, ry + 19, 6, 6, C.count, 4) end
      end
      button(X + 1, ry, W - 2, ROW, "", function() openEvent(r.id) end, {})
    end
  end
  return y + #rows * ROW + 2
end

local function hasCalendar()
  local ok, f = try(function() return _G.ToggleCalendar end)
  return ok and type(f) == "function" and type(C_Calendar) == "table"
end

-- A dismissable notice at the top of the list: the title, a line, × to close, and for a refusal "Open the event".
local function drawNote(n, y, close, eventId)
  local h1 = text(n.title, X + 14, y + 10, { size = 14, color = C.title, width = W - 56 })
  local h2 = n.line and text(n.line, X + 14, y + 12 + h1, { size = 13, width = W - 56 }) or 0
  local extra = 0
  if eventId then
    button(X + 14, y + 16 + h1 + h2, 130, 22, UI.Notices.TEXT.open, function() openEvent(eventId) end, { size = 12 })
    extra = 28
  end
  panel(X, y, W, h1 + h2 + 24 + extra)
  button(X + W - 32, y + 6, 26, 26, "×", close, { ink = C.muted })
  return y + h1 + h2 + 36 + extra
end

local function drawNotes(env, y, state)
  for _, n in ipairs(state.notices) do
    if not S.closed["state:" .. n.key] then y = drawNote(n, y, function() S.closed["state:" .. n.key] = true; render() end) end
  end
  if type(env.guild) ~= "table" then return y end
  local ok, list = try(UI.Notices.refusals, env.guild, env.date)
  for i, n in ipairs(ok and list or {}) do
    if i <= 3 then
      y = drawNote(n, y, function() UI.Notices.dismiss(env.guild, n.cid); ns.Sync.touch(); render() end, n.event)
    end
  end
  return y
end

local function drawList(env)
  local y = 8
  local _, state = try(UI.Notices.state, env)
  state = state or { notices = {} }
  y = drawNotes(env, y, state)
  local evs, by = E.held(env.guild) -- once for the month and the list
  local m
  local list = E.list(env, evs, by)
  y = strip(E.strip(env, list), y)
  if Frame.W >= NARROW then y, m = drawMonth(env, y, evs, by) end
  local cell = S.day and chosenCell(m)
  local dayTitle = cell and E.dayText(env, cell.at)
  if dayTitle then
    y = heading(dayTitle, nil, y)
    button(X + W - 118, y - 38, 110, 24, E.TEXT.allEvents, function() S.day = nil; render() end, { size = 13, align = "right" })
    list = { coming = E.dayRows(env, cell.ids, evs, by), earlier = list.earlier }
  else
    S.day = nil
    y = heading("Coming up", nil, y)
  end
  if #list.coming == 0 then
    local g = env.guild
    local nothing = type(g) ~= "table" or (next(g.records or {}) == nil and not (type(g.inbox) == "table" and g.inbox.at))
    if state.panel then -- waiting for the guild's details, not in a guild, or data for another guild: one plain panel
      local h = text(state.panel.title, X + 14, y, { size = 16, color = C.title, width = W - 28 })
      if state.panel.line then h = h + 6 + text(state.panel.line, X + 14, y + h + 6, { size = 13, width = W - 28 }) end
      y = y + h + 16
    elseif nothing then -- nothing from Tinteán yet: the map, and how it arrives
      scene("map", X, y)
      local h = text(UI.TEXT.noData, X + 144, y, { size = 16, color = C.title, width = W - 144 })
      h = h + 6 + text(UI.TEXT.noDataLine, X + 144, y + h + 6, { size = 13, width = W - 144 })
      y = y + math.max(h, 64) + 12
    else
      scene("campfire", X, y)
      local h = text(E.TEXT.empty, X + 144, y + 4, { size = 14, width = W - 144 })
      y = y + math.max(h + 4, 64) + 12
    end
    if T.hooks.afterEmpty then y = T.hooks.afterEmpty(cv, y, env) or y end
  else
    y = drawRows(list.coming, y) + 12
    if T.hooks.afterList then y = T.hooks.afterList(cv, y, env) or y end
  end
  local h = text(E.TEXT.under, X, y, { size = 12, color = C.muted, width = W })
  y = y + h + 6
  local lx = X
  if hasCalendar() then
    button(lx, y, 150, 22, E.TEXT.calendar, function() try(_G.ToggleCalendar) end, { size = 12 })
    lx = lx + 160
  end
  button(lx, y, 110, 22, E.TEXT.earlier, function() S.earlier = not S.earlier; render() end, { size = 12 })
  y = y + 34
  if S.earlier and #list.earlier > 0 then
    y = heading(E.TEXT.earlier, nil, y)
    y = drawRows(list.earlier, y) + 12
  end
  return y
end

---------------------------------------------------------------------------------------------- an event's page

local function drawWord(p, word, y)
  local w = E.word(word, p.title)
  if not w or S.away[p.id] then return y end
  local ink = C.sheetInk
  local top, yy = y, y + 10
  if w.relayed then
    for _, l in ipairs(w.lines) do yy = yy + text(l, X + 18, yy, { size = 14, color = ink, width = W - 40 }) + 6 end
  else
    yy = yy + text(w.heading, X + 18, yy, { size = 12, color = { .506, .345, .102, 1 } }) + 4 -- the page's accent (--sheet-accent)
    for _, t in ipairs(w.texts) do yy = yy + text(t, X + 18, yy, { size = 15, color = ink, width = W - 60 }) + 6 end
    text(E.TEXT.ask, X + 18, yy + 5, { size = 12, color = ink })
    button(X + 120, yy, 70, 26, E.TEXT.signUp, function() signUpAnyway(p, w) end, { bg = C.sea, ink = C.title, size = 12 })
    button(X + 198, yy, 70, 26, E.TEXT.notNow, function() try(ns.Words.notNow, p.id); S.away[p.id] = true; render() end,
      { bg = C.sheet, edge = dim(C.sheetInk, .25), ink = ink, size = 12 })
    yy = yy + 36
    if w.dismissable then button(X + W - 32, top + 6, 26, 26, "×", function() dismissWord(p) end, { ink = dim(C.sheetInk, .7) }) end
  end
  rect(X, top, W, yy - top + 4, C.sheet, 1)
  rect(X, top, 3, yy - top + 4, C.flame, 2)
  return yy + 20
end

local function drawWho(p, y)
  local w = p.who
  y = heading(E.TEXT.whosIn, w.meta, y)
  y = strip(w.figs, y - 4) + 4
  local rows = 0
  for _, g in ipairs(w.groups) do rows = rows + math.max(#g.rows, 1) end
  local ink = p.faded and .55 or 1
  local top, yy = y, y + 1
  for _, g in ipairs(w.groups) do
    text(g.label, X + 14, yy + 6, { size = 10, color = dim(C.gold, ink) })
    yy = yy + 24
    if #g.rows == 0 then
      text(E.TEXT.nobody, X + 14, yy + 2, { size = 12, color = dim(C.muted, ink) })
      yy = yy + 24
    end
    for _, r in ipairs(g.rows) do
      local nx, h, sz = X + 14, r.sub and 44 or 40, E.SIZE.who
      if classIcon(r.class, X + 14, yy + (h - sz) / 2, sz, ink) then nx = X + 14 + sz + 12 end
      text(r.name, nx, yy + (r.sub and 6 or 12), { size = 14, color = dim(r.color or C.title, ink) })
      if r.sub then text(r.sub, nx, yy + 24, { size = 12, color = dim(C.muted, ink) }) end
      text(r.status, X + W - 14, yy + (h - 14) / 2, { size = 12, color = dim(C[STATUS_INK[r.status] or "muted"], ink), right = true })
      yy = yy + h
    end
  end
  if rows > 0 then panel(X, top - 1, W, yy - top + 4) end
  y = yy + 10
  if w.summary then y = y + text(w.summary, X, y, { size = 12, color = C.muted, width = W }) + 10 end
  return y + 6
end

-- The page's notice (another of my characters is signed up already), until the person closes it.
local function drawNotice(p, y)
  if not p.notice or S.closed[p.notice.key] then return y end
  local h1 = text(p.notice.title, X + 14, y + 10, { size = 14, color = C.title })
  local h2 = text(p.notice.line, X + 14, y + 12 + h1, { size = 13, width = W - 56 })
  panel(X, y, W, h1 + h2 + 24)
  button(X + W - 32, y + 6, 26, 26, "×", function() S.closed[p.notice.key] = true; render() end, { ink = C.muted })
  return y + h1 + h2 + 42
end

local function drawSignup(p, y)
  y = heading(E.TEXT.yourSignup, nil, y)
  local m = p.me
  local top = y
  local nx = X + 14
  if classIcon(m.class, X + 14, y + 8, E.SIZE.me) then nx = X + 14 + E.SIZE.me + 12 end
  text(m.name, nx, y + 10, { size = 14, color = m.color or C.title })
  if m.line then text(m.line, nx, y + 28, { size = 12, color = C.muted }) end
  local rx = X + W - 14
  for i = #m.roles, 1, -1 do
    local role = m.roles[i]
    rx = rx - 84
    button(rx, y + 14, 80, 22, E.TEXT.roles[role], function() S.role[p.id] = role; render() end,
      { bg = role == m.role and C.sea or C.ground, edge = role == m.role and C.sea or C.lineStrong, ink = C.title, size = 11, icon = { role == "dps" and "damage" or role, C.title } })
  end
  y = y + 62
  for i, pill in ipairs(E.TEXT.pills) do
    local on = m.status == pill[1]
    button(X + 14 + (i - 1) * 96, y, 90, 30, pill[2], function() signUp(p, pill[1]) end,
      { bg = on and C.sea or C.ground, edge = on and C.sea or C.lineStrong, ink = C.title, size = 13, chosen = on })
  end
  local eb = noteBox()
  if eb then
    call(eb, "ClearAllPoints")
    call(eb, "SetPoint", "TOPLEFT", cv.child, "TOPLEFT", X + 14 + 3 * 96 + 10, -y)
    call(eb, "SetMaxLetters", p.note.max or 200)
    call(eb, "SetSize", W - 14 * 2 - 3 * 96 - 10, 30)
    call(eb.hint, "SetText", p.note.hint)
    if cv.noteFor ~= p.id then
      cv.noteFor = p.id
      call(eb, "SetText", p.note.text or "") -- as written: the escaped form is for font strings
    end
    call(eb, "Show")
    cv.noteUsed = true
  end
  y = y + 40
  local lines = {}
  for _, l in ipairs(p.lines) do lines[#lines + 1] = l end
  if S.said[p.id] then lines[#lines + 1] = S.said[p.id] end
  for _, l in ipairs(lines) do y = y + text(l, X + 14, y, { size = 13, color = C.body, width = W - 28 }) + 4 end
  y = y + 8
  panel(X, top, W, y - top)
  return y + 18
end

-- Your sign-up for a character that isn't on the roster: no pills, and the two lines that say why.
local function drawUnlisted(p, y)
  y = heading(E.TEXT.yourSignup, nil, y)
  local top = y
  y = y + 12
  for i, l in ipairs(p.unlisted) do
    y = y + text(l, X + 14, y, { size = i == 1 and 14 or 13, color = i == 1 and C.title or C.body, width = W - 28 }) + 4
  end
  y = y + 8
  panel(X, top, W, y - top)
  return y + 18
end

local function drawPage(env)
  local y = 8
  local p = E.page(env, S.page, S.role[S.page])
  if not p then S.page = nil; return drawList(env) end
  button(X, y, 76, 22, E.TEXT.back, leave, { size = 13, align = "left" }) -- "← Events": the arrow is drawn
  chevron(X + 4, y + 11, -1, C.moss)
  y = y + 30
  local face = p.faded and C.muted or C.title
  local head, tx = y, X + E.SIZE.page + 12
  placePic(p.art, X, y, E.SIZE.page)
  y = y + text(p.title, tx, y, { size = 26, color = face, font = "display" }) + 4
  y = y + text(p.when, tx, y, { size = 14, color = p.faded and C.muted or C.body, width = W - tx + X }) + 2
  y = y + text(p.meta, tx, y, { size = 12, color = C.muted, width = W - tx + X }) + 14
  y = math.max(y, head + E.SIZE.page + 14)
  if p.banner then
    local top, yy = y, y + 12
    for i, l in ipairs(p.banner) do
      yy = yy + text(l, X + 14, yy, { size = i == 1 and 14 or 13, color = i == 1 and C.title or C.body, width = W - 28 }) + 4
    end
    panel(X, top, W, yy - top + 8)
    y = yy + 24
    if p.state == "cancelled" and T.hooks.cancelledPage then y = T.hooks.cancelledPage(p, y, env) or y end -- Undo, for an officer
  end
  if p.state == "group" and not p.me then return y end
  if p.state == "group" then -- a member: the word, then the pills, and no list of who is in (their names stay on the website)
    local ok, word = try(ns.Words.forEvent, p.id)
    return drawSignup(p, drawNotice(p, drawWord(p, ok and word or nil, y)))
  end
  if p.state == "open" then
    local ok, word = try(ns.Words.forEvent, p.id)
    y = drawWord(p, ok and word or nil, y)
    y = drawNotice(p, y)
    if p.me then y = drawSignup(p, y) elseif p.unlisted then y = drawUnlisted(p, y) end
  end
  y = drawWho(p, y)
  if p.plan then
    y = heading(E.TEXT.plan, nil, y)
    local h = text(p.plan, X + 14, y + 12, { size = 14, color = C.sheetInk, width = W - 28 })
    rect(X, y, W, h + 24, C.sheet, 1)
    y = y + h + 40
  end
  if p.state == "open" then
    button(X, y, 150, 28, E.TEXT.post, function() postInChat(p) end, { bg = C.ground, edge = C.lineStrong, ink = C.body, size = 13 })
    if T.hooks.openPage then y = T.hooks.openPage(p, X + 160, y, env) or y end -- Edit event and Cancel event, for an officer
    y = y + 40
    if S.shut[p.id] then
      local A = UI.Arrivals.TEXT
      local h1 = text(A.shut, X + 14, y + 10, { size = 14, color = C.title })
      local h2 = text(A.line, X + 14, y + 12 + h1, { size = 13, width = W - 56 })
      panel(X, y, W, h1 + h2 + 24)
      button(X + W - 32, y + 6, 26, 26, "×", function() S.shut[p.id] = nil; render() end, { ink = C.muted })
      y = y + h1 + h2 + 42
    end
  end
  return y
end

---------------------------------------------------------------------------------------------- the tab

-- What a drawing depends on, apart from what the user just did: the guild's table, the store's touches (Sync.rev, which
-- every edit, inbox read and dismissal makes), the minute, the page, the month and the flags the page keeps.
local function signature(env)
  local pg = S.page
  return { env.guild, ns.Sync.rev, math.floor((env.now or 0) / 60), pg, S.shift, S.earlier, pg and S.role[pg],
    pg and S.away[pg], pg and S.said[pg], UI.statusNote and UI.statusNote.text, Frame.W, S.day, env.guildName,
    type(env.inbox) == "table" and env.inbox.state or nil }
end

local function same(a, b)
  if not (a and b) then return false end
  for i = 1, 14 do if a[i] ~= b[i] then return false end end
  return true
end

-- Every action draws again (render()); the tab's own refresh (every few seconds) draws only if something has changed.
function render(quiet)
  if not cv.child then return end
  -- Nothing is drawn where it can't be seen. The client lays a line of text out, and loads its font, when it is
  -- shown; text given to one in a shut window can stay blank until it is given again (the day numbers on the
  -- first open, M20.15). So a shut window draws nothing, and the draw waits for the first time it is open.
  local _, seen = call(cv.child, "IsVisible")
  if seen == false then cv.sig = nil; return end
  local env = Frame.env()
  local sig = signature(env)
  if quiet and same(sig, cv.sig) then return end
  cv.sig = sig
  begin()
  local y
  local ok = try(function() y = S.page and drawPage(env) or drawList(env) end)
  if not ok then cv.sig = nil end -- try again at the next refresh
  finish(ok and y or 8)
end
T.render = function() render(true) end
T.draw = function() render() end -- after an officer's action: draw again at once

-- The window or the tab goes away: the note box lets go of the keyboard.
-- and a chosen day is let go.
Frame.onHide = function() blur(); S.day = nil; if T.hooks.hidden then try(T.hooks.hidden) end end
Frame.onSelect = function(key) if key ~= "events" then blur(); S.day = nil end end

function T.build(panelFrame)
  local tab = Frame.tabs.events
  if tab then call(tab.head, "Hide"); call(tab.hr, "Hide") end -- the headings are drawn with the content
  local ok, sf = try(CreateFrame, "ScrollFrame", nil, panelFrame)
  if not ok or type(sf) ~= "table" then return end
  call(sf, "SetPoint", "TOPLEFT", panelFrame, "TOPLEFT", 0, -4)
  call(sf, "SetPoint", "BOTTOMRIGHT", panelFrame, "BOTTOMRIGHT", 0, 0)
  local ok2, child = try(CreateFrame, "Frame", nil, sf)
  if not ok2 or type(child) ~= "table" then return end
  call(child, "SetSize", Frame.W - 2, 400)
  call(sf, "SetScrollChild", child)
  call(child, "SetScript", "OnHide", blur)
  call(sf, "EnableMouseWheel", true)
  call(sf, "SetScript", "OnMouseWheel", function(self, delta)
    local _, cur = call(self, "GetVerticalScroll")
    local _, ch = call(child, "GetHeight")
    local _, sh = call(self, "GetHeight")
    local top = math.max((type(ch) == "number" and ch or 0) - (type(sh) == "number" and sh or 0), 0)
    call(self, "SetVerticalScroll", math.min(math.max((type(cur) == "number" and cur or 0) - delta * 40, 0), top))
  end)
  cv.scroll, cv.child = sf, child
  if T.hooks.built then try(T.hooks.built) end -- the officers' sheet goes over this panel
  render()
end

UI.registerTab("events", { label = "Events", heading = "Coming up", order = 10, build = T.build, refresh = T.render,
  count = function(events) return events end })

-- The drawing helpers for the other tabs (Bulletins, M20.16), which keep a canvas of their own: T.canvas(c, fn) runs fn
-- with the helpers pointed at `c` ({ pools = {}, child = <frame> }) and puts ours back after, even if fn fails.
T.kit = { rect = rect, panel = panel, pic = pic, placePic = placePic, text = text, button = button, chevron = chevron,
  strip = strip, scene = scene, heading = heading, begin = begin, finish = finish, dim = dim, classIcon = classIcon }
function T.canvas(c, fn)
  local mine = cv
  cv = c
  local ok = try(fn)
  cv = mine
  return ok
end

return T
