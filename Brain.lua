-- Central CD state for the party. Receives casts (CastTracker / Evidence)
-- and emits to Bar + SoundPipeline.
--
-- Sound semantics (after v0.2):
--   * cd_cast trigger is gone. We don't ping when something fires.
--   * cd_ready fires ONCE when every spell in GOBIGnINTERRUPTDB.allReadyList
--     is simultaneously off cooldown (i.e. inFlight count == 0 for each).
--     Latches: stays silent until at least one of them goes on CD again.
--
-- Public API:
--   GBI.Brain.OnCast(unit, spellID, cdEntry)
--   GBI.Brain.GetState(unit, spellID)
--   GBI.Brain.IterUnitState(unit)
--   GBI.Brain.Reset()
--   GBI.Brain.IsSpellInAllReadyList(spellID)
--   GBI.Brain.GetInFlight(spellID) -> count of party members currently on CD

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.Brain = GBI.Brain or {}
local M = GBI.Brain

local DEDUP = K.BRAIN_DEDUP_S

local state    = {}     -- state[unit][spellID] = { startedAt, endsAt, cdEntry }
local recent   = {}     -- recent[unit][spellID] = lastSeenAt (dedup)
local inFlight = {}     -- spellID -> # of units currently in their CD window
local seenBig  = {}     -- spellID -> true for any K.CAT_BIGCD observed this run
                        --   (basis of the "auto" burst-ready trigger source)

-- Latch starts TRUE so we don't fire on first load (no transition yet);
-- becomes false when a list-spell goes on CD; becomes true again only when
-- we observe all of them simultaneously off CD.
local allReadyLatch = true

-- Burst-window quality gates. We refuse to fire cd_ready when the supposed
-- "burst" was trivial (one spell observed, peak overlap of 1, or fired
-- immediately after the latch broke).
local BURST_MIN_SET    = 3        -- effective set must have >= N entries
local BURST_MIN_PEAK   = 2        -- at least N tracked spells must have been
                                  -- on cooldown simultaneously during the burst
local BURST_GUARD_S    = 30       -- latch must have been false for >= N seconds
local burstStartAt     = nil      -- GetTime() when latch flipped false
local burstPeakInFlight = 0       -- max overlap during current burst window

local function log(level, ...) if GBI.Log then GBI.Log[level]("brain", ...) end end

-- Effective burst-ready spell set, based on db.burst.mode:
--   "auto"   - every K.CAT_BIGCD spell observed casting in this run (default)
--   "manual" - only the user-curated GOBIGnINTERRUPTDB.allReadyList
--   "both"   - union of the two
local function burstMode()
    local b = GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.burst
    return (b and b.mode) or "auto"
end

local function effectiveSet()
    local out = {}
    local mode = burstMode()
    if mode == "manual" or mode == "both" then
        for _, sid in ipairs((GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.allReadyList) or {}) do
            out[sid] = true
        end
    end
    if mode == "auto" or mode == "both" then
        for sid in pairs(seenBig) do out[sid] = true end
    end
    return out
end

