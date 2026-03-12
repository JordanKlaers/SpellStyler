-- ContainerSettings.lua
-- Renders the Containers settings view inside the settings menu

local ADDON_NAME, SpellStyler = ...
SpellStyler.ContainerSettingsRenderer = SpellStyler.ContainerSettingsRenderer or {}
local ContainerSettingsRenderer = SpellStyler.ContainerSettingsRenderer

-- ============================================================
-- Shared helpers
-- ============================================================

local ICON_SIZE = 40
local ICON_PAD  = 4

--- Creates a small icon button with tooltip.
local function MakeIconBtn(parent, entry, size)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size, size)
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(btn)
    tex:SetTexture(entry.defaultIconTexturePath)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText((entry.name or tostring(entry.uniqueID)), 1, 1, 1)
        GameTooltip:AddLine(entry.trackerType or "", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

--- Creates a labelled horizontal scroll frame. Returns (label, scrollFrame, scrollChild).
local function MakeHorizRow(parent, anchorFrame, offsetY, labelText)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, offsetY)
    lbl:SetText(labelText)
    lbl:SetTextColor(0.75, 0.75, 0.75)

    local sf = CreateFrame("ScrollFrame", nil, parent)
    sf:SetPoint("TOPLEFT",  lbl, "BOTTOMLEFT", 0, -4)
    sf:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
    sf:SetHeight(ICON_SIZE + ICON_PAD * 2)

    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetHorizontalScroll()
        local max = self:GetHorizontalScrollRange()
        self:SetHorizontalScroll(math.max(0, math.min(max, cur - delta * (ICON_SIZE + ICON_PAD))))
    end)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetHeight(ICON_SIZE + ICON_PAD * 2)
    sc:SetWidth(1)
    sf:SetScrollChild(sc)
    sc._buttons = {}

    return lbl, sf, sc
end

--- Clears all pooled buttons from a scroll child.
local function ClearScrollChild(sc)
    for _, b in ipairs(sc._buttons) do
        b:Hide()
        b:SetParent(nil)
    end
    sc._buttons = {}
end

-- ============================================================
-- RenderContainerView
-- ============================================================

