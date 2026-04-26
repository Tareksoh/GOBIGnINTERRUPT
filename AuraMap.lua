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

GBI.AuraMap.byAuraID = {}   -- auraID -> cdSpellID

-- Build index. No-op in Phase 1 because no entry in Data_Cooldowns has an
-- `auraID` field yet. Kept structurally so Phase 3 only adds rows here.
local function build()
    for cdID, entry in pairs(GBI.Cooldowns or {}) do
        if entry and entry.auraID then
            GBI.AuraMap.byAuraID[entry.auraID] = cdID
        end
    end
end

function GBI.AuraMap.Lookup(auraID)
    if type(auraID) ~= "number" then return nil end
    return GBI.AuraMap.byAuraID[auraID]
end

build()
