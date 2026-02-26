-- NewSettings.lua
-- Simple border demo using the finalized border frame values

local settingsMenu
local borderFrames = {}

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
        borderFrames[1] = CreateBorderFrame(settingsMenu, "TopLeftCorner", "TOPLEFT", -22, 22, 0, 0.28, 0.316, 0.59, 0, 110, 108)
        borderFrames[2] = CreateBorderFrame(settingsMenu, "TopRightCorner", "TOPRIGHT", 68, 28.99, 0.8, 1, 0.002, 0.255, 0, 100, 100)
        borderFrames[3] = CreateBorderFrame(settingsMenu, "LineLeft", "LEFT", -23.99, -19.99, 0, 0.54, 0.2, 0.2, 0, 230, 500)
        borderFrames[4] = CreateBorderFrame(settingsMenu, "LineRight", "RIGHT", 207.98, -4.98, 0, 0.54, 0.2, 0.2, 0, 230, 500)
        borderFrames[5] = CreateBorderFrame(settingsMenu, "LineBottom", "BOTTOM", 8, -54.9, 0, 0.54, 0.2, 0.2, 90, 230, 292)
        borderFrames[6] = CreateBorderFrame(settingsMenu, "Corner1", "BOTTOMRIGHT", 10, -6, 0.34, 0.483, 0.27, 0.42, 90, 68, 68)
        borderFrames[7] = CreateBorderFrame(settingsMenu, "Corner2", "BOTTOMLEFT", -6, -8, 0.34, 0.483, 0.27, 0.42, 0, 68, 68)
        borderFrames[8] = CreateBorderFrame(settingsMenu, "TopBar", "TOP", 29, 29, 0.07, 0.45, 0.002, 0.255, 0, 281, 100)

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
        insetSettingsContainer:SetPoint("BOTTOMRIGHT", settingsMenu, "BOTTOMRIGHT", -5, 74)
        insetSettingsContainer:SetBackdrop({
            bgFile = 374154,
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        insetSettingsContainer:SetBackdropColor(0.15, 0.15, 0.15, 0.85)
        insetSettingsContainer:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

        -- Two sub-frames inside the inset container so we can toggle between views
        local settingsContentFrame = CreateFrame("Frame", nil, insetSettingsContainer)
        settingsContentFrame:SetAllPoints(insetSettingsContainer)
        settingsContentFrame:SetFrameLevel(insetSettingsContainer:GetFrameLevel() + 1)

        local helpContentFrame = CreateFrame("Frame", nil, insetSettingsContainer)
        helpContentFrame:SetAllPoints(insetSettingsContainer)
        helpContentFrame:SetFrameLevel(insetSettingsContainer:GetFrameLevel() + 1)
        helpContentFrame:Hide()

        -- Help text content
        local helpText = helpContentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        helpText:SetPoint("TOPLEFT", helpContentFrame, "TOPLEFT", 12, -12)
        helpText:SetPoint("BOTTOMRIGHT", helpContentFrame, "BOTTOMRIGHT", -12, 12)
        helpText:SetJustifyH("LEFT")
        helpText:SetJustifyV("TOP")
        helpText:SetSpacing(6)
        helpText:SetWordWrap(true)
        helpText:SetText(
            "|cFFFFD700Getting Started|r\n\n" ..
            "Open the Cooldown Manager and add spells to the |cFFFFD700Buff|r, |cFFFFD700Essential|r, or |cFFFFD700Utility|r tracking. " ..
            "A frame will be created for each spell you track.\n\n" ..
            "|cFFFFD700Positioning|r\n\n" ..
            "While settings are open, you can |cFFFFD700drag icons|r to reposition them. " ..
            "Select an icon and use the |cFFFFD700Arrow Keys|r for precise pixel-by-pixel movement.\n\n" ..
            "|cFFFFD700Configuring an Icon|r\n\n" ..
            "Click an icon in the |cFFFFD700left column|r of the settings menu to open its settings.\n\n" ..
            "|cFFFFD700Copying Settings|r\n\n" ..
            "Drag a |cFFFFD700section header bar|r and drop it onto an icon in the left column to copy " ..
            "that section's settings to the target icon. Position and custom textures are not copied.\n\n" ..
            "|cFFFFD700Hiding Blizzard Frames|r\n\n" ..
            "The |cFFFFD700Buffs|r, |cFFFFD700Essential|r, and |cFFFFD700Utility|r buttons at the bottom-left " ..
            "toggle the visibility of the corresponding Blizzard tracker frames. " ..
            "|cFFFFD700Yellow|r means the frame is visible, |cFF888888gray|r means it is hidden."
        )

        SpellStyler.IconSettingsRenderer:RenderIconControlView(settingsContentFrame)

        -- Help / Settings toggle button (bottom-right of the settings menu)
        local isHelpShown = false
        local helpBtn = CreateFrame("Button", nil, settingsMenu, "UIPanelButtonTemplate")
        helpBtn:SetSize(80, 22)
        helpBtn:SetPoint("BOTTOMRIGHT", settingsMenu, "BOTTOMRIGHT", -10, 18)
        helpBtn:SetText("Help")
        helpBtn:SetFrameLevel(settingsMenu:GetFrameLevel() + 3)
        helpBtn:SetScript("OnClick", function()
            isHelpShown = not isHelpShown
            if isHelpShown then
                settingsContentFrame:Hide()
                helpContentFrame:Show()
                helpBtn:SetText("Settings")
            else
                helpContentFrame:Hide()
                settingsContentFrame:Show()
                helpBtn:SetText("Help")
            end
        end)

        -- ============================
        -- Viewer Hide Buttons (bottom-left)
        -- Toggle visibility of each Blizzard tracker viewer frame
        -- State is persisted in SpellStyler_DB.hideViewers
        -- ============================
        local function MakeViewerToggleButton(trackerType, label, anchorFrame)
            local btn = CreateFrame("Button", nil, settingsMenu, "UIPanelButtonTemplate")
            btn:SetSize(90, 22)
            btn:SetFrameLevel(settingsMenu:GetFrameLevel() + 3)
            if anchorFrame then
                btn:SetPoint("BOTTOMLEFT", anchorFrame, "BOTTOMRIGHT", 5, 0)
            else
                btn:SetPoint("BOTTOMLEFT", settingsMenu, "BOTTOMLEFT", 10, 18)
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

            -- Refresh label each time the settings panel is shown
            btn:SetScript("OnShow", RefreshLabel)
            RefreshLabel()
            return btn
        end

        local buffsViewerBtn     = MakeViewerToggleButton("buffs",     "Buffs",     nil)
        local essentialViewerBtn = MakeViewerToggleButton("essential", "Essential", buffsViewerBtn)
        MakeViewerToggleButton("utility", "Utility", essentialViewerBtn)

        -- Row 2: Wipe Database button
        local wipeDbBtn = CreateFrame("Button", nil, settingsMenu, "UIPanelButtonTemplate")
        wipeDbBtn:SetSize(130, 22)
        wipeDbBtn:SetPoint("BOTTOMLEFT", settingsMenu, "BOTTOMLEFT", 10, 42)
        wipeDbBtn:SetFrameLevel(settingsMenu:GetFrameLevel() + 3)
        wipeDbBtn:SetText("|cFFFF4444Wipe Database|r")

        -- Confirmation popup for Wipe Database
        local wipeConfirmPopup = CreateFrame("Frame", nil, settingsMenu, "BackdropTemplate")
        wipeConfirmPopup:SetSize(220, 80)
        wipeConfirmPopup:SetPoint("BOTTOM", wipeDbBtn, "TOP", 0, 6)
        wipeConfirmPopup:SetFrameLevel(settingsMenu:GetFrameLevel() + 10)
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
            pendingShowAfterCombat = false
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
