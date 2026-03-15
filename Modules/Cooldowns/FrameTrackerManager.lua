-- ============================================================================
-- SpellStyler FrameTrackerManager.lua
-- Creates positionable highlight clones for tracker buffs
-- Detects active/inactive state via auraInstanceID (no secret value math)
-- ============================================================================

local addonName, SpellStyler = ...
SpellStyler.FrameTrackerManager = SpellStyler.FrameTrackerManager or {}
local FrameTrackerManager = SpellStyler.FrameTrackerManager
local FRAME_PREFIX = "TweaksUI_CustomFrameTracker_"

---@class TrackerFrameMeta
---@field activeSpellID number          The active spell ID (may differ from uniqueID when a spec overrides the spell)
---@field isSpellWithCharges boolean    true if the spell has more than one max charge
---@field spellChargeCount number       Max charge count (or 1 for non-charge spells)'moreThenOneChargeOnCooldown'
---@field isDurationActive boolean      true while a real cooldown is running
---@field isSpellOffGCD boolean|nil     true if the spell bypasses the GCD
---@field mockCooldownActive boolean    true while a mock cooldown preview is running (settings UI)
---@field canBeCast boolean             true when not on cooldown with all charges consumed
---@field spellHasCharges boolean       true when the spell currently has at least one charge available
---@field currentAuraInstanceID number  Instance ID of the currently tracked aura (buffs tracker type)
---@field customTexture string|nil         Custom texture of the icon

-- ============================================================================

-- ============================================================================


-- ============================================================================
-- STATE
-- ============================================================================
local cooldownManagerFrames = {
    buffs = {},
    essential = {},
    utility = {}
}

local SpellStyler_frames = {
    buffs = {},
    essential = {},
    utility = {}
}

local currentlyChanneledSpellData = {
    channelStatus = 'noActiveChannel', --'isActivlyChanneling', 'channelJustEnded'
    spellID = nil,
    inDetectionPeriod = false,
    --channelCooldownType = 'immediate', --'delayed',  assume its immediately applying the actual spell duration. This can be updated during channel if its type is one that shows the channel duration THEN the cooldown after its ended
    trackerType = nil,
}

-- Cache of spell IDs that are known to be off the GCD (isOnGCD is nil when they go on cooldown).
-- Built at runtime the first time we observe a real cooldown with isOnGCD == nil.
-- Used by the SetCooldown hook and other places that need to distinguish off-GCD spells.
local offGCDSpellCache = {}

-- updateFrame is defined in the UPDATE SYSTEM section
local isInitialized = false

