-- The one helper every string from outside passes before it is shown (formats/game.md section 12):
-- invalid UTF-8, control characters other than newline, zero-width and direction-changing characters go,
-- the length is capped, and the game's "|" codes are escaped so nothing a guildmate or a file sends can colour
-- text, make a link or a texture. Stored records are never changed by it: digests compare what the server said.
-- Pure.
local _, ns = ...
ns = ns or {}

local Text = {}
ns.Text = Text

-- Caps in characters (game.md section 12).
Text.CAPS = { title = 80, text = 600, notes = 2000, note = 200, name = 80, warning = 1000 }

local sbyte, ssub = string.byte, string.sub

-- Width of the well-formed UTF-8 character at byte i (no overlongs, surrogates or past U+10FFFF), or 0.
local function width(s, i)
  local b = sbyte(s, i)
  if b < 128 then return 1 end
  local need, lo, hi
  lo, hi = 128, 191
  if b >= 194 and b <= 223 then need = 1
  elseif b >= 224 and b <= 239 then
    need = 2
    if b == 224 then lo = 160 elseif b == 237 then hi = 159 end
  elseif b >= 240 and b <= 244 then
    need = 3
    if b == 240 then lo = 144 elseif b == 244 then hi = 143 end
  else
    return 0
  end
  local c = sbyte(s, i + 1)
  if not c or c < lo or c > hi then return 0 end
  for k = 2, need do
    c = sbyte(s, i + k)
    if not c or c < 128 or c > 191 then return 0 end
  end
  return need + 1
end

-- C1 controls, U+200B to U+200F, U+202A to U+202E, U+2066 to U+2069.
local function hidden(ch)
  local a, b, c = sbyte(ch, 1, 3)
  if a == 194 then return b >= 128 and b <= 159 end
  if a == 226 then
    if b == 128 then return (c >= 139 and c <= 143) or (c >= 170 and c <= 174) end
    if b == 129 then return c >= 166 and c <= 169 end
  end
  return false
end

-- Text.clean(value, max) -> a string safe to show (empty for anything that is not a string).
function Text.clean(s, max)
  if type(s) ~= "string" then return "" end
  max = max or Text.CAPS.text
  -- Work is bounded by the cap: a character is at most 4 bytes.
  if #s > max * 4 then s = ssub(s, 1, max * 4) end
  local out, n, i, len = {}, 0, 1, #s
  while i <= len and n < max do
    local w = width(s, i)
    if w == 0 then
      i = i + 1
    else
      local ch = ssub(s, i, i + w - 1)
      i = i + w
      if w == 1 then
        local b = sbyte(ch)
        if b == 10 or (b >= 32 and b ~= 127) then
          n = n + 1
          out[#out + 1] = b == 124 and "||" or ch
        end
      elseif not hidden(ch) then
        n = n + 1
        out[#out + 1] = ch
      end
    end
  end
  return table.concat(out)
end
