-- /gbi and /gobig slash dispatcher.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K

local function say(msg) print("|cff66ddffGBI|r " .. tostring(msg)) end

local function help()
    say("commands:")
    print("  /gbi              - status")
    print("  /gbi config       - open config UI")
    print("  /gbi overlay      - toggle CDs on party frames")
    print("  /gbi kicks        - print interrupt count this run")
    print("  /gbi kicks reset  - clear the interrupt counter")
    print("  /gbi on | off     - master enable")
    print("  /gbi debug        - toggle debug logging")
    print("  /gbi rescan       - re-queue party inspect")
    print("  /gbi reset        - clear CD state + bar")
    print("  /gbi lock         - lock/unlock anchor drag")
    print("  /gbi showalways   - toggle 'engine on outside dungeons'")
    print("  /gbi log [N]      - dump last N log lines (default 50)")
    print("  /gbi log clear    - wipe log buffer")
    print("  /gbi test ready   - simulate cd_ready sound")
    print("  /gbi test cast    - simulate cd_cast sound")
    print("  /gbi test interrupt - simulate interrupt-alert sound")
    print("  /gbi int on|off          - toggle interrupt-halfway alert")
    print("  /gbi int delay <s>       - alert delay from cast start (default 0.2)")
    print("  /gbi sound <trigger> off|rotate|random|specific <file>")
    print("           trigger: ready | interrupt    (cast is gone)")
    print("  /gbi preview <file.ogg>  - play a sound file directly")
    print("  /gbi list                - show all-ready spell list")
    print("  /gbi list add <spellID>  - add spell to all-ready trigger list")
    print("  /gbi list remove <spellID>")
    print("  /gbi list clear")
end