function ContainerSettingsRenderer:RenderContainerView(parentFrame)
    -- Forward declarations so closures below can reference them before actual creation.
    local RefreshIconLists
    local RefreshDropdown
    local RefreshOrientationDropdown
    local contentFrame, noContainerHint

    -- ---- Header row --------------------------------------------------------
    local headerLabel = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    headerLabel:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 12, -16)
    headerLabel:SetText("|cFFFFD700Container:|r")

    local nameDisplay = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameDisplay:SetPoint("LEFT", headerLabel, "RIGHT", 8, 0)
    nameDisplay:SetTextColor(1, 1, 1)

    local function RefreshNameDisplay()
        local name = SpellStyler.Containers:GetActiveName()
        nameDisplay:SetText(name or "|cFF888888(none)|r")
    end

    -- Dropdown
    local dropdown = CreateFrame("Frame", "SpellStylerContainerDropdown", parentFrame, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", headerLabel, "BOTTOMLEFT", -16, -10)
    UIDropDownMenu_SetWidth(dropdown, 120)

    local function InitDropdown(self, level)
        local containers = SpellStyler.Containers:GetDB()
        local names = {}
        for name in pairs(containers) do table.insert(names, name) end
        table.sort(names)
        for _, name in ipairs(names) do
            local info    = UIDropDownMenu_CreateInfo()
            info.text     = name
            info.value    = name
            info.checked  = (name == SpellStyler.Containers:GetActiveName())
            info.func     = function(btn)
                SpellStyler.Containers:SetActiveName(btn.value)
                RefreshDropdown()
            end
            UIDropDownMenu_AddButton(info, level)
        end
        if #names == 0 then
            local info    = UIDropDownMenu_CreateInfo()
            info.text     = "|cFF888888(no containers)|r"
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(dropdown, InitDropdown)

    RefreshDropdown = function()
        local name = SpellStyler.Containers:GetActiveName()
        if name then
            UIDropDownMenu_SetSelectedValue(dropdown, name)
            UIDropDownMenu_SetText(dropdown, name)
            if contentFrame    then contentFrame:Show()    end
            if noContainerHint then noContainerHint:Hide() end
        else
            UIDropDownMenu_SetText(dropdown, "")
            if contentFrame    then contentFrame:Hide()    end
            if noContainerHint then noContainerHint:Show() end
        end
        RefreshNameDisplay()
        if RefreshOrientationDropdown then RefreshOrientationDropdown() end
        if RefreshIconLists then RefreshIconLists() end
    end

    -- Add button
    local addBtn = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate")
    addBtn:SetSize(50, 22)
    addBtn:SetPoint("LEFT", dropdown, "RIGHT", 4, 0)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", function()
        SpellStyler.Containers:Add()
        RefreshDropdown()
    end)

    -- Delete button
    local deleteBtn = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate")
    deleteBtn:SetSize(55, 22)
    deleteBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
    deleteBtn:SetText("Delete")
    deleteBtn:SetScript("OnClick", function()
        SpellStyler.Containers:Delete()
        RefreshDropdown()
    end)

    -- ---- Separator ---------------------------------------------------------
    local sep = parentFrame:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT",  dropdown, "BOTTOMLEFT",  16, -10)
    sep:SetPoint("RIGHT", parentFrame, "RIGHT", -16, 0)

    -- ---- "No container" hint (shown when nothing is selected) ---------------
    noContainerHint = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noContainerHint:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 16, -20)
    noContainerHint:SetText("|cFF888888Select or create a container above.|r")
    noContainerHint:Hide()

    -- ---- Content frame (hidden until a container is selected) ---------------
    contentFrame = CreateFrame("Frame", nil, parentFrame)
    contentFrame:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -8)
    contentFrame:SetPoint("BOTTOMRIGHT", parentFrame, "BOTTOMRIGHT", 0, 0)
    contentFrame:Hide()

    -- Tiny 1px anchor at the top of contentFrame so MakeHorizRow can anchor off it.
    local contentTopAnchor = CreateFrame("Frame", nil, contentFrame)
    contentTopAnchor:SetSize(1, 1)
    contentTopAnchor:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, 0)

    -- ---- Orientation setting -----------------------------------------------
    local orientLabel = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    orientLabel:SetPoint("TOPLEFT", contentTopAnchor, "BOTTOMLEFT", 0, -4)
    orientLabel:SetText("|cFFFFD700Orientation|r")
    orientLabel:SetTextColor(0.75, 0.75, 0.75)

    local orientDropdown = CreateFrame("Frame", "SpellStylerOrientationDropdown", contentFrame, "UIDropDownMenuTemplate")
    orientDropdown:SetPoint("TOPLEFT", orientLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_SetWidth(orientDropdown, 100)

    local function InitOrientDropdown(self, level)
        local config = SpellStyler.Containers:GetActiveConfig()
        local current = (config and config.orientation) or "horizontal"
        for _, opt in ipairs({ "horizontal", "vertical" }) do
            local info   = UIDropDownMenu_CreateInfo()
            info.text    = opt:sub(1,1):upper() .. opt:sub(2)  -- capitalise first letter
            info.value   = opt
            info.checked = (opt == current)
            info.func    = function(btn)
                local cfg = SpellStyler.Containers:GetActiveConfig()
                if cfg then
                    cfg.orientation = btn.value
                    SpellStyler.Containers:LayoutContainer(SpellStyler.Containers:GetActiveName())
                end
                RefreshOrientationDropdown()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(orientDropdown, InitOrientDropdown)

    -- ---- Column / Row limit inputs ----------------------------------------
    local function MakeLimitBox(labelText)
        local lbl = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", orientDropdown, "BOTTOMLEFT", 16, -4)
        lbl:SetText(labelText)
        lbl:SetTextColor(0.75, 0.75, 0.75)
        local box = CreateFrame("EditBox", nil, contentFrame, "InputBoxTemplate")
        box:SetSize(44, 20)
        box:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(4)
        return lbl, box
    end

    local colLimitLbl, colLimitBox = MakeLimitBox("|cFFFFD700Column Limit|r")
    local rowLimitLbl, rowLimitBox = MakeLimitBox("|cFFFFD700Row Limit|r")

    local function SaveLimit(box, field)
        local cfg = SpellStyler.Containers:GetActiveConfig()
        if not cfg then return end
        cfg[field] = tonumber(box:GetText()) or 0
        SpellStyler.Containers:LayoutContainer(SpellStyler.Containers:GetActiveName())
    end

    colLimitBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() SaveLimit(self, "columnLimit") end)
    colLimitBox:SetScript("OnEditFocusLost", function(self) SaveLimit(self, "columnLimit") end)
    rowLimitBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() SaveLimit(self, "rowLimit") end)
    rowLimitBox:SetScript("OnEditFocusLost", function(self) SaveLimit(self, "rowLimit") end)

    -- ---- Alignment dropdown -----------------------------------------------
    local ALIGN_OPTIONS = {
        horizontal = { "left", "center", "right" },
        vertical   = { "top",  "center", "bottom" },
    }

    local alignLabel = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    alignLabel:SetPoint("TOPLEFT", orientDropdown, "BOTTOMLEFT", 16, -34)
    alignLabel:SetText("|cFFFFD700Alignment|r")
    alignLabel:SetTextColor(0.75, 0.75, 0.75)

    local alignDropdown = CreateFrame("Frame", "SpellStylerAlignDropdown", contentFrame, "UIDropDownMenuTemplate")
    alignDropdown:SetPoint("TOPLEFT", alignLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_SetWidth(alignDropdown, 100)

    local RefreshAlignmentDropdown  -- forward declare

    local function InitAlignDropdown(self, level)
        local config  = SpellStyler.Containers:GetActiveConfig()
        local orient  = (config and config.orientation) or "horizontal"
        local current = (config and config.alignment)   or ALIGN_OPTIONS[orient][1]
        for _, opt in ipairs(ALIGN_OPTIONS[orient]) do
            local info   = UIDropDownMenu_CreateInfo()
            info.text    = opt:sub(1,1):upper() .. opt:sub(2)
            info.value   = opt
            info.checked = (opt == current)
            info.func    = function(btn)
                local cfg = SpellStyler.Containers:GetActiveConfig()
                if cfg then
                    cfg.alignment = btn.value
                    SpellStyler.Containers:LayoutContainer(SpellStyler.Containers:GetActiveName())
                end
                if RefreshAlignmentDropdown then RefreshAlignmentDropdown() end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(alignDropdown, InitAlignDropdown)

    RefreshAlignmentDropdown = function()
        local config  = SpellStyler.Containers:GetActiveConfig()
        local orient  = (config and config.orientation) or "horizontal"
        local current = (config and config.alignment)   or ALIGN_OPTIONS[orient][1]
        -- Reset alignment if it's invalid for the current orientation
        local valid = false
        for _, v in ipairs(ALIGN_OPTIONS[orient]) do
            if v == current then valid = true break end
        end
        if not valid then
            current = ALIGN_OPTIONS[orient][1]
            if config then config.alignment = current end
        end
        UIDropDownMenu_SetSelectedValue(alignDropdown, current)
        UIDropDownMenu_SetText(alignDropdown, current:sub(1,1):upper() .. current:sub(2))
        CloseDropDownMenus()  -- force re-init on next open so options match orientation
    end

    -- Forward declared so RefreshOrientationDropdown can reference them before they are created.
    local iconWidthBox, iconHeightBox

    -- RefreshOrientationDropdown defined here so it closes over limit boxes + align dropdown
    RefreshOrientationDropdown = function()
        local config  = SpellStyler.Containers:GetActiveConfig()
        local current = (config and config.orientation) or "horizontal"
        UIDropDownMenu_SetSelectedValue(orientDropdown, current)
        UIDropDownMenu_SetText(orientDropdown, current:sub(1,1):upper() .. current:sub(2))

        local isHoriz = (current == "horizontal")
        colLimitLbl:SetShown(isHoriz)
        colLimitBox:SetShown(isHoriz)
        rowLimitLbl:SetShown(not isHoriz)
        rowLimitBox:SetShown(not isHoriz)

        if config then
            colLimitBox:SetText(tostring(config.columnLimit or 0))
            rowLimitBox:SetText(tostring(config.rowLimit    or 0))
        else
            colLimitBox:SetText("0")
            rowLimitBox:SetText("0")
        end

        -- Populate icon size inputs
        if iconWidthBox and iconHeightBox then
            if config then
                iconWidthBox:SetText(tostring(config.iconWidth  or 48))
                iconHeightBox:SetText(tostring(config.iconHeight or 48))
            else
                iconWidthBox:SetText("48")
                iconHeightBox:SetText("48")
            end
        end

        RefreshAlignmentDropdown()
    end

    -- ---- Icon Width / Height inputs ----------------------------------------
    local iconSizeLabel = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    iconSizeLabel:SetPoint("TOPLEFT", alignDropdown, "BOTTOMLEFT", 16, -4)
    iconSizeLabel:SetText("|cFFFFD700Icon Size|r")
    iconSizeLabel:SetTextColor(0.75, 0.75, 0.75)

    local iconWidthLbl = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    iconWidthLbl:SetPoint("TOPLEFT", iconSizeLabel, "BOTTOMLEFT", 0, -4)
    iconWidthLbl:SetText("Width:")
    iconWidthLbl:SetTextColor(0.75, 0.75, 0.75)

    iconWidthBox = CreateFrame("EditBox", nil, contentFrame, "InputBoxTemplate")
    iconWidthBox:SetSize(44, 20)
    iconWidthBox:SetPoint("LEFT", iconWidthLbl, "RIGHT", 6, 0)
    iconWidthBox:SetAutoFocus(false)
    iconWidthBox:SetNumeric(true)
    iconWidthBox:SetMaxLetters(4)

    local iconHeightLbl = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    iconHeightLbl:SetPoint("LEFT", iconWidthBox, "RIGHT", 12, 0)
    iconHeightLbl:SetText("Height:")
    iconHeightLbl:SetTextColor(0.75, 0.75, 0.75)

    iconHeightBox = CreateFrame("EditBox", nil, contentFrame, "InputBoxTemplate")
    iconHeightBox:SetSize(44, 20)
    iconHeightBox:SetPoint("LEFT", iconHeightLbl, "RIGHT", 6, 0)
    iconHeightBox:SetAutoFocus(false)
    iconHeightBox:SetNumeric(true)
    iconHeightBox:SetMaxLetters(4)

    local function SaveIconSize(box, field)
        local cfg = SpellStyler.Containers:GetActiveConfig()
        if not cfg then return end
        local val = tonumber(box:GetText()) or 48
        cfg[field] = math.max(8, val)
        SpellStyler.Containers:LayoutContainer(SpellStyler.Containers:GetActiveName())
    end

    iconWidthBox:SetScript("OnEnterPressed",  function(self) self:ClearFocus() SaveIconSize(self, "iconWidth")  end)
    iconWidthBox:SetScript("OnEditFocusLost", function(self) SaveIconSize(self, "iconWidth")  end)
    iconHeightBox:SetScript("OnEnterPressed",  function(self) self:ClearFocus() SaveIconSize(self, "iconHeight") end)
    iconHeightBox:SetScript("OnEditFocusLost", function(self) SaveIconSize(self, "iconHeight") end)

    -- Separator between settings and icon lists
    local orientSep = contentFrame:CreateTexture(nil, "ARTWORK")
    orientSep:SetColorTexture(0.4, 0.4, 0.4, 0.4)
    orientSep:SetHeight(1)
    orientSep:SetPoint("TOPLEFT",  iconWidthLbl, "BOTTOMLEFT",  0, -8)
    orientSep:SetPoint("RIGHT", contentFrame, "RIGHT", -16, 0)

    -- ---- Icon lists --------------------------------------------------------
    -- Row 1: all tracked icons
    local allLabel, allSF, allSC = MakeHorizRow(contentFrame, orientSep, -6,
        "|cFFFFD700All Tracked Icons|r  |cFF888888(click or drag to add)|r")

    -- Row 2: icons in this container
    local contLabel, contSF, contSC = MakeHorizRow(contentFrame, allSF, -14,
        "|cFFFFD700Container Icons|r  |cFF888888(click or drag to remove)|r")

    -- ---- Drag-and-drop infrastructure --------------------------------------
    -- Ghost frame that follows the cursor while dragging
    local ghostFrame = CreateFrame("Frame", nil, UIParent)
    ghostFrame:SetSize(ICON_SIZE, ICON_SIZE)
    ghostFrame:SetFrameStrata("TOOLTIP")
    local ghostTex = ghostFrame:CreateTexture(nil, "ARTWORK")
    ghostTex:SetAllPoints()
    ghostFrame.tex = ghostTex
    ghostFrame:Hide()

    -- Highlight overlays shown on the drop-target row during a drag
    local function MakeRowHL(sf)
        local hl = CreateFrame("Frame", nil, sf, "BackdropTemplate")
        hl:SetAllPoints(sf)
        hl:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        hl:SetBackdropColor(1, 0.85, 0, 0.10)
        hl:SetFrameLevel(sf:GetFrameLevel() + 1)
        hl:Hide()
        return hl
    end
    local allHL  = MakeRowHL(allSF)
    local contHL = MakeRowHL(contSF)

    local DRAG_THRESHOLD = 2   -- pixels before a mousedown is treated as a drag

    --- Wire drag + click onto a button.
    -- targetSF  : the ScrollFrame that is the valid drop zone
    -- targetHL  : the highlight overlay for that row
    -- onAction  : function() called on both click and successful drag-drop
    local function SetupDragDrop(btn, entry, targetSF, targetHL, onAction)
        local startX, startY, isDrag = 0, 0, false

        btn:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" then return end
            startX, startY = GetCursorPosition()
            isDrag = false
            ghostFrame.tex:SetTexture(entry.defaultIconTexturePath)
            -- position ghost immediately so it doesn't jump
            local scale = UIParent:GetEffectiveScale()
            ghostFrame:ClearAllPoints()
            ghostFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX / scale, startY / scale)
            ghostFrame:Show()
            ghostFrame:SetScript("OnUpdate", function()
                local cx, cy = GetCursorPosition()
                local sc2 = UIParent:GetEffectiveScale()
                ghostFrame:ClearAllPoints()
                ghostFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / sc2, cy / sc2)
                if not isDrag then
                    local dx, dy = cx - startX, cy - startY
                    if dx * dx + dy * dy > DRAG_THRESHOLD * DRAG_THRESHOLD then
                        isDrag = true
                    end
                end
                -- Highlight drop target when dragging
                if isDrag then
                    targetHL:SetShown(targetSF:IsMouseOver())
                end
            end)
        end)

        btn:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            ghostFrame:Hide()
            ghostFrame:SetScript("OnUpdate", nil)
            targetHL:Hide()
            GameTooltip:Hide()

            if isDrag then
                -- Drag path: only act if dropped on the target row
                if targetSF:IsMouseOver() then
                    onAction()
                end
            else
                -- Click path: always act
                onAction()
            end
        end)
    end

    -- Refresh both horizontal rows to reflect current state.
    RefreshIconLists = function()
        local FTM = SpellStyler.FrameTrackerManager
        if not FTM then return end

        local config = SpellStyler.Containers:GetActiveConfig()
        local inContainer = {}
        if config and config.associatedIcons then
            for _, uid in ipairs(config.associatedIcons) do inContainer[uid] = true end
        end

        local trackerList = FTM:getTrackerValuesListForSettings()

        -- ---- Row 1: all icons --------------------------------------------------
        ClearScrollChild(allSC)
        local x = ICON_PAD
        for _, entry in ipairs(trackerList) do
            local btn = MakeIconBtn(allSC, entry, ICON_SIZE)
            btn:SetPoint("TOPLEFT", allSC, "TOPLEFT", x, -ICON_PAD)
            if inContainer[entry.uniqueID] then
                -- Already in container — dimmed, not interactive
                btn:SetAlpha(0.3)
            else
                btn:SetAlpha(1.0)
                local capturedEntry = entry
                SetupDragDrop(btn, capturedEntry, contSF, contHL, function()
                    if not config then return end
                    table.insert(config.associatedIcons, capturedEntry.uniqueID)
                    RefreshIconLists()
                    SpellStyler.Containers:LayoutContainer(SpellStyler.Containers:GetActiveName())
                    -- LayoutContainer marks the frame _inContainer; re-sync drag state
                    if FTM and FTM.EnableDraggingForAllFrames then
                        FTM:EnableDraggingForAllFrames()
                    end
                end)
            end
            table.insert(allSC._buttons, btn)
            x = x + ICON_SIZE + ICON_PAD
        end
        allSC:SetWidth(math.max(x, 1))

        -- ---- Row 2: container icons --------------------------------------------
        ClearScrollChild(contSC)
        x = ICON_PAD
        if config and config.associatedIcons then
            local entryByID = {}
            for _, e in ipairs(trackerList) do entryByID[e.uniqueID] = e end

            for idx, uid in ipairs(config.associatedIcons) do
                local entry = entryByID[uid]
                if entry then
                    local btn = MakeIconBtn(contSC, entry, ICON_SIZE)
                    btn:SetPoint("TOPLEFT", contSC, "TOPLEFT", x, -ICON_PAD)
                    local capturedIdx = idx
                    local capturedEntry = entry
                    SetupDragDrop(btn, capturedEntry, allSF, allHL, function()
                        if not config then return end
                        SpellStyler.Containers:DetachIconsFromContainer({ capturedEntry.uniqueID })
                        table.remove(config.associatedIcons, capturedIdx)
                        RefreshIconLists()
                        SpellStyler.Containers:LayoutContainer(SpellStyler.Containers:GetActiveName())
                    end)
                    table.insert(contSC._buttons, btn)
                    x = x + ICON_SIZE + ICON_PAD
                end
            end
        end
        contSC:SetWidth(math.max(x, 1))
    end

    -- ---- Initial state -----------------------------------------------------
    RefreshDropdown()

    -- Re-sync when the view is shown
    parentFrame:HookScript("OnShow", function()
        RefreshDropdown()
    end)
end
