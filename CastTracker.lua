-- UNIT_SPELLCAST_SUCCEEDED listener for party + self.
--
-- Phase 1: only listens to player + party1..party4. Phase 1.5 will extend to
-- target/focus/nameplate/boss for the interrupt-halfway alert.
--
-- Routing: every successful cast is laundered through Taint.SafeSpellID,
-- looked up in Data_Cooldowns, and forwarded to Brain.lua as a CD_START
-- event with { unit, guid, spellID, classToken }.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.CastTracker = GBI.CastTracker or {}
local M = GBI.CastTracker

local function log(level, ...) if GBI.Log then GBI.Log[level]("cast", ...) end end

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_CastFrame")

-- Register UNIT_SPELLCAST_SUCCEEDED for the 5 party tokens. The last 5
-- arguments to RegisterUnitEvent are the unit tokens we receive events for.
local function registerPartyCasts()
    f:UnregisterAllEvents()
    f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED",
        "player", "party1", "party2", "party3", "party4")
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
end

f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "GROUP_ROSTER_UPDATE" then
        registerPartyCasts()
        log("Debug", "re-registered for roster change")
        return
    end

    if event ~= "UNIT_SPELLCAST_SUCCEEDED" then return end

    -- arg1 = unit, arg2 = castGUID, arg3 = spellID (potentially secret)
    local unit = arg1
    local rawSpellID = arg3
    if not K.PARTY_UNITS_SET[unit] then return end

    -- Recovery path for the 12.0.5 redaction: arg3 returns a fake/derived ID
    -- (or nil) for other party members, but the castGUID *string* sometimes
    -- embeds the real spell ID at segment 6.
    -- castGUID format: Cast-<type>-<server>-<inst>-<zoneUID>-<spellID>-<counter>
    --
    -- For tagged casts, both arg3 AND the castGUID are typically tagged in
    -- 12.0.5 — string.match on a tagged string throws under pcall. We
    -- detect that case via IsSecret and silently fall back to Evidence
    -- (UNIT_AURA-based detection) instead of spamming the debug log.
    local spellID = GBI.Taint and GBI.Taint.SafeSpellID and GBI.Taint.SafeSpellID(rawSpellID) or nil
    local guidTagged = false
    if not spellID and type(arg2) == "string" then
        if GBI.Taint and GBI.Taint.IsSecret and GBI.Taint.IsSecret(arg2) then
            guidTagged = true
        else
            -- Untagged castGUID — try to extract spell ID from segment 6.
            local okM, m = pcall(string.match, arg2,
                "^Cast%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
            local fromGUID = okM and tonumber(m) or nil
            if fromGUID then
                log("Debug", "recovered spell %d from castGUID (arg3 was %s)",
                    fromGUID, tostring(rawSpellID))
                spellID = fromGUID
            end
        end
    end

    if not spellID then
        if guidTagged then
            -- Expected for non-addon peer casts in 12.0.5. Evidence handles
            -- detection via aura name; quiet log line just so it shows up
            -- if you're tracing why a particular spell didn't fire.
            log("Debug", "skip: tagged cast on %s (Evidence will catch via aura)", unit)
        else
            log("Debug", "skip: cannot resolve spellID for %s (raw=%s)",
                unit, tostring(rawSpellID))
        end
        return
    end

    local cd = GBI.GetCooldown(spellID)
    if not cd then
        log("Debug", "  skip: spell %d on %s not in CD database", spellID, unit)
        return
    end

    -- Class filter: only fire if the unit's class matches the cd entry.
    local _, classToken = UnitClass(unit)
    if cd.class and cd.class ~= classToken then
        log("Debug", "  skip: cd.class=%s but %s is %s", cd.class, unit, tostring(classToken))
        return
    end

    -- Spec filter: only fire if the unit's spec matches (when a spec list is given).
    if cd.spec then
        local guid = GBI.Taint and GBI.Taint.SafeGUID and GBI.Taint.SafeGUID(unit) or nil
        local spec = guid and GBI.Inspect and GBI.Inspect.GetSpecByGUID
            and GBI.Inspect.GetSpecByGUID(guid) or nil
        if spec and not tContains(cd.spec, spec) then
            log("Debug", "skip %d on %s (spec %d not in cd.spec)", spellID, unit, spec)
            return
        end
        -- spec unknown: be permissive (don't skip)
    end

    log("Debug", "cast spell=%d unit=%s class=%s cat=%s",
        spellID, unit, tostring(classToken), tostring(cd.category))

    -- Stack-resource spells don't have a CD; StackTracker handles their
    -- display via Brain.SetStacks. The cast itself triggers a brief glow
    -- flash to acknowledge the activation.
    if cd.stackingResource then
        if GBI.Brain and GBI.Brain.FlashCast then
            GBI.Brain.FlashCast(unit, spellID)
        end
        return
    end
    if GBI.Brain and GBI.Brain.OnCast then
        GBI.Brain.OnCast(unit, spellID, cd)
    end
end)

-- tContains polyfill: WoW provides it, but not all clients expose it as a
-- global -- guard.
if not tContains then
    function tContains(t, v)
        if not t then return false end
        for _, e in ipairs(t) do if e == v then return true end end
        return false
    end
end

function M.Reregister()
    registerPartyCasts()
end

registerPartyCasts()
