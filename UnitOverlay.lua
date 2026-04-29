-- Cooldown icons anchored to each party member's unit frame (OmniCD-style).
-- Active only when DB.unitOverlay.enabled is true; the cooldown bar window
-- hides itself when this is on.
--
-- Anchor strategy (per unit):
--   try CompactPartyFrameMember<n>  (Edit-mode raid-style party frames, default in TWW)
--   then PartyMemberFrame<n>        (legacy party frames)
--   for the player: PlayerFrame
--   if none exist yet, defer until PLAYER_ENTERING_WORLD / GROUP_ROSTER_UPDATE.
--
-- These are friendly Blizzard frames; reading _G[name] is a clean operation
-- (not in a hostile-unit code path), no taint concerns.
--
-- Public API mirrors Bar's instance signature so Bar.lua can dispatch:
--   GBI.UnitOverlay.OnCDStart(unit, spellID, state)
--   GBI.UnitOverlay.OnCDReady(unit, spellID, state)
--   GBI.UnitOverlay.Show() / Hide() / Reset()

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.UnitOverlay = GBI.UnitOverlay or {}
local M = GBI.UnitOverlay

local MAX_ICONS = 6

local function ICON_SIZE()
    local d = (GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.unitOverlay) or {}
    return d.iconSize or 28
end

local function ICON_GAP()
    local d = (GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.unitOverlay) or {}
    return d.iconGap or 2
end

local function log(level, ...) if GBI.Log then GBI.Log[level]("overlay", ...) end end

-- containers[unit] = { container = Frame, icons = { entry, ... } }
local containers = {}
local visible = false

-- Anchor configuration: read from DB.unitOverlay.{side,offsetX,offsetY}.
-- side: BOTTOM | TOP | LEFT | RIGHT (relative to host unit frame)
local function anchorCfg()
    local d = (GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.unitOverlay) or {}
    return d.side or "BOTTOM", d.offsetX or 0, d.offsetY or -2
end

local SIDE_TABLE = {
    -- side -> { containerPoint, hostPoint }
    BOTTOM = { "TOPLEFT",     "BOTTOMLEFT" },
    TOP    = { "BOTTOMLEFT",  "TOPLEFT"    },
    LEFT   = { "RIGHT",       "LEFT"       },
    RIGHT  = { "LEFT",        "RIGHT"      },
}

function M.ApplyAnchor(container, host)
    local side, ox, oy = anchorCfg()
    local pts = SIDE_TABLE[side] or SIDE_TABLE.BOTTOM
    container:ClearAllPoints()
    container:SetPoint(pts[1], host, pts[2], ox, oy)
end

function M.Refresh()
    local sz = ICON_SIZE()
    for _, c in pairs(containers) do
        if c.container and c.host then
            c.container:SetSize((MAX_ICONS * sz + (MAX_ICONS - 1) * ICON_GAP()), sz)
            for _, e in ipairs(c.icons) do e.icon:SetSize(sz, sz) end
            for _, e in ipairs(c.testIcons or {}) do e.icon:SetSize(sz, sz) end
            M.ApplyAnchor(c.container, c.host)
            if M._relayout then M._relayout(c) end
        end
    end
end

local function unitIndex(unit)
    if unit == "player" then return 0 end
    return tonumber(unit:match("^party(%d)$")) or nil
end

local function visibleOrNil(f)
    if f and f:IsVisible() then return f end
    return nil
end

-- Compact frame indices are by sort order (role/spec), NOT unit token.
-- Always match by the frame's `.unit` attribute, never by trailing number.
local function findHostFrame(unit)
    if unit == "player" then
        -- CompactPartyFrame includes the player when "Show Player" is on; try
        -- to find a compact frame bound to "player" first, else PlayerFrame.
        for i = 1, 5 do
            local f = _G["CompactPartyFrameMember" .. i]
            if f and f.unit == "player" and f:IsVisible() then return f end
        end
        for i = 1, 5 do
            local f = _G["CompactRaidFrame" .. i]
            if f and f.unit == "player" and f:IsVisible() then return f end
        end
        return visibleOrNil(_G.PlayerFrame)
    end

    -- Party slot: scan CompactPartyFrameMember1..5 + CompactRaidFrame1..5
    -- + PartyMemberFrame1..4, return whichever has matching .unit.
    for i = 1, 5 do
        local f = _G["CompactPartyFrameMember" .. i]
        if f and f.unit == unit and f:IsVisible() then return f end
    end
    for i = 1, 5 do
        local f = _G["CompactRaidFrame" .. i]
        if f and f.unit == unit and f:IsVisible() then return f end
    end
    for i = 1, 4 do
        local f = _G["PartyMemberFrame" .. i]
        if f and f.unit == unit and f:IsVisible() then return f end
    end
    return nil
