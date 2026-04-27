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
            c.container:SetSize(MAX_ICONS * (sz + ICON_GAP()), sz)
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

    -- Build (or rebuild on host change).
    if c and c.container then c.container:Hide(); c.container:SetParent(nil) end

    local container = CreateFrame("Frame", nil, host)
    container:SetSize(MAX_ICONS * (ICON_SIZE() + ICON_GAP()), ICON_SIZE())
    container:SetFrameStrata("HIGH")
    container:Show()
    M.ApplyAnchor(container, host)
    log("Info", "container built unit=%s host=%s", unit, host:GetName() or "?")

    c = { container = container, host = host, icons = {} }
    containers[unit] = c
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
    table.sort(shown, function(a, b) return (a.endsAt or 0) < (b.endsAt or 0) end)
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

function M.OnCDStart(unit, spellID, state)
    if not visible then
        log("Debug", "OnCDStart visible=false (overlay hidden) unit=%s spell=%d", unit, spellID); return
    end
    local c = ensureContainer(unit)
    if not c then
        log("Info", "OnCDStart no host frame for unit=%s spell=%d", unit, spellID); return
    end
    local entry = getIconEntry(c)
    if not entry then
        log("Info", "OnCDStart no free icon (max=%d) unit=%s", MAX_ICONS, unit); return
    end
    log("Debug", "OnCDStart unit=%s spell=%d host=%s",
        unit, spellID, c.host:GetName() or "?")
    entry.spellID = spellID
    entry.endsAt  = state.endsAt
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    entry.icon.tex:SetTexture((info and info.iconID) or "Interface\\Icons\\INV_Misc_QuestionMark")
    entry.cooldown:SetCooldown(state.startedAt, state.endsAt - state.startedAt)
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
    for _, unit in ipairs(K.PARTY_UNITS) do ensureContainer(unit) end
end

function M.Hide()
    visible = false
    for _, c in pairs(containers) do
        if c.container then c.container:Hide() end
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
rf:SetScript("OnEvent", function()
    if not visible then return end
    for _, unit in ipairs(K.PARTY_UNITS) do
        if UnitExists(unit) then ensureContainer(unit) end
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

    local now = GetTime()
    for _, c in pairs(containers) do
        for _, e in ipairs(c.icons) do
            if e.icon:IsShown() and e.endsAt and e.endsAt <= now then
                -- Keep icon visible, glow to indicate spell is ready.
                if not e.glowing and _G.ActionButton_ShowOverlayGlow then
                    pcall(_G.ActionButton_ShowOverlayGlow, e.icon)
                    e.glowing = true
                end
            elseif e.glowing and e.endsAt and e.endsAt > now then
                if _G.ActionButton_HideOverlayGlow then
                    pcall(_G.ActionButton_HideOverlayGlow, e.icon)
                end
                e.glowing = false
            end
        end
        relayout(c)
    end
end)
