-- Peer-to-peer cooldown sharing.
--
-- WoW Midnight 12.0.5 redacts spell IDs from UNIT_SPELLCAST_* events for
-- party members on remote PCs. Our local detection therefore can't see what
-- other party members are casting — but THEIR addon instance can see THEIR
-- own casts perfectly. Solution: each addon broadcasts its own casts over
-- the addon channel; receivers feed them into Brain as if locally observed.
--
-- Wire format (semicolon-delimited):
--   U;<spellID>;<duration>           - cast announcement
-- Channel: RAID if in raid, else PARTY. Both ends must have the addon.
-- Default: enabled (DB.comm.enabled = true).

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.CDComm = GBI.CDComm or {}
local M = GBI.CDComm

local PREFIX = "GBINT"
local function log(level, ...) if GBI.Log then GBI.Log[level]("comm", ...) end end

local function enabled()
    -- Default ON: only disabled if user explicitly set comm.enabled = false.
    local c = GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.comm
    if c and c.enabled == false then return false end
    return true
end

-- Match "Name-Realm" or "Name" against a party unit token.
local function senderToUnit(sender)
    if not sender then return nil end
    local short = sender:match("^([^%-]+)") or sender
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            local n = UnitName(u)
            if n == short then return u end
        end
    end
    return nil
end

function M.Broadcast(spellID, duration)
    if not enabled() then
        log("Debug", "broadcast skip: comm disabled (spell=%s)", tostring(spellID)); return
    end
    if not IsInGroup() then
        log("Debug", "broadcast skip: not in group (spell=%s)", tostring(spellID)); return
    end
    if type(spellID) ~= "number" or type(duration) ~= "number" then
        log("Debug", "broadcast skip: bad args (spell=%s dur=%s)",
            tostring(spellID), tostring(duration)); return
    end
    local channel = IsInRaid() and "RAID" or "PARTY"
    local ok, err = C_ChatInfo.SendAddonMessage(PREFIX, ("U;%d;%d"):format(spellID, duration), channel)
    log("Debug", "broadcast U;%d;%d -> %s (ok=%s err=%s)",
        spellID, duration, channel, tostring(ok), tostring(err))
end

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_CommFrame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_ADDON")
f:SetScript("OnEvent", function(_, event, prefix, msg, channel, sender)
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        end
        return
    end
    if event ~= "CHAT_MSG_ADDON" or prefix ~= PREFIX then return end
    log("Debug", "recv raw msg=%s sender=%s ch=%s", tostring(msg), tostring(sender), tostring(channel))
    if not enabled() then log("Debug", "  drop: comm disabled"); return end

    local me = UnitName("player")
    if sender == me or (type(sender) == "string" and sender:match("^([^%-]+)") == me) then
        log("Debug", "  drop: self message")
        return
    end

    local mt, sidStr, durStr = strsplit(";", msg or "")
    if mt ~= "U" then log("Debug", "  drop: bad msgType=%s", tostring(mt)); return end
    local sid = tonumber(sidStr); local dur = tonumber(durStr)
    if not sid or not dur then
        log("Debug", "  drop: bad parse sid=%s dur=%s", tostring(sidStr), tostring(durStr)); return
    end

    local unit = senderToUnit(sender)
    if not unit then
        log("Debug", "  drop: senderToUnit nil for %s", tostring(sender)); return
    end

    local cd = GBI.GetCooldown and GBI.GetCooldown(sid)
    if not cd then
        log("Debug", "  drop: spell %d not in receiver's DB", sid); return
    end

    log("Debug", "recv U %s -> %s spell=%d dur=%d", sender, unit, sid, dur)
    if GBI.Brain and GBI.Brain.OnCast then
        GBI.Brain.OnCast(unit, sid, cd)
    end
end)
