-- Settings API canvas panel for GOBIGnINTERRUPT.
--
-- Sections:
--   1. General   - master enable, debug, lock anchor, show-always
--   2. Interrupt - enable, delay slider, sound mode dropdown
--   3. Burst     - all-ready spell list (add/remove rows) + sound mode dropdown
--   4. Bar       - icon size slider
--
-- Public:
--   GBI_OpenConfig()    - opens the panel (also bound to /gbi config)
--   GBI.Options.Refresh() - rebuild dynamic sections after data changes

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
local K = GBI.K
GBI.Options = GBI.Options or {}
local M = GBI.Options

local addonName = ...

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function db()
    GOBIGnINTERRUPTDB = GOBIGnINTERRUPTDB or {}
    return GOBIGnINTERRUPTDB
end

local function cbLabel(cb) return cb.Text or cb.text end

-- Mirrors relax8r8r's getSoundsForCategory: pulls files from the shared
-- SoundLibrary that are tagged with the given category (a string or a list).
local function soundsForCategory(category)
    local wanted = {}
    if type(category) == "string" then
        wanted[category] = true
    elseif type(category) == "table" then
        for _, c in ipairs(category) do wanted[c] = true end
    end
    local out = {}
    local lib = _G.SoundLibrary and _G.SoundLibrary.library or {}
    for filename, meta in pairs(lib) do
        for _, cat in ipairs(meta.categories or {}) do
            if wanted[cat] then
                out[#out + 1] = { file = filename, label = meta.label or filename }
                break
            end
        end
    end
    table.sort(out, function(a, b) return (a.label or a.file) < (b.label or b.file) end)
    return out
end

-- ---------------------------------------------------------------------------
-- Sound-mode dropdown widget. Used by interrupt + burst-ready triggers.
-- ---------------------------------------------------------------------------
-- Creates a [mode dropdown] [specific-file dropdown] pair on `parent`,
-- bound to GOBIGnINTERRUPTDB.sound[category].
local function makeSoundModeRow(parent, category, label)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(480, 26)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.text:SetPoint("LEFT", 0, 0)
    row.text:SetWidth(140)
    row.text:SetJustifyH("LEFT")
    row.text:SetText(label)

    row.modeDD = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
    row.modeDD:SetPoint("LEFT", row.text, "RIGHT", 6, 0)
    row.modeDD:SetWidth(120)

    row.fileDD = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
    row.fileDD:SetPoint("LEFT", row.modeDD, "RIGHT", 6, 0)
    row.fileDD:SetWidth(180)

    local function ensureCfg()
        local d = db()
        d.sound = d.sound or {}
        d.sound[category] = d.sound[category] or { mode = "off" }
        return d.sound[category]
    end

    local MODES = { "off", "specific", "rotate", "random" }
    local LABELS = { off = "Off", specific = "Pick specific", rotate = "Rotate", random = "Random" }

    local function refresh()
        local cfg = ensureCfg()
        row.modeDD:GenerateMenu()
        if cfg.mode == "specific" then
            row.fileDD:Show()
            row.fileDD:GenerateMenu()
        else
            row.fileDD:Hide()
        end
    end

    row.modeDD:SetupMenu(function(_, root)
        for _, m in ipairs(MODES) do
            root:CreateRadio(LABELS[m],
                function() return ensureCfg().mode == m end,
                function() ensureCfg().mode = m; refresh() end)
        end
    end)

    row.fileDD:SetupMenu(function(_, root)
        local sounds = soundsForCategory(category)
        if #sounds == 0 then
            root:CreateTitle("(no sounds tagged " .. category .. ")")
            return
        end
        for _, s in ipairs(sounds) do
            root:CreateRadio(s.label or s.file,
                function() return ensureCfg().file == s.file end,
                function()
                    ensureCfg().file = s.file
                    if GBI.SoundPipeline and GBI.SoundPipeline.Preview then
                        GBI.SoundPipeline.Preview(s.file)
                    end
                end)
        end
    end)

    row:SetScript("OnShow", refresh)
    return row
end

-- ---------------------------------------------------------------------------
-- All-ready list editor (Burst section).
-- ---------------------------------------------------------------------------
local function makeAllReadyEditor(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(480, 200)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOPLEFT")
    frame.title:SetText("All-ready spell list (sound fires when every spell is simultaneously off CD)")

    -- "Add spell ID" row at top
    frame.idEdit = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.idEdit:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 4, -8)
    frame.idEdit:SetSize(80, 20)
    frame.idEdit:SetAutoFocus(false)
    frame.idEdit:SetNumeric(true)
    frame.idEdit:SetMaxLetters(10)

    frame.addBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.addBtn:SetPoint("LEFT", frame.idEdit, "RIGHT", 8, 0)
    frame.addBtn:SetSize(80, 22)
    frame.addBtn:SetText("Add spell")

    -- Scrollable list of existing entries
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame.idEdit, "BOTTOMLEFT", 0, -8)
    scroll:SetSize(440, 130)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(420, 1)
    scroll:SetScrollChild(content)
    frame.scroll, frame.content = scroll, content

    local function rebuild()
        if frame.content._rows then
            for _, r in ipairs(frame.content._rows) do r:Hide() end
        end
        frame.content._rows = {}
        local list = db().allReadyList or {}
        local y = 0
        for _, sid in ipairs(list) do
            local row = CreateFrame("Frame", nil, frame.content)
            row:SetSize(420, 22)
            row:SetPoint("TOPLEFT", 0, -y)

            local info = GBI.GetCooldown and GBI.GetCooldown(sid)
            local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            lbl:SetPoint("LEFT", 0, 0)
            lbl:SetText(("%d  %s"):format(sid, info and info.name or "(unknown)"))

            local rm = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            rm:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            rm:SetSize(20, 20)
            rm:SetScript("OnClick", function()
                local l = db().allReadyList
                for i, e in ipairs(l) do
                    if e == sid then table.remove(l, i); break end
                end
                rebuild()
            end)

            table.insert(frame.content._rows, row)
            y = y + 24
        end
        frame.content:SetHeight(math.max(y, 1))
    end

    frame.addBtn:SetScript("OnClick", function()
        local sid = tonumber(frame.idEdit:GetText())
        if not sid or sid <= 0 then return end
        db().allReadyList = db().allReadyList or {}
        for _, e in ipairs(db().allReadyList) do
            if e == sid then return end
        end
        table.insert(db().allReadyList, sid)
        frame.idEdit:SetText("")
        rebuild()
    end)

    frame:SetScript("OnShow", rebuild)
    frame.Refresh = rebuild
    return frame
