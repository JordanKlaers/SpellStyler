-- HelpContentRenderer.lua
-- Renders the Help view inside the settings menu

local ADDON_NAME, SpellStyler = ...
SpellStyler.HelpContentRenderer = SpellStyler.HelpContentRenderer or {}
local HelpContentRenderer = SpellStyler.HelpContentRenderer

function HelpContentRenderer:RenderHelpView(parentFrame)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parentFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     parentFrame, "TOPLEFT",     4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", parentFrame, "BOTTOMRIGHT", -26, 4)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(scrollFrame:GetWidth(), 1)  -- height expands with content
    scrollFrame:SetScrollChild(scrollChild)

    local helpText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    helpText:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 12, -12)
    helpText:SetWidth(scrollFrame:GetWidth() - 24)
    helpText:SetJustifyH("LEFT")
    helpText:SetJustifyV("TOP")
    helpText:SetSpacing(6)
    helpText:SetWordWrap(true)
    helpText:SetText(
        "|cFFFFD700Getting Started|r\n\n" ..
        "Open the Cooldown Manager and add spells to the |cFFFFD700Buff|r, |cFFFFD700Essential|r, or |cFFFFD700Utility|r tracking. " ..
        "A frame will be created for each spell you track.\n" ..
        "When tracking buffs, enable edit mode to access the bilzzard settings for buffs and ensure you check the box for 'Hide When Inactive'\n\n" ..
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

    -- Resize the scroll child after layout so the scroll range is correct
    scrollChild:SetScript("OnUpdate", function(self)
        local h = helpText:GetHeight()
        if h > 0 then
            self:SetHeight(h + 24)
            self:SetScript("OnUpdate", nil)
        end
    end)
end
