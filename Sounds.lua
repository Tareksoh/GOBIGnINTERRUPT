-- Shared SoundLibrary global (same convention as relax8r8r). Every entry is
-- {filename : str -> { categories = {...}, label = "..." }}.
--
-- Categories used by GOBIGnINTERRUPT (Constants.lua):
--   "interrupts" — fired by interrupt-halfway alert (Phase 1.5)
--   "cd_cast"    — fired when a tracked party CD is cast    (Phase 2)
--   "cd_ready"   — fired when a tracked party CD comes off cooldown (Phase 1)
--
-- A single .ogg file can be tagged with multiple categories.
--
-- The library is intentionally a SHARED global named `SoundLibrary` (not
-- prefixed by addon name) so the same files / metadata can be reused across
-- relax8r8r and GOBIGnINTERRUPT. Both addons read the same global; whichever
-- loads first creates it.

SoundLibrary = SoundLibrary or {}
SoundLibrary.library = SoundLibrary.library or {}

-- Default seed: a placeholder sound that ships with the addon. Friends can
-- drop more .ogg into sounds/ and add entries here (or via the relax8r8r
-- converter tool).
if not SoundLibrary.library["ad3s.ogg"] then
    SoundLibrary.library["ad3s.ogg"] = {
        categories = { "cd_ready", "cd_cast" },
        label = "AD3S",
    }
end
if not SoundLibrary.library["just_kick.ogg"] then
    SoundLibrary.library["just_kick.ogg"] = {
        categories = { "interrupts" },
        label = "Just kick",
    }
end

-- Helper for the rest of the addon (mirrors relax8r8r's GetSoundsForCategory).
GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.Sounds = GBI.Sounds or {}

-- Returns array of { file, label } sorted by label.
function GBI.Sounds.ForCategory(category)
    local out = {}
    for filename, meta in pairs(SoundLibrary.library) do
        for _, c in ipairs(meta.categories or {}) do
            if c == category then
                out[#out + 1] = { file = filename, label = meta.label or filename }
                break
            end
        end
    end
    table.sort(out, function(a, b) return (a.label or a.file) < (b.label or b.file) end)
    return out
end

-- Where the addon expects sound files on disk. Callers prepend this to the
-- filename to build the PlaySoundFile path.
GBI.Sounds.PATH = "Interface\\AddOns\\GOBIGnINTERRUPT\\sounds\\"