end

-- ---------------------------------------------------------------------------
-- Panel (lazy-built)
-- ---------------------------------------------------------------------------

local panel, category
local subpanels = {}     -- { { name=..., frame=..., content=... } }

-- Helper: build a Settings-canvas-compatible subpanel frame with a scrollable
-- content area and a title. Returns the panel frame and the inner content
-- frame. Caller adds widgets to `content`.
local function makeSubPanel(name, subtitle)
    local sp = CreateFrame("Frame")
    sp.name = name
    sp:SetSize(560, 600)
    sp:SetClipsChildren(true)

    local sc = CreateFrame("ScrollFrame", nil, sp, "UIPanelScrollFrameTemplate")
    sc:SetPoint("TOPLEFT", sp, "TOPLEFT", 0, 0)
    sc:SetPoint("BOTTOMRIGHT", sp, "BOTTOMRIGHT", -28, 0)
    sc:SetClipsChildren(true)
    local content = CreateFrame("Frame", nil, sc)
    content:SetSize(540, 1000)
    content:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, 0)
    sc:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(name)
    if subtitle then
        local st = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        st:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
        st:SetText(subtitle)
        st:SetTextColor(0.7, 0.7, 0.7)
        sp._anchorTo = st
    else
        sp._anchorTo = title
    end
    sp._content = content
    table.insert(subpanels, { name = name, frame = sp, content = content })
    return sp, content
end

