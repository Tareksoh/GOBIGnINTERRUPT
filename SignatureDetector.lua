-- Signature-based detection for cooldowns that produce no trackable aura
-- (the "Class D" gap) or whose UNIT_SPELLCAST_* spell ID is 12.0.5-redacted
-- for remote party members.
--
-- Inspired by MiniCC's Modules/Cooldowns/SignatureDetector.lua. The idea:
-- even when a spell leaves no buff and its cast spell ID is tagged, the
-- *side-effect events* still fire. We correlate them against known rules.
--
-- Two signature types implemented:
--
--   CHANNEL — channeled cooldowns fire UNIT_SPELLCAST_CHANNEL_START then
--             _STOP. We try to launder the spell ID from START; if clean
--             and in our DB, commit directly. If tagged, match the measured
--             channel duration against CHANNEL_RULES for the caster's class.
--
--   BATCH   — a set of cosmetic events (UNIT_FLAGS, UNIT_MODEL_CHANGED,
--             UNIT_PORTRAIT_UPDATE) that co-occur within a short window when
--             certain transformation cooldowns fire. Seeded conservatively;
--             extend BATCH_RULES after in-game verification.
--
-- NOTE: this detector assumes the channel/cosmetic events still fire for
-- remote party members in 12.0.5 even when the spell ID is redacted. That
-- matches MiniCC's design, but it must be confirmed in a live group — if
-- the events are fully suppressed for remote PCs, these rules are inert
-- (they simply never fire) and can be removed.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.SignatureDetector = GBI.SignatureDetector or {}
local M = GBI.SignatureDetector

local function log(level, ...) if GBI.Log then GBI.Log[level]("signature", ...) end end

local function engineOn()
    return GBI.Bar and GBI.Bar.IsEngineEnabled and GBI.Bar.IsEngineEnabled() or false
end

-- Commit a signature-inferred cast. `castedAt` (optional) back-dates the
-- cooldown start: a channeled CD's cooldown begins when the channel STARTS,
-- not when it stops, so we pass the channel-start time. Without it Convoke
-- would show ~one channel length too much remaining. BATCH signatures fire
-- at cast time, so they pass nil (= now).
local function tryCommit(unit, spellID, reason, castedAt)
    local cd = spellID and GBI.GetCooldown(spellID)
    if not cd then return false end
    if cd.class then
        local _, classToken = UnitClass(unit)
        if classToken and cd.class ~= classToken then return false end
    end
    -- Don't stomp a fresher detection from another path.
    local existing = GBI.Brain and GBI.Brain.GetState
        and GBI.Brain.GetState(unit, spellID)
    if existing and existing.endsAt and existing.endsAt > GetTime() + 1 then
        return false
    end
    log("Debug", "signature-detect %d on %s (%s) castedAt=%s",
        spellID, unit, reason or "?", tostring(castedAt))
    if GBI.Brain and GBI.Brain.OnCast then
        GBI.Brain.OnCast(unit, spellID, cd, nil, castedAt)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- CHANNEL signatures
-- ---------------------------------------------------------------------------

-- spells recognizable by channel duration when the spell ID is redacted.
-- Only spells that (a) are channeled and (b) exist in Data_Cooldowns.
local CHANNEL_RULES = {
    -- Druid Convoke the Spirits: ~3.5s channel.
    { spellID = 391528, class = "DRUID", duration = 3.5, tol = 1.2 },
}

local channelStart = {}   -- [unit] = { t = startTime, spellID = laundered|nil }

local function onChannelStart(unit, _castGUID, rawSpellID)
    local spellID = GBI.Taint and GBI.Taint.SafeSpellID
        and GBI.Taint.SafeSpellID(rawSpellID) or nil
    channelStart[unit] = { t = GetTime(), spellID = spellID }
end

local function onChannelStop(unit)
    local rec = channelStart[unit]
    channelStart[unit] = nil
    if not rec then return end
    local dur = GetTime() - rec.t
    -- Path 1: clean spell ID straight from the START event. Back-date the
    -- cooldown to the channel start (rec.t).
    if rec.spellID and tryCommit(unit, rec.spellID, "channel-id", rec.t) then return end
    -- Path 2: match channel duration against rules for the caster's class.
    local _, classToken = UnitClass(unit)
    for _, rule in ipairs(CHANNEL_RULES) do
        if (not rule.class or rule.class == classToken)
           and math.abs(dur - rule.duration) <= (rule.tol or 1.0) then
            tryCommit(unit, rule.spellID, "channel-dur", rec.t)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- BATCH signatures — cosmetic events that co-occur on cast.
-- Seeded empty; the framework is here so rules can be added once verified
-- in a live group. Each rule: { spellID, class, events = { ev=true, ... },
-- window = seconds }. A batch commits when every required event for a unit
-- arrives within `window` of the first.
-- ---------------------------------------------------------------------------

local BATCH_RULES = {
    -- (none yet — add after confirming which transformation CDs fire a
    --  reliable UNIT_FLAGS/UNIT_MODEL_CHANGED/UNIT_PORTRAIT_UPDATE batch
    --  for remote party members in 12.0.5)
}

local BATCH_WINDOW = 0.5
local batchSeen = {}   -- [unit][event] = time

local function onBatchEvent(unit, event)
    if #BATCH_RULES == 0 then return end
    batchSeen[unit] = batchSeen[unit] or {}
    batchSeen[unit][event] = GetTime()
    local now = GetTime()
    local _, classToken = UnitClass(unit)
    for _, rule in ipairs(BATCH_RULES) do
        if not rule.class or rule.class == classToken then
            local complete = true
            for ev in pairs(rule.events) do
                local t = batchSeen[unit][ev]
                if not t or (now - t) > (rule.window or BATCH_WINDOW) then
                    complete = false
                    break
                end
            end
            if complete then
                if tryCommit(unit, rule.spellID, "batch") then
                    batchSeen[unit] = {}   -- consume
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_SignatureFrame")
f:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START",
    "party1", "party2", "party3", "party4")
f:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP",
    "party1", "party2", "party3", "party4")
-- BATCH events only registered if we have rules using them, to avoid the
-- overhead of high-frequency UNIT_FLAGS churn when nothing consumes it.
if #BATCH_RULES > 0 then
    f:RegisterUnitEvent("UNIT_FLAGS",          "party1", "party2", "party3", "party4")
    f:RegisterUnitEvent("UNIT_MODEL_CHANGED",  "party1", "party2", "party3", "party4")
    f:RegisterUnitEvent("UNIT_PORTRAIT_UPDATE","party1", "party2", "party3", "party4")
end
f:SetScript("OnEvent", function(_, event, unit, castGUID, rawSpellID)
    if not engineOn() then return end
    if type(unit) ~= "string" or not unit:match("^party[1-4]$") then return end
    if event == "UNIT_SPELLCAST_CHANNEL_START" then
        onChannelStart(unit, castGUID, rawSpellID)
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        onChannelStop(unit)
    else
        onBatchEvent(unit, event)
    end
end)
