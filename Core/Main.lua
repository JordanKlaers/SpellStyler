
-- ============================================================================
-- TweaksUI: Cooldowns - Main
-- Core addon initialization and slash commands
-- Version 3.0.2 - Unified Architecture
-- ============================================================================

local ADDON_NAME, SpellStyler = ...

-- Make SpellStyler accessible globally
_G.SpellStyler = SpellStyler


local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")

local addonLoaded = false
local playerLoggedIn = false

local function Initialize()
    if not addonLoaded or not playerLoggedIn then
        return
    end

    if SpellStyler.MinimapButton then
        SpellStyler.MinimapButton:Initialize()
    end
end

initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        addonLoaded = true
        -- Initialize account-wide DB
        SpellStyler_DB = SpellStyler_DB or {}

        -- Initialize per-character DB
        SpellStyler_CharDB = SpellStyler_CharDB or {}
        SpellStyler_CharDB.classSpecializations = SpellStyler_CharDB.classSpecializations or {}
        Initialize()
    elseif event == "PLAYER_LOGIN" then
        playerLoggedIn = true
        Initialize()
    end
end)







-- Keybind handler: Shift+Ctrl+L
local texScanFrame = CreateFrame("Frame")
texScanFrame:SetPropagateKeyboardInput(true)
texScanFrame:RegisterEvent("PLAYER_LOGIN")
texScanFrame:SetScript("OnEvent", function()
    texScanFrame:SetScript("OnKeyDown", function(self, key)
        if key == "X" and IsShiftKeyDown() and IsControlKeyDown() then
            frameData = {}
            visitiedFrames = {}
            savedTextures = {}
            local frames = C_System.GetFrameStack(0, true)
            for _, frame in ipairs(frames) do
                ListTexturesUnderMouse(frame, "")    
            end
        end
    end)
    texScanFrame:SetScript("OnKeyUp", function(self, key) end)
    texScanFrame:SetScript("OnMouseDown", function() end)
    texScanFrame:SetScript("OnMouseUp", function() end)
    texScanFrame:EnableKeyboard(true)
end)




