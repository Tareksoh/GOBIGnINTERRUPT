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

-- WoW exposes `issecretvalue` globally in 12.0.5+ — the proper way to
-- detect a tagged value before using it. Used by OmniReborn, InterruptTrack,
-- and Kicker. Falls back to a pcall'd index probe if not present.
local _issecret = _G.issecretvalue

local function isSecret(v)
    if v == nil then return false end
    if _issecret then
        local ok, r = pcall(_issecret, v)
        return ok and r and true or false
    end
    -- Fallback: try to use v as a key in a fresh empty table. If it throws,
    -- assume tagged.
    local probe = {}
    local ok = pcall(function() probe[v] = 1 end)
    return not ok
end
T.IsSecret = isSecret

-- Helpers ------------------------------------------------------------------

local function laundered(rawNum)
    if rawNum == nil then return nil end
    -- Path 1: tostring -> tonumber. Works for clean values + most tagged
    -- numbers (the tagging propagates through tostring digits in some
    -- builds but the resulting tonumber still strips it).
    local ok, s = pcall(tostring, rawNum)
    if ok and type(s) == "string" then
        local n = tonumber(s)
        if n then return n end
    end
    -- Path 2: string.format("%d", x). C-level integer formatting. The
    -- output string is plain Lua (not a tagged Lua-string), so tonumber
    -- works cleanly. Also pcall'd because format on a tagged number can
    -- still throw in some builds.
    local ok2, s2 = pcall(string.format, "%d", rawNum)
    if ok2 and type(s2) == "string" then
        local n = tonumber(s2)
        if n then return n end
    end
    return nil
end

function T.SafeNumber(raw)
    return laundered(raw)
end

function T.SafeSpellID(raw)
    if raw == nil or isSecret(raw) then return nil end
    local n = laundered(raw)
    if type(n) ~= "number" or n <= 0 then return nil end
    return n
end

-- Take any value and return it only if it's a non-secret string. Otherwise nil.
-- Use before passing user-supplied or event-payload strings to table keys
-- or string functions.
function T.SafeString2(raw)
    if type(raw) ~= "string" then return nil end
    if isSecret(raw) then return nil end
    return raw
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
