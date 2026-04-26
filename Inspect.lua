-- NotifyInspect queue + spec cache.
-- Adapted from MythicPlusCDTracker Engine.lua:526-606.
--
-- Public API:
--   GBI.Inspect.GetSpec(unit) -> specIndex | nil    (1..4 GetSpecialization style)
--   GBI.Inspect.GetSpecByGUID(guid) -> specIndex | nil
--   GBI.Inspect.RescanParty()                       (force re-queue all party)
--
-- Lifecycle:
--   On PLAYER_ENTERING_WORLD (in a 5-man), or GROUP_ROSTER_UPDATE, or
--   PLAYER_SPECIALIZATION_CHANGED, the Inspect manager queues the 4 other
--   party members. Self spec comes from GetSpecialization() directly.
--
-- Rate limit: Blizzard caps NotifyInspect at ~1 inspect / 1.5s. We pace the
-- queue conservatively at 1.5s. A unit that times out (5s, no INSPECT_READY)
-- gets retried up to 3 times, then we fall back to leaving its spec nil
-- (Brain treats nil-spec as "show the union of class CDs without spec filter").

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.Inspect = GBI.Inspect or {}
local M = GBI.Inspect

local THROTTLE = K.INSPECT_THROTTLE_S
local TIMEOUT  = K.INSPECT_TIMEOUT_S
local RETRIES  = K.INSPECT_RETRIES

-- spec cache, keyed by GUID. value = { spec = N, classToken = "MAGE", name = "..." }
local cache = {}

-- queue is an array of { unit, retriesLeft, queuedAt }
local queue = {}
local lastInspect = 0
local pendingByUnit = {}     -- unit -> queueEntry currently in flight
local timeoutHandle           -- C_Timer.NewTicker handle

-- Helpers ---------------------------------------------------------------

local function log(level, ...) if GBI.Log then GBI.Log[level]("inspect", ...) end end

local function unitGUIDSafe(unit)
    if not UnitExists(unit) then return nil end
    return GBI.Taint.SafeGUID(unit)
end

-- Read self spec without inspect (no round-trip required).
local function selfSpec()
    local guid = unitGUIDSafe("player")
    local _, classToken = UnitClass("player")
    local spec = GetSpecialization and GetSpecialization() or nil
    if guid then
        cache[guid] = {
            spec       = spec,
            classToken = classToken,
            name       = UnitName("player"),
        }
    end
end

-- Public lookups ---------------------------------------------------------

function M.GetSpecByGUID(guid)
    if not guid then return nil end
    local rec = cache[guid]
    return rec and rec.spec or nil
end

function M.GetSpec(unit)
    local guid = unitGUIDSafe(unit)
    if not guid then return nil end
    return M.GetSpecByGUID(guid)
end

function M.GetClassByGUID(guid)
    if not guid then return nil end
    local rec = cache[guid]
    return rec and rec.classToken or nil
end

-- Queue management -------------------------------------------------------

local function isQueued(unit)
    if pendingByUnit[unit] then return true end
    for _, e in ipairs(queue) do
        if e.unit == unit then return true end
    end
    return false
end

