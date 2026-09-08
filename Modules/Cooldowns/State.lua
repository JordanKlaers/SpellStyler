local ADDON_NAME, SpellStyler = ...
SpellStyler.State = SpellStyler.State or {}
local State = SpellStyler.State
local FrameTrackerManager  -- lazily resolved on first use (avoids load-order nil)
function State:AccessNestedValue(tbl, path, value, action)
    local keys = {}
    for key in string.gmatch(path, "[^.]+") do
        table.insert(keys, key)
    end
    local current = tbl
	if current == nil then
		return
	end
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

-- ============================================================================
-- DEEP COPY HELPER
-- Returns a fully independent recursive copy of `orig`.
-- Primitives are copied by value; tables are recursively cloned so the result
-- shares no references with the source.
-- ============================================================================
local function DeepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        for k, v in pairs(orig) do
            copy[k] = DeepCopy(v)
        end
    else
        copy = orig
    end
    return copy
end

-- ============================================================================
-- DEEP MERGE HELPER
-- Recursively fills missing keys in `target` with values from `defaults`.
-- Existing values in `target` are never overwritten.
-- ============================================================================
local function DeepMergeDefaults(target, defaults)
    for k, defaultVal in pairs(defaults) do
        if target[k] == nil then
            if type(defaultVal) == "table" then
                target[k] = {}
                DeepMergeDefaults(target[k], defaultVal)
            else
                target[k] = defaultVal
            end
        elseif type(target[k]) == "table" and type(defaultVal) == "table" then
            DeepMergeDefaults(target[k], defaultVal)
        end
    end
end

local function AddNewTrackerValueConfig(data)
    local iconSize = 48  -- Default icon size
    return {
        baseSpellID = data.baseSpellID,
        itemID = data.itemID,
		isEnabled = true,
		overrideSpellID = data.overrideSpellID,
        trackerType = data.trackerType, -- essential, utility, buffs
        name = data.name,
        defaultIconTexturePath = data.defaultIconTexturePath,
        isItem = data.isItem or false,  -- Flag to identify item trackers (for icon lookup)
        scale = 1,
        auraSpecs = data.auraSpecs or {
            -- table to indicate which specs the aura should be enabled for
        },
        isNPCDebuff = data.trackerType == 'buffs' and false or nil,  -- For buffs: track as debuff on target instead of buff on player
        additionalBuffIDs = {},
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
            disableDragging = false,
            displayCharges = data.trackerType == 'buffs' and true or false,
            iconDisplayState = data.trackerType == 'buffs' and 'available' or "always", -- "always", "active/cooldown", "inactive/available", "never"
            iconTexturePath = "",
            desaturated = false,
            enabled = true,
            size = nil, -- deprecated; use width/height
            width = 48,
            height = 48,
            opacity = 1,
            hideDefaultSweep = false,
            hideCooldownBling = false,
            isSpellOffGCD = false,
            insufficientPower = false,
            insufficientPowerIconColor = {
                r = 1,
                g = 0,
                b = 0,
                a = 1,
            },
            frameStrataLevel = "MEDIUM", -- BACKGROUND LOW MEDIUM HIGH DIALOG FULLSCREEN FULLSCREEN_DIALOG TOOLTIP
            frameStrataValue = 100,
            zoom = 0,
            borderSize = 0,
            borderColor = {
                r = 1,
                g = 1,
                b = 1,
                a = 0,
            }
        },
        -- Applied instead of the base iconSettings/iconColor when the spec-active override
        -- spell differs from the tracked baseSpellID (e.g. stance/form-swapped spells).
        iconSettingsOverrides = {
            enabled = false,
            iconColorOverride = { r = 1, g = 1, b = 1, a = 1 },
            iconTexturePathOverride = ""
        },
        chargeBasedDisplay = {
            enabled = false,
            displayState = true, -- true == show, false == hdie
            displayOperator = ">",
            chargeValue = 0
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
            font = "default",  -- Font selection: "default" = use global, or specific font name
            fontFlags = "default",  -- Font flags: "default" = use global, or single flag: "OUTLINE", "THICKOUTLINE", "MONOCHROME"
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
            font = "default",  -- Font selection: "default" = use global, or specific font name
            fontFlags = "default",  -- Font flags: "default" = use global, or single flag: "OUTLINE", "THICKOUTLINE", "MONOCHROME"
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
            font = "default",  -- Font selection: "default" = use global, or specific font name
            fontFlags = "default",  -- Font flags: "default" = use global, or single flag: "OUTLINE", "THICKOUTLINE", "MONOCHROME"
            color = {
                r = 1,
                g = 1,
                b = 1,
                a = 1,
            },
            x = 0,
            y = 0,
            useSpellDisplayCount = false,
        },
        statusBar = {
            includeTotemDuration = false,
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
        visualChargeBar = {
            displayState = "never",  -- "always", "never", "available" (show when >= 1)
            defaultBarTexture = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarFill.tga",
            customBarTexture = "",
            onlyRenderBar = false,
            barOrientation = "horizontal",
            fillOrEmpty = "regular",
            progressDirection = "standard",
            textureRotation = 0,
            defaultFillValue = "empty",
            color = { r = 0.2, g = 0.8, b = 1, a = 0.9 },
            backgroundColor = { r = 0, g = 0, b = 0, a = 0.65 },
            glowColor = { r = 1, g = 1, b = 1, a = 0.25 },
            borderColor = { r = 0, g = 0, b = 0, a = 1 },
            borderScale = 0.5,
            scale = 1,
            x = 0,
            y = 0,
            width = iconSize * 5,
            height = iconSize / 2,
            anchorParent = "RIGHT",
            anchorSelf = "LEFT",
            minValue = 0,
            maxValue = 5
        },
		specialVisibilityConditions = {},
        devNotes = {

        },
        totemBar = {
            attemptToTrack = false,
            displayState = 'never', --always, active, never
            defaultBarTexture = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarFill.tga",
            customBarTexture = "",
            onlyRenderBar = false,
            barOrientation = "horizontal",
            fillOrEmpty = "regular",
            progressDirection = "standard",
            textureRotation = 0,
            defaultFillValue = "empty",
            color = { r = 0.2, g = 0.8, b = 1, a = 0.9 },
            backgroundColor = { r = 0, g = 0, b = 0, a = 0.65 },
            glowColor = { r = 1, g = 1, b = 1, a = 0.25 },
            borderColor = { r = 0, g = 0, b = 0, a = 1 },
            borderScale = 0.5,
            scale = 1,
            x = 0,
            y = 0,
            width = iconSize * 5,
            height = iconSize / 2,
            anchorParent = "RIGHT",
            anchorSelf = "LEFT",
        }
    }
