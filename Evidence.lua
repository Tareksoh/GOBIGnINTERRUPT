-- UNIT_AURA evidence — fallback detection for party CDs when
-- UNIT_SPELLCAST_SUCCEEDED's spellID is redacted in 12.0.5.
--
-- Strategy: listen for UNIT_AURA on each party member; when a known CD's
-- buff appears (by spellId or by spell name via AuraMap), infer that the
-- player just cast that spell and forward to Brain. A polling fallback
-- (C_UnitAuras every 0.75s) covers configurations where UNIT_AURA is also
-- silent for remote-PC party members.
--
-- Limitations:
--   * Pure interrupts (kicks) leave no buff — handled by KickCounter.lua
--     and CDComm.lua's peer broadcast instead.
--   * CDs whose buff ID != cast ID resolve via spell-name matching.
--
-- Brain already dedups by 250ms, so the same cast detected via UNIT_SPELLCAST,
-- UNIT_AURA, polling, and CDComm doesn't fire multiple times.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K

local function log(level, ...) if GBI.Log then GBI.Log[level]("evidence", ...) end end

-- Resolve a unit's specID for AuraMap.LookupByName. Returns nil when unknown.
-- Player: GetSpecialization() (1..4). Party: from Inspect.GetSpecByGUID.
local function unitSpec(unit)
    if unit == "player" then
        return GetSpecialization and GetSpecialization() or nil
    end
    local guid = GBI.Taint and GBI.Taint.SafeGUID and GBI.Taint.SafeGUID(unit) or nil
    if not guid then return nil end
    return GBI.Inspect and GBI.Inspect.GetSpecByGUID
        and GBI.Inspect.GetSpecByGUID(guid) or nil
end

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_EvidenceFrame")
f:RegisterUnitEvent("UNIT_AURA",
    "player", "party1", "party2", "party3", "party4")

-- Back-calculate when the cast actually happened from an aura's
-- expirationTime - duration.
--
-- 12.0.5 IS tagging aura.duration / aura.expirationTime as secret values
-- on remote-PC party members. tonumber() alone does NOT strip the taint —
-- the resulting number still throws on comparison. We must launder via
-- tostring → tonumber to break the secret-tag chain (per the secret-values
-- guidance in MEMORY.md). Wrap every step in pcall as belt-and-braces so
-- a single weird aura never spams the bug-grabber.
local function castedAtFromAura(aura)
    if not aura then return nil end
    local okExp, expRaw = pcall(function() return aura.expirationTime end)
    local okDur, durRaw = pcall(function() return aura.duration end)
    if not (okExp and okDur) then return nil end
    -- Launder: tostring breaks the taint, tonumber re-types.
    local okL, exp, dur = pcall(function()
        return tonumber(tostring(expRaw)), tonumber(tostring(durRaw))
    end)
    if not okL or not exp or not dur then return nil end
    -- Compare under pcall too — if any value still carries taint, fail closed.
    local okCmp, ca = pcall(function()
        if dur <= 0 or exp <= 0 then return nil end
        local v = exp - dur
        if v <= 0 or v > GetTime() + 0.1 then return nil end
        return v
    end)
    if not okCmp then return nil end
    return ca
end

local function fire(unit, spellID, cd, castedAt)
    local existing = GBI.Brain and GBI.Brain.GetState
        and GBI.Brain.GetState(unit, spellID)
    if existing and existing.endsAt and existing.endsAt > GetTime() + 1 then
        return  -- already tracked as live
    end
    log("Debug", "evidence aura %d (%s) on %s castedAt=%s",
        spellID, cd.name, unit, tostring(castedAt))
    if GBI.Brain and GBI.Brain.OnCast then
        GBI.Brain.OnCast(unit, spellID, cd, nil, castedAt)
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
            -- M+ encounters apply Private Auras (encounter mechanics broadcast
            -- on party members) at arbitrary slots. Reading those throws under
            -- our pcall — but only THAT slot. Use a small consecutive-failure
            -- counter to detect end-of-list (where aura is genuinely nil),
            -- while skipping individual slots that trip the read. The old
            -- behavior of `break` on the first throw missed every legit CD
            -- buff sitting at higher slots than the private aura.
            local consecutiveNil = 0
            for i = 1, 40 do
                local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
                if not ok then
                    -- Forbidden / private aura at this slot. Skip and keep
                    -- iterating; reset the consecutive-nil counter since this
                    -- isn't end-of-list, just an unreadable slot.
                    log("Debug", "poll skip slot %d on %s (forbidden)", i, unit)
                    consecutiveNil = 0
                elseif not aura then
                    -- Real end-of-list once we see two nils in a row (defensive
                    -- against transient nil returns).
                    consecutiveNil = consecutiveNil + 1
                    if consecutiveNil >= 2 then break end
                else
                    consecutiveNil = 0
                    local okN, name = pcall(function() return aura.name end)
                    if okN and type(name) == "string" then
                        local last = seenAuras[unit][name]
                        -- New aura, OR the same aura recently expired and was re-applied
                        if not last or (now - last) > 5 then
                            local sid = GBI.AuraMap and GBI.AuraMap.LookupByName
                                and GBI.AuraMap.LookupByName(name, classToken, unitSpec(unit))
                            if sid then
                                local cd = GBI.GetCooldown(sid)
                                if cd then
                                    local ca = castedAtFromAura(aura)
                                    log("Debug", "poll-detect '%s' on %s -> %d castedAt=%s",
                                        name, unit, sid, tostring(ca))
                                    fire(unit, sid, cd, ca)   -- routes through dedup
                                end
                            end
                        end
                        seenAuras[unit][name] = now
                    end
                end
            end
        end
    end
