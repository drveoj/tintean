-- Deflate that does not compress: stored blocks only (RFC 1951, block type 0).
-- Valid raw deflate that every inflater reads; used when the game's own is not raw.
-- Deflate.stored(s) -> string
local _, ns = ...
ns = ns or {}

local Deflate = {}
ns.Deflate = Deflate

local schar, ssub = string.char, string.sub
local floor = math.floor

function Deflate.stored(s)
  local n = #s
  local parts, pos = {}, 1
  repeat
    local l = n - pos + 1
    if l > 65535 then l = 65535 end
    local final = (pos + l > n) and 1 or 0
    local nl = 65535 - l
    parts[#parts + 1] = schar(final, l % 256, floor(l / 256), nl % 256, floor(nl / 256))
    parts[#parts + 1] = ssub(s, pos, pos + l - 1)
    pos = pos + l
  until pos > n
  return table.concat(parts)
end
