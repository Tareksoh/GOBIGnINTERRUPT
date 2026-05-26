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

-- Counts are keyed by SHORT name (realm stripped) for cross-realm
-- consistency — UnitName can return "Name-Realm" for cross-realm party
-- members, which would split a player's count across two keys.
local function shortName(n)
    if type(n) ~= "string" then return nil end
    return n:match("^([^%-]+)") or n
end

local function isInterruptSpell(spellID)
    -- Use GBI.GetCooldown as the single chokepoint - it pcalls the table
    -- index so secret-tagged spellIDs miss cleanly instead of throwing.
    local cd = GBI.GetCooldown and GBI.GetCooldown(spellID)
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
            local name = shortName(UnitName(unit)) or unit
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

-- A successful UNIT_SPELLCAST_SUCCEEDED for an interrupt spell only tells
-- us the spell was CAST, not that anything was actually interrupted (target
-- might not have been casting / was stunned / dead / out of range). The
-- UNIT_SPELLCAST_INTERRUPTED event on the enemy is the authoritative
-- "kick landed" signal — attributeInterrupt() handles the credit there.
--
-- Crediting here in addition to attributeInterrupt would double-count
-- every successful kick made by the local addon user (the one player
-- whose own spell IDs aren't 12.0.5-redacted). Other party members'
-- counts route only through Path 2 (UNIT_SPELLCAST_INTERRUPTED +
-- temporal attribution / peer-broadcast), so this only affected the
-- viewer's own row in the bar.
local function onCast(unit, spellID)
    if not isInterruptSpell(spellID) then return end
    local name = UnitName(unit) or "?"
    log("Debug", "interrupt cast seen on %s spell=%d (no credit; pending INTERRUPTED)",
        name, spellID)
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
    "player", "party1", "party2", "party3", "party4",
    "partypet1", "partypet2", "partypet3", "partypet4")
-- UNIT_SPELLCAST_INTERRUPTED is unrestricted (fires on whatever the engine
-- delivers). We filter to enemy units inside the handler.
f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
f:RegisterEvent("CHALLENGE_MODE_START")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("GROUP_ROSTER_UPDATE")

-- ---------------------------------------------------------------------------
-- Kicker-style cross-attribution: when an enemy cast is interrupted we don't
-- get the source spellID reliably (12.0.5 redaction), but we DO get the unit
-- token of any party member that fired UNIT_SPELLCAST_SUCCEEDED moments
-- before. Inspired by /Kicker/Modules/Interrupt.lua.
-- ---------------------------------------------------------------------------
local recentPartyCasts = {}      -- [unit] = lastSeenAt
local KICK_ATTRIB_WINDOW = 0.5

local function recordRecentCast(unit)
    local owner = unit
    if type(unit) == "string" and unit:find("^partypet(%d)$") then
        owner = unit:gsub("partypet", "party")
    end
    if owner == "player" or (type(owner) == "string" and owner:match("^party[1-4]$")) then
        recentPartyCasts[owner] = GetTime()
    end
end

local function creditUnit(unit, reason)
    local name = shortName(UnitName(unit))
    if not name then return end
    counts[name] = (counts[name] or 0) + 1
    log("Debug", "kick++ %s (%s) total=%d", name, reason, counts[name])
    refresh()
end

-- Peer-broadcast attribution: the player on the other end announces
-- "I just landed an interrupt" via CDComm. Direct attribution beats
-- the temporal-window guess; consumes any pending Kicker-style record.
local recentPeerAttribAt = {}     -- [unit] = time (suppresses temporal fallback)
function M.AttributePeer(unit)
    creditUnit(unit, "peer-broadcast")
    recentPeerAttribAt[unit] = GetTime()
    recentPartyCasts[unit] = nil
end

local function attributeInterrupt()
    local now = GetTime()
    local bestUnit, bestTime = nil, -1
    for u, t in pairs(recentPartyCasts) do
        if (now - t) <= KICK_ATTRIB_WINDOW and t > bestTime then
            bestUnit, bestTime = u, t
        end
    end
    if not bestUnit then return end
    -- If a peer already self-attributed within ~0.5s, don't double-credit.
    local peerAt = recentPeerAttribAt[bestUnit]
    if peerAt and (now - peerAt) < KICK_ATTRIB_WINDOW then
        recentPartyCasts[bestUnit] = nil
        return
    end
    creditUnit(bestUnit, "temporal-attrib via " .. bestUnit)
    recentPartyCasts[bestUnit] = nil
    -- If the attribution lands on us, tell peers — they'll credit us
    -- directly instead of running their own temporal heuristic, which
    -- can mis-attribute on chained kicks.
    if bestUnit == "player" and GBI.CDComm and GBI.CDComm.BroadcastInterrupt then
        GBI.CDComm.BroadcastInterrupt()
    end
end

f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit = arg1
        if unit ~= "player" and not (type(unit) == "string"
            and (unit:match("^party[1-4]$") or unit:match("^partypet[1-4]$"))) then return end
        recordRecentCast(unit)
        -- Spell-ID path (works on same-PC parties + own casts; degrades
        -- silently elsewhere). The cross-attrib path above handles the rest.
        local spellID = (GBI.Taint and GBI.Taint.SafeSpellID and GBI.Taint.SafeSpellID(arg3)) or arg3
        if type(spellID) ~= "number" then return end
        onCast(unit, spellID)
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        local unit = arg1
        local isEnemy = unit == "target" or unit == "focus"
            or (type(unit) == "string" and (unit:match("^boss%d$") or unit:match("^nameplate%d+$")))
        if isEnemy then attributeInterrupt() end
    elseif event == "CHALLENGE_MODE_START" then
        M.Reset()
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        maybeResetForNewInstance()
        refresh()
    elseif event == "GROUP_ROSTER_UPDATE" then
        refresh()
    end
end)
