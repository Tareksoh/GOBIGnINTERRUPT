-- Player interrupt spell IDs per class / spec.
-- Used by Interrupt.lua (Phase 1.5) to know which spell's cooldown to check
-- before firing the halfway alert.
--
-- spec key is the integer GetSpecialization() returns (1..4 for current
-- specs). nil entry means "no interrupt" (Disc/Holy priest).

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT

-- Schema: Interrupts[CLASS_TOKEN] = { default = id, [specIndex] = id }
-- - default is used when spec is unknown.
-- - per-spec entries override.
GBI.Interrupts = {
    DEATHKNIGHT  = { default = 47528 },                            -- Mind Freeze (all specs)
    DEMONHUNTER  = { default = 183752 },                           -- Disrupt (all specs)
    DRUID        = { default = 106839, [1] = 78675, [4] = 106839 }, -- 1=Balance Solar Beam; 4=Resto fallback to Skull Bash via shapeshift; Feral/Guardian use 106839
    EVOKER       = { default = 351338 },                           -- Quell
    HUNTER       = { default = 147362, [3] = 187707 },             -- Counter Shot; 3=Survival Muzzle
    MAGE         = { default = 2139 },                             -- Counterspell
    MONK         = { default = 116705 },                           -- Spear Hand Strike
    PALADIN      = { default = 96231 },                            -- Rebuke
    PRIEST       = { [3] = 15487 },                                -- Silence (Shadow only); Disc/Holy = nil
    ROGUE        = { default = 1766 },                             -- Kick
    SHAMAN       = { default = 57994 },                            -- Wind Shear
    WARLOCK      = { default = 119910 },                           -- Spell Lock (Felhunter pet)
    WARRIOR      = { default = 6552 },                             -- Pummel
}

-- Resolve the interrupt spellID for the *player*. Returns spellID or nil.
function GBI.Interrupts.ForPlayer()
    local _, classToken = UnitClass("player")
    if not classToken then return nil end
    local entry = GBI.Interrupts[classToken]
    if not entry then return nil end
    local spec = GetSpecialization and GetSpecialization()
    if spec and entry[spec] then return entry[spec] end
    return entry.default
end
