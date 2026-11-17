-- Which of two versions of one record is kept (formats/README.md, Clocks).
--   server version:  (rev,  0, 0,  cid)
--   pending edit:    (rebase or base, 1, at, cid)   rebase: set by a new epoch (game.md section 7)     cid compared as bytes
-- The larger key wins. Nothing else orders versions.
local _, ns = ...
ns = ns or {}

local Order = {}
ns.Order = Order

local sbyte = string.byte

function Order.serverKey(v) return { v.rev or 0, 0, 0, v.cid } end
function Order.pendingKey(v) return { v.rebase or v.base or 0, 1, v.at or 0, v.cid } end
function Order.key(v)
  if v.pending then return Order.pendingKey(v) end
  return Order.serverKey(v)
end

-- Byte-wise, whatever the locale.
function Order.compareBytes(a, b)
  local n = #a < #b and #a or #b
  for i = 1, n do
    local x, y = sbyte(a, i), sbyte(b, i)
    if x ~= y then return x < y and -1 or 1 end
  end
  if #a == #b then return 0 end
  return #a < #b and -1 or 1
end

-- -1, 0 or 1.
function Order.compare(ka, kb)
  for i = 1, 3 do
    if ka[i] ~= kb[i] then return ka[i] < kb[i] and -1 or 1 end
  end
  return Order.compareBytes(ka[4], kb[4])
end

-- The version kept of the two (a on a tie).
function Order.keeps(a, b)
  if Order.compare(Order.key(a), Order.key(b)) >= 0 then return a end
  return b
end
