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

local function fire(unit, spellID, cd)
    local existing = GBI.Brain and GBI.Brain.GetState
        and GBI.Brain.GetState(unit, spellID)
    if existing and existing.endsAt and existing.endsAt > GetTime() + 1 then
        return  -- already tracked as live
    end
    log("Debug", "evidence aura %d (%s) on %s", spellID, cd.name, unit)
    if GBI.Brain and GBI.Brain.OnCast then
        GBI.Brain.OnCast(unit, spellID, cd)
    end
end

-- ---------------------------------------------------------------------------
-- Polling fallback. On some remote-PC configurations both UNIT_SPELLCAST_*
-- and UNIT_AURA events go silent for party members in 12.0.5. We bypass
-- the event wall by directly polling C_UnitAuras every 0.75s and treating
-- "newly seen aura since last tick" as a cast event.
-- ---------------------------------------------------------------------------

local POLL_INTERVAL = 0.75
local seenAuras = {}     -- [unit] = { [auraName] = lastSeenAt }

local function pollPartyAuras()
    local now = GetTime()
    for _, unit in ipairs(K.PARTY_OTHERS or { "party1", "party2", "party3", "party4" }) do
        if UnitExists(unit) then
            seenAuras[unit] = seenAuras[unit] or {}
            local _, classToken = UnitClass(unit)
            for i = 1, 40 do
                local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
                if not ok or not aura then break end
                local okN, name = pcall(function() return aura.name end)
                if okN and type(name) == "string" then
                    local last = seenAuras[unit][name]
                    -- New aura, OR the same aura recently expired and was re-applied
                    if not last or (now - last) > 5 then
                        local sid = GBI.AuraMap and GBI.AuraMap.LookupByName
                            and GBI.AuraMap.LookupByName(name, classToken)
                        if sid then
                            local cd = GBI.GetCooldown(sid)
                            if cd then
                                log("Debug", "poll-detect '%s' on %s -> %d", name, unit, sid)
                                if GBI.Brain and GBI.Brain.OnCast then
                                    GBI.Brain.OnCast(unit, sid, cd)
                                end
                            end
                        end
                    end
                    seenAuras[unit][name] = now
                end
            end
        end
    end
end

local poller = CreateFrame("Frame")
poller:SetScript("OnUpdate", function(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < POLL_INTERVAL then return end
    self.acc = 0
    pcall(pollPartyAuras)
end)

f:SetScript("OnEvent", function(_, event, unit, updateInfo)
    if event ~= "UNIT_AURA" then return end
    if not K.PARTY_UNITS_SET[unit] then return end
    if not updateInfo or updateInfo.isFullUpdate or not updateInfo.addedAuras then return end

    local _, classToken = UnitClass(unit)
    log("Debug", "UNIT_AURA unit=%s addedAuras=%d", unit, #updateInfo.addedAuras)

    for _, aura in ipairs(updateInfo.addedAuras) do
        -- Path 1: spellId. May be secret-tagged on remote-PC party members.
        local okId, rawId = pcall(function() return aura.spellId end)
        local spellID = okId and rawId and GBI.Taint.SafeSpellID(rawId) or nil
        local cd = spellID and GBI.GetCooldown(spellID)
        if cd and (not cd.class or cd.class == classToken) then
            fire(unit, spellID, cd)
        else
            -- Path 2: spell name. Names aren't tagged. Match against AuraMap.
            local okN, rawName = pcall(function() return aura.name end)
            if okN and type(rawName) == "string" then
                local sidByName = GBI.AuraMap and GBI.AuraMap.LookupByName
                    and GBI.AuraMap.LookupByName(rawName, classToken)
                if sidByName then
                    local cdN = GBI.GetCooldown(sidByName)
                    if cdN then
                        log("Debug", "  evidence-by-name '%s' -> %d", rawName, sidByName)
                        fire(unit, sidByName, cdN)
                    end
                else
                    log("Debug", "  aura '%s' on %s -> no DB match", rawName, unit)
                end
            end
        end
    end
end)
