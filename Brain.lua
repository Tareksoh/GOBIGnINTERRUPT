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

-- Only OFFENSIVE big-CD spells qualify for the burst-ready trigger.
-- Defensives, dispels, utility never count toward "all-ready burst".
local function isOffensiveCD(sid)
    local cd = GBI.GetCooldown and GBI.GetCooldown(sid)
    return cd and (cd.category == K.CAT_BIGCD or cd.category == K.CAT_OFFENSIVE)
end

local function effectiveSet()
    local out = {}
    local mode = burstMode()
    if mode == "manual" or mode == "both" then
        for _, sid in ipairs((GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.allReadyList) or {}) do
            if isOffensiveCD(sid) then out[sid] = true end
        end
    end
    if mode == "auto" or mode == "both" then
        for sid in pairs(seenBig) do
            if isOffensiveCD(sid) then out[sid] = true end
        end
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
end

-- (Re)schedule the end-of-cooldown event for an active (unit, spell).
-- `capturedEndsAt` is the timer's ownership token: if state.endsAt later
-- moves (a re-cast, or a peer "D" delta shortening the CD), the stale timer
-- sees the mismatch and bails, while whoever moved endsAt schedules a fresh
-- timer via this same function. This keeps inFlight / OnCDReady / the
-- all-ready latch firing at the correct (possibly updated) time.
local function scheduleReady(u, sid, capturedEndsAt)
    local remaining = math.max(0.1, capturedEndsAt - GetTime())
    C_Timer.After(remaining, function()
        local s = state[u] and state[u][sid]
        if not s then return end
        -- >= 0.5 (not > 0.5) so the boundary matches UpdateRemaining /
        -- pollPlayerDynamic, which reschedule when the move is >= 0.5s. At
        -- exactly 0.5 the stale timer must bail so only the fresh one fires.
        if type(s.endsAt) ~= "number" or math.abs(s.endsAt - capturedEndsAt) >= 0.5 then
            return  -- endsAt moved; a newer timer owns the decrement
        end
        inFlight[sid] = math.max(0, (inFlight[sid] or 1) - 1)
        log("Debug", "CD_READY unit=%s spell=%d inFlight=%d", u, sid, inFlight[sid])
        if GBI.Bar and GBI.Bar.OnCDReady then GBI.Bar.OnCDReady(u, sid, s) end

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

-- overrideDuration: when set (peer-comm path), use the sender's already-
-- adjusted duration verbatim instead of running TalentSync.AdjustCD again.
-- The sender already applied their own talent CDR.
--
-- castedAt: when set (Evidence aura path), back-date startedAt to the
-- moment the cast actually happened (aura.expirationTime - aura.duration)
-- so the remaining-CD shown for non-addon peers reflects the real timer
-- instead of "full duration from when we first noticed". Only honored on
-- non-peer paths and clamped to within the spell's effective duration.
function M.OnCast(unit, spellID, cdEntry, overrideDuration, castedAt)
    if not unit or not spellID or not cdEntry then return end
    if cdEntry.stackingResource then
        M.FlashCast(unit, spellID)
        return
    end
    local now = GetTime()
    local fromPeer = overrideDuration ~= nil

    -- Peer-priority: once a peer (with their actual talented duration) has
    -- reported a cast, ignore local detections for the next 5s. They'd just
    -- overwrite endsAt with our base/guess duration.
    if not fromPeer then
        local existing = state[unit] and state[unit][spellID]
        if existing and existing.fromPeer and existing.startedAt
            and (now - existing.startedAt) < 5 then return end
    end

    -- per-(unit,spell) dedup
    recent[unit] = recent[unit] or {}
    local last = recent[unit][spellID]
    if last and (now - last) < DEDUP then return end
    recent[unit][spellID] = now

    -- Duration: peer-comm path uses sender's reported value verbatim
    -- (already adjusted for their talents). Local detection paths apply
    -- TalentSync.AdjustCD fresh.
    local effDur
    if type(overrideDuration) == "number" and overrideDuration > 0 then
        effDur = overrideDuration
    else
        local baseDur = cdEntry.duration or 30
        effDur = baseDur
        if GBI.TalentSync and GBI.TalentSync.AdjustCD then
            effDur = GBI.TalentSync.AdjustCD(unit, spellID, baseDur) or baseDur
        end
    end

    -- Back-dated start: if Evidence inferred the actual cast time from an
    -- aura's expirationTime, accept it (clamped to within effDur of now) so
    -- the icon shows the true remaining time instead of full duration.
    -- Peer-comm path keeps `now` since the sender already reported `effDur`
    -- as remaining-from-now.
    local effStart = now
    if not fromPeer and type(castedAt) == "number"
        and castedAt > 0 and castedAt < now then
        local oldest = now - effDur
        if castedAt > oldest then effStart = castedAt end
    end

    -- record CD state. Capture whether an entry was already active first:
    -- a re-cast while the previous ready timer is still pending must NOT
    -- double-count inFlight, because the stale timer bails (endsAt moved)
    -- without decrementing. Only a fresh activation bumps the counter.
    state[unit] = state[unit] or {}
    local prev = state[unit][spellID]
    local wasActive = prev and type(prev.endsAt) == "number" and prev.endsAt > now
    state[unit][spellID] = {
        startedAt  = effStart,
        endsAt     = effStart + effDur,
        cdEntry    = cdEntry,
        charges    = cdEntry.charges,       -- nil for non-charged spells
        chargesMax = cdEntry.chargesMax,
        fromPeer   = fromPeer,              -- peer broadcast vs local detection
    }

    -- bump in-flight counter for this spell (only on a fresh activation)
    if not wasActive then
        inFlight[spellID] = (inFlight[spellID] or 0) + 1
    end

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

    -- Peer-share: broadcast our own casts so other PCs (where party
    -- UNIT_SPELLCAST is redacted) can show our CDs anyway. Include
    -- live charge counts when the spell uses charges.
    if unit == "player" and GBI.CDComm and GBI.CDComm.Broadcast then
        local ch, chMax
        if C_Spell and C_Spell.GetSpellCharges then
            local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
            if ok and type(info) == "table" then
                ch    = info.currentCharges
                chMax = info.maxCharges
                if ch and chMax and chMax > 1 then
                    state[unit][spellID].charges    = ch
                    state[unit][spellID].chargesMax = chMax
                end
            end
        end
        GBI.CDComm.Broadcast(spellID, effDur, ch, chMax)
    end

    -- schedule the end-of-cooldown event. scheduleReady uses (endsAt - now)
    -- so a back-dated Evidence cast fires on time, and it can be re-issued
    -- by UpdateRemaining when a peer delta shortens the CD.
    scheduleReady(unit, spellID, state[unit][spellID].endsAt)
end

function M.GetState(unit, spellID)
    if not state[unit] then return nil end
    return state[unit][spellID]
end

-- Returns the player's currently-active (endsAt > now) tracked CDs.
-- Used by CDComm to reply to a `Q` (query) message — late-joiners learn
-- about CDs already running before they joined.
function M.GetPlayerActiveCDs()
    local out = {}
    if not state.player then return out end
    local now = GetTime()
    for sid, s in pairs(state.player) do
        if s.endsAt and s.endsAt > now then
            out[sid] = s
        end
    end
    return out
end

-- Stacks for stack-resource spells. We synthesize a state entry so the
-- Bar/Overlay can render the icon (with a stack count overlay) even though
-- there's no traditional cooldown. endsAt is intentionally far in the
-- future so the icon stays visible; it un-fades to "ready" when the
-- threshold is reached.
-- Brief activation flash for stack-resource spells. Triggers a 2s extra
-- glow on the icon by re-stamping the existing state. Called when the
-- player or a peer actually casts the spell.
function M.FlashCast(unit, spellID)
    local s = state[unit] and state[unit][spellID]
    if not s then return end
    s.flashUntil = GetTime() + 2
    if GBI.Bar and GBI.Bar.OnCDStart then GBI.Bar.OnCDStart(unit, spellID, s) end
end

function M.SetStacks(unit, spellID, count, threshold)
    threshold = threshold or 1
    local cd = GBI.GetCooldown and GBI.GetCooldown(spellID)
    if not cd then return end
    state[unit] = state[unit] or {}
    local s = state[unit][spellID] or { startedAt = GetTime(), cdEntry = cd }
    -- Stack-resource spells don't have a CD - leave endsAt nil so the
    -- icon's CooldownFrameTemplate shows no swipe.
    s.endsAt         = nil
    s.stackCount     = count
    s.stackThreshold = threshold
    s.cdEntry        = cd
    state[unit][spellID] = s
    if GBI.Bar and GBI.Bar.OnCDStart then GBI.Bar.OnCDStart(unit, spellID, s) end
end

-- Inbound delta from a peer ("their CD now has X seconds left"). Adjusts
-- the existing entry's endsAt so the bar/overlay reflect the shorter time.
-- If we don't have an entry for this spell yet, ignore (the U should
-- arrive separately).
function M.UpdateRemaining(unit, spellID, remaining)
    if type(remaining) ~= "number" or remaining < 0 then return end
    local s = state[unit] and state[unit][spellID]
    if not s then return end
    -- Stack-resource entries (Brain.SetStacks) leave endsAt = nil; D deltas
    -- don't apply to them. Bail rather than crash on the math.abs below.
    if type(s.endsAt) ~= "number" then return end
    local newEnds = GetTime() + remaining
    if math.abs(newEnds - s.endsAt) < 0.5 then return end   -- ignore noise
    s.endsAt = newEnds
    log("Debug", "delta unit=%s spell=%d remaining=%.1fs", unit, spellID, remaining)
    if GBI.Bar and GBI.Bar.OnCDStart then
        GBI.Bar.OnCDStart(unit, spellID, s)   -- re-render with new endsAt
    end
    -- Reschedule the ready timer for the new (shorter) endsAt. Without this
    -- the original timer fires at the old time, sees endsAt moved, bails
    -- without decrementing inFlight, and the CD lingers in-flight forever
    -- (the all-ready latch never re-arms). scheduleReady's captured-endsAt
    -- token makes the stale original timer a no-op.
    scheduleReady(unit, spellID, newEnds)