end

function State:GetClassAndSpecInfo()
    local specIndex = GetSpecialization()
    local specID = GetSpecializationInfo(specIndex)
    local classID = C_SpecializationInfo.GetClassIDFromSpecID(specID)
    local numSpecs = C_SpecializationInfo.GetNumSpecializationsForClassID(classID)
    local specs = {}
    for i = 1, numSpecs do
        local specId, name, description, icon, role, primaryStat, pointsSpent, background, previewPointsSpent, isUnlocked = C_SpecializationInfo.GetSpecializationInfo(i)
        specs[i] = {
            specId = specId,
            name = name,
            description = description,
            icon = icon,
            role = role,
            primaryStat = primaryStat,
            pointsSpent = pointsSpent,
            background = background,
            previewPointsSpent = previewPointsSpent,
            isUnlocked = isUnlocked
        }
    end
    return {
        specIndex = specIndex,
        currentSpecID = specID,
        classID = classID,
        numSpecs = numSpecs,
        specs = specs
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
    specDB.spells = specDB.spells or {}
    specDB.items = specDB.items or {}
    specDB.docks = specDB.docks or {}
    specDB.globalSettings = specDB.globalSettings or {
        visibilitySettings = {
            hideWhenOutOfCombat = false,
        },
        fontSettings = {
            globalFont = "Friz Quadrata TT",  -- Default WoW font
            globalFontFlags = "OUTLINE",  -- Default font flags
            overrideAllFonts = false,
        }
    }
    -- Ensure nested tables always exist for older saved data
    specDB.globalSettings.visibilitySettings = specDB.globalSettings.visibilitySettings or {
        hideWhenOutOfCombat = false,
    }
    specDB.globalSettings.fontSettings = specDB.globalSettings.fontSettings or {
        globalFont = "Friz Quadrata TT",
        globalFontFlags = "OUTLINE",
        overrideAllFonts = false,
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
    -- Frame teardown (Hide + table wipe) was already done synchronously by
    -- FrameTrackerManager:TeardownSpecFrames() the moment the talent spell was
    -- detected. By the time this deferred call runs both tables are empty.
    -- Reset them again defensively in case HandleTalentChange is ever called
    -- from a path that didn't go through TeardownSpecFrames.

    -- FrameTrackerManager:TeardownSpecFrames()
    -- Re-hook all buff cooldown frames
    FrameTrackerManager:FreshCreateFrames("talent_change")

	local specDB = SpellStyler_CharDB.classSpecializations[State:GetCurrentSpecID()]

    SpellStyler.BuffManager:CreateBuffContainers()
end

-- ============================================================================
-- DATABASE MIGRATION
-- Called once from Main.lua Initialize() on PLAYER_LOGIN.
--
-- IMPORTANT: Steps that call C_Spell.GetBaseSpell / C_Spell.GetOverrideSpell
-- are SPEC-SENSITIVE — the same spell ID can resolve to a completely different
-- base/override depending on which spec is currently loaded (e.g. Holy Bulwark
-- exists as a standalone spell on Protection but is an override of Divine Toll
-- on Holy). Running those steps against an offline spec's DB would remap and
-- corrupt entries using the wrong spec's game state, potentially deleting spells
-- entirely. Those steps run ONLY for the currently active spec. All
-- spec-agnostic structural fixes (table init, utility/essential migration,
-- barFillDirection rename, DeepMergeDefaults backfill) are safe to run on
-- every stored spec.
-- ============================================================================
function State:MigrateDatabase()
    if not SpellStyler_CharDB or not SpellStyler_CharDB.classSpecializations then return end

    local currentSpecID = State:GetCurrentSpecID()
    for specID, specDB in pairs(SpellStyler_CharDB.classSpecializations) do
        -- Ensure destination tables exist
        specDB.spells    = specDB.spells    or {}
        specDB.buffs     = specDB.buffs     or {}
        specDB.essential = specDB.essential or {}
        specDB.utility   = specDB.utility   or {}
        specDB.items     = specDB.items     or {}

        -- ── Move utility & essential entries into spells ─────────────────
        -- Safe on all specs: pure table reshuffling, no spell API calls.
        for _, srcType in ipairs({ "utility", "essential" }) do
            for trackerKey, trackerValue in pairs(specDB[srcType]) do
                if not specDB.spells[trackerKey] then
                    trackerValue.trackerType = "spells"
                    specDB.spells[trackerKey] = trackerValue
                end
                specDB[srcType][trackerKey] = nil
            end
        end

        -- ── Move items from spells to items table ────────────────────────
        -- Safe on all specs: pure table reshuffling, no spell API calls.
        -- Legacy: items were previously stored in spells table with isItem flag
        for trackerKey, trackerValue in pairs(specDB.spells) do
            if trackerValue.isItem then
                if not specDB.items[trackerKey] then
                    trackerValue.trackerType = "items"
                    specDB.items[trackerKey] = trackerValue
                end
                specDB.spells[trackerKey] = nil
            end
        end

        -- ── Validate & backfill structure for every tracked entry ────────
        -- Safe on all specs: only reads existing values and fills missing keys.
        for _, trackerType in ipairs({ "buffs", "spells", "items" }) do
            for trackerKey, trackerValue in pairs(specDB[trackerType]) do
                -- Legacy: barFillDirection -> fillOrEmpty
                if trackerValue.statusBar
                    and trackerValue.statusBar.barFillDirection ~= nil
                    and trackerValue.statusBar.fillOrEmpty == nil
                then
                    trackerValue.statusBar.fillOrEmpty = trackerValue.statusBar.barFillDirection
                    trackerValue.statusBar.barFillDirection = nil
                end


                if trackerValue.statusBar.includeTotemDuration == nil and trackerValue.totemBar.attemptToTrack then
                    trackerValue.statusBar.includeTotemDuration = true
                end
                -- Legacy: countText.renderAsStatusBar -> visualChargeBar.displayState
                -- This migration ensures users who had the old checkbox get proper displayState values
                if trackerValue.countText and trackerValue.countText.renderAsStatusBar ~= nil then
                    -- Initialize visualChargeBar if it doesn't exist
                    if not trackerValue.visualChargeBar then
                        trackerValue.visualChargeBar = {}
                    end
                    -- Only migrate if displayState hasn't been set yet
                    if not trackerValue.visualChargeBar.displayState then
                        if trackerValue.countText.renderAsStatusBar == true then
                            trackerValue.visualChargeBar.displayState = "always"
                        else
                            trackerValue.visualChargeBar.displayState = "never"
                        end
                    end
                    -- Clean up the old field
                    trackerValue.countText.renderAsStatusBar = nil
                end

                if trackerType == 'buffs' then
                    if trackerValue.statusBar.displayState == 'inactive' then trackerValue.statusBar.displayState = 'never' end
                    if trackerValue.statusBar.displayState == 'always' then trackerValue.statusBar.displayState = 'active' end
                    if trackerValue.visualChargeBar.displayState == 'inactive' then trackerValue.visualChargeBar.displayState = 'never' end
                    if trackerValue.visualChargeBar.displayState == 'always' then trackerValue.visualChargeBar.displayState = 'active' end
                    if trackerValue.iconSettings.iconDisplayState ~= 'active' and trackerValue.iconSettings.iconDisplayState ~= 'never' then trackerValue.iconSettings.iconDisplayState = 'active' end
                    local classAndSpecData = SpellStyler.State:GetClassAndSpecInfo()
                    if not trackerValue.auraSpecs then
                        trackerValue.auraSpecs = {}
                    end
                    if next(trackerValue.auraSpecs) == nil then
                        for _, spec in ipairs(classAndSpecData.specs) do
                            trackerValue.auraSpecs[spec.specId] = classAndSpecData.currentSpecID == spec.specId
                        end
                    end
                    local isEnabledForAnyAura = false
                    for _, spec in ipairs(classAndSpecData.specs) do
                        isEnabledForAnyAura = isEnabledForAnyAura or trackerValue.auraSpecs[spec.specId]
                    end
                    if not isEnabledForAnyAura and trackerValue.isEnabled then
                        trackerValue.auraSpecs[classAndSpecData.currentSpecID] = true
                    end
                end
                local defaults = AddNewTrackerValueConfig({
                    baseSpellID            = trackerValue.baseSpellID,
                    trackerType            = trackerType,
                    name                   = trackerValue.name or C_Spell.GetSpellName(trackerValue.baseSpellID),
                    defaultIconTexturePath = trackerValue.defaultIconTexturePath,
                    overrideSpellID        = trackerValue.overrideSpellID,
                })
                DeepMergeDefaults(trackerValue, defaults)
            end
        end

        -- ── Spec-sensitive steps: ONLY run for the currently loaded spec ──
        -- C_Spell.GetBaseSpell and C_Spell.GetOverrideSpell return results
        -- relative to the active spec. Applying them to a different spec's DB
        -- would remap spell IDs using the wrong spec's data and corrupt/delete
        -- entries (e.g. Holy Bulwark on Prot gets mistaken for an override of
        -- Divine Toll when queried from Holy).
        if specID == currentSpecID then
            -- Remap spells stored under a non-base spell ID to their base ID.
            local spellRemaps = {}
            for trackerKey, trackerValue in pairs(specDB.spells) do
                local baseID = nil
                baseID = C_Spell.GetBaseSpell(trackerValue.baseSpellID)
                if baseID and baseID ~= trackerValue.baseSpellID then
                    table.insert(spellRemaps, { oldID = trackerValue.baseSpellID, newID = baseID, entry = trackerValue })
                end
            end
            for _, remap in ipairs(spellRemaps) do
                local baseID = remap.newID
                if not specDB.spells[baseID] then
                    local entry = remap.entry
                    entry.uniqueID = baseID
                    specDB.spells[baseID] = entry
                end
                local overrideID = baseID
                overrideID = C_Spell.GetOverrideSpell(baseID)
                specDB.spells[baseID].overrideSpellID = overrideID
                specDB.spells[remap.oldID] = nil
            end
        end
    end
end

function State:AddTrackerValue(trackerValueConstructorData)
    local db = State:GetDataBase_V2()
    local trackerType = trackerValueConstructorData.trackerType
	if not trackerType then return end
    local entry = AddNewTrackerValueConfig(trackerValueConstructorData)
    db[trackerType][trackerValueConstructorData.trackerKey] = entry
    return db[trackerType][trackerValueConstructorData.trackerKey]
end

function State:ResetTrackerValueConfig(trackerKey, trackerType)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local existing = db[trackerType] and db[trackerType][trackerKey]
    if not existing then return end
    -- Rebuild from defaults, preserving identity fields
    local defaults = AddNewTrackerValueConfig({
        baseSpellID = existing.baseSpellID,
        trackerType = trackerType,
        name = existing.name,
        defaultIconTexturePath = existing.defaultIconTexturePath,
        overrideSpellID = existing.overrideSpellID,
        isItem = existing.isItem,
    })
    db[trackerType][trackerKey] = defaults
    -- Refresh the live frame if it exists
    if FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey] then
        if SpellStyler.ConditionalEngine then
            SpellStyler.ConditionalEngine:EvaluateAll()
        end
        FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
    end
end

function State:GetAllTrackerValues(trackerType)
    local db = State:GetDataBase_V2()
    if not db then return {} end
    return db[trackerType]
end

function State:GetSpecificTrackerValue(trackerKey, trackerType)
    local db = State:GetDataBase_V2()
    local iconConfig = db[trackerType][trackerKey] or {}
    local foundConfig = db[trackerType][trackerKey] and true or false
    
    -- Ensure visualChargeBar defaults are populated whenever we access tracker config
    if foundConfig then
        State:EnsureVisualChargeBarDefaults(iconConfig)
    end
    
    return iconConfig, foundConfig
end

function State:CheckIsAlreadyTracker(trackerKey, trackerType)
    local db = State:GetDataBase_V2()
    return db[trackerType][trackerKey] and true or false
end

function State:RemoveTrackerValue(trackerKey, trackerType)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    if State:CheckIsAlreadyTracker(trackerKey, trackerType) then
        -- Clean up the frame
        local frame = FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey]
        if frame then
            frame:Hide()
            frame:ClearAllPoints()
            FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey] = nil
        end
        
        -- Remove from database
        db[trackerType][trackerKey] = nil
    end
