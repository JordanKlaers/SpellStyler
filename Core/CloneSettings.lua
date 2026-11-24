local ADDON_NAME, SpellStyler = ...
SpellStyler.CloneSettings = SpellStyler.CloneSettings or {}
local CloneSettings = SpellStyler.CloneSettings

local SECTION_DEFINITIONS = {
    { label = "Icon Settings", prefixes = { "iconColor", "scale", "position", "iconSettings", "shouldShowQualityEmblem" } },
    { label = "Aura Configuration", prefixes = { "auraConfig", "isNPCDebuff", "additionalBuffIDs" } },
    { label = "Aura / Cooldown Duration", prefixes = { "cooldownText", "statusBar" } },
    { label = "Conditional Property Overrides", prefixes = { "specialVisibilityConditions" } },
    { label = "Charge Based Display", prefixes = { "chargeBasedDisplay" } },
    { label = "Glow Notification", prefixes = { "glowNotification" } },
    { label = "Aura Stacks / Charges", prefixes = { "countText", "visualChargeBar" } },
    { label = "Custom Label", prefixes = { "customLabel" } },
}

local function GetTrackerKey(entry)
    return tostring(entry.trackerType) .. ":" .. tostring(entry.trackerKey)
end

local function GetTrackerLabel(entry)
    return (entry.name or tostring(entry.trackerKey))
        .. " |cff888888(" .. tostring(entry.trackerType or "?") .. ")|r"
end