local function accessNestedValue(tbl, path, value, action)
    local keys = {}
    for key in string.gmatch(path, "[^.]+") do
        table.insert(keys, key)
    end
    local current = tbl
    for i = 1, #keys - 1 do        
        if current[keys[i]] == nil then
            current[keys[i]] = {}
        end
        current = current[keys[i]]
    end
    
    -- Handle the final key with resolution
    local finalKey = keys[#keys]
    if (action == 'set') then
        current[finalKey] = value
    elseif (action == 'get') then
        return current[finalKey]
    end
end

local function AddNewTrackerValueConfig(data)
    return {
        uniqueID = data.uniqueID,
        trackerType = data.trackerType, -- essential, utility, buffs
        name = data.name,
        defaultIconTexturePath = data.defaultIconTexturePath,
        position = {
            anchorPoint = "center",
            relativeToFrame = nil,
            relativeAnchorPoint = "center",
            x = 0,
            y = 0
        },
        iconColor = {
            r = 1,
            g = 1,
            b = 1,
            a = 1,
        },
        iconSettings = {
            displayCharges = data.trackerType == 'buffs' and true or false,
            iconDisplayState = "always", -- "always", "active/cooldown", "inactive/available", "never"
            iconTexturePath = "",
            desaturated = false,
            enabled = true,
            size = 48,
            opacity = 1,
            hideDefaultSweep = false,
            isSpellOffGCD = false
        },
        customLabel = {
            display = false,
            text = "",
            size = 10,
            x = 0,
            y = 0,
            color = {
                r = 1,
                g = 1,
                b = 1,
                a = 1,
            }
        },
        cooldownText = {
            display = true,
            size = 14,
            color = {
                r = 1,
                g = 1,
                b = 1,
                a = 1,
            },
            x = 0,
            y = 0,
        },
        countText = {
            display = true,
            size = 12,
            color = {
                r = 1,
                g = 1,
                b = 1,
                a = 1,
            },
            x = 0,
            y = 0,
        },
        statusBar = {
            displayState = "never",  -- "always", "active", "inactive", "never"
            defaultBarTexture = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarFill.tga",
            customBarTexture = "",
            onlyRenderBar = false,
            barOrientation = 'horizontal', -- 'vertical'
            fillOrEmpty = 'regular', -- 'inverse'
            progressDirection = 'standard', -- 'reverse'
            defaultFillValue = 'empty', -- 'full'
            color = {
                r = 0.2,
                g = 0.8,
                b = 1,
                a = 0.9,
            },
            backgroundColor = {
                r = 0,
                g = 0,
                b = 0,
                a = 0.65,
            },
            glowColor = {
                r = 1,
                g = 1,
                b = 1,
                a = 0.25,
            },
            borderColor = {
                r = 0,
                g = 0,
                b = 0,
                a = 1,
            },
            borderScale = 0.5,
            scale = 1,
            x = 0,
            y = 0,
            width = 200,
            height = 20,
            rotation = 0,
            anchorParent = "RIGHT",
            anchorSelf = "LEFT"
        },
        showProcGlow = true  -- Show spell activation glow
    }
end
local _cachedSpecID = nil
function FrameTrackerManager:GetCurrentSpecID()
    local specIndex = GetSpecialization()
    if specIndex then
        local specID = GetSpecializationInfo(specIndex)
        if specID then
            _cachedSpecID = specID
            return specID
        end
    end
    -- During loading screens GetSpecialization() returns nil; fall back to last known spec
    return _cachedSpecID
end
function FrameTrackerManager:GetDataBase_V2()
    local classSpecialization = FrameTrackerManager:GetCurrentSpecID()
    if not SpellStyler_CharDB.classSpecializations then 
        SpellStyler_CharDB.classSpecializations = {} 
    end
    
    -- Initialize spec table if it doesn't exist
    if not SpellStyler_CharDB.classSpecializations[classSpecialization] then
        SpellStyler_CharDB.classSpecializations[classSpecialization] = {}
    end
    
    local specDB = SpellStyler_CharDB.classSpecializations[classSpecialization]
    
    -- Initialize tracker type tables
    specDB.buffs = specDB.buffs or {}
    specDB.essential = specDB.essential or {}
    specDB.utility = specDB.utility or {}
    specDB.docks = specDB.docks or {}
    
    return specDB
    --[[
    ============================================================================
        classSpecializations = {
            [specID] = {
                buffs = {},
                essential = {},
                utility = {},
            }
        }
    --]]
end

function FrameTrackerManager:HandleTalentChange()
    -- Re-hook all buff cooldown frames
    for _, tType in ipairs({"buffs", "essential", "utility"}) do
        FrameTrackerManager:HookAllBuffCooldownFrames(tType)
        FrameTrackerManager:ApplyViewerVisibility(tType)
    end

    -- Re-layout containers for the newly active spec
    if SpellStyler.Containers then
        local containers = SpellStyler.Containers:GetDB()
        for containerName in pairs(containers) do
            SpellStyler.Containers:LayoutContainer(containerName)
        end
    end

    -- Update settings menu if it's open
    if SpellStyler.settingsMenu and SpellStyler.settingsMenu:IsShown() and SpellStyler.settingsContentFrame then
        SpellStyler.IconSettingsRenderer:RenderIconControlView(SpellStyler.settingsContentFrame)
        if FrameTrackerManager.EnableDraggingForAllFrames then
            FrameTrackerManager:EnableDraggingForAllFrames()
        end
    end
end

function FrameTrackerManager:AddTrackerValue(trackerValueConstructorData)
    local db = FrameTrackerManager:GetDataBase_V2()
    local trackerType = trackerValueConstructorData.trackerType or "buffs"
    db[trackerType][trackerValueConstructorData.uniqueID] = AddNewTrackerValueConfig(trackerValueConstructorData)
    return db[trackerType][trackerValueConstructorData.uniqueID]
end

function FrameTrackerManager:ResetTrackerValueConfig(uniqueID, trackerType)
    local db = FrameTrackerManager:GetDataBase_V2()
    local existing = db[trackerType] and db[trackerType][uniqueID]
    if not existing then return end
    -- Rebuild from defaults, preserving identity fields
    local defaults = AddNewTrackerValueConfig({
        uniqueID = uniqueID,
        trackerType = trackerType,
        name = existing.name,
        defaultIconTexturePath = existing.defaultIconTexturePath,
    })
    db[trackerType][uniqueID] = defaults
    -- Refresh the live frame if it exists
    if SpellStyler_frames[trackerType] and SpellStyler_frames[trackerType][uniqueID] then
        FrameTrackerManager:UpdateFrame_ConfigurationChanges(uniqueID, trackerType)
        FrameTrackerManager:UpdateFrame_copyCharges({
            customFrame = SpellStyler_frames[trackerType][uniqueID],
            config = existing,
            uniqueID = uniqueID,
            trackerType = trackerType
        })
    end
end

function FrameTrackerManager:GetAllTrackerValues(trackerType)
    local db = FrameTrackerManager:GetDataBase_V2()
    if not db then return {} end
    return db[trackerType]
end

function FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
    local db = FrameTrackerManager:GetDataBase_V2()
    local iconConfig = db[trackerType][uniqueID] or {}
    -- Migrate legacy barFillDirection -> fillOrEmpty (one-time per-entry migration)
    if iconConfig.statusBar and iconConfig.statusBar.barFillDirection ~= nil and iconConfig.statusBar.fillOrEmpty == nil then
        iconConfig.statusBar.fillOrEmpty = iconConfig.statusBar.barFillDirection
        iconConfig.statusBar.barFillDirection = nil
    end
    return iconConfig
end

function FrameTrackerManager:CheckIsAlreadyTracker(uniqueID, trackerType)
    local db = FrameTrackerManager:GetDataBase_V2()
    return db[trackerType][uniqueID] and true or false
end

function FrameTrackerManager:RemoveTrackerValue(uniqueID, trackerType)
    local db = FrameTrackerManager:GetDataBase_V2()
    if FrameTrackerManager:CheckIsAlreadyTracker(uniqueID, trackerType) then
        -- Clean up the frame
        local frame = SpellStyler_frames[trackerType][uniqueID]
        if frame then
            frame:Hide()
            frame:ClearAllPoints()
            SpellStyler_frames[trackerType][uniqueID] = nil
        end
        
        -- Remove from database
        db[trackerType][uniqueID] = nil
    end
end

function FrameTrackerManager:SetTrackerValueConfigProperty(uniqueID, trackerType, path, value)
    local db = FrameTrackerManager:GetDataBase_V2()
    accessNestedValue(db[trackerType][uniqueID], path, value, "set")
    local trackerValue = db[trackerType][uniqueID]
    if trackerValue and SpellStyler_frames[trackerType][uniqueID] then
        FrameTrackerManager:UpdateFrame_ConfigurationChanges(uniqueID, trackerType)
        FrameTrackerManager:UpdateFrame_copyCharges({
            config = trackerValue,
            customFrame = SpellStyler_frames[trackerType][uniqueID],
            uniqueID = uniqueID,
            trackerType = trackerType
        })
    end
end

function FrameTrackerManager:GetTrackerValueConfigProperty(uniqueID, trackerType, path)
    local db = FrameTrackerManager:GetDataBase_V2()
    return accessNestedValue(db[trackerType][uniqueID], path, nil, "get")
end

function FrameTrackerManager:getTrackerValuesListForSettings()
    local listTrackerValues = {}
    for key, value in ipairs({ "buffs", "essential", "utility" }) do
        local trackerValues = FrameTrackerManager:GetAllTrackerValues(value)
        -- Loop through the buffs values
        for uniqueID, trackerValue in pairs(trackerValues) do
            -- Only add frames that are currently tracked by the cooldown manager
            if cooldownManagerFrames[value][uniqueID] then
                table.insert(listTrackerValues, {
                    uniqueID = uniqueID,
                    trackerType = trackerValue.trackerType,
                    name = trackerValue.name,
                    defaultIconTexturePath = trackerValue.defaultIconTexturePath
                })
            end
        end
    end
    return listTrackerValues
end


function FrameTrackerManager:CopySettings(copyInfo)
    local key = ''
    if copyInfo.category == 'Icon Settings' then
        key = 'iconSettings'
    elseif copyInfo.category == 'Bar Timer' then
        key = 'statusBar'
    elseif copyInfo.category == 'Cooldown Text' then
        key = 'countText'
    elseif copyInfo.category == 'Count/Charge Text' then
        key = 'cooldownText'
    elseif copyInfo.category == 'Custom Label (Accessibility)' then
        key = 'customLabel'
    end
    
    local sourceConfig = FrameTrackerManager:GetSpecificTrackerValue(copyInfo.sourceUniqueID, copyInfo.sourceTrackerType)
    FrameTrackerManager:SetTrackerValueConfigProperty(copyInfo.targetUniqueID, copyInfo.targetTrackerType, key, sourceConfig[key])
end

-- ============================================================================
-- VISIBILITY CONDITION CHECKING
-- Per-icon highlights should respect the tracker's visibility conditions
-- ============================================================================

-- Get current player state for visibility checks (mirrors Cooldowns.lua logic)
local function GetPlayerState()
    local state = {
        inCombat = InCombatLockdown() or UnitAffectingCombat("player"),
        inGroup = IsInGroup(),
        inRaid = IsInRaid(),
        inInstance = false,
        inArena = false,
        inBattleground = false,
        isSolo = not IsInGroup(),
        hasTarget = UnitExists("target"),
        isMounted = SpellStyler.UnitAPI:IsMountedOrTravelForm(),
    }
    
    -- Check instance type
    local _, instanceType = IsInInstance()
    if instanceType == "party" or instanceType == "raid" then
        state.inInstance = true
    elseif instanceType == "arena" then
        state.inArena = true
    elseif instanceType == "pvp" then
        state.inBattleground = true
    end
    
    return state
end

function FrameTrackerManager:GetCooldownManagerViewer(trackerType)
    local viewers = {
        buffs = _G["BuffIconCooldownViewer"],
        essential = _G["EssentialCooldownViewer"],
        utility = _G["UtilityCooldownViewer"]
    }
    return viewers[trackerType]
end

-- ============================================================================
-- VIEWER VISIBILITY
-- Stored in SpellStyler_DB.hideViewers = { buffs=bool, essential=bool, utility=bool }
-- ============================================================================
function FrameTrackerManager:GetViewerHidden(trackerType)
    if not SpellStyler_DB then return false end
    SpellStyler_DB.hideViewers = SpellStyler_DB.hideViewers or {}
    return SpellStyler_DB.hideViewers[trackerType] or false
end

function FrameTrackerManager:SetViewerHidden(trackerType, hidden)
    if not SpellStyler_DB then return end
    SpellStyler_DB.hideViewers = SpellStyler_DB.hideViewers or {}
    SpellStyler_DB.hideViewers[trackerType] = hidden
end

function FrameTrackerManager:ApplyViewerVisibility(trackerType)
    local viewer = FrameTrackerManager:GetCooldownManagerViewer(trackerType)
    if not viewer then return end
    -- Use alpha instead of Hide/Show so the viewer still exists and fires
    -- cooldown events; hiding it would break cooldown data collection.
    if FrameTrackerManager:GetViewerHidden(trackerType) then
        viewer:SetAlpha(0)
    else
        viewer:SetAlpha(1)
    end
end

local function ScanAndSaveCurrentCooldownManagerFrames(trackerType)
    local viewer = FrameTrackerManager:GetCooldownManagerViewer(trackerType)
    if not viewer then return {} end

    -- Snapshot previously known spellIDs so we can detect removals after the scan
    local previouslyKnown = {}
    for spellID in pairs(cooldownManagerFrames[trackerType]) do
        previouslyKnown[spellID] = true
    end
    local foundInThisScan = {}

    local numChildren = 0
    pcall(function() numChildren = viewer:GetNumChildren() or 0 end)
    local indexUponCollection = 1
    for i = 1, numChildren do
        local child = select(i, viewer:GetChildren())
        if child then
            -- Buffs are grabbed by finding frames that have a spellID, texture, icon frame and cooldown frame.
            local spellID = nil
            local texture = nil
            local icon = child.Icon or child.icon
            local cooldown = child.Cooldown or child.cooldown
            local spellData = {}
            
            -- Try to extract spellID
            local success = pcall(function()
                if child.GetSpellID then
                    spellID = child:GetSpellID()
                elseif child.spellID then
                    spellID = child.spellID or child.spellId or child.SpellID or child.SpellId
                end
                if spellID then
                    local suc, err = pcall(function()
                        local spellInfo = C_Spell.GetSpellInfo(spellID)
                    end)
                    spellData = C_Spell.GetSpellInfo(spellID)
                end
                if icon then
                    texture = (icon.GetTexture and icon:GetTexture()) or icon.texture or spellData.iconID
                end
                child.spellStyler_spellID = spellID
                child.spellStyler_name = spellData.name
                child.spellStyler_texture = texture
                child.spellStyler_indexUponCollection = indexUponCollection
                -- Should be the cooldown that holds the cached info used within the hooks but keeping on the frame as well ^
                cooldown.spellStyler_spellID = spellID
                cooldown.spellStyler_name = spellData.name
                cooldown.spellStyler_texture = texture
                cooldown.spellStyler_indexUponCollection = indexUponCollection
            end)
            --save buffs to state based on the information collected
            if spellID and texture and icon and cooldown then
                -- Store the source frame reference
                cooldownManagerFrames[trackerType][spellID] = child
                foundInThisScan[spellID] = true
                -- Add to database if not already tracked
                if not FrameTrackerManager:CheckIsAlreadyTracker(spellID, trackerType) then
                    FrameTrackerManager:AddTrackerValue({
                        uniqueID = spellID,
                        defaultIconTexturePath = texture,
                        name = spellData.name,
                        trackerType = trackerType
                    })
                else
                    --make sure it has the correct default texture
                    FrameTrackerManager:SetTrackerValueConfigProperty(spellID, trackerType, 'defaultIconTexturePath', texture)
                end
            end
        end
    end
    
    -- After scanning, create frames for any trackers in database that were scanned but don't have frames yet
    local trackerConfigs = FrameTrackerManager:GetAllTrackerValues(trackerType)
    if trackerConfigs then
        for spellID, trackerConfig in pairs(trackerConfigs) do
            -- Only create frame if this tracker was found during scan AND doesn't already have a frame
            if cooldownManagerFrames[trackerType][spellID] and not SpellStyler_frames[trackerType][spellID] then
                FrameTrackerManager:CreateTrackerFrame(spellID, trackerConfig, trackerType) 
            end
        end
    end

    -- Collect spellIDs that were known before but absent from this scan
    local staleIDs = {}
    for spellID in pairs(previouslyKnown) do
        if not foundInThisScan[spellID] then
            table.insert(staleIDs, spellID)
        end
    end

    -- Delay removal to allow for Blizzard's frame recycling during layout passes
    if #staleIDs > 0 then
        C_Timer.After(0.4, function()
            for _, spellID in ipairs(staleIDs) do
                -- Only remove if still absent (not re-added by a subsequent scan)
                if not foundInThisScan[spellID] then
                    local frame = SpellStyler_frames[trackerType][spellID]
                    if frame then
                        frame:Hide()
                        frame:ClearAllPoints()
                        SpellStyler_frames[trackerType][spellID] = nil
                    end
                    cooldownManagerFrames[trackerType][spellID] = nil
                end
            end
        end)
    end

    -- Apply any saved viewer visibility setting
    FrameTrackerManager:ApplyViewerVisibility(trackerType)
end

-- When onlyRenderBar is true, hides bg/glow/border by zeroing their alpha.
-- When false, restores each element to its correct config alpha via SetVertexColor.
-- The main fill (SetStatusBarTexture) is never touched.

--- @param data ApplyCooldownDurationData
function FrameTrackerManager:ApplyStatusBar_OnlyRenderBar(data)
    if not data.customFrame.statusBar then return end
    local onlyBar = data.config.statusBar.onlyRenderBar

    -- Background texture uses backgroundColor
    if data.customFrame.statusBar.bgTexture then
        local c = data.config.statusBar.backgroundColor
        data.customFrame.statusBar.bgTexture:SetVertexColor(c.r or 0, c.g or 0, c.b or 0, onlyBar and 0 or (c.a or 0.65))
    end

    -- Glow overlay uses glowColor
    if data.customFrame.statusBar.glowTexture then
        local c = data.config.statusBar.glowColor
        data.customFrame.statusBar.glowTexture:SetVertexColor(c.r or 1, c.g or 1, c.b or 1, onlyBar and 0 or (c.a or 0.25))
    end

    -- All 8 border pieces use borderColor
    local bc = data.config.statusBar.borderColor
    local br, bg, bb = bc.r or 0, bc.g or 0, bc.b or 0
    local ba = onlyBar and 0 or (bc.a or 1)
    if data.customFrame.statusBar.borderCornerTL then data.customFrame.statusBar.borderCornerTL:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderCornerTR then data.customFrame.statusBar.borderCornerTR:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderCornerBR then data.customFrame.statusBar.borderCornerBR:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderCornerBL then data.customFrame.statusBar.borderCornerBL:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderEdgeTop    then data.customFrame.statusBar.borderEdgeTop:SetVertexColor(br, bg, bb, ba)    end
    if data.customFrame.statusBar.borderEdgeRight  then data.customFrame.statusBar.borderEdgeRight:SetVertexColor(br, bg, bb, ba)  end
    if data.customFrame.statusBar.borderEdgeBottom then data.customFrame.statusBar.borderEdgeBottom:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderEdgeLeft   then data.customFrame.statusBar.borderEdgeLeft:SetVertexColor(br, bg, bb, ba)   end
end

function FrameTrackerManager:CreateTrackerFrame(uniqueID, trackerConfig, trackerType)
    if SpellStyler_frames[trackerType][uniqueID] then
        return SpellStyler_frames[trackerType][uniqueID]
    end
    local frameName = FRAME_PREFIX .. uniqueID
    local spellChargesInfo = C_Spell.GetSpellCharges(uniqueID)
    local spellInfo = C_Spell.GetSpellInfo(uniqueID)
    local frame = CreateFrame("Button", frameName, UIParent, "BackdropTemplate")
    -- Only set the icon's own size when it is not managed by a container.
    -- LayoutContainer resizes and positions frames that are _inContainer.
    if not frame._inContainer then
        frame:SetSize(trackerConfig.iconSettings.size, trackerConfig.iconSettings.size)
    end
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(100)


    ---@type TrackerFrameMeta
    frame.meta = {
        -- This is either the uniqueID (spellID) or the override spell id (if it changes into something use). Use this value when getting cooldown duration objects.
        activeSpellID = uniqueID,
        -- This helps in conjunction with spellChargeState || spellChargeCount (spellHasCharges) to control the visibility state for count
        isSpellWithCharges = spellChargesInfo and spellChargesInfo.maxCharges > 1,
        -- experimental direct count tracking
        spellChargeCount = spellChargesInfo and spellChargesInfo.maxCharges or 1,
        -- true when the spell currently has at least one charge available
        spellHasCharges = spellChargesInfo and spellChargesInfo.currentCharges > 1 or false,
        -- Used to track if the cooldown is active, so that the cooldowns can be updated in response to other spell casts (Holy Shock can reduce the cooldown of judgment)
        isDurationActive = false,
        -- This helps ensure proper resposne for triggering spell cooldowns for offGCD spells - in "SPELL_UPDATE_COOLDOWN"
        isSpellOffGCD = nil, -- Attempt to automatically identify. Revert to manually flagging with the old setting: trackerConfig.iconSettings.isSpellOffGCD or false,
        mockCooldownActive = false,
        -- true when not on cooldown with all charges consumed
        canBeCast = true,
        -- instance ID of the currently tracked aura (buffs only)
        currentAuraInstanceID = 0,
        customTexture = trackerConfig.iconSettings.iconTexturePath ~= '' and trackerConfig.iconSettings.iconTexturePath ~= nil and trackerConfig.iconSettings.iconTexturePath or nil
    }
    -- Seed the off-GCD cache immediately so the event handler knows before the first cast
    if frame.meta.isSpellOffGCD then
        offGCDSpellCache[uniqueID] = true
    end
    -- Make frame movable for Layout mode
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(false)  -- Don't eat mouse clicks - Layout overlay handles that
    
    
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    
    frame:SetBackdropColor(0, 0, 0, 0)
    frame:SetBackdropBorderColor(0, 0, 0, 0)
    
    -- Icon texture
    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.Icon = frame.icon

    frame.icon:SetPoint("TOPLEFT", 0, 0)
    frame.icon:SetPoint("BOTTOMRIGHT", 0, 0)
    frame.icon:SetTexCoord(0, 1, 0, 1)  -- Crop off edges for cleaner look
    local iconTexture = frame.meta.customTexture or trackerConfig.defaultIconTexturePath
    frame.icon:SetTexture(iconTexture)
    local color = trackerConfig.iconColor or {}
    frame.icon:SetVertexColor(
        color.r or 1,
        color.g or 1,
        color.b or 1,
        color.a or 1
    )

    frame.icon:SetDesaturated(false)  -- Initialize as not desaturated
    
    frame.cooldown = CreateFrame("Cooldown", frameName .. "_Cooldown", frame, "CooldownFrameTemplate")
    frame.Cooldown = frame.cooldown
    frame.cooldown:SetAllPoints(frame.icon)
    frame.cooldown:SetFrameLevel(frame:GetFrameLevel() + 2)  -- Above icon texture
    frame.cooldown:SetDrawEdge(true)
    frame.cooldown:SetDrawBling(false)
    frame.cooldown:SetSwipeColor(0, 0, 0, 0.8)
    
    -- Apply sweep and countdown text settings (per-icon overrides tracker-level)
    local hideSweep = trackerConfig.iconSettings.hideDefaultSweep
    local showCountdownText = trackerConfig.cooldownText.display

    
    frame.cooldown:SetDrawSwipe(hideSweep)
    frame.cooldown:SetHideCountdownNumbers(not showCountdownText)
    
    frame.cooldown:SetScript("OnShow", function(self)
        frame.meta.isDurationActive = true
        FrameTrackerManager:UpdateFrame_Duration_Active({
            customFrame = frame,
            config = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType),
            uniqueID = uniqueID,
            trackerType = trackerType
        })
    end)

    frame.cooldown:SetScript("OnHide", function(self)
        
    end)
    

    frame.cooldown:SetScript("OnCooldownDone", function(self)
        local spellInfo = C_Spell.GetSpellInfo(self.uniqueID)
        frame.meta.isDurationActive = false
        frame.meta.canBeCast = true
        -- If mock cooldown is active, disable it and update button text. This setup is in IconSettingsRenderer.lua
        if frame.meta.mockCooldownActive then
            frame.meta.mockCooldownActive = false
            -- Update the mock cooldown button text if it exists and is still valid
            if frame._spellStyler_mockCooldownBtn then
                pcall(function()
                    frame._spellStyler_mockCooldownBtn:SetText("Mock Cooldown")
                end)
            end
        end
        frame.meta.isDurationActive = false
        frame.meta.spellChargeCount = frame.meta.spellChargeCount + 1
        FrameTrackerManager:UpdateFrame_Duration_Inactive({
            customFrame = frame,
            trackerType = trackerType,
            uniqueID = self.uniqueID,
            config = FrameTrackerManager:GetSpecificTrackerValue(self.uniqueID, trackerType)
        })
        C_Timer.After(0, function()
            -- must occur one update cycle after this callback so the required information is updated.
            -- Attempt to reapply cooldown duration incase the spell has multiple charges that are still on cooldown.
            FrameTrackerManager:ApplyCooldownDuration({
                customFrame = frame,
                trackerType = trackerType,
                uniqueID = self.uniqueID,
                config = FrameTrackerManager:GetSpecificTrackerValue(self.uniqueID, trackerType)
            })
        end)
    end)
    
    -- Create StatusBar for tracker cooldown progress (secret-value compatible)
    -- This uses the new Midnight API that accepts DurationObjects with secrets
    frame.statusBar = CreateFrame("StatusBar", frameName .. "_StatusBar", frame)
    frame.statusBar:SetPoint(trackerConfig.statusBar.anchorSelf or "LEFT", frame, trackerConfig.statusBar.anchorParent or "RIGHT", 0, 0)
    local statusBarWidth = trackerConfig.statusBar and trackerConfig.statusBar.width or (trackerConfig.iconSettings.size * 4)
    local statusBarHeight = trackerConfig.statusBar and trackerConfig.statusBar.height or trackerConfig.iconSettings.size / 2
    frame.statusBar:SetSize(statusBarWidth, statusBarHeight)
    frame.statusBar:SetMinMaxValues(0, 1)
    frame.statusBar:SetValue(0)
    frame.statusBar:SetFrameLevel(frame:GetFrameLevel() + 1)  -- Base level for status bar
    frame.statusBar:SetStatusBarColor(
        trackerConfig.statusBar.color.r or 0.2,
        trackerConfig.statusBar.color.g or 0.8,
        trackerConfig.statusBar.color.b or 1,
        0 -- start with an alpha of zero so that GCD doesnt trigger accidentally.
    )
    
    -- Layer 1: Background (darkened fill texture) - BACKGROUND layer
    frame.statusBar.bgTexture = frame.statusBar:CreateTexture(nil, "BACKGROUND")
    frame.statusBar.bgTexture:SetAllPoints(frame.statusBar)
    local texture = ""
    if trackerConfig.statusBar.customBarTexture ~= '' then
        texture = trackerConfig.statusBar.customBarTexture
    else
        texture = trackerConfig.statusBar.defaultBarTexture
    end
    frame.statusBar.bgTexture:SetTexture(texture)
    frame.statusBar.bgTexture:SetVertexColor(
        trackerConfig.statusBar.backgroundColor.r,
        trackerConfig.statusBar.backgroundColor.g,
        trackerConfig.statusBar.backgroundColor.b,
        trackerConfig.statusBar.backgroundColor.a
    )  -- Darkened background
    
    -- Layer 2: Main Fill (active progress) - ARTWORK layer
    local barTexture = (trackerConfig.statusBar.customBarTexture and trackerConfig.statusBar.customBarTexture ~= "") 
        and trackerConfig.statusBar.customBarTexture 
        or trackerConfig.statusBar.defaultBarTexture
    frame.statusBar:SetStatusBarTexture(barTexture)
    -- Fill direction is controlled via TimerDirection in SetTimerDuration (ElapsedTime = fills up, RemainingTime = depletes)
    frame.statusBar:SetReverseFill(false)
    frame.statusBar:SetOrientation(
        (trackerConfig.statusBar.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL"
    )

    -- Layer 2.5: Full-cover texture (ARTWORK sublayer 1, above the fill at sublayer 0).
    -- Used when defaultFillValue='full' to visually fill the bar without fighting SetTimerDuration.
    -- Shown by UpdateFrame_Duration _Inactive when isFull, hidden when a real cooldown is active.
    frame.statusBar.fullCoverTexture = frame.statusBar:CreateTexture(nil, "ARTWORK", nil, 1)
    frame.statusBar.fullCoverTexture:SetAllPoints(frame.statusBar)
    frame.statusBar.fullCoverTexture:SetTexture(barTexture)
    frame.statusBar.fullCoverTexture:SetVertexColor(
        trackerConfig.statusBar.color.r or 0.2,
        trackerConfig.statusBar.color.g or 0.8,
        trackerConfig.statusBar.color.b or 1,
        trackerConfig.statusBar.color.a or 0.9
    )
    frame.statusBar.fullCoverTexture:Hide()

    -- Layer 3: Glow overlay - OVERLAY layer
    frame.statusBar.glowTexture = frame.statusBar:CreateTexture(nil, "OVERLAY")
    -- frame.statusBar.glowTexture:SetAllPoints(frame.statusBar)
    frame.statusBar.glowTexture:SetPoint("TOPLEFT", frame.statusBar, "TOPLEFT", 0, 0)
    frame.statusBar.glowTexture:SetPoint("BOTTOMRIGHT", frame.statusBar, "BOTTOMRIGHT", 0, 0)
    frame.statusBar.glowTexture:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarGlow.tga")
    frame.statusBar.glowTexture:SetBlendMode("ADD")
    frame.statusBar.glowTexture:SetVertexColor(
        trackerConfig.statusBar.glowColor.r or 1,
        trackerConfig.statusBar.glowColor.g or 1,
        trackerConfig.statusBar.glowColor.b or 1,
        trackerConfig.statusBar.glowColor.a or 0.25
    )  -- Semi-transparent glow
    frame.statusBar.glowTexture:SetDrawLayer("OVERLAY", 7)
    
    -- Layer 4: Border frame - above overlay (8 pieces: 4 corners + 4 edges)
    frame.statusBar.border = CreateFrame("Frame", nil, frame.statusBar)
    frame.statusBar.border:SetAllPoints(frame.statusBar)
    frame.statusBar.border:SetFrameLevel(frame.statusBar:GetFrameLevel() + 10)
    
    local cornerSize = 8
    local edgeThickness = 8
    
    -- Top-left corner
    frame.statusBar.borderCornerTL = frame.statusBar.border:CreateTexture(nil, "ARTWORK")
    frame.statusBar.borderCornerTL:SetSize(cornerSize, cornerSize)
    frame.statusBar.borderCornerTL:SetPoint("TOPLEFT", frame.statusBar.border, "TOPLEFT", -1.5, 1.5)
    frame.statusBar.borderCornerTL:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame.statusBar.borderCornerTL:SetRotation(0)
    frame.statusBar.borderCornerTL:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        trackerConfig.statusBar.borderColor.a or 1
    )
    frame.statusBar.borderCornerTL:SetScale(trackerConfig.statusBar.borderScale or 1)
    
    -- Top-right corner (rotated 270°)
    frame.statusBar.borderCornerTR = frame.statusBar.border:CreateTexture(nil, "ARTWORK")
    frame.statusBar.borderCornerTR:SetSize(cornerSize, cornerSize)
    frame.statusBar.borderCornerTR:SetPoint("TOPRIGHT", frame.statusBar.border, "TOPRIGHT", 1.5, 1.5)
    frame.statusBar.borderCornerTR:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame.statusBar.borderCornerTR:SetRotation(3 * math.pi / 2)
    frame.statusBar.borderCornerTR:SetVertexColor(
    trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        trackerConfig.statusBar.borderColor.a or 1)
    frame.statusBar.borderCornerTR:SetScale(trackerConfig.statusBar.borderScale or 1)
    
    -- Bottom-right corner (rotated 180°)
    frame.statusBar.borderCornerBR = frame.statusBar.border:CreateTexture(nil, "ARTWORK")
    frame.statusBar.borderCornerBR:SetSize(cornerSize, cornerSize)
    frame.statusBar.borderCornerBR:SetPoint("BOTTOMRIGHT", frame.statusBar.border, "BOTTOMRIGHT", 1.5, -1.5)
    frame.statusBar.borderCornerBR:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame.statusBar.borderCornerBR:SetRotation(math.pi)
    frame.statusBar.borderCornerBR:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        trackerConfig.statusBar.borderColor.a or 1
    )
    frame.statusBar.borderCornerBR:SetScale(trackerConfig.statusBar.borderScale or 1)
    
    -- Bottom-left corner (rotated 90°)
    frame.statusBar.borderCornerBL = frame.statusBar.border:CreateTexture(nil, "ARTWORK")
    frame.statusBar.borderCornerBL:SetSize(cornerSize, cornerSize)
    frame.statusBar.borderCornerBL:SetPoint("BOTTOMLEFT", frame.statusBar.border, "BOTTOMLEFT", -1.5, -1.5)
    frame.statusBar.borderCornerBL:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame.statusBar.borderCornerBL:SetRotation(math.pi / 2)
    frame.statusBar.borderCornerBL:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        trackerConfig.statusBar.borderColor.a or 1
    )
    frame.statusBar.borderCornerBL:SetScale(trackerConfig.statusBar.borderScale or 1)
    
    -- Top edge
    frame.statusBar.borderEdgeTop = frame.statusBar.border:CreateTexture(nil, "ARTWORK")
    frame.statusBar.borderEdgeTop:SetHeight(edgeThickness)
    frame.statusBar.borderEdgeTop:SetPoint("TOPLEFT", frame.statusBar.borderCornerTL, "TOPRIGHT", 0, 0)
    frame.statusBar.borderEdgeTop:SetPoint("TOPRIGHT", frame.statusBar.borderCornerTR, "TOPLEFT", 0, 0)
    frame.statusBar.borderEdgeTop:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line.tga")
    frame.statusBar.borderEdgeTop:SetRotation(0)
    frame.statusBar.borderEdgeTop:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        trackerConfig.statusBar.borderColor.a or 1
    )
    frame.statusBar.borderEdgeTop:SetScale(trackerConfig.statusBar.borderScale or 1)
    
    -- Right edge (vertical)
    frame.statusBar.borderEdgeRight = frame.statusBar.border:CreateTexture(nil, "ARTWORK")
    frame.statusBar.borderEdgeRight:SetWidth(edgeThickness)
    frame.statusBar.borderEdgeRight:SetPoint("TOPRIGHT", frame.statusBar.borderCornerTR, "BOTTOMRIGHT", 0, 0)
    frame.statusBar.borderEdgeRight:SetPoint("BOTTOMRIGHT", frame.statusBar.borderCornerBR, "TOPRIGHT", 0, 0)
    frame.statusBar.borderEdgeRight:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line_vertical.tga")
    frame.statusBar.borderEdgeRight:SetRotation(math.pi)
    frame.statusBar.borderEdgeRight:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        trackerConfig.statusBar.borderColor.a or 1
    )
    frame.statusBar.borderEdgeRight:SetScale(trackerConfig.statusBar.borderScale or 1)
    
    -- Bottom edge (rotated 180°)
    frame.statusBar.borderEdgeBottom = frame.statusBar.border:CreateTexture(nil, "ARTWORK")
    frame.statusBar.borderEdgeBottom:SetHeight(edgeThickness)
    frame.statusBar.borderEdgeBottom:SetPoint("BOTTOMRIGHT", frame.statusBar.borderCornerBR, "BOTTOMLEFT", 0, 0)
    frame.statusBar.borderEdgeBottom:SetPoint("BOTTOMLEFT", frame.statusBar.borderCornerBL, "BOTTOMRIGHT", 0, 0)
    frame.statusBar.borderEdgeBottom:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line.tga")
    frame.statusBar.borderEdgeBottom:SetRotation(math.pi)
    frame.statusBar.borderEdgeBottom:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        trackerConfig.statusBar.borderColor.a or 1
    )
    frame.statusBar.borderEdgeBottom:SetScale(trackerConfig.statusBar.borderScale or 1)
    
    -- Left edge (vertical)
    frame.statusBar.borderEdgeLeft = frame.statusBar.border:CreateTexture(nil, "ARTWORK")
    frame.statusBar.borderEdgeLeft:SetWidth(edgeThickness)
    frame.statusBar.borderEdgeLeft:SetPoint("BOTTOMLEFT", frame.statusBar.borderCornerBL, "TOPLEFT", 0, 0)
    frame.statusBar.borderEdgeLeft:SetPoint("TOPLEFT", frame.statusBar.borderCornerTL, "BOTTOMLEFT", 0, 0)
    frame.statusBar.borderEdgeLeft:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line_vertical.tga")
    frame.statusBar.borderEdgeLeft:SetRotation(0)
    frame.statusBar.borderEdgeLeft:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        trackerConfig.statusBar.borderColor.a or 1
    )
    frame.statusBar.borderEdgeLeft:SetScale(trackerConfig.statusBar.borderScale or 1)
    
    FrameTrackerManager:ApplyStatusBar_OnlyRenderBar({
        customFrame = frame,
        config = trackerConfig,
        uniqueID = uniqueID,
        trackerType = trackerType
    })
    frame.statusBar:Hide()  -- Hidden by default, shown when cooldown is active
    -- Stack count text (bottom right, larger font)
    frame.count = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    frame.Count = frame.count  -- Masque expects .Count
    -- Apply saved countText settings at creation
    local countCfg = trackerConfig.countText
    local countOffX = (countCfg and countCfg.x or 0) - 2
    local countOffY = (countCfg and countCfg.y or 0) + 2
    frame.count:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", countOffX, countOffY)
    frame.count:SetJustifyH("RIGHT")
    frame.count:SetDrawLayer("OVERLAY", 7)
    if countCfg and countCfg.size then
        local _fontPath, _, _fontFlags = frame.count:GetFont()
        if _fontPath then
            frame.count:SetFont(_fontPath, countCfg.size, _fontFlags or "OUTLINE")
        end
    end
    if countCfg and countCfg.color then
        frame.count:SetTextColor(
            countCfg.color.r or 1,
            countCfg.color.g or 1,
            countCfg.color.b or 1,
            countCfg.color.a or 1
        )
    end
    -- Visibility is resolved by UpdateFrame_copyCharges called at the bottom of this function
    
    -- Proc glow overlay (using Blizzard's built-in glow style)
    frame.glowFrame = CreateFrame("Frame", frameName .. "_Glow", frame)
    -- Start by matching the parent frame; BrieflyHighlightFrame may adjust outward offsets
    if frame.glowFrame.SetAllPoints then
        frame.glowFrame:SetAllPoints(frame)
    else
        frame.glowFrame:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 1, -1)
        frame.glowFrame:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    end
    frame.glowFrame:SetFrameLevel(frame:GetFrameLevel() + 5)
    frame.glowFrame:Hide()

    -- Create the glow texture (yellow spell activation border)
    frame.glowTexture = frame.glowFrame:CreateTexture(nil, "OVERLAY")
    -- Size the texture slightly larger than the icon so the border's outer pixels are visible
    frame.glowTexture:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.glowTexture:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.glowTexture:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    frame.glowTexture:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    frame.glowTexture:SetBlendMode("ADD")
    frame.glowTexture:SetVertexColor(1, 1, 0.6, 0.8)

    -- Animated glow ants (the spinning border effect)
    frame.glowAnts = frame.glowFrame:CreateTexture(nil, "OVERLAY")
    frame.glowAnts:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.glowAnts:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.glowAnts:SetTexture("Interface\\Cooldown\\star4")
    frame.glowAnts:SetTexCoord(0, 1, 0, 1)
    frame.glowAnts:SetBlendMode("ADD")
    frame.glowAnts:SetVertexColor(1, 1, 0.5, 0.6)
    
    -- Animation group for the glow
    frame.glowAnim = frame.glowAnts:CreateAnimationGroup()
    frame.glowAnim:SetLooping("REPEAT")
    local rotation = frame.glowAnim:CreateAnimation("Rotation")
    rotation:SetDegrees(-360)
    rotation:SetDuration(4)
    
    -- Custom label (for accessibility / identification)
    frame.customLabel = frame:CreateFontString(nil, "OVERLAY")
    -- Apply saved customLabel settings at creation
    local labelCfg = trackerConfig.customLabel
    local labelSize = (labelCfg and labelCfg.size) or 14
    frame.customLabel:SetFont("Fonts\\FRIZQT__.TTF", labelSize, "OUTLINE")
    local labelX = (labelCfg and labelCfg.x) or 0
    local labelY = (labelCfg and labelCfg.y) or 0
    frame.customLabel:SetPoint("CENTER", frame, "CENTER", labelX, labelY)
    if labelCfg and labelCfg.color then
        frame.customLabel:SetTextColor(
            labelCfg.color.r or 1,
            labelCfg.color.g or 1,
            labelCfg.color.b or 1,
            labelCfg.color.a or 1
        )
    else
        frame.customLabel:SetTextColor(1, 1, 1, 1)
    end
    frame.customLabel:SetShadowOffset(1, -1)
    frame.customLabel:SetShadowColor(0, 0, 0, 1)
    frame.customLabel:SetDrawLayer("OVERLAY", 7)
    if labelCfg and labelCfg.display and labelCfg.text and labelCfg.text ~= "" then
        frame.customLabel:SetText(labelCfg.text)
        frame.customLabel:Show()
    else
        frame.customLabel:Hide()
    end
    
    -- Apply saved position or default
    local pos = trackerConfig.position
    if pos and pos.anchorPoint and pos.x and pos.y then
        frame:ClearAllPoints()
        frame:SetPoint(
            pos.anchorPoint, 
            UIParent,  -- Always use UIParent for simplicity
            pos.relativeAnchorPoint or pos.anchorPoint, 
            pos.x or 0, 
            pos.y or 0
        )
    else
        -- Default position - center with offset based on slot
        frame:SetPoint("CENTER", UIParent, "CENTER", -200, -100)
    end
    
    frame.cooldown.uniqueID = uniqueID
    -- Initially hidden
    frame:Show()
    
    SpellStyler_frames[trackerType][uniqueID] = frame

    -- Assume the frame is inactive first. This is necessary because the frame cooldown callabcks dont fire unless a valid cooldown occurs. That will be applied next if so.
    FrameTrackerManager:UpdateFrame_Duration_Inactive({
        customFrame = frame,
        trackerType = trackerType,
        uniqueID = self.uniqueID,
        config = FrameTrackerManager:GetSpecificTrackerValue(self.uniqueID, trackerType)
    })
    -- If there is an active cooldown, it will handle calling the show or hide methods for the frame using the cooldown event callbacks
    FrameTrackerManager:ApplyCooldownDuration({
        customFrame = frame,
        config = trackerConfig,
        uniqueID = uniqueID,
        trackerType = trackerType
    })
    FrameTrackerManager:UpdateFrame_AuraEvent(uniqueID)

    return frame
