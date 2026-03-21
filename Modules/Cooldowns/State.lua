local ADDON_NAME, SpellStyler = ...
SpellStyler.State = SpellStyler.State or {}
local State = SpellStyler.State
local FrameTrackerManager  -- lazily resolved on first use (avoids load-order nil)
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
            isSpellOffGCD = false,
            frameStrataLevel = "MEDIUM", -- BACKGROUND LOW MEDIUM HIGH DIALOG FULLSCREEN FULLSCREEN_DIALOG TOOLTIP
            frameStrataValue = 100
        },
        glowNotification = {
            shouldDisplay = false,
            glowStyle = 'thin', -- 'thick'
            duration = 1,
            glowColor = {
                r = 1,
                g = 1,
                b = 1,
                a = 1
            }
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
function State:GetCurrentSpecID()
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
function State:GetDataBase_V2()
    local classSpecialization = State:GetCurrentSpecID()
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
    specDB.globalSettings = specDB.globalSettings or {
        visibilitySettings = {
            hideWhenOutOfCombat = false,
        }
    }
    -- Ensure nested tables always exist for older saved data
    specDB.globalSettings.visibilitySettings = specDB.globalSettings.visibilitySettings or {
        hideWhenOutOfCombat = false,
    }

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

function State:HandleTalentChange()
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
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

function State:AddTrackerValue(trackerValueConstructorData)
    local db = State:GetDataBase_V2()
    local trackerType = trackerValueConstructorData.trackerType or "buffs"
    db[trackerType][trackerValueConstructorData.uniqueID] = AddNewTrackerValueConfig(trackerValueConstructorData)
    return db[trackerType][trackerValueConstructorData.uniqueID]
end

function State:ResetTrackerValueConfig(uniqueID, trackerType)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
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
    if FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][uniqueID] then
        FrameTrackerManager:UpdateFrame_ConfigurationChanges(uniqueID, trackerType)
        FrameTrackerManager:UpdateFrame_copyCharges({
            customFrame = FrameTrackerManager.SpellStyler_frames[trackerType][uniqueID],
            config = existing,
            uniqueID = uniqueID,
            trackerType = trackerType
        })
    end
end

function State:GetAllTrackerValues(trackerType)
    local db = State:GetDataBase_V2()
    if not db then return {} end
    return db[trackerType]
end

function State:GetSpecificTrackerValue(uniqueID, trackerType)
    local db = State:GetDataBase_V2()
    local iconConfig = db[trackerType][uniqueID] or {}
    -- Migrate legacy barFillDirection -> fillOrEmpty (one-time per-entry migration)
    if iconConfig.statusBar and iconConfig.statusBar.barFillDirection ~= nil and iconConfig.statusBar.fillOrEmpty == nil then
        iconConfig.statusBar.fillOrEmpty = iconConfig.statusBar.barFillDirection
        iconConfig.statusBar.barFillDirection = nil
    end
    -- Backfill glowNotification for entries created before this setting existed
    if iconConfig.glowNotification == nil then
        iconConfig.glowNotification = {
            shouldDisplay = false,
            glowStyle = 'thin',
            duration = 1,
            glowColor = { r = 1, g = 1, b = 1, a = 1 },
        }
    end
    return iconConfig
end

function State:CheckIsAlreadyTracker(uniqueID, trackerType)
    local db = State:GetDataBase_V2()
    return db[trackerType][uniqueID] and true or false
end

function State:RemoveTrackerValue(uniqueID, trackerType)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    if State:CheckIsAlreadyTracker(uniqueID, trackerType) then
        -- Clean up the frame
        local frame = FrameTrackerManager.SpellStyler_frames[trackerType][uniqueID]
        if frame then
            frame:Hide()
            frame:ClearAllPoints()
            FrameTrackerManager.SpellStyler_frames[trackerType][uniqueID] = nil
        end
        
        -- Remove from database
        db[trackerType][uniqueID] = nil
    end
end

function State:SetTrackerValueConfigProperty(uniqueID, trackerType, path, value)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    accessNestedValue(db[trackerType][uniqueID], path, value, "set")
    local trackerValue = db[trackerType][uniqueID]
    if trackerValue and FrameTrackerManager.SpellStyler_frames[trackerType][uniqueID] then
        FrameTrackerManager:UpdateFrame_ConfigurationChanges(uniqueID, trackerType)
        FrameTrackerManager:UpdateFrame_copyCharges({
            config = trackerValue,
            customFrame = FrameTrackerManager.SpellStyler_frames[trackerType][uniqueID],
            uniqueID = uniqueID,
            trackerType = trackerType
        })
    end
end

function State:GetTrackerValueConfigProperty(uniqueID, trackerType, path)
    local db = State:GetDataBase_V2()
    return accessNestedValue(db[trackerType][uniqueID], path, nil, "get")
end

function State:getTrackerValuesListForSettings()
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local listTrackerValues = {}
    for key, value in ipairs({ "buffs", "essential", "utility" }) do
        local trackerValues = State:GetAllTrackerValues(value)
        -- Loop through the buffs values
        for uniqueID, trackerValue in pairs(trackerValues) do
            -- Only add frames that are currently tracked by the cooldown manager
            if FrameTrackerManager.cooldownManagerFrames[value][uniqueID] then
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


function State:CopySettings(copyInfo)
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
    
    local sourceConfig = State:GetSpecificTrackerValue(copyInfo.sourceUniqueID, copyInfo.sourceTrackerType)
    State:SetTrackerValueConfigProperty(copyInfo.targetUniqueID, copyInfo.targetTrackerType, key, sourceConfig[key])
end



function State:GetGlobalSettings()
    local db = State:GetDataBase_V2()
    return db.globalSettings
end

--- Applies the globalSettings.visibilitySettings to all tracker frames.
--- Called on PLAYER_REGEN_ENABLED / PLAYER_REGEN_DISABLED.
--- Uses SetAlpha so cooldown callbacks keep firing regardless of visibility.
function State:ApplyGlobalVisibility()
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local gs = State:GetGlobalSettings()
    if not gs then return end
    if not gs.visibilitySettings then
        gs.visibilitySettings = { hideWhenOutOfCombat = false }
    end
    local vs = gs.visibilitySettings

    local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
    local shouldShow = not (vs.hideWhenOutOfCombat and not inCombat)

    for _, trackerType in ipairs({"buffs", "essential", "utility"}) do
        for _, frame in pairs(FrameTrackerManager.SpellStyler_frames[trackerType]) do
            if shouldShow then
                frame:Show()
            else
                frame:Hide()
            end
        end
    end
end