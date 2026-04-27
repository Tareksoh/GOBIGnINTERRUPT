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

    -- VERBOSE: every event that reaches us, before any filter.
    log("Debug", "raw UNIT_SPELLCAST_SUCCEEDED unit=%s castGUID=%s rawSpell=%s",
        tostring(unit), tostring(arg2), tostring(rawSpellID))

    if not K.PARTY_UNITS_SET[unit] then return end

    -- Recovery path for the 12.0.5 redaction: arg3 returns a fake/derived ID
    -- (or nil) for other party members, but the castGUID *string* still
    -- embeds the real spell ID at segment 6.
    -- castGUID format: Cast-<type>-<server>-<inst>-<zoneUID>-<spellID>-<counter>
    local spellID = GBI.Taint.SafeSpellID(rawSpellID)
    if not spellID then
        -- raw arg3 was unusable (secret-tagged); recover spellID from
        -- castGUID segment 6. The GUID itself can be tagged so we first
        -- launder it via string.format("%s") (C-level, drops the taint
        -- marker), then pcall the match in case format itself failed.
        local castGUID = arg2
        if type(castGUID) == "string" then
            local cleanGUID
            local okF, formatted = pcall(string.format, "%s", castGUID)
            if okF and type(formatted) == "string" then
                cleanGUID = formatted
            else
                local okT, t = pcall(tostring, castGUID)
                if okT and type(t) == "string" then cleanGUID = t end
            end
            if cleanGUID then
                local okM, m = pcall(string.match, cleanGUID,
                    "^Cast%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
                local fromGUID = okM and tonumber(m) or nil
                if fromGUID then
                    log("Debug", "  recovered spell %d from castGUID (arg3 was %s)",
                        fromGUID, tostring(rawSpellID))
                    spellID = fromGUID
                else
                    -- Don't index the GUID string for logging; it may also
                    -- be tagged. Just note that match failed.
                    log("Debug", "  match failed: ok=%s m=%s",
                        tostring(okM), tostring(m))
                end
            end
        end
    end

    if not spellID then
        log("Debug", "  skip: cannot resolve spellID for %s (raw=%s, castGUID=%s)",
            unit, tostring(rawSpellID), tostring(arg2))
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
        local guid = GBI.Taint.SafeGUID(unit)
        local spec = guid and GBI.Inspect.GetSpecByGUID(guid) or nil
        if spec and not tContains(cd.spec, spec) then
            log("Debug", "skip %d on %s (spec %d not in cd.spec)", spellID, unit, spec)
            return
        end
        -- spec unknown: be permissive (don't skip)
    end

    log("Debug", "cast spell=%d unit=%s class=%s cat=%s",
        spellID, unit, tostring(classToken), tostring(cd.category))

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
