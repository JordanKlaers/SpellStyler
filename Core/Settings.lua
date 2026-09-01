local addonName, SpellStyler = ...
local FrameTrackerManager = SpellStyler.FrameTrackerManager
local State = SpellStyler.State
-- NewSettings.lua
-- Simple border demo using the finalized border frame values

SpellStyler.settingsMenu = nil
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
    frame:SetFrameLevel(SpellStyler.settingsMenu:GetFrameLevel() + 2)
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
    if SpellStyler.settingsMenu and SpellStyler.settingsMenu:IsShown() then return end
    -- Can't open (or create) protected frames while in combat; queue for after.
    if InCombatLockdown() then
        if not pendingShowAfterCombat then
            pendingShowAfterCombat = true
        end
        return
    end

    if not SpellStyler.settingsMenu then
        SpellStyler.settingsMenu = CreateFrame("Frame", "ss_BorderDemo", UIParent, "BackdropTemplate")
        SpellStyler.settingsMenu:Hide()  -- hide immediately so Show() later triggers OnShow hooks
		local width = 400
        SpellStyler.settingsMenu:SetSize(width, 600)
        SpellStyler.settingsMenu:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        SpellStyler.settingsMenu:SetBackdrop({ bgFile = 374155 })
        SpellStyler.settingsMenu:SetBackdropColor(1, 1, 1, 1)
        SpellStyler.settingsMenu:EnableMouse(true)
        SpellStyler.settingsMenu:SetMovable(true)
		SpellStyler.settingsMenu:SetFrameStrata("DIALOG") -- or "DIALOG"
		SpellStyler.settingsMenu:SetFrameLevel(10) 
        SpellStyler.settingsMenu:RegisterForDrag("LeftButton")
        SpellStyler.settingsMenu:SetScript("OnDragStart", SpellStyler.settingsMenu.StartMoving)
        SpellStyler.settingsMenu:SetScript("OnDragStop", SpellStyler.settingsMenu.StopMovingOrSizing)
        
        -- Disable dragging when menu is hidden
        SpellStyler.settingsMenu:SetScript("OnHide", function()
            if SpellStyler.IconSettingsRenderer and SpellStyler.IconSettingsRenderer.DisableDraggingForAllFrames then
                SpellStyler.IconSettingsRenderer:DisableDraggingForAllFrames()
            end
            -- Disable buff placeholder dragging and hide placeholders
            if SpellStyler.BuffManager and SpellStyler.BuffManager.EnablePlaceholderDragging then
                SpellStyler.BuffManager:EnablePlaceholderDragging(false)
            end
            -- Refresh all buff auras when settings menu closes
            if SpellStyler.BuffManager and SpellStyler.BuffManager.RefreshAllBuffAuras then
                SpellStyler.BuffManager:RefreshAllBuffAuras()
            end
        end)
        
        -- Enable dragging when menu is shown
        SpellStyler.settingsMenu:SetScript("OnShow", function()
            -- Enable buff placeholder dragging and show placeholders
            if SpellStyler.BuffManager and SpellStyler.BuffManager.EnablePlaceholderDragging then
                SpellStyler.BuffManager:EnablePlaceholderDragging(true)
            end
        end)
        
        -- Portrait frame: above the background backdrop, below the border frames.
        -- Created before the border frames so equal-level border children render on top.
        local portraitHolder = CreateFrame("Frame", nil, SpellStyler.settingsMenu)
        portraitHolder:SetSize(80, 80)
        portraitHolder:SetPoint("TOPLEFT", SpellStyler.settingsMenu, "TOPLEFT", -2, 9)
        portraitHolder:SetFrameLevel(SpellStyler.settingsMenu:GetFrameLevel() + 1)

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
        borderFrames[1] = CreateBorderFrame(SpellStyler.settingsMenu, "TopLeftCorner", "TOPLEFT", -22, 22,      0.000, 0.28,  0.316, 0.59,  0,     110, 108)
        borderFrames[2] = CreateBorderFrame(SpellStyler.settingsMenu, "TopRightCorner", "TOPRIGHT", 54, 28.99,  0.800, 1,     0.002, 0.255, 0,     80, 100)
        borderFrames[3] = CreateBorderFrame(SpellStyler.settingsMenu, "LineLeft", "LEFT", -22, -28,             0.000, 0.14,  0.221, 0.290, 0,     55, 485)
        borderFrames[4] = CreateBorderFrame(SpellStyler.settingsMenu, "LineRight", "RIGHT", 23, -13,            0.000, 0.14,  0.221, 0.290, 180,   55, 485)
        borderFrames[5] = CreateBorderFrame(SpellStyler.settingsMenu, "TopBar", "BOTTOM", 2, -27.9,             0.075, 0.45,  0.002, 0.255, 180,     350, 100)
        borderFrames[6] = CreateBorderFrame(SpellStyler.settingsMenu, "Corner1", "BOTTOMRIGHT", -373, -28,      0.800, 1,     0.002, 0.255, -180,     80, 100)
        borderFrames[7] = CreateBorderFrame(SpellStyler.settingsMenu, "Corner2", "BOTTOMLEFT", 374, -28,       1,     0.800, 0.002, 0.255, -180,     80, 100)
        borderFrames[8] = CreateBorderFrame(SpellStyler.settingsMenu, "TopBar", "TOP", 31, 29,                  0.075, 0.45,  0.002, 0.255, 0,     286, 100)

        -- Add title text (wrapped in a Frame so SetFrameLevel is available)
        local titleFrame = CreateFrame("Frame", nil, SpellStyler.settingsMenu)
        titleFrame:SetSize(200, 30)
        titleFrame:SetPoint("TOP", SpellStyler.settingsMenu, "TOP", 20, 0)
        titleFrame:SetFrameLevel(SpellStyler.settingsMenu:GetFrameLevel() + 3)
        local title = titleFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetAllPoints(titleFrame)
        title:SetText("Spell Styler")
        title:SetTextColor(1, 0.82, 0)
        
        -- Add close button
        local closeBtn = CreateFrame("Button", nil, SpellStyler.settingsMenu, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", SpellStyler.settingsMenu, "TOPRIGHT", -3, -2)
        closeBtn:SetScript("OnClick", function()
            if SpellStyler.IconSettingsRenderer.keyboardFrame then SpellStyler.IconSettingsRenderer.keyboardFrame:EnableKeyboard(false) end
            SpellStyler.settingsMenu:Hide()
        end)

        -- ESC key handler
        SpellStyler.settingsMenu:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                if SpellStyler.IconSettingsRenderer.keyboardFrame then SpellStyler.IconSettingsRenderer.keyboardFrame:EnableKeyboard(false) end
                self:Hide()
            end
        end)

        -- Allow the frame to receive keyboard events but let most keys propagate
        -- to the game (so WASD and other movement keys still work).
        SpellStyler.settingsMenu:EnableKeyboard(true)
        
        SpellStyler.settingsMenu:SetPropagateKeyboardInput(true)

        -- Create an inset frame the settings
        insetSettingsContainer = CreateFrame("Frame", nil, SpellStyler.settingsMenu, "BackdropTemplate")
        insetSettingsContainer:SetPoint("TOPLEFT", SpellStyler.settingsMenu, "TOPLEFT", 5, -80)
        insetSettingsContainer:SetPoint("BOTTOMRIGHT", SpellStyler.settingsMenu, "BOTTOMRIGHT", -5, 35)
        insetSettingsContainer:SetBackdrop({
            bgFile = 374154,
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        insetSettingsContainer:SetBackdropColor(0.15, 0.15, 0.15, 0.85)
        insetSettingsContainer:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)


        local auraRefreshBtn = CreateFrame("Button", nil, insetSettingsContainer, "UIPanelButtonTemplate")
        auraRefreshBtn:SetSize(160, 22)
        auraRefreshBtn:SetPoint("BOTTOMLEFT", SpellStyler.settingsMenu, "BOTTOMLEFT", 10, 5)
        auraRefreshBtn:SetText("Force Refresh Auras")
        auraRefreshBtn:SetFrameLevel(SpellStyler.settingsMenu:GetFrameLevel() + 3)
        auraRefreshBtn:SetScript("OnClick", function()
            SpellStyler.BuffManager:EnableAllAuras()
        end)
        auraRefreshBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local hasSecretAuras = C_Secrets.ShouldAurasBeSecret()
            local tooltipText = hasSecretAuras and 'You are experiencing aura lockdown. This will only refresh the aura data, handled by blizzard. If auras are no longer secret it should also update any settings.' or 'This should update aura data, handled by blizzard as well as any settings that affect the auras display.'
            GameTooltip:SetText(tooltipText, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        auraRefreshBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        auraRefreshBtn:EnableMouse(true)



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

        -- ---- Conditions view ----
        local conditionsContentFrame = CreateFrame("Frame", nil, insetSettingsContainer)
        conditionsContentFrame:SetAllPoints(insetSettingsContainer)
        conditionsContentFrame:SetFrameLevel(insetSettingsContainer:GetFrameLevel() + 1)

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
                local Containers = SpellStyler.Containers
                if Containers and Containers.GetViewerHidden then
                    if Containers:GetViewerHidden(trackerType) then
                        btn:SetText("|cFF888888" .. label .. "|r")
                    else
                        btn:SetText("|cFFFFD700" .. label .. "|r")
                    end
                else
                    btn:SetText(label)
                end
            end

            btn:SetScript("OnClick", function()
                local Containers = SpellStyler.Containers
                if Containers and Containers.SetViewerHidden and Containers.ApplyViewerVisibility then
                    Containers:SetViewerHidden(trackerType, not Containers:GetViewerHidden(trackerType))
                    Containers:ApplyViewerVisibility(trackerType)
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

        -- ---- Global Settings section ----
        local globalVisLabel = utilityContentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        globalVisLabel:SetPoint("TOPLEFT", wipeDbBtn, "BOTTOMLEFT", 0, -28)
        globalVisLabel:SetText("|cFFFFD700Global Settings|r")

        local globalVisSep = utilityContentFrame:CreateTexture(nil, "ARTWORK")
        globalVisSep:SetColorTexture(0.4, 0.4, 0.4, 0.5)
        globalVisSep:SetHeight(1)
        globalVisSep:SetPoint("TOPLEFT",  globalVisLabel, "BOTTOMLEFT", 0, -4)
        globalVisSep:SetPoint("TOPRIGHT", utilityContentFrame, "TOPRIGHT", -12, 0)

        local hideOutOfCombatCB = CreateFrame("CheckButton", nil, utilityContentFrame, "UICheckButtonTemplate")
        hideOutOfCombatCB:SetSize(26, 26)
        hideOutOfCombatCB:SetPoint("TOPLEFT", globalVisSep, "BOTTOMLEFT", 0, -6)
        hideOutOfCombatCB:SetFrameLevel(utilityContentFrame:GetFrameLevel() + 1)

        local hideOutOfCombatLbl = utilityContentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hideOutOfCombatLbl:SetPoint("LEFT", hideOutOfCombatCB, "RIGHT", 4, 0)
        hideOutOfCombatLbl:SetText("Hide when out of combat")
        hideOutOfCombatLbl:SetTextColor(0.9, 0.9, 0.9)

        local function RefreshGlobalVisCheckbox()
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                hideOutOfCombatCB:SetChecked(
                    gs and gs.visibilitySettings and gs.visibilitySettings.hideWhenOutOfCombat or false
                )
            end
        end

        hideOutOfCombatCB:SetScript("OnClick", function(self)
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                if gs and gs.visibilitySettings then
                    gs.visibilitySettings.hideWhenOutOfCombat = self:GetChecked()
                    State:ApplyGlobalVisibility()
                end
            end
        end)

        -- Show all icons when settings are open checkbox
        local showAllInSettingsCB = CreateFrame("CheckButton", nil, utilityContentFrame, "UICheckButtonTemplate")
        showAllInSettingsCB:SetSize(26, 26)
        showAllInSettingsCB:SetPoint("TOPLEFT", hideOutOfCombatCB, "BOTTOMLEFT", 0, -6)
        showAllInSettingsCB:SetFrameLevel(utilityContentFrame:GetFrameLevel() + 1)

        local showAllInSettingsLbl = utilityContentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        showAllInSettingsLbl:SetPoint("LEFT", showAllInSettingsCB, "RIGHT", 4, 0)
        showAllInSettingsLbl:SetText("Override icon visibility to 'shown'\nwhen settings are open")
        showAllInSettingsLbl:SetTextColor(0.9, 0.9, 0.9)
        showAllInSettingsLbl:SetJustifyH("LEFT")
        showAllInSettingsLbl:SetJustifyV("TOP")

        local function RefreshShowAllInSettingsCheckbox()
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                showAllInSettingsCB:SetChecked(
                    gs and gs.visibilitySettings and gs.visibilitySettings.showAllWhenSettingsOpen or false
                )
            end
        end

        showAllInSettingsCB:SetScript("OnClick", function(self)
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                if gs and gs.visibilitySettings then
                    local isChecked = self:GetChecked()
                    gs.visibilitySettings.showAllWhenSettingsOpen = isChecked
                    -- Immediately apply or remove the override
                    -- if State.OverrideAllIconsVisible then
                    State:OverrideAllIconsVisible(isChecked)
                    -- end
                end
            end
        end)

        -- Font Settings - Override checkbox first
        local overrideFontCB = CreateFrame("CheckButton", nil, utilityContentFrame, "UICheckButtonTemplate")
        overrideFontCB:SetSize(26, 26)
        overrideFontCB:SetPoint("TOPLEFT", showAllInSettingsCB, "BOTTOMLEFT", 0, -16)
        overrideFontCB:SetFrameLevel(utilityContentFrame:GetFrameLevel() + 1)

        local overrideFontLbl = utilityContentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        overrideFontLbl:SetPoint("LEFT", overrideFontCB, "RIGHT", 4, 0)
        overrideFontLbl:SetText("Override all font selections with global font and flags")
        overrideFontLbl:SetTextColor(0.9, 0.9, 0.9)

        local function RefreshOverrideFontCheckbox()
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                overrideFontCB:SetChecked(
                    gs and gs.fontSettings and gs.fontSettings.overrideAllFonts or false
                )
            end
        end

        overrideFontCB:SetScript("OnClick", function(self)
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                if gs and gs.fontSettings then
                    gs.fontSettings.overrideAllFonts = self:GetChecked()
                    -- Force refresh all frames
                    if SpellStyler.FrameTrackerManager then
                        for trackerType, frames in pairs(SpellStyler.FrameTrackerManager.SpellStyler_frames) do
                            for baseSpellID, _ in pairs(frames) do
                                SpellStyler.FrameTrackerManager:ApplyStaticFrameProperties(baseSpellID, trackerType)
                            end
                        end
                    end
                end
            end
        end)

        -- Global Font dropdown
        local fontLabel = utilityContentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fontLabel:SetPoint("TOPLEFT", overrideFontCB, "BOTTOMLEFT", 0, -12)
        fontLabel:SetText("Global Font:")
        fontLabel:SetTextColor(0.9, 0.9, 0.9)

        local fontDropdown = CreateFrame("Frame", nil, utilityContentFrame, "UIDropDownMenuTemplate")
        fontDropdown:SetPoint("LEFT", fontLabel, "RIGHT", -10, -2)
        UIDropDownMenu_SetWidth(fontDropdown, 180)

        local function RefreshFontDropdown()
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                local currentFont = gs and gs.fontSettings and gs.fontSettings.globalFont or "Friz Quadrata TT"
                UIDropDownMenu_SetText(fontDropdown, currentFont)
            end
        end

        UIDropDownMenu_Initialize(fontDropdown, function(self, level)
            local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
            if not LSM then return end
            
            local fonts = LSM:List("font")
            local gs = State:GetGlobalSettings()
            local currentFont = gs and gs.fontSettings and gs.fontSettings.globalFont or "Friz Quadrata TT"
            
            for _, fontName in ipairs(fonts) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = fontName
                info.value = fontName
                info.func = function()
                    if State.GetGlobalSettings then
                        local gs = State:GetGlobalSettings()
                        if gs and gs.fontSettings then
                            gs.fontSettings.globalFont = fontName
                            UIDropDownMenu_SetText(fontDropdown, fontName)
                            -- Force refresh all frames
                            if SpellStyler.FrameTrackerManager then
                                for trackerType, frames in pairs(SpellStyler.FrameTrackerManager.SpellStyler_frames) do
                                    for baseSpellID, _ in pairs(frames) do
                                        SpellStyler.FrameTrackerManager:ApplyStaticFrameProperties(baseSpellID, trackerType)
                                    end
                                end
                            end
                        end
                    end
                end
                info.checked = (fontName == currentFont)
                
                -- Apply font preview to each option
                local fontPath = LSM:Fetch("font", fontName)
                if fontPath then
                    local customFont = CreateFont("SpellStyler_GlobalFontPreview_" .. fontName:gsub("[^%w]", ""))
                    customFont:SetFont(fontPath, 12, "OUTLINE")
                    info.fontObject = customFont
                end
                
                UIDropDownMenu_AddButton(info, level)
            end
        end)

        -- Font Flags Dropdown
        local fontFlagsLabel = utilityContentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fontFlagsLabel:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -12)
        fontFlagsLabel:SetText("Global Font Flags:")
        fontFlagsLabel:SetTextColor(0.9, 0.9, 0.9)
        
        local fontFlagsDropdown = CreateFrame("Frame", nil, utilityContentFrame, "UIDropDownMenuTemplate")
        fontFlagsDropdown:SetPoint("LEFT", fontFlagsLabel, "RIGHT", -10, -2)
        UIDropDownMenu_SetWidth(fontFlagsDropdown, 180)

        local function RefreshFontFlagsDropdown()
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                local currentFlags = gs and gs.fontSettings and gs.fontSettings.globalFontFlags or "OUTLINE"
                
                -- Migration: Convert old comma-separated format to new single-value format
                if currentFlags:find(",") then
                    if currentFlags:find("THICKOUTLINE") then
                        currentFlags = "THICKOUTLINE"
                    elseif currentFlags:find("OUTLINE") then
                        currentFlags = "OUTLINE"
                    elseif currentFlags:find("MONOCHROME") then
                        currentFlags = "MONOCHROME"
                    else
                        currentFlags = "OUTLINE"
                    end
                    gs.fontSettings.globalFontFlags = currentFlags
                end
                
                -- Set display text based on current value
                local displayText = "Outline"
                if currentFlags == "THICKOUTLINE" then
                    displayText = "Thick Outline"
                elseif currentFlags == "MONOCHROME" then
                    displayText = "Monochrome"
                elseif currentFlags == "OUTLINE" then
                    displayText = "Outline"
                end
                
                UIDropDownMenu_SetText(fontFlagsDropdown, displayText)
            end
        end

        UIDropDownMenu_Initialize(fontFlagsDropdown, function(self, level)
            local gs = State:GetGlobalSettings()
            local currentFlags = gs and gs.fontSettings and gs.fontSettings.globalFontFlags or "OUTLINE"
            
            local options = {
                { label = "Outline", value = "OUTLINE" },
                { label = "Thick Outline", value = "THICKOUTLINE" },
                { label = "Monochrome", value = "MONOCHROME" },
            }
            
            for _, opt in ipairs(options) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = opt.label
                info.value = opt.value
                info.func = function()
                    if State.GetGlobalSettings then
                        local gs = State:GetGlobalSettings()
                        if gs and gs.fontSettings then
                            gs.fontSettings.globalFontFlags = opt.value
                            UIDropDownMenu_SetText(fontFlagsDropdown, opt.label)
                            -- Force refresh all frames
                            if SpellStyler.FrameTrackerManager then
                                for trackerType, frames in pairs(SpellStyler.FrameTrackerManager.SpellStyler_frames) do
                                    for baseSpellID, _ in pairs(frames) do
                                        SpellStyler.FrameTrackerManager:ApplyStaticFrameProperties(baseSpellID, trackerType)
                                    end
                                end
                            end
                        end
                    end
                end
                info.checked = (currentFlags == opt.value)
                UIDropDownMenu_AddButton(info, level)
            end
        end)

        utilityContentFrame:HookScript("OnShow", RefreshGlobalVisCheckbox)
        utilityContentFrame:HookScript("OnShow", RefreshShowAllInSettingsCheckbox)
        utilityContentFrame:HookScript("OnShow", RefreshOverrideFontCheckbox)
        utilityContentFrame:HookScript("OnShow", RefreshFontDropdown)
        utilityContentFrame:HookScript("OnShow", RefreshFontFlagsDropdown)

        SpellStyler.HelpContentRenderer:RenderHelpView(helpContentFrame)
        SpellStyler.IconSettingsRenderer:RenderIconControlView(settingsContentFrame)
        SpellStyler.ContainerSettingsRenderer:RenderContainerView(containerContentFrame)
        SpellStyler.ConditionalCreator:RenderConditionsView(conditionsContentFrame)

        RegisterView("icons",      settingsContentFrame)
        RegisterView("help",       helpContentFrame)
        RegisterView("containers", containerContentFrame)
        RegisterView("utility",    utilityContentFrame)
        RegisterView("conditions", conditionsContentFrame)
        SwitchToView("icons")

        -- Store references globally so other modules can update the settings menu
        SpellStyler.settingsContentFrame = settingsContentFrame
        SpellStyler.SwitchSettingsView = SwitchToView


        -- ============================
        -- Tab bar: parented to UIParent so it can sit BEHIND SpellStyler.settingsMenu.
        -- Children of SpellStyler.settingsMenu cannot have a lower FrameLevel than the menu
        -- itself, so we parent to UIParent and manage visibility manually.
        -- ============================
        local tabFaceW = 100
        local tabH     = 40
        local tabGap   = 6

        local tabBar = CreateFrame("Frame", nil, UIParent)
        tabBar:SetWidth(tabFaceW + 55)
        tabBar:SetFrameLevel(SpellStyler.settingsMenu:GetFrameLevel() - 1)  -- one level BEHIND SpellStyler.settingsMenu
        tabBar:SetPoint("TOPLEFT", SpellStyler.settingsMenu, "TOPRIGHT", 0, -100)

        -- Keep tabBar visible only while SpellStyler.settingsMenu is shown
        SpellStyler.settingsMenu:HookScript("OnShow", function()
            tabBar:Show()
            SpellStyler.IconSettingsRenderer:ReactivateKeyboard()
            if SpellStyler.Containers then
                SpellStyler.Containers:SetEditMode(true)
            end
            -- Re-render icon list when menu opens
            if SpellStyler.IconSettingsRenderer and settingsContentFrame then
                SpellStyler.IconSettingsRenderer:RenderIconControlView(settingsContentFrame)
            end
            -- Override icon visibility if enabled
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                if gs and gs.visibilitySettings and gs.visibilitySettings.showAllWhenSettingsOpen then
                    State:OverrideAllIconsVisible(true)
                end
            end
        end)
        SpellStyler.settingsMenu:HookScript("OnHide", function()
            tabBar:Hide()
            if SpellStyler.Containers then SpellStyler.Containers:SetEditMode(false) end
            -- Restore normal icon visibility
            if State.GetGlobalSettings then
                local gs = State:GetGlobalSettings()
                if gs and gs.visibilitySettings and gs.visibilitySettings.showAllWhenSettingsOpen then
                    State:OverrideAllIconsVisible(false)
                end
            end
        end)
        
        local tabSpells     = SpellStyler.CreateTab(tabBar, "Spells",     tabFaceW, tabH)
        local tabHelp       = SpellStyler.CreateTab(tabBar, "Help",       tabFaceW, tabH)
        local tabContainers = SpellStyler.CreateTab(tabBar, "Containers", tabFaceW, tabH)
        local tabUtility    = SpellStyler.CreateTab(tabBar, "Utility",    tabFaceW, tabH)
        local tabConditions = SpellStyler.CreateTab(tabBar, "Conditions", tabFaceW, tabH)

        tabBar:SetHeight(5 * tabH + 4 * tabGap)

        tabSpells:SetPoint("TOPLEFT",     tabBar,        "TOPLEFT", 0, 0)
        tabHelp:SetPoint("TOPLEFT",       tabSpells,     "BOTTOMLEFT", 0, -tabGap)
        tabContainers:SetPoint("TOPLEFT", tabHelp,       "BOTTOMLEFT", 0, -tabGap)
        tabUtility:SetPoint("TOPLEFT",    tabContainers, "BOTTOMLEFT", 0, -tabGap)
        tabConditions:SetPoint("TOPLEFT", tabUtility,    "BOTTOMLEFT", 0, -tabGap)

        tabSpells.onTabClick     = function() SwitchToView("icons") end
        tabHelp.onTabClick       = function() SwitchToView("help") end
        tabContainers.onTabClick = function() SwitchToView("containers") end
        tabUtility.onTabClick    = function() SwitchToView("utility") end
        tabConditions.onTabClick = function() SwitchToView("conditions") end

        SpellStyler.SetTabGroupExclusive({ tabSpells, tabHelp, tabContainers, tabUtility, tabConditions })
        tabSpells:SetSelected(true)
    end
	-- When the settings menu is open and the user clicks a tracker frame in the
	-- game world, switch to the Spells tab and select that icon.
	SpellStyler._selectIconInSettings = function(uniqueID, trackerType)
		if not (SpellStyler.settingsMenu and SpellStyler.settingsMenu:IsShown()) then return end
		SwitchToView("icons")
		SpellStyler.IconSettingsRenderer:SelectIcon(uniqueID, trackerType)
	end

	if SpellStyler.IconSettingsRenderer then
		if SpellStyler.IconSettingsRenderer.SetFrameClickCallback then
			SpellStyler.IconSettingsRenderer:SetFrameClickCallback(function(uniqueID, trackerType)
				SpellStyler._selectIconInSettings(uniqueID, trackerType)
			end)
		end
		if SpellStyler.IconSettingsRenderer.EnableDraggingForAllFrames then
			SpellStyler.IconSettingsRenderer:EnableDraggingForAllFrames()
		end
	end
    SpellStyler.settingsMenu:Show()
end

-- Combat-delay event frame: opens settings after combat, force-closes on combat enter
local combatDelayFrame = CreateFrame("Frame")
combatDelayFrame:RegisterEvent("PLAYER_IN_COMBAT_CHANGED")
combatDelayFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_IN_COMBAT_CHANGED" then
        -- Force-close the settings menu when entering combat
        local isInCombat = ...
        if isInCombat then
            if SpellStyler.IconSettingsRenderer.keyboardFrame then SpellStyler.IconSettingsRenderer.keyboardFrame:EnableKeyboard(false) end
            if SpellStyler.settingsMenu and SpellStyler.settingsMenu:IsShown() then
                SpellStyler.settingsMenu:Hide()
                pendingShowAfterCombat = true -- automatically reopen if it was forced closed
            end
        else
            if pendingShowAfterCombat then
                if SpellStyler.IconSettingsRenderer.keyboardFrame then SpellStyler.IconSettingsRenderer.keyboardFrame:EnableKeyboard(true) end
                pendingShowAfterCombat = false
                ShowBorderDemo()
            end
            if FrameTrackerManager.AttemptToScanBuffsAfterLeavingCombat then
                FrameTrackerManager.AttemptToScanBuffsAfterLeavingCombat = false
                -- FrameTrackerManager:HookAllBuffCooldownFrames("buffs")
                FrameTrackerManager:FreshCreateFrames("AttemptToScanBuffsAfterLeavingCombat")
            end
        end
    end
end)

_G["SLASH_SPELLSTYLER1"] = "/SpellStyler"
_G["SLASH_SPELLSTYLER2"] = "/spellstyler"
_G["SLASH_SPELLSTYLER3"] = "/ss"
SlashCmdList["SPELLSTYLER"] = function(msg)
    ShowBorderDemo()
end
