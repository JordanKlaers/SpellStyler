-- IconSettingsRenderer.lua
-- Standalone module for rendering icon configuration controls
-- Extracted from Cooldowns module to be reusable
--
-- USAGE EXAMPLE:
--[[
    -- In your frame setup code:
    local settingsPanel = CreateFrame("Frame", nil, parentFrame)
    settingsPanel:SetAllPoints()
    
    -- Initialize the renderer
    local rendererAPI = SpellStyler.IconSettingsIconSettingsRenderer:RenderIntoContainer(settingsPanel, {
        trackerType = "buffs",  -- or "customIcons"
        onIconClick = function(uniqueID)
            -- Optional: Called when an icon is selected
            print("Selected icon:", uniqueID)
        end
    })
    
    -- When an icon is clicked in your UI:
    rendererAPI.selectIcon(uniqueID)  -- Shows settings for this icon
    
    -- To clear the selection:
    rendererAPI.clearSelection()
]]

local ADDON_NAME, SpellStyler = ...
SpellStyler.IconSettingsRenderer = SpellStyler.IconSettingsRenderer or {}
local IconSettingsRenderer = SpellStyler.IconSettingsRenderer
local controlsPanel
local settingsMenuIconList = {}

-- Keyboard-based position shifting: populated each time an icon is rendered
local _activePositionConfigs = {}
local _keyboardFrame = nil

function IconSettingsRenderer:SetConsistentScrollingBehavior(scrollFrame)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        
        local scrollAmount = self:GetHeight() * 0.025
        
        self:SetVerticalScroll(math.max(0, math.min(maxScroll, current - (delta * scrollAmount))))
    end)
end


local function EnsureKeyboardFrame()
    if _keyboardFrame then return end
    pcall(function()
        _keyboardFrame = CreateFrame("Frame", "SpellStylerArrowKeyCapture", UIParent)
        _keyboardFrame:SetSize(1, 1)
        _keyboardFrame:SetPoint("CENTER")
        _keyboardFrame:EnableKeyboard(false)
        _keyboardFrame:SetScript("OnKeyDown", function(self, key)
            if key ~= "UP" and key ~= "DOWN" and key ~= "LEFT" and key ~= "RIGHT" then
                self:SetPropagateKeyboardInput(true)
                return
            end
            self:SetPropagateKeyboardInput(false)
            local cfg = IsShiftKeyDown() and _activePositionConfigs[2] or _activePositionConfigs[1]
            if not cfg then return end
            if key == "UP"    then cfg:setValue("y",  1)
            elseif key == "DOWN"  then cfg:setValue("y", -1)
            elseif key == "LEFT"  then cfg:setValue("x", -1)
            elseif key == "RIGHT" then cfg:setValue("x",  1)
            end
        end)
    end)
end

-- ============================================================================
-- INPUT FACTORY METHODS
-- ============================================================================

local function CreateIconButton(parent, iconPath, spellName, uniqueID, trackerType, size)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(size or 40, size or 40)
	local tex = btn:CreateTexture(nil, "ARTWORK")
	tex:SetAllPoints(btn)
	tex:SetTexture(iconPath)
	btn.trackerType = trackerType
	btn.uniqueID = uniqueID
	btn.texture = tex
	-- Glow border shown when a section header is dragged over this button
	local glowBorder = CreateFrame("Frame", nil, btn, "BackdropTemplate")
	glowBorder:SetPoint("TOPLEFT", btn, "TOPLEFT", -3, 3)
	glowBorder:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 3, -3)
	glowBorder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
	glowBorder:SetBackdropBorderColor(1, 0.8, 0, 1)
	glowBorder:Hide()
	btn.glowBorder = glowBorder
	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText((spellName or ("ID: "..tostring(uniqueID))) .. " - " .. trackerType, 1, 1, 1)
		GameTooltip:AddLine("ID: "..tostring(uniqueID), 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return btn
end
-- Creates: Label + Text Input (EditBox) inside a 290px row frame
-- Returns: row frame (for anchoring next control)
local function CreateTextInput(parent, config, anchor)
    config = config or {}

    -- Row container — anchors where the old label did, returned for chaining
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(290, 30)
    row:SetPoint(config.anchorPoint or "TOPLEFT", anchor, config.relativePoint or "BOTTOMLEFT", config.offsetX or 0, config.offsetY or -1)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(config.label)
    label:SetTextColor(0.8, 0.8, 0.8)
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetJustifyH("LEFT")

    local input = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    input:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    input:SetSize(config.width or 80, 18)
    input:SetAutoFocus(false)
    input:SetMaxLetters(config.maxLetters or 1000)

    input:SetText(tostring(config:getValue()))

    config.min = config.min or 0
    config.max = config.max or 5000
    input:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local value = config.numeric and tonumber(self:GetText()) or self:GetText()
        if config.numeric then
            if not value then
                value = config.min or 0
            end
            value = math.max(config.min, math.min(config.max, value))
            self:SetText(tostring(value))
        end
        config:setValue(value)
    end)
    input:SetScript("OnEditFocusLost", function(self)
        local value = config.numeric and tonumber(self:GetText()) or self:GetText()
        if config.numeric then
            if not value then
                value = config.min or 0
            end
            value = math.max(config.min, math.min(config.max, value))
            self:SetText(tostring(value))
        end
        config:setValue(value)
    end)

    return row, input
end

