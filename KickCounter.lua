-- Per-dungeon interrupt counter.
--
-- Listens to UNIT_SPELLCAST_SUCCEEDED on player + party1..4 (FRIENDLY units —
-- this is a clean context, no taint contagion). When the cast spellID matches
-- a known interrupt from GBI.Cooldowns (category == K.CAT_INTERRUPT), bump the
-- per-unit count.
--
-- Reset triggers:
--   * CHALLENGE_MODE_START                    -> begin a fresh M+ run
--   * ZONE_CHANGED_NEW_AREA, when entering a new instance map ID
--
-- Display: a fontstring attached to the bottom of the BarInterrupts anchor.
--
-- Public API:
--   GBI.KickCounter.Reset()
--   GBI.KickCounter.Get()         -> { [unitName] = count, ... }
--   GBI.KickCounter.Print()       -> /gbi kicks slash output

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.KickCounter = GBI.KickCounter or {}
local M = GBI.KickCounter

local counts = {}                 -- [unitName] = number
local currentMap = nil            -- last-seen instance map id
local label                       -- fontstring on the interrupt bar

local function log(level, ...) if GBI.Log then GBI.Log[level]("kicks", ...) end end

local function isInterruptSpell(spellID)
    if type(spellID) ~= "number" then return false end
    local cd = GBI.Cooldowns and GBI.Cooldowns[spellID]
    return cd and cd.category == K.CAT_INTERRUPT
end

local function ensureLabel()
    if label then return label end
    if not (GBI.Bar and GBI.Bar.GetInterruptAnchor) then return nil end
    local anchor = GBI.Bar.GetInterruptAnchor()
    if not anchor then return nil end
    label = anchor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -2)
    label:SetJustifyH("LEFT")
    label:SetWidth(600)
    return label
end

local function refresh()
    local fs = ensureLabel()
    if not fs then return end
    local parts = {}
    for _, unit in ipairs(K.PARTY_UNITS) do
        if UnitExists(unit) then
            local name = UnitName(unit) or unit
            local n = counts[name] or 0
            local _, classToken = UnitClass(unit)
            local s
            if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
                local c = RAID_CLASS_COLORS[classToken]
                s = ("|cff%02x%02x%02x%s|r:%d"):format(c.r * 255, c.g * 255, c.b * 255, name, n)
            else
                s = ("%s:%d"):format(name, n)
            end
            parts[#parts + 1] = s
        end
    end
    fs:SetText("Kicks  " .. table.concat(parts, "  "))
end

function M.Reset()
    counts = {}
    refresh()
    log("Info", "kick counter reset")
end

function M.Get() return counts end

function M.Print()
    local say = function(s) print("|cff66ddffGBI|r " .. s) end
    say("Kicks this run:")
    for name, n in pairs(counts) do print(("  %s: %d"):format(name, n)) end
end

local function onCast(unit, spellID)
    if not isInterruptSpell(spellID) then return end
    local name = UnitName(unit)
    if not name then return end
    counts[name] = (counts[name] or 0) + 1
    log("Debug", "kick++ %s spell=%d total=%d", name, spellID, counts[name])
    refresh()
end

local function maybeResetForNewInstance()
    local _, _, _, _, _, _, _, mapID = GetInstanceInfo()
    if mapID and mapID ~= currentMap then
        currentMap = mapID
        M.Reset()
    end
end

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_KickCounterFrame")
-- RegisterUnitEvent restricts to the named friendly units (no hostile taint).
-- Single call covers all unit tokens (up to 8 supported).
f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED",
    "player", "party1", "party2", "party3", "party4")
f:RegisterEvent("CHALLENGE_MODE_START")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("GROUP_ROSTER_UPDATE")

f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = arg1, arg2, arg3
        if unit ~= "player" and not (type(unit) == "string" and unit:match("^party[1-4]$")) then return end
        onCast(unit, spellID)
    elseif event == "CHALLENGE_MODE_START" then
        M.Reset()
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        maybeResetForNewInstance()
        refresh()
    elseif event == "GROUP_ROSTER_UPDATE" then
        refresh()
    end
end)
