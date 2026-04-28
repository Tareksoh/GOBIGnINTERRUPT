-- Profile manager.
--
-- DB.profiles[name] = snapshot table (copy of DB minus profiles/activeProfile)
-- DB.activeProfile  = string (the slot the user last loaded; advisory only —
--                     the live settings are still on GOBIGnINTERRUPTDB itself)
--
-- API:
--   GBI.Profiles.List()             -> array of profile names
--   GBI.Profiles.Save(name)         -> snapshot current settings into name
--   GBI.Profiles.Load(name)         -> replace current settings with profile;
--                                       returns true/false (caller /reloads)
--   GBI.Profiles.Delete(name)
--   GBI.Profiles.Export(name)       -> serialized string for copy/paste
--   GBI.Profiles.Import(name, str)  -> ok, err
--   GBI.Profiles.GetActiveName()    -> string

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.Profiles = GBI.Profiles or {}
local M = GBI.Profiles

local function log(level, ...) if GBI.Log then GBI.Log[level]("profiles", ...) end end

local function deepCopy(t, seen)
    if type(t) ~= "table" then return t end
    seen = seen or {}
    if seen[t] then return seen[t] end
    local out = {}
    seen[t] = out
    for k, v in pairs(t) do out[k] = deepCopy(v, seen) end
    return out
end

-- Fields excluded from a profile snapshot (managed elsewhere or per-character).
local EXCLUDE = {
    profiles      = true,
    activeProfile = true,
    contextCurrent = true,
    schemaVersion  = true,
}

local function snapshotCurrent()
    local snap = {}
    for k, v in pairs(GOBIGnINTERRUPTDB) do
        if not EXCLUDE[k] then snap[k] = deepCopy(v) end
    end
    return snap
end

local function applyProfile(snap)
    for k in pairs(GOBIGnINTERRUPTDB) do
        if not EXCLUDE[k] then GOBIGnINTERRUPTDB[k] = nil end
    end
    for k, v in pairs(snap or {}) do
        GOBIGnINTERRUPTDB[k] = deepCopy(v)
    end
end

function M.List()
    local out = {}
    -- Defensive: ensure Default is always present even if EnsureDefault
    -- hasn't run yet (e.g. UI panel built before PLAYER_LOGIN).
    local seen = { Default = true }
    out[1] = "Default"
    for name in pairs(GOBIGnINTERRUPTDB.profiles or {}) do
        if not seen[name] then
            seen[name] = true
            out[#out+1] = name
        end
    end
    table.sort(out)
    return out
end

function M.GetActiveName()
    return GOBIGnINTERRUPTDB.activeProfile or "Default"
end

-- Ensure a "Default" profile always exists. Called once at addon load
-- so the Options dropdown is never empty, and so users always have a
-- baseline they can revert to.
function M.EnsureDefault()
    GOBIGnINTERRUPTDB.profiles = GOBIGnINTERRUPTDB.profiles or {}
    if not GOBIGnINTERRUPTDB.profiles["Default"] then
        GOBIGnINTERRUPTDB.profiles["Default"] = snapshotCurrent()
    end
    if not GOBIGnINTERRUPTDB.activeProfile then
        GOBIGnINTERRUPTDB.activeProfile = "Default"
    end
end

function M.Save(name)
    if type(name) ~= "string" or name == "" then return false, "empty name" end
    GOBIGnINTERRUPTDB.profiles = GOBIGnINTERRUPTDB.profiles or {}
    GOBIGnINTERRUPTDB.profiles[name] = snapshotCurrent()
    GOBIGnINTERRUPTDB.activeProfile = name
    log("Info", "saved profile '%s'", name)
    return true
end

function M.Load(name)
    local snap = GOBIGnINTERRUPTDB.profiles and GOBIGnINTERRUPTDB.profiles[name]
    if not snap then return false, "no such profile" end
    applyProfile(snap)
    GOBIGnINTERRUPTDB.activeProfile = name
    log("Info", "loaded profile '%s'", name)
    return true
end

function M.Delete(name)
    if not (GOBIGnINTERRUPTDB.profiles and GOBIGnINTERRUPTDB.profiles[name]) then
        return false, "no such profile"
    end
    GOBIGnINTERRUPTDB.profiles[name] = nil
    if GOBIGnINTERRUPTDB.activeProfile == name then
        GOBIGnINTERRUPTDB.activeProfile = "Default"
    end
    log("Info", "deleted profile '%s'", name)
    return true
end

-- Serialization ------------------------------------------------------------

local function serialize(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string"  then return ("%q"):format(v) end
    if t == "number"  then return tostring(v) end
    if t == "boolean" then return tostring(v) end
    if t ~= "table"   then return "nil" end
    local parts = { "{" }
    local nextIndent = indent .. "  "
    for k, val in pairs(v) do
        local key
        if type(k) == "number" then key = "[" .. k .. "]"
        elseif type(k) == "string" then key = "[" .. ("%q"):format(k) .. "]"
        end
        if key then
            parts[#parts+1] = nextIndent .. key .. " = " .. serialize(val, nextIndent) .. ","
        end
    end
    parts[#parts+1] = indent .. "}"
    return table.concat(parts, "\n")
end

local function deserialize(str)
    if type(str) ~= "string" then return nil, "not a string" end
    -- Strip optional "GBINT:" prefix added by Export.
    str = str:gsub("^%s*GBINT:", "")
    local fn, err = loadstring("return " .. str)
    if not fn then return nil, err end
    setfenv(fn, {})    -- no global access
    local ok, t = pcall(fn)
    if not ok then return nil, t end
    if type(t) ~= "table" then return nil, "result is not a table" end
    return t
end

function M.Export(name)
    local snap = GOBIGnINTERRUPTDB.profiles and GOBIGnINTERRUPTDB.profiles[name]
    if not snap then return nil, "no such profile" end
    return "GBINT:" .. serialize(snap)
end

-- Init on PLAYER_LOGIN.
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() M.EnsureDefault() end)

function M.Import(name, str)
    if type(name) ~= "string" or name == "" then return false, "empty name" end
    local snap, err = deserialize(str)
    if not snap then return false, err end
    GOBIGnINTERRUPTDB.profiles = GOBIGnINTERRUPTDB.profiles or {}
    GOBIGnINTERRUPTDB.profiles[name] = snap
    log("Info", "imported profile '%s'", name)
    return true
end