end

function State:SetTrackerValueConfigProperty(trackerKey, trackerType, path, value)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    State:AccessNestedValue(db[trackerType][trackerKey], path, value, "set")
    local trackerValue = db[trackerType][trackerKey]
    
    -- For buffs, delete and recreate the specific buff
    if trackerType == "buffs" and SpellStyler.BuffManager then
        -- Delete the existing buff container
        if SpellStyler.BuffManager.buffContainers[trackerKey] then
            local containerData = SpellStyler.BuffManager.buffContainers[trackerKey]
            
            -- Hide and clean up aura container
            if containerData and trackerValue then
                SpellStyler.BuffManager:UpdateAura(containerData, trackerValue)
                containerData.auraContainer:UpdateAllAuras()
            end
        end
    elseif trackerValue and FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey] then
        -- For non-buffs, use the existing ApplyStaticFrameProperties approach
        FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
        
        -- Re-evaluate conditionals so variant frame gets proper overrides
        if SpellStyler.ConditionalEngine then
            SpellStyler.ConditionalEngine:EvaluateAll()
        end
    end
end

function State:GetTrackerValueConfigProperty(trackerKey, trackerType, path)
    local db = State:GetDataBase_V2()
    return State:AccessNestedValue(db[trackerType][trackerKey], path, nil, "get")