local function enqueue(unit, retries)
    if not unit or unit == "player" then return end
    if not UnitExists(unit) then return end
    if isQueued(unit) then return end
    queue[#queue + 1] = { unit = unit, retriesLeft = retries or RETRIES, queuedAt = GetTime() }
    log("Debug", "queued %s (retries=%d) qlen=%d", unit, retries or RETRIES, #queue)
end

local function nextUnit()
    return table.remove(queue, 1)
end

local function tryFire()
    if InCombatLockdown and InCombatLockdown() then
        -- inspecting in combat is technically allowed but flaky; defer
        return
    end
    if #queue == 0 and not next(pendingByUnit) then return end
    local now = GetTime()
    if (now - lastInspect) < THROTTLE then return end
    if next(pendingByUnit) then return end  -- one in flight at a time

    local entry = nextUnit()
    if not entry then return end
    if not UnitExists(entry.unit) then return end

    pendingByUnit[entry.unit] = entry
    entry.firedAt = now
    lastInspect = now
    log("Debug", "NotifyInspect %s", entry.unit)
    local ok = pcall(NotifyInspect, entry.unit)
    if not ok then
        log("Warn", "NotifyInspect threw on %s", entry.unit)
        pendingByUnit[entry.unit] = nil
    end
end

-- Drive the queue with a low-rate ticker (every 0.5s) — enough cadence to
-- keep up with the throttle.
local function startTicker()
    if timeoutHandle then return end
    timeoutHandle = C_Timer.NewTicker(0.5, function()
        tryFire()
        -- expire stuck pending units
        local now = GetTime()
        for unit, entry in pairs(pendingByUnit) do
            if (now - (entry.firedAt or 0)) > TIMEOUT then
                log("Warn", "%s timed out, retries=%d", unit, entry.retriesLeft)
                pendingByUnit[unit] = nil
                if entry.retriesLeft > 0 then
                    enqueue(unit, entry.retriesLeft - 1)
                end
            end
        end
    end)
end

-- INSPECT_READY handler --------------------------------------------------

-- Class token (uppercase, e.g. "WARRIOR") -> integer classID (1..13).
-- Used to translate a unit's class into a classID we can pass to
-- GetSpecializationInfoForClassID.
local CLASS_TOKEN_TO_ID = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5,
    DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8, WARLOCK = 9, MONK = 10,
    DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
}

-- Translate a global spec ID (e.g. 71 = Arms Warrior) to a 1..4 spec index
-- relative to the unit's class. Returns nil if not found.
local function globalSpecToIndex(globalSpec, classID)
    if not globalSpec or not classID then return nil end
    local n = (GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(classID)) or 4
    for i = 1, n do
        local id = select(1, GetSpecializationInfoForClassID(classID, i))
        if id == globalSpec then return i end
    end
    return nil
end

local function onInspectReady(guid)
    if not guid then return end
    for unit, entry in pairs(pendingByUnit) do
        local g = unitGUIDSafe(unit)
        if g == guid then
            local globalSpec = GetInspectSpecialization and GetInspectSpecialization(unit) or nil
            -- Get the unit's class (uppercase token from UnitClass).
            local _, classToken = UnitClass(unit)
            local classID = classToken and CLASS_TOKEN_TO_ID[classToken] or nil
            local specIndex
            if globalSpec and globalSpec > 0 and classID then
                specIndex = globalSpecToIndex(globalSpec, classID)
            end
            cache[guid] = {
                spec       = specIndex,    -- 1..4 (or nil)
                globalSpec = globalSpec,
                classToken = classToken,
                name       = UnitName(unit),
            }
            log("Info", "%s = %s spec=%s (global=%s)",
                unit, tostring(classToken), tostring(specIndex), tostring(globalSpec))
            pendingByUnit[unit] = nil
            return
        end
    end
end

-- Public re-scan ---------------------------------------------------------

function M.RescanParty()
    selfSpec()
    for _, unit in ipairs(K.PARTY_OTHERS) do
        if UnitExists(unit) then
            enqueue(unit, RETRIES)
        end
    end
    startTicker()
end

-- Event wiring -----------------------------------------------------------

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_InspectFrame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("INSPECT_READY")

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        selfSpec()
    elseif event == "PLAYER_ENTERING_WORLD" then
        selfSpec()
        -- Fire a rescan after a small delay so the roster has settled.
        C_Timer.After(1.0, function() M.RescanParty() end)
    elseif event == "GROUP_ROSTER_UPDATE" then
        C_Timer.After(0.5, function() M.RescanParty() end)
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        if arg1 == "player" or not arg1 then selfSpec() end
    elseif event == "INSPECT_READY" then
        onInspectReady(arg1)
    end
end)

startTicker()