end

local function ensureContainer(unit)
    local c = containers[unit]
    local host = findHostFrame(unit)
    if not host then return nil end

    -- Rebind if host changed OR if the host's unit attribute no longer
    -- matches our unit token (compact frames re-sort on roster updates).
    if c and c.container and c.host == host and host.unit == unit then
        c.container:Show()
        return c
    end

    -- Rebuild path (host changed or first build).
    --
    -- IMPORTANT: preserve the existing `c.icons` list across the rebuild.
    -- Compact party frames can re-sort on roster updates, INSPECT_READY,
    -- PLAYER_SPECIALIZATION_CHANGED, etc., which trips the rebind. The
    -- old behavior was to wipe `c.icons` on rebuild — that erased every
    -- live cooldown's state AND every placeholder until the next M.Show()
    -- repopulated, which manifested as the overlay flickering empty and
    -- live cooldowns "forgetting" they were on CD.
    --
    -- Instead, save the icon list, build a new container/tagFrame parented
    -- to the new host, then reparent each existing icon onto the new
    -- container. State (spellID, endsAt, placeholder, charges, ...) lives
    -- on the entry table, not the parent, so reparenting preserves it.
    local oldIcons = (c and c.icons) or {}

    if c and c.container then c.container:Hide(); c.container:SetParent(nil) end
    if c and c.noAddonTag then c.noAddonTag:Hide(); c.noAddonTag:SetParent(nil) end

    local container = CreateFrame("Frame", nil, host)
    container:SetSize((MAX_ICONS * ICON_SIZE() + (MAX_ICONS - 1) * ICON_GAP()), ICON_SIZE())
    container:SetFrameStrata("HIGH")
    container:Show()
    M.ApplyAnchor(container, host)
    log("Info", "container built unit=%s host=%s preservedIcons=%d",
        unit, host:GetName() or "?", #oldIcons)

    -- "No addon" badge: red "?" anchored INSIDE the host frame, offset
    -- RIGHT from the TOPLEFT corner by half an icon width so it clears
    -- the leader-crown / portrait area without sitting too far in.
    -- TOPRIGHT is already taken by Blizzard's role icon. Visible when
    -- CDComm.PeerHasAddon returns false for this unit.
    local tagFrame = CreateFrame("Frame", nil, host)
    tagFrame:SetSize(18, 18)
    tagFrame:SetPoint("TOPLEFT", host, "TOPLEFT", ICON_SIZE() / 2, -2)
    tagFrame:SetFrameStrata("HIGH")
    tagFrame:SetFrameLevel((host:GetFrameLevel() or 1) + 8)
    local plate = tagFrame:CreateTexture(nil, "BACKGROUND")
    plate:SetAllPoints(tagFrame)
    plate:SetColorTexture(0, 0, 0, 0.6)
    local tag = tagFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tag:SetPoint("CENTER", tagFrame, "CENTER", 0, 0)
    tag:SetText("|cffff3030?|r")
    tag:SetDrawLayer("OVERLAY", 7)
    tagFrame:Hide()

    -- Reparent every existing icon onto the new container so live state
    -- and placeholders both survive the rebind. Cooldown frames are
    -- children of the icon, so they ride along; defensively re-stamp
    -- SetCooldown for entries with an active endsAt in case the reparent
    -- reset the swipe.
    local nowT = GetTime()
    for _, e in ipairs(oldIcons) do
        if e.icon then
            e.icon:SetParent(container)
            e.icon:ClearAllPoints()
            e.icon:SetFrameStrata("HIGH")
            e.icon:SetFrameLevel((container:GetFrameLevel() or 1) + 5)
            if e.cooldown and type(e.endsAt) == "number" and e.endsAt > nowT then
                e.cooldown:SetCooldown(nowT, e.endsAt - nowT)
            end
        end
    end

    c = { container = container, host = host, icons = oldIcons, noAddonTag = tagFrame }
    containers[unit] = c
    -- Position the reparented icons; relayout reads c.icons.
    if M._relayout then M._relayout(c) end
    return c
end

local function getIconEntry(c)
    for _, e in ipairs(c.icons) do
        if not e.icon:IsShown() then return e end
    end
    if #c.icons >= MAX_ICONS then return nil end
    local icon = CreateFrame("Frame", nil, c.container)
    icon:SetSize(ICON_SIZE(), ICON_SIZE())
    icon:SetFrameStrata("HIGH")
    icon:SetFrameLevel((c.container:GetFrameLevel() or 1) + 5)
    local t = icon:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints(icon)
    icon.tex = t
    local cd = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate"); cd:SetAllPoints(icon)
    cd:SetDrawSwipe(true)
    cd:SetHideCountdownNumbers(false)
    icon.cooldown = cd
    local entry = { icon = icon, cooldown = cd, spellID = nil, endsAt = nil }
    table.insert(c.icons, entry)
    return entry
end

-- Layout direction: icons grow OUTWARD from the unit frame.
--   side BOTTOM -> container below frame, icons stack horizontally; first
--                  icon anchored TOPLEFT (under frame's left edge), grows right
--   side TOP    -> container above frame; first icon BOTTOMLEFT, grows right
--   side LEFT   -> container left of frame; first icon RIGHT-side of container
--                  (closest to frame), additional icons extend LEFTWARD
--   side RIGHT  -> container right of frame; first icon LEFT-side, grows right
local function relayout(c)
    local shown = {}
    for _, e in ipairs(c.icons) do
        if e.icon:IsShown() then shown[#shown + 1] = e end
    end
    table.sort(shown, GBI.MakeIconSort and GBI.MakeIconSort(
        GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.cdSort or "endsAt"
    ) or function(a, b) return (a.endsAt or 0) < (b.endsAt or 0) end)
    local side = (anchorCfg())   -- first return = side
    for i, e in ipairs(shown) do
        e.icon:ClearAllPoints()
        if side == "LEFT" then
            e.icon:SetPoint("RIGHT", c.container, "RIGHT",
                -(i - 1) * (ICON_SIZE() + ICON_GAP()), 0)
        elseif side == "TOP" then
            e.icon:SetPoint("BOTTOMLEFT", c.container, "BOTTOMLEFT",
                (i - 1) * (ICON_SIZE() + ICON_GAP()), 0)
        else  -- BOTTOM or RIGHT: anchor LEFT, grow rightward
            e.icon:SetPoint("LEFT", c.container, "LEFT",
                (i - 1) * (ICON_SIZE() + ICON_GAP()), 0)
        end
    end
end
M._relayout = relayout

-- Public ---------------------------------------------------------------

-- Spec-aware placeholder pre-population: dim icons for every CD a unit
-- could use, regardless of whether it's been observed yet.
function M.PopulatePlaceholders(unit)
    if not GBI.SpellsForUnit then return end
    local c = ensureContainer(unit)
    if not c then return end

    local placeholdersOn = GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.placeholders
        and GOBIGnINTERRUPTDB.placeholders.enabled ~= false

    -- Prune any icon whose spell isn't in the expected set (spec changed
    -- or user disabled it). Placeholders also hide when feature is off.
    local expected = {}
    for _, e in ipairs(GBI.SpellsForUnit(unit)) do expected[e.sid] = true end
    for _, x in ipairs(c.icons) do
        if x.spellID and (not expected[x.spellID]
            or (x.placeholder and not placeholdersOn)) then
            x.icon:Hide()
            x.spellID = nil       -- free the slot for reuse
            x.endsAt = nil
            x.placeholder = false
        end
    end

    if not placeholdersOn then return end

    for _, e in ipairs(GBI.SpellsForUnit(unit)) do
        local cd = e.cd
        if K.IsCooldownBarCategory(cd.category) then
            local exists
            for _, x in ipairs(c.icons) do
                if x.spellID == e.sid then exists = x; break end
            end
            if not exists then
                local entry = getIconEntry(c)
                if entry then
                    entry.spellID = e.sid
                    entry.endsAt = nil
                    entry.placeholder = true
                    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(e.sid)
                    entry.icon.tex:SetTexture(info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
                    -- Placeholders render normal (no dim/desaturate).
                    entry.icon:Show()
                end
            end
        end
    end
    if M._relayout then M._relayout(c) end
end

function M.OnCDStart(unit, spellID, state)
    if not visible then
        log("Debug", "OnCDStart visible=false (overlay hidden) unit=%s spell=%d", unit, spellID); return
    end
    local c = ensureContainer(unit)
    if not c then
        log("Info", "OnCDStart no host frame for unit=%s spell=%d", unit, spellID); return
    end
    -- Reuse placeholder/live entry for the same spell, else allocate.
    local entry
    for _, e in ipairs(c.icons) do
        if e.spellID == spellID then entry = e; break end
    end
    if not entry then
        entry = getIconEntry(c)
        if not entry then
            log("Info", "OnCDStart no free icon (max=%d) unit=%s", MAX_ICONS, unit); return
        end
    end
    log("Debug", "OnCDStart unit=%s spell=%d host=%s",
        unit, spellID, c.host:GetName() or "?")
    entry.spellID = spellID
    entry.endsAt  = state.endsAt
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    entry.icon.tex:SetTexture((info and info.iconID) or "Interface\\Icons\\INV_Misc_QuestionMark")
    if entry.placeholder then
        entry.placeholder = false
        entry.icon:SetAlpha(1.0)
        entry.icon.tex:SetDesaturated(false)
    end
    if state.stackCount ~= nil then
        entry.cooldown:SetCooldown(0, 0)
        if state.stackCount >= (state.stackThreshold or 1) then
            if _G.ActionButton_ShowOverlayGlow and not entry.glowing then
                pcall(_G.ActionButton_ShowOverlayGlow, entry.icon); entry.glowing = true
            end
        elseif entry.glowing and _G.ActionButton_HideOverlayGlow then
            pcall(_G.ActionButton_HideOverlayGlow, entry.icon); entry.glowing = false
        end
    else
        -- Pass (now, remaining) instead of (startedAt, fullDuration) so the
        -- swipe always works even when startedAt is in the past (back-calc
        -- from Evidence's aura.expirationTime). Blizzard's Cooldown frame
        -- has been observed mis-handling past start times in 12.0.5,
        -- showing the swipe complete at half the actual remaining time.
        local nowT = GetTime()
        local rem = state.endsAt - nowT
        if rem > 0 then
            entry.cooldown:SetCooldown(nowT, rem)
        else
            entry.cooldown:SetCooldown(0, 0)
        end
    end
    -- Stack/charge overlay (stacks take priority over charges).
    local n, total
    if state.stackCount then
        n, total = state.stackCount, state.stackThreshold
    elseif state.charges and state.chargesMax and state.chargesMax > 1 then
        n, total = state.charges, state.chargesMax
    end
    if n and total then
        if not entry.chargeText then
            entry.chargeText = entry.icon:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
            entry.chargeText:SetPoint("BOTTOMRIGHT", entry.icon, "BOTTOMRIGHT", -1, 1)
        end
        entry.chargeText:SetText(("%d/%d"):format(n, total))
        entry.chargeText:Show()
    elseif entry.chargeText then
        entry.chargeText:Hide()
    end
    entry.icon:Show()
    relayout(c)
end

function M.OnCDReady(unit, spellID)
    local c = containers[unit]
    if not c then return end
    -- Keep the icon for the run; ticker will glow it once ready.
    for _, e in ipairs(c.icons) do
        if e.spellID == spellID then e.endsAt = GetTime() - 0.01; break end
    end
    relayout(c)
end

function M.Show()
    visible = true
    for _, unit in ipairs(K.PARTY_UNITS) do
        ensureContainer(unit)
        if M.PopulatePlaceholders then M.PopulatePlaceholders(unit) end
    end
end

function M.Hide()
    visible = false
    for _, c in pairs(containers) do
        if c.container then c.container:Hide() end
        if c.noAddonTag then c.noAddonTag:Hide() end
    end
end

function M.Reset()
    for _, c in pairs(containers) do
        for _, e in ipairs(c.icons) do e.icon:Hide() end
    end
end

-- Test mode: translucent background + 5 placeholder icons on every container,
-- so the user can position the anchor offsets without needing real casts.
local testMode = false

local function applyTestVisuals(c, on)
    if on then
        if not c.testBG then
            local t = c.container:CreateTexture(nil, "BACKGROUND")
            t:SetAllPoints(c.container); t:SetColorTexture(0, 1, 0, 0.25)
            c.testBG = t
        else c.testBG:Show() end
        c.testIcons = c.testIcons or {}
        for i = 1, 5 do
            local entry = c.testIcons[i]
            if not entry then
                local icon = CreateFrame("Frame", nil, c.container)
                icon:SetSize(ICON_SIZE(), ICON_SIZE())
                icon:SetFrameStrata("HIGH")
                icon:SetFrameLevel((c.container:GetFrameLevel() or 1) + 5)
                local tex = icon:CreateTexture(nil, "ARTWORK"); tex:SetAllPoints(icon)
                tex:SetTexture("Interface\\Icons\\spell_fire_selfdestruct")
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                entry = { icon = icon, tex = tex }
                c.testIcons[i] = entry
            end
            entry.icon:ClearAllPoints()
            local side = (anchorCfg())
            if side == "LEFT" then
                entry.icon:SetPoint("RIGHT", c.container, "RIGHT",
                    -(i - 1) * (ICON_SIZE() + ICON_GAP()), 0)
            elseif side == "TOP" then
                entry.icon:SetPoint("BOTTOMLEFT", c.container, "BOTTOMLEFT",
                    (i - 1) * (ICON_SIZE() + ICON_GAP()), 0)
            else
                entry.icon:SetPoint("LEFT", c.container, "LEFT",
                    (i - 1) * (ICON_SIZE() + ICON_GAP()), 0)
            end
            entry.icon:Show()
        end
    else
        if c.testBG then c.testBG:Hide() end
        for _, e in ipairs(c.testIcons or {}) do e.icon:Hide() end
    end
end

function M.SetTestMode(on)
    testMode = on and true or false
    if testMode then
        for _, unit in ipairs(K.PARTY_UNITS) do
            if UnitExists(unit) then ensureContainer(unit) end
        end
    end
    for _, c in pairs(containers) do applyTestVisuals(c, testMode) end
end

function M.IsTestMode() return testMode end

-- Re-bind containers when the host frame disappears/changes (compact <-> legacy).
local rf = CreateFrame("Frame")
rf:RegisterEvent("GROUP_ROSTER_UPDATE")
rf:RegisterEvent("PLAYER_ENTERING_WORLD")
rf:RegisterEvent("RAID_ROSTER_UPDATE")
rf:RegisterEvent("INSPECT_READY")
rf:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
rf:SetScript("OnEvent", function()
    if not visible then return end
    for _, unit in ipairs(K.PARTY_UNITS) do
        if UnitExists(unit) then
            ensureContainer(unit)
            if M.PopulatePlaceholders then M.PopulatePlaceholders(unit) end
        end
    end
end)

local tk = CreateFrame("Frame")
tk:SetScript("OnUpdate", function(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < 0.5 then return end
    self.acc = 0

    -- Retry container build for units whose host frame wasn't ready earlier.
    if visible then
        for _, unit in ipairs(K.PARTY_UNITS) do
            if UnitExists(unit) then ensureContainer(unit) end
        end
    end

    -- Refresh the red "?" no-addon badge for each container.
    if visible and GBI.CDComm and GBI.CDComm.PeerHasAddon then
        for unit, c in pairs(containers) do
            if c.noAddonTag then
                local has = GBI.CDComm.PeerHasAddon(unit)
                if UnitExists(unit) and has == false then
                    c.noAddonTag:Show()
                else
                    c.noAddonTag:Hide()
                end
            end
        end
    end

    local now = GetTime()
    for _, c in pairs(containers) do
        for _, e in ipairs(c.icons) do
            -- Once observed, icons stay bright + visible. No glow on ready,
            -- no re-dim — only placeholders are dim (alpha 0.4 + desaturated)
            -- and they un-dim permanently on first OnCDStart.
            if e.glowing and _G.ActionButton_HideOverlayGlow then
                pcall(_G.ActionButton_HideOverlayGlow, e.icon)
                e.glowing = false
            end
        end
        relayout(c)
    end
end)
