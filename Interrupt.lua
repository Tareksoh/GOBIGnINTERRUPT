-- Interrupt-pull alert.
--
-- When an enemy mob (target/focus/nameplate/boss/arena) starts a castable
-- spell AND your interrupt is off cooldown, schedule a sound to fire
-- `seconds` after cast start (default 0.2 s). Cancel/respawn on cast
-- stop/interrupt/success or pushback for the same castGUID.
--
-- Why a fixed delay rather than half-of-cast-time?
--   In WoW Midnight 12.0.5 every value reachable from a hostile-unit event
--   handler is "secret-tagged" - including UnitCastingInfo's startMS/endMS
--   and the spellID from the event payload. Every laundering path
--   (tonumber(tostring(secret)), string.match on a secret GUID, etc.) fails.
--   Computing a duration-based threshold therefore can't be done robustly.
--   Fixed delay sidesteps all of that.
--
-- Public API:
--   GBI.Interrupt.SetEnabled(bool)
--   GBI.Interrupt.GetThreshold() -> { enabled, mode, ratio, seconds }
--
-- SavedVariables:
--   GOBIGnINTERRUPTDB.interrupt = {
--       enabled = true,
--       seconds = 0.2,                 -- delay from cast start to alert
--   }

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.Interrupt = GBI.Interrupt or {}
local M = GBI.Interrupt

local function log(level, ...) if GBI.Log then GBI.Log[level]("interrupt", ...) end end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local function ensureCfg()
    GOBIGnINTERRUPTDB = GOBIGnINTERRUPTDB or {}
    GOBIGnINTERRUPTDB.interrupt = GOBIGnINTERRUPTDB.interrupt or {}
    local c = GOBIGnINTERRUPTDB.interrupt
    if c.enabled == nil then c.enabled = true end
    c.seconds = c.seconds or 0.2
    -- Stale schema fields cleared (mode/ratio were never read at runtime).
    c.mode  = nil
    c.ratio = nil
    return c
end

function M.GetThreshold() return ensureCfg() end

function M.SetEnabled(on)
    ensureCfg().enabled = on and true or false
end

-- ---------------------------------------------------------------------------
-- Taint helpers
-- ---------------------------------------------------------------------------
-- castGUID strings on hostile units in 12.0.5 are secret-tagged: any
-- table-key op throws "attempted to index a table that cannot be indexed
-- with secret keys", and == compare throws "attempt to compare secret
-- string". laundered_bool's tostring -> string-equality also has a hidden
-- secret-string layer that needs its own pcall.

local function safeEq(a, b)
    if a == nil or b == nil then return a == b end
    local ok, eq = pcall(function() return a == b end)
    return ok and eq or false
end

local function laundered_bool(b)
    if b == nil then return false end
    local strOK, s = pcall(tostring, b)
    if not strOK then return false end
    local cmpOK, eq = pcall(function() return s == "true" end)
    return cmpOK and eq or false
end

-- ---------------------------------------------------------------------------
-- Player interrupt readiness
-- ---------------------------------------------------------------------------
-- Read from Brain's stored state (plain Lua numbers) instead of calling
-- C_Spell.GetSpellCooldown - the latter returns secret-tagged values when
-- our code path is already tainted by a hostile-unit event.

local function playerInterruptReady()
    local id = GBI.Interrupts and GBI.Interrupts.ForPlayer and GBI.Interrupts.ForPlayer()
    if not id then return false end
    if not (GBI.Brain and GBI.Brain.GetState) then return true end

    local s = GBI.Brain.GetState("player", id)
    if not s or not s.endsAt then return true end
    return s.endsAt <= GetTime()
end

-- ---------------------------------------------------------------------------
-- Per-cast tracking
-- ---------------------------------------------------------------------------
-- active[unit] = { castGUID = "...", timer = <C_Timer.NewTimer obj> }
local active = {}

-- Time-window dedup. UNIT_SPELLCAST_START fires on multiple unit tokens
-- (nameplateN + target + softenemy etc.) within microseconds for the same
-- real cast. We can't dedup by castGUID under taint, so we treat any
-- schedule within 100ms of the previous one as the same cast.
local lastScheduleAt = 0
local SAME_CAST_WINDOW = 0.10

-- Engine gate: the interrupt-halfway alert should only fire in the tracked
-- context (M+ / showAlways), not in raids / open world / when disabled.
local function engineOn()
    return GBI.Bar and GBI.Bar.IsEngineEnabled and GBI.Bar.IsEngineEnabled() or false
end

local function isCandidateUnit(unit)
    if not unit then return false end
    if unit == "player" or unit == "pet" then return false end
    if unit:match("^party%d$") then return false end
    if unit:match("^partypet%d$") then return false end
    if unit:match("^raid%d+$") then return false end
    if UnitIsFriend("player", unit) then return false end
    return UnitExists(unit)
