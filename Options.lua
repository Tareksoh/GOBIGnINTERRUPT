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
    local showAlways  = mkToggle(lockTgl,   -2, "showAlways", "Show outside dungeons too")

    local glowTgl = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    glowTgl:SetPoint("TOPLEFT", showAlways, "BOTTOMLEFT", 0, -2)
    cbLabel(glowTgl):SetText("Glow icons in last 2s before ready")
    glowTgl:SetScript("OnShow", function(s) s:SetChecked(db().glow and true or false) end)
    glowTgl:SetScript("OnClick", function(s) db().glow = s:GetChecked() and true or false end)

    local overlayTgl = CreateFrame("CheckButton", nil, content,"UICheckButtonTemplate")
    overlayTgl:SetPoint("TOPLEFT", glowTgl, "BOTTOMLEFT", 0, -2)
    cbLabel(overlayTgl):SetText("Show CDs on party frames (hides Cooldown window)")
    overlayTgl:SetScript("OnShow", function(s)
        s:SetChecked(db().unitOverlay and db().unitOverlay.enabled and true or false)
    end)
    overlayTgl:SetScript("OnClick", function(s)
        db().unitOverlay = db().unitOverlay or {}
        db().unitOverlay.enabled = s:GetChecked() and true or false
        if GBI.Bar and GBI.Bar.RefreshLayout then GBI.Bar.RefreshLayout() end
    end)

    -- side dropdown ---------------------------------------------------------
    local sideLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sideLabel:SetPoint("TOPLEFT", overlayTgl, "BOTTOMLEFT", 24, -8)
    sideLabel:SetText("Anchor side")

    local sideDD = CreateFrame("DropdownButton", nil, content,"WowStyle1DropdownTemplate")
    sideDD:SetPoint("LEFT", sideLabel, "RIGHT", 8, 0)
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
            local def = (key == "iconSize") and 28 or 0
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

    local sliderX = mkOffsetSlider(sideLabel, -28, "offsetX", "X offset", -200, 200)
    local sliderY = mkOffsetSlider(sliderX,   -22, "offsetY", "Y offset", -200, 200)
    local sliderSize = mkOffsetSlider(sliderY, -22, "iconSize", "Overlay icon size", 16, 64)

    -- test-mode toggle button (sits next to sliders)
    local testBtn = CreateFrame("Button", nil, content,"UIPanelButtonTemplate")
    testBtn:SetSize(140, 22)
    testBtn:SetPoint("LEFT", sliderY, "RIGHT", 24, 0)
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
    barHeader:SetPoint("TOPLEFT", sliderSize, "BOTTOMLEFT", -24, -36)
    barHeader:SetText("Bar appearance")

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

    local function makeBarControls(parent, anchorTo, dy, key, label)
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

        -- Icons per row
        local pr = CreateFrame("Slider", "GBIBarPerRow_" .. key, parent, "OptionsSliderTemplate")
        pr:SetPoint("TOPLEFT", sz, "BOTTOMLEFT", 0, -22)
        pr:SetWidth(180); pr:SetMinMaxValues(1, 20); pr:SetValueStep(1); pr:SetObeyStepOnDrag(true)
        _G[pr:GetName() .. "Low"]:SetText("1")
        _G[pr:GetName() .. "High"]:SetText("20")
        local prTxt = _G[pr:GetName() .. "Text"]
        pr:SetScript("OnShow", function(s)
            local saved = (db().bars or {})[key] or {}
            local n = saved.iconsPerRow or 8
            s:SetValue(n); prTxt:SetText("Icons per row: " .. n)
        end)
        pr:SetScript("OnValueChanged", function(s, v)
            v = math.floor(v + 0.5)
            prTxt:SetText("Icons per row: " .. v)
            db().bars = db().bars or {}; db().bars[key] = db().bars[key] or {}
            db().bars[key].iconsPerRow = v
            if GBI.Bar and GBI.Bar.ApplyAllBars then GBI.Bar.ApplyAllBars() end
        end)

        -- Grow direction
        local gdLbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        gdLbl:SetPoint("LEFT", pr, "RIGHT", 32, 0)
        gdLbl:SetText("Grow")
        local gd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
        gd:SetPoint("LEFT", gdLbl, "RIGHT", 6, 0); gd:SetWidth(110)
        local function curGrow()
            local saved = (db().bars or {})[key] or {}
            return saved.growDir or "RIGHT"
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

        return pr  -- caller anchors next group below this
    end

    local intControls = makeBarControls(content, barHeader, -8, "interrupts", "Interrupts window")
    local cdControls  = makeBarControls(content, intControls, -28, "cooldowns",  "Cooldowns window")

    -- ============= 2. Interrupt alert ============= --
    local intHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    intHeader:SetPoint("TOPLEFT", cdControls, "BOTTOMLEFT", -16, -28)
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

    -- Register
    category = Settings.RegisterCanvasLayoutCategory(panel, "GOBIGnINTERRUPT")
    Settings.RegisterAddOnCategory(category)
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