end

--- Minimal safety net for visualChargeBar config.
--- Only used as a fallback; primary defaults are set via DeepMergeDefaults in MigrateDatabase.
--- @param trackerValue table The tracker configuration
function State:EnsureVisualChargeBarDefaults(trackerValue)
    -- This should rarely trigger since MigrateDatabase handles defaults via DeepMergeDefaults.
    -- Only acts as a safety net if visualChargeBar is completely missing.
    if not trackerValue.visualChargeBar then
        local iconSize = (trackerValue.iconSettings and trackerValue.iconSettings.width) or 
                       (trackerValue.iconSettings and trackerValue.iconSettings.size) or 48
        trackerValue.visualChargeBar = {
            displayState = "never",
            defaultBarTexture = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarFill.tga",
            customBarTexture = "",
            onlyRenderBar = false,
            barOrientation = "horizontal",
            fillOrEmpty = "regular",
            progressDirection = "standard",
            textureRotation = 0,
            defaultFillValue = "empty",
            color = { r = 0.2, g = 0.8, b = 1, a = 0.9 },
            backgroundColor = { r = 0, g = 0, b = 0, a = 0.65 },
            glowColor = { r = 1, g = 1, b = 1, a = 0.25 },
            borderColor = { r = 0, g = 0, b = 0, a = 1 },
            borderScale = 0.5,
            scale = 1,
            x = 0,
            y = 0,
            width = iconSize * 5,
            height = iconSize / 2,
            anchorParent = "RIGHT",
            anchorSelf = "LEFT",
            minValue = 0,
            maxValue = 5
        }
    end
