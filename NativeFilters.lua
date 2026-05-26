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
-- Returns (unit, trusted). `trusted` is true only when aura.sourceUnit was a
-- real party token — i.e. Blizzard told us who cast it. When false, we fall
-- back to the scanned unit (good enough for self-buffs) but the spillover
-- resolver must NOT treat that fallback as proof of a distinct caster.
local function attributionUnit(aura, scannedUnit)
    local okSrc, src = pcall(function() return aura.sourceUnit end)
    if okSrc and type(src) == "string"
        and (src == "player" or K.PARTY_UNITS_SET[src]) then
        return src, true
    end
    return scannedUnit, false
end

-- ---------------------------------------------------------------------------
-- P4: disambiguation when the aura's spell ID is redacted.
--
-- GetUnitAuras usually returns clean spell IDs, but for some remote-PC
-- party auras in 12.0.5 aura.spellId is tagged and SafeSpellID returns nil.
-- Rather than drop the detection, we narrow by (class, spec, Blizzard
-- filter category): if exactly one DB spell for that unit could be in the
-- category that returned this aura, it must be that spell.
--
-- We classify our OWN DB spells once at first use, with their clean local
-- spell IDs (no taint), via the same Blizzard predicates MiniCC/IT use:
--   C_UnitAuras.AuraIsBigDefensive(spellID) -> BIG_DEFENSIVE
--   C_Spell.IsSpellImportant(spellID)       -> IMPORTANT
-- (EXTERNAL_DEFENSIVE has no clean predicate; those auras almost always
--  carry a clean spell ID anyway since they're cast by a visible peer, so
--  the clean path handles them.)
-- ---------------------------------------------------------------------------

local candidateIndex   -- [classToken][filterTag] = { spellID, ... }

local function buildCandidateIndex()
    local idx = {}
    local entries = GBI.IterCooldowns and GBI.IterCooldowns() or GBI.Cooldowns or {}
    for sid, cd in pairs(entries) do
        if cd and cd.class then
            local function add(tag)
                idx[cd.class] = idx[cd.class] or {}
                idx[cd.class][tag] = idx[cd.class][tag] or {}
                table.insert(idx[cd.class][tag], sid)
            end
            local okBD, isBD = pcall(C_UnitAuras.AuraIsBigDefensive, sid)
            if okBD and isBD then add("BIG_DEFENSIVE") end
            local okI, isI = pcall(function() return C_Spell.IsSpellImportant(sid) end)
            if okI and isI then add("IMPORTANT") end
        end
    end
    return idx
end

-- Returns the unit's spec as the GetSpecialization() 1..4 index, matching
-- the cd.spec values in Data_Cooldowns (NOT the global spec ID). Player uses
-- GetSpecialization() directly; party uses Inspect.GetSpecByGUID (which also
-- stores the 1..4 index). Mirrors Evidence.lua's unitSpec.
local function unitSpec(unit)
    if unit == "player" then
        return GetSpecialization and GetSpecialization() or nil
    end
    local guid = GBI.Taint and GBI.Taint.SafeGUID and GBI.Taint.SafeGUID(unit) or nil
    return guid and GBI.Inspect and GBI.Inspect.GetSpecByGUID
        and GBI.Inspect.GetSpecByGUID(guid) or nil
end

