-- Minimap button. Left-click opens config; right-click toggles unit overlay.
-- Position is stored as polar angle around the minimap, saved in
-- GOBIGnINTERRUPTDB.minimap.angle so it persists across sessions.

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.MinimapIcon = GBI.MinimapIcon or {}
local M = GBI.MinimapIcon

local ICON = "Interface\\Icons\\spell_fire_selfdestruct"
local RADIUS = 80

local btn

local function db()
    GOBIGnINTERRUPTDB = GOBIGnINTERRUPTDB or {}
    GOBIGnINTERRUPTDB.minimap = GOBIGnINTERRUPTDB.minimap or { angle = 200, hidden = false }
    return GOBIGnINTERRUPTDB.minimap
end

local function placeAtAngle(angle)
    local rad = math.rad(angle)
    local x, y = math.cos(rad) * RADIUS, math.sin(rad) * RADIUS
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function onUpdateDrag(self)
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    local angle = math.deg(math.atan2(py - my, px - mx))
    db().angle = angle
    placeAtAngle(angle)
end

function M.Show() if btn then btn:Show() end; db().hidden = false end
function M.Hide() if btn then btn:Hide() end; db().hidden = true end
function M.Toggle()
    if not btn then return end
    if btn:IsShown() then M.Hide() else M.Show() end
end

local function build()
    if btn then return btn end
    btn = CreateFrame("Button", "GOBIGnINTERRUPT_MinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture(ICON)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon

    btn:SetScript("OnDragStart", function(s) s:SetScript("OnUpdate", onUpdateDrag) end)
    btn:SetScript("OnDragStop",  function(s) s:SetScript("OnUpdate", nil) end)

    btn:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "LeftButton" then
            if _G.GBI_OpenConfig then _G.GBI_OpenConfig() end
        elseif mouseButton == "RightButton" then
            GOBIGnINTERRUPTDB.unitOverlay = GOBIGnINTERRUPTDB.unitOverlay or {}
            -- Toggle the unified cooldownsMode field instead of the legacy
            -- unitOverlay.enabled (which can drift apart from cooldownsMode).
            GOBIGnINTERRUPTDB.show = GOBIGnINTERRUPTDB.show or {}
            local cur = GOBIGnINTERRUPTDB.show.cooldownsMode or "bar"
            GOBIGnINTERRUPTDB.show.cooldownsMode = (cur == "overlay") and "bar" or "overlay"
            if GBI.Bar and GBI.Bar.RefreshLayout then GBI.Bar.RefreshLayout() end
        end
    end)

    btn:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff66ddffGOBIGnINTERRUPT|r")
        GameTooltip:AddLine("Left-click: open config", 1, 1, 1)
        GameTooltip:AddLine("Right-click: toggle CDs on party frames", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    placeAtAngle(db().angle or 200)
    if db().hidden then btn:Hide() else btn:Show() end
    return btn
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() build() end)
