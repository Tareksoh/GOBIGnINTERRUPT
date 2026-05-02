-- Hybrid native-filter detection (inspired by InterruptTrack v3.2.0).
--
-- WoW 12.x exposes filtered aura queries that Blizzard maintains:
--   C_UnitAuras.GetUnitAuras(unit, "HELPFUL|BIG_DEFENSIVE")
--   C_UnitAuras.GetUnitAuras(unit, "HELPFUL|EXTERNAL_DEFENSIVE")
--   C_UnitAuras.GetUnitAuras(unit, "HELPFUL|IMPORTANT")
--
-- These three categories cover most of the major-cooldown space:
--   BIG_DEFENSIVE       tank-style self-cast majors (Shield Wall,
--                       Ardent Defender, GoAK, Survival Instincts,
--                       Anti-Magic Shell, Vampiric Embrace, Berserk
--                       Guardian, Dispersion).
--   EXTERNAL_DEFENSIVE  cast-on-others (Pain Suppression, Ironbark,
--                       Power Word: Barrier, BoP, BoSac, Time Dilation,
--                       Life Cocoon, Roar of Sacrifice).
--   IMPORTANT           major offensive/utility (Avenging Wrath,
--                       Combustion, Bloodlust/Heroism/Time Warp,
--                       Power Infusion, Trueshot).
--
-- Two wins over the existing aura-name path in Evidence.lua:
--
-- 1) **External-defensive attribution.** When a healer casts Pain
--    Suppression on the tank, the buff appears on the TANK (recipient)
--    not the priest. Evidence's name lookup matches it to spell 33206
--    but can't tell which priest cast it. The filtered aura table
--    includes `aura.sourceUnit` — the caster's unit token. We attribute
--    the cooldown to source instead of target.
--
-- 2) **Lookup by spell ID, not aura name.** Bypasses the AuraMap and
--    works regardless of name-tagging or auraAlias coverage. Any spell
--    in our Data_Cooldowns gets detected when Blizzard tagged its aura
--    in one of the three categories.
--
-- Existing detection paths (CastTracker, Evidence-by-name, CDComm,
-- StackTracker) keep running. Brain.OnCast's existing 250ms dedup +
-- the in-fire() endsAt-fresh check handle overlap cleanly.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.NativeFilters = GBI.NativeFilters or {}
local M = GBI.NativeFilters

local FILTERS = {
    "HELPFUL|BIG_DEFENSIVE",
    "HELPFUL|EXTERNAL_DEFENSIVE",
    "HELPFUL|IMPORTANT",
}
local POLL_INTERVAL = 1.0  -- slower than Evidence's 0.75s; filtered lists
                           -- are small (typically 0–3 entries per unit).

local function log(level, ...) if GBI.Log then GBI.Log[level]("native", ...) end end

local function engineOn()
    return GBI.Bar and GBI.Bar.IsEngineEnabled and GBI.Bar.IsEngineEnabled() or false
end

-- Same triple-pcall pattern Evidence uses for back-dating. aura.duration
-- and aura.expirationTime can be tagged on remote-PC party auras in
-- 12.0.5; tostring -> tonumber strips the marker, then the comparison
-- is wrapped in pcall as belt-and-braces.
local function castedAtFromAura(aura)
    if not aura then return nil end
    local okExp, expRaw = pcall(function() return aura.expirationTime end)
    local okDur, durRaw = pcall(function() return aura.duration end)
    if not (okExp and okDur) then return nil end
    local okL, exp, dur = pcall(function()
        return tonumber(tostring(expRaw)), tonumber(tostring(durRaw))
    end)
    if not okL or not exp or not dur then return nil end
    local okCmp, ca = pcall(function()
        if dur <= 0 or exp <= 0 then return nil end
        local v = exp - dur
        if v <= 0 or v > GetTime() + 0.1 then return nil end
        return v
    end)
    if not okCmp then return nil end
    return ca
end

-- Resolve attribution: the buff is on `scannedUnit`, but the spell was
-- actually cast by aura.sourceUnit. Returns a unit token (string) we
-- trust, or falls back to scannedUnit so self-buffs still attribute
-- correctly.
local function attributionUnit(aura, scannedUnit)
    local okSrc, src = pcall(function() return aura.sourceUnit end)
    if okSrc and type(src) == "string" then
        if src == "player" or K.PARTY_UNITS_SET[src] then
            return src
        end
        -- Sometimes sourceUnit is "pet" or a token we don't manage. Drop
        -- through to scannedUnit so the cooldown still shows somewhere
        -- reasonable; better than ignoring the cast entirely.
    end
    return scannedUnit
end

local function processAura(aura, scannedUnit)
    local okId, rawId = pcall(function() return aura.spellId end)
    if not okId or not rawId then return end
    local spellID = GBI.Taint and GBI.Taint.SafeSpellID
        and GBI.Taint.SafeSpellID(rawId) or nil
    if not spellID then return end

    local cd = GBI.GetCooldown(spellID)
    if not cd then return end  -- spell not in our DB; nothing to track

    local attribUnit = attributionUnit(aura, scannedUnit)

    -- Class match: cd.class is the caster's class; verify against
    -- attribUnit. classToken nil (transient inspect race) -> permissive.
    if cd.class then
        local _, classToken = UnitClass(attribUnit)
        if classToken and cd.class ~= classToken then return end
    end

    -- Skip if Brain already has a fresh entry for this (unit, spell).
    -- fire() inside Evidence does the same check; we replicate it here
    -- so we don't pile log spam from repeated polls.
    local existing = GBI.Brain and GBI.Brain.GetState
        and GBI.Brain.GetState(attribUnit, spellID)
    if existing and existing.endsAt and existing.endsAt > GetTime() + 1 then
        return
    end

    local castedAt = castedAtFromAura(aura)
    log("Debug", "native-detect %d on %s (source=%s) castedAt=%s",
        spellID, attribUnit, scannedUnit, tostring(castedAt))
    if GBI.Brain and GBI.Brain.OnCast then
        GBI.Brain.OnCast(attribUnit, spellID, cd, nil, castedAt)
    end
end

local function scanUnit(unit)
    if not UnitExists(unit) then return end
    for _, filter in ipairs(FILTERS) do
        local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, filter)
        if ok and type(auras) == "table" then
            for _, aura in ipairs(auras) do
                pcall(processAura, aura, unit)
            end
        end
    end
end

local function scanAll()
    for _, unit in ipairs(K.PARTY_UNITS) do
        pcall(scanUnit, unit)
    end
end

-- Periodic poll: backstop in case UNIT_AURA event delivery is missed
-- or arrives before the engine flips the gate to enabled.
local poller = CreateFrame("Frame", "GOBIGnINTERRUPT_NativeFiltersPoller")
poller:SetScript("OnUpdate", function(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < POLL_INTERVAL then return end
    self.acc = 0
    if not engineOn() then return end
    scanAll()
end)

-- Event-driven: scan the affected unit on UNIT_AURA, refresh whole
-- party on roster updates so newly-joined members get scanned without
-- waiting POLL_INTERVAL.
local f = CreateFrame("Frame", "GOBIGnINTERRUPT_NativeFiltersFrame")
f:RegisterUnitEvent("UNIT_AURA",
    "player", "party1", "party2", "party3", "party4")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function(_, event, unit)
    if not engineOn() then return end
    if event == "UNIT_AURA" then
        if type(unit) ~= "string" then return end
        if unit == "player" or unit:match("^party[1-4]$") then
            pcall(scanUnit, unit)
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        scanAll()
    end
end)

-- Manual scan exposed for slash diag (/gbi native scan).
function M.ScanAll() scanAll() end