local function GetTrackerList()
    local list = {}
    if SpellStyler.State and SpellStyler.State.getTrackerValuesListForSettings then
        for _, entry in ipairs(SpellStyler.State:getTrackerValuesListForSettings()) do
            if not entry.isHeader then
                list[#list + 1] = entry
            end
        end
    end
    return list
end

local function HideChildren(parent)
    for _, child in ipairs({ parent:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ parent:GetRegions() }) do
        if region:IsObjectType("FontString") or region:IsObjectType("Texture") then
            region:Hide()
            if region:IsObjectType("FontString") then
                region:SetText("")
            end
        end
    end
end

local function CreateLabel(parent, text, size, color)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(text)
    label:SetTextColor(color[1], color[2], color[3])
    if size then
        label:SetWidth(size)
        label:SetWordWrap(true)
    end
    return label
end

function CloneSettings:CreateToolbarButton(parent, iconSize, iconPadding, yOffset, settingsParent, returnContainer)
    local cloneSettings = self
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(iconSize, iconSize)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", iconPadding, -yOffset)
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp")

    local texture = button:CreateTexture(nil, "ARTWORK")
    texture:SetAllPoints(button)
    texture:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\multi")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clone Settings", 1, 1, 1)
        GameTooltip:AddLine("Copy selected settings to other tracker values", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    button:SetScript("OnClick", function()
        local targetParent = type(settingsParent) == "function" and settingsParent() or settingsParent
        cloneSettings:Render(targetParent, returnContainer)
    end)

    return button
end

function CloneSettings:Render(parent, returnContainer)
    if not parent then
        return
    end

    if SpellStyler.IconSettingsRenderer then
        SpellStyler.IconSettingsRenderer:HideSelectedIconHeader()
    end

    HideChildren(parent)
    parent.currentControlsContainer = nil

    local trackerEntries = GetTrackerList()
    local selectedSource
    local selectedTemplateName
    local selectedTemplate
    local selectedTargets = {}
    local partialSettings = false
    local partialExpanded = false
    local selectedSections = {}
    local gridButtons = {}

    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -5)
    title:SetText("Clone Settings")
    title:SetTextColor(1, 0.82, 0)

    local subtitle = CreateLabel(parent, "Select a source, then select one or more targets.", nil, { 0.7, 0.7, 0.7 })
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetPoint("RIGHT", parent, "RIGHT", -12, 0)

    local applyButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    applyButton:SetSize(80, 22)
    applyButton:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -5)
    applyButton:SetText("Apply")
    applyButton:SetEnabled(false)

    local clearButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    clearButton:SetSize(105, 22)
    clearButton:SetPoint("LEFT", applyButton, "RIGHT", 8, 0)
    clearButton:SetText("Clear Selection")
    clearButton:SetEnabled(false)
    
    local sourceInstruction = CreateLabel(
        parent,
        "Choose a template, or click an icon below to copy from",
        nil,
        { 0.7, 0.7, 0.7 }
    )
    sourceInstruction:SetPoint("TOPLEFT", applyButton, "BOTTOMLEFT", 0, -8)
    sourceInstruction:SetPoint("RIGHT", parent, "RIGHT", -12, 0)

    local sourceRow = CreateFrame("Frame", nil, parent)
    sourceRow:SetPoint("TOPLEFT", sourceInstruction, "BOTTOMLEFT", 0, -4)
    sourceRow:SetPoint("RIGHT", parent, "RIGHT", -0, 0)
    sourceRow:SetHeight(42)

    local sourceLabel = CreateLabel(sourceRow, "Source:", nil, { 0.9, 0.9, 0.9 })
    sourceLabel:SetPoint("LEFT", sourceRow, "LEFT", 0, 0)

    local sourceIconFrame = CreateFrame("Frame", nil, sourceRow, "BackdropTemplate")
    sourceIconFrame:SetSize(34, 34)
    sourceIconFrame:SetPoint("LEFT", sourceLabel, "RIGHT", 8, 0)
    sourceIconFrame:SetBackdropColor(0, 0, 0, 0)
    sourceIconFrame:SetBackdropBorderColor(0,0,0,0)
    local sourceIcon = sourceIconFrame:CreateTexture(nil, "ARTWORK")
    sourceIcon:SetPoint("TOPLEFT", sourceIconFrame, "TOPLEFT", 2, -2)
    sourceIcon:SetPoint("BOTTOMRIGHT", sourceIconFrame, "BOTTOMRIGHT", -2, 2)

    local sourceName = CreateLabel(sourceRow, "", 90, { 0.8, 0.8, 0.8 })
    sourceName:SetPoint("LEFT", sourceIconFrame, "RIGHT", 6, 0)

    local UpdateSourceDisplay
    local templateDropdown = CreateFrame("Frame", nil, sourceRow, "UIDropDownMenuTemplate")
    templateDropdown:SetPoint("RIGHT", sourceRow, "RIGHT", 0, 0)
    UIDropDownMenu_SetWidth(templateDropdown, 120)
    UIDropDownMenu_SetText(templateDropdown, "Select template")
    local templates = SpellStyler_DB and SpellStyler_DB.trackerTemplates or {}
    local templateNames = {}
    for name in pairs(templates) do
        templateNames[#templateNames + 1] = name
    end
    table.sort(templateNames)
    UIDropDownMenu_Initialize(templateDropdown, function(self, level)
        if #templateNames == 0 then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "No templates available"
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
            return
        end
        for _, name in ipairs(templateNames) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = name
            info.value = name
            info.func = function()
                selectedSource = nil
                selectedTemplateName = name
                selectedTemplate = templates[name]
                selectedTargets = {}
                UIDropDownMenu_SetText(templateDropdown, name)
                CloseDropDownMenus()
                UpdateSourceDisplay()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)


    local settingsSelection = CreateFrame("Frame", nil, parent)
    settingsSelection:SetPoint("TOPLEFT", sourceRow, "BOTTOMLEFT", 0, -8)
    settingsSelection:SetSize(parent:GetWidth(), 22)

    local settingsSelectionTexture = settingsSelection:CreateTexture(nil, "BACKGROUND")
    settingsSelectionTexture:SetAllPoints(settingsSelection)
    settingsSelectionTexture:SetTexture(partialExpanded
        and "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_minus_cropped"
        or "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_plus_cropped")
    local settingsSelectionBtn = CreateFrame("Button", nil, settingsSelection)
    settingsSelectionBtn:SetAllPoints(settingsSelection)


    local copyBarText = settingsSelection:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    copyBarText:SetPoint("LEFT", settingsSelection, "LEFT", 8, 0)
    copyBarText:SetTextColor(0.9, 0.9, 0.9)

    local partialPanel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    partialPanel:SetPoint("TOPLEFT", settingsSelection, "BOTTOMLEFT", 0, 2)
    partialPanel:SetPoint("TOPRIGHT", settingsSelection, "BOTTOMRIGHT", 0, 2)
    partialPanel:SetHeight(190)
    partialPanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    partialPanel:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
    partialPanel:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)

    local gridScroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    gridScroll:SetPoint("TOPLEFT", settingsSelection, "BOTTOMLEFT", 0, -8)
    gridScroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -12, 0)
    local gridChild = CreateFrame("Frame", nil, gridScroll)
    local gridColumns = 8
    local gridGap = 4
    local parentWidth = parent:GetWidth()
    local gridIconSize = math.floor((parentWidth - 12 - ((gridColumns - 1) * gridGap)) / gridColumns)
    local gridColumnWidth = gridIconSize + gridGap
    local gridRowHeight = gridIconSize + gridGap
    gridChild:SetWidth(parentWidth - 12)
    gridScroll:SetScrollChild(gridChild)
    local gridScrollBar = _G[gridScroll:GetName() and (gridScroll:GetName() .. "ScrollBar") or nil] or gridScroll.ScrollBar
    if gridScrollBar then
        gridScrollBar:Hide()
        gridScrollBar.Show = function() end
    end

    local function UpdateApplyState()
        applyButton:SetEnabled((selectedSource ~= nil or selectedTemplate ~= nil) and next(selectedTargets) ~= nil
            and (not partialSettings or next(selectedSections) ~= nil))
    end

    local function UpdateGridButton(key)
        local button = gridButtons[key]
        if not button then
            return
        end
        if selectedSource and key == GetTrackerKey(selectedSource) then
            button:Hide()
            return
        end
        button:Show()
        if selectedTargets[key] then
            button.icon:SetVertexColor(1, 1, 1)
            button.selectionBorder:Show()
        else
            button.icon:SetVertexColor(1, 1, 1)
            button.selectionBorder:Hide()
        end
    end

    UpdateSourceDisplay = function()
        if selectedTemplateName then
            sourceIconFrame:Hide()
            sourceName:SetText(selectedTemplateName)
            templateDropdown:Hide()
            clearButton:SetEnabled(true)
        elseif selectedSource then
            sourceIcon:SetTexture(selectedSource.defaultIconTexturePath)
            sourceIconFrame:Show()
            sourceName:SetText(GetTrackerLabel(selectedSource))
            templateDropdown:Hide()
            clearButton:SetEnabled(true)
        else
            sourceIcon:SetTexture(nil)
            sourceIconFrame:Hide()
            sourceName:SetText("")
            templateDropdown:Show()
            UIDropDownMenu_SetText(templateDropdown, "Select template")
            clearButton:SetEnabled(false)
        end
        for key in pairs(gridButtons) do
            UpdateGridButton(key)
        end
        UpdateApplyState()
    end

    local function SetSourceOrTarget(entry)
        local key = GetTrackerKey(entry)
        if selectedTemplateName or not selectedSource then
            selectedTemplateName = nil
            selectedTemplate = nil
            selectedSource = entry
            selectedTargets = {}
        elseif key ~= GetTrackerKey(selectedSource) then
            if selectedTargets[key] then
                selectedTargets[key] = nil
            else
                selectedTargets[key] = entry
            end
        end
        UpdateSourceDisplay()
    end

    clearButton:SetScript("OnClick", function()
        selectedSource = nil
        selectedTemplateName = nil
        selectedTemplate = nil
        selectedTargets = {}
        UpdateSourceDisplay()
    end)

    local function UpdateCopyBar()
        settingsSelectionTexture:SetTexture(partialExpanded
            and "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_minus_cropped"
            or "Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_plus_cropped")
        copyBarText:SetText("Copy: " .. (partialSettings and "Partial Settings" or "All Settings")
            .. (partialExpanded and "  |cff888888(click to collapse)|r" or "  |cff888888(click to expand)|r"))
        partialPanel:SetShown(partialExpanded)
        if partialExpanded then
            gridScroll:ClearAllPoints()
            gridScroll:SetPoint("TOPLEFT", partialPanel, "BOTTOMLEFT", 0, -8)
            gridScroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -12, 0)
        else
            gridScroll:ClearAllPoints()
            gridScroll:SetPoint("TOPLEFT", settingsSelection, "BOTTOMLEFT", 0, -8)
            gridScroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -12, 0)
        end
        UpdateApplyState()
    end

    settingsSelectionBtn:SetScript("OnClick", function()
        partialExpanded = not partialExpanded
        UpdateCopyBar()
    end)

    for index, section in ipairs(SECTION_DEFINITIONS) do
        local checkbox = CreateFrame("CheckButton", nil, partialPanel, "UICheckButtonTemplate")
        checkbox:SetSize(22, 22)
        checkbox:SetPoint("TOPLEFT", partialPanel, "TOPLEFT", 8, -8 - ((index - 1) * 23))
        local label = CreateLabel(partialPanel, section.label, nil, { 0.85, 0.85, 0.85 })
        label:SetPoint("LEFT", checkbox, "RIGHT", 2, 0)
        checkbox:SetScript("OnClick", function(self)
            if self:GetChecked() then
                selectedSections[index] = true
            else
                selectedSections[index] = nil
            end
            partialSettings = next(selectedSections) ~= nil
            UpdateCopyBar()
        end)
    end

    local groupedEntries = {}
    for _, trackerType in ipairs({ "buffs", "spells", "items" }) do
        local hasTypeEntries = false
        for _, entry in ipairs(trackerEntries) do
            if entry.trackerType == trackerType then
                hasTypeEntries = true
                break
            end
        end
        if hasTypeEntries then
            groupedEntries[#groupedEntries + 1] = {
                isHeader = true,
                label = trackerType == "buffs"
                    and "Auras"
                    or trackerType:sub(1, 1):upper() .. trackerType:sub(2),
            }
            for _, entry in ipairs(trackerEntries) do
                if entry.trackerType == trackerType then
                    groupedEntries[#groupedEntries + 1] = entry
                end
            end
        end
    end

    local gridOffset = 0
    local gridColumn = 0
    for _, entry in ipairs(groupedEntries) do
        if entry.isHeader then
            if gridColumn > 0 then
                gridOffset = gridOffset + gridRowHeight
                gridColumn = 0
            end
            local header = CreateLabel(gridChild, entry.label, gridChild:GetWidth(), { 1, 0.82, 0 })
            header:SetPoint("TOPLEFT", gridChild, "TOPLEFT", 0, -gridOffset)
            gridOffset = gridOffset + 18
        else
            local key = GetTrackerKey(entry)
            local button = CreateFrame("Button", nil, gridChild)
            button:SetSize(gridIconSize, gridIconSize)
            button:SetPoint("TOPLEFT", gridChild, "TOPLEFT", gridColumn * gridColumnWidth, -gridOffset)
            local icon = button:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints(button)
            icon:SetTexture(entry.defaultIconTexturePath)
            button.icon = icon
            local selectionBorder = CreateFrame("Frame", nil, button, "BackdropTemplate")
            selectionBorder:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
            selectionBorder:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
            selectionBorder:SetFrameLevel(button:GetFrameLevel() + 1)
            selectionBorder:EnableMouse(false)
            selectionBorder:SetBackdrop({
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 2,
            })
            selectionBorder:SetBackdropBorderColor(1, 1, 1, 1)
            selectionBorder:Hide()
            button.selectionBorder = selectionBorder
            button:SetScript("OnClick", function()
                SetSourceOrTarget(entry)
            end)
            button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(entry.name or tostring(entry.trackerKey), 1, 1, 1)
                GameTooltip:AddLine(entry.trackerType or "", 0.7, 0.7, 0.7)
                GameTooltip:Show()
            end)
            button:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            gridButtons[key] = button
            gridColumn = gridColumn + 1
            if gridColumn == gridColumns then
                gridColumn = 0
                gridOffset = gridOffset + gridRowHeight
            end
        end
    end
    if gridColumn > 0 then
        gridOffset = gridOffset + gridRowHeight
    end
    gridChild:SetHeight(math.max(gridOffset, 1))

    applyButton:SetScript("OnClick", function()
        if (not selectedSource and not selectedTemplate) or not next(selectedTargets) then
            return
        end

        local state = SpellStyler.State
        if not state then
            return
        end

        local sections
        if partialSettings then
            sections = {}
            for index in pairs(selectedSections) do
                for _, prefix in ipairs(SECTION_DEFINITIONS[index].prefixes) do
                    sections[#sections + 1] = prefix
                end
            end
        end

        local targets = {}
        for _, target in pairs(selectedTargets) do
            targets[#targets + 1] = target
        end
        local source = selectedTemplate
            and { template = selectedTemplate }
            or selectedSource
        if source then
            state:CopySettings(source, sections, targets)
        end
    end)

    sourceIconFrame:Hide()
    partialPanel:Hide()
    settingsSelectionTexture:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_plus_cropped")
    copyBarText:SetText("Copy: All Settings  |cff888888(click to expand)|r")
    local parentScrollFrame = parent:GetParent()
    if parentScrollFrame then
        local availableHeight = parentScrollFrame:GetHeight()
        if availableHeight > 0 then
            parent:SetHeight(availableHeight)
        end
        C_Timer.After(0, function()
            local settledHeight = parentScrollFrame:GetHeight()
            if settledHeight > 0 then
                parent:SetHeight(settledHeight)
            end
        end)
    end
end