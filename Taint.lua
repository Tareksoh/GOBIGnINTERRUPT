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
    -- Path 1: tonumber(tostring(x)). BOTH steps inside one pcall: a secret
    -- number's tostring can yield a tagged string, and tonumber on that can
    -- throw in some builds, so neither step may run unguarded.
    local ok, n = pcall(function() return tonumber(tostring(rawNum)) end)
    if ok and type(n) == "number" then return n end
    -- Path 2: C-level integer format, also fully pcall'd. The output is a
    -- plain Lua string so tonumber on it is clean.
    local ok2, n2 = pcall(function() return tonumber(string.format("%d", rawNum)) end)
    if ok2 and type(n2) == "number" then return n2 end
    return nil
end

function T.SafeNumber(raw)
    return laundered(raw)
end

function T.SafeSpellID(raw)
    if raw == nil then return nil end
    -- Launder rather than early-reject: tostring->tonumber strips the secret
    -- marker, so a tagged-but-launderable spell ID is recovered as a clean
    -- positive number instead of being dropped (avoidable false negatives).
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

-- Wrap UnitGUID and REJECT secret strings. Callers use the result as a
-- table key (Inspect spec cache) and in equality, both of which throw on a
-- tagged string. Returning nil for a secret GUID means that unit simply
-- isn't cached/matched — graceful degradation (spec falls back to permissive
-- / peer-comm / defaults) instead of a crash.
function T.SafeGUID(unit)
    if not unit then return nil end
    local ok, g = pcall(UnitGUID, unit)
    if not ok then return nil end
    if type(g) ~= "string" then return nil end
    if isSecret(g) then return nil end
    return g
end

-- Explicit name for the "safe to use as a table key" contract. Identical to
-- SafeGUID (which now rejects secrets); use this at key-use sites for intent.
function T.SafeGUIDKey(unit)
    return T.SafeGUID(unit)
end

-- pcall a function and return (ok, returns...). Logs an Err line on failure
-- if the Log module is loaded.
function T.Try(fn, ...)
    local ok, r1, r2, r3, r4 = pcall(fn, ...)
    if not ok and GBI.Log then GBI.Log.Err("taint", "pcall failed: %s", tostring(r1)) end
    return ok, r1, r2, r3, r4
end
