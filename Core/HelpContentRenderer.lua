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
        "|cFFFFD700Adding Spells|r\n\n" ..
        "Spells are added manually using the |cFFFFD700plus icon|r from the spells menu. Search by ID or name.\n\n" ..
        "|cFFFFD700Multi-Icon Settings|r\n\n" ..
        "The multi-icon settings button allows you to select multiple spells or buffs at once to apply properties to each one at the same time.\n\n" ..
        "|cFFFFD700Conditional Overrides|r\n\n" ..
        "For conditional overrides, start by creating a condition in the |cFFFFD700conditions menu|r. Once created with a unique name, in the spells menu, the |cFFFFD700'conditional property overrides'|r of the sub menu can be used to set which properties to update. Add a new condition, select which properties to change, and which conditional to use to apply those properties. Please reach out on the discord if you have more conditions you'd like me to explore adding.\n\n" ..
        "|cFFFFD700Charge/Count Based Display|r\n\n" ..
        "The Charge/Count based display uses a positioning trick to allow you to display your spell or buff based on the current charges.\n\n" ..
        "|cFFFFD700Copying Settings|r\n\n" ..
        "Drag a |cFFFFD700sub-header|r and drop it over another spell or buff to copy the settings to that other ability.\n\n" ..
        "|cFFFFD700Support|r\n\n" ..
        "Please reach out in the discord if you have any questions, requests, or bugs!"
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
