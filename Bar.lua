-- Two parallel bar windows:
--   * BarInterrupts  - icons for K.CAT_INTERRUPT spells only
--   * BarCooldowns   - everything else (defensives, big CDs, utility, dispel)
--
-- Each window has its own draggable anchor and saved position
-- (DB.bars.interrupts / DB.bars.cooldowns).
--
-- Cooldown window is hidden when DB.unitOverlay.enabled is true; the
-- UnitOverlay module then draws the cooldown icons on top of party frames.
-- Interrupt window is always shown when the engine is enabled.
--
-- Public API (back-compat with Brain.lua):
--   GBI.Bar.OnCDStart(unit, spellID, state)   - dispatched by category
--   GBI.Bar.OnCDReady(unit, spellID, state)
--   GBI.Bar.OnAllReady()
--   GBI.Bar.Reset()
--   GBI.Bar.Show() / Hide() / SetEnabled(bool)
--   GBI.Bar.GetInterruptAnchor()  - for KickCounter to attach its label

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.Bar = GBI.Bar or {}
local M = GBI.Bar

local ICON_BASE   = 32          -- base icon size before per-bar scale
local ICON_GAP    = 4
local ROW_GAP     = 6
local NAME_WIDTH  = 80
local DEFAULT_ICONS_PER_ROW = 8
local GLOW_LEAD_S = 2            -- seconds before ready to start the glow pulse

-- Optional Blizzard ActionButton overlay glow. Wrapped in pcall because the
-- exact symbol moved between patches; if absent, glow is a no-op.
local function showGlow(frame)
    pcall(function()
        if _G.ActionButton_ShowOverlayGlow then _G.ActionButton_ShowOverlayGlow(frame) end
    end)
end
local function hideGlow(frame)
    pcall(function()
        if _G.ActionButton_HideOverlayGlow then _G.ActionButton_HideOverlayGlow(frame) end
    end)
end

local function glowEnabled()
    return GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.glow
end

local function log(level, ...) if GBI.Log then GBI.Log[level]("bar", ...) end end

