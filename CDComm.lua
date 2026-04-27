-- Peer-to-peer cooldown sharing.
--
-- WoW Midnight 12.0.5 redacts spell IDs from UNIT_SPELLCAST_* events for
-- party members on remote PCs. Our local detection therefore can't see what
-- other party members are casting — but THEIR addon instance can see THEIR
-- own casts perfectly. Solution: each addon broadcasts its own casts over
-- the addon channel; receivers feed them into Brain as if locally observed.
--
-- Wire format (semicolon-delimited):
--   U;<spellID>;<duration>[;<charges>;<chargesMax>]   - cast announcement
--   S;<specID>                                         - spec announcement
--   I                                                  - "I just landed an interrupt"
--   T;<nodeID,nodeID,...>                              - talent node IDs (future)
-- Receivers tolerate missing trailing fields (back-compat).
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

local function send(msg)
    if not enabled() or not IsInGroup() then return end
    -- Defensive: never broadcast a value that's secret-tagged.
    if GBI.Taint and GBI.Taint.IsSecret and GBI.Taint.IsSecret(msg) then return end
    local channel = IsInRaid() and "RAID" or "PARTY"
    return C_ChatInfo.SendAddonMessage(PREFIX, msg, channel)
end

function M.Broadcast(spellID, duration, charges, chargesMax)
    if type(spellID) ~= "number" or type(duration) ~= "number" then return end
    local msg
    if type(charges) == "number" and type(chargesMax) == "number" then
        msg = ("U;%d;%d;%d;%d"):format(spellID, duration, charges, chargesMax)
    else
        msg = ("U;%d;%d"):format(spellID, duration)
    end
    log("Debug", "send %s", msg)
    return send(msg)
end

function M.BroadcastSpec(specID)
    if type(specID) ~= "number" then return end
    log("Debug", "send S;%d", specID)
    return send(("S;%d"):format(specID))
end

function M.BroadcastInterrupt()
    log("Debug", "send I")
    return send("I")
end

-- "Cooldown delta" — used when a CD's remaining time shrinks mid-flight
-- (e.g. Devourer DH Metamorphosis reduced by ability usage). spellID +
-- the new remaining seconds.
function M.BroadcastDelta(spellID, remaining)
    if type(spellID) ~= "number" or type(remaining) ~= "number" then return end
    log("Debug", "send D;%d;%.1f", spellID, remaining)
    return send(("D;%d;%.1f"):format(spellID, remaining))
end

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_CommFrame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("CHAT_MSG_ADDON")

local function announceSpec()
    local s = GetSpecialization and GetSpecialization()
    if type(s) == "number" and s > 0 then M.BroadcastSpec(s) end
end
f:SetScript("OnEvent", function(_, event, prefix, msg, channel, sender)
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        end
        return
    end
    if event == "PLAYER_ENTERING_WORLD"
       or event == "PLAYER_SPECIALIZATION_CHANGED"
       or event == "GROUP_ROSTER_UPDATE" then
        -- Re-announce on these so late joiners learn our spec.
        C_Timer.After(1.5, announceSpec)
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

    local parts = { strsplit(";", msg or "") }
    local mt = parts[1]
    local unit = senderToUnit(sender)
    if not unit then
        log("Debug", "  drop: senderToUnit nil for %s", tostring(sender)); return
    end

    if mt == "U" then
        local sid = tonumber(parts[2]); local dur = tonumber(parts[3])
        local ch  = tonumber(parts[4]); local chMax = tonumber(parts[5])
        if not sid or not dur then return end
        local cd = GBI.GetCooldown and GBI.GetCooldown(sid)
        if not cd then return end
        log("Debug", "recv U %s -> %s spell=%d dur=%d ch=%s/%s",
            sender, unit, sid, dur, tostring(ch), tostring(chMax))
        if GBI.Brain and GBI.Brain.OnCast then
            local cdCopy = cd
            if ch and chMax then
                cdCopy = { name = cd.name, duration = cd.duration, class = cd.class,
                    category = cd.category, charges = ch, chargesMax = chMax }
            end
            GBI.Brain.OnCast(unit, sid, cdCopy)
        end
    elseif mt == "S" then
        local specID = tonumber(parts[2])
        if not specID then return end
        log("Debug", "recv S %s -> %s spec=%d", sender, unit, specID)
        if GBI.Inspect and GBI.Inspect.SetSpecForUnit then
            GBI.Inspect.SetSpecForUnit(unit, specID)
        end
    elseif mt == "I" then
        log("Debug", "recv I %s -> %s (interrupt)", sender, unit)
        if GBI.KickCounter and GBI.KickCounter.AttributePeer then
            GBI.KickCounter.AttributePeer(unit)
        end
    elseif mt == "D" then
        local sid = tonumber(parts[2]); local rem = tonumber(parts[3])
        if not sid or not rem then return end
        log("Debug", "recv D %s -> %s spell=%d rem=%.1f", sender, unit, sid, rem)
        if GBI.Brain and GBI.Brain.UpdateRemaining then
            GBI.Brain.UpdateRemaining(unit, sid, rem)
        end
    elseif mt == "T" then
        local idsStr = parts[2] or ""
        local set = {}
        for idStr in idsStr:gmatch("[^,]+") do
            local n = tonumber(idStr)
            if n then set[n] = true end
        end
        log("Debug", "recv T %s -> %s (%d nodes)", sender, unit, (function()
            local c = 0; for _ in pairs(set) do c = c + 1 end; return c end)())
        if GBI.TalentSync and GBI.TalentSync.SetTalents then
            GBI.TalentSync.SetTalents(unit, set)
        end
    else
        log("Debug", "  drop: unknown msgType=%s", tostring(mt))
    end
end)
