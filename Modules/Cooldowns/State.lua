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
    return {
		isEnabled = true,
		overrideSpellID = data.overrideSpellID,
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
            size = nil, -- deprecated; use width/height
            width = 48,
            height = 48,
            opacity = 1,
            hideDefaultSweep = false,
            isSpellOffGCD = false,
            insufficientPower = false,
            insufficientPowerIconColor = {
                r = 1,
                g = 0,
                b = 0,
                a = 1,
            },
            frameStrataLevel = "MEDIUM", -- BACKGROUND LOW MEDIUM HIGH DIALOG FULLSCREEN FULLSCREEN_DIALOG TOOLTIP
            frameStrataValue = 100
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
            useSpellDisplayCount = false,
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
        showProcGlow = true,  -- Show spell activation glow
		specialVisibilityConditions = {},
        devNotes = {

        }
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

function State:SetCorrectOverride(specDB)
	-- make sure the default Icon Texture Path and overrideSpellID match the current spell override when loading in
	for baseSpellID, trackerValue in pairs(specDB.spells) do
		pcall(function()
			local overrideID = baseSpellID
			pcall(function() overrideID = C_Spell.GetOverrideSpell(baseSpellID) end)
			local defaultIconTexturePath = overrideID
			local overrideInfo = C_Spell.GetSpellInfo(overrideID)
			if overrideInfo then defaultIconTexturePath = overrideInfo.iconID end
			specDB.spells[baseSpellID].defaultIconTexturePath = defaultIconTexturePath
			specDB.spells[baseSpellID].overrideSpellID = overrideID
		end)
	end
end


function State:HandleTalentChange()
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    -- Frame teardown (Hide + table wipe) was already done synchronously by
    -- FrameTrackerManager:TeardownSpecFrames() the moment the talent spell was
    -- detected. By the time this deferred call runs both tables are empty.
    -- Reset them again defensively in case HandleTalentChange is ever called
    -- from a path that didn't go through TeardownSpecFrames.
    FrameTrackerManager:TeardownSpecFrames()
	local specDB = SpellStyler_CharDB.classSpecializations[State:GetCurrentSpecID()]
	State:SetCorrectOverride(specDB)
    -- Re-hook all buff cooldown frames
    for _, tType in ipairs({"buffs"}) do
        FrameTrackerManager:HookAllBuffCooldownFrames(tType)
        if SpellStyler.Containers then
            SpellStyler.Containers:ApplyViewerVisibility(tType)
        end
    end
	FrameTrackerManager:CreateNonBuffTrackerFrames()
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
        if SpellStyler.IconSettingsRenderer and SpellStyler.IconSettingsRenderer.EnableDraggingForAllFrames then
            SpellStyler.IconSettingsRenderer:EnableDraggingForAllFrames()
        end
    end
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

        -- ── Move utility & essential entries into spells ─────────────────
        -- Safe on all specs: pure table reshuffling, no spell API calls.
        for _, srcType in ipairs({ "utility", "essential" }) do
            for uniqueID, trackerValue in pairs(specDB[srcType]) do
                if not specDB.spells[uniqueID] then
                    trackerValue.trackerType = "spells"
                    specDB.spells[uniqueID] = trackerValue
                end
                specDB[srcType][uniqueID] = nil
            end
        end

        -- ── Validate & backfill structure for every tracked entry ────────
        -- Safe on all specs: only reads existing values and fills missing keys.
        for _, trackerType in ipairs({ "buffs", "spells" }) do
            for baseSpellID, trackerValue in pairs(specDB[trackerType]) do
                -- Legacy: barFillDirection -> fillOrEmpty
                if trackerValue.statusBar
                    and trackerValue.statusBar.barFillDirection ~= nil
                    and trackerValue.statusBar.fillOrEmpty == nil
                then
                    trackerValue.statusBar.fillOrEmpty = trackerValue.statusBar.barFillDirection
                    trackerValue.statusBar.barFillDirection = nil
                end

                local defaults = AddNewTrackerValueConfig({
                    baseSpellID            = baseSpellID,
                    trackerType            = trackerType,
                    name                   = trackerValue.name,
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
            for uniqueID, trackerValue in pairs(specDB.spells) do
                local baseID = nil
                pcall(function() baseID = C_Spell.GetBaseSpell(uniqueID) end)
                if baseID and baseID ~= uniqueID then
                    table.insert(spellRemaps, { oldID = uniqueID, newID = baseID, entry = trackerValue })
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
                pcall(function() overrideID = C_Spell.GetOverrideSpell(baseID) end)
                specDB.spells[baseID].overrideSpellID = overrideID
                specDB.spells[remap.oldID] = nil
            end

            -- Refresh overrideSpellID and defaultIconTexturePath for the active spec.
            State:SetCorrectOverride(specDB)
        end
    end
end

function State:AddTrackerValue(trackerValueConstructorData)
    local db = State:GetDataBase_V2()
    local trackerType = trackerValueConstructorData.trackerType
	if not trackerType then return end
    local entry = AddNewTrackerValueConfig(trackerValueConstructorData)
    db[trackerType][trackerValueConstructorData.baseSpellID] = entry
    return db[trackerType][trackerValueConstructorData.baseSpellID]
end

function State:ResetTrackerValueConfig(baseSpellID, trackerType)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local existing = db[trackerType] and db[trackerType][baseSpellID]
    if not existing then return end
    -- Rebuild from defaults, preserving identity fields
    local defaults = AddNewTrackerValueConfig({
        baseSpellID = baseSpellID,
        trackerType = trackerType,
        name = existing.name,
        defaultIconTexturePath = existing.defaultIconTexturePath,
        overrideSpellID = existing.overrideSpellID,
    })
    db[trackerType][baseSpellID] = defaults
    -- Refresh the live frame if it exists
    if FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] then
        FrameTrackerManager:UpdateFrame_ConfigurationChanges(baseSpellID, trackerType)
        FrameTrackerManager:UpdateFrame_copyCharges({
            customFrame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID],
            config = existing,
            baseSpellID = baseSpellID,
            trackerType = trackerType
        })
    end
end

function State:GetAllTrackerValues(trackerType)
    local db = State:GetDataBase_V2()
    if not db then return {} end
    return db[trackerType]
end

function State:GetSpecificTrackerValue(baseSpellID, trackerType)
    local db = State:GetDataBase_V2()
    local iconConfig = db[trackerType][baseSpellID] or {}
    local foundConfig = db[trackerType][baseSpellID] and true or false
    return iconConfig, foundConfig
end

function State:CheckIsAlreadyTracker(baseSpellID, trackerType)
    local db = State:GetDataBase_V2()
    return db[trackerType][baseSpellID] and true or false
end

function State:RemoveTrackerValue(baseSpellID, trackerType)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    if State:CheckIsAlreadyTracker(baseSpellID, trackerType) then
        -- Clean up the frame
        local frame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
        if frame then
            frame:Hide()
            frame:ClearAllPoints()
            FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] = nil
        end
        
        -- Remove from database
        db[trackerType][baseSpellID] = nil
    end
