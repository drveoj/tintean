-- A small window holding text already selected, since chat text can't be copied
-- and the game can't write to the clipboard. ns.CopyBox.show(title, text).
-- Frame templates used (all in Blizzard's shared UI): BackdropTemplate (SetBackdrop),
-- UIPanelScrollFrameTemplate, UIPanelCloseButton. Fonts: GameFontNormal, GameFontHighlightSmall, ChatFontNormal.
-- The frame is made on first use, never at load; every game call goes through ns.try.
local _, ns = ...
ns = ns or {}

local CopyBox = {}
ns.CopyBox = CopyBox

CopyBox.NAME = "TinteanCopyBox"
CopyBox.HINT = "Press Ctrl+C to copy (Cmd+C on a Mac), then paste it where you need it."

local try = function(...) return ns.try(...) end

-- Call a method on a widget, ignoring a missing method or an error.
local function call(obj, method, ...)
  if type(obj) ~= "table" then return false end
  return try(obj[method], obj, ...)
end

local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8X8",
  edgeFile = "Interface\\Buttons\\WHITE8X8",
  edgeSize = 1,
}

local function build()
  local ok, f = try(CreateFrame, "Frame", CopyBox.NAME, UIParent, "BackdropTemplate")
  if not ok or type(f) ~= "table" then return nil end
  call(f, "SetSize", 520, 340)
  call(f, "SetPoint", "CENTER")
  call(f, "SetFrameStrata", "DIALOG")
  call(f, "SetMovable", true)
  call(f, "SetClampedToScreen", true)
  call(f, "EnableMouse", true)
  call(f, "RegisterForDrag", "LeftButton")
  call(f, "SetScript", "OnDragStart", function(self) call(self, "StartMoving") end)
  call(f, "SetScript", "OnDragStop", function(self) call(self, "StopMovingOrSizing") end)
  call(f, "SetBackdrop", BACKDROP)
  call(f, "SetBackdropColor", 0.07, 0.08, 0.12, 0.96)
  call(f, "SetBackdropBorderColor", 0.35, 0.33, 0.28, 1)
  call(f, "Hide")

  local _, title = try(f.CreateFontString, f, nil, "OVERLAY", "GameFontNormal")
  call(title, "SetPoint", "TOPLEFT", 14, -12)
  f.title = title

  local _, close = try(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
  call(close, "SetPoint", "TOPRIGHT", -2, -2)
  call(close, "SetScript", "OnClick", function() call(f, "Hide") end)

  local _, hint = try(f.CreateFontString, f, nil, "OVERLAY", "GameFontHighlightSmall")
  call(hint, "SetPoint", "BOTTOMLEFT", 14, 12)
  call(hint, "SetText", CopyBox.HINT)

  local _, scroll = try(CreateFrame, "ScrollFrame", CopyBox.NAME .. "Scroll", f, "UIPanelScrollFrameTemplate")
  call(scroll, "SetPoint", "TOPLEFT", 14, -40)
  call(scroll, "SetPoint", "BOTTOMRIGHT", -34, 36)

  local _, edit = try(CreateFrame, "EditBox", nil, scroll)
  call(edit, "SetMultiLine", true)
  call(edit, "SetAutoFocus", false)
  call(edit, "SetMaxLetters", 0)
  call(edit, "SetFontObject", ChatFontNormal)
  call(edit, "SetWidth", 470)
  call(scroll, "SetScrollChild", edit)
  -- Read-only in effect: an edit puts the text back and selects it again.
  call(edit, "SetScript", "OnTextChanged", function(self, byUser)
    if byUser and not CopyBox.busy and CopyBox.text then
      CopyBox.busy = true
      call(self, "SetText", CopyBox.text)
      call(self, "HighlightText")
      CopyBox.busy = false
    end
  end)
  call(edit, "SetScript", "OnEscapePressed", function() call(f, "Hide") end)

  f.edit = edit
  if type(UISpecialFrames) == "table" then
    UISpecialFrames[#UISpecialFrames + 1] = CopyBox.NAME
  end
  return f
end

function CopyBox.show(title, text)
  text = tostring(text or "")
  if not CopyBox.frame then CopyBox.frame = build() end
  local f = CopyBox.frame
  if not f then return false end
  call(f.title, "SetText", tostring(title or ""))
  CopyBox.text = text
  CopyBox.busy = true
  call(f.edit, "SetText", text)
  CopyBox.busy = false
  call(f, "Show")
  call(f.edit, "SetFocus")
  call(f.edit, "HighlightText")
  return true
end
