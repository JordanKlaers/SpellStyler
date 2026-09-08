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
                                local chargeInfo = C_Spell.GetSpellCharges(sid)
                                if (cooldownMS and cooldownMS > 0) or (chargeInfo and chargeInfo.maxCharges > 1) or (chargeInfo and chargeInfo.cooldownDuration > 0) then
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
        GameTooltip:SetText("Add Tracker", 1, 1, 1)
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
    -- entryType is one of "spell" | "item" | "aura"
    local selectedEntry = nil
    local selectedType  = nil
    local selectedBtn   = nil

    local previewEntry = nil
    local previewType  = nil

    local previewBtn = nil  -- forward-declared: single shared preview icon
    local previewTex = nil
    local addBtn     = nil  -- forward-declared: single shared add button

    -- These are also needed by the slot-picker before the shared controls are built.
    local slotPreviewBtn = nil
    local slotAddBtn = nil
    -- Forward-declared so closures can reference them
    -- (Lua closures only capture locals that are in scope at definition time)
    local gridSF
    local gridButtons
    local lastFilter = ""
    local FilterAndLayoutSafe
    local UpdatePreview

    local function Deselect()
        if selectedBtn and SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:StopAnts(selectedBtn)
        end
        selectedEntry = nil
        selectedType  = nil
        selectedBtn   = nil
        if addBtn then addBtn:Disable() end
    end

    local function SelectEntry(entry, entryType, btn)
        -- deselect old
        if selectedBtn and SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:StopAnts(selectedBtn)
        end
        selectedEntry = entry
        selectedType  = entryType
        selectedBtn   = btn
        if SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:SetupAnts(btn, { r = 1, g = 0.82, b = 0 })
            SpellStyler.GlowUtil:PlayAnts(btn)
        end
        if addBtn then addBtn:Enable() end
    end
    -- clicking empty space deselects
    container:SetScript("OnMouseDown", function() Deselect() end)

    
    --- Creates a labeled search input for the given entry type ("spell" | "item" | "aura").
    --- Focusing or typing in this box makes it the active source for the shared
    --- preview icon and Add button.
    local function createSearchInput(anchor, container, entryType, tooltipLines)
        local editBox = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
        editBox:SetSize(160, 22)
        editBox:SetPoint("BOTTOM", anchor, "BOTTOM", 0, 0)
        editBox:SetPoint("RIGHT", container, "RIGHT", -12, 0)
        editBox:SetAutoFocus(false)
        editBox:SetMaxLetters(100)

        if tooltipLines then
            editBox:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                for _, line in ipairs(tooltipLines) do
                    GameTooltip:AddLine(line, 1, 1, 1)
                end
                GameTooltip:Show()
            end)
            editBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        -- Clicking into this field makes it the active source for the shared preview/add controls
        editBox:SetScript("OnEditFocusGained", function(self)
            UpdatePreview(entryType, self:GetText())
        end)

        editBox:SetScript("OnTextChanged", function(self)
            UpdatePreview(entryType, self:GetText())
            FilterAndLayoutSafe(self:GetText(), gridSF:GetWidth())
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

        return editBox
    end

    -- Equippable slots (matches TextureHelper's equipment scan; Shirt/Tabard excluded)
    local equipmentSlots = {
        { id = 1,  name = "Head" },
        { id = 2,  name = "Neck" },
        { id = 3,  name = "Shoulder" },
        { id = 5,  name = "Chest" },
        { id = 6,  name = "Waist" },
        { id = 7,  name = "Legs" },
        { id = 8,  name = "Feet" },
        { id = 9,  name = "Wrist" },
        { id = 10, name = "Hands" },
        { id = 11, name = "Finger 1" },
        { id = 12, name = "Finger 2" },
        { id = 13, name = "Trinket 1" },
        { id = 14, name = "Trinket 2" },
        { id = 15, name = "Back" },
        { id = 16, name = "Main Hand" },
        { id = 17, name = "Off Hand" },
        { id = 18, name = "Ranged" },
    }

    --- Creates a dropdown listing each equipment slot, labeled by the currently
    --- equipped item's inventoryType, with that item's icon shown alongside it.
    local function getItemSlotTrackerKey(slotInfo)
        local slotName = (slotInfo and (slotInfo.name or slotInfo.slotName or "")) or ""
        local key = string.lower(slotName)
        key = key:gsub("%s+", "")
        key = key:gsub("[%-%/]+", "")
        return key
    end

    local function createItemSlotDropdown(anchor, container)
        local dropdown = CreateFrame("Frame", nil, container, "UIDropDownMenuTemplate")
        dropdown:SetPoint("BOTTOM", anchor, "BOTTOM", 0, -8)
        dropdown:SetPoint("RIGHT", container, "RIGHT", 6, 0)
        UIDropDownMenu_SetWidth(dropdown, 160)

        local function applySlotSelection(slotInfo)
            local itemID = GetInventoryItemID("player", slotInfo.id)
            local itemName = itemID and C_Item.GetItemNameByID(itemID) or slotInfo.name
            local itemIcon = itemID and C_Item.GetItemIconByID(itemID) or nil
            local slotEntry = {
                isSlotEntry = true,
                itemID = itemID,
                name = itemName,
                iconID = itemIcon,
                slotID = slotInfo.id,
                slotName = slotInfo.name,
                slotKey = getItemSlotTrackerKey(slotInfo)
            }

            if selectedBtn and SpellStyler.GlowUtil then
                SpellStyler.GlowUtil:StopAnts(selectedBtn)
            end
            selectedEntry = slotEntry
            selectedType = "item"
            selectedBtn = previewBtn
            previewEntry = slotEntry
            previewType = "item"
            if itemIcon then
                if previewTex then previewTex:SetTexture(itemIcon) end
                if previewBtn then previewBtn:Show() end
                if SpellStyler.GlowUtil and previewBtn then
                    SpellStyler.GlowUtil:SetupAnts(previewBtn, { r = 1, g = 0.82, b = 0 })
                    SpellStyler.GlowUtil:PlayAnts(previewBtn)
                end
            else
                previewEntry, previewType = nil, nil
                if previewBtn then previewBtn:Hide() end
            end

            if itemID then
                if addBtn then addBtn:Enable() end
            else
                if addBtn then addBtn:Disable() end
            end
        end

        UIDropDownMenu_Initialize(dropdown, function(self, level)
            for _, slotInfo in ipairs(equipmentSlots) do
                local itemLocation = ItemLocation:CreateFromEquipmentSlot(slotInfo.id)
                local iconTexture = GetInventoryItemTexture("player", slotInfo.id)
                local inventoryType = itemLocation:IsValid() and C_Item.GetItemInventoryType(itemLocation) or nil

                local info = UIDropDownMenu_CreateInfo()
                info.text = slotInfo.name
                info.icon = iconTexture
                info.notCheckable = true
                info.value = {
                    slotInfo = slotInfo,
                    itemLocation = itemLocation,
                    inventoryType = inventoryType
                }
                info.func = function()
                    UIDropDownMenu_SetSelectedValue(dropdown, slotInfo.id)
                    UIDropDownMenu_SetText(dropdown, slotInfo.name)
                    applySlotSelection(slotInfo)
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)

        UIDropDownMenu_SetText(dropdown, "Select Slot")

        return dropdown
    end

    -- ── Static header UI ───────────────────────────────────────────────
    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -4)
    title:SetText("|cFFFFD700Spell|r")
    local editBox = createSearchInput(title, container, "spell")

    local itemTitle = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    itemTitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    itemTitle:SetText("|cFFFFD700Item|r")

    local itemEditBox = createSearchInput(itemTitle, container, "item")

    local itemBySlotTitle = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    itemBySlotTitle:SetPoint("TOPLEFT", itemTitle, "BOTTOMLEFT", 0, -10)
    itemBySlotTitle:SetText("|cFFFFD700Item by Slot|r")

    local itemBySlotDropdown = createItemSlotDropdown(itemBySlotTitle, container)

    local auraTitle = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    auraTitle:SetPoint("TOPLEFT", itemBySlotTitle, "BOTTOMLEFT", 0, -10)
    auraTitle:SetText("|cFFFFD700Aura|r")

    local auraEditBox = createSearchInput(auraTitle, container, "aura", {
        "Any spellID should work.",
        "You can add additional IDs",
        "in the settings menu after adding.",
        "All aura data will display within the",
        "same frame using the games own priority",
        "Reach out in the discord if you cant find your buff ID",
    })

    -- ── Shared preview icon + Add button ────────────────────────────────
    -- Whichever input field is active (spell/item/aura) drives what these show and do.
    local PREVIEW_SIZE = 30
    previewBtn = CreateFrame("Button", nil, container)
    previewBtn:SetSize(PREVIEW_SIZE, PREVIEW_SIZE)
    previewBtn:SetPoint("TOPLEFT", auraEditBox, "BOTTOMLEFT", 0, -10)
    previewBtn:EnableMouse(true)
    previewBtn:RegisterForClicks("LeftButtonUp")
    previewBtn:Hide()

    previewTex = previewBtn:CreateTexture(nil, "ARTWORK")
    previewTex:SetAllPoints()
    previewTex:SetTexCoord(0, 1, 0, 1)
    local previewHL = previewBtn:CreateTexture(nil, "HIGHLIGHT")
    previewHL:SetAllPoints()
    previewHL:SetColorTexture(1, 1, 1, 0.25)

    previewBtn:SetScript("OnEnter", function(self)
        if previewEntry then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if previewType == "item" then
                GameTooltip:SetItemByID(previewEntry.itemID)
            else
                GameTooltip:SetSpellByID(previewEntry.spellID)
            end
            GameTooltip:Show()
        end
    end)
    previewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    previewBtn:SetScript("OnClick", function(self)
        if previewEntry then SelectEntry(previewEntry, previewType, self) end
    end)

    addBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 22)
    addBtn:SetPoint("LEFT", previewBtn, "RIGHT", 8, (PREVIEW_SIZE - 22) / 2)
    addBtn:SetText("Add")
    addBtn:Disable()
    addBtn:SetScript("OnClick", function()
        if not selectedEntry or not selectedType then return end
        local FTM   = SpellStyler.FrameTrackerManager
        local State = SpellStyler.State

        local trackingID
        local trackerConfig
        local trackerType

        if selectedType == "spell" then
            trackerType = "spells"
            trackingID = C_Spell.GetBaseSpell(selectedEntry.spellID)
            local existingTrackerConfig, foundConfig = State:GetSpecificTrackerValue(trackingID, "spells")
            if existingTrackerConfig and foundConfig then
                trackerConfig = existingTrackerConfig
                State:SetTrackerValueConfigProperty(trackingID, "spells", 'isEnabled', true)
            else
                -- Track spell by baseSpellID
                local overrideSpellID = C_Spell.GetOverrideSpell(selectedEntry.spellID)
                -- Get icon from override spell for correct initial appearance
                local overrideSpellInfo = C_Spell.GetSpellInfo(overrideSpellID)
                local iconTexture = (overrideSpellInfo and overrideSpellInfo.iconID) or selectedEntry.iconID
                trackerConfig = State:AddTrackerValue({
                    trackerKey              = trackingID,
                    baseSpellID             = trackingID,
                    overrideSpellID         = overrideSpellID,
                    trackerType             = "spells",
                    name                    = selectedEntry.name,
                    defaultIconTexturePath  = iconTexture,
                })
            end
        elseif selectedType == "item" then
            trackerType = "items"

            -- If this came from an equipped slot picker, key the DB by the slot name
            -- (e.g. "head", "finger1") and use the current item data for the config.
            if selectedEntry.isSlotEntry then
                local itemID = selectedEntry.itemID
                local _, spellID = C_Item.GetItemSpell(itemID)
                trackingID = selectedEntry.slotKey

                local existingTrackerConfig, foundConfig = State:GetSpecificTrackerValue(trackingID, "items")
                if existingTrackerConfig and foundConfig then
                    trackerConfig = existingTrackerConfig
                    State:SetTrackerValueConfigProperty(trackingID, "items", 'isEnabled', true)
                    State:SetTrackerValueConfigProperty(trackingID, "items", 'itemID', itemID)
                    State:SetTrackerValueConfigProperty(trackingID, "items", 'baseSpellID', spellID or trackingID)
                    State:SetTrackerValueConfigProperty(trackingID, "items", 'overrideSpellID', spellID or trackingID)
                    State:SetTrackerValueConfigProperty(trackingID, "items", 'name', selectedEntry.name)
                    State:SetTrackerValueConfigProperty(trackingID, "items", 'defaultIconTexturePath', C_Item.GetItemIconByID(itemID))
                else
                    local iconTexture = C_Item.GetItemIconByID(itemID)
                    trackerConfig = State:AddTrackerValue({
                        trackerKey              = trackingID,
                        itemID                  = itemID,
                        baseSpellID             = spellID or trackingID,
                        overrideSpellID         = spellID or trackingID,
                        trackerType             = "items",
                        name                    = selectedEntry.name,
                        defaultIconTexturePath  = iconTexture,
                        isItem                  = true,
                    })
                end
            else
                -- Normal item search result: keep the existing spell-ID item key behavior.
                local spellName, spellID = C_Item.GetItemSpell(selectedEntry.itemID)
                trackingID = spellID
                local existingTrackerConfig, foundConfig = State:GetSpecificTrackerValue(spellID, "items")
                if existingTrackerConfig and foundConfig then
                    trackerConfig = existingTrackerConfig
                    State:SetTrackerValueConfigProperty(spellID, "items", 'isEnabled', true)
                    State:SetTrackerValueConfigProperty(spellID, "items", 'itemID', selectedEntry.itemID)
                    State:SetTrackerValueConfigProperty(spellID, "items", 'baseSpellID', spellID)
                    State:SetTrackerValueConfigProperty(spellID, "items", 'overrideSpellID', spellID)
                else
                    local iconTexture = C_Item.GetItemIconByID(selectedEntry.itemID)
                    trackerConfig = State:AddTrackerValue({
                        trackerKey              = trackingID,
                        itemID                  = selectedEntry.itemID,
                        baseSpellID             = spellID,
                        overrideSpellID         = spellID,
                        trackerType             = "items",
                        name                    = selectedEntry.name,
                        defaultIconTexturePath  = iconTexture,
                        isItem                  = true,
                    })
                end
            end
        elseif selectedType == "aura" then
            trackerType = "buffs"
            local BuffManager = SpellStyler.BuffManager
            trackingID = C_Spell.GetBaseSpell(selectedEntry.spellID)
            local existingTrackerConfig, foundConfig = State:GetSpecificTrackerValue(trackingID, "buffs")
            local currentSpecID = State and State.GetCurrentSpecID and State:GetCurrentSpecID()
            if existingTrackerConfig and foundConfig then
                trackerConfig = existingTrackerConfig
                State:SetTrackerValueConfigProperty(trackingID, "buffs", 'isEnabled', true)
                -- If you are readding an aura, flag the aura as being applicable for the current specID
                State:SetTrackerValueConfigProperty(trackingID, "buffs", 'auraSpecs.' .. currentSpecID, true)
                if BuffManager.buffContainers[trackingID] then
                    BuffManager:UpdateAura(BuffManager.buffContainers[trackingID], trackerConfig)
                end
            else
                -- Track aura by baseSpellID
                local overrideSpellID = C_Spell.GetOverrideSpell(selectedEntry.spellID)
                -- Get icon from override spell for correct initial appearance
                local overrideSpellInfo = C_Spell.GetSpellInfo(overrideSpellID)
                local iconTexture = (overrideSpellInfo and overrideSpellInfo.iconID) or selectedEntry.iconID
                trackerConfig = State:AddTrackerValue({
                    trackerKey              = trackingID,
                    baseSpellID             = trackingID,
                    overrideSpellID         = overrideSpellID,
                    trackerType             = "buffs",
                    name                    = selectedEntry.name,
                    defaultIconTexturePath  = iconTexture,
                    auraSpecs               = {
                        [currentSpecID] = true
                    }
                })
            end
        end

        if not trackerConfig then return end

        -- Wipe devNotes before creating frame (fresh start for error tracking)
        State:SetTrackerValueConfigProperty(trackingID, trackerType, "devNotes", {})

        if selectedType == "aura" then
            local BuffManager = SpellStyler.BuffManager
            if BuffManager and BuffManager.CreateSingleAuraContainer then
                BuffManager:CreateSingleAuraContainer(trackingID, trackerConfig)
            end
        else
            -- CreateFrameMiddleware creates base frame, variant frame (if needed),
            -- sets up charge infrastructure, and drives updates
            FTM:CreateCompleteFrame(trackingID, trackerConfig, trackerType)

            -- Remove from the grid so it can't be added twice (auras aren't in the grid)
            local addedID = selectedType == "item" and selectedEntry.itemID or selectedEntry.spellID
            for i = #gridButtons, 1, -1 do
                local entryID = gridButtons[i].type == "item"
                    and gridButtons[i].data.itemID
                    or gridButtons[i].data.spellID
                if gridButtons[i].type == selectedType and entryID == addedID then
                    gridButtons[i].btn:Hide()
                    table.remove(gridButtons, i)
                end
            end
            FilterAndLayoutSafe(lastFilter, gridSF:GetWidth())
        end

        -- Clear selection
        Deselect()

        -- Refresh the icon list in the settings panel so the new entry appears
        if SpellStyler.settingsContentFrame then
            SpellStyler.IconSettingsRenderer:RenderIconControlView(SpellStyler.settingsContentFrame)
            local ISR = SpellStyler.IconSettingsRenderer
            if ISR and ISR.EnableDraggingForAllFrames then
                ISR:EnableDraggingForAllFrames()
            end
        end
    end)

    -- ── Separator ──────────────────────────────────────────────────────
    local sep = container:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    sep:SetHeight(1)
    sep:SetPoint("LEFT", auraTitle, "LEFT", 0, 0)
    sep:SetPoint("TOP", previewBtn, "BOTTOM", 0, -5)
    sep:SetPoint("RIGHT", container, "RIGHT", -12, 0)

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
                SelectEntry(capturedSpell, "spell", self)
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
                SelectEntry(capturedItem, "item", self)
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
    -- Shared by all three inputs; entryType selects which lookup API to use.
    UpdatePreview = function(entryType, text)
        if not text or text == "" then
            if previewBtn then previewBtn:Hide() end
            previewEntry, previewType = nil, nil
            if selectedBtn == previewBtn then Deselect() end
            return
        end

        local id = tonumber(text)
        local found = nil

        if entryType == "item" then
            if id then
                local itemName = C_Item.GetItemNameByID(id)
                local itemIcon = C_Item.GetItemIconByID(id)
                if itemName and itemIcon then
                    found = { itemID = id, name = itemName, iconID = itemIcon }
                end
            else
                local itemName = C_Item.GetItemNameByID(text)
                local itemIcon = C_Item.GetItemIconByID(text)
                local itemID = C_Item.GetItemIDForItemInfo(text)
                if itemName and itemIcon then
                    found = { itemID = itemID, name = itemName, iconID = itemIcon }
                end
            end
        else
            -- "spell" and "aura" both resolve against the spell APIs
            if id then
                local si = C_Spell.GetSpellInfo(id)
                if si then
                    found = { spellID = id, name = si.name, iconID = si.iconID }
                end
            else
                local si = C_Spell.GetSpellInfo(text)
                if si then
                    found = { spellID = si.spellID, name = si.name, iconID = si.iconID }
                end
            end
        end

        if found then
            previewEntry, previewType = found, entryType
            previewTex:SetTexture(found.iconID)
            previewBtn:Show()

            -- If the previously glow-selected btn was this preview icon,
            -- re-apply glow since SetupAnts was called on it before Show
            if selectedBtn == previewBtn then
                SpellStyler.GlowUtil:SetupAnts(previewBtn, { r = 1, g = 0.82, b = 0 })
                SpellStyler.GlowUtil:PlayAnts(previewBtn)
            end
        else
            previewEntry, previewType = nil, nil
            if previewBtn then previewBtn:Hide() end
            if selectedBtn == previewBtn then Deselect() end
        end
    end

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
