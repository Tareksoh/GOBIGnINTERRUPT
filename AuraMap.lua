-- Aura -> CD lookup. Phase 3 (Evidence.lua) populates this from
-- Data_Cooldowns + a small per-cd `auraName` annotation, so when we *miss*
-- a UNIT_SPELLCAST_SUCCEEDED for a cast (taint suppression), we can still
-- fire the CD off the buff appearing.
--
-- Phase 1: stub. We register no aura events here. Brain.lua never calls
-- Lookup(). The file exists so the .toc load order stays stable for later.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.AuraMap = GBI.AuraMap or {}

GBI.AuraMap.byAuraID = {}                -- auraID -> cdSpellID
GBI.AuraMap.byNameClass = {}             -- name -> { CLASS_TOKEN -> cdSpellID }

-- Built at addon load: index Data_Cooldowns by both spellID and name+class.
-- The name index is the fallback for 12.0.5 remote-PC parties where aura.spellId
-- comes back tagged-and-unlaunderable; aura.name is plain and reliable.
local function build()
    for cdID, entry in pairs(GBI.Cooldowns or {}) do
        if entry and entry.auraID then
            GBI.AuraMap.byAuraID[entry.auraID] = cdID
        end
        if entry and entry.name and entry.class then
            GBI.AuraMap.byNameClass[entry.name] = GBI.AuraMap.byNameClass[entry.name] or {}
            GBI.AuraMap.byNameClass[entry.name][entry.class] = cdID
        end
    end
end

function GBI.AuraMap.Lookup(auraID)
    if type(auraID) ~= "number" then return nil end
    return GBI.AuraMap.byAuraID[auraID]
end

-- Returns cdSpellID or nil. classToken can be nil — we'll try every class match.
function GBI.AuraMap.LookupByName(name, classToken)
    if type(name) ~= "string" then return nil end
    local byClass = GBI.AuraMap.byNameClass[name]
    if not byClass then return nil end
    if classToken and byClass[classToken] then return byClass[classToken] end
    -- generic match (e.g. abilities not class-locked)
    for _, sid in pairs(byClass) do return sid end
    return nil
end

build()