end

local function cancelFor(unit)
    local a = active[unit]
    if not a then return end
    if a.timer and a.timer.Cancel then a.timer:Cancel() end
    active[unit] = nil
end

-- ---------------------------------------------------------------------------
-- Fire
-- ---------------------------------------------------------------------------

local function fireIfStillValid(unit, castGUID, spellID)
    local a = active[unit]
    if not a or not safeEq(a.castGUID, castGUID) then return end
    active[unit] = nil

    if not engineOn() then return end   -- engine turned off after scheduling

    if not playerInterruptReady() then
        log("Debug", "fire skip %s: kick on CD at trigger", unit); return
    end

    log("Info", "ALERT %s (spellID=%s)", unit, tostring(spellID))
    if GBI.SoundPipeline and GBI.SoundPipeline.Fire then
        GBI.SoundPipeline.Fire(K.SOUND_CAT_INTERRUPT_ALERT, { unit = unit, spellID = spellID })
    end
end

-- ---------------------------------------------------------------------------
-- Schedule
-- ---------------------------------------------------------------------------

-- Probe UnitCastingInfo's notInterruptible. Returns true if the cast is
-- explicitly NOT interruptible. Tagged-boolean safe.
-- UnitCastingInfo returns:
--   name, displayedName, icon, startTimeMS, endTimeMS, isTradeskill,
--   castID, notInterruptible, spellID, isEmpowered, numEmpowerStages
-- We need return #8.
local function castIsNotInterruptible(unit)
    local ok, notInt = pcall(function()
        local _, _, _, _, _, _, _, n = UnitCastingInfo(unit)
        return n
    end)
    if not ok or notInt == nil then
        ok, notInt = pcall(function()
            local _, _, _, _, _, _, _, n = UnitChannelInfo(unit)
            return n
        end)
    end
    if not ok or notInt == nil then return false end
    return laundered_bool(notInt)
end

local function onStart_inner(unit, castGUID, eventSpellID)
    -- Same-cast multi-token dedup
    if (GetTime() - lastScheduleAt) < SAME_CAST_WINDOW then return end
    if not engineOn() then return end   -- no interrupt alerts outside M+/showAlways
    if not ensureCfg().enabled then return end
    if not isCandidateUnit(unit) then return end

    -- Skip if Blizzard says this cast can't be interrupted (boss-only cast,
    -- channel without interrupt flag, etc.). Tag-safe boolean check.
    if castIsNotInterruptible(unit) then
        log("Debug", "skip %s: cast not interruptible", unit)
        return
    end

    -- Player kick must be off CD; read Brain's clean state, not the API.
    local readyOK, ready = pcall(playerInterruptReady)
    if not readyOK or not ready then
        log("Debug", "skip %s: kick on CD", unit)
        return
    end

    local delay = ensureCfg().seconds or 0.2

    cancelFor(unit)
    local timerOK, timer = pcall(C_Timer.NewTimer, delay, function()
        fireIfStillValid(unit, castGUID, eventSpellID)
    end)
    if not timerOK then return end
    active[unit] = { castGUID = castGUID, timer = timer }
    lastScheduleAt = GetTime()
    log("Debug", "scheduled %s in %.2fs (spellID=%s)",
        unit, delay, tostring(eventSpellID))
end

local function onStart(unit, castGUID, eventSpellID)
    pcall(onStart_inner, unit, castGUID, eventSpellID)
end

local function onEnd(unit, castGUID)
    local a = active[unit]
    if a and safeEq(a.castGUID, castGUID) then
        cancelFor(unit)
    end
end

local function onDelayed(unit, castGUID, eventSpellID)
    local a = active[unit]
    if not a or not safeEq(a.castGUID, castGUID) then return end
    cancelFor(unit)
    onStart(unit, castGUID, eventSpellID)
end

-- ---------------------------------------------------------------------------
-- Event handler
-- ---------------------------------------------------------------------------

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_InterruptFrame")
f:RegisterEvent("UNIT_SPELLCAST_START")
f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
f:RegisterEvent("UNIT_SPELLCAST_DELAYED")
f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTIBLE")
f:RegisterEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE")
f:RegisterEvent("UNIT_SPELLCAST_STOP")
f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

f:SetScript("OnEvent", function(_, event, unit, castGUID, spellID)
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        onStart(unit, castGUID, spellID)
    elseif event == "UNIT_SPELLCAST_DELAYED" then
        onDelayed(unit, castGUID, spellID)
    elseif event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        onEnd(unit, castGUID)
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" then
        if not active[unit] then onStart(unit, castGUID, spellID) end
    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_SUCCEEDED" then
        onEnd(unit, castGUID)
    end
end)