end

-- ============================================================================
-- DRAGGING FUNCTIONS FOR CONFIG MENU
-- ============================================================================

local onFrameClickCallback = nil

function FrameTrackerManager:SetFrameClickCallback(callback)
    onFrameClickCallback = callback
end

function FrameTrackerManager:EnableDraggingForAllFrames()
    for trackerType, frames in pairs(SpellStyler_frames) do
        for uniqueID, frame in pairs(frames) do
            if frame and not frame._inContainer then
                frame:EnableMouse(true)
                frame:RegisterForDrag("LeftButton")
                
                frame:SetScript("OnDragStart", function(self)
                    self:StartMoving()
                    -- Notify settings panel that this icon was selected
                    if onFrameClickCallback then
                        onFrameClickCallback(uniqueID, trackerType)
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
                    
                    FrameTrackerManager:SetTrackerValueConfigProperty(uniqueID, trackerType, "position", positionData)
                    
                    -- Verify it was saved
                    local saved = FrameTrackerManager:GetTrackerValueConfigProperty(uniqueID, trackerType, "position")
                end)
                
                -- Add click handler to select icon in settings
                frame:SetScript("OnMouseDown", function(self, button)
                    if button == "LeftButton" and onFrameClickCallback then
                        onFrameClickCallback(uniqueID, trackerType)
                    end
                end)
            end
        end
    end