-- Creates: Label + Dropdown inside a 290px row frame
-- Returns: row frame (for anchoring next control)
function IconSettingsRenderer:CreateDropdown(parent, config, anchor)
    config = config or {}

    -- Row container — anchors where the old label did, returned for chaining
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(290, 30)
    row:SetPoint(config.anchorPoint or "TOPLEFT", anchor, config.relativePoint or "BOTTOMLEFT", config.offsetX or 0, config.offsetY or -1)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(config.label)
    label:SetTextColor(0.8, 0.8, 0.8)
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetJustifyH("LEFT")

    local dropdown = CreateFrame("Frame", nil, row, "UIDropDownMenuTemplate")
    dropdown:SetPoint("RIGHT", row, "RIGHT", 18, 0)
    UIDropDownMenu_SetWidth(dropdown, config.width or 140)

    UIDropDownMenu_Initialize(dropdown, function(self, level)
        for _, opt in ipairs(config.options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.value = opt.value
            info.func = function()
                config:setValue(opt.value)
                UIDropDownMenu_SetText(dropdown, opt.label)
            end
            info.checked = (config:getValue() == opt.value)
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    -- Set initial text from current value
    local currentValue = config:getValue()
    for _, opt in ipairs(config.options) do
        if opt.value == currentValue then
            UIDropDownMenu_SetText(dropdown, opt.label)
            break
        end
    end

    return row, dropdown
end

-- Creates: Label + Color Picker Button inside a 290px row frame
-- Returns: row frame (for anchoring next control)
local function CreateColorPicker(parent, config, anchor)
    config = config or {}

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(290, 30)
    row:SetPoint(config.anchorPoint or "TOPLEFT", anchor, config.relativePoint or "BOTTOMLEFT", config.offsetX or 0, config.offsetY or -1)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(config.label)
    label:SetTextColor(0.8, 0.8, 0.8)
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetJustifyH("LEFT")

    local btn = CreateFrame("Button", nil, row, "BackdropTemplate")
    btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    btn:SetSize(24, 16)
    btn:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1})
    local color = config:getValue()
    btn:SetBackdropColor(color.r, color.g, color.b, color.a or 1)
    btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

    btn:SetScript("OnClick", function()
        local currentColor = config:getValue()
        local r, g, b, a = currentColor.r or 1, currentColor.g or 1, currentColor.b or 1, currentColor.a or 1

        local info = {
            swatchFunc = function()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                local na = ColorPickerFrame:GetColorAlpha() or 1
                btn:SetBackdropColor(nr, ng, nb, na)
                config:setValue({r = nr, g = ng, b = nb, a = na})
            end,
            opacityFunc = function()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                local na = ColorPickerFrame:GetColorAlpha() or 1
                btn:SetBackdropColor(nr, ng, nb, na)
                config:setValue({r = nr, g = ng, b = nb, a = na})
            end or nil,
            cancelFunc = function(prev)
                btn:SetBackdropColor(prev.r, prev.g, prev.b, prev.a or 1)
                config:setValue({r = prev.r, g = prev.g, b = prev.b, a = prev.a or 1})
            end,
            hasOpacity = 1,
            opacity = a,
            r = r,
            g = g,
            b = b,
        }
        ColorPickerFrame:SetupColorPickerAndShow(info)
    end)

    return row, btn
end