end

-- Local-player polling: when SPELL_UPDATE_COOLDOWN fires, scan our active
-- tracked CDs. If the engine reports a shorter remaining than we expect
-- (dynamic CDR like Devourer Meta), broadcast a D delta to peers and
-- update our own state.
local lastDeltaAt = {}              -- spellID -> last broadcast time
local DELTA_THROTTLE = 1.0          -- one D message per spell per second max

local function pollPlayerDynamic()
    if not (state.player and C_Spell and C_Spell.GetSpellCooldown) then return end
    local now = GetTime()
    for sid, s in pairs(state.player) do
        -- Stack-resource entries (Brain.SetStacks) intentionally leave
        -- endsAt = nil; skip them rather than aborting the whole scan.
        if type(s.endsAt) == "number" and s.endsAt > now then
            local ok, info = pcall(C_Spell.GetSpellCooldown, sid)
            if ok and type(info) == "table" and info.startTime and info.duration
               and info.duration > 0 then
                local realEnds = info.startTime + info.duration
                if realEnds < s.endsAt - 1 then
                    s.endsAt = realEnds
                    if GBI.Bar and GBI.Bar.OnCDStart then
                        GBI.Bar.OnCDStart("player", sid, s)
                    end
                    -- Reschedule the ready timer for the shortened endsAt
                    -- (same fix as UpdateRemaining): otherwise the original
                    -- timer bails on the mismatch and never decrements
                    -- inFlight, leaking the player's own dynamic-CDR cooldown.
                    scheduleReady("player", sid, realEnds)
                    if (now - (lastDeltaAt[sid] or 0)) >= DELTA_THROTTLE
                       and GBI.CDComm and GBI.CDComm.BroadcastDelta then
                        GBI.CDComm.BroadcastDelta(sid, math.max(0, realEnds - now))
                        lastDeltaAt[sid] = now
                    end
                end
            end
        end
    end
end

local pollFrame = CreateFrame("Frame", "GOBIGnINTERRUPT_DeltaPoll")
pollFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
pollFrame:SetScript("OnEvent", function() pcall(pollPlayerDynamic) end)

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
    if GBI.StackTracker and GBI.StackTracker.Reset then GBI.StackTracker.Reset() end
    if GBI.CDComm and GBI.CDComm.ResetPeerPresence then GBI.CDComm.ResetPeerPresence() end
    log("Info", "state reset")
end
