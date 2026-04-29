-- Shared constants. Pure data, no behaviour.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.K = GBI.K or {}
local K = GBI.K

-- Unit token sets ---------------------------------------------------------

K.PARTY_UNITS  = { "player", "party1", "party2", "party3", "party4" }
K.PARTY_OTHERS = { "party1", "party2", "party3", "party4" }      -- excl. player
K.BOSS_UNITS   = { "boss1", "boss2", "boss3", "boss4", "boss5" }
K.NAMEPLATE_MAX = 40                                              -- nameplate1..40

K.PARTY_UNITS_SET = {}
for _, u in ipairs(K.PARTY_UNITS) do K.PARTY_UNITS_SET[u] = true end

-- CD categories -----------------------------------------------------------

K.CAT_INTERRUPT = "interrupt"
K.CAT_BIGCD     = "bigcd"
K.CAT_DEFENSIVE = "defensive"
K.CAT_OFFENSIVE = "offensive"
K.CAT_DISPEL    = "dispel"
K.CAT_UTILITY   = "utility"

K.ALL_CATEGORIES = {
    K.CAT_INTERRUPT, K.CAT_BIGCD, K.CAT_DEFENSIVE,
    K.CAT_OFFENSIVE, K.CAT_DISPEL, K.CAT_UTILITY,
}

-- Membership helper: is this category eligible for the cooldown bar /
-- unit overlay? Everything except CAT_INTERRUPT (which has its own
-- progress-bar window). The Spell DB UI's per-spell checkboxes are the
-- granularity users curate; a coarse category filter here would silently
-- override their explicit choices — e.g. ticking Leg Sweep (UTILITY) or
-- a dispel had no effect because the bar refused the category.
function K.IsCooldownBarCategory(cat)
    return cat ~= nil and cat ~= K.CAT_INTERRUPT
end

-- Sound trigger categories (match Sounds.lua tagging) ---------------------

K.SOUND_CAT_INTERRUPT_ALERT = "interrupts"
K.SOUND_CAT_CD_CAST         = "cd_cast"
K.SOUND_CAT_CD_READY        = "cd_ready"

-- Mythic+ instance difficulty IDs.
-- See https://warcraft.wiki.gg/wiki/DifficultyID. 8 = Mythic Keystone.
K.M_PLUS_DIFFICULTIES = { [8] = true, [23] = true }   -- 23 = Mythic 5-man (legacy)

-- Class tokens (uppercase, English; from UnitClass second return) ---------
K.CLASS_TOKENS = {
    "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER", "MAGE",
    "MONK", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}

-- Throttle defaults -------------------------------------------------------

K.INSPECT_THROTTLE_S        = 1.5    -- between NotifyInspect calls (API limit)
K.INSPECT_TIMEOUT_S         = 5.0    -- give up on a unit if INSPECT_READY hasn't fired
K.INSPECT_RETRIES           = 3
K.BRAIN_DEDUP_S             = 0.25   -- collapse same-spellID-same-unit within this window
K.SOUND_THROTTLE_S          = 0.5    -- min gap between any two sounds