-- A "bar instance" packs the anchor + per-unit rows + icon pool for one
-- category group. We build two of them.
local function newBar(spec)
    local self = {
        spec     = spec,                    -- { key, title, defaultY, savedKey }
        anchor   = nil,
        rows     = {},                      -- unit -> rowFrame
        icons    = {},                      -- unit -> { {icon, cooldown, spellID, endsAt}, ... }
        scale    = 1.0,                     -- icon-size multiplier (per-bar)
    }

    local function saved() return GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.bars and GOBIGnINTERRUPTDB.bars[spec.key] or {} end
    local function effIcon()    return math.floor(ICON_BASE * self.scale + 0.5) end
    local function effRowH()
        return effIcon() + 4
    end
    local function effPerRow()
        if spec.progressBar then return 6 end   -- interrupts: enough slots, panel width is fixed
        return saved().iconsPerRow or DEFAULT_ICONS_PER_ROW
    end
    local function effGrowDir() return saved().growDir or "RIGHT" end
    local function effBarWidth() return saved().barWidth or 220 end
    local function effPanelW()
        if spec.progressBar then return NAME_WIDTH + effBarWidth() + 16 end
        return NAME_WIDTH + effPerRow() * (effIcon() + ICON_GAP) + 16
    end
    local function effPanelH()  return 16 + #K.PARTY_UNITS * (effRowH() + ROW_GAP) end

    local function ensureRow(unit, idx)
        if self.rows[unit] then return self.rows[unit] end
        local row = CreateFrame("Frame", nil, self.anchor)
        row:SetSize(effPanelW() - 16, effRowH())
        row:SetPoint("TOPLEFT", self.anchor, "TOPLEFT", 8, -8 - (idx - 1) * (effRowH() + ROW_GAP))

        if spec.progressBar then
            -- Bar fills the right portion of the row; name strip sits to its left.
            local bar = CreateFrame("StatusBar", nil, row)
            bar:SetPoint("LEFT", row, "LEFT", NAME_WIDTH, 0)
            bar:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            bar:SetHeight(effIcon() + 4)
            bar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
            bar:SetStatusBarColor(0.15, 0.55, 0.85, 0.85)   -- neutral teal-blue, no class collision
            bar:SetMinMaxValues(0, 1); bar:SetValue(0)
            -- Direction: RIGHT = fill anchored left, empties from right (icons
            -- start right, slide left as CD ticks). LEFT = mirror (SetReverseFill).
            if effGrowDir() == "LEFT" then bar:SetReverseFill(true) else bar:SetReverseFill(false) end
            local bg = bar:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(bar)
            bg:SetColorTexture(0, 0, 0, 0.45)
            -- Countdown text comes from the icon's CooldownFrameTemplate
            -- (OmniCC-compatible). No separate bar text — keeps the bar clean.
            row.progBar = bar
            row.bg = bg                              -- backwards compat
            bar:SetScript("OnUpdate", function(self, elapsed)
                self.acc = (self.acc or 0) + elapsed
                if self.acc < 0.05 then return end
                self.acc = 0
                local now = GetTime()

                -- Drive bar value off the soonest-ending icon (still the
                -- main visual) and reposition every visible icon along
                -- its own remaining-fraction so they ride the tick-down.
                local soonestStart, soonestEnd
                local barW = self:GetWidth()
                local growLeft = effGrowDir() == "LEFT"
                for _, e in ipairs(self.iconList or {}) do
                    if e.icon:IsShown() and e.endsAt then
                        if not soonestEnd or e.endsAt < soonestEnd then
                            soonestStart = e.startedAt or now
                            soonestEnd   = e.endsAt
                        end
                        local total = math.max(0.1, e.endsAt - (e.startedAt or now))
                        local rem = math.max(0, e.endsAt - now)
                        local frac = rem / total
                        e.icon:ClearAllPoints()
                        if growLeft then
                            -- Icon starts at left edge, slides right toward bar's right end as fill empties.
                            e.icon:SetPoint("CENTER", self, "RIGHT", -frac * barW, 0)
                        else
                            e.icon:SetPoint("CENTER", self, "LEFT",  frac * barW, 0)
                        end
                    end
                end

                if not soonestEnd or soonestEnd <= now then
                    self:SetValue(0); return
                end
                local total = math.max(0.1, soonestEnd - (soonestStart or now))
                local rem = soonestEnd - now
                self:SetMinMaxValues(0, total)
                self:SetValue(rem)
            end)
        else
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints(row)
            row.bg:SetColorTexture(0, 0, 0, 0.35)
        end

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        if spec.progressBar then
            -- Name strip to the LEFT of the bar.
            row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.name:SetPoint("RIGHT", row.progBar, "LEFT", -4, 0)
            row.name:SetJustifyH("RIGHT")
            local f, sz = row.name:GetFont()
            if f then row.name:SetFont(f, sz or 12, "OUTLINE") end
        else
            row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.name:SetWidth(NAME_WIDTH)
            row.name:SetJustifyH("LEFT")
        end

        self.rows[unit] = row
        self.icons[unit] = {}
        if row.progBar then row.progBar.iconList = self.icons[unit] end
        return row
    end

    -- For the interrupts window: returns true if the unit's class+spec has
    -- an interrupt spell tracked in GBI.Interrupts. Permissive on unknown spec.
    local function unitHasInterrupt(unit)
        local _, classToken = UnitClass(unit)
        if not classToken then return true end
        local entry = GBI.Interrupts and GBI.Interrupts[classToken]
        if not entry then return false end           -- class has no interrupt at all
        if entry.default then return true end         -- whole class qualifies
        -- per-spec: need to know spec. Permissive on unknown.
        local guid = GBI.Taint and GBI.Taint.SafeGUID and GBI.Taint.SafeGUID(unit)
        local spec = guid and GBI.Inspect and GBI.Inspect.GetSpecByGUID
            and GBI.Inspect.GetSpecByGUID(guid) or nil
        if not spec then return true end              -- unknown spec → show
        return entry[spec] ~= nil
    end

    local function refreshNames()
        local visibleIdx = 0
        for _, unit in ipairs(K.PARTY_UNITS) do
            local row = self.rows[unit]
            if row then
                local skipNoInterrupt = spec.progressBar and UnitExists(unit)
                    and not unitHasInterrupt(unit)
                if UnitExists(unit) and not skipNoInterrupt then
                    local name = UnitName(unit) or unit
                    local _, classToken = UnitClass(unit)
                    if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
                        local c = RAID_CLASS_COLORS[classToken]
                        row.name:SetText(("|cff%02x%02x%02x%s|r"):format(c.r * 255, c.g * 255, c.b * 255, name))
                    else
                        row.name:SetText(name)
                    end
                    row:Show()
                    -- repack visible rows to top of panel
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", self.anchor, "TOPLEFT",
                        8, -8 - visibleIdx * (effRowH() + ROW_GAP))
                    visibleIdx = visibleIdx + 1
                    if self.PopulatePlaceholders then self.PopulatePlaceholders(unit) end
                else
                    row:Hide()
                end
            end
        end
        -- shrink panel to fit only visible rows
        if self.anchor then
            local h = math.max(16 + visibleIdx * (effRowH() + ROW_GAP), effRowH() + 24)
            self.anchor:SetHeight(h)
        end
    end
    self.refreshNames = refreshNames

    local function ensureAnchor()
        if self.anchor then return self.anchor end
        local frameName = "GOBIGnINTERRUPT_Anchor_" .. spec.key
        self.anchor = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
        self.anchor:SetSize(effPanelW(), effPanelH())
        self.anchor:SetPoint("CENTER", UIParent, "CENTER", 0, spec.defaultY)
        self.anchor:SetMovable(true)
        self.anchor:EnableMouse(true)
        self.anchor:RegisterForDrag("LeftButton")
        self.anchor:SetScript("OnDragStart", function(s)
            if not GOBIGnINTERRUPTDB or not GOBIGnINTERRUPTDB.locked then s:StartMoving() end
        end)
        self.anchor:SetScript("OnDragStop", function(s)
            s:StopMovingOrSizing()
            local p, _, rp, x, y = s:GetPoint()
            GOBIGnINTERRUPTDB = GOBIGnINTERRUPTDB or {}
            GOBIGnINTERRUPTDB.bars = GOBIGnINTERRUPTDB.bars or {}
            GOBIGnINTERRUPTDB.bars[spec.key] = { p = p, rp = rp, x = x, y = y }
        end)
        if self.anchor.SetBackdrop then
            self.anchor:SetBackdrop({
                bgFile   = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            self.anchor:SetBackdropColor(0, 0, 0, 0.55)
            self.anchor:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        end

        local title = self.anchor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        title:SetPoint("BOTTOMLEFT", self.anchor, "TOPLEFT", 4, 2)
        title:SetText(spec.title)
        self.anchor.title = title

        -- Resize grip: drag horizontally to change icon size + panel size
        -- (does NOT use SetScale — affects real frame dimensions instead).
        local grip = CreateFrame("Frame", nil, self.anchor)
        grip:SetSize(14, 14)
        grip:SetPoint("BOTTOMRIGHT", self.anchor, "BOTTOMRIGHT", -2, 2)
        grip:EnableMouse(true)
        local gtex = grip:CreateTexture(nil, "OVERLAY")
        gtex:SetAllPoints(grip)
        gtex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        grip:SetScript("OnMouseDown", function(s)
            s.dragging = true
            s.startX = GetCursorPosition()
            s.startScale = self.scale
        end)
        grip:SetScript("OnMouseUp", function(s)
            s.dragging = false
            GOBIGnINTERRUPTDB.bars = GOBIGnINTERRUPTDB.bars or {}
            GOBIGnINTERRUPTDB.bars[spec.key] = GOBIGnINTERRUPTDB.bars[spec.key] or {}
            GOBIGnINTERRUPTDB.bars[spec.key].scale = self.scale
        end)
        grip:SetScript("OnUpdate", function(s)
            if not s.dragging then return end
            local x = GetCursorPosition()
            local delta = (x - s.startX) / 200
            local ns = math.max(0.5, math.min(2.5, s.startScale + delta))
            if math.abs(ns - self.scale) >= 0.01 then
                self.scale = ns
                if self.applyScale then self.applyScale() end
            end
        end)
        self.anchor.grip = grip

        for i, unit in ipairs(K.PARTY_UNITS) do ensureRow(unit, i) end
        refreshNames()
        if self.applyLocked then self.applyLocked() end
        return self.anchor
    end

    -- When the anchor is locked, hide chrome (background, border, title,
    -- resize grip, row backgrounds) so the bar is just floating icons.
    function self.applyLocked()
        if not self.anchor then return end
        local locked = GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.locked
        if self.anchor.SetBackdrop then
            if locked then
                self.anchor:SetBackdrop(nil)
            else
                self.anchor:SetBackdrop({
                    bgFile   = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Buttons\\WHITE8x8",
                    edgeSize = 1,
                })
                self.anchor:SetBackdropColor(0, 0, 0, 0.55)
                self.anchor:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
            end
        end
        if self.anchor.title then
            if locked then self.anchor.title:Hide() else self.anchor.title:Show() end
        end
        if self.anchor.grip then
            if locked then self.anchor.grip:Hide() else self.anchor.grip:Show() end
        end
        for _, unit in ipairs(K.PARTY_UNITS) do
            local row = self.rows[unit]
            if row and row.bg then
                if locked then row.bg:Hide() else row.bg:Show() end
            end
            -- name always visible, regardless of lock state
        end
        self.anchor:EnableMouse(not locked)
    end
    self.ensureAnchor = ensureAnchor

    -- Spec-aware placeholder pre-population. For each unit, look up the
    -- tracked spells matching their class+spec and create dim/desaturated
    -- icons for spells that haven't been observed yet. When a real cast
    -- arrives, OnCDStart finds the existing entry by spellID and converts
    -- it to a live icon (un-dim, set endsAt, run cooldown swipe).
    function self.PopulatePlaceholders(unit)
        if not (GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.placeholders
            and GOBIGnINTERRUPTDB.placeholders.enabled ~= false) then return end
        if not GBI.SpellsForUnit then return end
        local row = self.rows[unit]
        if not row then return end
        local list = self.icons[unit] or {}
        self.icons[unit] = list

        -- Build expected spell-ID set for this unit's class+spec.
        local expected = {}
        for _, e in ipairs(GBI.SpellsForUnit(unit)) do expected[e.sid] = true end

        -- Prune placeholder entries no longer in the expected set (spec changed
        -- or initial permissive list got pruned once inspect resolved).
        for i = #list, 1, -1 do
            local x = list[i]
            if x.placeholder and not expected[x.spellID] then
                x.icon:Hide()
                table.remove(list, i)
            end
        end

        for _, e in ipairs(GBI.SpellsForUnit(unit)) do
            local cd = e.cd
            local include = (spec.progressBar and cd.category == K.CAT_INTERRUPT)
                         or (not spec.progressBar and cd.category ~= K.CAT_INTERRUPT
                                                  and cd.category ~= K.CAT_DISPEL
                                                  and cd.category ~= K.CAT_UTILITY)
            if include then
                local exists
                for _, x in ipairs(list) do
                    if x.spellID == e.sid then exists = x; break end
                end
                if not exists then
                    local icon = CreateFrame("Frame", nil, row)
                    icon:SetSize(effIcon(), effIcon())
                    local t = icon:CreateTexture(nil, "ARTWORK"); t:SetAllPoints(icon)
                    icon.tex = t
                    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(e.sid)
                    t:SetTexture(info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
                    t:SetDesaturated(true)
                    icon:SetAlpha(0.4)
                    local cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
                    cooldown:SetAllPoints(icon)
                    icon.cooldown = cooldown
                    table.insert(list, { icon = icon, cooldown = cooldown,
                        spellID = e.sid, endsAt = nil, placeholder = true })
                    icon:Show()
                end
            end
        end
        if self.applyScale then self.applyScale() end
    end

    local function restorePosition()
        local saved = GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.bars and GOBIGnINTERRUPTDB.bars[spec.key]
        if not (self.anchor and saved) then return end
        if saved.p and saved.x and saved.y then
            self.anchor:ClearAllPoints()
            self.anchor:SetPoint(saved.p, UIParent, saved.rp or saved.p, saved.x, saved.y)
        end
        if saved.scale and saved.scale > 0 then
            self.scale = math.max(0.5, math.min(2.5, saved.scale))
            self.applyScale()
        end
    end

    local function expireIcons()
        local now = GetTime()
        local glowOn = glowEnabled()
        for _, units in pairs(self.icons) do
            for _, entry in ipairs(units) do
                local expired = entry.endsAt and entry.endsAt <= now
                if expired then
                    -- KEEP the icon visible for the whole run; glow it to
                    -- show the spell is ready. Brain.Reset (zone change)
                    -- removes them via Bar.Reset for a fresh state.
                    if not entry.glowing then showGlow(entry.icon); entry.glowing = true end
                elseif glowOn and entry.endsAt and (entry.endsAt - now) <= GLOW_LEAD_S then
                    if not entry.glowing then showGlow(entry.icon); entry.glowing = true end
                elseif entry.glowing and not glowOn then
                    hideGlow(entry.icon); entry.glowing = false
                end
            end
        end
    end
    self.expireIcons = expireIcons

    function self.Show()
        ensureAnchor(); restorePosition(); self.anchor:Show(); refreshNames()
        if self.applyLocked then self.applyLocked() end
    end
    function self.Hide()
        if self.anchor then self.anchor:Hide() end
    end
    function self.Reset()
        if not self.anchor then return end
        for unit, list in pairs(self.icons) do
            for _, e in ipairs(list) do
                e.icon:Hide()
            end
            self.icons[unit] = {}
        end
    end

    function self.applyScale()
        if not self.anchor then return end
        self.anchor:SetSize(effPanelW(), effPanelH())
        for i, unit in ipairs(K.PARTY_UNITS) do
            local row = self.rows[unit]
            if row then
                row:SetSize(effPanelW() - 16, effRowH())
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", self.anchor, "TOPLEFT",
                    8, -8 - (i - 1) * (effRowH() + ROW_GAP))
            end
            local list = self.icons[unit] or {}
            for _, e in ipairs(list) do
                e.icon:SetSize(effIcon(), effIcon())
            end
        end
        if spec.progressBar then
            local growLeft = effGrowDir() == "LEFT"
            for _, row in pairs(self.rows) do
                if row.progBar then
                    row.progBar:SetHeight(effIcon() + 4)
                    row.progBar:SetReverseFill(growLeft)
                end
            end
            return  -- bar OnUpdate handles icon positions per-frame
        end
        -- relayout visible icons in each row (with wrap + grow direction)
        for unit, list in pairs(self.icons) do
            local visible = {}
            for _, e in ipairs(list) do if e.icon:IsShown() then visible[#visible+1] = e end end
            table.sort(visible, function(a, b) local al=a.endsAt~=nil; local bl=b.endsAt~=nil; if al~=bl then return al end; if al then return a.endsAt<b.endsAt end; return (a.spellID or 0)<(b.spellID or 0) end)
            local row = self.rows[unit]
            local perRow = effPerRow()
            local stride = effIcon() + ICON_GAP
            local grow = effGrowDir()
            for i, e in ipairs(visible) do
                e.icon:ClearAllPoints()
                local col = (i - 1) % perRow
                local subRow = math.floor((i - 1) / perRow)
                local x = NAME_WIDTH + 4 + col * stride
                if grow == "LEFT" then
                    e.icon:SetPoint("RIGHT", row, "RIGHT", -col * stride, -subRow * stride)
                else
                    e.icon:SetPoint("LEFT", row, "LEFT", x, -subRow * stride)
                end
            end
        end
    end

    function self.OnCDStart(unit, spellID, state)
        ensureAnchor()
        local row = self.rows[unit]
        if not row then return end

        local list = self.icons[unit]
        local entry
        -- Reuse existing entry for the same spell first (interrupt rows
        -- keep entries around in "ready, glowing" state).
        for _, e in ipairs(list) do
            if e.spellID == spellID then entry = e; break end
        end
        if not entry then
            for _, e in ipairs(list) do
                if not e.icon:IsShown() then entry = e; break end
            end
        end
        if not entry then
            local icon = CreateFrame("Frame", nil, row)
            icon:SetSize(effIcon(), effIcon())
            local t = icon:CreateTexture(nil, "ARTWORK")
            t:SetAllPoints(icon)
            icon.tex = t
            local cd = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
            cd:SetAllPoints(icon)
            icon.cooldown = cd
            entry = { icon = icon, cooldown = cd, spellID = nil, endsAt = nil }
            table.insert(list, entry)
        end

        entry.spellID   = spellID
        entry.startedAt = state.startedAt
        entry.endsAt    = state.endsAt
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
        local iconPath = info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark"
        entry.icon.tex:SetTexture(iconPath)
        entry.cooldown:SetCooldown(state.startedAt, state.endsAt - state.startedAt)
        entry.icon:Show()
        if entry.placeholder then
            entry.placeholder = false
            entry.icon:SetAlpha(1.0)
            if entry.icon.tex then entry.icon.tex:SetDesaturated(false) end
        end
        if entry.glowing then hideGlow(entry.icon); entry.glowing = false end

        if spec.progressBar then
            -- Bar's OnUpdate positions icons along the fill edge; skip default layout.
        else
            local visible = {}
            for _, e in ipairs(list) do
                if e.icon:IsShown() then visible[#visible + 1] = e end
            end
            table.sort(visible, function(a, b) local al=a.endsAt~=nil; local bl=b.endsAt~=nil; if al~=bl then return al end; if al then return a.endsAt<b.endsAt end; return (a.spellID or 0)<(b.spellID or 0) end)
            local perRow = effPerRow()
            local stride = effIcon() + ICON_GAP
            local grow = effGrowDir()
            for i, e in ipairs(visible) do
                e.icon:ClearAllPoints()
                local col = (i - 1) % perRow
                local subRow = math.floor((i - 1) / perRow)
                if grow == "LEFT" then
                    e.icon:SetPoint("RIGHT", row, "RIGHT", -col * stride, -subRow * stride)
                else
                    e.icon:SetPoint("LEFT", row, "LEFT",
                        NAME_WIDTH + 4 + col * stride, -subRow * stride)
                end
            end
        end
    end

    function self.OnCDReady(unit, spellID)
        local list = self.icons[unit] or {}
        for _, e in ipairs(list) do
            if e.spellID == spellID then
                -- Mark ready; expireIcons handles the glow on next tick.
                -- The icon stays visible for the rest of the run.
                e.endsAt = GetTime() - 0.01
                return
            end
        end
    end

    return self
end

-- Two instances ------------------------------------------------------------

local barInt = newBar({ key = "interrupts", title = "GBI Interrupts", defaultY = 160, progressBar = true })
local barCD  = newBar({ key = "cooldowns",  title = "GBI Cooldowns",  defaultY = 60  })

local function unitOverlayActive()
    return GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.unitOverlay
        and GOBIGnINTERRUPTDB.unitOverlay.enabled
        and GBI.UnitOverlay
end

local function dispatch(state, fnName, unit, spellID)
    local cdEntry = state.cdEntry
    if not cdEntry then return end
    if cdEntry.category == K.CAT_INTERRUPT then
        barInt[fnName](unit, spellID, state)
    else
        if unitOverlayActive() then
            local ov = GBI.UnitOverlay
            -- The overlay visibility may have been flipped off by an engine
            -- state change (M.Hide on context=world). Re-ensure it's shown
            -- whenever we have a CD to paint and the user has the option on.
            if ov.Show then ov.Show() end
            if ov[fnName] then ov[fnName](unit, spellID, state) end
        else
            barCD[fnName](unit, spellID, state)
        end
    end
end

function M.OnCDStart(unit, spellID, state) dispatch(state, "OnCDStart", unit, spellID) end
function M.OnCDReady(unit, spellID, state) dispatch(state, "OnCDReady", unit, spellID) end

function M.OnAllReady()
    -- visual ping on the cooldown bar/overlay (subtle flash). Phase 2: TBD.
end

function M.Reset()
    barInt.Reset(); barCD.Reset()
    if GBI.UnitOverlay and GBI.UnitOverlay.Reset then GBI.UnitOverlay.Reset() end
    if GBI.KickCounter and GBI.KickCounter.Reset then GBI.KickCounter.Reset() end
end

function M.Show()
    barInt.Show()
    if unitOverlayActive() then
        barCD.Hide()
        if GBI.UnitOverlay and GBI.UnitOverlay.Show then GBI.UnitOverlay.Show() end
    else
        barCD.Show()
        if GBI.UnitOverlay and GBI.UnitOverlay.Hide then GBI.UnitOverlay.Hide() end
    end
end

function M.Hide()
    barInt.Hide(); barCD.Hide()
    if GBI.UnitOverlay and GBI.UnitOverlay.Hide then GBI.UnitOverlay.Hide() end
end

function M.SetEnabled(on) if on then M.Show() else M.Hide() end end

function M.GetInterruptAnchor() barInt.ensureAnchor(); return barInt.anchor end

-- Visual test: drop a fake interrupt CD on every party slot so the row layout,
-- progress bars, and resize controls can be tuned without an actual M+ run.
function M.TestInterruptFill(durationS)
    durationS = durationS or 15
    local now = GetTime()
    barInt.Show()
    for _, unit in ipairs(K.PARTY_UNITS) do
        barInt.OnCDStart(unit, 6552, {
            startedAt = now,
            endsAt    = now + durationS,
            cdEntry   = { name = "Pummel", duration = durationS, category = K.CAT_INTERRUPT },
        })
    end
end

function M.RefreshLocked()
    if barInt.applyLocked then barInt.applyLocked() end
    if barCD.applyLocked  then barCD.applyLocked()  end
end

function M.ApplyAllBars()
    -- Re-read scale from saved-vars and reflow icons per the new layout cfg.
    local function syncAndApply(b)
        local s = (GOBIGnINTERRUPTDB.bars or {})[b.spec.key]
        if s and s.scale and s.scale > 0 then
            b.scale = math.max(0.5, math.min(2.5, s.scale))
        end
        if b.applyScale then b.applyScale() end
    end
    syncAndApply(barInt); syncAndApply(barCD)
end

-- Re-evaluate cooldown-window vs unit-overlay when the option flips.
function M.RefreshLayout()
    if barInt.anchor and barInt.anchor:IsShown() then
        if unitOverlayActive() then
            barCD.Hide()
            if GBI.UnitOverlay and GBI.UnitOverlay.Show then GBI.UnitOverlay.Show() end
        else
            barCD.Show()
            if GBI.UnitOverlay and GBI.UnitOverlay.Hide then GBI.UnitOverlay.Hide() end
        end
    end
end

local rf = CreateFrame("Frame", "GOBIGnINTERRUPT_BarRosterFrame")
rf:RegisterEvent("GROUP_ROSTER_UPDATE")
rf:RegisterEvent("UNIT_NAME_UPDATE")
rf:RegisterEvent("INSPECT_READY")
rf:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
rf:SetScript("OnEvent", function()
    if barInt.anchor then barInt.refreshNames() end
    if barCD.anchor  then barCD.refreshNames()  end
end)

local tk = CreateFrame("Frame", "GOBIGnINTERRUPT_BarTickerFrame")
tk:SetScript("OnUpdate", function(self, elapsed)
    self.acc = (self.acc or 0) + elapsed
    if self.acc < 0.5 then return end
    self.acc = 0
    barInt.expireIcons(); barCD.expireIcons()
end)
