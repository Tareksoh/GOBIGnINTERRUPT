-- Stack-resource tracker.
--
-- Some 12.0.5 abilities aren't on a normal cooldown — they unlock when the
-- player accumulates N stacks of a charging aura. Devourer DH's
-- Void Metamorphosis (1217605, threshold 50) is the canonical example.
--
-- For each cdEntry in Data_Cooldowns with `stackingResource = { auraID, threshold }`,
-- this module:
--   * Watches UNIT_AURA + polls C_UnitAuras every 0.5s for the player and party
--   * Updates the per-unit stack count
--   * Calls Brain.SetStacks(unit, spellID, current, threshold)
--   * Triggers Bar/UnitOverlay re-render with the stack overlay
--
-- Peer comm: each player broadcasts their own stack count via CDComm "K"
-- message. Receivers update local state directly.
--
-- Wire format: K;<spellID>;<currentStacks>

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.StackTracker = GBI.StackTracker or {}
local M = GBI.StackTracker

local function log(level, ...) if GBI.Log then GBI.Log[level]("stacks", ...) end end

-- Engine gate: stack-resource spells only matter inside the tracked
-- context (M+ / showAlways). When the engine is off, skip all scan work so
-- we don't poll C_UnitAuras every 0.5s in raids/world or write Brain/UI
-- state. (Index building on login still runs — it's cheap and harmless.)
local function engineOn()
    return GBI.Bar and GBI.Bar.IsEngineEnabled and GBI.Bar.IsEngineEnabled() or false
end

-- Build a reverse index: auraID -> { spellID, threshold }.
local function buildIndex()
    local idx = {}
    local merge = GBI.IterCooldowns and GBI.IterCooldowns(true) or GBI.Cooldowns or {}
    for sid, cd in pairs(merge) do
        if type(cd) == "table" and cd.stackingResource and cd.stackingResource.auraID
           and cd.stackingResource.auraID > 0 then
            idx[cd.stackingResource.auraID] = {
                spellID = sid,
                threshold = cd.stackingResource.threshold or 1,
            }
        end
    end
    return idx
end

local auraIndex = {}
local function refreshIndex() auraIndex = buildIndex() end

-- per-unit current stack counts: stacks[unit][spellID] = n
local stacks = {}

local function setStacks(unit, spellID, n, threshold)
    stacks[unit] = stacks[unit] or {}
    if stacks[unit][spellID] == n then return end       -- no change
    stacks[unit][spellID] = n
    if GBI.Brain and GBI.Brain.SetStacks then
        GBI.Brain.SetStacks(unit, spellID, n, threshold)
    end
end

local function scanUnit(unit)
    if not UnitExists(unit) then return end
    if next(auraIndex) == nil then return end
    -- Skip individual unreadable (private-aura) slots instead of breaking
    -- the whole scan; two consecutive nils = genuine end-of-list. Same
    -- pattern as Evidence.lua.
    local consecutiveNil = 0
    for i = 1, 40 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then
            consecutiveNil = 0
        elseif not aura then
            consecutiveNil = consecutiveNil + 1
            if consecutiveNil >= 2 then break end
        else
            consecutiveNil = 0
            -- Launder the spell ID (tostring->tonumber strips the secret
            -- marker) rather than rejecting tagged values outright.
            local okId, rawId = pcall(function() return aura.spellId end)
            local sid = okId and rawId and GBI.Taint and GBI.Taint.SafeSpellID
                and GBI.Taint.SafeSpellID(rawId) or nil
            if sid then
                local entry = auraIndex[sid]   -- sid is now a clean number
                if entry then
                    -- applications can be a secret number (type()=="number"
                    -- still passes for tagged), which would propagate into
                    -- Brain/UI and throw on a later >= compare. Launder it.
                    local okN, rawN = pcall(function() return aura.applications end)
                    local stackN = (okN and rawN ~= nil
                        and GBI.Taint and GBI.Taint.SafeNumber
                        and GBI.Taint.SafeNumber(rawN)) or 1
                    setStacks(unit, entry.spellID, stackN, entry.threshold)
                    if unit == "player" and GBI.CDComm and GBI.CDComm.BroadcastStacks then
                        GBI.CDComm.BroadcastStacks(entry.spellID, stackN)
                    end
                end
            end
        end
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterUnitEvent("UNIT_AURA",
    "player", "party1", "party2", "party3", "party4")
f:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        refreshIndex()
        return
    end
    if not unit then return end
    if not engineOn() then return end
    if unit ~= "player" and not (type(unit) == "string" and unit:match("^party[1-4]$")) then return end
    pcall(scanUnit, unit)
end)

-- Periodic backup poll. UNIT_AURA can be silent on some configurations.
local poller = CreateFrame("Frame")
poller:SetScript("OnUpdate", function(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < 0.5 then return end
    self.acc = 0
    if not engineOn() then return end
    if next(auraIndex) == nil then return end
    for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
        pcall(scanUnit, u)
    end
end)

-- Public: lookup current stacks
function M.Get(unit, spellID)
    return stacks[unit] and stacks[unit][spellID]
end

function M.Refresh() refreshIndex() end

-- Called from Brain.Reset on zone change / new dungeon to drop any stale
-- stack counters (would otherwise leak across runs).
function M.Reset() stacks = {} end