end

function State:SetTrackerValueConfigProperty(baseSpellID, trackerType, path, value)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    accessNestedValue(db[trackerType][baseSpellID], path, value, "set")
    local trackerValue = db[trackerType][baseSpellID]
    if trackerValue and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] then
        FrameTrackerManager:UpdateFrame_ConfigurationChanges(baseSpellID, trackerType)
        -- FrameTrackerManager:UpdateFrame_copyCharges({
        --     config = trackerValue,
        --     customFrame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID],
        --     baseSpellID = baseSpellID,
        --     trackerType = trackerType
        -- })
    end
end

function State:GetTrackerValueConfigProperty(baseSpellID, trackerType, path)
    local db = State:GetDataBase_V2()
    return accessNestedValue(db[trackerType][baseSpellID], path, nil, "get")
end

function State:getTrackerValuesListForSettings()
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local listTrackerValues = {}
    for _, trackerType in ipairs({ "buffs" }) do
        local trackerValues = State:GetAllTrackerValues(trackerType)
        local group = {}
        for baseSpellID, trackerValue in pairs(trackerValues) do
            if FrameTrackerManager.cooldownManagerFrames[trackerType][baseSpellID] then
                local frame = FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                local activeSpellID = (frame and frame.meta and frame.meta.activeSpellID) or trackerValue.overrideSpellID or baseSpellID
                local spellInfo = activeSpellID and C_Spell.GetSpellInfo(activeSpellID)
                local displayName = (spellInfo and spellInfo.name) or trackerValue.name
                table.insert(group, {
                    uniqueID = baseSpellID,
                    baseSpellID = baseSpellID,
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
    for baseSpellID, trackerValue in pairs(spellsValues or {}) do
        if trackerValue.isEnabled ~= false and (C_SpellBook.IsSpellKnown(baseSpellID) or C_SpellBook.IsSpellKnown(trackerValue.overrideSpellID)) then
            local frame = FrameTrackerManager.SpellStyler_frames["spells"] and FrameTrackerManager.SpellStyler_frames["spells"][baseSpellID]
            local activeSpellID = (frame and frame.meta and frame.meta.activeSpellID) or trackerValue.overrideSpellID or baseSpellID
            local spellInfo = activeSpellID and C_Spell.GetSpellInfo(activeSpellID)
            local displayName = (spellInfo and spellInfo.name) or trackerValue.name
            table.insert(spellsGroup, {
                uniqueID = baseSpellID,
                baseSpellID = baseSpellID,
                activeSpellID = activeSpellID,
                trackerType = "spells",
                name = displayName,
                defaultIconTexturePath = trackerValue.defaultIconTexturePath,
                devNotes = trackerValue.devNotes
            })
        end
    end
    if #spellsGroup > 0 then
        table.insert(listTrackerValues, { isHeader = true, label = "Spells" })
        for _, entry in ipairs(spellsGroup) do
            table.insert(listTrackerValues, entry)
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

    local sourceConfig = State:GetSpecificTrackerValue(copyInfo.sourceBaseSpellID, copyInfo.sourceTrackerType)
    -- Deep-copy so the target gets its own independent table, not a shared
    -- reference that would cause writes on one spell to silently affect the other.
    local valueCopy = DeepCopy(sourceConfig[key])
    State:SetTrackerValueConfigProperty(copyInfo.targetBaseSpellID, copyInfo.targetTrackerType, key, valueCopy)
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

function State:AddSpecialVisibilityCondition(baseSpellID, trackerType, customName)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry then return end
    if not entry.specialVisibilityConditions then
        entry.specialVisibilityConditions = {}
    end
    table.insert(entry.specialVisibilityConditions, NewSpecialVisibilityCondition(customName))
    return #entry.specialVisibilityConditions
end

function State:RemoveSpecialVisibilityCondition(baseSpellID, trackerType, index)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry or not entry.specialVisibilityConditions then return end
    table.remove(entry.specialVisibilityConditions, index)
end

function State:GetSpecialVisibilityConditions(baseSpellID, trackerType)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry then return {} end
    return entry.specialVisibilityConditions or {}
end

function State:SetSpecialVisibilityConditionProperty(baseSpellID, trackerType, index, path, value)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[index] then return end
    accessNestedValue(entry.specialVisibilityConditions[index], path, value, "set")
end

function State:GetSpecialVisibilityConditionProperty(baseSpellID, trackerType, index, path)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[index] then return nil end
    return accessNestedValue(entry.specialVisibilityConditions[index], path, nil, "get")
end

-- ─── Property-override helpers ───────────────────────────────────────────────

function State:GetPropertyOverrides(baseSpellID, trackerType, condIndex)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return {} end
    return entry.specialVisibilityConditions[condIndex].propertyOverrides or {}
end

function State:AddPropertyOverride(baseSpellID, trackerType, condIndex)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return end
    local cond = entry.specialVisibilityConditions[condIndex]
    cond.propertyOverrides = cond.propertyOverrides or {}
    table.insert(cond.propertyOverrides, { property = "", value = "" })
    
    -- Trigger live evaluation update
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
    
    return #cond.propertyOverrides
end

function State:RemovePropertyOverride(baseSpellID, trackerType, condIndex, overrideIndex)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return end
    local cond = entry.specialVisibilityConditions[condIndex]
    if not cond.propertyOverrides or not cond.propertyOverrides[overrideIndex] then return end
    table.remove(cond.propertyOverrides, overrideIndex)
    
    -- Trigger live evaluation update
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
end

function State:SetPropertyOverrideField(baseSpellID, trackerType, condIndex, overrideIndex, field, value)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return end
    local cond = entry.specialVisibilityConditions[condIndex]
    if not cond.propertyOverrides or not cond.propertyOverrides[overrideIndex] then return end
    cond.propertyOverrides[overrideIndex][field] = value
    
    -- Trigger live evaluation update
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
end

function State:SetSpecialVisibilityConditionConditionalName(baseSpellID, trackerType, condIndex, conditionalName)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][baseSpellID]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return end
    entry.specialVisibilityConditions[condIndex].conditionalName = conditionalName
    
    -- Trigger live evaluation update
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end
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
        for baseSpellID, frame in pairs(FrameTrackerManager.SpellStyler_frames[trackerType]) do
            FrameTrackerManager:UpdateFrame_ConfigurationChanges(baseSpellID, trackerType)
        end
    end
end