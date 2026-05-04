-- Talent-aware CD durations.
--
-- Sources of talent data, in priority order:
--   1. LibSpecialization callback — peers running any LibSpec-aware addon
--      (MiniCC, FrameSort, InterruptTrack, GBI v1.3.0+) broadcast their
--      talent string when joining or speccing. We decode it into a per-
--      player {spellID = rank} map.
--   2. Class + spec defaults — when no real talent data is available for
--      a peer, fall back to assumed picks per class and per spec. Most
--      players take the same major-CDR talents in M+; a default works
--      better than treating everyone as having zero talents.
--   3. Local player's actual talents — read via C_Traits at login and
--      after any spec / talent change. Same decoder as the LibSpec path
--      so the local result is symmetrical with peer data.
--
-- Compatibility:
--   * The existing CDComm "T;<nodeID,...>" message handler still works
--     for v1.2.x GBI peers — SetTalents converts the node-set into a
--     rank-1 map. v1.3.0+ peers communicate via LibSpec instead.
--
-- Public API:
--   GBI.TalentSync.HasTalent(unit, talentID)       -> bool
--   GBI.TalentSync.GetTalentRank(unit, talentID)   -> number (0 if none)
--   GBI.TalentSync.GetTalents(unit)                -> ranks table or nil
--   GBI.TalentSync.SetTalents(unit, set)           -> back-compat: store node-set
--   GBI.TalentSync.AdjustCD(unit, spellID, baseDur) -> adjusted seconds
--
-- Talent → CD mod registry:
--   GBI.TalentSync.MODS[talentID] = { { spellID = X, delta = -N }, ... }
--
-- Talent-string decoder logic adapted from InterruptTrack's IT_Talents.lua
-- (battle-tested in production with WoW 12.0.5; same export-string format).

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.TalentSync = GBI.TalentSync or {}
local M = GBI.TalentSync

local function log(level, ...) if GBI.Log then GBI.Log[level]("talents", ...) end end

local function shortName(n)
    if type(n) ~= "string" then return nil end
    return n:match("^([^%-]+)") or n
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local talentRanks   = {}   -- [shortName][spellID] = rank
local talentSpecIds = {}   -- [shortName] = specID (from LibSpec callback)
local defaultsCache = {}   -- "CLASS|specID" -> merged ranks table

-- ---------------------------------------------------------------------------
-- Class + spec defaults — assumed talent picks per class and per spec.
-- Used as a fallback when no real talent string is available for a peer.
-- Sourced from InterruptTrack v3.2.1's IT_Talents.lua data tables.
-- ---------------------------------------------------------------------------

local ClassDefaults = {
    DEATHKNIGHT = {
        [205727] = 1, -- Anti-Magic Barrier (AMS -20s CD, +40% duration)
    },
    HUNTER = {
        [1258485] = 1, -- Improved Aspect of the Turtle (-30s)
        [459450]  = 1, -- Survival of the Fittest +1 charge
        [53480]   = 1, -- Roar of Sacrifice
    },
    MAGE = {
        [382424]  = 2, -- Winter's Protection (Ice Block -60s at rank 2)
        [1265517] = 1, -- Permafrost Bauble (Ice Block -30s)
    },
    MONK = {
        [388813] = 1, -- Expeditious Fortification (Fortifying Brew CDR)
    },
    PALADIN = {
        [114154] = 1, -- Unbreakable Spirit (Bubble/DP/Ardent -30%)
        [384909] = 1, -- Blessed Protector (BoP/Spellwarding -60s)
    },
    SHAMAN = {
        [381647] = 1, -- Planes Traveler (Astral Shift -30s)
    },
    WARRIOR = {
        [107574] = 1, -- Avatar (quasi-universal across specs)
        [184364] = 1, -- Enraged Regeneration (Fury)
    },
    DEMONHUNTER = {
        [196718] = 1, -- Darkness (common across DH specs)
    },
}