end

-- Engine gate: ask Bar.IsEngineEnabled (set authoritatively by SetEnabled
-- via App.UpdateContext). Evidence's UNIT_AURA handler and the polling
-- loop both bail when the engine is off — saves CPU and silences the
-- "no DB match" debug log spam outside dungeons.
local function engineOn()
    return GBI.Bar and GBI.Bar.IsEngineEnabled and GBI.Bar.IsEngineEnabled() or false
end

local poller = CreateFrame("Frame")
poller:SetScript("OnUpdate", function(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < POLL_INTERVAL then return end
    self.acc = 0
    if not engineOn() then return end
    pcall(pollPartyAuras)
end)

f:SetScript("OnEvent", function(_, event, unit, updateInfo)
    if event ~= "UNIT_AURA" then return end
    if not engineOn() then return end
    if not K.PARTY_UNITS_SET[unit] then return end
    if not updateInfo or updateInfo.isFullUpdate or not updateInfo.addedAuras then return end

    local _, classToken = UnitClass(unit)
    log("Debug", "UNIT_AURA unit=%s addedAuras=%d", unit, #updateInfo.addedAuras)

    for _, aura in ipairs(updateInfo.addedAuras) do
        local castedAt = castedAtFromAura(aura)
        -- Path 1: spellId. May be secret-tagged on remote-PC party members.
        local okId, rawId = pcall(function() return aura.spellId end)
        local spellID = okId and rawId and GBI.Taint.SafeSpellID(rawId) or nil
        local cd = spellID and GBI.GetCooldown(spellID)
        if cd and (not cd.class or cd.class == classToken) then
            fire(unit, spellID, cd, castedAt)
        else
            -- Path 2: spell name. Names usually aren't tagged for friendly
            -- units; we still distinguish a SafeString2 reject (tagged name)
            -- from a real "not in AuraMap" so we know whether to chase a
            -- 12.0.5 string-tagging regression vs a missing data entry.
            local okN, rawName = pcall(function() return aura.name end)
            if okN and type(rawName) == "string" then
                local cleanName = GBI.Taint and GBI.Taint.SafeString2
                    and GBI.Taint.SafeString2(rawName) or nil
                if not cleanName then
                    log("Debug", "  aura '%s' on %s -> name is secret-tagged " ..
                        "(SafeString2 rejected; lookup not attempted)",
                        rawName, unit)
                else
                    local sidByName = GBI.AuraMap and GBI.AuraMap.LookupByName
                        and GBI.AuraMap.LookupByName(cleanName, classToken, unitSpec(unit))
                    if sidByName then
                        local cdN = GBI.GetCooldown(sidByName)
                        if cdN then
                            log("Debug", "  evidence-by-name '%s' on %s -> %d",
                                rawName, unit, sidByName)
                            fire(unit, sidByName, cdN, castedAt)
                        else
                            -- AuraMap matched but spell gated by user's Spell DB.
                            log("Debug", "  aura '%s' on %s -> matched %d but " ..
                                "GetCooldown=nil (disabled in Spell DB?)",
                                rawName, unit, sidByName)
                        end
                    else
                        log("Debug", "  aura '%s' on %s -> not in AuraMap",
                            rawName, unit)
                    end
                end
            end
        end
    end
end)