-- Creates: Checkbox + Label
-- Returns: checkbox frame (for anchoring next control)
local function CreateCheckbox(parent, config, anchor)
    config = config or {}
    
    local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    checkbox:SetSize(24, 24)
    checkbox:SetPoint(config.anchorPoint or "TOPLEFT", anchor, config.relativePoint or "BOTTOMLEFT", config.offsetX or 0, config.offsetY or -5)
    
    checkbox:SetChecked(config:getValue())
    
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", checkbox, "RIGHT", 2, 0)
    label:SetText(config.label)
    label:SetTextColor(0.8, 0.8, 0.8)
    
    if config.setValue then
        checkbox:SetScript("OnClick", function(self)
            config:setValue(self:GetChecked())
        end)
    end

    if config.tooltip then
        local function showTooltip(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(config.label, 1, 1, 1, 1, true)
            GameTooltip:AddLine(config.tooltip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end
        local function hideTooltip() GameTooltip:Hide() end
        checkbox:SetScript("OnEnter", showTooltip)
        checkbox:SetScript("OnLeave", hideTooltip)
        label:SetScript("OnEnter", showTooltip)
        label:SetScript("OnLeave", hideTooltip)
    end
    
    return checkbox, label
end

-- Creates: Position hint row (arrow-key driven; no buttons)
-- Returns: row frame (for anchoring next control)
local function CreatePositionHint(parent, config, anchor, hintText)
    config = config or {}
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(290, 20)
    row:SetPoint(config.anchorPoint or "TOPLEFT", anchor, config.relativePoint or "BOTTOMLEFT", config.offsetX or 0, config.offsetY or -10)
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(config.label or "")
    label:SetTextColor(0.8, 0.8, 0.8)
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetJustifyH("LEFT")
    local hint = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetText(hintText or "|cff888888← ↑ ↓ →|r")
    hint:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    hint:SetJustifyH("RIGHT")
    return row
end

-- Creates: Button with state (no label)
-- Returns: button frame (for anchoring next control)
local function CreateButton(parent, config, anchor)
    config = config or {}
    
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetPoint(config.anchorPoint or "TOPLEFT", anchor, config.relativePoint or "BOTTOMLEFT", config.offsetX or 0, config.offsetY or -25)
    btn:SetSize(config.width or 120, config.height or 24)
    btn:SetText(config.buttonText or "Button")
    
    if config.onClick then
        btn:SetScript("OnClick", function(self)
            config.onClick(self, btn)
        end)
    end
    
    -- Store button reference for state updates
    if config.onStateGet then
        btn.getState = config.onStateGet
    end
    
    return btn
end

-- Creates: Label + Value Label (read-only)
-- Returns: label frame (for anchoring next control)
local function CreateLabel(parent, config, anchor)
    config = config or {}
    
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(config.label or "")
    label:SetTextColor(0.8, 0.8, 0.8)
    label:SetPoint(config.anchorPoint or "TOPLEFT", anchor, config.relativePoint or "BOTTOMLEFT", config.offsetX or 0, config.offsetY or -10)
    
    local valueLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valueLabel:SetPoint("LEFT", label, "RIGHT", 4, 0)
    valueLabel:SetTextColor(1, 1, 0.5)
    
    if config.getValue then
        valueLabel:SetText(config:getValue() or "")
    end
    
    label.valueLabel = valueLabel
    
    return label, valueLabel
end


-- ============================================================================
-- CONFIG INPUT DEFINITIONS
-- ============================================================================

function IconSettingsRenderer:GetIconConfigInputs(config)
    local RADIAL_DISPLAY_OPTIONS = {}
    if config.trackerType == 'buffs' then
        RADIAL_DISPLAY_OPTIONS = {
            { label = "Show Always", value = "always" },
            { label = "Show when active", value = "active" },
            { label = "Show when inactive", value = "inactive" },
            { label = "Show Never", value = "never" },
        }
    else
        RADIAL_DISPLAY_OPTIONS = {
            { label = "Show Always", value = "always" },
            { label = "Show Only on Cooldown", value = "cooldown" },
            { label = "Show Only when Available", value = "available" },
            { label = "Show Never", value = "never" },
        }
    end
	local ANCHOR_OPTIONS = {
		{ label = "TOP", value = "TOP" },
		{ label = "BOTTOM", value = "BOTTOM" },
		{ label = "LEFT", value = "LEFT" },
		{ label = "RIGHT", value = "RIGHT" },
		{ label = "CENTER", value = "CENTER" },
		{ label = "TOPLEFT", value = "TOPLEFT" },
		{ label = "TOPRIGHT", value = "TOPRIGHT" },
		{ label = "BOTTOMLEFT", value = "BOTTOMLEFT" },
		{ label = "BOTTOMRIGHT", value = "BOTTOMRIGHT" },
	}
    
    return {
        -- Icon settings
        {
            type = "header",
            text = "|cffffcc00Icon Settings|r",
            state = 'expanded',
            sectionContent = {
                {
                    type = "dropdown",
                    label = "Icon Display State:",
                    options = RADIAL_DISPLAY_OPTIONS,
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.iconDisplayState") or "always" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.iconDisplayState", value) end,
                },
                {
                    type = "textinput",
                    label = "Custom Texture Path:",
                    width = 160,
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.iconTexturePath") or "" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.iconTexturePath", value) end,
                },
                {
                    type = "colorpicker",
                    label = "Icon Color:",
                    getValue = function(self) return config.getValue(self.uniqueID, "iconColor") or {r=1, g=1, b=1, a=1} end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconColor", value) end,
                },
                {
                    type = "positionbuttons",
                    label = "Shift Position:",
                    getValue = function(self) 
                        local x = config.getValue(self.uniqueID, "position.x") or 0
                        local y = config.getValue(self.uniqueID, "position.y") or 0
                        return x, y
                    end,
                    setValue = function(self, axis, value)
                        local oldValueX, oldValueY = self:getValue()
                        local newValue = 0
                        if axis == 'y' then newValue = oldValueY + value end
                        if axis == 'x' then newValue = oldValueX + value end
                        
                        config.setValue(self.uniqueID, "position." .. axis, newValue)
                    end,
                },
                {
                    type = "textinput",
                    label = "Size:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.size") or 48 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.size", value) end,
                },
                {
                    type = "textinput",
                    label = "Opacity:",
                    numeric = true,
                    max = 1,
                    min = 0,
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.opacity") or 1.0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.opacity", value) end,
                },
                {
                    type = "checkbox",
                    label = "Desaturate when on cooldown",
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.desaturated") or false end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.desaturated", value) end,
                },
                {
                    type = "checkbox",
                    label = "Hide default swipe animation",
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.hideDefaultSweep") == true end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.hideDefaultSweep", value) end,
                },
                {
                    type = "checkbox",
                    label = "Is Spell Off the GCD",
                    tooltip = "Enable for spells that are inherently off the global cooldown (e.g. self-buff procs). When checked, SPELL_UPDATE_COOLDOWN events for this spell will always be treated as a real cooldown regardless of the isOnGCD field.",
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.isSpellOffGCD") or false end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.isSpellOffGCD", value) end,
                },
            }
        },
        
        -- Status bar
        {
            type = "header",
            text = "Bar Timer",
            state = 'collapsed',
            section = {
				{
                    type = "button",
                    buttonText = "Mock Cooldown",
                    width = 120,
                    offsetY = -15,
                    onClick = function(btn, btnFrame)
                        SpellStyler.FrameTrackerManager:ToggleMockCooldown(btn.uniqueID, btn.trackerType)
                        -- Update button text based on new state
                        local updatedFrame = SpellStyler.FrameTrackerManager:GetTrackerFrame(btn.uniqueID, btn.trackerType)
                        local isNowActive = updatedFrame and updatedFrame._spellStyler_mockCooldownActive or false
                        btnFrame:SetText(isNowActive and "Stop Cooldown" or "Mock Cooldown")
                    end,
                    onStateGet = function(self)
                        local trackerFrame = SpellStyler.FrameTrackerManager:GetTrackerFrame(self.uniqueID, self.trackerType)
                        local isMockActive = trackerFrame and trackerFrame._spellStyler_mockCooldownActive or false
                        return isMockActive and "Stop Cooldown" or "Mock Cooldown"
                    end,
                },
                {
                    type = "dropdown",
                    label = "Bar Display State:",
                    options = RADIAL_DISPLAY_OPTIONS,
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.displayState") or "always" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.displayState", value) end,
                },
				{
                    type = "dropdown",
                    label = "Anchor Point on Self:",
                    options = ANCHOR_OPTIONS,
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.anchorSelf") or "LEFT" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.anchorSelf", value) end,
                },
				{
                    type = "dropdown",
                    label = "Anchor Point on Icon:",
                    options = ANCHOR_OPTIONS,
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.anchorParent") or "RIGHT" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.anchorParent", value) end,
                },
                {
                    type = "textinput",
                    label = "Custom Texture Path:",
                    width = 160,
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.customBarTexture") or "" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.customBarTexture", value) end,
                },
                {
                    type = "checkbox",
                    label = "Only Render Bar (no border/background):",
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.onlyRenderBar") or false end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.onlyRenderBar", value) end,
                },
                {
                    type = "dropdown",
                    label = "Bar Orientation:",
                    options = {
                        { label = "Horizontal", value = "horizontal" },
                        { label = "Vertical",   value = "vertical" },
                    },
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.barOrientation") or "horizontal" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.barOrientation", value) end,
                },
                {
                    type = "dropdown",
                    label = "Fill Direction:",
                    options = {
                        { label = "Regular", value = "regular" },
                        { label = "Inverse", value = "inverse" },
                    },
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.barFillDirection") or "regular" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.barFillDirection", value) end,
                },
                {
                    type = "dropdown",
                    label = "Default Fill Value:",
                    options = {
                        { label = "Empty", value = "empty" },
                        { label = "Full",  value = "full" },
                    },
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.defaultFillValue") or "empty" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.defaultFillValue", value) end,
                },
                {
                    type = "colorpicker",
                    label = "Bar Color:",
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.color") or {r=1, g=1, b=1, a=1} end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.color", value) end,
                },
                {
                    type = "colorpicker",
                    label = "Background Color:",
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.backgroundColor") or {r=0.2, g=0.2, b=0.2, a=0.6} end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.backgroundColor", value) end,
                },
                {
                    type = "colorpicker",
                    label = "Glow Color:",
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.glowColor") or {r=0.5, g=0.8, b=1, a=0.4} end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.glowColor", value) end,
                },
                {
                    type = "colorpicker",
                    label = "Border Color:",
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.borderColor") or {r=1, g=1, b=1, a=1} end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.borderColor", value) end,
                },
                {
                    type = "textinput",
                    label = "Scale:",
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.scale") or 1.0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.scale", value) end,
                },
                {
                    type = "textinput",
                    label = "Border Scale:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.borderScale") or 1.0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.borderScale", value) end,
                },
                {
                    type = "positionbuttons",
                    label = "Shift Position:",
                    getValue = function(self) 
                        local x = config.getValue(self.uniqueID, "statusBar.x") or 0
                        local y = config.getValue(self.uniqueID, "statusBar.y") or 0
                        return x, y
                    end,
                    setValue = function(self, axis, value)
                        local oldValueX, oldValueY = self:getValue()
                        local newValue = 0
                        if axis == 'y' then newValue = oldValueY + value end
                        if axis == 'x' then newValue = oldValueX + value end
                        
                        config.setValue(self.uniqueID, "statusBar." .. axis, newValue)
                    end,
                },
                {
                    type = "textinput",
                    label = "Width:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.width") or (config.getValue(self.uniqueID, "size") * 4) end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.width", value) end,
                },
                {
                    type = "textinput",
                    label = "Height:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.height") or config.getValue(self.uniqueID, "size") end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.height", value) end,
                },
            }
        },
        
        -- Cooldown Text
        {
            type = "header",
            text = "Cooldown Text",
            state = 'collapsed',
            section = {
                {
                    type = "checkbox",
                    label = "Display Cooldown Text",
                    getValue = function(self) return config.getValue(self.uniqueID, "cooldownText.display") or false end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "cooldownText.display", value) end,
                },
                {
                    type = "textinput",
                    label = "Size:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "cooldownText.size") or 14 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "cooldownText.size", value) end,
                },
                {
                    type = "colorpicker",
                    label = "Color:",
                    getValue = function(self) return config.getValue(self.uniqueID, "cooldownText.color") or {r=1, g=1, b=1, a=1} end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "cooldownText.color", value) end,
                },
                {
                    type = "textinput",
                    label = "Offset X:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "cooldownText.x") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "cooldownText.x", value) end,
                },
                {
                    type = "textinput",
                    label = "Offset Y:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "cooldownText.y") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "cooldownText.y", value) end,
                },
            }
        },
        
        -- Count Text
        {
            type = "header",
            text = "Count/Charge Text",
            state = 'collapsed',
            section = {
                {
                    type = "checkbox",
                    label = "Display Charge/Count Text",
                    getValue = function(self) return config.getValue(self.uniqueID, "countText.display") or false end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "countText.display", value) end,
                },
                {
                    type = "textinput",
                    label = "Size:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "countText.size") or 14 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "countText.size", value) end,
                },
                {
                    type = "colorpicker",
                    label = "Color:",
                    getValue = function(self) return config.getValue(self.uniqueID, "countText.color") or {r=1, g=1, b=1, a=1} end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "countText.color", value) end,
                },
                {
                    type = "textinput",
                    label = "Offset X:",
                    numeric = true,
                    min = -5000,
                    getValue = function(self) return config.getValue(self.uniqueID, "countText.x") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "countText.x", value) end,
                },
                {
                    type = "textinput",
                    label = "Offset Y:",
                    numeric = true,
                    min = -5000,
                    getValue = function(self) return config.getValue(self.uniqueID, "countText.y") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "countText.y", value) end,
                },
            }
        },
        
        -- Custom Label
        {
            type = "header",
            text = "Custom Label (Accessibility)",
            state = 'collapsed',
            section = {
                {
                    type = "checkbox",
                    label = "Show Custom Label",
                    getValue = function(self) return config.getValue(self.uniqueID, "customLabel.display") or false end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "customLabel.display", value) end,
                },
                {
                    type = "textinput",
                    label = "Text:",
                    getValue = function(self) return config.getValue(self.uniqueID, "customLabel.text") or "" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "customLabel.text", value) end,
                },
                {
                    type = "textinput",
                    label = "Font Size:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "customLabel.size") or 14 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "customLabel.size", value) end,
                },
                {
                    type = "colorpicker",
                    label = "Color:",
                    getValue = function(self) return config.getValue(self.uniqueID, "customLabel.color") or {r=1, g=1, b=1, a=1} end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "customLabel.color", value) end,
                },
                {
                    type = "textinput",
                    label = "Offset X:",
                    numeric = true,
                    min = -5000,
                    getValue = function(self) return config.getValue(self.uniqueID, "customLabel.x") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "customLabel.x", value) end,
                },
                {
                    type = "textinput",
                    label = "Offset Y:",
                    numeric = true,
                    min = -5000,
                    getValue = function(self) return config.getValue(self.uniqueID, "customLabel.y") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "customLabel.y", value) end,
                },
            }
        },
    }
