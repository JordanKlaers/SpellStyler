local ADDON_NAME, SpellStyler = ...
SpellStyler.AddSpells = SpellStyler.AddSpells or {}
local AddSpells = SpellStyler.AddSpells

local PLUS_ICON_PATH = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\PlusIcon"

-- ============================================================================
-- Spell data gathering
-- ============================================================================

--- Scans the player spellbook and returns a flat list of spells that belong to
--- the current spec or to the General tab (_specID == "none").
--- Each entry: { spellID, name, iconID, isPassive }
function AddSpells:GetCurrentSpecSpells()
    local currentSpecID = SpellStyler.State and SpellStyler.State.GetCurrentSpecID
        and SpellStyler.State:GetCurrentSpecID()

    local spells = {}
    local seen = {}   -- deduplicate by spellID

    local numLines = C_SpellBook.GetNumSpellBookSkillLines()
    for i = 1, numLines do
        local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(i)
        if lineInfo and not lineInfo.isGuild then
            local specID = lineInfo.specID  -- nil for General, number for spec tabs
            local isGeneral  = (specID == nil)
            local isCurrentSpec = currentSpecID and (specID == currentSpecID)

            if isGeneral or isCurrentSpec then
                local offset = lineInfo.itemIndexOffset
                local count  = lineInfo.numSpellBookItems
                for j = offset + 1, offset + count do
                    local info = C_SpellBook.GetSpellBookItemInfo(j, Enum.SpellBookSpellBank.Player)
					local donk = C_SpellBook.GetSpellBookItemLevelLearned(j, Enum.SpellBookSpellBank.Player)
                    if info
                        and not info.isOffSpec
                        and info.itemType == Enum.SpellBookItemType.Spell then
                        local sid = info.spellID or info.actionID
                        if sid and not seen[sid] then
                            seen[sid] = true
                            -- Use C_Spell.GetSpellInfo for authoritative icon/name
                            local si = C_Spell.GetSpellInfo(sid)
                            if si then
                                local cooldownMS = GetSpellBaseCooldown(sid)
                                if cooldownMS and cooldownMS > 0 then
                                    table.insert(spells, {
                                        spellID   = sid,
                                        name      = si.name,
                                        iconID    = si.iconID,
                                        isPassive = info.isPassive,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return spells
end

--- Scans the player's bags and equipped items, returning a flat list of usable items
--- with cooldowns. Each entry: { itemID, name, iconID, isEquipped }
function AddSpells:GetPlayerItems()
    local items = {}
    local seen = {}  -- deduplicate by itemID
    
    -- Helper to check if item has an actual cooldown when used
    local function itemHasCooldown(itemID)
        -- Check if item has a spell (on-use effect)
        local spellName, spellID = C_Item.GetItemSpell(itemID)
        if not spellID then
            return false  -- No on-use effect
        end
        -- Check if the spell has a cooldown
        local cooldownMS = GetSpellBaseCooldown(spellID)
        if cooldownMS and cooldownMS > 1500 then  -- More than 1.5s GCD
            return true
        end
        
        -- Also check current cooldown state (catches items currently on cooldown)
        local start, duration = C_Container.GetItemCooldown(itemID)
        if duration and duration > 1.5 then  -- Active cooldown greater than GCD
            return true
        end
        
        return false
    end
    
    -- Scan equipped items (inventory slots 1-19)
    for slotID = 1, 19 do
        local itemID = GetInventoryItemID("player", slotID)
        if itemID and not seen[itemID] then
            -- Use C_Item.GetItemIconByID for icon (modern API)
            local itemIcon = C_Item.GetItemIconByID(itemID)
            local itemName = C_Item.GetItemNameByID(itemID)
            
            -- Only include if item is usable and has a real cooldown
            local isUsable = C_Item.IsUsableItem(itemID)
            local hasCooldown = itemHasCooldown(itemID)
            
            if itemName and itemIcon and isUsable and hasCooldown then
                seen[itemID] = true
                table.insert(items, {
                    itemID = itemID,
                    name = itemName,
                    iconID = itemIcon,
                    isEquipped = true,
                })
            end
        end
    end
    
    -- Scan bags (0 = backpack, 1-4 = bag slots)
    for bagID = 0, 6 do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if numSlots then
            for slotID = 1, numSlots do
                local itemInfo = C_Container.GetContainerItemInfo(bagID, slotID)
                if itemInfo and itemInfo.itemID then
                    local itemID = itemInfo.itemID
                    if not seen[itemID] then
                        local itemName = itemInfo.itemName
                        local itemIcon = itemInfo.iconFileID
                        
                        -- Get additional info if needed using modern API
                        if not itemName then
                            itemName = C_Item.GetItemNameByID(itemID)
                        end
                        if not itemIcon then
                            itemIcon = C_Item.GetItemIconByID(itemID)
                        end
                        
                        -- Only include if item is usable and has a real cooldown
                        local isUsable = C_Item.IsUsableItem(itemID)
                        local hasCooldown = itemHasCooldown(itemID)
                        
                        if itemName and itemIcon and isUsable and hasCooldown then
                            seen[itemID] = true
                            table.insert(items, {
                                itemID = itemID,
                                name = itemName,
                                iconID = itemIcon,
                                isEquipped = false,
                            })
                        end
                    end
                end
            end
        end
    end
    return items
end

-- ============================================================================
-- Plus button (icon column entry)
-- ============================================================================

--- Creates and returns the plus icon button to be placed in the icon scroll child.
--- Caller is responsible for SetPoint positioning.
function AddSpells:CreatePlusButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(40, 40)
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(btn)
    tex:SetTexture(PLUS_ICON_PATH)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Add Spell", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp")
    return btn
end

-- ============================================================================
-- Add Spells view (right panel)
-- ============================================================================

local ICON_SIZE   = 36
local ICON_PAD    = 4
local ICONS_PER_ROW = 6

--- Renders the "Add Spell" view into the given parent panel.
--- Follows the same clear-and-rebuild pattern as RenderConfigControlsForSpecificIcon.
function AddSpells:RenderAddSpellsView(parent)
    if not parent then return end

    -- Clear all old controls from scroll child
    -- Collect all children and regions first to avoid iteration issues during removal
    local childrenToRemove = {}
    for _, child in ipairs({parent:GetChildren()}) do
        table.insert(childrenToRemove, child)
    end
    
    local regionsToRemove = {}
    for _, region in ipairs({parent:GetRegions()}) do
        if region:IsObjectType("FontString") or region:IsObjectType("Texture") then
            table.insert(regionsToRemove, region)
        end
    end
    
    -- Now remove all children
    for _, child in ipairs(childrenToRemove) do
        child:Hide()
        child:SetParent(nil)
    end
    
    -- And clear all regions
    for _, region in ipairs(regionsToRemove) do
        region:Hide()
        if region:IsObjectType("FontString") then
            region:SetText("")
        end
    end
    
    parent.currentControlsContainer = nil

    local container = CreateFrame("Frame", nil, parent)
    container:SetAllPoints()
    container:EnableMouse(true)
    parent.currentControlsContainer = container

    -- ── Selection state ────────────────────────────────────────────────
    local selectedSpell = nil
    local selectedBtn   = nil
    local addBtn        = nil  -- forward-declared so closures can reference it
    -- Forward-declared so the addBtn OnClick closure can reference them
    -- (Lua closures only capture locals that are in scope at definition time)
    local gridSF
    local gridButtons
    local lastFilter = ""
    local FilterAndLayoutSafe

    local function Deselect()
        if selectedBtn and SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:StopAnts(selectedBtn)
        end
        selectedSpell = nil
        selectedBtn   = nil
        if addBtn then addBtn:Disable() end
    end

    local function SelectSpell(spell, btn)
        -- deselect old
        if selectedBtn and SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:StopAnts(selectedBtn)
        end
        selectedSpell = spell
        selectedBtn   = btn
        if SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:SetupAnts(btn, { r = 1, g = 0.82, b = 0 })
            SpellStyler.GlowUtil:PlayAnts(btn)
        end
        if addBtn then addBtn:Enable() end
    end

    -- clicking empty space deselects
    container:SetScript("OnMouseDown", function() Deselect() end)

    -- ── Static header UI ───────────────────────────────────────────────
    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -16)
    title:SetText("|cFFFFD700Add Spell|r")

    local subtitle = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Showing class spells and items with cooldowns.")
    subtitle:SetTextColor(0.7, 0.7, 0.7)

    -- Search / spell-ID input
    local PREVIEW_SIZE = 30
    local editBox = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
    editBox:SetSize(160, 22)
    editBox:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -14)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(100)

    -- Lookup preview icon (right of editBox, hidden until a match is found)
    local previewBtn = CreateFrame("Button", nil, container)
    previewBtn:SetSize(PREVIEW_SIZE, PREVIEW_SIZE)
    previewBtn:SetPoint("LEFT", editBox, "RIGHT", 8, 0)
    previewBtn:EnableMouse(true)
    previewBtn:RegisterForClicks("LeftButtonUp")
    previewBtn:Hide()

    local previewTex = previewBtn:CreateTexture(nil, "ARTWORK")
    previewTex:SetAllPoints()
    previewTex:SetTexCoord(0, 1, 0, 1)
    local previewHL = previewBtn:CreateTexture(nil, "HIGHLIGHT")
    previewHL:SetAllPoints()
    previewHL:SetColorTexture(1, 1, 1, 0.25)

    local previewSpell = nil  -- current spell shown in previewBtn

    previewBtn:SetScript("OnEnter", function(self)
        if previewSpell then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(previewSpell.spellID)
            GameTooltip:Show()
        end
    end)
    previewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    previewBtn:SetScript("OnClick", function(self)
        if previewSpell then SelectSpell(previewSpell, self) end
    end)

    -- Add button (disabled until a spell is selected)
    addBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 22)
    addBtn:SetPoint("LEFT", previewBtn, "RIGHT", 8, (PREVIEW_SIZE - 22) / 2)
    addBtn:SetText("Add")
    addBtn:Disable()
    addBtn:SetScript("OnClick", function()
        if not selectedSpell then return end
        local FTM   = SpellStyler.FrameTrackerManager
        local State = SpellStyler.State
        
        -- Determine if selected item is a spell or an item
        local isItem = selectedSpell.itemID ~= nil
        local trackingID, trackerConfig
        local trackerConfig

        if isItem then
            -- Get the spell ID from the item (for event tracking and cooldown)
            local spellName, spellID = C_Item.GetItemSpell(selectedSpell.itemID)
            local existingTrackerConfig = SpellStyler.State:GetSpecificTrackerValue(spellID, "items")
            if existingTrackerConfig then
                trackerConfig = existingTrackerConfig
                SpellStyler.State:SetTrackerValueConfigProperty(spellID, "items", 'isEnabled', true)
            else
                -- Track item by spellID as the database key
                trackingID = spellID
                
                -- Get the item icon texture path directly
                local iconTexture = C_Item.GetItemIconByID(selectedSpell.itemID)
                
                trackerConfig = State:AddTrackerValue({
                    itemID                  = selectedSpell.itemID,       -- Store actual itemID
                    baseSpellID             = spellID,                    -- Use spellID as the key
                    overrideSpellID         = spellID,                    -- Also use spellID for activeSpellID
                    trackerType             = "items",                    -- Use dedicated "items" tracker type
                    name                    = selectedSpell.name,
                    defaultIconTexturePath  = iconTexture,                -- Store actual texture path, not itemID
                    isItem                  = true,                       -- Flag to identify this as an item tracker
                })
            end
        else
            trackingID = C_Spell.GetBaseSpell(selectedSpell.spellID)
            local existingTrackerConfig = SpellStyler.State:GetSpecificTrackerValue(trackingID, "spells")
            if existingTrackerConfig then
                trackerConfig = existingTrackerConfig
                SpellStyler.State:SetTrackerValueConfigProperty(trackingID, "spells", 'isEnabled', true)
            else
                -- Track spell by baseSpellID
                local overrideSpellID = C_Spell.GetOverrideSpell(selectedSpell.spellID)
                -- Get icon from override spell for correct initial appearance
                local overrideSpellInfo = C_Spell.GetSpellInfo(overrideSpellID)
                local iconTexture = (overrideSpellInfo and overrideSpellInfo.iconID) or selectedSpell.iconID
                trackerConfig = State:AddTrackerValue({
                    baseSpellID             = trackingID,
                    overrideSpellID         = overrideSpellID,
                    trackerType             = "spells",
                    name                    = selectedSpell.name,
                    defaultIconTexturePath  = iconTexture,
                })
            end
        end
        
        if not trackerConfig then return end

        -- Wipe devNotes before creating frame (fresh start for error tracking)
        local trackerType = isItem and "items" or "spells"
        SpellStyler.State:SetTrackerValueConfigProperty(trackingID, trackerType, "devNotes", {})
        
        -- CreateFrameMiddleware creates base frame, variant frame (if needed),
        -- sets up charge infrastructure, and drives updates
        FTM:CreateCompleteFrame(trackingID, trackerConfig, trackerType)

        -- Remove from the grid so it can't be added twice
        local addedID = isItem and selectedSpell.itemID or selectedSpell.spellID
        for i = #gridButtons, 1, -1 do
            local entryID = gridButtons[i].type == "item" 
                and gridButtons[i].data.itemID 
                or gridButtons[i].data.spellID
            if entryID == addedID then
                gridButtons[i].btn:Hide()
                table.remove(gridButtons, i)
            end
        end
        FilterAndLayoutSafe(lastFilter, gridSF:GetWidth())

        -- Clear selection
        Deselect()

        -- Refresh the icon list in the settings panel so the new spell/item appears
        if SpellStyler.settingsContentFrame then
            SpellStyler.IconSettingsRenderer:RenderIconControlView(SpellStyler.settingsContentFrame)
            local ISR = SpellStyler.IconSettingsRenderer
            if ISR and ISR.EnableDraggingForAllFrames then
                ISR:EnableDraggingForAllFrames()
            end
        end
    end)

    -- ESC: clear search text first, then deselect on second press
    editBox:SetScript("OnEscapePressed", function(self)
        if self:GetText() ~= "" then
            self:SetText("")
        else
            Deselect()
        end
        self:ClearFocus()
    end)

    -- ── Separator ──────────────────────────────────────────────────────
    local sep = container:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", editBox, "BOTTOMLEFT", -2, -10)
    sep:SetPoint("RIGHT",   container, "RIGHT", -12, 0)

    -- ── Grid scroll frame ──────────────────────────────────────────────
    local ICONS_PER_ROW_GRID = 6
    local GRID_GAP = 5
    -- Extra space so the ScrollFrame clip boundary doesn't cut the glow ring
    local GLOW_PAD = 16

    gridSF = CreateFrame("ScrollFrame", nil, container)
    -- Extend left and up by GLOW_PAD; icons are offset to compensate below
    gridSF:SetPoint("TOPLEFT",  sep, "BOTTOMLEFT",  -GLOW_PAD,  -(8 + GLOW_PAD))
    gridSF:SetPoint("TOPRIGHT", sep, "BOTTOMRIGHT",  4,          -(8 + GLOW_PAD))
    gridSF:SetPoint("BOTTOM",   container, "BOTTOM",  0,           8)

    local gridChild = CreateFrame("Frame", nil, gridSF)
    gridSF:SetScrollChild(gridChild)
    
    -- Reset scroll position and enable scrolling
    gridSF:SetVerticalScroll(0)
    gridSF:EnableMouseWheel(true)

    -- ── Build buttons for every spell and item ────────────────────────
    local spells = AddSpells:GetCurrentSpecSpells()
    local items = AddSpells:GetPlayerItems()
    -- Each entry: { btn = Frame, data = spellEntry or itemEntry, type = "spell" or "item" }
    gridButtons = {}

    local State = SpellStyler.State
    
    -- Helper function to check if spell/item is tracked and enabled
    local function isTrackedAndEnabled(spellID, trackerType)
        if not State:CheckIsAlreadyTracker(spellID, trackerType) then
            return false
        end
        local config = State:GetSpecificTrackerValue(spellID, trackerType)
        return config and config.isEnabled ~= false
    end
    
    -- Add spells
    for _, spell in ipairs(spells) do
        -- Skip spells that are already tracked AND enabled in any tracker type.
        -- DB entries are keyed by GetBaseSpell(), so the duplicate check must use
        -- the same key; using the raw spellbook ID would miss override spells.
        local baseID = C_Spell.GetBaseSpell(spell.spellID)
        
        local alreadyTrackedAndEnabled = isTrackedAndEnabled(baseID, "buffs")
            or isTrackedAndEnabled(baseID, "essential")
            or isTrackedAndEnabled(baseID, "utility")
            or isTrackedAndEnabled(baseID, "spells")
        
        if not alreadyTrackedAndEnabled then
            local capturedSpell = spell
            local btn = CreateFrame("Button", nil, gridChild)
            btn:EnableMouse(true)
            btn:RegisterForClicks("LeftButtonUp")

            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            tex:SetTexture(spell.iconID)
            tex:SetTexCoord(0, 1, 0, 1)

            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.25)

            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetSpellByID(capturedSpell.spellID)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            btn:SetScript("OnClick", function(self)
                SelectSpell(capturedSpell, self)
            end)

            table.insert(gridButtons, { btn = btn, data = capturedSpell, type = "spell" })
        end
    end
    
    -- Add items
    for _, item in ipairs(items) do
        -- Get spell ID from item for tracking
        local spellName, spellID = C_Item.GetItemSpell(item.itemID)
        
        -- Check if item is already tracked (items use spellID as the key with "items" tracker type)
        local alreadyTrackedAndEnabled = spellID and isTrackedAndEnabled(spellID, "items")
        
        if not alreadyTrackedAndEnabled or true then
            local capturedItem = item
            local btn = CreateFrame("Button", nil, gridChild)
            btn:EnableMouse(true)
            btn:RegisterForClicks("LeftButtonUp")

            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            tex:SetTexture(item.iconID)
            tex:SetTexCoord(0, 1, 0, 1)

            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.25)

            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(capturedItem.itemID)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            btn:SetScript("OnClick", function(self)
                SelectSpell(capturedItem, self)
            end)

            table.insert(gridButtons, { btn = btn, data = capturedItem, type = "item" })
        end
    end

    -- ── Layout / search filter ─────────────────────────────────────────
    local currentIconSize = 36
    -- (lastFilter and FilterAndLayoutSafe are forward-declared above)

    FilterAndLayoutSafe = function(filterText, availableWidth)
        filterText     = filterText or ""
        availableWidth = availableWidth or gridSF:GetWidth()
        lastFilter     = filterText

        -- availableWidth is the full SF width (includes GLOW_PAD on the left);
        -- subtract GLOW_PAD so icon sizing matches the original visual width.
        local iconWidth = availableWidth - GLOW_PAD
        local lower = filterText:lower()
        local col, row = 0, 0
        local iconSize = math.floor(
            (iconWidth - (ICONS_PER_ROW_GRID - 1) * GRID_GAP) / ICONS_PER_ROW_GRID
        )
        if iconSize < 1 then return end
        currentIconSize = iconSize
        gridChild:SetWidth(availableWidth)

        local spellCount = 0
        local itemCount = 0
        
        -- First pass: layout spells
        for _, entry in ipairs(gridButtons) do
            if entry.type == "spell" then
                local btn = entry.btn
                local matches = (filterText == "")
                    or entry.data.name:lower():find(lower, 1, true)
                if matches then
                    btn:SetSize(iconSize, iconSize)
                    btn:ClearAllPoints()
                    btn:SetPoint("TOPLEFT", gridChild, "TOPLEFT",
                        GLOW_PAD + col * (iconSize + GRID_GAP),
                        -(GLOW_PAD + row * (iconSize + GRID_GAP))
                    )
                    btn:Show()
                    col = col + 1
                    if col >= ICONS_PER_ROW_GRID then col = 0; row = row + 1 end
                    spellCount = spellCount + 1
                else
                    btn:Hide()
                end
            end
        end
        
        -- Add gap between spells and items (skip to next row + add extra spacing)
        if spellCount > 0 and col > 0 then
            col = 0
            row = row + 1
        end
        local gapRows = 0.5  -- Half row gap
        if spellCount > 0 then
            row = row + gapRows
        end
        
        -- Second pass: layout items
        for _, entry in ipairs(gridButtons) do
            if entry.type == "item" then
                local btn = entry.btn
                local matches = (filterText == "")
                    or entry.data.name:lower():find(lower, 1, true)
                if matches then
                    btn:SetSize(iconSize, iconSize)
                    btn:ClearAllPoints()
                    btn:SetPoint("TOPLEFT", gridChild, "TOPLEFT",
                        GLOW_PAD + col * (iconSize + GRID_GAP),
                        -(GLOW_PAD + row * (iconSize + GRID_GAP))
                    )
                    btn:Show()
                    col = col + 1
                    if col >= ICONS_PER_ROW_GRID then col = 0; row = row + 1 end
                    itemCount = itemCount + 1
                else
                    btn:Hide()
                end
            end
        end

        local totalCount = spellCount + itemCount
        local totalRows = math.ceil(row) + (col > 0 and 1 or 0)
        gridChild:SetHeight(math.max(GLOW_PAD + totalRows * (iconSize + GRID_GAP) + 20, 1))
    end

    -- ── Lookup icon update (direct spell-ID/item-ID or name lookup) ──────
    local function UpdateLookupIcon(text)
        if not text or text == "" then
            previewBtn:Hide()
            previewSpell = nil
            -- stop glow if previewBtn was selected
            if selectedBtn == previewBtn then Deselect() end
            return
        end
        
        local id = tonumber(text)
        local foundSpell, foundItem = false, false
        
        -- Try spell lookup first
        if id then
            local si = C_Spell.GetSpellInfo(id)
            if si then
                previewSpell = { spellID = id, name = si.name, iconID = si.iconID }
                foundSpell = true
            end
        else
            -- Try spell name lookup
            local si = C_Spell.GetSpellInfo(text)
            if si then
                previewSpell = { spellID = si.spellID, name = si.name, iconID = si.iconID }
                foundSpell = true
            end
        end
        
        -- If spell not found, try item lookup
        if not foundSpell and id then
            local itemName = C_Item.GetItemNameByID(id)
            local itemIcon = C_Item.GetItemIconByID(id)
            
            if itemName and itemIcon then
                previewSpell = { itemID = id, name = itemName, iconID = itemIcon }
                foundItem = true
            end
        end
        
        if foundSpell or foundItem then
            previewTex:SetTexture(previewSpell.iconID)
            previewBtn:Show()
            
            -- Update tooltip handler based on type
            previewBtn:SetScript("OnEnter", function(self)
                if previewSpell then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if previewSpell.itemID then
                        GameTooltip:SetItemByID(previewSpell.itemID)
                    else
                        GameTooltip:SetSpellByID(previewSpell.spellID)
                    end
                    GameTooltip:Show()
                end
            end)
            
            -- If the previously glow-selected btn was this preview icon,
            -- re-apply glow since SetupAnts was called on it before Show
            if selectedBtn == previewBtn then
                SpellStyler.GlowUtil:SetupAnts(previewBtn, { r = 1, g = 0.82, b = 0 })
                SpellStyler.GlowUtil:PlayAnts(previewBtn)
            end
        else
            previewSpell = nil
            previewBtn:Hide()
            if selectedBtn == previewBtn then Deselect() end
        end
    end

    -- ── Wire editBox ───────────────────────────────────────────────────
    editBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        UpdateLookupIcon(text)
        FilterAndLayoutSafe(text, gridSF:GetWidth())
    end)

    -- ── Scroll + resize ────────────────────────────────────────────────
    gridSF:SetScript("OnMouseWheel", function(self, delta)
        local cur  = self:GetVerticalScroll()
        local max  = self:GetVerticalScrollRange()
        local step = (currentIconSize + GRID_GAP) * 2
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * step)))
    end)

    gridSF:SetScript("OnSizeChanged", function(self, width)
        FilterAndLayoutSafe(lastFilter, width)
    end)

    -- Initial layout
    local initWidth = gridSF:GetWidth()
    if initWidth and initWidth > 0 then
        FilterAndLayoutSafe("", initWidth)
    end
end
