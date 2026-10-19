local ADDON_NAME, SpellStyler = ...
SpellStyler.AddSpells = SpellStyler.AddSpells or {}
local AddSpells = SpellStyler.AddSpells
local State = SpellStyler.State

local PLUS_ICON_PATH = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\PlusIcon"

State.items = {
    -- save items and their qualities. The key should be the spellId of the item (different qualities share the same spellId for the item)
    ownedItemQualityCache = {},
    -- Returns a number representing the item quality
    GetItemQuality = function(itemID)
        if not itemID then return nil end
        if C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityInfo then
            local info = C_TradeSkillUI.GetItemReagentQualityInfo(itemID)
            if info and (info.quality or info.qualityLevel) then
                return info.quality or info.qualityLevel
            end
        end
        local _, _, quality = C_Item.GetItemInfo(itemID)
        return quality
    end,
    AddOwnedItemToQualityCache = function(itemID)
        if not itemID then return end

        local _, itemSpellID = C_Item.GetItemSpell(itemID)
        local cacheKey = itemSpellID or itemID
        local quality = SpellStyler.State.items.GetItemQuality(itemID)
        local texture = C_Item.GetItemIconByID(itemID)
        local cache = SpellStyler.State.items.ownedItemQualityCache
        cache[cacheKey] = cache[cacheKey] or {}
        cache[cacheKey][itemID] = {
            itemID = itemID,
            qualityLevel = tonumber(quality) or quality,
            texturePath = texture,
            textureID = texture,
        }
    end,
    GetOwnedItemIDs = function()
        local ids = {}
        local seen = {}
        for slotID = 1, 19 do
            local itemID = GetInventoryItemID("player", slotID)
            if itemID and not seen[itemID] then
                seen[itemID] = true
                table.insert(ids, itemID)
            end
        end
        for bagID = 0, 6 do
            for slotID = 1, (C_Container.GetContainerNumSlots(bagID) or 0) do
                local info = C_Container.GetContainerItemInfo(bagID, slotID)
                if info and info.itemID and not seen[info.itemID] then
                    seen[info.itemID] = true
                    table.insert(ids, info.itemID)
                end
            end
        end
        return ids
    end,
    RebuildOwnedItemQualityCache= function()
        SpellStyler.State.items.ownedItemQualityCache = {}

        for _, itemID in ipairs(SpellStyler.State.items.GetOwnedItemIDs()) do
            SpellStyler.State.items.AddOwnedItemToQualityCache(itemID)
        end
    end,
    AddOwnedItemQualityFromBagSlot = function(bagSlot)
        if type(bagSlot) ~= "number" then return end

        local itemInfo = C_Container.GetContainerItemInfo(0, bagSlot)
        if itemInfo and itemInfo.itemID then
            SpellStyler.State.items.AddOwnedItemToQualityCache(itemInfo.itemID)
        end
    end,
    GetBestCachedItemQuality = function(itemID, spellID)
        if not itemID and not spellID then return nil end

        local cacheKey = spellID
        if not cacheKey and itemID then
            local _, itemSpellID = C_Item.GetItemSpell(itemID)
            cacheKey = itemSpellID or itemID
        end

        local cachedItems = SpellStyler.State.items.ownedItemQualityCache[cacheKey]
        local best
        local bestCount = cachedItems and 0 or nil
        if cachedItems then
            for _, itemData in pairs(cachedItems) do
                local itemCount = C_Item.GetItemCount(itemData.itemID, false, true)
                if itemCount > 0
                    and itemData.qualityLevel
                    and (not best or itemData.qualityLevel > best.qualityLevel)
                then
                    best = itemData
                    bestCount = itemCount
                end
            end
        end
        return best, bestCount
    end,

    -- GetOwnedItemQualityBySpellID = function(spellID)
    --     return SpellStyler.State.items.GetBestCachedItemQuality(nil, spellID)
    -- end,

    --- Returns the highest-quality owned variant while retaining the configured base item ID.
    GetOwnedItemQuality = function(itemID, associatedItemQualitiesOrSpellID)
        local spellID = type(associatedItemQualitiesOrSpellID) == "number"
            and associatedItemQualitiesOrSpellID
            or nil
        return SpellStyler.State.items.GetBestCachedItemQuality(itemID, spellID)
    end,

    GetOwnedItemIcon = function(itemID, associatedItemQualities, fallback)
        local resolved = SpellStyler.State.items.GetOwnedItemQuality(itemID, associatedItemQualities)
        return (resolved and (resolved.texturePath or resolved.textureID))
            or fallback
            or (itemID and C_Item.GetItemIconByID(itemID))
    end,

    --- Resolves an item icon and draws its quality marker. Used by settings and live frames.
    RenderOwnedItemQuality = function(frame, itemID, associatedItemQualities)
        if not frame or not itemID then return nil end
        local resolved = SpellStyler.State.items.GetOwnedItemQuality(itemID, associatedItemQualities)
        if resolved and frame.SetTexture then
            frame:SetTexture(resolved.texturePath or resolved.textureID)
        elseif resolved and frame.icon and frame.icon.SetTexture then
            frame.icon:SetTexture(resolved.texturePath or resolved.textureID)
        end
        SpellStyler.FrameTrackerManager.utils.ApplyItemQualityOverlay(itemID, frame, associatedItemQualities, true)
        return resolved
    end

}


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
                        and not info.isPassive
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
--- with cooldowns. Each entry retains itemID and includes owned quality variants.
function AddSpells:GetPlayerItems()
    local items = {}
    local seen = {}  -- deduplicate by itemID
    local seenNames = {}
    local function getQualities(itemID, itemName, spellID)
        local records = {}
        local cachedItems = SpellStyler.State.items.ownedItemQualityCache[spellID or itemID]
        for _, itemData in pairs(cachedItems or {}) do
            if itemData.qualityLevel then
                records[#records + 1] = {
                    itemID = itemData.itemID,
                    qualityLevel = itemData.qualityLevel,
                    texturePath = itemData.texturePath,
                    textureID = itemData.textureID,
                }
            end
        end
        return records
    end
    
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
            
            if itemName and not seenNames[itemName] and itemIcon and isUsable and hasCooldown then
                seen[itemID] = true
                seenNames[itemName] = true
                table.insert(items, {
                    itemID = itemID,
                    name = itemName,
                    iconID = itemIcon,
                    isEquipped = true,
                    associatedItemQualities = getQualities(itemID, itemName, select(2, C_Item.GetItemSpell(itemID))),
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
                        
                        if itemName and not seenNames[itemName] and itemIcon and isUsable and hasCooldown then
                            seen[itemID] = true
                            seenNames[itemName] = true
                            table.insert(items, {
                                itemID = itemID,
                                name = itemName,
                                iconID = itemIcon,
                                isEquipped = false,
                                associatedItemQualities = getQualities(itemID, itemName, select(2, C_Item.GetItemSpell(itemID))),
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

local DISABLED_ICON_PATH = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\HiddenIcon"

function AddSpells:RenderDisabledValuesView(parent)
    if not parent then return end
    SpellStyler.IconSettingsRenderer:HideSelectedIconHeader()

    local parentScrollFrame = parent:GetParent()
    if parentScrollFrame and parentScrollFrame.GetHeight then
        parent:SetHeight(parentScrollFrame:GetHeight())
        parentScrollFrame:SetVerticalScroll(0)
    end

    local childrenToRemove = {}
    for _, child in ipairs({ parent:GetChildren() }) do
        table.insert(childrenToRemove, child)
    end
    for _, child in ipairs(childrenToRemove) do
        child:Hide()
        child:SetParent(nil)
    end

    local regionsToRemove = {}
    for _, region in ipairs({ parent:GetRegions() }) do
        if region:IsObjectType("FontString") or region:IsObjectType("Texture") then
            table.insert(regionsToRemove, region)
        end
    end
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

    local selectedEntry
    local selectedButton

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -4)
    title:SetText("|cFFFFD700Disabled Values|r")

    local note = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    note:SetText("Select a preexisting value to reenable")
    note:SetTextColor(0.8, 0.8, 0.8)
    local subNote = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    subNote:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -10)
    subNote:SetPoint("RIGHT", container, "RIGHT", -10, 0)
    subNote:SetJustifyH("LEFT")
    subNote:SetText("IDs may overlap between entries. Ensure you have the correct entry enabled before considering deletion.")
    subNote:SetTextColor(0.8, 0.8, 0.8)

    local reenableButton = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    reenableButton:SetSize(100, 24)
    reenableButton:SetPoint("TOPLEFT", subNote, "BOTTOMLEFT", 0, -12)
    reenableButton:SetText("reenable")
    reenableButton:Disable()

    local deleteButton = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    deleteButton:SetSize(150, 24)
    deleteButton:SetPoint("LEFT", reenableButton, "RIGHT", 8, 0)
    deleteButton:SetText("permenantly delete")
    deleteButton:Disable()

    local confirmPopup = CreateFrame("Frame", nil, container, "BackdropTemplate")
    confirmPopup:SetSize(230, 82)
    confirmPopup:SetPoint("TOPLEFT", reenableButton, "BOTTOMLEFT", 0, -6)
    confirmPopup:SetFrameLevel(container:GetFrameLevel() + 10)
    confirmPopup:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    confirmPopup:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    confirmPopup:SetBackdropBorderColor(0.8, 0.2, 0.2, 1)
    confirmPopup:Hide()

    local confirmText = confirmPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    confirmText:SetPoint("TOP", confirmPopup, "TOP", 0, -10)
    confirmText:SetText("Permanently delete this value?")
    confirmText:SetTextColor(1, 0.4, 0.4)

    local confirmButton = CreateFrame("Button", nil, confirmPopup, "UIPanelButtonTemplate")
    confirmButton:SetSize(80, 22)
    confirmButton:SetPoint("BOTTOMLEFT", confirmPopup, "BOTTOMLEFT", 14, 10)
    confirmButton:SetText("confirm")

    local cancelButton = CreateFrame("Button", nil, confirmPopup, "UIPanelButtonTemplate")
    cancelButton:SetSize(80, 22)
    cancelButton:SetPoint("BOTTOMRIGHT", confirmPopup, "BOTTOMRIGHT", -14, 10)
    cancelButton:SetText("cancel")
    cancelButton:SetScript("OnClick", function()
        confirmPopup:Hide()
    end)

    local gridSF = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
    gridSF:SetPoint("TOPLEFT", reenableButton, "BOTTOMLEFT", 0, -18)
    gridSF:SetPoint("TOPRIGHT", container, "TOPRIGHT", -12, 0)
    gridSF:SetPoint("BOTTOM", container, "BOTTOM", 0, 10)

    local gridChild = CreateFrame("Frame", nil, gridSF)
    gridSF:SetScrollChild(gridChild)
    gridSF:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maximum = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(maximum, current - delta * self:GetHeight() * 0.25)))
    end)

    local disabledValues = SpellStyler.State:GetDisabledTrackerValuesForSettings()
    local iconSize, iconPadding, iconsPerRow = 40, 5, 6
    local categoryGroups = {
        { trackerType = "buffs", label = "Auras", entries = {} },
        { trackerType = "items", label = "Items", entries = {} },
        { trackerType = "spells", label = "Spells", entries = {} },
    }
    local groupsByTrackerType = {}
    for _, group in ipairs(categoryGroups) do
        groupsByTrackerType[group.trackerType] = group
    end
    for _, entry in ipairs(disabledValues) do
        local group = groupsByTrackerType[entry.trackerType]
        if group then
            table.insert(group.entries, entry)
        end
    end

    local function getSpellInfo(spellID)
        return spellID and C_Spell.GetSpellInfo(tonumber(spellID) or spellID)
    end

    local function getEntryIcon(entry)
        local config = entry.config
        if entry.trackerType == "items" then
            return SpellStyler.State.items.GetOwnedItemIcon(config.itemID, config.associatedItemQualities,
                    config.itemID and C_Item.GetItemIconByID(config.itemID))
                or config.defaultIconTexturePath
                or DISABLED_ICON_PATH
        end
        local baseSpellID = entry.baseSpellID
        local variation = SpellStyler.State:GetAssociatedSpellID(config, baseSpellID)
        if variation and variation.iconTexturePath and variation.iconTexturePath ~= "" then
            return variation.iconTexturePath
        end
        local spellInfo = getSpellInfo(baseSpellID)
        return (spellInfo and spellInfo.iconID) or config.defaultIconTexturePath or DISABLED_ICON_PATH
    end

    local function sameSpellID(left, right)
        return left ~= nil and right ~= nil and tostring(left) == tostring(right)
    end

    local function getTrackerStatus(trackerType, trackerConfig)
        if trackerType == "spells" then
            return SpellStyler.State:IsSpellTrackerEnabled(trackerConfig) and "enabled" or "disabled"
        end
        return trackerConfig.isEnabled == false and "disabled" or "enabled"
    end

    local function findStateMatches(entry, baseSpellID, overrideSpellID)
        local targetIDs = {
            [tostring(baseSpellID)] = baseSpellID,
        }
        if overrideSpellID then
            targetIDs[tostring(overrideSpellID)] = overrideSpellID
        end

        local matches = {}
        local seenMatchKeys = {}
        local trackerTypes = { "buffs", "items", "spells" }
        for _, trackerType in ipairs(trackerTypes) do
            for trackerKey, trackerConfig in pairs(SpellStyler.State:GetAllTrackerValues(trackerType) or {}) do
                if not (trackerType == entry.trackerType and sameSpellID(trackerKey, entry.trackerKey)) then
                    local matchedKind
                    local matchedValue
                    local otherBaseSpellID = trackerConfig.baseSpellID

                    for targetID in pairs(targetIDs) do
                        if sameSpellID(targetID, otherBaseSpellID) then
                            matchedKind = "base"
                            matchedValue = otherBaseSpellID
                            break
                        end
                    end

                    if not matchedKind then
                        for _, additionalSpellID in ipairs(trackerConfig.additionalBuffIDs or {}) do
                            if targetIDs[tostring(additionalSpellID)] then
                                matchedKind = "additional aura"
                                matchedValue = additionalSpellID
                                break
                            end
                        end
                    end

                    if not matchedKind then
                        local associatedSpellIDs = {
                            trackerConfig.overrideSpellID,
                        }
                        for spellID in pairs(SpellStyler.State:GetAssociatedSpellIDs(trackerConfig)) do
                            table.insert(associatedSpellIDs, spellID)
                        end
                        for _, associatedSpellID in ipairs(associatedSpellIDs) do
                            if targetIDs[tostring(associatedSpellID)] then
                                matchedKind = "associated"
                                matchedValue = associatedSpellID
                                break
                            end
                        end
                    end

                    local matchKey = tostring(trackerKey)
                    if matchedKind and not seenMatchKeys[matchKey] then
                        seenMatchKeys[matchKey] = true
                        table.insert(matches, {
                            kind = matchedKind,
                            value = matchedValue,
                            trackerKey = trackerKey,
                            trackerType = trackerType,
                            status = getTrackerStatus(trackerType, trackerConfig),
                        })
                    end
                end
            end
        end
        return matches
    end

    local function selectEntry(entry, button)
        if selectedButton then
            selectedButton:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        end
        selectedEntry = entry
        selectedButton = button
        selectedButton:SetBackdropBorderColor(1, 0.82, 0, 1)
        reenableButton:Enable()
        deleteButton:Enable()
    end

    local function refreshSettingsView()
        if SpellStyler.IconSettingsRenderer and SpellStyler.settingsContentFrame then
            SpellStyler.IconSettingsRenderer:RenderIconControlView(SpellStyler.settingsContentFrame)
        end
    end

    reenableButton:SetScript("OnClick", function()
        if not selectedEntry then return end
        SpellStyler.State:ReenableTrackerValue(selectedEntry.trackerKey, selectedEntry.trackerType)
        refreshSettingsView()
    end)

    deleteButton:SetScript("OnClick", function()
        if selectedEntry then
            confirmPopup:Show()
        end
    end)

    confirmButton:SetScript("OnClick", function()
        if not selectedEntry then return end
        confirmPopup:Hide()
        if SpellStyler.State:IsTrackerValueDisabled(
            selectedEntry.trackerKey,
            selectedEntry.trackerType
        ) then
            SpellStyler.State:RemoveTrackerValue(selectedEntry.trackerKey, selectedEntry.trackerType)
        end
        refreshSettingsView()
    end)

    local currentYOffset = 0
    local categoryLabelHeight = 18
    for _, group in ipairs(categoryGroups) do
        if #group.entries > 0 then
            local categoryLabel = gridChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            categoryLabel:SetPoint("TOPLEFT", gridChild, "TOPLEFT", 0, -currentYOffset)
            categoryLabel:SetText(group.label)
            categoryLabel:SetTextColor(1, 0.82, 0, 1)
            currentYOffset = currentYOffset + categoryLabelHeight

            for index, entry in ipairs(group.entries) do
                local button = CreateFrame("Button", nil, gridChild, "BackdropTemplate")
                button:SetSize(iconSize, iconSize)
                button:SetPoint(
                    "TOPLEFT",
                    gridChild,
                    "TOPLEFT",
                    ((index - 1) % iconsPerRow) * (iconSize + iconPadding),
                    -currentYOffset - math.floor((index - 1) / iconsPerRow) * (iconSize + iconPadding)
                )
                button:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
                button:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

                local texture = button:CreateTexture(nil, "ARTWORK")
                texture:SetAllPoints(button)
                texture:SetTexture(getEntryIcon(entry))
                SpellStyler.FrameTrackerManager.utils.ApplyItemQualityOverlay(entry.config.itemID, button,
                    entry.config.associatedItemQualities, entry.config.shouldShowQualityEmblem)

                button:SetScript("OnClick", function()
                    selectEntry(entry, button)
                end)
                button:SetScript("OnEnter", function(self)
                    local baseSpellID = entry.baseSpellID
                    local baseInfo = getSpellInfo(baseSpellID)
                    local overrideID = baseSpellID and C_Spell.GetOverrideSpell(baseSpellID)
                    local overrideInfo = getSpellInfo(overrideID)
                    local stateMatches = findStateMatches(entry, baseSpellID, overrideID)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if entry.trackerType == "items" then
                        local itemName = entry.config.name
                            or (entry.config.itemID and C_Item.GetItemNameByID(entry.config.itemID))
                            or "Unknown"
                        GameTooltip:SetText(itemName, 1, 1, 1)
                        GameTooltip:AddLine("Item ID: " .. tostring(entry.config.itemID or "Unknown"), 0.8, 0.8, 0.8, true)
                    else
                        GameTooltip:SetText(overrideInfo and overrideInfo.name or "Unknown", 1, 1, 1)
                        GameTooltip:AddLine("Base spell: " .. (baseInfo and baseInfo.name or "Unknown") .. " - " .. tostring(baseSpellID), 0.8, 0.8, 0.8, true)
                    end
                    GameTooltip:AddLine("State Key: " .. entry.trackerKey, 0.8, 0.8, 0.8, true)
                    for _, match in ipairs(stateMatches) do
                        local matchText
                        if match.kind == "base" then
                            matchText = "This entry's base spell ID currently exists in another entry as that entry's base spell ID"
                        elseif match.kind == "associated" then
                            matchText = "An associated spell ID " .. tostring(match.value) .. ", from this entry currently exists in another entry as one of its associated spells"
                        else
                            matchText = "An additional aura spell ID from this entry currently exists in another entry as one of its additional aura spell IDs"
                        end
                        GameTooltip:AddLine(matchText, 1, 0.7, 0.3, true)
                        GameTooltip:AddLine(
                            "The entry it matched with is stored with the key " .. tostring(match.trackerKey)
                                .. " and is currently " .. match.status,
                            0.8, 0.8, 0.8, true
                        )
                    end
                    GameTooltip:Show()
                end)
                button:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
            end

            currentYOffset = currentYOffset
                + math.ceil(#group.entries / iconsPerRow) * (iconSize + iconPadding)
                + iconPadding
        end
    end

    gridChild:SetSize(math.max(gridSF:GetWidth(), 1), math.max(currentYOffset, 1))

    if #disabledValues == 0 then
        local emptyLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        emptyLabel:SetPoint("TOPLEFT", gridSF, "TOPLEFT", 0, -8)
        emptyLabel:SetText("No disabled values")
        emptyLabel:SetTextColor(0.5, 0.5, 0.5)
    end
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
    SpellStyler.IconSettingsRenderer:HideSelectedIconHeader()

    local parentScrollFrame = parent:GetParent()
    if parentScrollFrame and parentScrollFrame.GetHeight then
        parent:SetHeight(parentScrollFrame:GetHeight())
        parentScrollFrame:SetVerticalScroll(0)
    end

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
    local addBtnTooltip = nil
    local activeAddType = nil
    local addDisabledReason = nil

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

    local function AddSpellIdentityIDs(ids, spellID)
        if not spellID then return end
        ids[tostring(spellID)] = spellID

        local baseSpellID = C_Spell.GetBaseSpell(spellID, GetSpecialization())
        if baseSpellID then
            ids[tostring(baseSpellID)] = baseSpellID
        end

        local overrideSpellID = C_Spell.GetOverrideSpell(spellID, GetSpecialization())
        if overrideSpellID then
            ids[tostring(overrideSpellID)] = overrideSpellID
        end
    end

    local function GetTrackerIdentityIDs(trackerConfig, trackerType)
        local ids = {}
        AddSpellIdentityIDs(ids, trackerConfig and trackerConfig.baseSpellID)
        AddSpellIdentityIDs(ids, trackerConfig and trackerConfig.overrideSpellID)

        if trackerType == "spells" then
            for spellID in pairs(SpellStyler.State:GetAssociatedSpellIDs(trackerConfig)) do
                AddSpellIdentityIDs(ids, spellID)
            end
        end

        return ids
    end

    local function FindMatchingTracker(spellID, trackerType)
        if not spellID then return end

        local targetIDs = {}
        AddSpellIdentityIDs(targetIDs, spellID)
        for trackerKey, trackerConfig in pairs(
            SpellStyler.State:GetAllTrackerValues(trackerType) or {}
        ) do
            for targetID in pairs(targetIDs) do
                if GetTrackerIdentityIDs(trackerConfig, trackerType)[targetID] then
                    return trackerKey, trackerConfig
                end
            end
        end
    end

    local function FindSharedSpellTracker(spellID)
        local baseSpellID = C_Spell.GetBaseSpell(spellID, GetSpecialization())
        local trackerKey, trackerConfig = FindMatchingTracker(spellID, "spells")
        local matchedByOverride = false
        local overrideSpellID = C_Spell.GetOverrideSpell(spellID, GetSpecialization())
        if trackerConfig and overrideSpellID and tostring(overrideSpellID) ~= tostring(spellID) then
            local trackerIDs = GetTrackerIdentityIDs(trackerConfig, "spells")
            matchedByOverride = trackerIDs[tostring(overrideSpellID)] ~= nil
        end
        return trackerKey, trackerConfig, baseSpellID, matchedByOverride
    end

    local function GetSpellDuplicateReason(spellID, trackerConfig, matchedByOverride)
        if matchedByOverride then
            local overrideSpellID = C_Spell.GetOverrideSpell(spellID, GetSpecialization())
            local overrideInfo = overrideSpellID and C_Spell.GetSpellInfo(overrideSpellID)
            local overrideName = (overrideInfo and overrideInfo.name)
                or tostring(overrideSpellID)
            return "This spell's override is currently "
                .. overrideName .. ", which is already tracked."
        end
        return "This spell is already tracked."
    end

    local function FindMatchingItemTracker(itemID, associatedItemQualities)
        if not itemID then return end

        local candidateIDs = {
            [tostring(itemID)] = true,
        }
        for _, record in ipairs(
            associatedItemQualities
                or (selectedEntry and selectedEntry.associatedItemQualities)
                or {}
        ) do
            candidateIDs[tostring(record.itemID)] = true
        end

        for trackerKey, trackerConfig in pairs(
            SpellStyler.State:GetAllTrackerValues("items") or {}
        ) do
            local trackedIDs = {}
            if trackerConfig.itemID then
                trackedIDs[tostring(trackerConfig.itemID)] = true
            end
            for _, record in ipairs(trackerConfig.associatedItemQualities or {}) do
                trackedIDs[tostring(record.itemID)] = true
            end
            for candidateID in pairs(candidateIDs) do
                if trackedIDs[candidateID] then
                    return trackerKey, trackerConfig
                end
            end
        end

        local _, spellID = C_Item.GetItemSpell(itemID)
        return spellID and FindMatchingTracker(spellID, "items")
    end

    local function GetItemDuplicateReason(itemID, trackerConfig)
        local resolved = SpellStyler.State.items.GetOwnedItemQuality(
            itemID,
            trackerConfig and trackerConfig.associatedItemQualities
        )
        local resolvedItemID = resolved and resolved.itemID or itemID
        local quality = resolved and resolved.qualityLevel or SpellStyler.State.items.GetItemQuality(resolvedItemID)
        local count = C_Item.GetItemCount(resolvedItemID, true, true)
        return "This item is already tracked. You currently have "
            .. tostring(count or 0)
            .. " at quality level "
            .. tostring(quality or "unknown")
    end

    local function IsTrackerEnabled(trackerConfig, spellID)
        if not trackerConfig then return false end
        if spellID then
            local association = SpellStyler.State:GetAssociatedSpellID(trackerConfig, spellID)
            return association ~= nil and association.enabled == true
        end
        for _, association in pairs(SpellStyler.State:GetAssociatedSpellIDs(trackerConfig)) do
            if association.enabled == true then
                return true
            end
        end

        return trackerConfig.isEnabled ~= false
    end

    local function AddSearchableSpell(spellsByID, spellID)
        if spellID and not spellsByID[spellID] and not C_Spell.IsSpellPassive(spellID)
        then
            local spellInfo = C_Spell.GetSpellInfo(spellID)
            if spellInfo and spellInfo.name then
                spellsByID[spellID] = spellInfo
            end
        end
    end

    local function GetSearchableSpellInfos()
        local spellsByID = {}
        local currentSpecID = SpellStyler.State and SpellStyler.State.GetCurrentSpecID
            and SpellStyler.State:GetCurrentSpecID()

        -- Only General and the current specialization's spellbook are searchable.
        local numLines = C_SpellBook.GetNumSpellBookSkillLines()
        for lineIndex = 1, numLines do
            local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(lineIndex)
            local isGeneral = lineInfo and lineInfo.specID == nil
            local isCurrentSpec = lineInfo and currentSpecID
                and lineInfo.specID == currentSpecID
            if lineInfo and not lineInfo.isGuild and (isGeneral or isCurrentSpec) then
                local firstItem = lineInfo.itemIndexOffset + 1
                local lastItem = firstItem + lineInfo.numSpellBookItems - 1
                for itemIndex = firstItem, lastItem do
                    local spellBookInfo = C_SpellBook.GetSpellBookItemInfo(
                        itemIndex,
                        Enum.SpellBookSpellBank.Player
                    )
                    if spellBookInfo and spellBookInfo.itemType == Enum.SpellBookItemType.Spell then
                        local spellID = spellBookInfo.spellID or spellBookInfo.actionID
                        AddSearchableSpell(spellsByID, spellID)
                    end
                end
            end
        end

        -- Talent definitions expose spell IDs even when their nodes are unselected.
        if C_ClassTalents and C_Traits then
            local configID = C_ClassTalents.GetActiveConfigID()
            local configInfo = configID and C_Traits.GetConfigInfo(configID)
            for _, treeID in ipairs((configInfo and configInfo.treeIDs) or {}) do
                for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
                    local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                    for _, entryID in ipairs((nodeInfo and nodeInfo.entryIDs) or {}) do
                        local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                        local definitionInfo = entryInfo and entryInfo.definitionID
                            and C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                        if definitionInfo then
                            AddSearchableSpell(spellsByID, definitionInfo.spellID)
                            AddSearchableSpell(spellsByID, definitionInfo.overriddenSpellID)
                        end
                    end
                end
            end
        end

        return spellsByID
    end

    local function FindExactSpellByText(text)
        local searchText = string.lower(text)
        for _, spellInfo in pairs(GetSearchableSpellInfos()) do
            if string.lower(spellInfo.name) == searchText then
                return spellInfo
            end
        end
    end

    local function UpdateAddButtonState(shouldEnable)
        if not addBtn then return end
        if shouldEnable then
            addDisabledReason = nil
            addBtn:Enable()
            if addBtnTooltip then addBtnTooltip:Hide() end
        else
            addBtn:Disable()
            if addBtnTooltip then addBtnTooltip:Show() end
        end
    end

    local function UpdateAddButtonLabel(entryType)
        activeAddType = entryType
        if not addBtn then return end
        local labels = {
            spell = "Spell",
            item = "Item",
            aura = "Aura",
        }
        addBtn:SetText(entryType and ("Add " .. labels[entryType]) or "Add")
    end

    local function Deselect()
        if selectedBtn and SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:StopAnts(selectedBtn)
        end
        selectedEntry = nil
        selectedType  = nil
        selectedBtn   = nil
        addDisabledReason = nil
        UpdateAddButtonLabel(nil)
        UpdateAddButtonState(false)
    end

    local function IsAuraBaseSpellTracked(spellID)
        local baseSpellID = C_Spell.GetBaseSpell(spellID) or spellID
        for _, trackerConfig in pairs(SpellStyler.State:GetAllTrackerValues("buffs") or {}) do
            if trackerConfig.baseSpellID
                and tostring(trackerConfig.baseSpellID) == tostring(baseSpellID) then
                return true
            end
        end
        return false
    end

    local function SelectEntry(entry, entryType, btn)
        -- deselect old
        if selectedBtn and SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:StopAnts(selectedBtn)
        end
        selectedEntry = entry
        selectedType  = entryType
        selectedBtn   = btn
        UpdateAddButtonLabel(entryType)
        if SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:SetupAnts(btn, { r = 1, g = 0.82, b = 0 })
            SpellStyler.GlowUtil:PlayAnts(btn)
        end
        if addBtn then
            local trackerConfig
            local isAlreadyTracked = false
            local matchedByOverride = false
            if entryType == "spell" then
                local _, matchedConfig, _, overrideMatch = FindSharedSpellTracker(entry.spellID)
                trackerConfig = matchedConfig
                isAlreadyTracked = trackerConfig ~= nil
                    and IsTrackerEnabled(trackerConfig, entry.spellID)
                matchedByOverride = overrideMatch
            elseif entryType == "item" and entry.itemID then
                local _, matchedConfig = FindMatchingItemTracker(entry.itemID)
                trackerConfig = matchedConfig
                isAlreadyTracked = trackerConfig ~= nil
                    and trackerConfig.isEnabled ~= false
            end
            if entryType == "aura" then
                local _, auraConfig = FindMatchingTracker(entry.spellID, "buffs")
                trackerConfig = auraConfig
                isAlreadyTracked = auraConfig ~= nil and auraConfig.isEnabled ~= false
            end
            if isAlreadyTracked then
                addDisabledReason = entryType == "aura"
                    and "This aura is already tracked."
                    or entryType == "item"
                        and GetItemDuplicateReason(entry.itemID, trackerConfig)
                        or GetSpellDuplicateReason(entry.spellID, trackerConfig, matchedByOverride)
                UpdateAddButtonState(false)
            else
                addDisabledReason = nil
                UpdateAddButtonState(true)
            end
        end
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
            UpdateAddButtonLabel(entryType)
            if entryType == "aura" then
                FilterAndLayoutSafe("", gridSF:GetWidth())
            end
            UpdatePreview(entryType, self:GetText())
        end)

        editBox:SetScript("OnTextChanged", function(self)
            UpdateAddButtonLabel(entryType)
            UpdatePreview(entryType, self:GetText())
            if entryType == "aura" then
                FilterAndLayoutSafe("", gridSF:GetWidth())
            else
                FilterAndLayoutSafe(self:GetText(), gridSF:GetWidth())
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
                UpdateAddButtonState(true)
            else
                UpdateAddButtonState(false)
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
                GameTooltip:SetText(previewEntry.name or "Unknown", 1, 1, 1)
                GameTooltip:AddLine("Item ID: " .. tostring(previewEntry.itemID), 0.8, 0.8, 0.8, true)
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
    addBtn:SetSize(82, 22)
    addBtn:SetPoint("LEFT", previewBtn, "RIGHT", 8, (PREVIEW_SIZE - 22) / 2)
    addBtn:SetText("Add")
    addBtn:Disable()
    local function ShowAddDisabledTooltip(owner)
        if addDisabledReason then
            GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
            GameTooltip:SetText(addDisabledReason, 1, 1, 1, 1, true)
            GameTooltip:Show()
        elseif selectedType == "item" and selectedEntry then
            local _, trackerConfig = FindMatchingItemTracker(selectedEntry.itemID)
            if trackerConfig and trackerConfig.isEnabled ~= false then
                addDisabledReason = GetItemDuplicateReason(selectedEntry.itemID, trackerConfig)
                GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
                GameTooltip:SetText(addDisabledReason, 1, 1, 1, 1, true)
                GameTooltip:Show()
            end
        elseif selectedType == "spell" and selectedEntry then
            local _, trackerConfig, baseSpellID, matchedByOverride =
                FindSharedSpellTracker(selectedEntry.spellID)
            if IsTrackerEnabled(trackerConfig, selectedEntry.spellID) then
                if matchedByOverride then
                    addDisabledReason = GetSpellDuplicateReason(
                        selectedEntry.spellID,
                        trackerConfig,
                        matchedByOverride
                    )
                    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
                    GameTooltip:SetText(addDisabledReason, 1, 1, 1, 1, true)
                    GameTooltip:Show()
                    return
                end
                local currentSpellID = C_Spell.GetOverrideSpell(baseSpellID)
                local spellInfo = currentSpellID and C_Spell.GetSpellInfo(currentSpellID)
                local spellName = (spellInfo and spellInfo.name) or tostring(currentSpellID or baseSpellID)
                GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
                GameTooltip:SetText("This spell is already tracked. It may likely be overwritten or transformed into another spell. It currently appears to be " .. spellName, 1, 1, 1)
                GameTooltip:Show()
            end
        end
    end
    addBtn:SetScript("OnEnter", function(self) ShowAddDisabledTooltip(self) end)
    addBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    addBtnTooltip = CreateFrame("Frame", nil, container)
    addBtnTooltip:SetAllPoints(addBtn)
    addBtnTooltip:SetFrameStrata(addBtn:GetFrameStrata())
    addBtnTooltip:SetFrameLevel(addBtn:GetFrameLevel() + 10)
    addBtnTooltip:EnableMouse(true)
    addBtnTooltip:SetScript("OnEnter", function(self) ShowAddDisabledTooltip(self) end)
    addBtnTooltip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    addBtnTooltip:Hide()
    addBtn:SetScript("OnClick", function()
        if not selectedEntry or not selectedType then return end
        if selectedType == "spell" then
            local existingKey, existingConfig = FindSharedSpellTracker(selectedEntry.spellID)
            if existingKey then
                if not State:IsTrackerEnabled(existingConfig) then
                    State:ReenableTrackerValue(existingKey, "spells")
                    if SpellStyler.settingsContentFrame then
                        SpellStyler.IconSettingsRenderer:RenderIconControlView(SpellStyler.settingsContentFrame)
                    end
                end
                return
            end
        elseif selectedType == "item" and selectedEntry.itemID then
            local existingKey, existingConfig = FindMatchingItemTracker(selectedEntry.itemID)
            if existingKey then
                if not State:IsTrackerEnabled(existingConfig) then
                    State:ReenableTrackerValue(existingKey, "items")
                    if SpellStyler.settingsContentFrame then
                        SpellStyler.IconSettingsRenderer:RenderIconControlView(SpellStyler.settingsContentFrame)
                    end
                end
                return
            end
        elseif selectedType == "aura" then
            local BuffManager = SpellStyler.BuffManager
            local trackingID = C_Spell.GetBaseSpell(selectedEntry.spellID) or selectedEntry.spellID
            local existingTrackerConfig, foundConfig = State:GetSpecificTrackerValue(trackingID, "buffs")
            if existingTrackerConfig and foundConfig then
                State:SetTrackerValueConfigProperty(trackingID, "buffs", 'isEnabled', true)
                -- If you are readding an aura, flag the aura as being applicable for the current specID
                State:SetTrackerValueConfigProperty(trackingID, "buffs", 'auraSpecs.' .. State:GetCurrentSpecID(), true)
                if BuffManager.buffContainers[trackingID] then
                    BuffManager:UpdateAura(BuffManager.buffContainers[trackingID], existingTrackerConfig)
                end
                return
            end
        end
        local FTM   = SpellStyler.FrameTrackerManager
        local State = SpellStyler.State

        local trackingID
        local trackerConfig
        local trackerType

        if selectedType == "spell" then
            trackerType = "spells"
            local iconTexture = selectedEntry.iconID
            local baseSpellID = C_Spell.GetBaseSpell(selectedEntry.spellID, GetSpecialization())
                or selectedEntry.spellID
            trackingID = baseSpellID
            trackerConfig = State:AddTrackerValue({
                trackerKey              = baseSpellID,
                baseSpellID             = baseSpellID,
                overrideSpellID         = C_Spell.GetOverrideSpell(baseSpellID),
                trackerType             = "spells",
                name                    = selectedEntry.name,
                defaultIconTexturePath  = iconTexture,
            })
            local function enableSpellID(spellID)
                if spellID and (C_SpellBook.IsSpellKnown(spellID) or C_SpellBook.IsSpellInSpellBook(spellID)) then
                    State:UpdateAssociatedSpells(trackerConfig, spellID, { enabled = true })
                end
            end
            enableSpellID(baseSpellID)
            enableSpellID(C_Spell.GetOverrideSpell(baseSpellID, GetSpecialization(), true))
        elseif selectedType == "item" then
            trackerType = "items"

            -- If this came from an equipped slot picker, key the DB by the slot name
            -- (e.g. "head", "finger1") and use the current item data for the config.
            if selectedEntry.isSlotEntry then
                local itemID = selectedEntry.itemID
                local _, spellID = C_Item.GetItemSpell(itemID)
                trackingID = selectedEntry.slotKey

                
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
                    associatedItemQualities = selectedEntry.associatedItemQualities or {},
                })
            else
                -- Normal item search results use the item ID when an item has no
                -- usable spell ID, such as some potion variants.
                local spellName, spellID = C_Item.GetItemSpell(selectedEntry.itemID)
                trackingID = spellID or selectedEntry.itemID

                local iconTexture = selectedEntry.iconID or C_Item.GetItemIconByID(selectedEntry.itemID)
                trackerConfig = State:AddTrackerValue({
                    trackerKey              = trackingID,
                    itemID                  = selectedEntry.itemID,
                    baseSpellID             = spellID or selectedEntry.itemID,
                    overrideSpellID         = spellID or selectedEntry.itemID,
                    trackerType             = "items",
                    name                    = selectedEntry.name,
                    defaultIconTexturePath  = iconTexture,
                    isItem                  = true,
                    associatedItemQualities = selectedEntry.associatedItemQualities or {},
                })
            end
        elseif selectedType == "aura" then
            trackerType = "buffs"
            
            -- Track aura by baseSpellID
            trackingID = C_Spell.GetBaseSpell(selectedEntry.spellID, GetSpecialization())
                or selectedEntry.spellID
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
                    [State:GetCurrentSpecID()] = true
                }
            })
        end

        if not trackerConfig then return end

        -- Wipe devNotes before creating frame (fresh start for error tracking)
        State:SetTrackerValueConfigProperty(trackingID, trackerType, "devNotes", {})

        if selectedType == "aura" then
            local BuffManager = SpellStyler.BuffManager
            if BuffManager and BuffManager.CreateSingleAuraContainer then
                BuffManager:CreateSingleAuraContainer(trackingID, trackerConfig)
                if SpellStyler.settingsMenu
                    and SpellStyler.settingsMenu:IsShown()
                    and BuffManager.EnablePlaceholderDragging then
                    BuffManager:EnablePlaceholderDragging(true)
                end
            end
        else
            -- CreateFrameMiddleware creates base frame, variant frame (if needed),
            -- sets up charge infrastructure, and drives updates
            FTM.FrameBuilder.CreateCompleteFrame(trackingID, trackerConfig, trackerType)

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
    gridSF:SetPoint("TOPLEFT",  sep, "BOTTOMLEFT",  -GLOW_PAD,  -4)
    gridSF:SetPoint("TOPRIGHT", sep, "BOTTOMRIGHT",  4,          -4)
    gridSF:SetPoint("BOTTOM",   container, "BOTTOM",  0,           8)

    local gridChild = CreateFrame("Frame", nil, gridSF)
    gridSF:SetScrollChild(gridChild)
    local spellsLabel = gridChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spellsLabel:SetText("Spells")
    spellsLabel:SetTextColor(1, 0.82, 0)
    local itemsLabel = gridChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemsLabel:SetText("Items")
    itemsLabel:SetTextColor(1, 0.82, 0)
    
    -- Reset scroll position and enable scrolling
    gridSF:SetVerticalScroll(0)
    gridSF:EnableMouseWheel(true)

    -- ── Build buttons for every spell and item ────────────────────────
    local spells = AddSpells:GetCurrentSpecSpells()
    local knownSpellIDs = {}
    for _, spell in ipairs(spells) do
        knownSpellIDs[spell.spellID] = true
    end
    for spellID, spellInfo in pairs(GetSearchableSpellInfos()) do
        if not knownSpellIDs[spellID] then
            table.insert(spells, {
                spellID = spellID,
                name = spellInfo.name,
                iconID = spellInfo.originalIconID or spellInfo.iconID,
            })
        end
    end
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
            tex:SetTexture(SpellStyler.State.items.GetOwnedItemIcon(item.itemID, item.associatedItemQualities, item.iconID))
            tex:SetTexCoord(0, 1, 0, 1)
            SpellStyler.FrameTrackerManager.utils.ApplyItemQualityOverlay(item.itemID, btn, item.associatedItemQualities, true)

            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.25)

            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(capturedItem.name or "Unknown", 1, 1, 1)
                GameTooltip:AddLine("Item ID: " .. tostring(capturedItem.itemID), 0.8, 0.8, 0.8, true)
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
        local rowHeight = iconSize + GRID_GAP
        spellsLabel:Show()
        spellsLabel:SetPoint("TOPLEFT", gridChild, "TOPLEFT", GLOW_PAD, -4)

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
                        -(GLOW_PAD + row * rowHeight + 8)
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
            row = row + 1.5
        else
            col = 0
            row = row + 0.5
        end
        itemsLabel:Show()
        itemsLabel:SetPoint(
            "TOPLEFT",
            gridChild,
            "TOPLEFT",
            GLOW_PAD,
            -(GLOW_PAD + row * rowHeight)
        )
        row = row + 0.5
        
        -- Second pass: layout items
        for _, entry in ipairs(gridButtons) do
            if entry.type == "item" then
                local btn = entry.btn
                local matches = (filterText == "")
                    or entry.data.name:lower():find(lower, 1, true)
                if matches then
                    btn:SetSize(iconSize, iconSize)
                    SpellStyler.FrameTrackerManager.utils.ApplyItemQualityOverlay(
                        entry.data.itemID,
                        btn,
                        entry.data.associatedItemQualities,
                        true
                    )
                    btn:ClearAllPoints()
                    btn:SetPoint("TOPLEFT", gridChild, "TOPLEFT",
                        GLOW_PAD + col * (iconSize + GRID_GAP),
                        -(GLOW_PAD + row * rowHeight)
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
                if si and (not C_Spell.IsSpellPassive(id) or entryType == "buffs") then
                    local iconID = C_Spell.GetSpellTexture(id) or si.iconID
                    found = { spellID = id, name = si.name, iconID = iconID }
                end
            else
                local finalMatch = FindExactSpellByText(text)
                if not finalMatch and entryType == "aura" then
                    local spellInfo = C_Spell.GetSpellInfo(text)
                    local spellID = spellInfo and (spellInfo.spellID
                        or C_Spell.GetSpellIDForSpellIdentifier(text))
                    if spellInfo and spellID then
                        finalMatch = {
                            spellID = spellID,
                            name = spellInfo.name,
                            iconID = spellInfo.iconID,
                        }
                    end
                end
                if finalMatch then
                    local iconID = finalMatch.originalIconID or finalMatch.iconID
                    found = {
                        spellID = finalMatch.spellID,
                        name = finalMatch.name,
                        iconID = iconID
                    }
                end
            end
        end

        if found then
            if entryType == "item" and found.itemID then
                found.associatedItemQualities = found.associatedItemQualities or {}
                SpellStyler.State.items.GetOwnedItemQuality(found.itemID, found.associatedItemQualities)
            end
            previewEntry, previewType = found, entryType
            UpdateAddButtonLabel(entryType)
            previewTex:SetTexture(entryType == "item"
                and SpellStyler.State.items.GetOwnedItemIcon(
                    found.itemID,
                    found.associatedItemQualities,
                    found.iconID
                )
                or found.iconID)
            if entryType == "item" then
                SpellStyler.FrameTrackerManager.utils.ApplyItemQualityOverlay(
                    found.itemID,
                    previewBtn,
                    found.associatedItemQualities,
                    true
                )
            else
                SpellStyler.FrameTrackerManager.utils.ApplyItemQualityOverlay(nil, previewBtn)
            end
            previewBtn:Show()

            local isAlreadyTracked = false
            local matchedByOverride = false
            if entryType == "aura" then
                local auraKey, auraConfig = FindMatchingTracker(found.spellID, "buffs")
                isAlreadyTracked = auraKey ~= nil and auraConfig.isEnabled ~= false
            elseif entryType == "spell" then
                local _, trackerConfig, _, overrideMatch = FindSharedSpellTracker(found.spellID)
                isAlreadyTracked = trackerConfig ~= nil
                    and IsTrackerEnabled(trackerConfig, found.spellID)
                matchedByOverride = overrideMatch
                if matchedByOverride then
                    addDisabledReason = GetSpellDuplicateReason(
                        found.spellID,
                        trackerConfig,
                        matchedByOverride
                    )
                end
            elseif entryType == "item" then
                local _, trackerConfig = FindMatchingItemTracker(
                    found.itemID,
                    found.associatedItemQualities
                )
                isAlreadyTracked = trackerConfig ~= nil and trackerConfig.isEnabled ~= false
            end
            if isAlreadyTracked then
                if entryType ~= "spell" or not matchedByOverride then
                    addDisabledReason = entryType == "aura"
                        and "This aura is already tracked."
                        or entryType == "item"
                        and GetItemDuplicateReason(found.itemID, trackerConfig)
                        or "This spell is already tracked."
                end
                UpdateAddButtonState(false)
            else
                addDisabledReason = nil
                UpdateAddButtonState(true)
            end

            -- If the previously glow-selected btn was this preview icon,
            -- re-apply glow since SetupAnts was called on it before Show
            if selectedBtn == previewBtn then
                SpellStyler.GlowUtil:SetupAnts(previewBtn, { r = 1, g = 0.82, b = 0 })
                SpellStyler.GlowUtil:PlayAnts(previewBtn)
            end
        else
            previewEntry, previewType = nil, nil
            addDisabledReason = nil
            UpdateAddButtonState(false)
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
