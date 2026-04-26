-- Midnight 12.0.5 secret-value scrub helpers.
--
-- Many WoW APIs (UnitGUID for hostiles, aura.spellId, UNIT_SPELLCAST_*'s
-- spellId) return a value that prints fine but throws "table index is secret"
-- when used as a table key. The fix is to round-trip through tostring -> tonumber
-- so the secret marker doesn't survive into our lookup tables.
--
-- Adapted from InterruptTrack IT_Core.lua:25-58 (slider-OnValueChanged launderer)
-- and OmniReborn's `issecretvalue` guard pattern.
--
-- Public API:
--   GBI.Taint.SafeSpellID(raw)    -> number | nil
--   GBI.Taint.SafeNumber(raw)     -> number | nil    (alias; works for any tainted number)
--   GBI.Taint.SafeString(raw)     -> string          ("" if can't read, never throws)
--   GBI.Taint.SafeAura(aura, key) -> any | nil       (pcalled aura[key])
--   GBI.Taint.SafeGUID(unit)      -> string | nil    (laundered UnitGUID)

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.Taint = GBI.Taint or {}
local T = GBI.Taint

-- Helpers ------------------------------------------------------------------

local function laundered(rawNum)
    if rawNum == nil then return nil end
    -- tostring on a secret-tagged number returns the right digits; tonumber
    -- of that string yields a regular non-secret number.
    local ok, s = pcall(tostring, rawNum)
    if not ok or not s then return nil end
    return tonumber(s)
end

function T.SafeNumber(raw)
    return laundered(raw)
end

function T.SafeSpellID(raw)
    local n = laundered(raw)
    if n and n > 0 then return n end
    return nil
end

function T.SafeString(raw)
    if raw == nil then return "" end
    local ok, s = pcall(tostring, raw)
    if ok and s then return s end
    return ""
end

-- Read aura[field] under pcall. Returns (ok, value).
-- Some auras are entirely "private" — any field access throws.
function T.SafeAura(aura, key)
    if aura == nil or key == nil then return false, nil end
    local ok, v = pcall(function() return aura[key] end)
    if ok then return true, v end
    return false, nil
end

-- Wrap UnitGUID. For hostile/private units in 12.0.x it can return a tainted
-- string; we don't index by it but we do compare equality, which is fine on
-- strings even if tainted. Still, this gives us a defensive read.
function T.SafeGUID(unit)
    if not unit then return nil end
    local ok, g = pcall(UnitGUID, unit)
    if not ok then return nil end
    if type(g) ~= "string" then return nil end
    return g
end

-- pcall a function and return (ok, returns...). Logs an Err line on failure
-- if the Log module is loaded.
function T.Try(fn, ...)
    local ok, r1, r2, r3, r4 = pcall(fn, ...)
    if not ok and GBI.Log then GBI.Log.Err("taint", "pcall failed: %s", tostring(r1)) end
    return ok, r1, r2, r3, r4
end