end

function FrameTrackerManager:DisableDraggingForAllFrames()
    onFrameClickCallback = nil
    
    for trackerType, frames in pairs(SpellStyler_frames) do
        for uniqueID, frame in pairs(frames) do
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

function FrameTrackerManager:GetTrackerFrame(uniqueID, trackerType)
    return SpellStyler_frames[trackerType] and SpellStyler_frames[trackerType][uniqueID] or nil
end

function FrameTrackerManager:ToggleMockCooldown(uniqueID, trackerType)
    local frame = SpellStyler_frames[trackerType] and SpellStyler_frames[trackerType][uniqueID]
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
    else
        -- Enable mock cooldown (15 second duration)
        frame.meta.mockCooldownActive = true
        local mockDuration = 15
        local now = GetTime()
        
        -- Create a proper DurationObject for Apply Cooldown Duration()
        local mockDurationObj = C_DurationUtil.CreateDuration()
        mockDurationObj:SetTimeFromStart(now, mockDuration)
        
        FrameTrackerManager:ApplyCooldownDuration({
            customFrame = frame,
            uniqueID = uniqueID,
            trackerType = trackerType,
            config = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType),
            durationObject = mockDurationObj
        })
    end
end

function FrameTrackerManager:BrieflyHighlightFrame(uniqueID, trackerType)
    local f = SpellStyler_frames and SpellStyler_frames[trackerType] and SpellStyler_frames[trackerType][uniqueID]
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


