-- Aura -> CD lookup. Built at addon load from Data_Cooldowns.
--
-- The name index is the fallback for 12.0.5 remote-PC parties where
-- aura.spellId comes back tagged-and-unlaunderable; aura.name is plain
-- and reliable, so Evidence.lua matches the buff name against this map
-- to resolve the cast spell ID for non-addon peers.
--
-- Schema for entries in Data_Cooldowns:
--   name         - the cast spell name (display); registered as a lookup key
--   auraAliases  - optional list of additional buff names to register
--                  (use when WoW's buff name differs from the cast name,
--                  e.g. Void Eruption -> "Voidform")
--
-- Multiple spells can register under the same (name, class). Two scenarios:
--   1. Spec-disambiguated: e.g. Bladestorm 227847 (Arms) and 46924 (Fury)
--      both register "Bladestorm" -> WARRIOR. LookupByName resolves by
--      passing the unit's specID; we pick the entry with matching `cd.spec`.
--   2. Spec-overlapping: e.g. all three Shaman Ascendances register
--      "Ascendance" -> SHAMAN. With specID, we still resolve correctly.
--      Without specID, the first candidate is returned (last-loaded behavior
--      of the old map; deterministic only on tied entries).

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.AuraMap = GBI.AuraMap or {}

GBI.AuraMap.byAuraID    = {}                -- auraID -> cdSpellID
GBI.AuraMap.byNameClass = {}                -- name -> { CLASS_TOKEN -> { sid, sid, ... } }

local function registerName(name, classToken, cdID)
    if type(name) ~= "string" or not classToken then return end
    GBI.AuraMap.byNameClass[name] = GBI.AuraMap.byNameClass[name] or {}
    local list = GBI.AuraMap.byNameClass[name][classToken]
    if not list then
        list = {}
        GBI.AuraMap.byNameClass[name][classToken] = list
    end
    -- de-dupe: alias may match the spell's own entry.name
    for _, existing in ipairs(list) do
        if existing == cdID then return end
    end
    table.insert(list, cdID)
end

local function build()
    for cdID, entry in pairs(GBI.Cooldowns or {}) do
        if entry and entry.auraID then
            GBI.AuraMap.byAuraID[entry.auraID] = cdID
        end
        if entry and entry.class then
            registerName(entry.name, entry.class, cdID)
            if type(entry.auraAliases) == "table" then
                for _, alias in ipairs(entry.auraAliases) do
                    registerName(alias, entry.class, cdID)
                end
            end
        end
    end
end

function GBI.AuraMap.Lookup(auraID)
    if type(auraID) ~= "number" then return nil end
    return GBI.AuraMap.byAuraID[auraID]
end

-- Resolve a candidate list to a single spell ID.
-- Preference order:
--   1. Entry whose `cd.spec` includes the unit's specID (when specID given).
--   2. Entry without `cd.spec` (applies to all specs of the class).
--   3. First candidate in the list.
local function pickFromList(list, specID)
    if not list or #list == 0 then return nil end
    if #list == 1 then return list[1] end
    if specID then
        for _, sid in ipairs(list) do
            local cd = GBI.Cooldowns[sid]
            if cd and type(cd.spec) == "table" then
                for _, s in ipairs(cd.spec) do
                    if s == specID then return sid end
                end
            end
        end
    end
    for _, sid in ipairs(list) do
        local cd = GBI.Cooldowns[sid]
        if cd and not cd.spec then return sid end
    end
    return list[1]
end

-- Returns cdSpellID or nil.
--   classToken nil -> try every class match (returns first hit).
--   specID     nil -> no spec preference (still works for unique names).
function GBI.AuraMap.LookupByName(name, classToken, specID)
    -- Reject tagged strings up front (issecretvalue check in Taint).
    name = GBI.Taint and GBI.Taint.SafeString2 and GBI.Taint.SafeString2(name) or nil
    if not name then return nil end
    local byClass = GBI.AuraMap.byNameClass[name]
    if not byClass then return nil end
    if classToken and byClass[classToken] then
        return pickFromList(byClass[classToken], specID)
    end
    -- No class given (or this name doesn't exist for that class) — return
    -- the first match across any class.
    for _, list in pairs(byClass) do
        local sid = pickFromList(list, specID)
        if sid then return sid end
    end
    return nil
end

build()