local SpecDefaults = {
    [102] = { [468743] = 1 },                                     -- Balance: Whirling Stars
    [103] = { [102543] = 1, [391174] = 1, [391548] = 1 },         -- Feral
    [105] = { [382552] = 1 },                                     -- Resto: Improved Ironbark
    [64]  = { [1244110] = 1 },                                    -- Frost Mage: Glacial Bulwark
    [63]  = { [1254194] = 1 },                                    -- Fire Mage: Kindling
    [254] = { [260404] = 1 },                                     -- MM Hunter: Calling the Shots
    [256] = { [373035] = 1 },                                     -- Disc Priest: Twins of the Sun Priestess
    [257] = { [419110] = 1, [440738] = 1 },                       -- Holy Priest
    [258] = { [288733] = 1 },                                     -- Shadow: Intangibility
    [65]  = { [384820] = 1, [216331] = 1 },                       -- Holy Pal
    [66]  = { [384820] = 1 },                                     -- Prot Pal
    [70]  = { [458359] = 1, [384820] = 1 },                       -- Ret Pal
    [73]  = { [397103] = 1 },                                     -- Prot War: Defender's Aegis
    [72]  = { [383468] = 1 },                                     -- Fury War: Invigorating Fury
    [268] = { [450989] = 1 },                                     -- Brewmaster
    [269] = { [280197] = 1, [450989] = 1 },                       -- Windwalker
    [270] = { [202424] = 1 },                                     -- Mistweaver: Chrysalis
    [262] = { [114050] = 1, [462440] = 1, [462443] = 1 },         -- Elem Sham
    [264] = { [114052] = 1, [462440] = 1 },                       -- Resto Sham
    [1468] = { [376204] = 1, [376240] = 2 },                      -- Pres Evoker
    [1473] = { [412713] = 1 },                                    -- Aug Evoker
}

local function getDefaultRanks(classToken, specID)
    local key = (classToken or "") .. "|" .. (specID or "")
    if defaultsCache[key] then return defaultsCache[key] end
    local classDef = classToken and ClassDefaults[classToken]
    local specDef  = specID and SpecDefaults[specID]
    if not classDef and not specDef then return nil end
    local merged = {}
    if classDef then for k, v in pairs(classDef) do merged[k] = v end end
    if specDef  then for k, v in pairs(specDef)  do merged[k] = v end end
    defaultsCache[key] = merged
    return merged
end

-- Resolve effective talent ranks for a unit. Real LibSpec/local data
-- wins; otherwise fall back to class+spec defaults.
local function getEffectiveRanks(unit)
    if not unit then return nil end
    local short = shortName(UnitName(unit))
    if short and talentRanks[short] then return talentRanks[short] end
    local _, classToken = UnitClass(unit)
    local specID = short and talentSpecIds[short] or nil
    if not specID and unit == "player" then
        specID = GetSpecialization and GetSpecializationInfo
            and GetSpecializationInfo(GetSpecialization()) or nil
    end
    return getDefaultRanks(classToken, specID)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.GetTalents(unit)
    return getEffectiveRanks(unit)
end

function M.HasTalent(unit, talentID)
    if not unit or not talentID then return false end
    local ranks = getEffectiveRanks(unit)
    return ranks ~= nil and (ranks[talentID] or 0) > 0
end

function M.GetTalentRank(unit, talentID)
    if not unit or not talentID then return 0 end
    local ranks = getEffectiveRanks(unit)
    return ranks and (ranks[talentID] or 0) or 0
end

-- Back-compat: the old CDComm "T" handler hands us a node-ID set. Convert
-- to a rank-1 map. v1.2.x peers still send these; v1.3.0+ peers
-- communicate via LibSpec callback (decoded talent string -> ranks).
function M.SetTalents(unit, set)
    local short = shortName(UnitName(unit))
    if not short or type(set) ~= "table" then return end
    local ranks = {}
    for k in pairs(set) do ranks[k] = 1 end
    talentRanks[short] = ranks
end

-- ---------------------------------------------------------------------------
-- Talent → CD mods (talent ID -> { spellID, delta })
-- ---------------------------------------------------------------------------