local function getList()
    -- Back-compat: return an array view of the effective set so existing
    -- callers that iterate or count #list still work.
    local set = effectiveSet()
    local arr = {}
    for sid in pairs(set) do arr[#arr+1] = sid end
    return arr
end

function M.IsSpellInAllReadyList(spellID)
    return effectiveSet()[spellID] == true
end

function M.GetInFlight(spellID) return inFlight[spellID] or 0 end

local function allReady()
    local set = effectiveSet()
    local empty = true
    for sid in pairs(set) do
        empty = false
        if (inFlight[sid] or 0) > 0 then return false end
    end
    if empty then return false end
    return true
end

local function fireAllReady(triggerSpell)
    if GBI.SoundPipeline and GBI.SoundPipeline.Fire then
        GBI.SoundPipeline.Fire(K.SOUND_CAT_CD_READY,
            { reason = "all-ready", spellID = triggerSpell })
    end
    if GBI.Bar and GBI.Bar.OnAllReady then GBI.Bar.OnAllReady() end
end

function M.OnCast(unit, spellID, cdEntry)
    if not unit or not spellID or not cdEntry then return end
    local now = GetTime()

    -- per-(unit,spell) dedup
    recent[unit] = recent[unit] or {}
    local last = recent[unit][spellID]
    if last and (now - last) < DEDUP then return end
    recent[unit][spellID] = now

    -- record CD state
    state[unit] = state[unit] or {}
    state[unit][spellID] = {
        startedAt = now,
        endsAt    = now + (cdEntry.duration or 30),
        cdEntry   = cdEntry,
    }

    -- bump in-flight counter for this spell
    inFlight[spellID] = (inFlight[spellID] or 0) + 1

    -- Auto-source for burst-ready trigger: any BIGCD we ever see goes into
    -- the seen set. Members of the set must all be simultaneously ready
    -- before the cd_ready sound can fire again.
    if cdEntry.category == K.CAT_BIGCD then seenBig[spellID] = true end

    log("Debug", "CD_START unit=%s spell=%d ends=%.1f inFlight=%d",
        unit, spellID, state[unit][spellID].endsAt, inFlight[spellID])

    -- If this spell is in the all-ready list, the burst window is now broken
    if M.IsSpellInAllReadyList(spellID) and allReadyLatch then
        allReadyLatch = false
        burstStartAt  = now
        burstPeakInFlight = 0
        log("Debug", "all-ready latch -> false (spell %d went active)", spellID)
    end

    -- Track peak simultaneous-on-CD count across tracked spells (B).
    if M.IsSpellInAllReadyList(spellID) then
        local sum = 0
        for sid in pairs(effectiveSet()) do
            sum = sum + (inFlight[sid] or 0)
        end
        if sum > burstPeakInFlight then burstPeakInFlight = sum end
    end

    -- emit start to bar (cd_cast SoundPipeline.Fire intentionally removed)
    if GBI.Bar and GBI.Bar.OnCDStart then
        GBI.Bar.OnCDStart(unit, spellID, state[unit][spellID])
    end

    -- schedule the end-of-cooldown event
    local duration = cdEntry.duration or 30
    local sid      = spellID
    local u        = unit
    local endsAt   = state[unit][spellID].endsAt

    C_Timer.After(duration, function()
        local s = state[u] and state[u][sid]
        if not s then return end
        -- guard against re-cast: if endsAt drifted, this isn't the same
        -- timer's owner anymore.
        if math.abs(s.endsAt - endsAt) > 0.5 then return end

        -- decrement in-flight
        inFlight[sid] = math.max(0, (inFlight[sid] or 1) - 1)

        log("Debug", "CD_READY unit=%s spell=%d inFlight=%d", u, sid, inFlight[sid])
        if GBI.Bar and GBI.Bar.OnCDReady then GBI.Bar.OnCDReady(u, sid, s) end

        -- only re-arm + fire if this spell is in the list, and the entire
        -- list is now ready, and we previously broke the latch.
        if (not allReadyLatch) and M.IsSpellInAllReadyList(sid) and allReady() then
            local set = effectiveSet()
            local setSize = 0
            for _ in pairs(set) do setSize = setSize + 1 end
            local elapsed = burstStartAt and (GetTime() - burstStartAt) or 0
            local pass = setSize >= BURST_MIN_SET
                     and burstPeakInFlight >= BURST_MIN_PEAK
                     and elapsed >= BURST_GUARD_S
            if pass then
                allReadyLatch = true
                log("Info", "ALL READY  set=%d peak=%d elapsed=%.1fs (last: %d)",
                    setSize, burstPeakInFlight, elapsed, sid)
                fireAllReady(sid)
            else
                allReadyLatch = true       -- still re-arm latch, just no fire
                log("Debug", "all-ready GATE-FAIL set=%d peak=%d elapsed=%.1fs " ..
                    "(min set=%d peak=%d guard=%ds) - skipping fire",
                    setSize, burstPeakInFlight, elapsed,
                    BURST_MIN_SET, BURST_MIN_PEAK, BURST_GUARD_S)
            end
            burstStartAt = nil
            burstPeakInFlight = 0
        end
    end)
end

function M.GetState(unit, spellID)
    if not state[unit] then return nil end
    return state[unit][spellID]
end

function M.IterUnitState(unit) return pairs(state[unit] or {}) end

function M.Reset()
    state          = {}
    recent         = {}
    inFlight       = {}
    seenBig        = {}
    allReadyLatch  = true
    burstStartAt   = nil
    burstPeakInFlight = 0
    if GBI.Bar and GBI.Bar.Reset then GBI.Bar.Reset() end
    log("Info", "state reset")
end
