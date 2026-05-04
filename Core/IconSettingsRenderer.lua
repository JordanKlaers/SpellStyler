local ADDON_NAME, SpellStyler = ...
SpellStyler.IconSettingsRenderer = SpellStyler.IconSettingsRenderer or {}
local IconSettingsRenderer = SpellStyler.IconSettingsRenderer
local State = SpellStyler.State

local controlsPanel
local settingsMenuIconList = {}
local _lastSelectedIcon = nil  -- { uniqueID, trackerType } persists across menu open/close
-- Persisted expand/collapse state for individual Special Visibility Condition entries
-- keyed by tostring(uniqueID), value is a table { [conditionIndex] = "collapsed"/nil }
local _conditionEntryStates = {}

-- Direct position-shifter functions, set each render pass from RenderConfigControlsForSpecificIcon
local _shiftIconPosition = nil  -- function(axis, delta)
local _shiftBarPosition  = nil  -- function(axis, delta)
IconSettingsRenderer.keyboardFrame = nil

-- References to position input fields so arrow keys can update them
local _iconPositionInputs = { x = nil, y = nil }
local _barPositionInputs = { x = nil, y = nil }

-- Callback for when frames are clicked in layout mode
local onFrameClickCallback = nil

function IconSettingsRenderer:SetConsistentScrollingBehavior(scrollFrame)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        
        local scrollAmount = self:GetHeight() * 0.025
        
        self:SetVerticalScroll(math.max(0, math.min(maxScroll, current - (delta * scrollAmount))))
    end)
end


local function EnsureKeyboardFrame()
    if IconSettingsRenderer.keyboardFrame then return end
    pcall(function()
        IconSettingsRenderer.keyboardFrame = CreateFrame("Frame", "SpellStylerArrowKeyCapture", UIParent)
        IconSettingsRenderer.keyboardFrame:SetSize(1, 1)
        IconSettingsRenderer.keyboardFrame:SetPoint("CENTER")
        IconSettingsRenderer.keyboardFrame:EnableKeyboard(false)
        IconSettingsRenderer.keyboardFrame:SetScript("OnKeyDown", function(self, key)
            if key ~= "UP" and key ~= "DOWN" and key ~= "LEFT" and key ~= "RIGHT" then
                self:SetPropagateKeyboardInput(true)
                return
            end
            self:SetPropagateKeyboardInput(false)
            local fn = IsShiftKeyDown() and _shiftBarPosition or _shiftIconPosition
            if not fn then return end
            if key == "UP"    then fn("y",  1)
            elseif key == "DOWN"  then fn("y", -1)
            elseif key == "LEFT"  then fn("x", -1)
            elseif key == "RIGHT" then fn("x",  1)
            end
        end)
    end)
end

-- Called each time the settings menu is shown so keyboard stays active
-- across close/reopen without needing a full re-render.
function IconSettingsRenderer:ReactivateKeyboard()
    if _lastSelectedIcon and self.keyboardFrame then
        self.keyboardFrame:EnableKeyboard(true)
    end
end

-- Programmatically select an icon by uniqueID/trackerType.
-- Scrolls the icon column to make the button visible, opens its config panel,
-- and enables arrow-key position shifting for it.
function IconSettingsRenderer:SelectIcon(uniqueID, trackerType)
    -- Update selection state and render the config panel
    _lastSelectedIcon = { uniqueID = uniqueID, trackerType = trackerType }
    self:RenderConfigControlsForSpecificIcon({ uniqueID = uniqueID, trackerType = trackerType })

    -- Briefly highlight the frame in the game world so the user can locate it
    self:BrieflyHighlightFrame(uniqueID, trackerType)
end

-- ============================================================================
-- INPUT FACTORY METHODS
-- ============================================================================

local function CreateIconButton(parent, iconPath, spellName, uniqueID, trackerType, size, devNotes)
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
		GameTooltip:SetText((spellName or ("ID: "..tostring(uniqueID))) .. " - " .. (trackerType or "?"), 1, 1, 1)
		GameTooltip:AddLine("ID: "..tostring(uniqueID), 0.7, 0.7, 0.7)
		
		-- Add devNotes if they exist
		if devNotes and type(devNotes) == "table" and #devNotes > 0 then
			GameTooltip:AddLine(" ", 1, 1, 1)
			GameTooltip:AddLine("Errors:", 1, 0.2, 0.2)
			for _, note in ipairs(devNotes) do
				GameTooltip:AddLine(note, 1, 0.5, 0.5, true)
			end
		end
		
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

    config.min = config.min or (config.allowNegative and -5000 or 0)
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