M.MODS = {
    -- Death Knight
    [205727]  = { { spellID = 48707,  delta = -20 } },  -- AMS Barrier (-20s)
    [1218603] = { { spellID = 51271,  delta = -15 } },  -- Pillar of Frost
    [288848]  = { { spellID = 275699, delta = -15 } },  -- Apocalypse
    -- Hunter
    [266921]  = { { spellID = 186265, delta = -30 } },  -- Aspect of the Turtle (legacy)
    [1258485] = { { spellID = 186265, delta = -30 } },  -- Improved Aspect of the Turtle
    -- Druid
    [391174]  = { { spellID = 106951, delta = -60 } },  -- Berserk Persistence
    [102543]  = { { spellID = 106951, delta = -60 } },  -- Feral Incarnation talent
    [382552]  = { { spellID = 102342, delta = -20 } },  -- Improved Ironbark
    [468743]  = { { spellID = 194223, delta = -60 } },  -- Whirling Stars (Balance Incarnation)
    -- Mage
    [382424]  = { { spellID = 45438,  delta = -60 } },  -- Winter's Protection (Ice Block r2)
    [1265517] = { { spellID = 45438,  delta = -30 } },  -- Permafrost Bauble (Ice Block)
    [1254194] = { { spellID = 190319, delta = -60 } },  -- Kindling (Combustion)
    -- Paladin
    [114154]  = { { spellID = 642,    delta = -90 },    -- Unbreakable Spirit -30% on Bubble
                  { spellID = 498,    delta = -18 },    -- and Divine Protection
                  { spellID = 31850,  delta = -27 }, }, -- and Ardent Defender
    [384909]  = { { spellID = 1022,   delta = -60 },    -- Blessed Protector
                  { spellID = 204018, delta = -60 }, }, -- on BoP and Spellwarding
    -- Priest
    [288733]  = { { spellID = 47585,  delta = -30 } },  -- Intangibility (Dispersion)
    [238100]  = { { spellID = 19236,  delta = -20 } },  -- Desperate Prayer reduction
    -- Hunter (continued)
    [260404]  = { { spellID = 288613, delta = -30 } },  -- Calling the Shots (Trueshot)
    -- Shaman
    [381647]  = { { spellID = 108271, delta = -30 } },  -- Planes Traveler (Astral Shift)
    -- Demon Hunter
    [212593]  = { { spellID = 196718, delta = -120 } }, -- Darkness reduction
    -- Evoker
    [412713]  = { { spellID = 363916, delta = -10 } },  -- Obsidian Scales (Aug)
    -- Monk
    [388813]  = { { spellID = 115203, delta = -30 } },  -- Expeditious Fortification (Fortifying Brew)
    [202424]  = { { spellID = 116849, delta = -30 } },  -- Chrysalis (Life Cocoon)
}

function M.AdjustCD(unit, spellID, baseDuration)
    if type(baseDuration) ~= "number" then return baseDuration end
    local ranks = getEffectiveRanks(unit)
    if not ranks then return baseDuration end
    local d = baseDuration
    for talentID, rank in pairs(ranks) do
        if rank and rank > 0 then
            local mods = M.MODS[talentID]
            if mods then
                for _, mod in ipairs(mods) do
                    if mod.spellID == spellID then
                        d = math.max(1, d + (mod.delta or 0))
                    end
                end
            end
        end
    end
    return d
end

-- ---------------------------------------------------------------------------
-- Talent-string decoder (adapted from InterruptTrack v3.2.1 / IT_Talents.lua)
-- ---------------------------------------------------------------------------

