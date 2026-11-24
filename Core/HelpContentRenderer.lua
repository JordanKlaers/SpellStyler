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
        "Add content to track via the |cFFFFD700Spells|r tab, then click the |cFFFFD700Add|r button in the top left.\n\n" ..
        "|cFFFFD700Re-enabling Values|r\n\n" ..
        "Re-enable values from the |cFFFFD700Spells|r tab by clicking the |cFFFFD700Disabled Values|r button on the left.\n\n" ..
        "|cFFFFD700Copying Settings|r\n\n" ..
        "Copy settings from a template or another tracked value onto one or more other entries.\n" ..
        "Drag a sub menu header and drop over an icon in the left column to copy that section between tracker entries\n\n" ..
        "|cFFFFD700Creating Templates|r\n\n" ..
        "Create a template by selecting a tracked value and creating a template from that value's settings. A template stores the full current settings.\n\n" ..
        "|cFFFFD700Containers|r\n\n" ..
        "Place values in a container from the |cFFFFD700Container|r tab. Functionality is limited, but it includes a collapsible setting to hide values that are on cooldown or unavailable to cast.\n\n" ..
        "|cFFFFD700Conditional Property Overrides|r\n\n" ..
        "Some properties can be controlled conditionally. Create a condition on the |cFFFFD700Conditions|r tab. Then, in the spells menu, open the |cFFFFD700Conditional Property Overrides|r section to choose the condition to use and the properties to modify.\n\n" ..
        "|cFFFFD700Profiles|r\n\n" ..
        "Enable profiles from the |cFFFFD700Profiles|r tab. You can use a single profile for a specialization, or automatically apply different profiles when swapping between talent loadouts for that specialization.\n\n" ..
        "|cFFFFD700Support|r\n\n" ..
        "Please reach out in the discord if you have any questions, requests, or bugs!\nhttps://discord.gg/MKZUeDQEbM"
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