-- Creates: Position input fields (X and Y) with arrow-key support
-- Returns: container frame (for anchoring next control) and input references
local function CreatePositionInputs(parent, config, anchor, isBarPosition)
    config = config or {}
    
    -- Container frame
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(290, 50)
    container:SetPoint(config.anchorPoint or "TOPLEFT", anchor, config.relativePoint or "BOTTOMLEFT", config.offsetX or 0, config.offsetY or 0)
    
    -- Main label - vertically centered, left-aligned
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(config.label or "Position:")
    label:SetTextColor(0.8, 0.8, 0.8)
    label:SetPoint("LEFT", container, "LEFT", 0, 0)
    label:SetJustifyH("LEFT")
    
    -- Input row - positioned on the right side
    local inputRow = CreateFrame("Frame", nil, container)
    inputRow:SetSize(290, 20)
    inputRow:SetPoint("RIGHT", container, "RIGHT", 0, 0)
    
    -- Y input (rightmost)
    local yInput = CreateFrame("EditBox", nil, inputRow, "InputBoxTemplate")
    yInput:SetPoint("RIGHT", inputRow, "RIGHT", 0, 0)
    yInput:SetSize(50, 18)
    yInput:SetAutoFocus(false)
    yInput:SetNumeric(false)
    yInput:SetMaxLetters(6)
    
    -- Y label
    local yLabel = inputRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    yLabel:SetText("Y:")
    yLabel:SetTextColor(0.7, 0.7, 0.7)
    yLabel:SetPoint("RIGHT", yInput, "LEFT", -3, 0)
    
    -- X input (to the left of Y label)
    local xInput = CreateFrame("EditBox", nil, inputRow, "InputBoxTemplate")
    xInput:SetPoint("RIGHT", yLabel, "LEFT", -8, 0)
    xInput:SetSize(50, 18)
    xInput:SetAutoFocus(false)
    xInput:SetNumeric(false)
    xInput:SetMaxLetters(6)
    
    -- X label
    local xLabel = inputRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xLabel:SetText("X:")
    xLabel:SetTextColor(0.7, 0.7, 0.7)
    xLabel:SetPoint("RIGHT", xInput, "LEFT", -3, 0)
    
    -- Hint text (positioned below the inputs)
    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetText(config.hintText)
    hint:SetTextColor(0.8, 0.8, 0.8)
    hint:SetPoint("TOPRIGHT", inputRow, "BOTTOMRIGHT", 0, -2)
    hint:SetJustifyH("RIGHT")
    
    -- Set initial values from config
    xInput:SetText(tostring(config.getX and config:getX() or 0))
    yInput:SetText(tostring(config.getY and config:getY() or 0))
    
    -- Handle X input changes
    local function updateX()
        local value = tonumber(xInput:GetText())
        if not value then value = 0 end
        value = math.max(-5000, math.min(5000, value))
        xInput:SetText(tostring(value))
        if config.setX then config:setX(value) end
    end
    
    xInput:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        updateX()
    end)
    xInput:SetScript("OnEditFocusLost", updateX)
    
    -- Handle Y input changes
    local function updateY()
        local value = tonumber(yInput:GetText())
        if not value then value = 0 end
        value = math.max(-5000, math.min(5000, value))
        yInput:SetText(tostring(value))
        if config.setY then config:setY(value) end
    end
    
    yInput:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        updateY()
    end)
    yInput:SetScript("OnEditFocusLost", updateY)
    
    -- Store references for arrow key updates
    if isBarPosition then
        _barPositionInputs.x = xInput
        _barPositionInputs.y = yInput
    else
        _iconPositionInputs.x = xInput
        _iconPositionInputs.y = yInput
    end
    
    return container, { x = xInput, y = yInput }
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
    local COMPARISON_OPTIONS = {
        { label = "less than",             value = "<"  },
        { label = "greater than",          value = ">"  },
    }
    return {
        -- Icon settings
        {
            type = "header",
            text = "Icon Settings",
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
                    label = "Position:",
                    hintText = "You can also use arrow keys or mouse drag",
                    isBarPosition = false,
                },
                {
                    type = "textinput",
                    label = "Width:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.width") or 48 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.width", value) end,
                },
                {
                    type = "textinput",
                    label = "Height:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.height") or 48 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.height", value) end,
                },
                {
                    type = "textinput",
                    label = "Texture Zoom:",
                    tooltip = "Use values between 0 and 100",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.zoom") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.zoom", value) end,
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
                    type = "dropdown",
                    label = "Frame Strata:",
                    options = {
                        { label = "BACKGROUND",       value = "BACKGROUND" },
                        { label = "LOW",              value = "LOW" },
                        { label = "MEDIUM",           value = "MEDIUM" },
                        { label = "HIGH",             value = "HIGH" },
                        { label = "DIALOG",           value = "DIALOG" },
                        { label = "FULLSCREEN",       value = "FULLSCREEN" },
                        { label = "FULLSCREEN_DIALOG",value = "FULLSCREEN_DIALOG" },
                        { label = "TOOLTIP",          value = "TOOLTIP" },
                    },
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.frameStrataLevel") or "MEDIUM" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.frameStrataLevel", value) end,
                },
                {
                    type = "textinput",
                    label = "Frame Level:",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "iconSettings.frameStrataValue") or 100 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "iconSettings.frameStrataValue", value) end,
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
                }
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
                        SpellStyler.IconSettingsRenderer:ToggleMockCooldown(btn.uniqueID, btn.trackerType)
                        -- Update button text based on new state
                        
                        local isNowActive = SpellStyler.FrameTrackerManager.SpellStyler_frames[btn.trackerType][btn.uniqueID].meta.mockCooldownActive
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
                    label = "Fill or Empty:",
                    options = {
                        { label = "Fill", value = "regular" },
                        { label = "Empty", value = "inverse" },
                    },
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.fillOrEmpty") or "regular" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.fillOrEmpty", value) end,
                },
                {
                    type = "dropdown",
                    label = "Progress Direction:",
                    options = {
                        { label = "Standard", value = "standard" },
                        { label = "Reverse",  value = "reverse" },
                    },
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.progressDirection") or "standard" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.progressDirection", value) end,
                },
                {
                    type = "dropdown",
                    label = "Texture Rotation:",
                    options = {
                        { label = "0 degrees", value = 0 },
                        { label = "90 degrees",  value = math.pi / 2 },
                        { label = "180 degrees",  value = math.pi },
                        { label = "270 degrees",  value = (math.pi / 2) * 3 },
                    },
                    getValue = function(self) return config.getValue(self.uniqueID, "statusBar.textureRotation") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "statusBar.textureRotation", value) end,
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
                    label = "Position:",
                    hintText = "You can also use shift + arrow keys",
                    isBarPosition = true,
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
        {
            type = "header",
            text = "Conditional Property Overrides",
            state = 'collapsed',
            section = {
                {
                    type = "customRender",
                    render = function(container, lastControl, uid, tType, rerender)
                        return IconSettingsRenderer:RenderSpecialVisibilityConditionsContent(container, lastControl, uid, tType, rerender)
                    end
                }
            }
        },
        {
            type = "header",
            text = "Charge/Count based display",
            state = 'collapsed',
            section = {
                {
                    type = "checkbox",
                    label = "Enabled charge based display",
                    getValue = function(self) return config.getValue(self.uniqueID, "chargeBasedDisplay.enabled") or false end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "chargeBasedDisplay.enabled", value) end,
                },
                {
                    type = "dropdown",
                    label = "Display State",
                    options = {
                        { label = "Show", value = true },
                        { label = "Hide",  value = false },
                    },
                    getValue = function(self) return config.getValue(self.uniqueID, "chargeBasedDisplay.displayState") or true end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "chargeBasedDisplay.displayState", value) end,
                },
                {
                    type = "dropdown",
                    label = "comparison operator",
                    options = COMPARISON_OPTIONS,
                    getValue = function(self) return config.getValue(self.uniqueID, "chargeBasedDisplay.displayOperator") or true end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "chargeBasedDisplay.displayOperator", value) end,
                },
                {
                    type = "textinput",
                    label = "Value",
                    numeric = true,
                    getValue = function(self) return config.getValue(self.uniqueID, "chargeBasedDisplay.chargeValue") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "chargeBasedDisplay.chargeValue", value) end,
                },
            }
        },
        {
            type = "header",
            text = "Glow notification",
            state = 'collapsed',
            section = {
                {
                    type = "checkbox",
                    label = "Display icon glow when spell\nbecomes available to cast",
                    getValue = function(self) return config.getValue(self.uniqueID, "glowNotification.shouldDisplay") or false end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "glowNotification.shouldDisplay", value) end,
                },
                {
                    type = "dropdown",
                    label = "Glow Style",
                    options = {
                        { label = "Thin", value = "thin" },
                        { label = "Thick", value = "thick" }
                    },
                    getValue = function(self) return config.getValue(self.uniqueID, "glowNotification.glowStyle") or "thin" end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "glowNotification.glowStyle", value) end,
                },
                {
                    type = "textinput",
                    label = "Duration",
                    getValue = function(self) return config.getValue(self.uniqueID, "glowNotification.duration") or 1.0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "glowNotification.duration", value) end,
                },
                {
                    type = "colorpicker",
                    label = "Glow Color:",
                    getValue = function(self) return config.getValue(self.uniqueID, "glowNotification.glowColor") or {r=1, g=1, b=1, a=1} end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "glowNotification.glowColor", value) end,
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
                    min = -5000,
                    getValue = function(self) return config.getValue(self.uniqueID, "cooldownText.x") or 0 end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "cooldownText.x", value) end,
                },
                {
                    type = "textinput",
                    label = "Offset Y:",
                    numeric = true,
                    min = -5000,
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
                    type = "checkbox",
                    label = "Replace with Spell Display Count",
                    tooltip = "This will render the display count for the spell. This is different than charges and stacks. An example is Expel Harm showing the count of healing Spheres. The value is pulled from the action bar and the spell must be on the bar for it to work.",
                    getValue = function(self) return config.getValue(self.uniqueID, "countText.useSpellDisplayCount") or false end,
                    setValue = function(self, value) config.setValue(self.uniqueID, "countText.useSpellDisplayCount", value) end,
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
-- SPECIAL VISIBILITY CONDITIONS SECTION RENDERER
-- Called from the customRender control inside the "Special Visibility Conditions"
-- header section.  Returns the last frame created so the outer layout loop can
-- chain subsequent controls from it.
-- ============================================================================

-- ============================================================================
-- SPECIAL VISIBILITY CONDITIONS SECTION RENDERER
-- Called from the customRender control inside the "Special Visibility Conditions"
-- header section.  Returns the last frame created so the outer layout loop can
-- chain subsequent controls from it.
-- ============================================================================

-- Maps each user-visible property label to its dot-path in the tracker config
-- and the type of value input needed.
local PROPERTY_DEFS = {
    { label = "Offset X",              path = "position.x",                     inputType = "text"  },
    { label = "Offset Y",              path = "position.y",                     inputType = "text"  },
    { label = "Icon Color",            path = "iconColor",                      inputType = "color" },
    { label = "Icon Custom Texture",   path = "iconSettings.iconTexturePath",   inputType = "text",     inputLabel = "Texture path:"  },
    { label = "Icon Width",            path = "iconSettings.width",             inputType = "text"  },
    { label = "Icon Height",           path = "iconSettings.height",            inputType = "text"  },
    { label = "Opacity",               path = "iconSettings.opacity",           inputType = "text"  },
    { label = "Trigger Glow",          path = "glowNotification.shouldDisplay", inputType = "text",     inputLabel = "Glow duration:"  },
    { label = "Custom Label",          path = "customLabel.text",               inputType = "text"  },
    { label = "Custom Label Size",     path = "customLabel.size",               inputType = "text"  },
    { label = "Custom Label X",        path = "customLabel.x",                  inputType = "text"  },
    { label = "Custom Label Y",        path = "customLabel.y",                  inputType = "text"  },
    { label = "Custom Label Color",    path = "customLabel.color",              inputType = "color" },
    { label = "Cooldown Text Size",    path = "cooldownText.size",              inputType = "text"  },
    { label = "Cooldown Text Color",   path = "cooldownText.color",             inputType = "color" },
    { label = "Cooldown Text X",       path = "cooldownText.x",                 inputType = "text"  },
    { label = "Cooldown Text Y",       path = "cooldownText.y",                 inputType = "text"  },
    { label = "Count Text Size",       path = "countText.size",                 inputType = "text"  },
    { label = "Count Text X",          path = "countText.x",                    inputType = "text"  },
    { label = "Count Text Y",          path = "countText.y",                    inputType = "text"  },
    { label = "Count Text Color",      path = "countText.color",                inputType = "color" },
    -- { label = "CD Bar Texture",        path = "statusBar.customBarTexture",     inputType = "text"  },
    { label = "CD Bar Color",          path = "statusBar.color",                inputType = "color" },
    -- { label = "CD Bar BG Color",       path = "statusBar.backgroundColor",      inputType = "color" },
    -- { label = "CD Bar Border Color",   path = "statusBar.borderColor",          inputType = "color" },
    -- { label = "CD Bar Border Scale",   path = "statusBar.borderScale",          inputType = "text"  },
    { label = "CD Bar Scale",          path = "statusBar.scale",                inputType = "text"  },
    { label = "CD Bar X",              path = "statusBar.x",                    inputType = "text"  },
    { label = "CD Bar Y",              path = "statusBar.y",                    inputType = "text"  },
    { label = "CD Bar Width",          path = "statusBar.width",                inputType = "text"  },
    { label = "CD Bar Height",         path = "statusBar.height",               inputType = "text"  },
}

local _PROP_DEF_BY_PATH = {}
for _, def in ipairs(PROPERTY_DEFS) do _PROP_DEF_BY_PATH[def.path] = def end

local PLUS_ICON_PATH_SVC = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\PlusIcon.tga"

function IconSettingsRenderer:RenderSpecialVisibilityConditionsContent(container, lastControl, uniqueID, trackerType, rerender)
    local conditions = SpellStyler.State:GetSpecialVisibilityConditions(uniqueID, trackerType)

    -- ── "Add" row ──────────────────────────────────────────────────────────
    local addRow = CreateFrame("Frame", nil, container)
    addRow:SetSize(290, 28)
    addRow:SetPoint("TOPLEFT", lastControl, "BOTTOMLEFT", 0, -10)

    local nameInput = CreateFrame("EditBox", nil, addRow, "InputBoxTemplate")
    nameInput:SetSize(150, 18)
    nameInput:SetPoint("LEFT", addRow, "LEFT", 14, 0)
    nameInput:SetAutoFocus(false)
    nameInput:SetMaxLetters(64)
    nameInput:SetText("New Condition")

    local addBtn = CreateFrame("Button", nil, addRow, "UIPanelButtonTemplate")
    addBtn:SetSize(76, 22)
    addBtn:SetPoint("LEFT", nameInput, "RIGHT", 6, 0)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", function()
        local name = nameInput:GetText()
        if name and name ~= "" then
            SpellStyler.State:AddSpecialVisibilityCondition(uniqueID, trackerType, name)
            rerender()
        end
    end)

    -- Thin divider beneath the Add row
    local divider = container:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.4, 0.4, 0.4, 0.4)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT",  addRow, "BOTTOMLEFT",  0, -6)
    divider:SetPoint("TOPRIGHT", addRow, "BOTTOMRIGHT", 0, -6)

    local dividerAnchor = CreateFrame("Frame", nil, container)
    dividerAnchor:SetSize(290, 1)
    dividerAnchor:SetPoint("TOPLEFT", addRow, "BOTTOMLEFT", 0, -6)

    local currentAnchor = dividerAnchor

    -- ── Per-condition entries ──────────────────────────────────────────────
    local uidKey = tostring(uniqueID)
    _conditionEntryStates[uidKey] = _conditionEntryStates[uidKey] or {}

    for i, cond in ipairs(conditions) do
        local isExpanded = (_conditionEntryStates[uidKey][i] ~= "collapsed")
        local capturedI  = i

        -- Sub-header bar
        local subHeaderBg = CreateFrame("Frame", nil, container)
        subHeaderBg:SetPoint("TOPLEFT", currentAnchor, "BOTTOMLEFT", 0, -8)
        subHeaderBg:SetSize(258, 22)
        local subHeaderTexture = subHeaderBg:CreateTexture(nil, "BACKGROUND")
        subHeaderTexture:SetAllPoints(subHeaderBg)
        subHeaderTexture:SetTexture(isExpanded
            and "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_minus_green"
            or  "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_plus_green")

        local subHeaderBtn = CreateFrame("Button", nil, subHeaderBg)
        subHeaderBtn:SetAllPoints(subHeaderBg)

        local condLabel = (cond.customName and cond.customName ~= "") and cond.customName or ("Condition " .. i)
        local subHeaderText = subHeaderBg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        subHeaderText:SetPoint("LEFT", subHeaderBg, "LEFT", 8, 0)
        subHeaderText:SetText(condLabel)

        subHeaderText:SetTextColor(86/255, 160/255, 130/255)

        local delBtn = CreateFrame("Button", nil, container, "UIPanelCloseButton")
        delBtn:SetSize(22, 22)
        delBtn:SetPoint("LEFT", subHeaderBg, "RIGHT", 4, 0)
        delBtn:SetScript("OnClick", function()
            -- Get the frame and conditional key before removing from state
            local customFrame = SpellStyler.FrameTrackerManager.SpellStyler_frames[trackerType] and SpellStyler.FrameTrackerManager.SpellStyler_frames[trackerType][uniqueID]
            local conditionalKey = (cond.customName and cond.customName ~= "") and cond.customName or (cond.conditionalName or ("Condition " .. capturedI))
            
            -- Remove from state
            SpellStyler.State:RemoveSpecialVisibilityCondition(uniqueID, trackerType, capturedI)
            _conditionEntryStates[uidKey][capturedI] = nil
            
            -- Explicitly clear this conditional's cached overrides and update the frame
            if customFrame and SpellStyler.ConditionalEngine then
                SpellStyler.ConditionalEngine:ClearFramePropertyOverrides(customFrame, conditionalKey)
                if SpellStyler.FrameTrackerManager then
                    SpellStyler.FrameTrackerManager:UpdateFrame_ConfigurationChanges(uniqueID, trackerType)
                end
            end
            
            -- Now rerender the UI to show the deletion
            rerender()
        end)

        subHeaderBtn:SetScript("OnClick", function()
            if _conditionEntryStates[uidKey][capturedI] == "collapsed" then
                _conditionEntryStates[uidKey][capturedI] = nil
            else
                _conditionEntryStates[uidKey][capturedI] = "collapsed"
            end
            rerender()
        end)

        currentAnchor = subHeaderBg

        if isExpanded then
            -- ── Property overrides ─────────────────────────────────────────────
            local overrides = cond.propertyOverrides or {}

            local BOX_W    = 252  -- bordered box width; delete btn floats to the right
            local BOX_PAD  = 6   -- inner horizontal/vertical padding
            local ROW_H    = 24  -- height of each inner row
            local ROW_GAP  = 4   -- gap between the rows
            local BOX_H    = BOX_PAD + ROW_H + ROW_GAP + ROW_H + ROW_GAP + ROW_H + (BOX_PAD * 2)  -- 92

            for j, override in ipairs(overrides) do
                local capturedJ = j
                local propDef   = _PROP_DEF_BY_PATH[override.property]

                -- ── Bordered container for this override ───────────────────────
                local overrideBox = CreateFrame("Frame", nil, container, "BackdropTemplate")
                overrideBox:SetPoint("TOPLEFT", currentAnchor, "BOTTOMLEFT", 0, -6)
                overrideBox:SetSize(290, BOX_H)
                overrideBox:SetBackdrop({
                    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = true, tileSize = 16, edgeSize = 10,
                    insets = { left = 3, right = 3, top = 3, bottom = 3 },
                })
                overrideBox:SetBackdropColor(0.07, 0.07, 0.14, 0.75)
                overrideBox:SetBackdropBorderColor(0.32, 0.32, 0.52, 0.85)

                -- Delete button – floats to the right of the box (matches sub-header pattern)
                local delOverrideBtn = CreateFrame("Button", nil, container, "UIPanelCloseButton")
                delOverrideBtn:SetSize(20, 20)
                delOverrideBtn:SetPoint("TOPRIGHT", overrideBox, "TOPRIGHT", -4, -4)
                delOverrideBtn:SetScript("OnClick", function()
                    -- Get the frame and conditional key before removing from state
                    local customFrame = SpellStyler.FrameTrackerManager.SpellStyler_frames[trackerType] and SpellStyler.FrameTrackerManager.SpellStyler_frames[trackerType][uniqueID]
                    local conditionalKey = (cond.customName and cond.customName ~= "") and cond.customName or (cond.conditionalName or ("Condition " .. capturedI))
                    
                    -- Remove the property override from state
                    SpellStyler.State:RemovePropertyOverride(uniqueID, trackerType, capturedI, capturedJ)
                    
                    -- Explicitly clear this conditional's cached overrides and update the frame
                    if customFrame and SpellStyler.ConditionalEngine then
                        SpellStyler.ConditionalEngine:ClearFramePropertyOverrides(customFrame, conditionalKey)
                        if SpellStyler.FrameTrackerManager then
                            SpellStyler.FrameTrackerManager:UpdateFrame_ConfigurationChanges(uniqueID, trackerType)
                        end
                        SpellStyler.ConditionalEngine:EvaluateAll()
                    end
                    
                    -- Now rerender the UI to show the deletion
                    rerender()
                end)

                -- ── Row 1: "Set property:" ─────────────────────────────────────
                local propLabel = overrideBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                propLabel:SetPoint("TOPLEFT", overrideBox, "TOPLEFT", BOX_PAD, -BOX_PAD)
                propLabel:SetText("Set property:")
                propLabel:SetTextColor(0.65, 0.65, 0.65)

                -- Dropdown anchored to the right edge of the box
                -- UIDropDownMenuTemplate has ~16px right dead-zone; +14 corrects for it
                local propDropdown = CreateFrame("Frame", nil, overrideBox, "UIDropDownMenuTemplate")
                propDropdown:SetPoint("TOPRIGHT", delOverrideBtn, "TOPLEFT", 10, 0)
                UIDropDownMenu_SetWidth(propDropdown, 130)

                local function RefreshPropDropdown()
                    local def = _PROP_DEF_BY_PATH[override.property]
                    UIDropDownMenu_SetText(propDropdown, def and def.label or "|cFF888888(pick one)|r")
                end

                UIDropDownMenu_Initialize(propDropdown, function(self, level)
                    for _, def in ipairs(PROPERTY_DEFS) do
                        local info   = UIDropDownMenu_CreateInfo()
                        info.text    = def.label
                        info.value   = def.path
                        info.checked = (override.property == def.path)
                        info.func    = function(btn)
                            SpellStyler.State:SetPropertyOverrideField(uniqueID, trackerType, capturedI, capturedJ, "property", btn.value)
                            local newDef = _PROP_DEF_BY_PATH[btn.value]
                            if newDef and newDef.inputType == "color" then
                                SpellStyler.State:SetPropertyOverrideField(uniqueID, trackerType, capturedI, capturedJ, "value", { r=1, g=1, b=1, a=1 })
                            else
                                SpellStyler.State:SetPropertyOverrideField(uniqueID, trackerType, capturedI, capturedJ, "value", "")
                            end
                            rerender()
                            if SpellStyler.ConditionalEngine then
                                SpellStyler.ConditionalEngine:EvaluateAll()
                            end
                        end
                        UIDropDownMenu_AddButton(info, level)
                    end
                end)
                RefreshPropDropdown()

                -- ── Row 2: Value input (label from propDef.inputLabel or "Set value:") ────
                local valLabel = overrideBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                valLabel:SetPoint("TOPLEFT", overrideBox, "TOPLEFT", BOX_PAD, -(BOX_PAD + ROW_H + ROW_GAP) - 5)
                valLabel:SetText((propDef and propDef.inputLabel) or "Set value:")
                valLabel:SetTextColor(0.65, 0.65, 0.65)

                if propDef and propDef.inputType == "color" then
                    local colorVal = type(override.value) == "table" and override.value or { r=1, g=1, b=1, a=1 }
                    local colorBtn = CreateFrame("Button", nil, overrideBox, "BackdropTemplate")
                    colorBtn:SetSize(46, 16)
                    colorBtn:SetPoint("TOPRIGHT", propDropdown, "BOTTOMRIGHT", -16, -4)
                    colorBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
                    colorBtn:SetBackdropColor(colorVal.r, colorVal.g, colorVal.b, colorVal.a or 1)
                    colorBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                    colorBtn:SetScript("OnClick", function()
                        local cur = type(override.value) == "table" and override.value or { r=1, g=1, b=1, a=1 }
                        local info = {
                            swatchFunc = function()
                                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                                local na = ColorPickerFrame:GetColorAlpha() or 1
                                colorBtn:SetBackdropColor(nr, ng, nb, na)
                                SpellStyler.State:SetPropertyOverrideField(uniqueID, trackerType, capturedI, capturedJ, "value", { r=nr, g=ng, b=nb, a=na })
                                if SpellStyler.ConditionalEngine then
                                    SpellStyler.ConditionalEngine:EvaluateAll()
                                end
                            end,
                            opacityFunc = function()
                                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                                local na = ColorPickerFrame:GetColorAlpha() or 1
                                colorBtn:SetBackdropColor(nr, ng, nb, na)
                                SpellStyler.State:SetPropertyOverrideField(uniqueID, trackerType, capturedI, capturedJ, "value", { r=nr, g=ng, b=nb, a=na })
                                if SpellStyler.ConditionalEngine then
                                    SpellStyler.ConditionalEngine:EvaluateAll()
                                end
                            end,
                            cancelFunc = function(prev)
                                colorBtn:SetBackdropColor(prev.r, prev.g, prev.b, prev.a or 1)
                                SpellStyler.State:SetPropertyOverrideField(uniqueID, trackerType, capturedI, capturedJ, "value", { r=prev.r, g=prev.g, b=prev.b, a=prev.a or 1 })
                                if SpellStyler.ConditionalEngine then
                                    SpellStyler.ConditionalEngine:EvaluateAll()
                                end
                            end,
                            hasOpacity = 1,
                            opacity    = cur.a or 1,
                            r = cur.r or 1,
                            g = cur.g or 1,
                            b = cur.b or 1,
                        }
                        ColorPickerFrame:SetupColorPickerAndShow(info)
                    end)
                else
                    local textInput = CreateFrame("EditBox", nil, overrideBox, "InputBoxTemplate")
                    textInput:SetSize(130, 18)
                    textInput:SetPoint("TOPRIGHT", propDropdown, "BOTTOMRIGHT", -16, -4)
                    textInput:SetAutoFocus(false)
                    textInput:SetMaxLetters(256)
                    textInput:SetText(tostring(override.value or ""))
                    textInput:SetScript("OnTextChanged", function(self)
                        SpellStyler.State:SetPropertyOverrideField(uniqueID, trackerType, capturedI, capturedJ, "value", self:GetText())
                        if SpellStyler.ConditionalEngine then
                            SpellStyler.ConditionalEngine:EvaluateAll()
                        end
                    end)
                end

                -- ── Row 3: Duration input ──────────────────────────────────────
                local durationLabel = overrideBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                durationLabel:SetPoint("TOPLEFT", overrideBox, "TOPLEFT", BOX_PAD, -(BOX_PAD + ROW_H + ROW_GAP + ROW_H + ROW_GAP))
                durationLabel:SetWidth(170)
                durationLabel:SetWordWrap(true)
                durationLabel:SetJustifyH("LEFT")
                durationLabel:SetText("Add duration for temporary application. Otherwise leave blank")
                durationLabel:SetTextColor(0.65, 0.65, 0.65)

                local durationInput = CreateFrame("EditBox", nil, overrideBox, "InputBoxTemplate")
                durationInput:SetSize(60, 18)
                durationInput:SetPoint("TOPRIGHT", propDropdown, "BOTTOMRIGHT", -16, -(ROW_H + ROW_GAP + 4))
                durationInput:SetAutoFocus(false)
                durationInput:SetMaxLetters(10)
                durationInput:SetText(tostring(override.duration or ""))
                durationInput:SetScript("OnTextChanged", function(self)
                    local text = self:GetText()
                    local duration = (text and text ~= "") and tonumber(text) or nil
                    SpellStyler.State:SetPropertyOverrideField(uniqueID, trackerType, capturedI, capturedJ, "duration", duration)
                    if SpellStyler.ConditionalEngine then
                        SpellStyler.ConditionalEngine:EvaluateAll()
                    end
                end)

                currentAnchor = overrideBox
            end

            -- ── Plus button to add a new property override ─────────────────────
            local plusRow = CreateFrame("Frame", nil, container)
            plusRow:SetSize(290, 26)
            plusRow:SetPoint("TOPLEFT", currentAnchor, "BOTTOMLEFT", 0, -4)

            local plusBtn = CreateFrame("Button", nil, plusRow)
            plusBtn:SetSize(18, 18)
            plusBtn:SetPoint("LEFT", plusRow, "LEFT", 0, 0)
            local plusTex = plusBtn:CreateTexture(nil, "ARTWORK")
            plusTex:SetAllPoints()
            plusTex:SetTexture(PLUS_ICON_PATH_SVC)
            local plusHl = plusBtn:CreateTexture(nil, "HIGHLIGHT")
            plusHl:SetAllPoints()
            plusHl:SetTexture(PLUS_ICON_PATH_SVC)
            plusHl:SetAlpha(0.6)
            plusBtn:SetScript("OnClick", function()
                SpellStyler.State:AddPropertyOverride(uniqueID, trackerType, capturedI)
                rerender()
            end)

            local plusLabel = plusRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            plusLabel:SetPoint("LEFT", plusBtn, "RIGHT", 4, 0)
            plusLabel:SetText("Add property override")
            plusLabel:SetTextColor(0.5, 0.5, 0.5)

            currentAnchor = plusRow

            -- ── "When condition is true:" conditional selector ─────────────────
            local condTriggerRow = CreateFrame("Frame", nil, container)
            condTriggerRow:SetSize(290, 30)
            condTriggerRow:SetPoint("TOPLEFT", currentAnchor, "BOTTOMLEFT", 0, -8)

            local condTriggerLabel = condTriggerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            condTriggerLabel:SetPoint("LEFT", condTriggerRow, "LEFT", 0, 2)
            condTriggerLabel:SetText("When condition is true:")
            condTriggerLabel:SetTextColor(0.65, 0.65, 0.65)

            local condTriggerDropdown = CreateFrame("Frame", nil, condTriggerRow, "UIDropDownMenuTemplate")
            condTriggerDropdown:SetPoint("RIGHT", condTriggerRow, "RIGHT", 18, 0)
            UIDropDownMenu_SetWidth(condTriggerDropdown, 110)

            local function RefreshCondTrigger()
                local name = cond.conditionalName
                UIDropDownMenu_SetText(condTriggerDropdown, (name and name ~= "") and name or "|cFF888888(none)|r")
            end

            UIDropDownMenu_Initialize(condTriggerDropdown, function(self, level)
                -- "(none)" option
                local noneInfo    = UIDropDownMenu_CreateInfo()
                noneInfo.text     = "|cFF888888(none)|r"
                noneInfo.value    = ""
                noneInfo.checked  = (cond.conditionalName == "" or cond.conditionalName == nil)
                noneInfo.func     = function()
                    SpellStyler.State:SetSpecialVisibilityConditionConditionalName(uniqueID, trackerType, capturedI, "")
                    RefreshCondTrigger()
                    if SpellStyler.ConditionalEngine then
                        SpellStyler.ConditionalEngine:EvaluateAll()
                    end
                end
                UIDropDownMenu_AddButton(noneInfo, level)

                -- Saved conditionals from the DB
                local names = {}
                if SpellStyler_DB and SpellStyler_DB.conditionals then
                    for name in pairs(SpellStyler_DB.conditionals) do
                        table.insert(names, name)
                    end
                    table.sort(names)
                end
                for _, name in ipairs(names) do
                    local info   = UIDropDownMenu_CreateInfo()
                    info.text    = name
                    info.value   = name
                    info.checked = (cond.conditionalName == name)
                    info.func    = function(btn)
                        SpellStyler.State:SetSpecialVisibilityConditionConditionalName(uniqueID, trackerType, capturedI, btn.value)
                        RefreshCondTrigger()
                    end
                    UIDropDownMenu_AddButton(info, level)
                end
                if #names == 0 then
                    local info    = UIDropDownMenu_CreateInfo()
                    info.text     = "|cFF888888(no conditionals saved)|r"
                    info.disabled = true
                    UIDropDownMenu_AddButton(info, level)
                end
            end)
            RefreshCondTrigger()

            currentAnchor = condTriggerRow
        end
    end

    -- Return the last frame so the outer renderer can anchor the next section to it
    return currentAnchor
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

    -- Reset position shifters for this render pass; set as direct closures below
    _shiftIconPosition = function(axis, delta)
        local x = SpellStyler.State:GetTrackerValueConfigProperty(uniqueID, trackerType, "position.x") or 0
        local y = SpellStyler.State:GetTrackerValueConfigProperty(uniqueID, trackerType, "position.y") or 0
        local newValue = (axis == "x" and x or y) + delta
        SpellStyler.State:SetTrackerValueConfigProperty(uniqueID, trackerType, "position." .. axis, newValue)
        -- Update input field if it exists
        if _iconPositionInputs[axis] then
            _iconPositionInputs[axis]:SetText(tostring(newValue))
        end
    end
    _shiftBarPosition = function(axis, delta)
        local x = SpellStyler.State:GetTrackerValueConfigProperty(uniqueID, trackerType, "statusBar.x") or 0
        local y = SpellStyler.State:GetTrackerValueConfigProperty(uniqueID, trackerType, "statusBar.y") or 0
        local newValue = (axis == "x" and x or y) + delta
        SpellStyler.State:SetTrackerValueConfigProperty(uniqueID, trackerType, "statusBar." .. axis, newValue)
        -- Update input field if it exists
        if _barPositionInputs[axis] then
            _barPositionInputs[axis]:SetText(tostring(newValue))
        end
    end
    if IconSettingsRenderer.keyboardFrame then IconSettingsRenderer.keyboardFrame:EnableKeyboard(false) end
    
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
            return SpellStyler.State:GetTrackerValueConfigProperty(uniqueID, trackerType, path) 
        end,
        setValue = function(uniqueID, path, value) 
            SpellStyler.State:SetTrackerValueConfigProperty(uniqueID, trackerType, path, value) 
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
    local trackedValue = SpellStyler.State:GetSpecificTrackerValue(uniqueID, trackerType)
    if trackedValue then
        -- Derive the current spell name from the live frame's activeSpellID when available
        local trackerFrame = SpellStyler.FrameTrackerManager.SpellStyler_frames[trackerType] and SpellStyler.FrameTrackerManager.SpellStyler_frames[trackerType][uniqueID]
        local activeSpellID = (trackerFrame and trackerFrame.meta and trackerFrame.meta.activeSpellID) or trackedValue.overrideSpellID or uniqueID
        local spellInfo = activeSpellID and C_Spell.GetSpellInfo(activeSpellID)
        local displayName = (spellInfo and spellInfo.name) or trackedValue.name or tostring(uniqueID)
        local header = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        header:SetPoint("TOPLEFT", 0, -10)
        header:SetText(displayName .. " - (" .. trackerType .. ")")
        header:SetTextColor(1, 0.82, 0)
		local icon = CreateIconButton(container, trackedValue.defaultIconTexturePath, displayName, uniqueID, trackedValue.trackerType, 30, trackedValue.devNotes)
		icon:SetPoint("LEFT", header, "RIGHT", 10, 0)

		-- Reset to Defaults button
		local resetBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
		resetBtn:SetSize(120, 22)
		resetBtn:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -10)
		resetBtn:SetText("Reset to Defaults")
		resetBtn:SetScript("OnClick", function()
			SpellStyler.State:ResetTrackerValueConfig(uniqueID, trackerType)
			IconSettingsRenderer:RenderConfigControlsForSpecificIcon(options)
		end)

		-- Disable button (non-buffs only)
		if trackerType ~= "buffs" then
			local disableBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
			disableBtn:SetSize(80, 22)
			disableBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
			disableBtn:SetText("Disable")
			disableBtn:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText(
					"This will remove the spell from being tracked. The settings will be saved in the database if you want to re-add the spell",
					nil, nil, nil, nil, true
				)
				GameTooltip:Show()
			end)
			disableBtn:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			disableBtn:SetScript("OnClick", function()
				-- Mark as disabled in the DB
				SpellStyler.State:SetTrackerValueConfigProperty(uniqueID, trackerType, "isEnabled", false)
				-- Completely destroy the live frame (clears cooldown, detaches from
				-- UIParent, nils the SpellStyler_frames entry so no event handler
				-- can ever reach it again). DB entry is preserved.
				if SpellStyler.FrameTrackerManager then
					SpellStyler.FrameTrackerManager:DestroyTrackerFrame(uniqueID, trackerType)
				end
				-- Re-render the icon list so the entry disappears
				if SpellStyler.settingsContentFrame then
					IconSettingsRenderer:RenderIconControlView(SpellStyler.settingsContentFrame)
				end
			end)
		end

        lastControl = resetBtn
    end
    
    -- Validate config inputs
    if not config.configInputs then
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
				ghostFrame.sourceBaseSpellID      = uniqueID
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
				
				local sourceBaseSpellID     = ghostFrame.sourceBaseSpellID
				local sourceTrackerType  = ghostFrame.sourceTrackerType
				local category			 = ghostFrame.category
				-- Check if cursor is over one of the icon selector buttons on the left
				for _, iconBtn in ipairs(settingsMenuIconList or {}) do
					if iconBtn:IsMouseOver() then
						local targetBaseSpellID    = iconBtn.uniqueID
						local targetTrackerType = iconBtn.trackerType
						local copyInfo = {
							targetBaseSpellID = targetBaseSpellID,
							targetTrackerType = targetTrackerType,
							sourceBaseSpellID = sourceBaseSpellID,
							sourceTrackerType = sourceTrackerType,
							category = category
						}
						SpellStyler.State:CopySettings(copyInfo)
						-- CopySettingsSection(sourceSectionIndex, sourceBaseSpellID, sourceTrackerType, targetBaseSpellID, targetTrackerType)
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
                        -- Determine if this is for bar position or icon position based on context
                        local isBarPosition = controlDef.isBarPosition or false
                        controlDef.getX = function(self)
                            local path = isBarPosition and "statusBar.x" or "position.x"
                            return SpellStyler.State:GetTrackerValueConfigProperty(uniqueID, trackerType, path) or 0
                        end
                        controlDef.getY = function(self)
                            local path = isBarPosition and "statusBar.y" or "position.y"
                            return SpellStyler.State:GetTrackerValueConfigProperty(uniqueID, trackerType, path) or 0
                        end
                        controlDef.setX = function(self, value)
                            local path = isBarPosition and "statusBar.x" or "position.x"
                            SpellStyler.State:SetTrackerValueConfigProperty(uniqueID, trackerType, path, value)
                        end
                        controlDef.setY = function(self, value)
                            local path = isBarPosition and "statusBar.y" or "position.y"
                            SpellStyler.State:SetTrackerValueConfigProperty(uniqueID, trackerType, path, value)
                        end
                        local row, inputs = CreatePositionInputs(container, controlDef, lastControl, isBarPosition)
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
                    elseif controlDef.type == "customRender" then
                        if controlDef.render then
                            local result = controlDef.render(container, lastControl, uniqueID, trackerType, function()
                                IconSettingsRenderer:RenderConfigControlsForSpecificIcon(options)
                            end)
                            if result then controlFrame = result end
                        end
                    end
                    
                    if controlFrame then
                        lastControl = controlFrame
                    end
                end
            end
        end
    end
    
    -- Enable arrow-key position shifting (shifters are always set for any loaded icon)
    EnsureKeyboardFrame()
    IconSettingsRenderer.keyboardFrame:EnableKeyboard(true)

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
		if SpellStyler.State:CheckIsAlreadyTracker(uniqueID, tType) then
			return tType
		end
	end
	return ""	