local function dispatch(msg)
    GOBIGnINTERRUPTDB = GOBIGnINTERRUPTDB or {}
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "" or msg == "status" then
        local db = GOBIGnINTERRUPTDB
        say(("enabled=%s  debug=%s  locked=%s  showAlways=%s  context=%s"):format(
            tostring(db.enabled), tostring(db.debug),
            tostring(db.locked), tostring(db.showAlways),
            tostring(db.contextCurrent)))
        return
    end

    if msg == "on" then
        GOBIGnINTERRUPTDB.enabled = true; say("ON")
        if GBI.App then GBI.App.UpdateContext() end
        return
    end
    if msg == "off" then
        GOBIGnINTERRUPTDB.enabled = false; say("OFF")
        -- Route through App.UpdateContext so engineEnabled in Bar.lua is
        -- updated authoritatively. Calling Bar.Hide() directly leaves the
        -- gate stale and lets a later RefreshLayout / option toggle re-show.
        if GBI.App and GBI.App.UpdateContext then GBI.App.UpdateContext()
        elseif GBI.Bar and GBI.Bar.SetEnabled then GBI.Bar.SetEnabled(false) end
        return
    end
    if msg == "debug" then
        GOBIGnINTERRUPTDB.debug = not GOBIGnINTERRUPTDB.debug
        say("debug = " .. tostring(GOBIGnINTERRUPTDB.debug))
        return
    end
    if msg == "rescan" then
        if GBI.Inspect and GBI.Inspect.RescanParty then GBI.Inspect.RescanParty() end
        say("rescan queued")
        return
    end
    if msg == "reset" then
        if GBI.App then GBI.App.Reset() end
        say("reset")
        return
    end
    if msg == "lock" then
        GOBIGnINTERRUPTDB.locked = not GOBIGnINTERRUPTDB.locked
        say("locked = " .. tostring(GOBIGnINTERRUPTDB.locked))
        if GBI.Bar and GBI.Bar.RefreshLocked then GBI.Bar.RefreshLocked() end
        return
    end
    if msg == "showalways" then
        GOBIGnINTERRUPTDB.showAlways = not GOBIGnINTERRUPTDB.showAlways
        say("showAlways = " .. tostring(GOBIGnINTERRUPTDB.showAlways))
        if GBI.App then GBI.App.UpdateContext() end
        return
    end

    -- /gbi log [N]   /gbi log clear
    local logTail = msg:match("^log%s+(%S+)$")
    if msg == "log" or logTail then
        if logTail == "clear" then
            if GBI.Log then GBI.Log.Clear() end
            say("log cleared")
        else
            local n = tonumber(logTail) or 50
            if GBI.Log then GBI.Log.Dump(n) end
        end
        return
    end

    -- /gbi int ...
    local intRest = msg:match("^int%s+(.+)$")
    if intRest then
        GOBIGnINTERRUPTDB.interrupt = GOBIGnINTERRUPTDB.interrupt or {}
        local cfg = GOBIGnINTERRUPTDB.interrupt
        if intRest == "on"  then cfg.enabled = true;  say("interrupt alert ON");  return end
        if intRest == "off" then cfg.enabled = false; say("interrupt alert OFF"); return end
        local s = tonumber(intRest:match("^delay%s+([%d%.]+)$"))
                or tonumber(intRest:match("^fixed%s+([%d%.]+)$"))
        if s and s > 0 then
            cfg.seconds = s
            say(("delay = %.2fs from cast start"):format(s)); return
        end
        say("usage: /gbi int on | off | delay <seconds>")
        return
    end

    -- /gbi test <which>   - plays through SoundPipeline (respects mode = off)
    -- /gbi preview <file>  - plays a specific filename, ignores mode
    local target = msg:match("^test%s+(%S+)$")
    if target then
        local map = {
            ready     = K.SOUND_CAT_CD_READY,
            cast      = K.SOUND_CAT_CD_CAST,
            interrupt = K.SOUND_CAT_INTERRUPT_ALERT,
        }
        local cat = map[target]
        if not cat then say("unknown test target: " .. target); return end
        if GBI.SoundPipeline then GBI.SoundPipeline.Fire(cat, { test = true }) end
        if target == "interrupt" and GBI.Bar and GBI.Bar.TestInterruptFill then
            GBI.Bar.TestInterruptFill(15)
        end
        say("fired " .. cat .. " (silent if mode=off)")
        return
    end
    local previewFile = msg:match("^preview%s+(%S+)$")
    if previewFile then
        if GBI.SoundPipeline and GBI.SoundPipeline.Preview then
            local ok = GBI.SoundPipeline.Preview(previewFile)
            say(ok and ("played " .. previewFile) or ("FAILED to play " .. previewFile))
        end
        return
    end

    -- /gbi list ...
    if msg == "list" or msg == "list show" then
        local list = GOBIGnINTERRUPTDB.allReadyList or {}
        if #list == 0 then say("all-ready list is empty"); return end
        say(("all-ready list (%d spells):"):format(#list))
        for _, sid in ipairs(list) do
            local cd = GBI.GetCooldown and GBI.GetCooldown(sid)
            local lbl = cd and cd.name or ("spell " .. sid)
            local active = (GBI.Brain and GBI.Brain.GetInFlight(sid) or 0)
            print(("  %d  %s  %s"):format(sid, lbl, active > 0 and "(ON CD)" or "(ready)"))
        end
        return
    end
    do
        local addID = msg:match("^list%s+add%s+(%d+)$")
        if addID then
            local sid = tonumber(addID)
            GOBIGnINTERRUPTDB.allReadyList = GOBIGnINTERRUPTDB.allReadyList or {}
            for _, e in ipairs(GOBIGnINTERRUPTDB.allReadyList) do
                if e == sid then say(sid .. " already in list"); return end
            end
            table.insert(GOBIGnINTERRUPTDB.allReadyList, sid)
            local cd = GBI.GetCooldown and GBI.GetCooldown(sid)
            say(("added %d (%s)"):format(sid, cd and cd.name or "unknown spell"))
            return
        end
        local rmID = msg:match("^list%s+remove%s+(%d+)$") or msg:match("^list%s+rm%s+(%d+)$")
        if rmID then
            local sid = tonumber(rmID)
            local list = GOBIGnINTERRUPTDB.allReadyList or {}
            for i, e in ipairs(list) do
                if e == sid then
                    table.remove(list, i); say("removed " .. sid); return
                end
            end
            say(sid .. " not in list")
            return
        end
        if msg == "list clear" then
            GOBIGnINTERRUPTDB.allReadyList = {}
            say("all-ready list cleared")
            return
        end
    end

    -- /gbi sound <trigger> <mode>     - off | specific <file> | rotate | random
    local triggerName, soundRest = msg:match("^sound%s+(%S+)%s+(.+)$")
    if triggerName then
        local triggerMap = {
            ready = K.SOUND_CAT_CD_READY,
            cast  = K.SOUND_CAT_CD_CAST,
            interrupt = K.SOUND_CAT_INTERRUPT_ALERT,
            interrupts = K.SOUND_CAT_INTERRUPT_ALERT,
        }
        local cat = triggerMap[triggerName]
        if not cat then
            say("trigger must be one of: ready / cast / interrupt"); return
        end
        GOBIGnINTERRUPTDB.sound = GOBIGnINTERRUPTDB.sound or {}
        GOBIGnINTERRUPTDB.sound[cat] = GOBIGnINTERRUPTDB.sound[cat] or {}
        local cfg = GOBIGnINTERRUPTDB.sound[cat]
        if soundRest == "off" then
            cfg.mode = "off"; say(cat .. " mode = off")
        elseif soundRest == "rotate" then
            cfg.mode = "rotate"; cfg.rotateIdx = 0; say(cat .. " mode = rotate")
        elseif soundRest == "random" then
            cfg.mode = "random"; say(cat .. " mode = random")
        else
            local file = soundRest:match("^specific%s+(.+)$") or soundRest
            cfg.mode = "specific"; cfg.file = file
            say(cat .. " mode = specific (" .. file .. ")")
        end
        return
    end

    if msg == "config" or msg == "options" or msg == "ui" then
        if _G.GBI_OpenConfig then _G.GBI_OpenConfig() else say("config UI not loaded") end
        return
    end

    if msg == "kicks" then
        if GBI.KickCounter and GBI.KickCounter.Print then GBI.KickCounter.Print() end
        return
    end

    if msg == "peers" then
        if not (GBI.CDComm and GBI.CDComm.DumpPeerPresence) then
            say("comm not loaded"); return
        end
        local d = GBI.CDComm.DumpPeerPresence()
        if d.lastQueryAt == 0 then
            say("Q never sent (peer presence: unknown for everyone)")
        else
            say(("last Q: %.1fs ago  (grace: 5s)"):format(d.secsSinceQuery or -1))
        end
        if #d.peers == 0 then
            print("  (no party members detected)")
        end
        for _, p in ipairs(d.peers) do
            local label
            if p.hasAddon == true then
                label = "|cff66ff66HAS GBI|r"
                    .. (p.secsAgo and (" (last msg %.1fs ago)"):format(p.secsAgo) or "")
            elseif p.hasAddon == false then
                label = "|cffff3030NO GBI|r (would show \"?\" badge)"
            else
                label = "|cffaaaaaaUNKNOWN|r (still in grace)"
            end
            print(("  %s [%s]  %s"):format(p.name, p.unit, label))
        end
        return
    end
    if msg == "kicks reset" then
        if GBI.KickCounter and GBI.KickCounter.Reset then GBI.KickCounter.Reset() end
        say("kick counter reset"); return
    end

    if msg == "overlay" then
        GOBIGnINTERRUPTDB.unitOverlay = GOBIGnINTERRUPTDB.unitOverlay or {}
        GOBIGnINTERRUPTDB.show = GOBIGnINTERRUPTDB.show or {}
        local cur = GOBIGnINTERRUPTDB.show.cooldownsMode or "bar"
        GOBIGnINTERRUPTDB.show.cooldownsMode = (cur == "overlay") and "bar" or "overlay"
        local nowOverlay = GOBIGnINTERRUPTDB.show.cooldownsMode == "overlay"
        say("CDs on party frames = " .. tostring(nowOverlay))
        if GBI.Bar and GBI.Bar.RefreshLayout then GBI.Bar.RefreshLayout() end
        return
    end

    if msg == "help" or msg == "?" then help(); return end
    say("unknown command. /gbi help")
end

-- WoW normalizes the slash-key to uppercase internally; lowercase letters in
-- the SlashCmdList key cause "Unknown command". Use all-caps GBIROOT.
SLASH_GBIROOT1 = "/gbi"
SLASH_GBIROOT2 = "/gobig"
SlashCmdList["GBIROOT"] = dispatch