-- Given a unit and the Blizzard filter category that returned a tagged
-- aura, return the unique candidate spell ID — or nil if zero / ambiguous.
local function disambiguate(unit, filterTag)
    if not candidateIndex then candidateIndex = buildCandidateIndex() end
    local _, classToken = UnitClass(unit)
    if not classToken then return nil end
    local list = candidateIndex[classToken] and candidateIndex[classToken][filterTag]
    if not list or #list == 0 then return nil end
    local specID = unitSpec(unit)
    local matches = {}
    for _, sid in ipairs(list) do
        local cd = GBI.GetCooldown(sid)
        if cd then
            if cd.spec and specID then
                for _, s in ipairs(cd.spec) do
                    if s == specID then matches[#matches + 1] = sid; break end
                end
            elseif not cd.spec then
                matches[#matches + 1] = sid
            end
        end
    end
    if #matches == 1 then return matches[1] end
    return nil   -- zero or ambiguous: don't guess
end

-- Commit a single confirmed detection to Brain. Extracted from the old
-- processAura so both the normal path and the spillover-resolved path
-- share one code path.
local function commit(attribUnit, spellID, cd, aura)
    if not attribUnit or not spellID or not cd then return end

    -- Class match: cd.class is the caster's class; verify against
    -- attribUnit. classToken nil (transient inspect race) -> permissive.
    if cd.class then
        local _, classToken = UnitClass(attribUnit)
        if classToken and cd.class ~= classToken then return end
    end

    -- Skip if Brain already has a fresh entry for this (unit, spell).
    local existing = GBI.Brain and GBI.Brain.GetState
        and GBI.Brain.GetState(attribUnit, spellID)
    if existing and existing.endsAt and existing.endsAt > GetTime() + 1 then
        return
    end

    local castedAt = castedAtFromAura(aura)
    log("Debug", "native-detect %d on %s castedAt=%s",
        spellID, attribUnit, tostring(castedAt))
    if GBI.Brain and GBI.Brain.OnCast then
        GBI.Brain.OnCast(attribUnit, spellID, cd, nil, castedAt)
    end
end

-- Same spell appearing on >= this many distinct party members in one scan
-- is treated as an AoE / spillover event (Berserker Roar group buff,
-- Grounding Totem spillover, encounter-wide IMPORTANT auras) rather than
-- that many independent casts.
local SPILLOVER_MIN_UNITS = 3

-- Single scan pass over the whole party, collect-then-decide so we can
-- recognize AoE spillover (P2). Two phases:
--   1. Collect every filtered aura whose spellID is in our DB, grouped by
--      spellID, recording (recipient unit, attributed source, aura).
--   2. Per spell: if it landed on >= SPILLOVER_MIN_UNITS recipients it's a
--      group/AoE effect — credit only the single consistent source (the
--      caster also receives their own buff), or suppress entirely when the
--      source is ambiguous. Otherwise credit each hit normally (Brain's
--      250ms dedup collapses same-source duplicates).
local function scanAll()
    local candidates = {}   -- spellID -> { { recipient, source, aura, cd }, ... }
    for _, unit in ipairs(K.PARTY_UNITS) do
        if UnitExists(unit) then
            for _, filter in ipairs(FILTERS) do
                local filterTag = filter:match("|([%w_]+)$")   -- e.g. BIG_DEFENSIVE (note underscore)
                local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, filter)
                if ok and type(auras) == "table" then
                    for _, aura in ipairs(auras) do
                        local okId, rawId = pcall(function() return aura.spellId end)
                        local spellID = okId and rawId and GBI.Taint and GBI.Taint.SafeSpellID
                            and GBI.Taint.SafeSpellID(rawId) or nil
                        -- P4: spell ID redacted -> narrow by class+spec+category.
                        if not spellID and filterTag then
                            spellID = disambiguate(unit, filterTag)
                            if spellID then
                                log("Debug", "disambiguated tagged %s aura on %s -> %d",
                                    filterTag, unit, spellID)
                            end
                        end
                        local cd = spellID and GBI.GetCooldown(spellID) or nil
                        if cd then
                            local src, trusted = attributionUnit(aura, unit)
                            candidates[spellID] = candidates[spellID] or {}
                            table.insert(candidates[spellID],
                                { recipient = unit, source = src,
                                  trusted = trusted, aura = aura, cd = cd })
                        end
                    end
                end
            end
        end
    end

    for spellID, hits in pairs(candidates) do
        local distinctRecipients = {}
        for _, h in ipairs(hits) do distinctRecipients[h.recipient] = true end
        local recipientCount = 0
        for _ in pairs(distinctRecipients) do recipientCount = recipientCount + 1 end

        if recipientCount >= SPILLOVER_MIN_UNITS then
            -- This spell is active on many units. Resolve using only
            -- TRUSTED sources (aura.sourceUnit was a real party token).
            -- Each distinct trusted source = one genuine cast:
            --   * 1 trusted source  -> a group buff (Berserker Roar): the
            --     other recipients are spillover; credit the caster once.
            --   * N trusted sources -> N independent casters happened to
            --     have the same buff up (3 Paladins on Avenging Wrath);
            --     credit each — NOT a spillover, don't drop them.
            --   * 0 trusted sources -> unattributable AoE (encounter buff,
            --     or fallback-only data); suppress.
            local trustedHit = {}   -- source -> a representative hit
            for _, h in ipairs(hits) do
                if h.trusted and not trustedHit[h.source] then
                    trustedHit[h.source] = h
                end
            end
            local n = 0
            for src, h in pairs(trustedHit) do
                n = n + 1
                commit(src, spellID, h.cd, h.aura)
            end
            if n == 0 then
                log("Debug", "spillover %d on %d units, no trusted source -> suppress",
                    spellID, recipientCount)
            else
                log("Debug", "spillover %d on %d units -> credited %d trusted source(s)",
                    spellID, recipientCount, n)
            end
        else
            for _, h in ipairs(hits) do
                commit(h.source, spellID, h.cd, h.aura)
            end
        end
    end
end

-- Coalesced scan: many UNIT_AURA events fire in a burst when an AoE buff
-- lands on the whole party. Debounce them into a single spillover-aware
-- scanAll 0.1s later so the collect-then-decide pass sees all units at once.
local scanPending = false
local function requestScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(0.1, function()
        scanPending = false
        if engineOn() then scanAll() end
    end)
end

-- Periodic poll: backstop in case UNIT_AURA event delivery is missed.
local poller = CreateFrame("Frame", "GOBIGnINTERRUPT_NativeFiltersPoller")
poller:SetScript("OnUpdate", function(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < POLL_INTERVAL then return end
    self.acc = 0
    if not engineOn() then return end
    scanAll()
end)

-- Event-driven: any party aura change requests a debounced scan.
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
            requestScan()
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        requestScan()
    end
end)

-- Manual scan exposed for slash diag (/gbi native scan).
function M.ScanAll() scanAll() end
