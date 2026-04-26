-- Addon entry. Owns the lifecycle:
--   ADDON_LOADED            - init savedvars
--   PLAYER_ENTERING_WORLD   - figure out context (M+ vs not), enable/disable engine
--   ZONE_CHANGED_NEW_AREA   - re-eval context
--
-- "Engine enabled" means the Bar is shown and CDs from CastTracker fire normally.
-- In open world / raid we hide everything to keep the screen clean.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.App = GBI.App or {}
local App = GBI.App

local addonName = ...

local function log(level, ...) if GBI.Log then GBI.Log[level]("app", ...) end end

local DEFAULTS = {
    enabled         = true,            -- master on/off
    debug           = false,
    locked          = false,           -- when true, anchor cannot be dragged
    showAlways      = false,           -- if true, ignore context check
    contextCurrent  = "unknown",       -- diagnostic
    sound           = {},              -- per-trigger config (see SoundPipeline)
    allReadyList    = {},              -- spellIDs whose simultaneous-ready
                                       -- transition fires the cd_ready sound.
                                       -- Populate via /gbi list add <spellID>.
    unitOverlay     = { enabled = false }, -- when true, CDs draw on party frames
                                            -- and the cooldown bar window hides.
    burst           = { mode = "auto" },   -- burst-ready trigger source:
                                            -- auto | manual | both (see Brain.lua)
}

local SCHEMA_VERSION = 4

local function migrate()
    local db = GOBIGnINTERRUPTDB
    if not db then return end
    local from = db.schemaVersion or 1
    if from < 2 then
        if db.sound then
            for _, key in ipairs({ "cd_cast", "cd_ready" }) do
                if db.sound[key] and db.sound[key].mode == "rotate" then
                    db.sound[key].mode = "off"
                end
            end
        end
    end
    if from < 3 then
        -- v2 -> v3: interrupt-alert default delay dropped from 1.0 s -> 0.2 s.
        -- Migrate users still on the old default; leave explicit user values alone.
        if db.interrupt and db.interrupt.seconds == 1.0 then
            db.interrupt.seconds = 0.2
        end
    end
    if from < 4 then
        -- v3 -> v4: bar split into two anchors. Migrate the old single
        -- `bar` position to the cooldown anchor; interrupt anchor uses default.
        if db.bar then
            db.bars = db.bars or {}
            db.bars.cooldowns = db.bar
            db.bar = nil
        end
        db.unitOverlay = db.unitOverlay or { enabled = false }
    end
    db.schemaVersion = SCHEMA_VERSION
end

local function ensureDB()
    GOBIGnINTERRUPTDB = GOBIGnINTERRUPTDB or {}
    for k, v in pairs(DEFAULTS) do
        if GOBIGnINTERRUPTDB[k] == nil then
            -- shallow copy for tables, otherwise direct assignment
            if type(v) == "table" then GOBIGnINTERRUPTDB[k] = {} else GOBIGnINTERRUPTDB[k] = v end
        end
    end
    GOBIGnINTERRUPTDB.sound = GOBIGnINTERRUPTDB.sound or {}
end

-- Context detection.
-- Returns one of: "mythicplus", "party", "raid", "arena", "world", "battleground"
local function detectContext()
    local inInstance, kind = IsInInstance()
    if not inInstance then return "world" end
    if kind == "raid" then return "raid" end
    if kind == "arena" then return "arena" end
    if kind == "pvp" then return "battleground" end
    if kind == "party" then
        -- Differentiate Mythic+ from regular dungeon via difficulty ID.
        local diff = select(3, GetInstanceInfo()) or 0
        if K.M_PLUS_DIFFICULTIES[diff] then return "mythicplus" end
        return "party"
    end
    return "unknown"
end

-- Decide whether the engine should be on.
local function shouldEnable(context)
    if not GOBIGnINTERRUPTDB.enabled then return false end
    if GOBIGnINTERRUPTDB.showAlways then return true end
    return context == "mythicplus" or context == "party"
end

function App.UpdateContext()
    local ctx = detectContext()
    GOBIGnINTERRUPTDB.contextCurrent = ctx
    local on = shouldEnable(ctx)
    log("Info", "context=%s engine=%s", ctx, on and "ON" or "OFF")
    if GBI.Bar and GBI.Bar.SetEnabled then GBI.Bar.SetEnabled(on) end
    if on then
        if GBI.Inspect and GBI.Inspect.RescanParty then
            C_Timer.After(1.0, function() GBI.Inspect.RescanParty() end)
        end
    else
        if GBI.Brain and GBI.Brain.Reset then GBI.Brain.Reset() end
    end
end

function App.Reset()
    if GBI.Brain and GBI.Brain.Reset then GBI.Brain.Reset() end
    if GBI.Bar and GBI.Bar.Reset then GBI.Bar.Reset() end
end

local f = CreateFrame("Frame", "GOBIGnINTERRUPT_AppFrame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("CHALLENGE_MODE_START")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        ensureDB()
        migrate()
        log("Info", "loaded v%s", GetAddOnMetadata and GetAddOnMetadata(addonName, "Version") or "?")
    elseif event == "PLAYER_ENTERING_WORLD" then
        ensureDB()
        C_Timer.After(0.5, App.UpdateContext)
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "CHALLENGE_MODE_START" then
        C_Timer.After(0.5, App.UpdateContext)
    end
end)
