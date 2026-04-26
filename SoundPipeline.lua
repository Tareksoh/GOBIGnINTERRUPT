-- Routes sound triggers to PlaySoundFile, with per-trigger mode:
--   "off"        — silent
--   "specific"   — single file from the trigger's tagged category
--   "rotate"     — round-robin through every sound tagged with the category
--   "random"     — uniform random with one-step no-repeat
--
-- SavedVariables:
--   GOBIGnINTERRUPTDB.sound[trigger] = {
--       mode = "off"|"specific"|"rotate"|"random",
--       file = "filename.ogg",   -- used when mode == "specific"
--       rotateIdx = N,           -- pointer for rotate mode (0 = next is index 1)
--       lastRandom = "filename"  -- one-step no-repeat memory
--   }
-- Trigger keys are the K.SOUND_CAT_* constants ("interrupts", "cd_cast", "cd_ready").
--
-- Public API:
--   GBI.SoundPipeline.Fire(category, ctx) - play (or skip) the sound for that trigger.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.SoundPipeline = GBI.SoundPipeline or {}
local M = GBI.SoundPipeline

local THROTTLE = K.SOUND_THROTTLE_S
local lastFiredAt = 0

local function log(level, ...) if GBI.Log then GBI.Log[level]("sound", ...) end end

-- Default mode per trigger:
--   interrupts -> "rotate" (the marquee feature; audible by default)
--   cd_cast    -> "off"    (party-CD chatter; user can /gbi sound cast rotate)
--   cd_ready   -> "off"    (likewise)
local DEFAULT_MODE = {
    interrupts = "rotate",
    cd_cast    = "off",
    cd_ready   = "off",
}

local function ensureCfg(category)
    GOBIGnINTERRUPTDB = GOBIGnINTERRUPTDB or {}
    GOBIGnINTERRUPTDB.sound = GOBIGnINTERRUPTDB.sound or {}
    local s = GOBIGnINTERRUPTDB.sound
    s[category] = s[category] or {
        mode       = DEFAULT_MODE[category] or "off",
        file       = nil,
        rotateIdx  = 0,
        lastRandom = nil,
    }
    return s[category]
end

local function play(filename)
    if not filename or filename == "" then return false end
    return PlaySoundFile(GBI.Sounds.PATH .. filename, "Master")
end

local function pickSpecific(cfg)
    return cfg.file
end

local function pickRotate(cfg, category)
    local pool = GBI.Sounds.ForCategory(category)
    if #pool == 0 then return nil end
    cfg.rotateIdx = (cfg.rotateIdx or 0) + 1
    if cfg.rotateIdx > #pool then cfg.rotateIdx = 1 end
    return pool[cfg.rotateIdx].file
end

local function pickRandom(cfg, category)
    local pool = GBI.Sounds.ForCategory(category)
    if #pool == 0 then return nil end
    if #pool == 1 then return pool[1].file end
    -- One-step no-repeat: pick a random index, retry if same as last.
    local picked
    for _ = 1, 4 do
        local idx = math.random(1, #pool)
        picked = pool[idx].file
        if picked ~= cfg.lastRandom then break end
    end
    cfg.lastRandom = picked
    return picked
end

function M.Fire(category, ctx)
    if not category then return end
    if not GOBIGnINTERRUPTDB or not GOBIGnINTERRUPTDB.enabled then return end

    -- global throttle (prevents triple-fire chaos)
    local now = GetTime()
    if (now - lastFiredAt) < THROTTLE then return end

    local cfg = ensureCfg(category)
    if cfg.mode == "off" then return end

    local filename
    if cfg.mode == "specific" then filename = pickSpecific(cfg)
    elseif cfg.mode == "rotate" then filename = pickRotate(cfg, category)
    elseif cfg.mode == "random" then filename = pickRandom(cfg, category)
    end

    if not filename then
        log("Debug", "no file picked for %s mode=%s", category, cfg.mode)
        return
    end

    local ok = play(filename)
    if ok then
        lastFiredAt = now
        log("Debug", "fired %s: %s", category, filename)
    else
        log("Warn", "PlaySoundFile failed for %s: %s", category, filename)
    end
end

-- For Options panel preview: play a specific filename without altering rotate/random state.
function M.Preview(filename) return play(filename) end
