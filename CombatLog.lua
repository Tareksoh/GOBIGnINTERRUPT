-- CLEU-based party CD detection — third fallback path on top of
-- UNIT_SPELLCAST_SUCCEEDED (CastTracker), UNIT_AURA + polling (Evidence),
-- and CDComm peer broadcast.
--
-- Why we need this:
--   * Pure interrupts (Pummel, Mind Freeze) leave no buff aura — UNIT_AURA
--     polling can't see them.
--   * Instant DPS CDs without buffs (Touch of Death, Wake of Ashes)
--     similarly invisible to the polling path.
--   * Spells whose buff name differs from the cast name need aliases or
--     direct spellID — CLEU gives us the spellID for free.
--
-- 12.0.5 reality:
--   * COMBAT_LOG_EVENT_UNFILTERED is NOT blocked or batched. Events fire
--     in real time during combat (verified against OmniReborn / Details).
--   * Friendly-source SPELL_CAST_SUCCESS spellID is CLEAN (not redacted).
--   * Hostile-source events have tagged spellIDs but we don't read those.
--
-- Dedup: Brain.OnCast already throttles per (unit, spellID) at 250ms via
-- BRAIN_DEDUP_S. CastTracker / Evidence / CDComm / CombatLog all route
-- through Brain.OnCast → naturally collapsed when they fire close together.
--
-- Toggle: DB.combatLog.enabled (default true).

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.CombatLog = GBI.CombatLog or {}
local M = GBI.CombatLog

local function log(level, ...) if GBI.Log then GBI.Log[level]("cleu", ...) end end

local function enabled()
    local c = GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.combatLog
    if c and c.enabled == false then return false end
    return true
end

-- sourceGUID -> party unit token. Cached; flushed on roster updates.
local guidCache = {}
local function flushGUIDCache() guidCache = {} end

local function findUnit(sourceGUID)
    if not sourceGUID then return nil end
    if guidCache[sourceGUID] ~= nil then return guidCache[sourceGUID] or nil end
    -- Build cache entry: party + player.
    for _, unit in ipairs(K.PARTY_UNITS) do
        if UnitExists(unit) then
            local g = UnitGUID(unit)
            if g == sourceGUID then
                guidCache[sourceGUID] = unit
                return unit
            end
        end
    end
    guidCache[sourceGUID] = false   -- negative cache to skip future scans
    return nil
end

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_CLEUFrame")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")

f:SetScript("OnEvent", function(_, event)
    if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        flushGUIDCache()
        return
    end
    if event ~= "COMBAT_LOG_EVENT_UNFILTERED" then return end
    if not enabled() then return end

    local _, subEvent, _, sourceGUID, _, sourceFlags, _, _, _, _, _, spellID =
        CombatLogGetCurrentEventInfo()

    if subEvent ~= "SPELL_CAST_SUCCESS" then return end
    if type(spellID) ~= "number" then return end
    if not sourceGUID then return end

    -- Skip pet GUIDs — pet abilities aren't tracked under owner.
    if type(sourceGUID) == "string" and sourceGUID:sub(1, 4) == "Pet-" then return end

    local unit = findUnit(sourceGUID)
    if not unit then return end

    local cd = GBI.GetCooldown and GBI.GetCooldown(spellID)
    if not cd then return end

    -- Class filter: only fire if the unit's class matches the cd entry.
    local _, classToken = UnitClass(unit)
    if cd.class and classToken and cd.class ~= classToken then return end

    log("Debug", "cleu cast unit=%s spell=%d (%s)", unit, spellID, cd.name or "?")
    if GBI.Brain and GBI.Brain.OnCast then
        -- No overrideDuration — Brain applies TalentSync if known; the dedup
        -- window collapses concurrent CastTracker / CDComm hits.
        GBI.Brain.OnCast(unit, spellID, cd)
    end
end)