end

function State:getTrackerValuesListForSettings()
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local listTrackerValues = {}
    
    for _, trackerType in ipairs({ "buffs" }) do
        local trackerValues = State:GetAllTrackerValues(trackerType)
        local group = {}
        for trackerKey, trackerValue in pairs(trackerValues) do
            local shouldInclude = trackerValue.isEnabled ~= false
            State:EnsureVisualChargeBarDefaults(trackerValue)
            if shouldInclude then
                local frame = FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey]
                local activeSpellID = (frame and frame.meta and frame.meta.activeSpellID) or trackerValue.overrideSpellID or trackerValue.baseSpellID
                local spellInfo = activeSpellID and C_Spell.GetSpellInfo(activeSpellID)
                local displayName = (spellInfo and spellInfo.name) or trackerValue.name
                table.insert(group, {
                    trackerKey = trackerKey,
                    uniqueID = trackerValue.baseSpellID,
                    baseSpellID = trackerValue.baseSpellID,
                    activeSpellID = activeSpellID,
                    trackerType = trackerValue.trackerType,
                    name = displayName,
                    defaultIconTexturePath = trackerValue.defaultIconTexturePath,
                    devNotes = trackerValue.devNotes
                })
            end
        end
        if #group > 0 then
            -- Insert a header sentinel before each non-empty group
            table.insert(listTrackerValues, {
                isHeader = true,
                label = trackerType:sub(1,1):upper() .. trackerType:sub(2)
            })
            for _, entry in ipairs(group) do
                table.insert(listTrackerValues, entry)
            end
        end
    end

    -- Manually-added spells (no viewer frame required)
    local spellsValues = State:GetAllTrackerValues("spells")
    local spellsGroup = {}
    for trackerKey, trackerValue in pairs(spellsValues or {}) do
        State:EnsureVisualChargeBarDefaults(trackerValue)
        
        -- Only include enabled spells that are known
        local shouldInclude = trackerValue.isEnabled ~= false
            and (C_SpellBook.IsSpellKnown(trackerValue.baseSpellID) or C_SpellBook.IsSpellKnown(trackerValue.overrideSpellID))
        
        if shouldInclude then
            local frame = FrameTrackerManager.SpellStyler_frames["spells"] and FrameTrackerManager.SpellStyler_frames["spells"][trackerKey]
            local activeSpellID = (frame and frame.meta and frame.meta.activeSpellID) or trackerValue.overrideSpellID or trackerValue.baseSpellID
            local spellInfo = activeSpellID and C_Spell.GetSpellInfo(activeSpellID)
            local displayName = (spellInfo and spellInfo.name) or trackerValue.name
            
            table.insert(spellsGroup, {
                trackerKey = trackerKey,
                uniqueID = trackerValue.baseSpellID,
                baseSpellID = trackerValue.baseSpellID,
                activeSpellID = activeSpellID,
                trackerType = "spells",
                name = displayName,
                defaultIconTexturePath = trackerValue.defaultIconTexturePath,
                devNotes = trackerValue.devNotes
            })
        end
    end
    
    -- Manually-added items (no viewer frame required)
    local itemsValues = State:GetAllTrackerValues("items")
    local itemsGroup = {}
    for trackerKey, trackerValue in pairs(itemsValues or {}) do
        State:EnsureVisualChargeBarDefaults(trackerValue)
        
        -- Only include enabled items
        if trackerValue.isEnabled ~= false then
            local frame = FrameTrackerManager.SpellStyler_frames["items"] and FrameTrackerManager.SpellStyler_frames["items"][trackerKey]
            local activeSpellID = (frame and frame.meta and frame.meta.activeSpellID) or trackerValue.overrideSpellID or trackerValue.baseSpellID
            
            -- For items, use stored name and icon texture
            local displayName = trackerValue.name or "Unknown Item"
            local iconTexture = trackerValue.defaultIconTexturePath
            
            table.insert(itemsGroup, {
                trackerKey = trackerKey,
                uniqueID = trackerValue.baseSpellID,
                baseSpellID = trackerValue.baseSpellID,
                activeSpellID = activeSpellID,
                trackerType = "items",
                name = displayName,
                defaultIconTexturePath = iconTexture,
                devNotes = trackerValue.devNotes
            })
        end
    end
    
    -- Add Items section (after Buffs, before Spells)
    if #itemsGroup > 0 then
        table.insert(listTrackerValues, { isHeader = true, label = "Items" })
        for _, entry in ipairs(itemsGroup) do
            table.insert(listTrackerValues, entry)
        end
    end
    
    -- Add Spells section (after Items)
    if #spellsGroup > 0 then
        table.insert(listTrackerValues, { isHeader = true, label = "Spells" })
        for _, entry in ipairs(spellsGroup) do
            table.insert(listTrackerValues, entry)
        end
    end

    return listTrackerValues
