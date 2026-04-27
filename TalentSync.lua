-- Per-player talent CDR sync.
--
-- Each addon instance reads its own talent tree (clean local data, no taint)
-- and broadcasts the active node IDs over CDComm. Receivers store the set
-- per-unit; GBI.GetCooldown applies any registered talent reductions when
-- looking up a CD for that unit.
--
-- Wire format: T;<nodeID,nodeID,...>
--
-- Talent CDR rules live in GBI.TalentSync.MODS:
--   [talentNodeOrSpellID] = { { spellID = X, delta = -30 }, ... }
-- Sourced from InterruptTrack's IT.knownTalents pattern. Currently a small
-- seed list for high-impact spells; user can extend at runtime.
--
-- API:
--   GBI.TalentSync.GetTalents(unit)       -> set { [nodeID]=true } or nil
--   GBI.TalentSync.SetTalents(unit, set)  -> store from incoming peer msg
--   GBI.TalentSync.AdjustCD(unit, spellID, baseDuration) -> adjusted seconds

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.TalentSync = GBI.TalentSync or {}
local M = GBI.TalentSync

local function log(level, ...) if GBI.Log then GBI.Log[level]("talents", ...) end end

-- Stored per-unit. Keyed by canonical name (UnitName) so it survives
-- partyN slot renumbering on roster changes.
local talentByName = {}

function M.GetTalents(unit)
    local name = UnitName(unit); if not name then return nil end
    return talentByName[name]
end

function M.SetTalents(unit, set)
    local name = UnitName(unit); if not name then return end
    talentByName[name] = set
end

-- Talent CDR rules. Conservative seed - keys are talent spell IDs (matching
-- InterruptTrack's pattern). Extend by adding new entries.
M.MODS = {
    -- DK Anti-Magic Shell extension (talent 205727 / 457574 in InterruptTrack)
    [205727] = { { spellID = 48707, delta = -20 } },
    -- Hunter Aspect of the Turtle
    [266921] = { { spellID = 186265, delta = -30 } },
    -- DK Pillar of Frost (1218603 reduces by 15s)
    [1218603] = { { spellID = 51271, delta = -15 } },
    -- DK Apocalypse (288848 reduces by 15s)
    [288848] = { { spellID = 275699, delta = -15 } },
    -- Druid Berserk Persistence (391174 reduces by 60s)
    [391174] = { { spellID = 106951, delta = -60 } },
}

function M.AdjustCD(unit, spellID, baseDuration)
    if type(baseDuration) ~= "number" then return baseDuration end
    local set = M.GetTalents(unit)
    if not set then return baseDuration end
    local d = baseDuration
    for nodeID in pairs(set) do
        local mods = M.MODS[nodeID]
        if mods then
            for _, m in ipairs(mods) do
                if m.spellID == spellID then
                    d = math.max(1, d + (m.delta or 0))
                end
            end
        end
    end
    return d
end

-- Read local player talent node IDs into a set. Uses C_Traits if available;
-- returns an empty set on any pcall failure (defensive).
local function readLocalTalents()
    local out = {}
    if not (C_ClassTalents and C_Traits) then return out end
    local ok, configID = pcall(C_ClassTalents.GetActiveConfigID)
    if not ok or not configID then return out end
    local ok2, treeIDs = pcall(C_ClassTalents.GetConfigIDsByClassID,
        select(3, UnitClass("player")))
    if ok2 and treeIDs then
        -- treeIDs may not be useful; fall back to GetTreeNodes via configID
    end
    -- Walk every node in the active config; record IDs of nodes with rank > 0.
    local ok3, nodes = pcall(C_Traits.GetTreeNodes, 0)  -- 0 returns active tree
    if not ok3 or type(nodes) ~= "table" then return out end
    for _, nodeID in ipairs(nodes) do
        local okN, info = pcall(C_Traits.GetNodeInfo, configID, nodeID)
        if okN and info and info.activeRank and info.activeRank > 0 then
            -- Use the activeEntry's definitionID's spellID if available;
            -- otherwise the node ID itself as a fallback key.
            local key = nodeID
            local entryID = info.activeEntry and info.activeEntry.entryID
            if entryID then
                local okE, entry = pcall(C_Traits.GetEntryInfo, configID, entryID)
                if okE and entry and entry.definitionID then
                    local okD, def = pcall(C_Traits.GetDefinitionInfo, entry.definitionID)
                    if okD and def and def.spellID then key = def.spellID end
                end
            end
            out[key] = true
        end
    end
    return out
end

function M.BroadcastSelf()
    if not (GBI.CDComm and GBI.CDComm.Broadcast) then return end
    local set = readLocalTalents()
    local ids = {}
    for k in pairs(set) do ids[#ids + 1] = tostring(k) end
    if #ids == 0 then return end
    local payload = "T;" .. table.concat(ids, ",")
    -- Use the same channel as CDComm.
    if not (GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.comm
        and GOBIGnINTERRUPTDB.comm.enabled == false) then
        if IsInGroup() and C_ChatInfo and C_ChatInfo.SendAddonMessage then
            local channel = IsInRaid() and "RAID" or "PARTY"
            C_ChatInfo.SendAddonMessage("GBINT", payload, channel)
            log("Debug", "broadcast %s (%d nodes)", payload:sub(1, 60), #ids)
        end
    end
    -- Also store our own set so local lookups benefit immediately.
    talentByName[UnitName("player")] = set
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("TRAIT_CONFIG_UPDATED")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:SetScript("OnEvent", function() C_Timer.After(2, M.BroadcastSelf) end)