end


-- ============================================================================
-- MULTI-ICON SETTINGS RENDERER
-- Renders a settings panel that applies config changes to multiple icons.
-- ============================================================================

-- Persisted across section-toggle re-renders
local _multiSectionStates   = {}
local _multiSelectedIconIDs = {}   -- key = "uid_trackerType" -> { uniqueID, trackerType }
local _multiValues          = {}   -- key = dot-path -> value, acts as the "current" state for the multi panel

function IconSettingsRenderer:RenderMultiIconSettingsView(parentFrame)
    if not parentFrame then return end

    -- Disable arrow-key shifting (not applicable in multi mode)
    if IconSettingsRenderer.keyboardFrame then
        IconSettingsRenderer.keyboardFrame:EnableKeyboard(false)
    end
    _lastSelectedIcon = nil

    -- Destroy old controls container
    if parentFrame.currentControlsContainer then
        parentFrame.currentControlsContainer:Hide()
        parentFrame.currentControlsContainer:SetParent(nil)
        parentFrame.currentControlsContainer = nil
    end

    local container = CreateFrame("Frame", nil, parentFrame)
    container:SetAllPoints()
    parentFrame.currentControlsContainer = container

    -- ── Header ──────────────────────────────────────────────────────────────
    local header = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 10, -12)
    header:SetText("Multi Icon Settings")
    header:SetTextColor(1, 0.82, 0)

    local subtitle = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    subtitle:SetText("Changes apply to all selected icons below")
    subtitle:SetTextColor(0.6, 0.6, 0.6)

    -- ── Multi-select icon picker ─────────────────────────────────────────────
    local dropLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dropLabel:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -12)
    dropLabel:SetText("Apply to Icons:")
    dropLabel:SetTextColor(0.8, 0.8, 0.8)

    local dropBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    dropBtn:SetPoint("TOPLEFT", dropLabel, "BOTTOMLEFT", 0, -4)
    dropBtn:SetSize(220, 22)

    local function UpdateDropBtnText()
        local count = 0
        for _ in pairs(_multiSelectedIconIDs) do count = count + 1 end
        dropBtn:SetText(count .. " icon" .. (count == 1 and "" or "s") .. " selected")
    end
    UpdateDropBtnText()

    -- Floating dropdown panel parented to UIParent so it is never clipped
    -- No global name: avoids "already exists" errors on section-toggle re-renders
    local dropPanel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    dropPanel:SetSize(260, 220)  -- height adjusted dynamically in RebuildDropList
    dropPanel:SetFrameStrata("TOOLTIP")
    dropPanel:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    dropPanel:SetBackdropColor(0.08, 0.08, 0.08, 0.97)
    dropPanel:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    dropPanel:Hide()

    -- Scroll area inside the dropdown panel (fixed; only the child is rebuilt)
    local dpScroll = CreateFrame("ScrollFrame", nil, dropPanel, "UIPanelScrollFrameTemplate")
    dpScroll:SetPoint("TOPLEFT", 4, -4)
    dpScroll:SetPoint("BOTTOMRIGHT", -24, 4)

    -- currentScrollChild tracks the live child so we can hide it on rebuild
    local currentScrollChild = nil

    -- Rebuilds the checkbox list from the current tracker state.
    -- Called every time the panel is opened so additions/removals are reflected.
    local function RebuildDropList()
        -- Fetch fresh icon list
        local freshIcons = {}
        if SpellStyler.State and SpellStyler.State.getTrackerValuesListForSettings then
            local trackerList = SpellStyler.State:getTrackerValuesListForSettings()
            for _, entry in ipairs(trackerList) do
                if not entry.isHeader then
                    table.insert(freshIcons, entry)
                end
            end
        end

        -- Hide the previous scroll child (WoW has no frame:Destroy)
        if currentScrollChild then
            currentScrollChild:Hide()
            currentScrollChild:SetParent(nil)
            currentScrollChild = nil
        end

        -- Resize panel to fit content (capped at 220px)
        local panelHeight = math.min(#freshIcons * 26 + 28 + 12, 220)
        dropPanel:SetHeight(panelHeight)

        local dpScrollChild = CreateFrame("Frame", nil, dpScroll)
        dpScrollChild:SetSize(230, math.max(#freshIcons * 26 + 28 + 10, 10))
        dpScroll:SetScrollChild(dpScrollChild)
        currentScrollChild = dpScrollChild

        -- "Select All" / "Clear All" buttons
        local checkboxRefs = {}

        local selectAllBtn = CreateFrame("Button", nil, dpScrollChild, "UIPanelButtonTemplate")
        selectAllBtn:SetSize(90, 18)
        selectAllBtn:SetPoint("TOPLEFT", 4, -4)
        selectAllBtn:SetText("Select All")

        local clearAllBtn = CreateFrame("Button", nil, dpScrollChild, "UIPanelButtonTemplate")
        clearAllBtn:SetSize(80, 18)
        clearAllBtn:SetPoint("LEFT", selectAllBtn, "RIGHT", 6, 0)
        clearAllBtn:SetText("Clear All")

        -- One checkbox per icon
        for i, entry in ipairs(freshIcons) do
            local key = tostring(entry.uniqueID) .. "_" .. (entry.trackerType or "")
            local cb = CreateFrame("CheckButton", nil, dpScrollChild, "UICheckButtonTemplate")
            cb:SetSize(20, 20)
            cb:SetPoint("TOPLEFT", 4, -(i - 1) * 26 - 28)  -- 28 = height of the two header buttons
            cb:SetChecked(_multiSelectedIconIDs[key] ~= nil)
            local lbl = dpScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            lbl:SetText((entry.name or tostring(entry.uniqueID)) .. " |cff888888(" .. (entry.trackerType or "?") .. ")|r")
            lbl:SetTextColor(0.9, 0.9, 0.9)
            cb:SetScript("OnClick", function(self)
                if self:GetChecked() then
                    _multiSelectedIconIDs[key] = { uniqueID = entry.uniqueID, trackerType = entry.trackerType }
                else
                    _multiSelectedIconIDs[key] = nil
                end
                UpdateDropBtnText()
            end)
            checkboxRefs[key] = { cb = cb, entry = entry }
        end

        selectAllBtn:SetScript("OnClick", function()
            for key, ref in pairs(checkboxRefs) do
                ref.cb:SetChecked(true)
                _multiSelectedIconIDs[key] = { uniqueID = ref.entry.uniqueID, trackerType = ref.entry.trackerType }
            end
            UpdateDropBtnText()
        end)
        clearAllBtn:SetScript("OnClick", function()
            for key, ref in pairs(checkboxRefs) do
                ref.cb:SetChecked(false)
                _multiSelectedIconIDs[key] = nil
            end
            UpdateDropBtnText()
        end)
    end

    dropBtn:SetScript("OnClick", function(self)
        if dropPanel:IsShown() then
            dropPanel:Hide()
        else
            RebuildDropList()  -- refresh list before showing
            dropPanel:ClearAllPoints()
            dropPanel:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
            dropPanel:Show()
        end
    end)

    -- Hide the dropdown panel when the container is hidden
    container:SetScript("OnHide", function() dropPanel:Hide() end)

    -- ── Config for multi-icon control rendering ─────────────────────────────
    -- getValue reads from the shared _multiValues scratch table so controls
    -- always show the last value the user committed (instead of always showing
    -- each control's hard-coded default).
    -- setValue writes to _multiValues and fans out to every selected icon.
    local config = {
        trackerType = "spells",
        getValue = function(uid, path)
            return _multiValues[path]  -- nil on first open → controls show their own defaults
        end,
        setValue = function(uid, path, value)
            -- Store in scratch table so getValue reflects the new value immediately
            _multiValues[path] = value
            -- Apply to every selected icon
            for _, iconEntry in pairs(_multiSelectedIconIDs) do
                SpellStyler.State:SetTrackerValueConfigProperty(
                    iconEntry.uniqueID, iconEntry.trackerType, path, value)
            end
        end,
    }
    config.configInputs = IconSettingsRenderer:GetIconConfigInputs(config)

    -- ── Section rendering ────────────────────────────────────────────────────
    local lastControl = dropBtn
    local sectionIndex = 0

    for _, inputDef in ipairs(config.configInputs) do
        if inputDef.type == "header" then
            sectionIndex = sectionIndex + 1
            if _multiSectionStates[sectionIndex] == nil then
                _multiSectionStates[sectionIndex] = inputDef.state or "collapsed"
            end
            local isExpanded = (_multiSectionStates[sectionIndex] == "expanded")
            local sectionContent = inputDef.section or inputDef.sectionContent or {}

            local headerFrameBg = CreateFrame("Frame", nil, container, "BackdropTemplate")
            headerFrameBg:SetPoint("TOPLEFT", lastControl, "BOTTOMLEFT", 0, inputDef.anchorOffsetY or -20)
            headerFrameBg:SetSize(290, 25)
            local headerTexture = headerFrameBg:CreateTexture(nil, "BACKGROUND")
            headerTexture:SetAllPoints(headerFrameBg)
            headerTexture:SetTexture(isExpanded
                and "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_minus_cropped"
                or  "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_plus_cropped")

            local headerBtn = CreateFrame("Button", nil, headerFrameBg)
            headerBtn:SetAllPoints(headerFrameBg)
            local headerText = headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            headerText:SetPoint("LEFT", headerFrameBg, "LEFT", 15, 0)
            headerText:SetText(inputDef.text or "")
            headerText:SetTextColor(1, 0.82, 0)

            local capturedIdx = sectionIndex
            headerBtn:SetScript("OnClick", function()
                _multiSectionStates[capturedIdx] = (_multiSectionStates[capturedIdx] == "expanded") and "collapsed" or "expanded"
                IconSettingsRenderer:RenderMultiIconSettingsView(parentFrame)
            end)
            headerBtn:SetScript("OnEnter", function() headerText:SetTextColor(1, 1, 0.5) end)
            headerBtn:SetScript("OnLeave", function() headerText:SetTextColor(1, 0.82, 0) end)

            lastControl = headerFrameBg

            if isExpanded then
                for _, controlDef in ipairs(sectionContent) do
                    -- Skip "Mock Cooldown" button — not meaningful in multi mode
                    if controlDef.type == "button" then
                        -- intentionally skipped
                    else
                        controlDef.uniqueID = nil  -- no single uniqueID in multi mode

                        local controlFrame = nil
                        if controlDef.type == "dropdown" then
                            local row = IconSettingsRenderer:CreateDropdown(container, controlDef, lastControl)
                            controlFrame = row
                        elseif controlDef.type == "textinput" then
                            local row = CreateTextInput(container, controlDef, lastControl)
                            controlFrame = row
                        elseif controlDef.type == "colorpicker" then
                            local row = CreateColorPicker(container, controlDef, lastControl)
                            controlFrame = row
                        elseif controlDef.type == "checkbox" then
                            local checkbox = CreateCheckbox(container, controlDef, lastControl)
                            controlFrame = checkbox
                        elseif controlDef.type == "positionbuttons" then
                            local row = CreatePositionHint(container, controlDef, lastControl, controlDef.hintText)
                            controlFrame = row
                        elseif controlDef.type == "label" then
                            local label = CreateLabel(container, controlDef, lastControl)
                            controlFrame = label
                        end

                        if controlFrame then
                            lastControl = controlFrame
                        end
                    end
                end
            end
        end
    end

    -- Dynamic panel height
    if lastControl and lastControl.GetBottom then
        local panelTop  = parentFrame:GetTop()
        local lastBottom = lastControl:GetBottom()
        if panelTop and lastBottom then
            parentFrame:SetHeight(math.max(panelTop - lastBottom + 40, 400))
        else
            parentFrame:SetHeight(900)
        end
    else
        parentFrame:SetHeight(900)
    end
end




function IconSettingsRenderer:RenderIconControlView(containerFrame)
	local iconSize, minPadding = 40, 4

	-- Clean up previous render (so this function can be called again after an Update)
	if containerFrame._ssIconScrollFrame then
		containerFrame._ssIconScrollFrame:Hide()
		containerFrame._ssIconScrollFrame:SetParent(nil)
		containerFrame._ssIconScrollFrame = nil
	end
	if containerFrame._ssSettingsPanel then
		containerFrame._ssSettingsPanel:Hide()
		containerFrame._ssSettingsPanel:SetParent(nil)
		containerFrame._ssSettingsPanel = nil
	end
	settingsMenuIconList = {}
	controlsPanel = nil

	-- Create a scroll frame for the icon column, with hidden scrollbar and left padding for icons
	local iconScrollFrame = CreateFrame("ScrollFrame", nil, containerFrame, "UIPanelScrollFrameTemplate")
	iconScrollFrame:SetPoint("TOPLEFT", containerFrame, "TOPLEFT", 4, -4)
	iconScrollFrame:SetWidth(iconSize + 7) -- 7px left padding for icons
	iconScrollFrame:SetPoint("BOTTOMLEFT", containerFrame, "BOTTOMLEFT", 4, 4)

	local iconScrollChild = CreateFrame("Frame", nil, iconScrollFrame)
	iconScrollChild:SetSize(iconSize + 7, 100) -- height will be set dynamically
	iconScrollFrame:SetScrollChild(iconScrollChild)
	-- Store so SelectIcon can scroll to the right button
	self._iconScrollFrame = iconScrollFrame

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
    if SpellStyler.State and SpellStyler.State.getTrackerValuesListForSettings then
        local trackerList = SpellStyler.State:getTrackerValuesListForSettings()
        local iconPadding = 7
        local headerHeight = 14
        local headerPaddingBottom = 4
        local separatorGap = 6  -- space above and below the separator line

        -- Calculate total scroll child height: plus button + multi button + separator + entries
        local totalHeight = iconPadding + iconSize + minPadding + iconSize + separatorGap + 1 + separatorGap
        for _, entry in ipairs(trackerList) do
            if entry.isHeader then
                totalHeight = totalHeight + headerHeight + headerPaddingBottom
            else
                totalHeight = totalHeight + iconSize + minPadding
            end
        end
        iconScrollChild:SetHeight(math.max(totalHeight, 100))

        -- Plus button at the very top
        if SpellStyler.AddSpells then
            local plusBtn = SpellStyler.AddSpells:CreatePlusButton(iconScrollChild)
            plusBtn:SetPoint("TOPLEFT", iconScrollChild, "TOPLEFT", iconPadding, -iconPadding)
            plusBtn:SetScript("OnClick", function()
                _lastSelectedIcon = nil
                SpellStyler.AddSpells:RenderAddSpellsView(controlsPanel)
            end)
        end

        -- Multi-icon settings button (below the plus button)
        local multiBtn = CreateFrame("Button", nil, iconScrollChild)
        multiBtn:SetSize(iconSize, iconSize)
        multiBtn:SetPoint("TOPLEFT", iconScrollChild, "TOPLEFT", iconPadding, -(iconPadding + iconSize + minPadding))
        local multiTex = multiBtn:CreateTexture(nil, "ARTWORK")
        multiTex:SetAllPoints(multiBtn)
        multiTex:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\multi")
        multiBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Multi-Icon Settings", 1, 1, 1)
            GameTooltip:AddLine("Apply settings to multiple icons at once", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        multiBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        multiBtn:SetScript("OnClick", function()
            _lastSelectedIcon = nil
            IconSettingsRenderer:RenderMultiIconSettingsView(controlsPanel)
        end)

        -- Separator line between toolbar buttons and spell list
        local sep = iconScrollChild:CreateTexture(nil, "ARTWORK")
        sep:SetColorTexture(0.4, 0.4, 0.4, 0.5)
        sep:SetHeight(1)
        local sepY = -(iconPadding + iconSize + minPadding + iconSize + separatorGap)
        sep:SetPoint("TOPLEFT",  iconScrollChild, "TOPLEFT",  2, sepY)
        sep:SetPoint("TOPRIGHT", iconScrollChild, "TOPRIGHT", -2, sepY)

        local yOffset = -(iconPadding + iconSize + minPadding + iconSize + separatorGap + 1 + separatorGap)
        for _, entry in ipairs(trackerList) do
            if entry.isHeader then
                local lbl = iconScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                lbl:SetPoint("TOPLEFT", iconScrollChild, "TOPLEFT", 0, yOffset)
                lbl:SetWidth(iconSize + iconPadding * 2)
                lbl:SetText("|cFFFFD700" .. entry.label .. "|r")
                lbl:SetJustifyH("CENTER")
                yOffset = yOffset - headerHeight - headerPaddingBottom
            else
                local btn = CreateIconButton(iconScrollChild, entry.defaultIconTexturePath, entry.name, entry.uniqueID, entry.trackerType, nil, entry.devNotes)
                table.insert(settingsMenuIconList, btn)
                btn:ClearAllPoints()
                btn:SetParent(iconScrollChild)
                btn:SetPoint("TOPLEFT", iconScrollChild, "TOPLEFT", iconPadding, yOffset)
                btn:SetScript("OnClick", function(self)
                    _lastSelectedIcon = { uniqueID = entry.uniqueID, trackerType = entry.trackerType }
                    IconSettingsRenderer:RenderConfigControlsForSpecificIcon({
                        uniqueID = entry.uniqueID,
                        trackerType = entry.trackerType
                    })
                    -- When clicking an icon in the settings list, briefly show the
                    -- glow on the actual tracker frame for 2 seconds so the user
                    -- can visually locate it in the UI.
                    SpellStyler.IconSettingsRenderer:BrieflyHighlightFrame(entry.uniqueID, entry.trackerType)
                end)
                btn:EnableMouse(true)
                btn:RegisterForClicks("LeftButtonUp")
                yOffset = yOffset - iconSize - minPadding
            end
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

	-- Store references for cleanup on re-render
	containerFrame._ssIconScrollFrame = iconScrollFrame
	containerFrame._ssSettingsPanel = settingsPanel

	-- Re-select the previously chosen icon so arrow-key shifting works immediately
	if _lastSelectedIcon then
		IconSettingsRenderer:RenderConfigControlsForSpecificIcon({
			uniqueID    = _lastSelectedIcon.uniqueID,
			trackerType = _lastSelectedIcon.trackerType,
		})
	end
end

-- ============================================================================
-- LAYOUT MODE FUNCTIONS
-- Moved from FrameTrackerManager.lua as they are UI/settings-specific
-- ============================================================================

function IconSettingsRenderer:SetFrameClickCallback(callback)
    onFrameClickCallback = callback
end

function IconSettingsRenderer:EnableDraggingForAllFrames()
    local FrameTrackerManager = SpellStyler.FrameTrackerManager
    if not FrameTrackerManager then return end
    
    for trackerType, frames in pairs(FrameTrackerManager.SpellStyler_frames) do
        for baseSpellID, frame in pairs(frames) do
            if frame and not frame._inContainer then
                frame:EnableMouse(true)
                frame:RegisterForDrag("LeftButton")
                
                frame:SetScript("OnDragStart", function(self)
                    self:StartMoving()
                    -- Notify settings panel that this icon was selected
                    if onFrameClickCallback then
                        onFrameClickCallback(baseSpellID, trackerType)
                    end
                end)
                
                frame:SetScript("OnDragStop", function(self)
                    self:StopMovingOrSizing()
                    -- Save the new full position to the database (anchor, relative point, offsets)
                    local point, relativeTo, relativePoint, xOff, yOff = self:GetPoint()
                    -- Prefer saving a sanitized reference for relativeTo (use UIParent name when applicable)
                    local relRef = nil
                    if relativeTo == UIParent then
                        relRef = "UIParent"
                    end
                    
                    local positionData = {
                        anchorPoint = point or "CENTER",
                        relativeToFrame = relRef or nil,
                        relativeAnchorPoint = relativePoint or point or "CENTER",
                        x = xOff or 0,
                        y = yOff or 0
                    }
                    
                    State:SetTrackerValueConfigProperty(baseSpellID, trackerType, "position", positionData)
                    
                    -- Verify it was saved
                    local saved = State:GetTrackerValueConfigProperty(baseSpellID, trackerType, "position")
                end)
                
                -- Add click handler to select icon in settings
                frame:SetScript("OnMouseDown", function(self, button)
                    if button == "LeftButton" and onFrameClickCallback then
                        onFrameClickCallback(baseSpellID, trackerType)
                    end
                end)
            end
        end
    end
end

function IconSettingsRenderer:DisableDraggingForAllFrames()
    local FrameTrackerManager = SpellStyler.FrameTrackerManager
    if not FrameTrackerManager then return end
    
    onFrameClickCallback = nil
    
    for trackerType, frames in pairs(FrameTrackerManager.SpellStyler_frames) do
        for baseSpellID, frame in pairs(frames) do
            if frame then
                frame:EnableMouse(false)
                frame:RegisterForDrag()
                frame:SetScript("OnDragStart", nil)
                frame:SetScript("OnDragStop",  nil)
                frame:SetScript("OnMouseDown", nil)
                
                -- Hide the drag border indicator
                if frame._SpellStyler_dragBorder then
                    frame._SpellStyler_dragBorder:Hide()
                end
            end
        end
    end
end

function IconSettingsRenderer:ToggleMockCooldown(baseSpellID, trackerType)
    local FrameTrackerManager = SpellStyler.FrameTrackerManager
    if not FrameTrackerManager then return end
    
    local frame = FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    if not frame then
        return
    end
    
    -- Check if mock cooldown is currently active
    local isMockActive = frame.meta.mockCooldownActive or false
    if isMockActive then
        -- Disable mock cooldown
        frame.meta.mockCooldownActive = false
        if frame.cooldown then
            frame.cooldown:Clear()
        end
        if frame.statusBar then
            local mockDurationObj = C_DurationUtil.CreateDuration()
            mockDurationObj:SetTimeFromEnd(GetTime(), 0.001)
            frame.statusBar:SetTimerDuration(
                mockDurationObj,
                Enum.StatusBarInterpolation.Immediate,
                Enum.StatusBarTimerDirection.RemainingTime
            )
        end
        frame.meta.buffStatus = 'absent'

        FrameTrackerManager:DriveFrameUpdate(
            frame,
            {
                resolveDuration = false,
                syncChargeText = true
            },
            nil,
            "mockCooldown_remove"
        )
    else
        -- Enable mock cooldown (15 second duration)
        frame.meta.mockCooldownActive = true
        frame.meta.buffStatus = 'active'
        local mockDuration = 15
        local now = GetTime()
        
        -- Create a proper DurationObject for Apply Cooldown Duration()
        local mockDurationObj = C_DurationUtil.CreateDuration()
        mockDurationObj:SetTimeFromStart(now, mockDuration)
        local config = State:GetSpecificTrackerValue(baseSpellID, trackerType)

        FrameTrackerManager:DriveFrameUpdate(
            frame,
            {
                resolveDuration = true,
                syncChargeText = true
            }, {
                durationObject = mockDurationObj
            },
            "mockCooldown_set"
        )
    end
end

function IconSettingsRenderer:BrieflyHighlightFrame(baseSpellID, trackerType)
    local FrameTrackerManager = SpellStyler.FrameTrackerManager
    if not FrameTrackerManager then return end
    
    local f = FrameTrackerManager.SpellStyler_frames and FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    if f then
        local duration = 2
        local fadeIn = 0.5
        local fadeOut = 0.5
        pcall(function()
            -- Ensure glowFrame covers the frame
            if f.glowFrame and f.glowFrame.SetAllPoints then
                f.glowFrame:SetAllPoints(f)
            end

            -- Size the glow elements to be proportional to the icon size (use icon width when available)
            local width = 48
            if f.icon and f.icon.GetWidth then
                width = f.icon:GetWidth() or width
            elseif f.GetWidth then
                width = f:GetWidth() or width
            end
            local offset = math.max(8, math.floor(width * 0.22))

            -- Anchor glow textures to the glowFrame so they can extend outward
            if f.glowTexture then
                f.glowTexture:ClearAllPoints()
                f.glowTexture:SetPoint("TOPLEFT", f.glowFrame, "TOPLEFT", -offset, offset)
                f.glowTexture:SetPoint("BOTTOMRIGHT", f.glowFrame, "BOTTOMRIGHT", offset, -offset)
            end
            if f.glowAnts then
                local antsOffset = math.max(4, math.floor(offset * 0.5))
                f.glowAnts:ClearAllPoints()
                f.glowAnts:SetPoint("TOPLEFT", f.glowFrame, "TOPLEFT", -antsOffset, antsOffset)
                f.glowAnts:SetPoint("BOTTOMRIGHT", f.glowFrame, "BOTTOMRIGHT", antsOffset, -antsOffset)
            end

            if f.glowFrame then
                f.glowFrame:SetAlpha(0)
                f.glowFrame:Show()
                if UIFrameFadeIn then
                    UIFrameFadeIn(f.glowFrame, fadeIn, 0, 1)
                else
                    f.glowFrame:SetAlpha(1)
                end
            end

            if f.glowAnim and f.glowAnim.Play then
                pcall(function() f.glowAnim:Play() end)
            end
        end)

        C_Timer.After(duration - fadeOut, function()
            pcall(function()
                if f.glowAnim and f.glowAnim.Stop then pcall(function() f.glowAnim:Stop() end) end
                if f.glowFrame then
                    if UIFrameFadeOut then
                        UIFrameFadeOut(f.glowFrame, fadeOut, f.glowFrame:GetAlpha() or 1, 0)
                        C_Timer.After(fadeOut, function()
                            pcall(function() if f.glowFrame then f.glowFrame:Hide() end end)
                        end)
                    else
                        f.glowFrame:Hide()
                    end
                end
            end)
        end)
    end
end
