-- UNIT_AURA evidence. Phase 3 brought forward to Phase 1.
--
-- In Midnight 12.0.5, UNIT_SPELLCAST_SUCCEEDED's spellID is fully redacted
-- to nil for OTHER party members. We can't read it, can't scrub it. Local
-- cast detection for party1..party4 is dead.
--
-- Workaround: listen for UNIT_AURA on each party member. When a known CD's
-- buff appears (e.g. Avenging Wrath aura applies to a paladin), infer that
-- the player just cast that spell and forward to Brain.
--
-- Limitations:
--   * Won't catch pure interrupts (Pummel, Kick, etc.) — those leave no buff.
--   * Won't catch CDs where the buff aura ID differs from the cast spell ID.
--     For Phase 1 we assume aura ID == cast spell ID; that holds for the
--     majority of tracked Data_Cooldowns entries (defensives, big CDs).
--
-- Brain already dedups by 250ms, so when our own cast is detected via both
-- UNIT_SPELLCAST_SUCCEEDED *and* UNIT_AURA we don't double-fire.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K

local function log(level, ...) if GBI.Log then GBI.Log[level]("evidence", ...) end end

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_EvidenceFrame")
f:RegisterUnitEvent("UNIT_AURA",
    "player", "party1", "party2", "party3", "party4")

f:SetScript("OnEvent", function(_, event, unit, updateInfo)
    if event ~= "UNIT_AURA" then return end
    if not K.PARTY_UNITS_SET[unit] then return end
    if not updateInfo or updateInfo.isFullUpdate or not updateInfo.addedAuras then return end

    local _, classToken = UnitClass(unit)

    for _, aura in ipairs(updateInfo.addedAuras) do
        -- Midnight: any field access on a private aura throws. pcall.
        local ok, rawId = pcall(function() return aura.spellId end)
        if ok and rawId then
            local spellID = GBI.Taint.SafeSpellID(rawId)
            if spellID then
                local cd = GBI.GetCooldown(spellID)
                if cd and (not cd.class or cd.class == classToken) then
                    -- Skip if Brain already has fresh state (avoids re-fire on
                    -- buff refresh / pet aura churn).
                    local existing = GBI.Brain and GBI.Brain.GetState
                        and GBI.Brain.GetState(unit, spellID)
                    if existing and existing.endsAt and existing.endsAt > GetTime() + 1 then
                        -- already tracking this CD as live; skip
                    else
                        log("Debug", "evidence aura %d (%s) on %s", spellID, cd.name, unit)
                        if GBI.Brain and GBI.Brain.OnCast then
                            GBI.Brain.OnCast(unit, spellID, cd)
                        end
                    end
                end
            end
        end
    end
end)