--- @param data ApplyCooldownDurationData
function FrameTrackerManager:UpdateFrame_Duration_Inactive(data)
    local trackerConfig = data.config
    if not trackerConfig or not trackerConfig.statusBar then return end
    local frame = data.customFrame
    if not frame then return end
    local showstatusBar = (
        trackerConfig.statusBar.displayState == "always"
        or trackerConfig.statusBar.displayState == "available"
        or trackerConfig.statusBar.displayState == "inactive"
    )
    local showSpellIcon = (
        trackerConfig.iconSettings.iconDisplayState == 'always'
        or trackerConfig.iconSettings.iconDisplayState == 'available'
        or trackerConfig.iconSettings.iconDisplayState == 'inactive'
    )
    local suc, err = pcall(function()
        if showstatusBar then
            local barColor = trackerConfig.statusBar.color
            local isFull = trackerConfig.statusBar.defaultFillValue == 'full'
            frame.statusBar:Show()
            frame.statusBar:SetStatusBarColor(
                barColor.r or 0.2,
                barColor.g or 0.8,
                barColor.b or 1,
                0  -- always hide the timer-driven fill; fullCoverTexture handles the 'full' visual
            )
            -- frame.statusBar:SetValue(isFull and 1 or 0)
            -- Show/hide the cover texture for 'full' defaultFillValue.
            -- This overlay sits above the fill (ARTWORK sublayer 1) and visually
            -- fills the bar without interacting with SetTimerDuration, so it is
            -- immune to GCD timer interference.
            if frame.statusBar.fullCoverTexture then
                if isFull then
                    local c = trackerConfig.statusBar.color
                    frame.statusBar.fullCoverTexture:SetVertexColor(c.r or 0.2, c.g or 0.8, c.b or 1, c.a or 0.9)
                    frame.statusBar.fullCoverTexture:Show()
                else
                    frame.statusBar.fullCoverTexture:Hide()
                end
            end
        else
            frame.statusBar:Hide()
        end
        frame.cooldown:SetDrawSwipe(false)
        frame.cooldown:SetDrawEdge(false)
        frame.cooldown:SetHideCountdownNumbers(true)
        if showSpellIcon then
            frame.icon:Show()
            frame.count:Show()
        else
            frame.count:Hide()
            frame.icon:Hide()
        end
        if frame.meta.spellHasCharges and trackerConfig.iconSettings.iconDisplayState ~= 'never' then
            frame.icon:Show()
            frame.count:Show()
        end

        -- Apply desaturation for non-buff trackers when not on cooldown
        if data.trackerType ~= "buffs" and trackerConfig.iconSettings.desaturated then
            frame.icon:SetDesaturated(false)
            -- Restore original color from config
            local color = trackerConfig.iconColor or {}
            frame.icon:SetVertexColor(
                color.r or 1,
                color.g or 1,
                color.b or 1,
                color.a or 1
            )
        end
    end)
    FrameTrackerManager:ApplyStatusBar_OnlyRenderBar(data)
end

--- @param data ApplyCooldownDurationData
function FrameTrackerManager:UpdateFrame_Duration_Active(data)
    local trackerConfig = data.config
    if not trackerConfig or not trackerConfig.statusBar then return end
    local frame = data.customFrame
    if not frame then return end
    local showstatusBar = (
        trackerConfig.statusBar.displayState == "always"
        or trackerConfig.statusBar.displayState == "active"
        or trackerConfig.statusBar.displayState == "cooldown"
    )
    local canBeCast = frame.meta.canBeCast or (frame.meta.isSpellOffGCD == true and frame.meta.spellChargeCount > 0)
    local showSpellIcon = (
        trackerConfig.iconSettings.iconDisplayState == 'always'
        -- has available charges or can be cast
        or (canBeCast and (
            trackerConfig.iconSettings.iconDisplayState == 'inactive'
            or trackerConfig.iconSettings.iconDisplayState == 'available'
        ))
        -- has no available charges or can NOT be cast
        or (not canBeCast and (
            trackerConfig.iconSettings.iconDisplayState == 'cooldown'
            or trackerConfig.iconSettings.iconDisplayState == 'active'
        ))
    )
    local suc, err = pcall(function()
        if showstatusBar then
            frame.statusBar:Show()
            local barColor = trackerConfig.statusBar.color
            frame.statusBar:SetStatusBarColor(
                barColor.r or 0.2,
                barColor.g or 0.8,
                barColor.b or 1,
                barColor.a or 0.9
            )
        end
        frame.cooldown:SetDrawSwipe(not trackerConfig.iconSettings.hideDefaultSweep)
        frame.cooldown:SetDrawEdge(not trackerConfig.iconSettings.hideDefaultSweep)
        frame.cooldown:SetHideCountdownNumbers(not trackerConfig.cooldownText.display)
        if showSpellIcon then
            frame.icon:Show()
            frame.count:Show()
        else
            frame.icon:Hide()
            frame.count:Hide()
        end
        
        -- Apply desaturation for non-buff trackers when on cooldown
        if trackerConfig.iconSettings.desaturated and data.trackerType ~= "buffs" then
            frame.icon:SetDesaturated(true)
            -- Apply grayscale vertex color for "on cooldown" feel
            frame.icon:SetVertexColor(0.6, 0.6, 0.6, 0.6)
        end
        
        -- A real cooldown is active; hide the full-cover overlay so the timer-driven fill shows through.
        if frame.statusBar.fullCoverTexture then
            frame.statusBar.fullCoverTexture:Hide()
        end
    end)
    FrameTrackerManager:ApplyStatusBar_OnlyRenderBar(data)
end


--If spells with charges continue to be an issue (I think off GCD spells with charges might be the most likely culprit) then use this method (implementing SetAlpha(C_Spell.GetSpellCharges(spellID).currentCharges)) in conjunction with the "SPELL_UPDATE_CHARGES" event - calling only for frames with charges

--- @param data ApplyCooldownDurationData
function FrameTrackerManager:UpdateFrame_ChargeVisibility(data)
    local frame  = data.customFrame
    local config = data.config
    if not frame or not config then return end
    -- -----------------------------------------------------------------------
    -- 1.  Charge count – provided by the caller; no API calls made here.
    -- -----------------------------------------------------------------------
    local currentCharges = data.currentCharges
    if currentCharges == nil then
        -- Caller did not supply a value; bail out rather than silently
        -- applying wrong visibility state.
        return
    end
    -- -----------------------------------------------------------------------
    -- 2.  Icon visibility  (respects iconDisplayState)
    -- -----------------------------------------------------------------------
    local displayState = config.iconSettings.iconDisplayState
    local showSpellIcon = nil

    if displayState == 'always' then
        showSpellIcon = true
    elseif displayState == 'never' then
        showSpellIcon = false
    end

    if showSpellIcon == true then
        frame.icon:SetAlpha(1)
        frame.icon:Show()
    elseif showSpellIcon == false then
        frame.icon:SetAlpha(0)
        frame.icon:Hide()
    elseif showSpellIcon == nil then
        frame.icon:SetAlpha(currentCharges)
    end

    -- -----------------------------------------------------------------------
    -- 3.  Cooldown sweep / edge / countdown text
    -- -----------------------------------------------------------------------
    
    frame.cooldown:SetDrawSwipe(not config.iconSettings.hideDefaultSweep)
    frame.cooldown:SetDrawEdge(not config.iconSettings.hideDefaultSweep)
    frame.cooldown:SetHideCountdownNumbers(not config.cooldownText.display)
end