local function buildTalentToSpellMap(specID)
    if not (C_ClassTalents and C_Traits and Constants and Constants.TraitConsts) then
        return nil
    end
    local configID = Constants.TraitConsts.VIEW_TRAIT_CONFIG_ID
    pcall(C_ClassTalents.InitializeViewLoadout, specID, 100)
    pcall(C_ClassTalents.ViewLoadout, {})
    local ok, configInfo = pcall(C_Traits.GetConfigInfo, configID)
    if not ok or not configInfo then return nil end

    local map = {}
    for _, treeID in ipairs(configInfo.treeIDs or {}) do
        local okN, nodes = pcall(C_Traits.GetTreeNodes, treeID)
        if okN and nodes then
            for _, nodeID in ipairs(nodes) do
                local okNode, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
                if okNode and node and node.ID ~= 0 then
                    for choiceIdx, talentID in ipairs(node.entryIDs or {}) do
                        local okE, entry = pcall(C_Traits.GetEntryInfo, configID, talentID)
                        if okE and entry then
                            if Enum and Enum.TraitNodeType
                               and node.type == Enum.TraitNodeType.SubTreeSelection then
                                map[node.ID .. "_" .. choiceIdx] = {
                                    spellID = -1, maxRank = -1,
                                    type = node.type, subTreeID = entry.subTreeID,
                                }
                            elseif entry.definitionID then
                                local okD, def = pcall(C_Traits.GetDefinitionInfo, entry.definitionID)
                                if okD and def and def.spellID then
                                    map[node.ID .. "_" .. choiceIdx] = {
                                        spellID = def.spellID, maxRank = node.maxRanks,
                                        type = node.type, subTreeID = node.subTreeID,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return map
end

local function decodeTalentStream(stream)
    local function readBool(s) return s:ExtractValue(1) == 1 end
    local selected = readBool(stream)
    local purchased, rank, choiceIdx = nil, nil, 1
    if selected then
        purchased = readBool(stream)
        if purchased then
            local notMax = readBool(stream)
            if notMax then rank = stream:ExtractValue(6) end
            if readBool(stream) then choiceIdx = stream:ExtractValue(2) + 1 end
        end
    end
    return selected, purchased, rank, choiceIdx
end

local function decodeTalentString(specID, exportStr)
    if not (C_Traits and C_Traits.GetLoadoutSerializationVersion
            and ImportDataStreamMixin and C_ClassTalents) then return nil end

    local talentMap = buildTalentToSpellMap(specID)
    if not talentMap then return nil end

    local ok, stream = pcall(CreateAndInitFromMixin, ImportDataStreamMixin, exportStr)
    if not ok or not stream then return nil end

    local okV, ver = pcall(function() return stream:ExtractValue(8) end)
    if not okV then return nil end
    local okS, encSpec = pcall(function() return stream:ExtractValue(16) end)
    if not okS then return nil end
    pcall(function() stream:ExtractValue(128) end)  -- discard treeHash

    local okL, serVer = pcall(C_Traits.GetLoadoutSerializationVersion)
    if not okL or serVer ~= 2 or ver ~= 2 or encSpec ~= specID then return nil end

    local okT, traitTree = pcall(C_ClassTalents.GetTraitTreeForSpec, specID)
    if not okT or not traitTree then return nil end

    local okNodes, nodes = pcall(C_Traits.GetTreeNodes, traitTree)
    if not okNodes or not nodes then return nil end

    local records = {}
    local heroChoice
    for _, nodeID in ipairs(nodes) do
        local selected, purchased, rank, choiceIdx = decodeTalentStream(stream)
        local spell = talentMap[nodeID .. "_" .. choiceIdx]
        local rec = {
            spellID   = spell and spell.spellID or -1,
            selected  = selected,
            purchased = purchased,
            rank      = rank,
            maxRank   = spell and spell.maxRank or nil,
            subTreeID = spell and spell.subTreeID or nil,
            nodeType  = spell and spell.type or nil,
        }
        records[#records + 1] = rec
        if Enum and Enum.TraitNodeType
           and rec.nodeType == Enum.TraitNodeType.SubTreeSelection then
            heroChoice = spell and spell.subTreeID
        end
    end

    local result = {}
    for _, rec in ipairs(records) do
        if rec.subTreeID == nil or rec.subTreeID == heroChoice then
            if rec.spellID and rec.spellID > 0 then
                result[rec.spellID] = (not rec.selected) and 0
                    or rec.rank or rec.maxRank or 1
            end
        end
    end
    return result
end

local function storeRanks(short, specID, ranks)
    if not short or not ranks then return end
    talentRanks[short]   = ranks
    talentSpecIds[short] = specID
    log("Debug", "stored talent ranks for %s (specID=%s, %d entries)",
        short, tostring(specID), (function() local n=0 for _ in pairs(ranks) do n=n+1 end return n end)())
end

local function updateLocalPlayer()
    if not (GetSpecialization and GetSpecializationInfo
            and C_ClassTalents and C_Traits) then return end
    local okSpec, specIdx = pcall(GetSpecialization)
    if not okSpec or not specIdx then return end
    local okInfo, specID = pcall(GetSpecializationInfo, specIdx)
    if not okInfo or not specID then return end
    local okCfg, configID = pcall(C_ClassTalents.GetActiveConfigID)
    if not okCfg or not configID then return end
    local okStr, exportStr = pcall(C_Traits.GenerateImportString, configID)
    if not okStr or not exportStr then return end
    local ranks = decodeTalentString(specID, exportStr)
    if not ranks then return end
    local short = shortName(UnitName("player"))
    if short then storeRanks(short, specID, ranks) end
end

-- ---------------------------------------------------------------------------
-- LibSpecialization registration: receive talent strings from any group
-- member running an addon that uses LibSpec (MiniCC, FrameSort,
-- InterruptTrack, GBI v1.3.0+).
-- ---------------------------------------------------------------------------

local function registerLibSpec()
    if not LibStub then return false end
    local LS = LibStub("LibSpecialization", true)
    if not LS or not LS.RegisterGroup then return false end
    LS.RegisterGroup(M, function(specID, _, _, playerName, talentString)
        if not playerName then return end
        local short = shortName(playerName)
        if not short then return end
        if talentString and specID then
            local ranks = decodeTalentString(specID, talentString)
            if ranks then
                storeRanks(short, specID, ranks)
                return
            end
        end
        -- Even without a talent string, knowing specID lets us apply
        -- the per-spec defaults instead of just per-class.
        if specID then talentSpecIds[short] = specID end
    end)
    log("Info", "registered with LibSpecialization")
    return true
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_TalentSyncFrame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("TRAIT_CONFIG_UPDATED")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        registerLibSpec()
        C_Timer.After(1.0, updateLocalPlayer)
    else
        C_Timer.After(0.5, updateLocalPlayer)
    end
end)