end


function State:CopySettings(copyInfo)
    local keys = {}
    if copyInfo.category == 'Icon Settings' then
        keys = {'iconSettings'}
    elseif copyInfo.category == 'Spell Cooldown / Buff Duration' or copyInfo.category == 'Spell/Item Cooldown Duration' then
        keys = {'cooldownText', 'statusBar'}
    elseif copyInfo.category == 'Charge/Count based display' then
        keys = {'chargeBasedDisplay'}
    elseif copyInfo.category == 'Glow notification' then
        keys = {'glowNotification'}
    elseif copyInfo.category == 'Spell Charges / Buff Stacks' then
        keys = {'countText', 'visualChargeBar'}
    elseif copyInfo.category == 'Totem Tracking' then
        keys = {'totemBar'}
    elseif copyInfo.category == 'Custom Label (Accessibility)' then
        keys = {'customLabel'}
    end

    local sourceConfig = State:GetSpecificTrackerValue(copyInfo.sourceTrackerKey, copyInfo.sourceTrackerType)
    
    -- Deep-copy each key from source to target
    -- Each key gets its own independent table to prevent shared references
    for _, key in ipairs(keys) do
        local valueCopy = DeepCopy(sourceConfig[key])
        State:SetTrackerValueConfigProperty(copyInfo.targetTrackerKey, copyInfo.targetTrackerType, key, valueCopy)
    end
end



-- ============================================================================
-- SPECIAL VISIBILITY CONDITIONS
-- Per-entry CRUD helpers for the specialVisibilityConditions array stored on
-- each tracker value config.
-- ============================================================================

local function NewSpecialVisibilityCondition(customName)
    return {
        customName        = customName or "",
        -- Array of { property = "dot.path", value = <string|number|color table> }
        propertyOverrides = {},
        -- Name key from SpellStyler_DB.conditionals that triggers this override
        conditionalName   = "",
    }
end

function State:AddSpecialVisibilityCondition(trackerKey, trackerType, customName)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry then return end
    if not entry.specialVisibilityConditions then
        entry.specialVisibilityConditions = {}
    end
    table.insert(entry.specialVisibilityConditions, NewSpecialVisibilityCondition(customName))

    -- Re-evaluate conditionals
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
    FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
    
    return #entry.specialVisibilityConditions
end

function State:RemoveSpecialVisibilityCondition(trackerKey, trackerType, index)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions then return end
    
    -- CRITICAL: Clear all caches since entire conditional is being removed
    local frame = FrameTrackerManager.SpellStyler_frames[trackerType] 
        and FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey]
    
    if frame and SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:ClearAllConditionalCaches(frame)
    end
    
    -- Remove the conditional from database
    table.remove(entry.specialVisibilityConditions, index)
    
    -- Re-evaluate conditionals with fresh caches
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
    FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
end

function State:GetSpecialVisibilityConditions(trackerKey, trackerType)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry then return {} end
    return entry.specialVisibilityConditions or {}
end

function State:SetSpecialVisibilityConditionProperty(trackerKey, trackerType, index, path, value)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[index] then return end
    
    -- Check if customName is changing (which changes the conditional key)
    local isCustomNameChange = (path == "customName")
    
    if isCustomNameChange then
        -- Clear all caches since key will change
        local frame = FrameTrackerManager.SpellStyler_frames[trackerType] 
            and FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey]
        
        if frame and SpellStyler.ConditionalEngine then
            SpellStyler.ConditionalEngine:ClearAllConditionalCaches(frame)
        end
    end
    
    State:AccessNestedValue(entry.specialVisibilityConditions[index], path, value, "set")

    -- Re-evaluate conditionals
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
    FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
end

function State:GetSpecialVisibilityConditionProperty(trackerKey, trackerType, index, path)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[index] then return nil end
    return State:AccessNestedValue(entry.specialVisibilityConditions[index], path, nil, "get")
end

-- ─── Property-override helpers ───────────────────────────────────────────────

function State:GetPropertyOverrides(trackerKey, trackerType, condIndex)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return {} end
    return entry.specialVisibilityConditions[condIndex].propertyOverrides or {}
end

function State:AddPropertyOverride(trackerKey, trackerType, condIndex)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return end
    local cond = entry.specialVisibilityConditions[condIndex]
    cond.propertyOverrides = cond.propertyOverrides or {}
    table.insert(cond.propertyOverrides, { property = "", value = "" })
    
    -- Trigger live evaluation update
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
    FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
    return #cond.propertyOverrides
end

