-- NewSettings.lua
-- Simple border demo using the finalized border frame values

local settingsMenu
local borderFrames = {}

-- View management
local views = {}
local activeViewName = nil

local function RegisterView(name, frame)
    views[name] = frame
    frame:Hide()
end

local function SwitchToView(name)
    for _, f in pairs(views) do f:Hide() end
    if views[name] then
        views[name]:Show()
        activeViewName = name
    end
end

local function CreateBorderFrame(parent, name, point, xOff, yOff, l, r, t, b, rot, width, height)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(width, height)
    frame:SetPoint(point, parent, point, xOff, yOff)
    frame:SetBackdropColor(0, 0, 0, 0)
    frame:SetBackdropBorderColor(0, 0, 0, 0)
    frame:EnableMouse(false)
    frame:SetMovable(false)
    frame:SetFrameLevel(settingsMenu:GetFrameLevel() + 2)
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(frame)
    tex:SetTexture(2406979)
    tex:SetTexCoord(l, r, t, b)
    if rot and rot ~= 0 then tex:SetRotation(math.rad(rot)) end
    return frame
end



local insetSettingsContainer
local pendingShowAfterCombat = false



local function ShowBorderDemo()
    if settingsMenu and settingsMenu:IsShown() then return end
    -- Can't open (or create) protected frames while in combat; queue for after.
    if InCombatLockdown() then
        if not pendingShowAfterCombat then
            pendingShowAfterCombat = true
        end
        return
    end

    if not settingsMenu then
        settingsMenu = CreateFrame("Frame", "ss_BorderDemo", UIParent, "BackdropTemplate")
        settingsMenu:Hide()  -- hide immediately so Show() later triggers OnShow hooks
		local width = 400
        settingsMenu:SetSize(width, 600)
        settingsMenu:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        settingsMenu:SetBackdrop({ bgFile = 374155 })
        settingsMenu:SetBackdropColor(1, 1, 1, 1)
        settingsMenu:EnableMouse(true)
        settingsMenu:SetMovable(true)
		settingsMenu:SetFrameStrata("DIALOG") -- or "DIALOG"
		settingsMenu:SetFrameLevel(10) 
        settingsMenu:RegisterForDrag("LeftButton")
        settingsMenu:SetScript("OnDragStart", settingsMenu.StartMoving)
        settingsMenu:SetScript("OnDragStop", settingsMenu.StopMovingOrSizing)
        
        -- Disable dragging when menu is hidden
        settingsMenu:SetScript("OnHide", function()
            if SpellStyler.FrameTrackerManager and SpellStyler.FrameTrackerManager.DisableDraggingForAllFrames then
                SpellStyler.FrameTrackerManager:DisableDraggingForAllFrames()
            end
        end)
        
        -- Portrait frame: above the background backdrop, below the border frames.
        -- Created before the border frames so equal-level border children render on top.
        local portraitHolder = CreateFrame("Frame", nil, settingsMenu)
        portraitHolder:SetSize(80, 80)
        portraitHolder:SetPoint("TOPLEFT", settingsMenu, "TOPLEFT", -2, 9)
        portraitHolder:SetFrameLevel(settingsMenu:GetFrameLevel() + 1)

        local portraitTex = portraitHolder:CreateTexture(nil, "ARTWORK")
        portraitTex:SetAllPoints(portraitHolder)

        -- Render the player's portrait face onto the texture.
        -- SetPortraitTexture(texture, unit) is the correct retail API for this;
        -- SetPortraitToTexture was removed in patch 12.0.0.
        -- PlayerSpellsFramePortrait is a PlayerModel (3D), not a flat texture, so
        -- we can't copy its texture directly.
        SetPortraitTexture(portraitTex, "player")

        -- Circular crop via mask texture
        local circleMask = portraitHolder:CreateMaskTexture()
        circleMask:SetAllPoints(portraitTex)
        circleMask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        portraitTex:AddMaskTexture(circleMask)

        -- Add border children
        borderFrames[1] = CreateBorderFrame(settingsMenu, "TopLeftCorner", "TOPLEFT", -22, 22,      0.000, 0.28,  0.316, 0.59,  0,     110, 108)
        borderFrames[2] = CreateBorderFrame(settingsMenu, "TopRightCorner", "TOPRIGHT", 54, 28.99,  0.800, 1,     0.002, 0.255, 0,     80, 100)
        borderFrames[3] = CreateBorderFrame(settingsMenu, "LineLeft", "LEFT", -22, -28,             0.000, 0.14,  0.221, 0.290, 0,     55, 485)
        borderFrames[4] = CreateBorderFrame(settingsMenu, "LineRight", "RIGHT", 23, -13,            0.000, 0.14,  0.221, 0.290, 180,   55, 485)
        borderFrames[5] = CreateBorderFrame(settingsMenu, "TopBar", "BOTTOM", 2, -27.9,             0.075, 0.45,  0.002, 0.255, 180,     350, 100)
        borderFrames[6] = CreateBorderFrame(settingsMenu, "Corner1", "BOTTOMRIGHT", -373, -28,      0.800, 1,     0.002, 0.255, -180,     80, 100)
        borderFrames[7] = CreateBorderFrame(settingsMenu, "Corner2", "BOTTOMLEFT", 374, -28,       1,     0.800, 0.002, 0.255, -180,     80, 100)
        borderFrames[8] = CreateBorderFrame(settingsMenu, "TopBar", "TOP", 31, 29,                  0.075, 0.45,  0.002, 0.255, 0,     286, 100)

        -- Add title text (wrapped in a Frame so SetFrameLevel is available)
        local titleFrame = CreateFrame("Frame", nil, settingsMenu)
        titleFrame:SetSize(200, 30)
        titleFrame:SetPoint("TOP", settingsMenu, "TOP", 20, 0)
        titleFrame:SetFrameLevel(settingsMenu:GetFrameLevel() + 3)
        local title = titleFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetAllPoints(titleFrame)
        title:SetText("Spell Styler")
        title:SetTextColor(1, 0.82, 0)
        
        -- Add close button
        local closeBtn = CreateFrame("Button", nil, settingsMenu, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", settingsMenu, "TOPRIGHT", -3, -2)
        closeBtn:SetScript("OnClick", function()
            settingsMenu:Hide()
        end)

        -- ESC key handler
        settingsMenu:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                self:Hide()
            end
        end)

        -- Allow the frame to receive keyboard events but let most keys propagate
        -- to the game (so WASD and other movement keys still work).
        settingsMenu:EnableKeyboard(true)
        pcall(function() 
            settingsMenu:SetPropagateKeyboardInput(true)
        end)

        -- Create an inset frame the settings
        insetSettingsContainer = CreateFrame("Frame", nil, settingsMenu, "BackdropTemplate")
        insetSettingsContainer:SetPoint("TOPLEFT", settingsMenu, "TOPLEFT", 5, -80)
        insetSettingsContainer:SetPoint("BOTTOMRIGHT", settingsMenu, "BOTTOMRIGHT", -5, 35)
        insetSettingsContainer:SetBackdrop({
            bgFile = 374154,
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        insetSettingsContainer:SetBackdropColor(0.15, 0.15, 0.15, 0.85)
        insetSettingsContainer:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

        -- Add "Update" button (refreshes all tracker hooks and viewer visibility)
        local updateBtn = CreateFrame("Button", nil, insetSettingsContainer, "UIPanelButtonTemplate")
        updateBtn:SetSize(70, 22)
        updateBtn:SetPoint("BOTTOMRIGHT", settingsMenu, "BOTTOMRIGHT", -10, 5)
        updateBtn:SetText("Update")
        updateBtn:SetFrameLevel(settingsMenu:GetFrameLevel() + 3)

        local cdmToggleBtn = CreateFrame("Button", nil, insetSettingsContainer, "UIPanelButtonTemplate")
        cdmToggleBtn:SetSize(100, 22)
        cdmToggleBtn:SetPoint("BOTTOMLEFT", settingsMenu, "BOTTOMLEFT", 10, 5)
        cdmToggleBtn:SetText("Toggle CDM")
        cdmToggleBtn:SetFrameLevel(settingsMenu:GetFrameLevel() + 3)
        cdmToggleBtn:SetScript("OnClick", function()
            pcall(function()
                if CooldownViewerSettings:IsShown() then
                    HideUIPanel(CooldownViewerSettings)
                else
                    ShowUIPanel(CooldownViewerSettings) 
                end
            end)
        end)



        -- View frames inside the inset container
        local settingsContentFrame = CreateFrame("Frame", nil, insetSettingsContainer)
        settingsContentFrame:SetAllPoints(insetSettingsContainer)
        settingsContentFrame:SetFrameLevel(insetSettingsContainer:GetFrameLevel() + 1)

        local helpContentFrame = CreateFrame("Frame", nil, insetSettingsContainer)
        helpContentFrame:SetAllPoints(insetSettingsContainer)
        helpContentFrame:SetFrameLevel(insetSettingsContainer:GetFrameLevel() + 1)

        -- ---- Containers view ----
        local containerContentFrame = CreateFrame("Frame", nil, insetSettingsContainer)
        containerContentFrame:SetAllPoints(insetSettingsContainer)
        containerContentFrame:SetFrameLevel(insetSettingsContainer:GetFrameLevel() + 1)

        -- ---- Utility view ----
        local utilityContentFrame = CreateFrame("Frame", nil, insetSettingsContainer)
        utilityContentFrame:SetAllPoints(insetSettingsContainer)
        utilityContentFrame:SetFrameLevel(insetSettingsContainer:GetFrameLevel() + 1)

        -- Blizzard frame visibility section
        local visLabel = utilityContentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        visLabel:SetPoint("TOPLEFT", utilityContentFrame, "TOPLEFT", 12, -16)
        visLabel:SetText("|cFFFFD700Blizzard Frame Visibility|r")

        local function MakeViewerToggleButton(trackerType, label, anchorFrame)
            local btn = CreateFrame("Button", nil, utilityContentFrame, "UIPanelButtonTemplate")
            btn:SetSize(110, 26)
            btn:SetFrameLevel(utilityContentFrame:GetFrameLevel() + 1)
            if anchorFrame then
                btn:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", 8, 0)
            else
                btn:SetPoint("TOPLEFT", visLabel, "BOTTOMLEFT", 0, -10)
            end

            local function RefreshLabel()
                local FTM = SpellStyler.FrameTrackerManager
                if FTM and FTM.GetViewerHidden then
                    if FTM:GetViewerHidden(trackerType) then
                        btn:SetText("|cFF888888" .. label .. "|r")
                    else
                        btn:SetText("|cFFFFD700" .. label .. "|r")
                    end
                else
                    btn:SetText(label)
                end
            end

            btn:SetScript("OnClick", function()
                local FTM = SpellStyler.FrameTrackerManager
                if FTM and FTM.SetViewerHidden and FTM.ApplyViewerVisibility then
                    FTM:SetViewerHidden(trackerType, not FTM:GetViewerHidden(trackerType))
                    FTM:ApplyViewerVisibility(trackerType)
                end
                RefreshLabel()
            end)

            utilityContentFrame:HookScript("OnShow", RefreshLabel)
            RefreshLabel()
            return btn
        end

        local buffsViewerBtn     = MakeViewerToggleButton("buffs",     "Buffs",     nil)
        local essentialViewerBtn = MakeViewerToggleButton("essential", "Essential", buffsViewerBtn)
        MakeViewerToggleButton("utility", "Utility", essentialViewerBtn)

        -- Database section
        local dbLabel = utilityContentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dbLabel:SetPoint("TOPLEFT", utilityContentFrame, "TOPLEFT", 12, -78)
        dbLabel:SetText("|cFFFFD700Database|r")

        local wipeDbBtn = CreateFrame("Button", nil, utilityContentFrame, "UIPanelButtonTemplate")
        wipeDbBtn:SetSize(130, 26)
        wipeDbBtn:SetPoint("TOPLEFT", dbLabel, "BOTTOMLEFT", 0, -10)
        wipeDbBtn:SetFrameLevel(utilityContentFrame:GetFrameLevel() + 1)
        wipeDbBtn:SetText("|cFFFF4444Wipe Database|r")

        local wipeConfirmPopup = CreateFrame("Frame", nil, utilityContentFrame, "BackdropTemplate")
        wipeConfirmPopup:SetSize(220, 80)
        wipeConfirmPopup:SetPoint("TOP", wipeDbBtn, "BOTTOM", 0, -6)
        wipeConfirmPopup:SetFrameLevel(utilityContentFrame:GetFrameLevel() + 10)
        wipeConfirmPopup:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = false, edgeSize = 12,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        wipeConfirmPopup:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        wipeConfirmPopup:SetBackdropBorderColor(0.8, 0.2, 0.2, 1)
        wipeConfirmPopup:Hide()

        local wipeConfirmText = wipeConfirmPopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        wipeConfirmText:SetPoint("TOP", wipeConfirmPopup, "TOP", 0, -12)
        wipeConfirmText:SetText("Wipe all icon data?")
        wipeConfirmText:SetTextColor(1, 0.4, 0.4)

        local wipeYesBtn = CreateFrame("Button", nil, wipeConfirmPopup, "UIPanelButtonTemplate")
        wipeYesBtn:SetSize(80, 22)
        wipeYesBtn:SetPoint("BOTTOMLEFT", wipeConfirmPopup, "BOTTOMLEFT", 14, 10)
        wipeYesBtn:SetText("|cFF44FF44Yes|r")
        wipeYesBtn:SetScript("OnClick", function()
            wipeConfirmPopup:Hide()
            SpellStyler_CharDB.classSpecializations = {}
            SpellStyler.FrameTrackerManager:SetupCooldownManagerHooks()
        end)

        local wipeNoBtn = CreateFrame("Button", nil, wipeConfirmPopup, "UIPanelButtonTemplate")
        wipeNoBtn:SetSize(80, 22)
        wipeNoBtn:SetPoint("BOTTOMRIGHT", wipeConfirmPopup, "BOTTOMRIGHT", -14, 10)
        wipeNoBtn:SetText("No")
        wipeNoBtn:SetScript("OnClick", function()
            wipeConfirmPopup:Hide()
        end)

        wipeDbBtn:SetScript("OnClick", function()
            if wipeConfirmPopup:IsShown() then
                wipeConfirmPopup:Hide()
            else
                wipeConfirmPopup:Show()
            end
        end)

        SpellStyler.HelpContentRenderer:RenderHelpView(helpContentFrame)
        SpellStyler.IconSettingsRenderer:RenderIconControlView(settingsContentFrame)
        SpellStyler.ContainerSettingsRenderer:RenderContainerView(containerContentFrame)

        RegisterView("icons",      settingsContentFrame)
        RegisterView("help",       helpContentFrame)
        RegisterView("containers", containerContentFrame)
        RegisterView("utility",    utilityContentFrame)
        SwitchToView("icons")

        -- Store references globally so other modules can update the settings menu
        SpellStyler.settingsMenu = settingsMenu
        SpellStyler.settingsContentFrame = settingsContentFrame
        SpellStyler.SwitchSettingsView = SwitchToView

        -- Now that settingsContentFrame exists, wire up the Update button
        updateBtn:SetScript("OnClick", function()
            for _, tType in ipairs({"buffs", "essential", "utility"}) do
                SpellStyler.FrameTrackerManager:HookAllBuffCooldownFrames(tType)
                SpellStyler.FrameTrackerManager:ApplyViewerVisibility(tType)
            end
            -- Re-render the icon list so new/removed trackers appear
            SpellStyler.IconSettingsRenderer:RenderIconControlView(settingsContentFrame)
            -- Enable dragging for any newly created frames
            if SpellStyler.FrameTrackerManager.EnableDraggingForAllFrames then
                SpellStyler.FrameTrackerManager:EnableDraggingForAllFrames()
            end
        end)

        -- ============================
        -- Tab bar: parented to UIParent so it can sit BEHIND settingsMenu.
        -- Children of settingsMenu cannot have a lower FrameLevel than the menu
        -- itself, so we parent to UIParent and manage visibility manually.
        -- ============================
        local tabFaceW = 100
        local tabH     = 40
        local tabGap   = 6

        local tabBar = CreateFrame("Frame", nil, UIParent)
        tabBar:SetWidth(tabFaceW + 55)
        tabBar:SetFrameLevel(settingsMenu:GetFrameLevel() - 1)  -- one level BEHIND settingsMenu
        tabBar:SetPoint("TOPLEFT", settingsMenu, "TOPRIGHT", 0, -100)

        -- Keep tabBar visible only while settingsMenu is shown
        settingsMenu:HookScript("OnShow", function()
            tabBar:Show()
            if SpellStyler.Containers then
                SpellStyler.Containers:SetEditMode(true)
            end
        end)
        settingsMenu:HookScript("OnHide", function()
            tabBar:Hide()
            if SpellStyler.Containers then SpellStyler.Containers:SetEditMode(false) end
        end)
        
        local tabSpells     = SpellStyler.CreateTab(tabBar, "Spells",     tabFaceW, tabH)
        local tabHelp       = SpellStyler.CreateTab(tabBar, "Help",       tabFaceW, tabH)
        local tabContainers = SpellStyler.CreateTab(tabBar, "Containers", tabFaceW, tabH)
        local tabUtility    = SpellStyler.CreateTab(tabBar, "Utility",    tabFaceW, tabH)

        tabBar:SetHeight(4 * tabH + 3 * tabGap)

        tabSpells:SetPoint("TOPLEFT",     tabBar,        "TOPLEFT", 0, 0)
        tabHelp:SetPoint("TOPLEFT",       tabSpells,     "BOTTOMLEFT", 0, -tabGap)
        tabContainers:SetPoint("TOPLEFT", tabHelp,       "BOTTOMLEFT", 0, -tabGap)
        tabUtility:SetPoint("TOPLEFT",    tabContainers, "BOTTOMLEFT", 0, -tabGap)

        tabSpells.onTabClick     = function() SwitchToView("icons") end
        tabHelp.onTabClick       = function() SwitchToView("help") end
        tabContainers.onTabClick = function() SwitchToView("containers") end
        tabUtility.onTabClick    = function() SwitchToView("utility") end

        SpellStyler.SetTabGroupExclusive({ tabSpells, tabHelp, tabContainers, tabUtility })
        tabSpells:SetSelected(true)
    end
	if SpellStyler.FrameTrackerManager then
		if SpellStyler.FrameTrackerManager.SetFrameClickCallback and SpellStyler._selectIconInSettings then
			SpellStyler.FrameTrackerManager:SetFrameClickCallback(function(uniqueID, trackerType)
				SpellStyler._selectIconInSettings(uniqueID, trackerType)
			end)
		end
		if SpellStyler.FrameTrackerManager.EnableDraggingForAllFrames then
			SpellStyler.FrameTrackerManager:EnableDraggingForAllFrames()
		end
	end
    settingsMenu:Show()
end

-- Combat-delay event frame: opens settings after combat, force-closes on combat enter
local combatDelayFrame = CreateFrame("Frame")
combatDelayFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatDelayFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
combatDelayFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Force-close the settings menu when entering combat
        if settingsMenu and settingsMenu:IsShown() then
            settingsMenu:Hide()
            pendingShowAfterCombat = true -- automatically reopen if it was forced closed
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingShowAfterCombat then
            pendingShowAfterCombat = false
            ShowBorderDemo()
        end
    end
end)

_G["SLASH_SPELLSTYLER1"] = "/SpellStyler"
_G["SLASH_SPELLSTYLER2"] = "/spellstyler"
_G["SLASH_SPELLSTYLER3"] = "/ss"
SlashCmdList["SPELLSTYLER"] = function(msg)
    ShowBorderDemo()
end