local function buildPanel()
    panel = CreateFrame("Frame")
    panel.name = "GOBIGnINTERRUPT"
    panel:SetSize(560, 600)

    -- Scrollable content area. The Settings canvas does not scroll, so wrap
    -- everything in our own ScrollFrame; widgets attach to `content`.
    panel:SetClipsChildren(true)
    local scroll = CreateFrame("ScrollFrame", "GBI_OptionsScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 0)
    scroll:SetClipsChildren(true)
    local content = CreateFrame("Frame", "GBI_OptionsContent", scroll)
    content:SetSize(540, 1100)
    content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    scroll:SetScrollChild(content)
    panel._content = content

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("GOBIGnINTERRUPT")

    local subtitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetText("M+ party CD tracker + interrupt-pull alert.")
    subtitle:SetTextColor(0.7, 0.7, 0.7)

    -- ============= 1. General toggles ============= --
    local function mkToggle(parentRel, dy, dbKey, labelText)
        local cb = CreateFrame("CheckButton", nil, content,"UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", parentRel, "BOTTOMLEFT", 0, dy)
        cbLabel(cb):SetText(labelText)
        cb:SetScript("OnShow", function(s) s:SetChecked(db()[dbKey] and true or false) end)
        cb:SetScript("OnClick", function(s)
            db()[dbKey] = s:GetChecked() and true or false
            if dbKey == "locked" and GBI.Bar and GBI.Bar.RefreshLocked then
                GBI.Bar.RefreshLocked()
            end
        end)
        return cb
    end

    local enable      = mkToggle(subtitle,  -8, "enabled",    "Enable addon")
    local debugTgl    = mkToggle(enable,    -2, "debug",      "Debug logging")
    local lockTgl     = mkToggle(debugTgl,  -2, "locked",     "Lock anchor (cannot drag)")
    -- "Show outside dungeons" toggle removed. The engine now always tracks
    -- when the addon is enabled; the show toggles below decide what's visible.
    local showAlways = lockTgl     -- alias so downstream anchors still work

    local function mkShowToggle(parentRel, dy, key, labelText)
        local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", parentRel, "BOTTOMLEFT", 0, dy)
        cbLabel(cb):SetText(labelText)
        cb:SetScript("OnShow", function(s)
            local sh = db().show or {}
            s:SetChecked(sh[key] ~= false)
        end)
        cb:SetScript("OnClick", function(s)
            db().show = db().show or {}
            db().show[key] = s:GetChecked() and true or false
            if GBI.Bar and GBI.Bar.RefreshLayout then GBI.Bar.RefreshLayout() end
        end)
        return cb
    end
    local showInt = mkShowToggle(showAlways, -2, "interruptBar", "Show Interrupts bar")

    -- Cooldowns mode dropdown — replaces the old "Show CD bar" + "Show
    -- on party frames" pair which interacted confusingly.
    local cdModeLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cdModeLbl:SetPoint("TOPLEFT", showInt, "BOTTOMLEFT", 0, -6)
    cdModeLbl:SetText("Cooldowns display")
    local cdModeDD = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    cdModeDD:SetPoint("LEFT", cdModeLbl, "RIGHT", 8, 0); cdModeDD:SetWidth(180)
    local CD_MODES = {
        { key = "bar",     label = "Bar window" },
        { key = "overlay", label = "Party-frame overlay" },
        { key = "off",     label = "Off" },
    }
    local function curCDMode()
        local s = db().show or {}
        if s.cooldownsMode then return s.cooldownsMode end
        if s.cooldownBar == false then return "off" end
        if (db().unitOverlay or {}).enabled then return "overlay" end
        return "bar"
    end
    cdModeDD:SetupMenu(function(_, root)
        for _, m in ipairs(CD_MODES) do
            root:CreateRadio(m.label, function() return curCDMode() == m.key end, function()
                db().show = db().show or {}
                db().show.cooldownsMode = m.key
                -- Mirror to legacy fields for back-compat.
                db().show.cooldownBar = (m.key ~= "off")
                db().unitOverlay = db().unitOverlay or {}
                db().unitOverlay.enabled = (m.key == "overlay")
                if GBI.Bar and GBI.Bar.RefreshLayout then GBI.Bar.RefreshLayout() end
                cdModeDD:GenerateMenu()
            end)
        end
    end)
    cdModeDD:SetScript("OnShow", function() cdModeDD:GenerateMenu() end)
    -- Make the next widget (overlayTgl) anchor below the dropdown row.
    local showCD = cdModeDD

    local glowTgl = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    -- Anchor to cdModeLbl (left-margin column), NOT cdModeDD (which is to
    -- the right of the label and would push glow off-axis).
    glowTgl:SetPoint("TOPLEFT", cdModeLbl, "BOTTOMLEFT", -4, -8)
    cbLabel(glowTgl):SetText("Glow icons in last 2s before ready")
    glowTgl:SetScript("OnShow", function(s) s:SetChecked(db().glow and true or false) end)
    glowTgl:SetScript("OnClick", function(s) db().glow = s:GetChecked() and true or false end)

    -- (Old "Show CDs on party frames" checkbox removed - unified into the
    -- "Cooldowns display" dropdown above which has Bar / Overlay / Off.)

    -- side dropdown ---------------------------------------------------------
    -- Overlay anchor block. Left-aligned with the checkboxes above.
    local sideLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sideLabel:SetPoint("TOPLEFT", glowTgl, "BOTTOMLEFT", 0, -22)
    sideLabel:SetText("Overlay")
    local sideLabel2 = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sideLabel2:SetPoint("TOPLEFT", sideLabel, "BOTTOMLEFT", 0, -8)
    sideLabel2:SetText("Anchor side")

    local sideDD = CreateFrame("DropdownButton", nil, content,"WowStyle1DropdownTemplate")
    sideDD:SetPoint("LEFT", sideLabel2, "RIGHT", 8, 0)
    sideDD:SetWidth(120)

    local SIDES = { "BOTTOM", "TOP", "LEFT", "RIGHT" }
    local function curSide() return (db().unitOverlay and db().unitOverlay.side) or "BOTTOM" end
    sideDD:SetupMenu(function(_, root)
        for _, s in ipairs(SIDES) do
            root:CreateRadio(s, function() return curSide() == s end, function()
                db().unitOverlay = db().unitOverlay or {}
                db().unitOverlay.side = s
                if GBI.UnitOverlay and GBI.UnitOverlay.Refresh then GBI.UnitOverlay.Refresh() end
                sideDD:GenerateMenu()
            end)
        end
    end)
    sideDD:SetScript("OnShow", function() sideDD:GenerateMenu() end)

    -- offset sliders --------------------------------------------------------
    local function mkOffsetSlider(parentRel, dy, key, label, lo, hi)
        local s = CreateFrame("Slider", "GBIOverlayOffset_" .. key, content, "OptionsSliderTemplate")
        s:SetPoint("TOPLEFT", parentRel, "BOTTOMLEFT", 0, dy)
        s:SetWidth(220)
        s:SetMinMaxValues(lo, hi); s:SetValueStep(1); s:SetObeyStepOnDrag(true)
        _G[s:GetName() .. "Low"]:SetText(tostring(lo))
        _G[s:GetName() .. "High"]:SetText(tostring(hi))
        local txt = _G[s:GetName() .. "Text"]
        txt:SetText(label)
        s:SetScript("OnShow", function(self)
            local def = ({ iconSize = 28, iconGap = 2 })[key] or 0
            self:SetValue((db().unitOverlay and db().unitOverlay[key]) or def)
        end)
        s:SetScript("OnValueChanged", function(self, v)
            v = math.floor(v + 0.5)
            db().unitOverlay = db().unitOverlay or {}
            db().unitOverlay[key] = v
            txt:SetText(label .. ": " .. v)
            if GBI.UnitOverlay and GBI.UnitOverlay.Refresh then GBI.UnitOverlay.Refresh() end
        end)
        return s
    end

    local sliderX = mkOffsetSlider(sideLabel2, -28, "offsetX", "X offset", -200, 200)
    local sliderY = mkOffsetSlider(sliderX,   -22, "offsetY", "Y offset", -200, 200)
    local sliderSize = mkOffsetSlider(sliderY,    -22, "iconSize", "Overlay icon size", 16, 64)
    local sliderGap  = mkOffsetSlider(sliderSize, -22, "iconGap",  "Icon spacing",       0, 20)

    -- test-mode toggle button (sits next to sliders)
    local testBtn = CreateFrame("Button", nil, content,"UIPanelButtonTemplate")
    testBtn:SetSize(140, 22)
    -- Place below the slider stack so the buttons aren't squeezed off the right edge.
    testBtn:SetPoint("TOPLEFT", sliderGap, "BOTTOMLEFT", 0, -16)
    local function refreshTestBtn()
        local on = GBI.UnitOverlay and GBI.UnitOverlay.IsTestMode and GBI.UnitOverlay.IsTestMode()
        testBtn:SetText(on and "Test mode: ON" or "Test mode: OFF")
    end
    testBtn:SetScript("OnClick", function()
        if not (GBI.UnitOverlay and GBI.UnitOverlay.SetTestMode) then return end
        local on = GBI.UnitOverlay.IsTestMode and GBI.UnitOverlay.IsTestMode()
        GBI.UnitOverlay.SetTestMode(not on)
        refreshTestBtn()
    end)
    testBtn:SetScript("OnShow", refreshTestBtn)

    -- 5-second auto-disable preview button
    local previewBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    previewBtn:SetSize(110, 22)
    previewBtn:SetPoint("LEFT", testBtn, "RIGHT", 8, 0)
    previewBtn:SetText("5s preview")
    previewBtn:SetScript("OnClick", function()
        if not (GBI.UnitOverlay and GBI.UnitOverlay.SetTestMode) then return end
        GBI.UnitOverlay.SetTestMode(true); refreshTestBtn()
        C_Timer.After(5, function()
            GBI.UnitOverlay.SetTestMode(false); refreshTestBtn()
        end)
    end)

    -- ============= 1.5 Bar appearance (per-window) ============= --
    local barHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    barHeader:SetPoint("TOPLEFT", testBtn, "BOTTOMLEFT", 0, -28)
    barHeader:SetText("Bar appearance")

    local intFillBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    intFillBtn:SetSize(180, 22)
    intFillBtn:SetPoint("LEFT", barHeader, "RIGHT", 24, 0)
    intFillBtn:SetText("Test interrupts (15s)")
    intFillBtn:SetScript("OnClick", function()
        if GBI.Bar and GBI.Bar.TestInterruptFill then GBI.Bar.TestInterruptFill(15) end
    end)

    local function refreshBars()
        if GBI.Bar and GBI.Bar.RefreshLayout then GBI.Bar.RefreshLayout() end
    end

    local function applyBarSizeChange(key, sizePx)
        GOBIGnINTERRUPTDB.bars = GOBIGnINTERRUPTDB.bars or {}
        GOBIGnINTERRUPTDB.bars[key] = GOBIGnINTERRUPTDB.bars[key] or {}
        -- Bar code reads `scale`; map slider px -> scale (base 32px).
        GOBIGnINTERRUPTDB.bars[key].scale = sizePx / 32
        if GBI.Bar and GBI.Bar.ApplyAllBars then GBI.Bar.ApplyAllBars() end
    end

    local function makeBarControls(parent, anchorTo, dy, key, label, isProgressBar)
        local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, dy)
        lbl:SetText(label)

        -- Icon size slider
        local sz = CreateFrame("Slider", "GBIBarSize_" .. key, parent, "OptionsSliderTemplate")
        sz:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 8, -16)
        sz:SetWidth(180); sz:SetMinMaxValues(20, 80); sz:SetValueStep(2); sz:SetObeyStepOnDrag(true)
        _G[sz:GetName() .. "Low"]:SetText("20")
        _G[sz:GetName() .. "High"]:SetText("80")
        local szTxt = _G[sz:GetName() .. "Text"]
        sz:SetScript("OnShow", function(s)
            local saved = (db().bars or {})[key] or {}
            local px = math.floor((saved.scale or 1) * 32 + 0.5)
            s:SetValue(px); szTxt:SetText("Icon size: " .. px)
        end)
        sz:SetScript("OnValueChanged", function(s, v)
            v = math.floor(v + 0.5)
            szTxt:SetText("Icon size: " .. v)
            applyBarSizeChange(key, v)
        end)

        local lastSlider = sz

        if isProgressBar then
            -- Bar window: use a bar-width slider instead of icons-per-row.
            local bw = CreateFrame("Slider", "GBIBarWidth_" .. key, parent, "OptionsSliderTemplate")
            bw:SetPoint("TOPLEFT", sz, "BOTTOMLEFT", 0, -22)
            bw:SetWidth(180); bw:SetMinMaxValues(120, 600); bw:SetValueStep(10); bw:SetObeyStepOnDrag(true)
            _G[bw:GetName() .. "Low"]:SetText("120")
            _G[bw:GetName() .. "High"]:SetText("600")
            local bwTxt = _G[bw:GetName() .. "Text"]
            bw:SetScript("OnShow", function(s)
                local sv = (db().bars or {})[key] or {}
                local n = sv.barWidth or 220
                s:SetValue(n); bwTxt:SetText("Bar width: " .. n)
            end)
            bw:SetScript("OnValueChanged", function(s, v)
                v = math.floor(v + 0.5)
                bwTxt:SetText("Bar width: " .. v)
                db().bars = db().bars or {}; db().bars[key] = db().bars[key] or {}
                db().bars[key].barWidth = v
                if GBI.Bar and GBI.Bar.ApplyAllBars then GBI.Bar.ApplyAllBars() end
            end)

            -- Grow direction (also applies to progress bar fill direction)
            local gdLbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            gdLbl:SetPoint("LEFT", bw, "RIGHT", 32, 0)
            gdLbl:SetText("Grow")
            local gd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
            gd:SetPoint("LEFT", gdLbl, "RIGHT", 6, 0); gd:SetWidth(110)
            local function curGrow()
                local sv = (db().bars or {})[key] or {}
                return sv.growDir or "RIGHT"
            end
            gd:SetupMenu(function(_, root)
                for _, dir in ipairs({ "RIGHT", "LEFT" }) do
                    root:CreateRadio(dir, function() return curGrow() == dir end, function()
                        db().bars = db().bars or {}; db().bars[key] = db().bars[key] or {}
                        db().bars[key].growDir = dir
                        if GBI.Bar and GBI.Bar.ApplyAllBars then GBI.Bar.ApplyAllBars() end
                        gd:GenerateMenu()
                    end)
                end
            end)
            gd:SetScript("OnShow", function() gd:GenerateMenu() end)
            lastSlider = bw
        else
            -- Icons per row
            local pr = CreateFrame("Slider", "GBIBarPerRow_" .. key, parent, "OptionsSliderTemplate")
            pr:SetPoint("TOPLEFT", sz, "BOTTOMLEFT", 0, -22)
            pr:SetWidth(180); pr:SetMinMaxValues(1, 20); pr:SetValueStep(1); pr:SetObeyStepOnDrag(true)
            _G[pr:GetName() .. "Low"]:SetText("1")
            _G[pr:GetName() .. "High"]:SetText("20")
            local prTxt = _G[pr:GetName() .. "Text"]
            pr:SetScript("OnShow", function(s)
                local sv = (db().bars or {})[key] or {}
                local n = sv.iconsPerRow or 8
                s:SetValue(n); prTxt:SetText("Icons per row: " .. n)
            end)
            pr:SetScript("OnValueChanged", function(s, v)
                v = math.floor(v + 0.5)
                prTxt:SetText("Icons per row: " .. v)
                db().bars = db().bars or {}; db().bars[key] = db().bars[key] or {}
                db().bars[key].iconsPerRow = v
                if GBI.Bar and GBI.Bar.ApplyAllBars then GBI.Bar.ApplyAllBars() end
            end)

            -- Grow direction (cooldowns only)
            local gdLbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            gdLbl:SetPoint("LEFT", pr, "RIGHT", 32, 0)
            gdLbl:SetText("Grow")
            local gd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
            gd:SetPoint("LEFT", gdLbl, "RIGHT", 6, 0); gd:SetWidth(110)
            local function curGrow()
                local sv = (db().bars or {})[key] or {}
                return sv.growDir or "RIGHT"
            end
            gd:SetupMenu(function(_, root)
                for _, dir in ipairs({ "RIGHT", "LEFT" }) do
                    root:CreateRadio(dir, function() return curGrow() == dir end, function()
                        db().bars = db().bars or {}; db().bars[key] = db().bars[key] or {}
                        db().bars[key].growDir = dir
                        if GBI.Bar and GBI.Bar.ApplyAllBars then GBI.Bar.ApplyAllBars() end
                        gd:GenerateMenu()
                    end)
                end
            end)
            gd:SetScript("OnShow", function() gd:GenerateMenu() end)
            lastSlider = pr
        end

        return lastSlider
    end

    local intControls = makeBarControls(content, barHeader, -8, "interrupts", "Interrupts window", true)
    local cdControls  = makeBarControls(content, intControls, -28, "cooldowns",  "Cooldowns window", false)

    -- Cooldown sort dropdown (also applies to UnitOverlay).
    local sortLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sortLbl:SetPoint("TOPLEFT", cdControls, "BOTTOMLEFT", 0, -16)
    sortLbl:SetText("Cooldown sort")
    local sortDD = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    sortDD:SetPoint("LEFT", sortLbl, "RIGHT", 8, 0); sortDD:SetWidth(220)
    local SORT_LIST = {
        { key = "endsAt",   label = "By remaining CD (default)" },
        { key = "offFirst", label = "Offensive first" },
        { key = "defFirst", label = "Defensive first" },
    }
    local function curSort() return db().cdSort or "endsAt" end
    sortDD:SetupMenu(function(_, root)
        for _, s in ipairs(SORT_LIST) do
            root:CreateRadio(s.label, function() return curSort() == s.key end, function()
                db().cdSort = s.key
                if GBI.Bar and GBI.Bar.ApplyAllBars then GBI.Bar.ApplyAllBars() end
                if GBI.UnitOverlay and GBI.UnitOverlay.Refresh then GBI.UnitOverlay.Refresh() end
                sortDD:GenerateMenu()
            end)
        end
    end)
    sortDD:SetScript("OnShow", function() sortDD:GenerateMenu() end)

    -- ============= 2. Interrupt alert ============= --
    local intHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    intHeader:SetPoint("TOPLEFT", sortDD, "BOTTOMLEFT", -16, -28)
    intHeader:SetText("Interrupt-pull alert")

    local intEnable = CreateFrame("CheckButton", nil, content,"UICheckButtonTemplate")
    intEnable:SetPoint("TOPLEFT", intHeader, "BOTTOMLEFT", 0, -2)
    cbLabel(intEnable):SetText("Enabled")
    intEnable:SetScript("OnShow", function(s)
        s:SetChecked(db().interrupt and db().interrupt.enabled and true or false)
    end)
    intEnable:SetScript("OnClick", function(s)
        db().interrupt = db().interrupt or {}
        db().interrupt.enabled = s:GetChecked() and true or false
    end)

    -- Delay slider 0.1 - 2.0 s
    local intSlider = CreateFrame("Slider", "GBI_IntDelaySlider", content, "OptionsSliderTemplate")
    intSlider:SetPoint("TOPLEFT", intEnable, "BOTTOMLEFT", 4, -28)
    intSlider:SetWidth(220)
    intSlider:SetMinMaxValues(0.1, 2.0)
    intSlider:SetValueStep(0.05)
    intSlider:SetObeyStepOnDrag(true)
    intSlider:SetScript("OnShow", function(s)
        db().interrupt = db().interrupt or {}
        s:SetValue(db().interrupt.seconds or 0.2)
    end)
    intSlider:SetScript("OnValueChanged", function(s, v)
        v = math.floor(v * 20 + 0.5) / 20
        db().interrupt = db().interrupt or {}
        db().interrupt.seconds = v
        local t = _G[s:GetName() .. "Text"]
        if t then t:SetText(("Delay after cast start: %.2fs"):format(v)) end
    end)
    _G["GBI_IntDelaySliderLow"]:SetText("0.1")
    _G["GBI_IntDelaySliderHigh"]:SetText("2.0")
    _G["GBI_IntDelaySliderText"]:SetText("Delay after cast start: 0.2s")

    -- Sound mode for interrupt
    local intSound = makeSoundModeRow(content, K.SOUND_CAT_INTERRUPT_ALERT, "Interrupt sound:")
    intSound:SetPoint("TOPLEFT", intSlider, "BOTTOMLEFT", -4, -22)

    -- ============= 3. Burst-ready ============= --
    local burstHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    burstHeader:SetPoint("TOPLEFT", intSound, "BOTTOMLEFT", 0, -16)
    burstHeader:SetText("Burst-ready alert")

    local burstSound = makeSoundModeRow(content, K.SOUND_CAT_CD_READY, "Burst sound:")
    burstSound:SetPoint("TOPLEFT", burstHeader, "BOTTOMLEFT", 0, -4)

    -- Mode: auto (every BIGCD the party uses) | manual (curated list) | both.
    local modeLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modeLabel:SetPoint("TOPLEFT", burstSound, "BOTTOMLEFT", 0, -8)
    modeLabel:SetText("Trigger source")

    local modeDD = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    modeDD:SetPoint("LEFT", modeLabel, "RIGHT", 8, 0)
    modeDD:SetWidth(220)
    local MODES_BURST = {
        { key = "auto",   label = "Auto - all party big CDs"   },
        { key = "manual", label = "Manual - only my list below" },
        { key = "both",   label = "Both"                         },
    }
    local function curBurstMode()
        return (db().burst and db().burst.mode) or "auto"
    end
    modeDD:SetupMenu(function(_, root)
        for _, m in ipairs(MODES_BURST) do
            root:CreateRadio(m.label, function() return curBurstMode() == m.key end, function()
                db().burst = db().burst or {}
                db().burst.mode = m.key
                modeDD:GenerateMenu()
            end)
        end
    end)
    modeDD:SetScript("OnShow", function() modeDD:GenerateMenu() end)

    local burstList = makeAllReadyEditor(content)
    burstList:SetPoint("TOPLEFT", modeLabel, "BOTTOMLEFT", 0, -12)
    panel._burstList = burstList

    -- ============= 4. Spell DB management (subpanel) ============= --
    local sdbPanel, sdbContent = makeSubPanel("Spell Database",
        "Pick a class+spec+category, untick spells you don't want tracked, or add custom spell IDs.")
    -- shadow `content` locally so the rest of this block lays out into the
    -- subpanel without needing to rewrite every reference
    local content = sdbContent
    local sdbHeader = sdbPanel._anchorTo
    local sdbHelp = sdbHeader     -- existing references use sdbHelp as anchor

    local classDD = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    classDD:SetPoint("TOPLEFT", sdbHelp, "BOTTOMLEFT", 0, -8)
    classDD:SetWidth(160)

    local CLASS_LIST = K.CLASS_TOKENS or {
        "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER", "MAGE",
        "MONK", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
    }
    local SPEC_NAMES = {
        DEATHKNIGHT = { "Blood", "Frost", "Unholy" },
        DEMONHUNTER = { "Havoc", "Vengeance", "Devourer" },
        DRUID       = { "Balance", "Feral", "Guardian", "Restoration" },
        EVOKER      = { "Devastation", "Preservation", "Augmentation" },
        HUNTER      = { "Beast Mastery", "Marksmanship", "Survival" },
        MAGE        = { "Arcane", "Fire", "Frost" },
        MONK        = { "Brewmaster", "Windwalker", "Mistweaver" },
        PALADIN     = { "Holy", "Protection", "Retribution" },
        PRIEST      = { "Discipline", "Holy", "Shadow" },
        ROGUE       = { "Assassination", "Outlaw", "Subtlety" },
        SHAMAN      = { "Elemental", "Enhancement", "Restoration" },
        WARLOCK     = { "Affliction", "Demonology", "Destruction" },
        WARRIOR     = { "Arms", "Fury", "Protection" },
    }
    local currentClass = CLASS_LIST[1]
    local currentSpec  = nil   -- nil = all specs
    local currentCat   = "ALL" -- ALL | OFFENSIVE | DEFENSIVE | INTERRUPT | UTILITY

    local listScroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", classDD, "BOTTOMLEFT", 0, -8)
    listScroll:SetSize(440, 200)
    local listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetSize(420, 1)
    listScroll:SetScrollChild(listContent)

    local listRows = {}
    local function rebuildList()
        for _, r in ipairs(listRows) do r:Hide() end
        listRows = {}
        if not (GBI.IterCooldowns or GBI.Cooldowns) then return end
        local entries = (GBI.IterCooldowns and GBI.IterCooldowns(true)) or GBI.Cooldowns or {}
        local matches = {}
        for sid, cd in pairs(entries) do
            if cd and cd.class == currentClass then
                local specOK = true
                if currentSpec then
                    if not cd.spec then
                        specOK = true        -- all-spec spell shows under any spec filter
                    else
                        specOK = false
                        for _, s in ipairs(cd.spec) do
                            if s == currentSpec then specOK = true; break end
                        end
                    end
                end
                local catOK = true
                if currentCat == "OFFENSIVE" then
                    catOK = cd.category == K.CAT_BIGCD or cd.category == K.CAT_OFFENSIVE
                elseif currentCat == "DEFENSIVE" then
                    catOK = cd.category == K.CAT_DEFENSIVE
                elseif currentCat == "INTERRUPT" then
                    catOK = cd.category == K.CAT_INTERRUPT
                elseif currentCat == "UTILITY" then
                    catOK = cd.category == K.CAT_UTILITY or cd.category == K.CAT_DISPEL
                end
                if specOK and catOK then
                    matches[#matches + 1] = { sid = sid, cd = cd }
                end
            end
        end
        table.sort(matches, function(a, b) return (a.cd.name or "") < (b.cd.name or "") end)
        local y = 0
        for _, m in ipairs(matches) do
            local row = CreateFrame("Frame", nil, listContent)
            row:SetSize(420, 22)
            row:SetPoint("TOPLEFT", 0, -y)
            local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            cb:SetPoint("LEFT", 0, 0)
            local sdb = db().spellDb or {}
            local disabled = sdb.disabled and sdb.disabled[m.sid]
            cb:SetChecked(not disabled)
            cb:SetScript("OnClick", function(s)
                db().spellDb = db().spellDb or { disabled = {}, custom = {} }
                db().spellDb.disabled = db().spellDb.disabled or {}
                db().spellDb.disabled[m.sid] = (not s:GetChecked()) and true or nil
            end)
            local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            lbl:SetText(("%d  %s  (%ds, %s)"):format(m.sid, m.cd.name or "?",
                m.cd.duration or 0, tostring(m.cd.category)))
            -- Custom entries get a remove button
            if (db().spellDb or {}).custom and db().spellDb.custom[m.sid] then
                local rm = CreateFrame("Button", nil, row, "UIPanelCloseButton")
                rm:SetSize(20, 20); rm:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                rm:SetScript("OnClick", function()
                    db().spellDb.custom[m.sid] = nil
                    rebuildList()
                end)
            end
            listRows[#listRows + 1] = row
            y = y + 24
        end
        listContent:SetHeight(math.max(y, 1))
    end

    local specDD = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    specDD:SetPoint("LEFT", classDD, "RIGHT", 8, 0); specDD:SetWidth(160)

    classDD:SetupMenu(function(_, root)
        for _, c in ipairs(CLASS_LIST) do
            root:CreateRadio(c, function() return currentClass == c end, function()
                currentClass = c
                currentSpec = nil
                specDD:GenerateMenu()
                rebuildList()
                classDD:GenerateMenu()
            end)
        end
    end)
    classDD:SetScript("OnShow", function() classDD:GenerateMenu(); rebuildList() end)

    specDD:SetupMenu(function(_, root)
        root:CreateRadio("All specs", function() return currentSpec == nil end, function()
            currentSpec = nil; rebuildList(); specDD:GenerateMenu()
        end)
        for i, name in ipairs(SPEC_NAMES[currentClass] or {}) do
            root:CreateRadio(name, function() return currentSpec == i end, function()
                currentSpec = i; rebuildList(); specDD:GenerateMenu()
            end)
        end
    end)
    specDD:SetScript("OnShow", function() specDD:GenerateMenu() end)

    local catDD = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    catDD:SetPoint("LEFT", specDD, "RIGHT", 8, 0); catDD:SetWidth(140)
    local CAT_LIST = {
        { key = "ALL",        label = "All categories" },
        { key = "OFFENSIVE",  label = "Offensive" },
        { key = "DEFENSIVE",  label = "Defensive" },
        { key = "INTERRUPT",  label = "Interrupt" },
        { key = "UTILITY",    label = "Utility / Dispel" },
    }
    catDD:SetupMenu(function(_, root)
        for _, c in ipairs(CAT_LIST) do
            root:CreateRadio(c.label, function() return currentCat == c.key end, function()
                currentCat = c.key; rebuildList(); catDD:GenerateMenu()
            end)
        end
    end)
    catDD:SetScript("OnShow", function() catDD:GenerateMenu() end)

    -- Add custom spell row
    local addLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addLabel:SetPoint("TOPLEFT", listScroll, "BOTTOMLEFT", 0, -10)
    addLabel:SetText("Add custom (id  name  duration  cat: bigcd|defensive|interrupt|utility|dispel):")

    local function mkInput(parent, prev, w, dx)
        local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        e:SetSize(w, 20); e:SetAutoFocus(false); e:SetMaxLetters(40)
        if prev then e:SetPoint("LEFT", prev, "RIGHT", dx or 8, 0)
        else e:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", 8, -8) end
        return e
    end
    local addId   = mkInput(content, nil, 60); addId:SetNumeric(true)
    local addName = mkInput(content, addId,  140)
    local addDur  = mkInput(content, addName, 50); addDur:SetNumeric(true)
    local addCat  = mkInput(content, addDur, 80)

    local addBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    addBtn:SetSize(90, 22)
    addBtn:SetPoint("LEFT", addCat, "RIGHT", 8, 0)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", function()
        local sid = tonumber(addId:GetText())
        local name = addName:GetText() or ""
        local dur = tonumber(addDur:GetText())
        local catRaw = (addCat:GetText() or ""):lower()
        local catMap = {
            bigcd = K.CAT_BIGCD, defensive = K.CAT_DEFENSIVE,
            interrupt = K.CAT_INTERRUPT, utility = K.CAT_UTILITY,
            dispel = K.CAT_DISPEL, offensive = K.CAT_OFFENSIVE,
        }
        local cat = catMap[catRaw]
        if not (sid and sid > 0 and dur and dur > 0 and cat and #name > 0) then return end
        db().spellDb = db().spellDb or { disabled = {}, custom = {} }
        db().spellDb.custom = db().spellDb.custom or {}
        db().spellDb.custom[sid] = {
            name = name, duration = dur, class = currentClass, category = cat,
        }
        addId:SetText(""); addName:SetText(""); addDur:SetText(""); addCat:SetText("")
        rebuildList()
    end)

    -- ============= 5. Profiles (subpanel) ============= --
    local profPanel, profContent = makeSubPanel("Profiles",
        "Save settings as named profiles. Export to share with friends; import from text.")
    local content = profContent     -- shadow for the Profiles block
    local profHeader = profPanel._anchorTo

    local profDD = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    profDD:SetPoint("TOPLEFT", profHeader, "BOTTOMLEFT", 0, -8)
    profDD:SetWidth(200)

    local function refreshProfDD()
        if profDD.GenerateMenu then profDD:GenerateMenu() end
    end
    profDD:SetupMenu(function(_, root)
        local active = GBI.Profiles and GBI.Profiles.GetActiveName() or "Default"
        for _, n in ipairs(GBI.Profiles and GBI.Profiles.List() or {}) do
            root:CreateRadio(n, function() return active == n end, function()
                if GBI.Profiles and GBI.Profiles.Load(n) then
                    StaticPopup_Show("GBI_PROFILE_LOADED")
                end
                refreshProfDD()
            end)
        end
    end)
    profDD:SetScript("OnShow", refreshProfDD)

    StaticPopupDialogs["GBI_PROFILE_LOADED"] = StaticPopupDialogs["GBI_PROFILE_LOADED"] or {
        text = "Profile loaded. Reload UI to apply?",
        button1 = "Reload", button2 = "Cancel",
        OnAccept = ReloadUI, timeout = 0, hideOnEscape = true,
    }

    local nameEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    nameEdit:SetPoint("LEFT", profDD, "RIGHT", 16, 0)
    nameEdit:SetSize(140, 22); nameEdit:SetAutoFocus(false); nameEdit:SetMaxLetters(32)

    local function btn(parent, anchor, dx, label, w, click)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(w or 70, 22)
        b:SetPoint("LEFT", anchor, "RIGHT", dx or 6, 0)
        b:SetText(label)
        b:SetScript("OnClick", click)
        return b
    end

    local saveBtn = btn(content, nameEdit, 6, "Save", 70, function()
        local n = nameEdit:GetText()
        if not n or n == "" then return end
        if GBI.Profiles and GBI.Profiles.Save(n) then
            nameEdit:SetText("")
            refreshProfDD()
        end
    end)
    local delBtn = btn(content, saveBtn, 6, "Delete", 70, function()
        local n = nameEdit:GetText()
        if not n or n == "" then n = (GBI.Profiles and GBI.Profiles.GetActiveName()) end
        if GBI.Profiles and GBI.Profiles.Delete(n) then
            refreshProfDD()
        end
    end)

    -- Import / export edit box.
    local ioBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    ioBox:SetPoint("TOPLEFT", profDD, "BOTTOMLEFT", 4, -28)
    ioBox:SetSize(440, 22); ioBox:SetAutoFocus(false); ioBox:SetMaxLetters(0)

    local exportBtn = btn(content, ioBox, 6, "Export", 70, function()
        local n = nameEdit:GetText()
        if not n or n == "" then n = (GBI.Profiles and GBI.Profiles.GetActiveName()) end
        local s = GBI.Profiles and GBI.Profiles.Export(n)
        if s then ioBox:SetText(s); ioBox:HighlightText() end
    end)
    btn(content, exportBtn, 6, "Import", 70, function()
        local n = nameEdit:GetText()
        if not n or n == "" then return end
        local txt = ioBox:GetText()
        if GBI.Profiles and GBI.Profiles.Import(n, txt) then
            ioBox:SetText("")
            refreshProfDD()
        end
    end)

    local profHelp = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profHelp:SetPoint("TOPLEFT", ioBox, "BOTTOMLEFT", 0, -4)
    profHelp:SetText("Type a profile name, then Save. To Export, click Export — copy the text. To Import, paste in the box and click Import.")
    profHelp:SetTextColor(0.7, 0.7, 0.7)

    -- Subpanel content heights
    sdbContent:SetHeight(900)
    profContent:SetHeight(450)
    -- Main panel content (General + Bars + Overlay + Sounds only now)
    panel._content:SetHeight(1100)

    -- Register
    category = Settings.RegisterCanvasLayoutCategory(panel, "GOBIGnINTERRUPT")
    Settings.RegisterAddOnCategory(category)
    -- Register each subpanel as a child category in the AddOns settings tree.
    for _, sp in ipairs(subpanels) do
        Settings.RegisterCanvasLayoutSubcategory(category, sp.frame, sp.name)
    end
end

-- ---------------------------------------------------------------------------
-- Public open + refresh
-- ---------------------------------------------------------------------------

function M.Refresh()
    if panel and panel._burstList and panel._burstList.Refresh then
        panel._burstList.Refresh()
    end
end

function GBI_OpenConfig()
    if InCombatLockdown() then
        print("|cffffaa00GBI:|r cannot open config in combat.")
        return
    end
    if not panel then buildPanel() end
    Settings.OpenToCategory(category:GetID())
    Settings.OpenToCategory(category:GetID())
end