function State:RemovePropertyOverride(trackerKey, trackerType, condIndex, overrideIndex)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return end
    local cond = entry.specialVisibilityConditions[condIndex]
    if not cond.propertyOverrides or not cond.propertyOverrides[overrideIndex] then return end
    
    -- Clear cache for this specific conditional before removing property
    local frame = FrameTrackerManager.SpellStyler_frames[trackerType] 
        and FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey]
    
    if frame and SpellStyler.ConditionalEngine then
        local conditionalKey = SpellStyler.ConditionalEngine:GenerateConditionalKey(cond, condIndex)
        SpellStyler.ConditionalEngine:ClearEvaluationCache(frame, conditionalKey)
    end
    
    -- Remove the property override from state
    table.remove(cond.propertyOverrides, overrideIndex)
    
    -- Re-evaluate conditionals
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
    FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
end

function State:SetPropertyOverrideField(trackerKey, trackerType, propertiesToUpdate)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]

    for _, propertyConfig in ipairs(propertiesToUpdate) do
        if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[propertyConfig.condIndex] then return end
        local cond = entry.specialVisibilityConditions[propertyConfig.condIndex]
        if not cond.propertyOverrides or not cond.propertyOverrides[propertyConfig.overrideIndex] then return end
        
        -- Update database (persistent storage)
        cond.propertyOverrides[propertyConfig.overrideIndex][propertyConfig.field] = propertyConfig.value
        local frame = FrameTrackerManager.SpellStyler_frames[trackerType] 
            and FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey]
        
        -- Generate consistent conditional key using helper method
        local conditionalKey = SpellStyler.ConditionalEngine:GenerateConditionalKey(cond, propertyConfig.condIndex)
        
        -- Clear evaluation and property override caches for this specific conditional
        -- This ensures fresh evaluation with the new field value
        if frame and SpellStyler.ConditionalEngine then
            SpellStyler.ConditionalEngine:ClearEvaluationCache(frame, conditionalKey)
        end    
    end
    
    
    -- CRITICAL: Re-evaluate conditionals to apply the new property override
    -- Without this, property overrides are cleared but never re-applied!
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end

    -- Trigger frame update to apply the new value
    FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
end

function State:SetSpecialVisibilityConditionConditionalName(trackerKey, trackerType, condIndex, conditionalName)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return end
    
    -- CRITICAL: When conditional name changes, the conditionalKey changes too!
    -- Must clear ALL caches for this frame to remove old key's property overrides
    local frame = FrameTrackerManager.SpellStyler_frames[trackerType] 
        and FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey]
    
    if frame and SpellStyler.ConditionalEngine then
        -- Clear all conditional caches since the key is changing
        SpellStyler.ConditionalEngine:ClearAllConditionalCaches(frame)
    end
    
    -- Now update the conditional name in database
    entry.specialVisibilityConditions[condIndex].conditionalName = conditionalName
    
    -- Trigger live evaluation update with fresh caches
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
    FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
end

function State:GetGlobalSettings()
    local db = State:GetDataBase_V2()
    return db.globalSettings
end

--- Resolves which font path to use based on priority:
--- 1. Global override (if overrideAllFonts is enabled)
--- 2. Global default (if specificFont is nil or "default")
--- 3. Specific font selection
--- 4. Fallback: current font if available, otherwise Friz Quadrata
--- @param specificFont? string The font name from tracker config (cooldownText.font, countText.font, or customLabel.font)
--- @param fallbackFontPath? string Optional fallback path from frame:GetFont() to preserve existing font
--- @return string fontPath The resolved font file path
function State:ResolveFontPath(specificFont, fallbackFontPath)
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    
    -- Get global settings
    local gs = State:GetGlobalSettings()
    local fontSettings = gs and gs.fontSettings
    
    -- Priority 1: Global override is enabled
    if fontSettings and fontSettings.overrideAllFonts and fontSettings.globalFont then
        if LSM and LSM:IsValid("font", fontSettings.globalFont) then
            return LSM:Fetch("font", fontSettings.globalFont)
        end
    end
    
    -- Priority 2: Specific font is "default" or nil, use global default
    if not specificFont or specificFont == "default" then
        if fontSettings and fontSettings.globalFont and LSM and LSM:IsValid("font", fontSettings.globalFont) then
            return LSM:Fetch("font", fontSettings.globalFont)
        end
    end
    
    -- Priority 3: Use specific font selection
    if specificFont and specificFont ~= "default" then
        if LSM and LSM:IsValid("font", specificFont) then
            return LSM:Fetch("font", specificFont)
        end
    end
    
    -- Priority 4: Fallback to current font or default WoW font
    if fallbackFontPath then
        return fallbackFontPath
    end
    -- Ultimate fallback: Friz Quadrata (default WoW font)
    return "Fonts\\FRIZQT__.TTF"
end

