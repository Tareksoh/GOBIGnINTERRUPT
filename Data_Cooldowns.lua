-- M+ party cooldown database. Phase 1 curated subset (~120 entries) — the
-- most-tracked CDs across the 13 classes. Add/edit liberally.
--
-- Schema:
--   GBI.Cooldowns[spellID] = {
--       name     = "Display name",
--       duration = <seconds>,
--       class    = "WARRIOR" | ...,
--       category = K.CAT_INTERRUPT | K.CAT_DEFENSIVE | K.CAT_BIGCD |
--                  K.CAT_OFFENSIVE | K.CAT_DISPEL | K.CAT_UTILITY,
--       spec     = nil  -> all specs of the class can use it
--                | {1,2,...} -> only those spec indices (GetSpecialization())
--   }
--
-- Spec IDs follow GetSpecialization() return: 1..4. See:
--   https://warcraft.wiki.gg/wiki/SpecializationID
-- Notes are inline so a maintainer can verify against Wowhead.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K

GBI.Cooldowns = {

-- ========================= INTERRUPTS (one per class, dual where speced) ===

[47528]  = { name = "Mind Freeze",         duration = 15, class = "DEATHKNIGHT", category = K.CAT_INTERRUPT },
[183752] = { name = "Disrupt",             duration = 15, class = "DEMONHUNTER", category = K.CAT_INTERRUPT },
[106839] = { name = "Skull Bash",          duration = 15, class = "DRUID",       category = K.CAT_INTERRUPT, spec = {2,3} },
[78675]  = { name = "Solar Beam",          duration = 60, class = "DRUID",       category = K.CAT_INTERRUPT, spec = {1} },
[351338] = { name = "Quell",               duration = 20, class = "EVOKER",      category = K.CAT_INTERRUPT },  -- OmniReborn
[147362] = { name = "Counter Shot",        duration = 24, class = "HUNTER",      category = K.CAT_INTERRUPT, spec = {1,2} },
[187707] = { name = "Muzzle",              duration = 24, class = "HUNTER",      category = K.CAT_INTERRUPT, spec = {3} },  -- OmniReborn
[2139]   = { name = "Counterspell",        duration = 24, class = "MAGE",        category = K.CAT_INTERRUPT },
[116705] = { name = "Spear Hand Strike",   duration = 15, class = "MONK",        category = K.CAT_INTERRUPT },
[96231]  = { name = "Rebuke",              duration = 15, class = "PALADIN",     category = K.CAT_INTERRUPT },
[15487]  = { name = "Silence",             duration = 45, class = "PRIEST",      category = K.CAT_INTERRUPT, spec = {3} },
[1766]   = { name = "Kick",                duration = 15, class = "ROGUE",       category = K.CAT_INTERRUPT },
[57994]  = { name = "Wind Shear",          duration = 12, class = "SHAMAN",      category = K.CAT_INTERRUPT },
[119910] = { name = "Spell Lock",          duration = 24, class = "WARLOCK",     category = K.CAT_INTERRUPT },
[6552]   = { name = "Pummel",              duration = 15, class = "WARRIOR",     category = K.CAT_INTERRUPT },

-- ========================= BIG DPS COOLDOWNS ===============================

[107574] = { name = "Avatar",              duration = 90, class = "WARRIOR",     category = K.CAT_BIGCD, spec = {1,2} },
[1719]   = { name = "Recklessness",        duration = 90, class = "WARRIOR",     category = K.CAT_BIGCD, spec = {2} },
[31884]  = { name = "Avenging Wrath",      duration = 120, class = "PALADIN",    category = K.CAT_BIGCD },
[231895] = { name = "Crusade",             duration = 120, class = "PALADIN",    category = K.CAT_BIGCD, spec = {3} },
[255937] = { name = "Wake of Ashes",       duration = 30, class = "PALADIN",     category = K.CAT_BIGCD, spec = {3} },
[288613] = { name = "Trueshot",            duration = 120, class = "HUNTER",     category = K.CAT_BIGCD, spec = {2} },
[19574]  = { name = "Bestial Wrath",       duration = 30, class = "HUNTER",      category = K.CAT_BIGCD, spec = {1} },  -- 12.0.5 BM redesign: static 30s (ORB's 90 is stale)
[360952] = { name = "Coordinated Assault", duration = 120, class = "HUNTER",     category = K.CAT_BIGCD, spec = {3} },
[121471] = { name = "Shadow Blades",       duration = 90, class = "ROGUE",       category = K.CAT_BIGCD, spec = {3} },  -- MiniCC (talented)
[13750]  = { name = "Adrenaline Rush",     duration = 180, class = "ROGUE",      category = K.CAT_BIGCD, spec = {2} },
[10060]  = { name = "Power Infusion",      duration = 120, class = "PRIEST",     category = K.CAT_BIGCD },
[228260] = { name = "Void Eruption",       duration = 120, class = "PRIEST",     category = K.CAT_BIGCD, spec = {3} },  -- MiniCC
[51271]  = { name = "Pillar of Frost",     duration = 45, class = "DEATHKNIGHT", category = K.CAT_BIGCD, spec = {2} },  -- MiniCC (talented)
[42650]  = { name = "Army of the Dead",    duration = 180, class = "DEATHKNIGHT",category = K.CAT_BIGCD, spec = {3} },
[275699] = { name = "Apocalypse",          duration = 75, class = "DEATHKNIGHT", category = K.CAT_BIGCD, spec = {3} },  -- not in ORB, kept base
[114050] = { name = "Ascendance (Ele)",    duration = 180, class = "SHAMAN",     category = K.CAT_BIGCD, spec = {1} },
[114051] = { name = "Ascendance (Enh)",    duration = 180, class = "SHAMAN",     category = K.CAT_BIGCD, spec = {2} },
[191634] = { name = "Stormkeeper",         duration = 60, class = "SHAMAN",      category = K.CAT_BIGCD, spec = {1} },
[190319] = { name = "Combustion",          duration = 120, class = "MAGE",       category = K.CAT_BIGCD, spec = {2} },  -- OmniReborn base
[12472]  = { name = "Icy Veins",           duration = 180, class = "MAGE",       category = K.CAT_BIGCD, spec = {3} },  -- OmniReborn
[365350] = { name = "Arcane Surge",        duration = 90, class = "MAGE",        category = K.CAT_BIGCD, spec = {1} },
[265187] = { name = "Demonic Tyrant",      duration = 90, class = "WARLOCK",     category = K.CAT_BIGCD, spec = {2} },  -- OmniReborn
[386997] = { name = "Soul Rot",            duration = 60, class = "WARLOCK",     category = K.CAT_BIGCD, spec = {1} },
[137639] = { name = "Storm, Earth & Fire", duration = 90, class = "MONK",        category = K.CAT_BIGCD, spec = {3} },
[152173] = { name = "Serenity",            duration = 90, class = "MONK",        category = K.CAT_BIGCD, spec = {3} },
[123904] = { name = "Invoke Xuen",         duration = 120, class = "MONK",       category = K.CAT_BIGCD, spec = {3} },
[322109] = { name = "Touch of Death",      duration = 180, class = "MONK",       category = K.CAT_BIGCD },
[391528] = { name = "Convoke the Spirits", duration = 120, class = "DRUID",      category = K.CAT_BIGCD },
[106951] = { name = "Berserk",             duration = 180, class = "DRUID",      category = K.CAT_BIGCD, spec = {2} },  -- OmniReborn base
[194223] = { name = "Celestial Alignment", duration = 180, class = "DRUID",      category = K.CAT_BIGCD, spec = {1} },
[191427] = { name = "Metamorphosis (Hav)", duration = 180, class = "DEMONHUNTER",category = K.CAT_BIGCD, spec = {1} },  -- OmniReborn base
[370965] = { name = "The Hunt",            duration = 90, class = "DEMONHUNTER", category = K.CAT_BIGCD },
[375087] = { name = "Dragonrage",          duration = 120, class = "EVOKER",     category = K.CAT_BIGCD, spec = {1} },
[359073] = { name = "Eternity Surge",      duration = 30, class = "EVOKER",      category = K.CAT_BIGCD, spec = {1} },
[403631] = { name = "Breath of Eons",      duration = 120, class = "EVOKER",     category = K.CAT_BIGCD, spec = {3} },

-- ========================= KEY DEFENSIVES ==================================

[871]    = { name = "Shield Wall",         duration = 180, class = "WARRIOR",    category = K.CAT_DEFENSIVE, spec = {3} },  -- OmniReborn
[12975]  = { name = "Last Stand",          duration = 180, class = "WARRIOR",    category = K.CAT_DEFENSIVE, spec = {3} },
[97462]  = { name = "Rallying Cry",        duration = 180, class = "WARRIOR",    category = K.CAT_DEFENSIVE },
[23920]  = { name = "Spell Reflection",    duration = 25, class = "WARRIOR",     category = K.CAT_DEFENSIVE },
[642]    = { name = "Divine Shield",       duration = 300, class = "PALADIN",    category = K.CAT_DEFENSIVE },
[31850]  = { name = "Ardent Defender",     duration = 90, class = "PALADIN",     category = K.CAT_DEFENSIVE, spec = {2} },  -- OmniReborn
[86659]  = { name = "Guardian of Ancient Kings", duration = 180, class = "PALADIN", category = K.CAT_DEFENSIVE, spec = {2} },  -- MiniCC
[498]    = { name = "Divine Protection",   duration = 60, class = "PALADIN",     category = K.CAT_DEFENSIVE },
[633]    = { name = "Lay on Hands",        duration = 600, class = "PALADIN",    category = K.CAT_DEFENSIVE },
[186265] = { name = "Aspect of the Turtle",duration = 180, class = "HUNTER",     category = K.CAT_DEFENSIVE },
[264735] = { name = "Survival of the Fittest", duration = 90, class = "HUNTER",  category = K.CAT_DEFENSIVE },  -- OmniReborn
[31224]  = { name = "Cloak of Shadows",    duration = 120, class = "ROGUE",      category = K.CAT_DEFENSIVE },  -- MiniCC
[5277]   = { name = "Evasion",             duration = 120, class = "ROGUE",      category = K.CAT_DEFENSIVE },  -- MiniCC
[1856]   = { name = "Vanish",              duration = 120, class = "ROGUE",      category = K.CAT_DEFENSIVE },
[33206]  = { name = "Pain Suppression",    duration = 180, class = "PRIEST",     category = K.CAT_DEFENSIVE, spec = {1} },
[62618]  = { name = "Power Word: Barrier", duration = 180, class = "PRIEST",     category = K.CAT_DEFENSIVE, spec = {1} },
[47585]  = { name = "Dispersion",          duration = 120, class = "PRIEST",     category = K.CAT_DEFENSIVE, spec = {3} },
[19236]  = { name = "Desperate Prayer",    duration = 90, class = "PRIEST",      category = K.CAT_DEFENSIVE },
[48792]  = { name = "Icebound Fortitude",  duration = 120, class = "DEATHKNIGHT",category = K.CAT_DEFENSIVE },  -- MiniCC
[48707]  = { name = "Anti-Magic Shell",    duration = 60, class = "DEATHKNIGHT", category = K.CAT_DEFENSIVE },
[55233]  = { name = "Vampiric Blood",      duration = 90, class = "DEATHKNIGHT", category = K.CAT_DEFENSIVE, spec = {1} },  -- MiniCC
[108271] = { name = "Astral Shift",        duration = 120, class = "SHAMAN",     category = K.CAT_DEFENSIVE },  -- MiniCC
[45438]  = { name = "Ice Block",           duration = 240, class = "MAGE",       category = K.CAT_DEFENSIVE },
[55342]  = { name = "Mirror Image",        duration = 120, class = "MAGE",       category = K.CAT_DEFENSIVE },
[110959] = { name = "Greater Invisibility",duration = 120, class = "MAGE",       category = K.CAT_DEFENSIVE, spec = {1} },
[110909] = { name = "Alter Time",          duration = 60, class = "MAGE",        category = K.CAT_DEFENSIVE },
[104773] = { name = "Unending Resolve",    duration = 180, class = "WARLOCK",    category = K.CAT_DEFENSIVE },
[108416] = { name = "Dark Pact",           duration = 60, class = "WARLOCK",     category = K.CAT_DEFENSIVE },
[122783] = { name = "Diffuse Magic",       duration = 90, class = "MONK",        category = K.CAT_DEFENSIVE },
[122470] = { name = "Touch of Karma",      duration = 90, class = "MONK",        category = K.CAT_DEFENSIVE, spec = {3} },
[115203] = { name = "Fortifying Brew",     duration = 120, class = "MONK",       category = K.CAT_DEFENSIVE },  -- MiniCC (WW/MW; BrM is 360 baseline)
[22812]  = { name = "Barkskin",            duration = 60, class = "DRUID",       category = K.CAT_DEFENSIVE },
[61336]  = { name = "Survival Instincts",  duration = 180, class = "DRUID",      category = K.CAT_DEFENSIVE },  -- OmniReborn
[198589] = { name = "Blur",                duration = 60, class = "DEMONHUNTER", category = K.CAT_DEFENSIVE, spec = {1} },
[196718] = { name = "Darkness",            duration = 300, class = "DEMONHUNTER",category = K.CAT_DEFENSIVE },
[196555] = { name = "Netherwalk",          duration = 180, class = "DEMONHUNTER",category = K.CAT_DEFENSIVE, spec = {1} },
[363916] = { name = "Obsidian Scales",     duration = 90, class = "EVOKER",      category = K.CAT_DEFENSIVE },  -- OmniReborn
[374348] = { name = "Renewing Blaze",      duration = 90, class = "EVOKER",      category = K.CAT_DEFENSIVE },

-- ========================= UTILITY (Heroism, Combat Rez, Immune, Mass Dispel) =

[32182]  = { name = "Heroism",             duration = 600, class = "SHAMAN",     category = K.CAT_UTILITY },
[2825]   = { name = "Bloodlust",           duration = 600, class = "SHAMAN",     category = K.CAT_UTILITY },
[80353]  = { name = "Time Warp",           duration = 300, class = "MAGE",       category = K.CAT_UTILITY },  -- OmniReborn
[264667] = { name = "Primal Rage",         duration = 360, class = "HUNTER",     category = K.CAT_UTILITY },
[20484]  = { name = "Rebirth",             duration = 600, class = "DRUID",      category = K.CAT_UTILITY },
[20707]  = { name = "Soulstone",           duration = 600, class = "WARLOCK",    category = K.CAT_UTILITY },
[20608]  = { name = "Reincarnation",       duration = 600, class = "SHAMAN",     category = K.CAT_UTILITY },
[32375]  = { name = "Mass Dispel",         duration = 45, class = "PRIEST",      category = K.CAT_DISPEL },
[527]    = { name = "Purify",              duration = 8,  class = "PRIEST",      category = K.CAT_DISPEL },
[88423]  = { name = "Nature's Cure",       duration = 8,  class = "DRUID",       category = K.CAT_DISPEL },
[2782]   = { name = "Remove Corruption",   duration = 8,  class = "DRUID",       category = K.CAT_DISPEL },
[51886]  = { name = "Cleanse Spirit",      duration = 8,  class = "SHAMAN",      category = K.CAT_DISPEL },
[77130]  = { name = "Purify Spirit",       duration = 8,  class = "SHAMAN",      category = K.CAT_DISPEL },
[4987]   = { name = "Cleanse",             duration = 8,  class = "PALADIN",     category = K.CAT_DISPEL },
[115450] = { name = "Detox",               duration = 8,  class = "MONK",        category = K.CAT_DISPEL },
[218164] = { name = "Detox (Brewmaster)",  duration = 8,  class = "MONK",        category = K.CAT_DISPEL, spec = {1} },
[475] =    { name = "Remove Curse",        duration = 8,  class = "MAGE",        category = K.CAT_DISPEL },
[527]   = nil,  -- (de-dup; already above)

[192058] = { name = "Capacitor Totem",     duration = 60, class = "SHAMAN",      category = K.CAT_UTILITY },
[207684] = { name = "Sigil of Misery",     duration = 90, class = "DEMONHUNTER",category = K.CAT_UTILITY, spec = {2} },
[1022]   = { name = "Blessing of Protection", duration = 300, class = "PALADIN",category = K.CAT_UTILITY },
[6940]   = { name = "Blessing of Sacrifice",  duration = 120, class = "PALADIN",category = K.CAT_UTILITY, spec = {1} },
[1044]   = { name = "Blessing of Freedom", duration = 25, class = "PALADIN",    category = K.CAT_UTILITY },

-- ========================= ADDED FROM InterruptTrack ========================

[204021] = { name = "Fiery Brand",         duration = 60,  class = "DEMONHUNTER",category = K.CAT_DEFENSIVE, spec = {2} },
[187827] = { name = "Metamorphosis (Veng)",duration = 120, class = "DEMONHUNTER",category = K.CAT_DEFENSIVE, spec = {2} },
[209258] = { name = "Last Resort",         duration = 480, class = "DEMONHUNTER",category = K.CAT_DEFENSIVE, spec = {2} },
[50334]  = { name = "Berserk (Guardian)",  duration = 180, class = "DRUID",      category = K.CAT_DEFENSIVE, spec = {3} },
[102342] = { name = "Ironbark",            duration = 90,  class = "DRUID",      category = K.CAT_DEFENSIVE, spec = {4} },
[357170] = { name = "Time Dilation",       duration = 60,  class = "EVOKER",     category = K.CAT_DEFENSIVE, spec = {2} },
[1250646]= { name = "Takedown",            duration = 90,  class = "HUNTER",     category = K.CAT_BIGCD,     spec = {3} },
[132578] = { name = "Invoke Niuzao",       duration = 120, class = "MONK",       category = K.CAT_BIGCD,     spec = {1} },
[116849] = { name = "Life Cocoon",         duration = 120, class = "MONK",       category = K.CAT_DEFENSIVE, spec = {3} },
[64843]  = { name = "Divine Hymn",         duration = 180, class = "PRIEST",     category = K.CAT_DEFENSIVE, spec = {2} },
[47788]  = { name = "Guardian Spirit",     duration = 180, class = "PRIEST",     category = K.CAT_DEFENSIVE, spec = {2} },
[185313] = { name = "Shadow Dance",        duration = 20,  class = "ROGUE",      category = K.CAT_BIGCD,     spec = {3} },
[114052] = { name = "Ascendance (Resto)",  duration = 180, class = "SHAMAN",     category = K.CAT_DEFENSIVE, spec = {3} },
[118038] = { name = "Die by the Sword",    duration = 120, class = "WARRIOR",    category = K.CAT_DEFENSIVE, spec = {1} },
[184364] = { name = "Enraged Regeneration",duration = 120, class = "WARRIOR",    category = K.CAT_DEFENSIVE, spec = {2} },

-- Additional commonly-tracked CDs not in either source
[216331] = { name = "Avenging Crusader",   duration = 60,  class = "PALADIN",    category = K.CAT_BIGCD,     spec = {1} },
[342245] = { name = "Alter Time",          duration = 50,  class = "MAGE",       category = K.CAT_DEFENSIVE },
[414659] = { name = "Ice Cold",            duration = 240, class = "MAGE",       category = K.CAT_DEFENSIVE },
[204018] = { name = "Blessing of Spellwarding", duration = 180, class = "PALADIN",category = K.CAT_DEFENSIVE, spec = {2} },
[119914] = { name = "Axe Toss",            duration = 24,  class = "WARLOCK",    category = K.CAT_INTERRUPT, spec = {2} },

}

-- Flat lookup helper. Given a spellID (already laundered via Taint.SafeSpellID),
-- returns the entry table or nil.
function GBI.GetCooldown(spellID)
    if type(spellID) ~= "number" then return nil end
    -- User overrides: disabled list wins, then custom list, then built-in.
    local sdb = GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.spellDb
    if sdb then
        if sdb.disabled and sdb.disabled[spellID] then return nil end
        if sdb.custom and sdb.custom[spellID] then return sdb.custom[spellID] end
    end
    -- spellID may be secret-tagged from remote-PC party UNIT_SPELLCAST events;
    -- pcall the index so a tainted key misses cleanly instead of throwing.
    local ok, cd = pcall(function() return GBI.Cooldowns[spellID] end)
    if not ok then return nil end
    return cd
end

-- All tracked CDs available to a given unit (class + spec match).
-- Permissive on unknown spec.
function GBI.SpellsForUnit(unit)
    local out = {}
    if not unit or not UnitExists(unit) then return out end
    local _, classToken = UnitClass(unit)
    if not classToken then return out end
    local guid = GBI.Taint and GBI.Taint.SafeGUID and GBI.Taint.SafeGUID(unit)
    local spec = guid and GBI.Inspect and GBI.Inspect.GetSpecByGUID
        and GBI.Inspect.GetSpecByGUID(guid) or nil
    local entries = GBI.IterCooldowns and GBI.IterCooldowns() or GBI.Cooldowns or {}
    for sid, cd in pairs(entries) do
        if cd and cd.class == classToken then
            local specOK = true
            if cd.spec and spec then
                specOK = false
                for _, s in ipairs(cd.spec) do
                    if s == spec then specOK = true; break end
                end
            end
            if specOK then out[#out + 1] = { sid = sid, cd = cd } end
        end
    end
    return out
end

-- Iterate all entries (built-in + custom). Caller filters by class etc.
function GBI.IterCooldowns()
    local merged = {}
    for sid, cd in pairs(GBI.Cooldowns) do merged[sid] = cd end
    local sdb = GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.spellDb
    if sdb and sdb.custom then
        for sid, cd in pairs(sdb.custom) do merged[sid] = cd end
    end
    return merged
end