end

-- ============================================================================
-- GENERIC CONFIG CONTROL RENDERER
-- ============================================================================
--[[
	options = {
		parentFrame
		uniqueID,
		trackerType
	}
]]
function IconSettingsRenderer:RenderConfigControlsForSpecificIcon(options)
    local parent = options.parentFrame or controlsPanel
	if not parent then return end
	local uniqueID = options.uniqueID
	local trackerType = options.trackerType or IconSettingsRenderer:getTrackerTypeForID(uniqueID)
    local PANEL_WIDTH = options.panelWidth or 400
    options.sectionStates = options.sectionStates or {}

    -- Reset arrow-key position configs for this render pass
    _activePositionConfigs = {}
    if _keyboardFrame then _keyboardFrame:EnableKeyboard(false) end
    
    -- Destroy old controls container
    if parent.currentControlsContainer then
        parent.currentControlsContainer:Hide()
        parent.currentControlsContainer:SetParent(nil)
        parent.currentControlsContainer = nil
    end
    
    -- Clear any stale button references from the tracker frame
    local trackerFrame = SpellStyler.FrameTrackerManager:GetTrackerFrame(uniqueID, trackerType)
    if trackerFrame then
        trackerFrame._spellStyler_mockCooldownBtn = nil
    end
    
    -- Build config object with proper getValue/setValue for FrameTrackerManager
    -- These functions are called by control definitions with: config.getValue(self.uniqueID, "path")
    local config = {
        trackerType = trackerType,  -- Store to avoid repeated lookups
        getValue = function(uniqueID, path) 
            return SpellStyler.FrameTrackerManager:GetTrackerValueConfigProperty(uniqueID, trackerType, path) 
        end,
        setValue = function(uniqueID, path, value) 
            SpellStyler.FrameTrackerManager:SetTrackerValueConfigProperty(uniqueID, trackerType, path, value) 
        end
    }
    
    -- Get input definitions for this icon
    config.configInputs = IconSettingsRenderer:GetIconConfigInputs(config)
    
    if not config.configInputs then
        return
    end
    
    -- Create fresh controls container
    local container = CreateFrame("Frame", nil, parent)
    container:SetAllPoints()
    parent.currentControlsContainer = container
    
    -- Build controls
    local lastControl = nil
    
    -- Render main header with icon name
    local trackedValue = SpellStyler.FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
    if trackedValue then
        local header = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        header:SetPoint("TOPLEFT", 0, -10)
        header:SetText((trackedValue.name or uniqueID) .. " - (" .. trackerType .. ")")
        header:SetTextColor(1, 0.82, 0)
		local icon = CreateIconButton(container, trackedValue.defaultIconTexturePath, trackedValue.name or "", uniqueID, trackedValue.trackerType, 30)
		icon:SetPoint("LEFT", header, "RIGHT", 10, 0)

		-- Reset to Defaults button
		local resetBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
		resetBtn:SetSize(120, 22)
		resetBtn:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -10)
		resetBtn:SetText("Reset to Defaults")
		resetBtn:SetScript("OnClick", function()
			SpellStyler.FrameTrackerManager:ResetTrackerValueConfig(uniqueID, trackerType)
			IconSettingsRenderer:RenderConfigControlsForSpecificIcon(options)
		end)

        lastControl = resetBtn
    end
    
    -- Validate config inputs
    if not config.configInputs then
        print("ERROR: config.configInputs is nil")
        return
    end
    
    -- Loop through config inputs and render sections
    local sectionIndex = 0
    for i, inputDef in ipairs(config.configInputs) do
        if inputDef.type == "header" then
            sectionIndex = sectionIndex + 1
            
            -- Initialize section state from definition if not already set
            if options.sectionStates[sectionIndex] == nil then
                options.sectionStates[sectionIndex] = inputDef.state or "expanded"
            end
            
            local isExpanded = (options.sectionStates[sectionIndex] == "expanded")
            local sectionContent = inputDef.section or inputDef.sectionContent or {}
            
            -- Create header background frame with texture
            local headerFrameBg = CreateFrame("Frame", nil, container, "BackdropTemplate")
            if lastControl then
                headerFrameBg:SetPoint("TOPLEFT", lastControl, "BOTTOMLEFT", 0, inputDef.anchorOffsetY or -20)
            else
                headerFrameBg:SetPoint("TOPLEFT", 10, -10)
            end
            headerFrameBg:SetSize(290, 25)
            
            -- Create texture for header background
            local headerTexture = headerFrameBg:CreateTexture(nil, "BACKGROUND")
            headerTexture:SetAllPoints(headerFrameBg)
            headerTexture:SetTexture(isExpanded and "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_minus_cropped" or "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_plus_cropped")
            
            -- Create clickable header button (overlay on the texture)
            local headerBtn = CreateFrame("Button", nil, headerFrameBg)
            headerBtn:SetAllPoints(headerFrameBg)
            
            -- Header text (positioned on left side of the frame)
            local headerText = headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            headerText:SetPoint("LEFT", headerFrameBg, "LEFT", 15, 0)
            headerText:SetText(inputDef.text or "")
            headerText:SetTextColor(1, 0.82, 0)
            
            -- Capture section index and texture for toggle handler
            local capturedSectionIndex = sectionIndex
            
            -- Click handler to toggle section
            headerBtn:SetScript("OnClick", function()
                options.sectionStates[capturedSectionIndex] = (options.sectionStates[capturedSectionIndex] == "expanded") and "collapsed" or "expanded"
                IconSettingsRenderer:RenderConfigControlsForSpecificIcon(options)
            end)
            
            -- Hover effects
            headerBtn:SetScript("OnEnter", function()
                headerText:SetTextColor(1, 1, 0.5)
            end)
            headerBtn:SetScript("OnLeave", function()
                headerText:SetTextColor(1, 0.82, 0)
            end)
            
			-- dragging for copying settings of a section to another icon
			local ghostFrame = nil

			headerBtn:SetScript("OnMouseDown", function(self, button)
				if button ~= "LeftButton" then return end
				
				-- Create a ghost that looks like the header
				ghostFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
				ghostFrame:SetSize(self:GetWidth(), self:GetHeight())
				ghostFrame:SetFrameStrata("TOOLTIP")  -- Always on top while dragging
				-- Stamp source context so OnMouseUp has explicit, unambiguous access
				ghostFrame.sourceUniqueID      = uniqueID
				ghostFrame.sourceTrackerType   = trackerType
				ghostFrame.sourceSectionIndex  = capturedSectionIndex
				ghostFrame.category = inputDef.text or ""
				local ghostTexture = ghostFrame:CreateTexture(nil, "BACKGROUND")
            	ghostTexture:SetAllPoints(ghostFrame)
            	ghostTexture:SetTexture(isExpanded and "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_minus_cropped" or "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_plus_cropped")
				local ghostText = ghostFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            	ghostText:SetPoint("LEFT", ghostFrame, "LEFT", 15, 0)
            	ghostText:SetText(inputDef.text or "")
            	ghostText:SetTextColor(1, 0.82, 0)

				ghostFrame:SetAlpha(0.7)
				
				-- Follow cursor via OnUpdate
				ghostFrame:SetScript("OnUpdate", function()
					local x, y = GetCursorPosition()
					local scale = UIParent:GetEffectiveScale()
					ghostFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
					-- Highlight whichever icon selector button the cursor is over
					for _, iconBtn in ipairs(settingsMenuIconList or {}) do
						if iconBtn.glowBorder then
							if iconBtn:IsMouseOver() then
								iconBtn.glowBorder:Show()
							else
								iconBtn.glowBorder:Hide()
							end
						end
					end
				end)
				
				ghostFrame:Show()
			end)

			headerBtn:SetScript("OnMouseUp", function(self, button)
				if not ghostFrame then return end
				
				local sourceUniqueID     = ghostFrame.sourceUniqueID
				local sourceTrackerType  = ghostFrame.sourceTrackerType
				local category			 = ghostFrame.category
				-- Check if cursor is over one of the icon selector buttons on the left
				for _, iconBtn in ipairs(settingsMenuIconList or {}) do
					if iconBtn:IsMouseOver() then
						local targetUniqueID    = iconBtn.uniqueID
						local targetTrackerType = iconBtn.trackerType
						local copyInfo = {
							targetUniqueID = targetUniqueID,
							targetTrackerType = targetTrackerType,
							sourceUniqueID = sourceUniqueID,
							sourceTrackerType = sourceTrackerType,
							category = category
						}
						SpellStyler.FrameTrackerManager:CopySettings(copyInfo)
						-- CopySettingsSection(sourceSectionIndex, sourceUniqueID, sourceTrackerType, targetUniqueID, targetTrackerType)
					end
					-- Always clear glow on drop
					if iconBtn.glowBorder then
						iconBtn.glowBorder:Hide()
					end
				end
				
				ghostFrame:Hide()
				ghostFrame:SetScript("OnUpdate", nil)
				ghostFrame = nil
			end)



            lastControl = headerFrameBg
            
            -- Render section content if expanded
            if isExpanded then
                for _, controlDef in ipairs(sectionContent) do
                    -- Set uniqueID on control so getValue/setValue can access it via self.uniqueID
                    controlDef.uniqueID = uniqueID
                    
                    -- Handle dynamic options for dropdowns
                    if controlDef.type == "dropdown" and controlDef.getOptions then
                        controlDef.options = controlDef:getOptions()
                    end
                    
                    -- Render control based on type
                    local controlFrame = nil
                    if controlDef.type == "dropdown" then
                        local label, dropdown = IconSettingsRenderer:CreateDropdown(container, controlDef, lastControl)
                        controlFrame = label
                    elseif controlDef.type == "textinput" then
                        local label, input = CreateTextInput(container, controlDef, lastControl)
                        controlFrame = label
                    elseif controlDef.type == "colorpicker" then
                        local label, btn = CreateColorPicker(container, controlDef, lastControl)
                        controlFrame = label
                    elseif controlDef.type == "checkbox" then
                        local checkbox, label = CreateCheckbox(container, controlDef, lastControl)
                        controlFrame = checkbox
                    elseif controlDef.type == "positionbuttons" then
                        table.insert(_activePositionConfigs, controlDef)
                        local hintText = (#_activePositionConfigs == 1)
                            and "|cff888888Drag icon or use arrow keys to move|r"
                            or  "|cff888888Shift + arrow keys to move status bar|r"
                        local row = CreatePositionHint(container, controlDef, lastControl, hintText)
                        controlFrame = row
                    elseif controlDef.type == "button" then
                        local btn = CreateButton(container, controlDef, lastControl)
                        -- Store context on button for onClick callback
                        btn.uniqueID = uniqueID
                        btn.trackerType = trackerType
                        -- Set initial button text based on state
                        if controlDef.onStateGet then
                            btn:SetText(controlDef:onStateGet())
                        end
                        -- Store button reference on frame so cooldown hook can update it
                        local trackerFrame = SpellStyler.FrameTrackerManager:GetTrackerFrame(uniqueID, trackerType)
                        if trackerFrame then
                            trackerFrame._spellStyler_mockCooldownBtn = btn
                        end
                        controlFrame = btn
                    elseif controlDef.type == "label" then
                        local label, valueLabel = CreateLabel(container, controlDef, lastControl)
                        controlFrame = label
                    end
                    
                    if controlFrame then
                        lastControl = controlFrame
                    end
                end
            end
        end
    end
    
    -- Enable arrow-key position shifting if any positionbuttons were rendered
    if #_activePositionConfigs > 0 then
        EnsureKeyboardFrame()
        _keyboardFrame:EnableKeyboard(true)
    end

    -- Set panel height dynamically based on last control
    if lastControl and lastControl.GetBottom then
        local panelTop = parent:GetTop()
        local lastControlBottom = lastControl:GetBottom()
        if panelTop and lastControlBottom then
            local contentHeight = panelTop - lastControlBottom + 40
            local finalHeight = math.max(contentHeight, 400)
            parent:SetHeight(finalHeight)
            if options.onHeightUpdated then
                options.onHeightUpdated(finalHeight)
            end
        else
            parent:SetHeight(900)
            if options.onHeightUpdated then
                options.onHeightUpdated(900)
            end
        end
    else
        parent:SetHeight(900)
        if options.onHeightUpdated then
            options.onHeightUpdated(900)
        end
    end
end

-- ============================================================================
-- RENDER SETTINGS INTO CONTAINER
-- Main entry point for rendering icon settings into any container frame
-- ============================================================================
function IconSettingsRenderer:getTrackerTypeForID(uniqueID)
	for _, tType in ipairs({"buffs", "essential", "utility"}) do
		if SpellStyler.FrameTrackerManager:CheckIsAlreadyTracker(uniqueID, tType) then
			return tType
		end
	end
	return ""	
end




function IconSettingsRenderer:RenderIconControlView(containerFrame)
	local iconSize, minPadding = 40, 4

	-- Create a scroll frame for the icon column, with hidden scrollbar and left padding for icons
	local iconScrollFrame = CreateFrame("ScrollFrame", nil, containerFrame, "UIPanelScrollFrameTemplate")
	iconScrollFrame:SetPoint("TOPLEFT", containerFrame, "TOPLEFT", 4, -4)
	iconScrollFrame:SetWidth(iconSize + 7) -- 7px left padding for icons
	iconScrollFrame:SetPoint("BOTTOMLEFT", containerFrame, "BOTTOMLEFT", 4, 4)

	local iconScrollChild = CreateFrame("Frame", nil, iconScrollFrame)
	iconScrollChild:SetSize(iconSize + 7, 100) -- height will be set dynamically
	iconScrollFrame:SetScrollChild(iconScrollChild)

	-- Hide the scrollbar if it exists
	local scrollBar = _G[iconScrollFrame:GetName() and (iconScrollFrame:GetName().."ScrollBar") or nil] or iconScrollFrame.ScrollBar
	if scrollBar then
		scrollBar:Hide()
		scrollBar.Show = function() end -- prevent it from being shown by template code
	end

	-- Add smooth scrolling behavior
	if SpellStyler.Cooldowns and type(IconSettingsRenderer.SetConsistentScrollingBehavior) == "function" then
		IconSettingsRenderer:SetConsistentScrollingBehavior(iconScrollFrame)
	end

	-- Create settings panel to the right of the icon scroll
	local settingsPanel = CreateFrame("Frame", nil, containerFrame, "BackdropTemplate")
	settingsPanel:SetPoint("TOPLEFT", iconScrollFrame, "TOPRIGHT", 10, -6)
	settingsPanel:SetPoint("BOTTOMRIGHT", containerFrame, "BOTTOMRIGHT", -10, 10)
	settingsPanel:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Buttons\\WHITE8x8",
		edgeSize = 1,
	})
	settingsPanel:SetBackdropColor(0.08, 0.08, 0.08, 0.8)
	settingsPanel:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
	
	
	
    -- Render icons directly into the scroll child in a single column
    IconSettingsRenderer.iconSelectorButtons = {}
    if SpellStyler.FrameTrackerManager and SpellStyler.FrameTrackerManager.getTrackerValuesListForSettings then
        local trackerList = SpellStyler.FrameTrackerManager:getTrackerValuesListForSettings()
        local count = #trackerList
        local iconPadding = 7
        local totalHeight = count * iconSize + (count + 1) * minPadding
        iconScrollChild:SetHeight(totalHeight)
        for i, entry in ipairs(trackerList) do
            local btn = CreateIconButton(iconScrollChild, entry.defaultIconTexturePath, entry.name, entry.uniqueID, entry.trackerType)
            table.insert(settingsMenuIconList, btn)
            local y = -iconPadding - (i - 1) * (iconSize + minPadding)
            btn:ClearAllPoints()
            btn:SetParent(iconScrollChild)
            btn:SetPoint("TOPLEFT", iconScrollChild, "TOPLEFT", iconPadding, y)
            btn:SetScript("OnClick", function(self)
				IconSettingsRenderer:RenderConfigControlsForSpecificIcon({
					uniqueID = entry.uniqueID,
					trackerType = entry.trackerType
				})
                -- When clicking an icon in the settings list, briefly show the
                -- glow on the actual tracker frame for 2 seconds so the user
                -- can visually locate it in the UI.
				SpellStyler.FrameTrackerManager:BrieflyHighlightFrame(entry.uniqueID, entry.trackerType)
                
            end)
            btn:EnableMouse(true)
            btn:RegisterForClicks("LeftButtonUp")
        end
    end
	

    local settingsPanelScrollFrame = CreateFrame("ScrollFrame", nil, settingsPanel, "UIPanelScrollFrameTemplate")
    settingsPanelScrollFrame:SetPoint("TOPLEFT", 10, -10)
    settingsPanelScrollFrame:SetPoint("BOTTOMRIGHT", -10, 10)
    if SpellStyler and SpellStyler.Cooldowns and type(IconSettingsRenderer.SetConsistentScrollingBehavior) == "function" then
        IconSettingsRenderer:SetConsistentScrollingBehavior(settingsPanelScrollFrame)
    end

    -- Hide the vertical scrollbar
	local scrollBar = _G[settingsPanelScrollFrame:GetName() and (settingsPanelScrollFrame:GetName().."ScrollBar") or nil] or settingsPanelScrollFrame.ScrollBar
	if scrollBar then
		scrollBar:Hide()
		scrollBar.Show = function() end -- prevent it from being shown by template code
	end

    local scrollChild = CreateFrame("Frame", nil, settingsPanelScrollFrame)
    scrollChild:SetSize(settingsPanel:GetWidth() - 20, settingsPanel:GetHeight() - 20)
    settingsPanelScrollFrame:SetScrollChild(scrollChild)
    
    -- Controls panel (no backdrop, just a container inside scrollChild)
    controlsPanel = CreateFrame("Frame", nil, scrollChild)
    controlsPanel:SetPoint("TOPLEFT", 0, 0)
    controlsPanel:SetPoint("BOTTOMRIGHT", 0, 0)
    -- controlsPanel:SetHeight(100)  -- Will be updated dynamically
    
    -- "No Selection" label
    local noSelectionLabel = controlsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noSelectionLabel:SetPoint("CENTER", controlsPanel, "CENTER", 0, 0)
    noSelectionLabel:SetText("Select an icon to configure")
    noSelectionLabel:SetTextColor(0.5, 0.5, 0.5)

	-- associating the "no selection" to the parent so it can be removed when an icon is clicked
	controlsPanel.currentControlsContainer = noSelectionLabel
end