function FrameTrackerManager:UpdateFrame_ConfigurationChanges(uniqueID, trackerType)
    local trackerConfig = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
    local sourceFrame = cooldownManagerFrames[trackerType][uniqueID]
    local frame = SpellStyler_frames[trackerType][uniqueID]
    FrameTrackerManager:UpdateFrame_AuraEvent(uniqueID)
    if frame.meta.isDurationActive then
        FrameTrackerManager:UpdateFrame_Duration_Active({
            uniqueID = uniqueID,
            trackerType = trackerType,
            config = trackerConfig,
            customFrame = frame
        })
    else
        FrameTrackerManager:UpdateFrame_Duration_Inactive({
            uniqueID = uniqueID,
            trackerType = trackerType,
            config = trackerConfig,
            customFrame = frame
        })
    end
    if trackerType == 'buffs' then
        FrameTrackerManager:UpdateFrame_AuraEvent(uniqueID)
    end
    -- Update icon texture
    local customTexture = (trackerConfig.iconSettings.iconTexturePath ~= "" and trackerConfig.iconSettings.iconTexturePath)
    local texture = customTexture or frame.updatedIconID or trackerConfig.defaultIconTexturePath
    frame.icon:SetTexture(texture)
    
    -- Update icon color
    local color = trackerConfig.iconColor or {}
    frame.icon:SetVertexColor(
        color.r or 1,
        color.g or 1,
        color.b or 1,
        color.a or 1
    )
    
    -- Update size (skip when the frame is managed by a container; LayoutContainer controls its size)
    if not frame._inContainer then
        frame:SetSize(trackerConfig.iconSettings.size, trackerConfig.iconSettings.size)
    end

    -- Update opacity
    frame:SetAlpha(trackerConfig.iconSettings.opacity or 1)

    -- Update off-GCD flag; also seed the runtime cache so the event handler
    -- doesn't need to wait for the first cast to know this spell bypasses the GCD.
    frame.meta.isSpellOffGCD = trackerConfig.iconSettings.isSpellOffGCD or false
    if frame.meta.isSpellOffGCD then
        offGCDSpellCache[frame.meta.activeSpellID] = true
    end
        
    -- Attempt to get the cooldown text frame if possible, to update its styles
    local cdText = frame.cooldown.Text or frame.cooldown.text
    if not cdText then
        -- Search regions for FontString
        for i = 1, frame.cooldown:GetNumRegions() do
            local region = select(i, frame.cooldown:GetRegions())
            if region and region:GetObjectType() == "FontString" then
                cdText = region
                break
            end
        end
    end
        
    if cdText and trackerConfig.cooldownText then
        pcall(function()
            -- Apply font size
            local fontPath, _, fontFlags = cdText:GetFont()
            if fontPath and trackerConfig.cooldownText.size then
                cdText:SetFont(fontPath, trackerConfig.cooldownText.size, fontFlags or "OUTLINE")
            end
            
            -- Apply color
            if trackerConfig.cooldownText.color then
                cdText:SetTextColor(
                    trackerConfig.cooldownText.color.r or 1,
                    trackerConfig.cooldownText.color.g or 1,
                    trackerConfig.cooldownText.color.b or 1,
                    trackerConfig.cooldownText.color.a or 1
                )
            end
            
            -- Apply offset
            cdText:ClearAllPoints()
            cdText:SetPoint("CENTER", frame.cooldown, "CENTER", 
                trackerConfig.cooldownText.x or 0, 
                trackerConfig.cooldownText.y or 0)
        end)
    end

    
    -- Update count/stack text
    if frame.count and trackerConfig.countText then
        pcall(function()
            -- Apply font size
            local fontPath, _, fontFlags = frame.count:GetFont()
            if fontPath and trackerConfig.countText.size then
                frame.count:SetFont(fontPath, trackerConfig.countText.size, fontFlags or "OUTLINE")
            end

            -- Apply color
            if trackerConfig.countText.color then
                frame.count:SetTextColor(
                    trackerConfig.countText.color.r or 1,
                    trackerConfig.countText.color.g or 1,
                    trackerConfig.countText.color.b or 1,
                    trackerConfig.countText.color.a or 1
                )
            end

            -- Apply offset
            frame.count:ClearAllPoints()
            frame.count:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",
                (trackerConfig.countText.x or 0) - 2,
                (trackerConfig.countText.y or 0) + 2)

            -- Apply visibility: hide if displayCharges disabled OR countText.display is off
            if not trackerConfig.countText.display then
                frame.count:SetText("")
                frame.count:Hide()
            else
                frame.count:Show()
            end
        end)
    end
    
    -- Update custom label
    if frame.customLabel and trackerConfig.customLabel then
        pcall(function()
            -- Set visibility and text
            if trackerConfig.customLabel.display and trackerConfig.customLabel.text and trackerConfig.customLabel.text ~= "" then
                frame.customLabel:SetText(trackerConfig.customLabel.text)
                frame.customLabel:Show()
            else
                frame.customLabel:Hide()
            end
            
            -- Apply font size
            if trackerConfig.customLabel.size then
                frame.customLabel:SetFont("Fonts\\FRIZQT__.TTF", trackerConfig.customLabel.size, "OUTLINE")
            end
            
            -- Apply color
            if trackerConfig.customLabel.color then
                frame.customLabel:SetTextColor(
                    trackerConfig.customLabel.color.r or 1,
                    trackerConfig.customLabel.color.g or 1,
                    trackerConfig.customLabel.color.b or 1,
                    trackerConfig.customLabel.color.a or 1
                )
            end
            
            -- Apply offset
            frame.customLabel:ClearAllPoints()
            frame.customLabel:SetPoint("CENTER", frame, "CENTER", 
                trackerConfig.customLabel.x or 0, 
                trackerConfig.customLabel.y or 0)
        end)
    end
    
    -- Update status bar styling
    if frame.statusBar and trackerConfig.statusBar then
        pcall(function()
            -- Apply main fill color
            if trackerConfig.statusBar.color then
                frame.statusBar:SetStatusBarColor(
                    trackerConfig.statusBar.color.r or 0.2,
                    trackerConfig.statusBar.color.g or 0.8,
                    trackerConfig.statusBar.color.b or 1,
                    trackerConfig.statusBar.color.a or 0.9
                )
            end
            
            -- Apply background color
            if frame.statusBar.bgTexture and trackerConfig.statusBar.backgroundColor then
                frame.statusBar.bgTexture:SetVertexColor(
                    trackerConfig.statusBar.backgroundColor.r or 0.2,
                    trackerConfig.statusBar.backgroundColor.g or 0.2,
                    trackerConfig.statusBar.backgroundColor.b or 0.2,
                    trackerConfig.statusBar.backgroundColor.a or 0.6
                )
            end
            
            -- Apply glow color
            if frame.statusBar.glowTexture and trackerConfig.statusBar.glowColor then
                frame.statusBar.glowTexture:SetVertexColor(
                    trackerConfig.statusBar.glowColor.r or 0.5,
                    trackerConfig.statusBar.glowColor.g or 0.8,
                    trackerConfig.statusBar.glowColor.b or 1,
                    trackerConfig.statusBar.glowColor.a or 0.4
                )
            end
            
            -- Apply border color to all 8 pieces (4 corners + 4 edges)
            if trackerConfig.statusBar.borderColor then
                local borderR = trackerConfig.statusBar.borderColor.r or 1
                local borderG = trackerConfig.statusBar.borderColor.g or 1
                local borderB = trackerConfig.statusBar.borderColor.b or 1
                local borderA = trackerConfig.statusBar.borderColor.a or 1
                
                -- Apply to all 4 corners
                if frame.statusBar.borderCornerTL then frame.statusBar.borderCornerTL:SetVertexColor(borderR, borderG, borderB, borderA) end
                if frame.statusBar.borderCornerTR then frame.statusBar.borderCornerTR:SetVertexColor(borderR, borderG, borderB, borderA) end
                if frame.statusBar.borderCornerBR then frame.statusBar.borderCornerBR:SetVertexColor(borderR, borderG, borderB, borderA) end
                if frame.statusBar.borderCornerBL then frame.statusBar.borderCornerBL:SetVertexColor(borderR, borderG, borderB, borderA) end
                
                -- Apply to all 4 edges
                if frame.statusBar.borderEdgeTop then frame.statusBar.borderEdgeTop:SetVertexColor(borderR, borderG, borderB, borderA) end
                if frame.statusBar.borderEdgeRight then frame.statusBar.borderEdgeRight:SetVertexColor(borderR, borderG, borderB, borderA) end
                if frame.statusBar.borderEdgeBottom then frame.statusBar.borderEdgeBottom:SetVertexColor(borderR, borderG, borderB, borderA) end
                if frame.statusBar.borderEdgeLeft then frame.statusBar.borderEdgeLeft:SetVertexColor(borderR, borderG, borderB, borderA) end
            end
            
            -- Apply scale
            if trackerConfig.statusBar.scale then
                frame.statusBar:SetScale(trackerConfig.statusBar.scale)
            end

            -- Apply bar texture (custom overrides default)
            local barTexture = (trackerConfig.statusBar.customBarTexture and trackerConfig.statusBar.customBarTexture ~= "")
                and trackerConfig.statusBar.customBarTexture
                or trackerConfig.statusBar.defaultBarTexture
            if barTexture then
                frame.statusBar:SetStatusBarTexture(barTexture)
                -- Keep the full-cover texture in sync with the bar texture
                if frame.statusBar.fullCoverTexture then
                    frame.statusBar.fullCoverTexture:SetTexture(barTexture)
                end
            end
            
            -- Apply width and height
            local statusBarWidth = trackerConfig.statusBar.width or (trackerConfig.iconSettings.size * 4)
            local statusBarHeight = trackerConfig.statusBar.height or trackerConfig.iconSettings.size
            frame.statusBar:SetSize(statusBarWidth, statusBarHeight)

            -- Fill direction is driven by TimerDirection in SetTimerDuration; no fill-anchor reversal needed
            frame.statusBar:SetReverseFill(false)
            frame.statusBar:SetOrientation(
                (trackerConfig.statusBar.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL"
            )

            -- Apply fill style (progressDirection) immediately so a settings change is reflected live
            local fillStyle = (trackerConfig and trackerConfig.statusBar and trackerConfig.statusBar.progressDirection == 'reverse')
            local textureRotation = (trackerConfig and trackerConfig.statusBar and trackerConfig.statusBar.textureRotation or 0)
            if textureRotation then
                frame.statusBar:RotateTextures(textureRotation)
            end
            frame.statusBar:SetFillStyle(fillStyle and Enum.StatusBarFillStyle.Reverse or Enum.StatusBarFillStyle.Standard)

            -- Apply anchors and positioning
            frame.statusBar:ClearAllPoints()
            frame.statusBar:SetPoint(
                trackerConfig.statusBar.anchorSelf or "LEFT",
                frame,
                trackerConfig.statusBar.anchorParent or "RIGHT",
                (trackerConfig.statusBar.x or 0),
                (trackerConfig.statusBar.y or 0)
            )
            
            -- Apply rotation
            if trackerConfig.statusBar.rotation then
                frame.statusBar:SetRotation(math.rad(trackerConfig.statusBar.rotation))
            end
        end)
        -- Called outside pcall so a pcall error can't prevent it from running
        FrameTrackerManager:ApplyStatusBar_OnlyRenderBar({
            uniqueID = uniqueID,
            trackerType = trackerType,
            config = trackerConfig,
            customFrame = frame
        })
    end
    
    -- Update position
    local pos = trackerConfig.position
    if pos and pos.anchorPoint and not frame._inContainer then
        frame:ClearAllPoints()
        frame:SetPoint(
            pos.anchorPoint, 
            UIParent,
            pos.relativeAnchorPoint or pos.anchorPoint, 
            pos.x or 0, 
            pos.y or 0
        )
    end

    -- Re-apply the timer duration with the latest fillOrEmpty direction and progressDirection.
    -- ApplyCooldownDuration returns immediately when no active duration object is available,
    -- so this is safe to call unconditionally here.
    FrameTrackerManager:ApplyCooldownDuration({
        customFrame = frame,
        config = trackerConfig,
        uniqueID = uniqueID,
        trackerType = trackerType
    })
end




--- @param data ApplyCooldownDurationData
function FrameTrackerManager:UpdateFrame_copyCharges(data)

    if not data.customFrame or not data.config then return end
    local charges = C_Spell.GetSpellCharges(data.customFrame.meta.activeSpellID) or {}
    -- If display charges is disabled in the settings, or this is an OffGCD spell with no available charge, or the spell has mutated, is on cooldown AND can be cast (that would mean it turned into a spell with charges and it has 1 charge available and 1 on cooldown. This only works with 2 charges)
    -- Those should all cover zero or 1 charges
    local spellInfo = C_Spell.GetSpellInfo(data.customFrame.meta.activeSpellID)
    if not data.config.countText.display
        or (data.customFrame.meta.isSpellOffGCD == true and data.customFrame.meta.spellChargeCount < 2)
        or (
            -- original spell and doesnt have charges
            data.uniqueID == data.customFrame.meta.activeSpellID
            and not data.customFrame.meta.isSpellWithCharges
        ) then
        data.customFrame.count:SetText("")
        data.customFrame.count:Hide()
        return
    else
        data.customFrame.count:Show()
    end

    
    local success, error = pcall(function()
        local countCfg = data.config.countText
        if countCfg then
            local fontPath, _, fontFlags = data.customFrame.count:GetFont()
            if fontPath and countCfg.size then
                data.customFrame.count:SetFont(fontPath, countCfg.size, fontFlags or "OUTLINE")
            end
            if countCfg.color then
                data.customFrame.count:SetTextColor(
                    countCfg.color.r or 1,
                    countCfg.color.g or 1,
                    countCfg.color.b or 1,
                    countCfg.color.a or 1
                )
            end
            data.customFrame.count:ClearAllPoints()
            data.customFrame.count:SetPoint("BOTTOMRIGHT", data.customFrame, "BOTTOMRIGHT",
                (countCfg.x or 0) - 2,
                (countCfg.y or 0) + 2)
        end
    end)
    local suc, err = pcall(function()
        data.customFrame.count:SetText(charges.currentCharges or 1)
        data.customFrame.count:SetAlpha(charges.currentCharges or 1)
    end)
end

function FrameTrackerManager:UpdateFrame_AuraEvent(uniqueID)
    local frame = SpellStyler_frames["buffs"][uniqueID]
    if not frame then
        return
    end
    local sourceFrame = cooldownManagerFrames["buffs"][uniqueID]
    local db = FrameTrackerManager:GetDataBase_V2()
    local config = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, "buffs")
    if not config or not config.iconSettings then
        --This can happen when changing specs. The old and new frames exist in a moment where the hook functions still trigger on the old frames but reference the new database (for the spec you changed to) resulting in no config, usually due to the spell not existing in the new spec. Not to mention its for a frame used by the old spec.
        return
    end
    local auraInstanceID = nil
    if sourceFrame then
        pcall(function()
            auraInstanceID = sourceFrame.auraInstanceID
        end)
    end
   
    if auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then       
        local success, err = pcall(function()
            if config.countText.display then
                frame.count:SetText(C_UnitAuras.GetAuraApplicationDisplayCount("player", auraInstanceID, 1))
                frame.count:Show()
            end
        end)
    end
    local success, error = pcall(function()
        local countCfg = config.countText
        if countCfg then
            local fontPath, _, fontFlags = frame.count:GetFont()
            if fontPath and countCfg.size then
                frame.count:SetFont(fontPath, countCfg.size, fontFlags or "OUTLINE")
            end
            if countCfg.color then
                frame.count:SetTextColor(
                    countCfg.color.r or 1,
                    countCfg.color.g or 1,
                    countCfg.color.b or 1,
                    countCfg.color.a or 1
                )
            end
            frame.count:ClearAllPoints()
            frame.count:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",
                (countCfg.x or 0) - 2,
                (countCfg.y or 0) + 2)
        end
    end)
    local isBuffShown = auraInstanceID ~= nil or (sourceFrame and sourceFrame:IsShown()) or false
    if isBuffShown then
        if config.iconSettings.iconDisplayState == 'always' or config.iconSettings.iconDisplayState == 'active' or config.iconSettings.iconDisplayState == 'cooldown' then
            frame.Icon:Show()
        else
            frame.Icon:Hide()
        end
        -- Buff is active, restore normal color
        if config.iconSettings.desaturated then
            frame.icon:SetDesaturated(false)
            -- Restore original color from config
            local color = config.iconColor or {}
            frame.icon:SetVertexColor(
                color.r or 1,
                color.g or 1,
                color.b or 1,
                color.a or 1
            )
        end
    else
        frame.count:SetText("")
        if config.iconSettings.iconDisplayState == 'always' or config.iconSettings.iconDisplayState == 'inactive' or config.iconSettings.iconDisplayState == 'available' then
            frame.Icon:Show()
        else
            frame.Icon:Hide()
        end
        -- Buff is inactive, apply grayscale effect
        if config.iconSettings.desaturated then
            frame.icon:SetVertexColor(0.6, 0.6, 0.6, 0.6)
            frame.icon:SetDesaturated(true)
        end
    end