--- Resolves which font flags to use based on priority:
--- 1. Global override (if overrideAllFonts is enabled)
--- 2. Global default (if specificFlags is nil or "default")
--- 3. Specific flags selection
--- 4. Fallback: current flags if available, otherwise "OUTLINE"
--- @param specificFlags? string The font flags from tracker config (cooldownText.fontFlags, countText.fontFlags, or customLabel.fontFlags)
--- @param fallbackFlags? string Optional fallback flags from frame:GetFont() to preserve existing flags
--- @return string fontFlags The resolved font flags string
function State:ResolveFontFlags(specificFlags, fallbackFlags)
    -- Get global settings
    local gs = State:GetGlobalSettings()
    local fontSettings = gs and gs.fontSettings
    
    -- Priority 1: Global override is enabled
    if fontSettings and fontSettings.overrideAllFonts and fontSettings.globalFontFlags then
        return fontSettings.globalFontFlags
    end
    
    -- Priority 2: Specific flags is "default" or nil, use global default
    if not specificFlags or specificFlags == "default" then
        if fontSettings and fontSettings.globalFontFlags then
            return fontSettings.globalFontFlags
        end
    end
    
    -- Migration: Convert old comma-separated format to new single-value format
    -- WoW's SetFont only accepts a single flag string, not comma-separated values
    if specificFlags and type(specificFlags) == "string" and specificFlags:find(",") then
        -- Extract the first flag from comma-separated list
        -- Prioritize THICKOUTLINE > OUTLINE > MONOCHROME
        if specificFlags:find("THICKOUTLINE") then
            return "THICKOUTLINE"
        elseif specificFlags:find("OUTLINE") then
            return "OUTLINE"
        elseif specificFlags:find("MONOCHROME") then
            return "MONOCHROME"
        else
            -- Invalid old format, use global default
            if fontSettings and fontSettings.globalFontFlags then
                return fontSettings.globalFontFlags
            end
            return "OUTLINE"
        end
    end
    
    -- Priority 3: Use specific flags selection
    if specificFlags and specificFlags ~= "default" then
        return specificFlags
    end
    
    -- Priority 4: Fallback to current flags or default
    if fallbackFlags and fallbackFlags ~= "" then
        return fallbackFlags
    end
    
    -- Ultimate fallback: OUTLINE (standard WoW default)
    return "OUTLINE"
end
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

    for trackerType, _ in pairs(FrameTrackerManager.SpellStyler_frames) do
        for _, frame in pairs(FrameTrackerManager.SpellStyler_frames[trackerType]) do
            if shouldShow then
                frame:Show()
            else
                frame:Hide()
            end
        end
    end
end

--- Override all icon visibility when settings menu is open
--- @param shouldOverride boolean When true, forces all icons visible; when false, restores normal visibility
function State:OverrideAllIconsVisible(shouldOverride)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    if not FrameTrackerManager or not FrameTrackerManager.SpellStyler_frames then return end
    -- Simply trigger a full update on all frames
    -- The ApplyVisibility.Icon function already checks the global setting
    for trackerType, _ in pairs(FrameTrackerManager.SpellStyler_frames) do
        for trackerKey, frame in pairs(FrameTrackerManager.SpellStyler_frames[trackerType]) do
            FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, trackerType)
        end
    end
end

function State:GetShouldOverrideVisibility()
    local shouldOverrideVisibility = false
    if SpellStyler.settingsMenu and SpellStyler.settingsMenu:IsShown() then
        local State = SpellStyler.State
        if State and State.GetGlobalSettings then
            local gs = State:GetGlobalSettings()
            if gs and gs.visibilitySettings and gs.visibilitySettings.showAllWhenSettingsOpen then
                shouldOverrideVisibility = true
            end
        end
    end
    return shouldOverrideVisibility
end

-- ============================================================================
-- EQUIPMENT CHANGE HANDLING
-- Keeps "Item by Slot" trackers (Core/AddSpells.lua) in sync with whatever
-- is currently equipped in that slot.
-- ============================================================================

-- Mirrors the equipment slot list in Core/AddSpells.lua's createItemSlotDropdown
local EQUIPMENT_SLOTS = {
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

-- Must produce the same key as Core/AddSpells.lua's getItemSlotTrackerKey
local function GetItemSlotTrackerKey(slotName)
    local key = string.lower(slotName or "")
    key = key:gsub("%s+", "")
    key = key:gsub("[%-%/]+", "")
    return key
end

--- Refreshes baseSpellID/itemID/name/defaultIconTexturePath on every "Item by Slot"
--- tracker so they reflect whatever item is currently equipped, then re-applies
--- frame properties if the tracker is enabled and its frame already exists.
function State:HandleEquipmentChanged()
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()

    for _, slotInfo in ipairs(EQUIPMENT_SLOTS) do
        local trackerKey = GetItemSlotTrackerKey(slotInfo.name)
        local trackerValue = db.items[trackerKey]
        if trackerValue then
            local itemID = GetInventoryItemID("player", slotInfo.id)
            local spellID = nil
            if itemID then
                local _, sid = C_Item.GetItemSpell(itemID)
                spellID = sid
            end

            trackerValue.itemID = itemID
            trackerValue.baseSpellID = spellID or trackerKey
            trackerValue.name = (itemID and C_Item.GetItemNameByID(itemID)) or slotInfo.name
            trackerValue.defaultIconTexturePath = itemID and C_Item.GetItemIconByID(itemID) or nil

            if trackerValue.isEnabled ~= false
                and FrameTrackerManager.SpellStyler_frames.items
                and FrameTrackerManager.SpellStyler_frames.items[trackerKey]
            then
                FrameTrackerManager:ApplyStaticFrameProperties(trackerKey, "items")
            end
        end
    end
end

local equipmentEventFrame = CreateFrame("Frame")
equipmentEventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
equipmentEventFrame:SetScript("OnEvent", function()
    State:HandleEquipmentChanged()
end)