end


-- Set up hooks on BuffIconCooldownViewer to mirror cooldown updates
function FrameTrackerManager:SetupCooldownManagerHooks()
    for _, trackerType in ipairs({"buffs", "essential", "utility"}) do
        local viewer = FrameTrackerManager:GetCooldownManagerViewer(trackerType)
        if not viewer then
            C_Timer.After(1, function() self:SetupCooldownManagerHooks() end)
            return
        end

        -- Hook SetAlpha on the viewer so Blizzard can't override our visibility setting.
        -- Recursion guard prevents the hook from re-entering itself when we call SetAlpha.
        if not viewer._spellStyler_alphaHooked then
            viewer._spellStyler_alphaHooked = true
            hooksecurefunc(viewer, "SetAlpha", function(self, alpha)
                if self._spellStyler_settingViewerAlpha then return end
                if FrameTrackerManager:GetViewerHidden(trackerType) and alpha ~= 0 then
                    self._spellStyler_settingViewerAlpha = true
                    self:SetAlpha(0)
                    self._spellStyler_settingViewerAlpha = false
                end
            end)
        end

        -- Initial scan of existing icons
        self:HookAllBuffCooldownFrames(trackerType)
    end
    FrameTrackerManager:MoveOverlappingIcons()

    -- Apply saved container layouts now that all tracker frames exist
    if SpellStyler.Containers then
        local containers = SpellStyler.Containers:GetDB()
        for containerName in pairs(containers) do
            SpellStyler.Containers:LayoutContainer(containerName)
        end
    end
end

function FrameTrackerManager:MoveOverlappingIcons()
    local allFrameConfigs = {}
    for _, trackerType in ipairs({"buffs", "essential", "utility"}) do
        local specificTrackerConfigs = FrameTrackerManager:GetAllTrackerValues(trackerType)
        for _, value in pairs(specificTrackerConfigs) do
            table.insert(allFrameConfigs, value)
        end
    end
    
    local spacing = 46
    local i = 1
    for _, frameData in ipairs(allFrameConfigs) do
        
        if (frameData.position.x == 0 and frameData.position.y == 0) then
            local j = i - 1
            local col = j % 5
            local row = math.floor(j / 5)
            local x = col * spacing
            local y = -row * spacing
            FrameTrackerManager:SetTrackerValueConfigProperty(frameData.uniqueID, frameData.trackerType, 'position.x', x)
            FrameTrackerManager:SetTrackerValueConfigProperty(frameData.uniqueID, frameData.trackerType, 'position.y', y)
            local trackerConfig = FrameTrackerManager:GetSpecificTrackerValue(frameData.uniqueID, frameData.trackerType)
            local frame = SpellStyler_frames and SpellStyler_frames[trackerConfig.trackerType] and SpellStyler_frames[trackerConfig.trackerType][trackerConfig.uniqueID]
            if frame then
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER", trackerConfig.position.x, trackerConfig.position.y)
                i = i + 1
            end
        end
    end
end


-- ============================================================================
-- SPELL Cooldown Tracking
-- ============================================================================





-- Hook all buffs icon cooldowns to mirror to per-icon frames
function FrameTrackerManager:HookAllBuffCooldownFrames(trackerType)
    local viewer = FrameTrackerManager:GetCooldownManagerViewer(trackerType)
    if not viewer then return end
    ScanAndSaveCurrentCooldownManagerFrames(trackerType)
    for slotIndex, cdm_frame in pairs(cooldownManagerFrames[trackerType]) do
        -- Only hook frames that haven't been hooked yet
        if not cdm_frame._spellStyler_hasHookedFrame then
            cdm_frame._spellStyler_hasHookedFrame = true
        
            -- Hide the Blizzard buffs frames by keeping alpha at 0
            cdm_frame._spellStyler_alphaLocked = true
            -- cdm_frame:SetAlpha(0)
            
            -- Hook SetAlpha with recursion guard
            hooksecurefunc(cdm_frame, 'SetAlpha', function(self, alpha)
                if not self._spellStyler_settingAlpha and alpha ~= 0 then
                    self._spellStyler_settingAlpha = true
                    -- self:SetAlpha(0)
                    self._spellStyler_settingAlpha = false
                end
            end)
            
            local function hookCallback(self)
                local uniqueID = self.spellStyler_spellID
                local classSpecialization = FrameTrackerManager:GetCurrentSpecID()
                --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
                local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
                if hasSpecialization and uniqueID and SpellStyler_frames[trackerType][uniqueID] then
                    -- For buffs, track active state based on visibility
                    local isShown = false
                    pcall(function() 
                        isShown = self:IsShown()
                    end)
                    if trackerType == "buffs" then
                        local durationObj = nil
                        pcall(function()
                            --if the icon does NOT have a custom texture, then update it dynamically
                            if not SpellStyler_frames[trackerType][uniqueID].meta.customTexture then
                                local frame = SpellStyler_frames[trackerType][uniqueID]
                                local icon = self.Icon or self.icon
                                local texture = (icon.GetTexture and icon:GetTexture()) or icon.texture or self.spellStyler_texture
                                frame.icon:SetTexture(texture)
                            end
                        end)
                        pcall(function()
                            durationObj = C_UnitAuras.GetAuraDuration("player", self:GetAuraSpellInstanceID())
                            if durationObj then
                                local frame = SpellStyler_frames[trackerType][uniqueID]
                                FrameTrackerManager:ApplyCooldownDuration({
                                    customFrame = frame,
                                    uniqueID = uniqueID,
                                    trackerType = trackerType,
                                    config = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType),
                                    durationObject = durationObj
                                })
                            end
                        end)
                        FrameTrackerManager:UpdateFrame_AuraEvent(uniqueID)
                    end
                end
            end

            if cdm_frame.RefreshApplications then hooksecurefunc(cdm_frame, "RefreshApplications", hookCallback) end
            if cdm_frame.RefreshActive then hooksecurefunc(cdm_frame, "RefreshActive", hookCallback) end
            if cdm_frame.UpdateShownState then hooksecurefunc(cdm_frame, "UpdateShownState", hookCallback) end

            local sourceCooldown = cdm_frame.Cooldown or cdm_frame.cooldown

            -- SetCooldownFromDurationObject hook reserved for future use.

            if sourceCooldown and not cdm_frame.hasHookedCooldown then
                cdm_frame.hasHookedCooldown = true
                hooksecurefunc(sourceCooldown, "SetCooldown", function(self, start, duration)
                    local suc, err = pcall(function()
                        local classSpecialization = FrameTrackerManager:GetCurrentSpecID()
                        --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
                        local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
                        if not hasSpecialization then return end
                        local uniqueID = self.spellStyler_spellID
                        local customFrame = SpellStyler_frames[trackerType][uniqueID]
                        if not customFrame then return end
                        local spellInfo = C_Spell.GetSpellInfo(uniqueID)
                        local durationObj = nil
                        if trackerType ~= "buffs" then return end
                        local success, erro = pcall(function()
                            durationObj = C_UnitAuras.GetAuraDuration("player", cdm_frame:GetAuraSpellInstanceID())
                            customFrame.meta.currentAuraInstanceID = cdm_frame:GetAuraSpellInstanceID()
                            if durationObj then
                                FrameTrackerManager:ApplyCooldownDuration({
                                    customFrame = customFrame,
                                    uniqueID = uniqueID,
                                    trackerType = trackerType,
                                    config = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType),
                                    durationObject = durationObj
                                })
                            end
                        end)
                    end)
                end)
            end
        end
    end
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================
local hasPlayerEnetedWorld = false

function FrameTrackerManager:Initalize()
    if isInitialized or not hasPlayerEnetedWorld then return end
    isInitialized = true

    FrameTrackerManager:SetupCooldownManagerHooks()
    C_Timer.After(3, function()
        -- Re-setup hooks in case viewer was recreated
        FrameTrackerManager:SetupCooldownManagerHooks()
    end)
end



--- @class ApplyCooldownDurationData
--- @field uniqueID number
--- @field config table
--- @field trackerType string
--- @field customFrame table
--- @field forceUpdate? boolean
--- @field durationObject? table    -- optional pre-resolved duration object; when set, the C_Spell lookup is skipped
--- @field currentCharges? number   -- caller-supplied charge count for UpdateFrame_ChargeVisibility (0 = on cooldown)

--- @param data ApplyCooldownDurationData
function FrameTrackerManager:ApplyCooldownDuration(data)
    local durationObject = data.durationObject  -- optional pre-resolved duration object
    local s, e
    if not durationObject then
        s, e = pcall(function()
            -- try to get spell charge duration first
            durationObject = C_Spell.GetSpellChargeDuration(data.customFrame.meta.activeSpellID)
            if not durationObject then
                --if that failed, maybe it was a spell without charges
                durationObject = C_Spell.GetSpellCooldownDuration(data.customFrame.meta.activeSpellID)
            end
        end)
    end
    if data.forceUpdate then
        data.customFrame.cooldown:Clear()
    end
    local spellInfo = C_Spell.GetSpellInfo(data.customFrame.meta.activeSpellID)
    if e or not durationObject then
        return
    end
    if data.customFrame.statusBar and data.customFrame.statusBar.SetTimerDuration then
        local cdTimerDir = (data.config and data.config.statusBar and data.config.statusBar.fillOrEmpty == 'inverse')
            and Enum.StatusBarTimerDirection.ElapsedTime
            or  Enum.StatusBarTimerDirection.RemainingTime
        local cdFillStyle = (data.config and data.config.statusBar and data.config.statusBar.progressDirection == 'reverse')
        local textureRotation = (data.config and data.config.statusBar and data.config.statusBar.textureRotation or 0)
        if textureRotation then
            data.customFrame.statusBar:RotateTextures(textureRotation)
        end
        data.customFrame.statusBar:SetFillStyle(cdFillStyle and Enum.StatusBarFillStyle.Reverse or Enum.StatusBarFillStyle.Standard)
        data.customFrame.statusBar:SetTimerDuration(
            durationObject,
            Enum.StatusBarInterpolation.Immediate,
            cdTimerDir
        )
        --Apply cooldown to the statusbar first and set hidden. If a real cooldown is happening, the SetScript('OnShow') callback for the cooldown frame will properly apply the visibility
        if not data.customFrame.meta.isDurationActive then
            local showstatusBar = (
                data.config.statusBar.displayState == "always"
                or data.config.statusBar.displayState == "available"
                or data.config.statusBar.displayState == "inactive"
            )
            local suc, err = pcall(function()
                if showstatusBar then
                    local barColor = data.config.statusBar.color
                    local isFull = data.config.statusBar.defaultFillValue == 'full'
                    data.customFrame.statusBar:Show()
                    data.customFrame.statusBar:SetStatusBarColor(
                        barColor.r or 0.2,
                        barColor.g or 0.8,
                        barColor.b or 1,
                        0  -- always hide the timer-driven fill; fullCoverTexture handles the 'full' visual
                    )
                    -- data.customFrame.statusBar:SetValue(isFull and 1 or 0)
                    -- Show/hide the cover texture for 'full' defaultFillValue.
                    -- This overlay sits above the fill (ARTWORK sublayer 1) and visually
                    -- fills the bar without interacting with SetTimerDuration, so it is
                    -- immune to GCD timer interference.
                    if data.customFrame.statusBar.fullCoverTexture then
                        if isFull then
                            local c = data.config.statusBar.color
                            data.customFrame.statusBar.fullCoverTexture:SetVertexColor(c.r or 0.2, c.g or 0.8, c.b or 1, c.a or 0.9)
                            data.customFrame.statusBar.fullCoverTexture:Show()
                        else
                            data.customFrame.statusBar.fullCoverTexture:Hide()
                        end
                    end
                else
                    data.customFrame.statusBar:Hide()
                end
            end)
        end
    end
    data.customFrame.cooldown:SetCooldown(durationObject:GetStartTime(), durationObject:GetTotalDuration())
    FrameTrackerManager:ApplyStatusBar_OnlyRenderBar(data)
end



--- @param spellID number
--- @return ApplyCooldownDurationData|nil
function FrameTrackerManager:MatchTrackerFrame(spellID)
    local match = nil
    --[[
        -- This should match the values used by apply Cooldown Duration
        match = {
            forceUpdate -- optional
            customFrame
            uniqueID
            trackerType,
            config
        }
    ]]
    local matchType = ''
    for _, tType in ipairs({"essential", "utility"}) do
        for trackerID, trackedFrame in pairs(SpellStyler_frames[tType]) do
            local overRideID = C_Spell.GetOverrideSpell(trackerID)
            if trackerID == spellID then
                matchType = 'direct'
                
            elseif overRideID == spellID then
                matchType = 'override'
            end
            --match found, update the return data
            if matchType ~= '' then
                local spellInfo = C_Spell.GetSpellInfo(spellID)
                match = {
                    matchType = matchType,
                    config = FrameTrackerManager:GetSpecificTrackerValue(trackerID, tType),
                    uniqueID = trackerID,
                    customFrame = trackedFrame,
                    trackerType = tType
                }
                return match
            end
        end
    end
    return match
end



-- Event frame for UNIT_AURA and PLAYER_ENTERING_WORLD
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("SPELL_UPDATE_ICON")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")


eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        hasPlayerEnetedWorld = true
        FrameTrackerManager:Initalize()
    end
    if event == "PLAYER_LEAVING_WORLD" then
        hasPlayerEnetedWorld = false
    end
    local classSpecialization = FrameTrackerManager:GetCurrentSpecID()
    --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
    local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
    if (event ~= "UNIT_SPELLCAST_SUCCEEDED") and (hasPlayerEnetedWorld == false or not hasSpecialization) then
        return
    end

    if event == "SPELL_UPDATE_CHARGES" then
        for _, tType in ipairs({"essential", "utility"}) do
            for uniqueID, customFrame in pairs(SpellStyler_frames[tType]) do
                local match = FrameTrackerManager:MatchTrackerFrame(uniqueID)
                if match then
                    FrameTrackerManager:UpdateFrame_copyCharges(match)
                end
            end
        end
    end
    if event == "UNIT_AURA" then
        local unitTarget, updateInfo = ...
        local db = FrameTrackerManager:GetDataBase_V2()
        local removedAuraInstanceID = updateInfo.removedAuraInstanceIDs
        if unitTarget ~= "player" or not removedAuraInstanceID then return end
        local removedAuraSet = {}
        for _, auraID in ipairs(removedAuraInstanceID) do
            removedAuraSet[auraID] = true
        end
        
        for uniqueID, customFrame in pairs(SpellStyler_frames["buffs"]) do
            local currentAuraInstanceID = customFrame.meta.currentAuraInstanceID or 0
            if removedAuraSet[currentAuraInstanceID] then
                customFrame.cooldown:Clear()
                customFrame.statusBar:SetValue(0)
                FrameTrackerManager:UpdateFrame_AuraEvent(uniqueID)
                FrameTrackerManager:UpdateFrame_Duration_Inactive({
                    uniqueID = uniqueID,
                    trackerType = 'buffs',
                    config = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, 'buffs'),
                    customFrame = customFrame
                })
            end
        end
    end
    if event == "SPELL_UPDATE_ICON" then
        local spellID = ...
        if not spellID then return end
        pcall(function()
            local match = FrameTrackerManager:MatchTrackerFrame(spellID)
            if match then
                local spellInfo = C_Spell.GetSpellInfo(spellID)
                if match.config.iconSettings.iconTexturePath == nil or match.config.iconSettings.iconTexturePath == '' then
                    match.customFrame.icon:SetTexture(spellInfo.iconID)
                end

                match.customFrame.meta.activeSpellID = C_Spell.GetOverrideSpell(match.uniqueID)
                

                -- When the override reverts the spell may lose (or gain) charges;
                -- refresh the charge count display immediately.
                local chargesObj = C_Spell.GetSpellCharges(match.customFrame.meta.activeSpellID)
                match.customFrame.meta.isSpellWithCharges = chargesObj ~= nil

                -- When the spell Icon changes, its possible the spell itsself has changed. Clear any active cooldown and attempt to reapply. This might be effective like when crusader strike changes back into avenging crusader (which would still be on cooldown)
                FrameTrackerManager:ApplyCooldownDuration(match)
                -- If the spell mutates back into the original, its possible the cooldown frame show/hide events dont fire if the mutated spell was on cooldown when it changes back to the original. Doube check is "isDurationActive" to called the method if needed
                if match.customFrame.meta.isDurationActive then
                    FrameTrackerManager:UpdateFrame_Duration_Active(match)
                end
            end
        end)
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unitTarget, castGUID, spellID, castBarID = ...
        local isSecretSpellID = issecretvalue(spellID)
        local s, e = pcall(function()
            if isSecretSpellID then
            else
                -- Detect talent changes (spell 384255 is the talent change spell)
                if spellID == 384255 or spellID == 200749 then
                    C_Timer.After(0.5, function()
                        local classSpecialization = FrameTrackerManager:GetCurrentSpecID()
                        --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
                        local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
                        FrameTrackerManager:HandleTalentChange()
                    end)
                    return
                end
                local classSpecialization = FrameTrackerManager:GetCurrentSpecID()
                --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
                local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
                if not hasSpecialization then
                    return
                end
                --make sure "SPELL_UPDATE_ICON" is processed first
                C_Timer.After(0, function()
                    local match = FrameTrackerManager:MatchTrackerFrame(spellID)

                    if match then
                        local override = C_Spell.GetOverrideSpell(spellID)
                        if override ~= spellID then
                            local spellInfoUpdate = C_Spell.GetSpellInfo(override)
                            --The spell that was cast, is not equal to the active spell (likely due to changing via its cast). Wait for the spell cast to match the active in order to apply to correct/active cooldown
                            --Save the override spell onto the frame though to be able to check future casts
                            match.customFrame.meta.activeSpellID = override

                            --assume that when a spell cast results in a mutation, the new spell starts OFF cooldown. Call the method based on that assumption.
                            FrameTrackerManager:UpdateFrame_Duration_Inactive(match)
                            -- Attempt to update charges if it mutated into a spell with charges
                            FrameTrackerManager:UpdateFrame_copyCharges(match)
                        else
                            local spellInfo = C_Spell.GetSpellInfo(spellID)
                            FrameTrackerManager:ApplyCooldownDuration(match)
                        end
                    end
                    
                    for _, tType in ipairs({"essential", "utility"}) do
                        for uniqueID, trackedFrame in pairs(SpellStyler_frames[tType]) do
                            -- skip the frame that was already matched
                            if not match or uniqueID ~= match.uniqueID or tType ~= match.trackerType then
                                local spellInfo = C_Spell.GetSpellInfo(uniqueID)
                                if trackedFrame.meta.isDurationActive then
                                    FrameTrackerManager:ApplyCooldownDuration({
                                        customFrame = trackedFrame,
                                        uniqueID = uniqueID,
                                        trackerType = tType,
                                        config = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, tType)
                                    })
                                end
                            end
                        end
                    end
                end)
            end
        end)
    end
    if event == "SPELL_UPDATE_COOLDOWN" then
        local spellID, baseSpellID, category, startRecoveryCategory = ...
        if not spellID then
            return
        end
        local spellInfo = C_Spell.GetSpellInfo(spellID)
        local cooldownInfo = C_Spell.GetSpellCooldown(spellID)
        local frameMatchData = FrameTrackerManager:MatchTrackerFrame(spellID)
        if frameMatchData then
            local success, error = pcall(function()
                if cooldownInfo.isOnGCD == true then
                    return  -- GCD only – nothing to do
                end
                -- local baseSpellInfo = C_Spell.GetSpellInfo(spellID)
                local overrideSpellID = C_Spell.GetOverrideSpell(spellID)
                -- local overrideSpellInfo = C_Spell.GetSpellInfo(overrideSpellID)
                if overrideSpellID ~= frameMatchData.customFrame.meta.activeSpellID then
                    --The spell that was cast, is not equal to the active spell (likely due to changing via its cast). Wait for the spell cast to match the active in order to apply to correct/active cooldown
                    --Save the override spell onto the frame though to be able to check future casts
                    frameMatchData.customFrame.meta.activeSpellID = overrideSpellID

                    --assume that when a spell cast results in a mutation, the new spell starts OFF cooldown. Call the method based on that assumption.
                    -- FrameTrackerManager:UpdateFrame_Duration_Inactive(frameMatchData)
                    return
                end

                if (cooldownInfo.isOnGCD == nil or frameMatchData.customFrame.meta.isSpellOffGCD == true) and frameMatchData.customFrame.meta.isSpellWithCharges then
                    --[[
                        ignore off GCD spells with charges. This event cant destinguish if the spell still have available charges.
                        Attempt to Manually track charges - If anyone reports an error with charges - check if the spell is off GCD - if so, change to using "SPELL_UPDATE_CHARGES" and SetAlpha to controll visibility
                        Also set on the frame the type of spell this is
                    ]]
                    frameMatchData.customFrame.meta.isSpellOffGCD = true
                    frameMatchData.customFrame.meta.spellChargeCount = frameMatchData.customFrame.meta.spellChargeCount - 1
                    if frameMatchData.customFrame.meta.spellChargeCount == 0 then
                        frameMatchData.customFrame.meta.canBeCast = false    
                    end
                else
                    -- If the spell is on GCD, but cooldownInfo.isOnGCD == false, then it was a valid cast, or its off the gcd but can only be cast once.
                    frameMatchData.customFrame.meta.canBeCast = false
                end
                FrameTrackerManager:ApplyCooldownDuration(frameMatchData)
                -- the spell might already be on cooldown if its a spell with charges. Call "UpdateFrame_Duration_Active" again because the can BeCast flag is updated and could cause the icon to hide (among other parts of the frame)
                if frameMatchData.customFrame.meta.isDurationActive then
                    FrameTrackerManager:UpdateFrame_Duration_Active(frameMatchData)
                end
            end)
        end
    end
end)


