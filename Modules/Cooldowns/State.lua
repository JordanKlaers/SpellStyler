local ADDON_NAME, SpellStyler = ...
SpellStyler.State = SpellStyler.State or {}
local State = SpellStyler.State
local FrameTrackerManager  -- lazily resolved on first use (avoids load-order nil)

--[[====================================================
TABLE AND NESTED-VALUE UTILITIES
Shared copying, default merging, and configuration-path access.
====================================================]]

--[[----------------------------------------------------
DEEP COPY HELPER
When copying settings between trackers or initializing icon variations, clone
nested tables so later edits to the destination do not change the source.
Primitive values are returned unchanged.
----------------------------------------------------]]
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

--[[----------------------------------------------------
DEEP MERGE HELPER
During database migration, recursively backfill missing configuration fields
from the current defaults without overwriting existing user settings.
----------------------------------------------------]]
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

--[[----------------------------------------------------
Settings controls and the conditional engine use dot-separated paths to read
or write nested configuration fields. Missing intermediate tables are created
for both actions; "get" returns the final field and "set" assigns it.
----------------------------------------------------]]
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

--[[====================================================
SPECIALIZATION, DATABASE ACCESS, AND CONFIGURATION DEFAULTS
Select the saved-data scope and define the tracker configuration schema.
====================================================]]

--[[--------------------------------------------------
Aura settings use this to offer specialization choices, and migration uses
it to initialize aura enablement by spec. Return the current class/spec IDs
together with the available specialization names, icons, roles, and metadata.
----------------------------------------------------]]
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
local PROFILE_DATA_KEYS = {
    "buffs",
    "essential",
    "utility",
    "spells",
    "items",
    "docks",
    "globalSettings",
}

--[[----------------------------------------------------
Database access, aura filtering, and settings/search code use this for the
current specialization's saved data. Cache the last valid spec ID so loading
screens with no specialization available can still use that identity.
----------------------------------------------------]]
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

function State:GetActiveTalentConfigID()
    local specID = self:GetCurrentSpecID()
    if C_ClassTalents
        and C_ClassTalents.GetLastSelectedSavedConfigID
        and specID
    then
        return C_ClassTalents.GetLastSelectedSavedConfigID(specID)
    end

    if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
        return C_ClassTalents.GetActiveConfigID()
    end
end

function State:GetTalentLoadoutsForSpec(specID)
    if not specID or not C_ClassTalents or not C_ClassTalents.GetConfigIDsBySpecID then
        return {}
    end

    local loadouts = {}
    for _, configID in ipairs(C_ClassTalents.GetConfigIDsBySpecID(specID) or {}) do
        local configInfo = C_Traits and C_Traits.GetConfigInfo
            and C_Traits.GetConfigInfo(configID)
        loadouts[#loadouts + 1] = {
            id = configID,
            name = (configInfo and configInfo.name) or ("Talent Loadout " .. tostring(configID)),
        }
    end
    return loadouts
end

function State:GetActiveTalentLoadoutInfo()
    local configID = self:GetActiveTalentConfigID()
    if not configID then return nil end

    local configInfo = C_Traits and C_Traits.GetConfigInfo
        and C_Traits.GetConfigInfo(configID)

    return {
        id = configID,
        name = (configInfo and configInfo.name) or ("Talent Loadout " .. tostring(configID)),
    }
end

function State:CanRegisterTalentLoadouts()
    local hasUnspentHeroPoints = C_ClassTalents
        and C_ClassTalents.HasUnspentHeroTalentPoints
        and select(1, C_ClassTalents.HasUnspentHeroTalentPoints())
    local hasUnspentTalentPoints = C_ClassTalents
        and C_ClassTalents.HasUnspentTalentPoints
        and select(1, C_ClassTalents.HasUnspentTalentPoints())

    return not hasUnspentHeroPoints and not hasUnspentTalentPoints
end

function State:ReconcileTalentLoadouts(specID, specDB, populateMissing)
    if not specDB or not specDB.profileSettings then return false end

    local validLoadouts = self:GetTalentLoadoutsForSpec(specID)
    if #validLoadouts == 0 then
        return false
    end

    local savedLoadouts = specDB.profileSettings.talentLoadouts
    local validLoadoutIDs = {}
    for _, loadout in ipairs(validLoadouts) do
        validLoadoutIDs[tostring(loadout.id)] = true
    end

    for configID in pairs(savedLoadouts) do
        if not validLoadoutIDs[tostring(configID)] then
            savedLoadouts[configID] = nil
        elseif type(configID) == "string" and tonumber(configID) then
            local numericConfigID = tonumber(configID)
            if not savedLoadouts[numericConfigID] then
                savedLoadouts[numericConfigID] = savedLoadouts[configID]
            end
            savedLoadouts[configID] = nil
        end
    end

    for _, loadout in ipairs(validLoadouts) do
        local savedLoadout = savedLoadouts[loadout.id]
        if not savedLoadout and populateMissing then
            savedLoadout = {
                profile = specDB.profileSettings.singleProfile or "default",
            }
            savedLoadouts[loadout.id] = savedLoadout
        end
        if savedLoadout then
            savedLoadout.name = loadout.name
        end
    end

    return true
end

local function CreateDefaultProfileData(source)
    local profile = {}
    for _, key in ipairs(PROFILE_DATA_KEYS) do
        profile[key] = DeepCopy(source[key] or {})
    end
    return profile
end

local function EnsureProfileDataShape(profile)
    for _, key in ipairs(PROFILE_DATA_KEYS) do
        profile[key] = profile[key] or {}
    end
end

function State:GetActiveProfileName(specDB)
    if not specDB or type(specDB.profiles) ~= "table" then
        return "default"
    end

    local settings = specDB.profileSettings or {}
    local profileName = settings.singleProfile or "default"

    if settings.mode == "talent" then
        local loadout = settings.talentLoadouts
            and settings.talentLoadouts[self:GetActiveTalentConfigID()]
        profileName = (loadout and loadout.profile) or profileName
    end

    if type(specDB.profiles[profileName]) ~= "table" then
        profileName = "default"
    end
    if type(specDB.profiles[profileName]) ~= "table" then
        profileName = next(specDB.profiles)
    end
    return profileName
end

--[[----------------------------------------------------
Tracker operations and settings code use this as the entry point to the
character's current-spec database. Create missing tracker collections and
global-setting blocks, then return the live saved table, not a copy.
----------------------------------------------------]]
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

    if specDB.profiles then
        specDB.profileSettings = specDB.profileSettings or {
            mode = "single",
            singleProfile = "default",
            talentLoadouts = {},
        }
        specDB.profileSettings.talentLoadouts = specDB.profileSettings.talentLoadouts or {}
        specDB.profiles.default = specDB.profiles.default or CreateDefaultProfileData(specDB)
        for _, profile in pairs(specDB.profiles) do
            EnsureProfileDataShape(profile)
        end
        local activeProfile = specDB.profiles[self:GetActiveProfileName(specDB)]
        EnsureProfileDataShape(activeProfile)
        activeProfile.globalSettings.visibilitySettings = activeProfile.globalSettings.visibilitySettings or {
            hideWhenOutOfCombat = false,
        }
        activeProfile.globalSettings.fontSettings = activeProfile.globalSettings.fontSettings or {
            globalFont = "Friz Quadrata TT",
            globalFontFlags = "OUTLINE",
            overrideAllFonts = false,
        }
        return activeProfile
    end
    
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
        classSpecializations = {
            [specID] = {
                buffs = {},
                spells = {},
                items = {},
            }
        }
    --]]
end

local AddNewTrackerValueConfig

--[[----------------------------------------------------
Adding a tracker, resetting its settings, and backfilling older saved data all
use this constructor for the current configuration defaults. It returns a
configuration object; the caller decides where to store or merge it.
----------------------------------------------------]]
function AddNewTrackerValueConfig(data)
    local iconSize = 48  -- Default icon size
    return {
        baseSpellID = data.baseSpellID,
        itemID = data.itemID,
		isEnabled = true,
        trackerType = data.trackerType, -- essential, utility, buffs
        name = data.name,
        defaultIconTexturePath = data.defaultIconTexturePath,
        iconColor = data.iconColor or { r = 1, g = 1, b = 1, a = 1 },
        isItem = data.isItem or false,  -- Flag to identify item trackers (for icon lookup)
        scale = 1,
        auraConfig = {
            filters = {
                [AuraUtil.AuraFilters.Helpful] = true
            },
            unit = 'player'
        },
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
        iconSettings = {
            disableDragging = false,
            displayCharges = data.trackerType == 'buffs' and true or false,
            iconDisplayState = data.trackerType == 'buffs' and 'available' or "always", -- "always", "active/cooldown", "inactive/available", "never"
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
        associatedSpellIDs = data.trackerType == "spells" and (data.associatedSpellIDs or {}) or nil,
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

--[[----------------------------------------------------
When tracker access or settings-list rendering encounters an entry with no
visualChargeBar block, initialize a hidden bar with usable defaults. Existing
blocks are left untouched; migration handles broader default backfilling.
----------------------------------------------------]]
--- @param trackerValue table The tracker configuration
function State:EnsureVisualChargeBarDefaults(trackerValue)
    --[[----------------------------------------------------
    This should rarely trigger since MigrateDatabase handles defaults via DeepMergeDefaults.
    Only acts as a safety net if visualChargeBar is completely missing.
    ====================================================]]
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

--[[====================================================
CUSTOM TEXTURES AND ASSOCIATED SPELL SETTINGS
Maintain the shared texture library and per-spell enabled/texture/color settings.
====================================================]]

--[[----------------------------------------------------
Before storing or comparing custom textures, convert string paths to WoW's
backslash format. Numeric texture file IDs pass through unchanged.
    ----------------------------------------------------]]
local function NormalizeCustomTexturePath(texturePath)
    if type(texturePath) ~= "string" then
        return texturePath
    end
    return string.gsub(texturePath, "/", "\\")
end

--[[----------------------------------------------------
Custom-texture registration and cleanup use this comparison key to treat
differently cased or slash-formatted paths as duplicates while keeping
numeric file IDs distinct from strings containing the same digits.
----------------------------------------------------]]
local function GetCustomTextureKey(texturePath)
    if type(texturePath) == "string" then
        return string.lower(NormalizeCustomTexturePath(texturePath))
    end
    return type(texturePath) .. ":" .. tostring(texturePath)
end

--[[----------------------------------------------------
When a user enters or selects a custom icon texture, or migration discovers
an older saved texture, add it once to the account-wide texture-picker list.
Accepts non-empty string paths and numeric texture file IDs.
----------------------------------------------------]]
function State:AddCustomTexture(texturePath)
    if (type(texturePath) ~= "string" and type(texturePath) ~= "number")
        or texturePath == ""
    then
        return
    end
    texturePath = NormalizeCustomTexturePath(texturePath)
    SpellStyler_DB = SpellStyler_DB or {}
    SpellStyler_DB.customTextures = SpellStyler_DB.customTextures or {}
    for _, existingPath in ipairs(SpellStyler_DB.customTextures) do
        if GetCustomTextureKey(existingPath) == GetCustomTextureKey(texturePath) then return end
    end
    table.insert(SpellStyler_DB.customTextures, texturePath)
end

--[[----------------------------------------------------
When the icon texture picker opens its custom-texture page, return the shared
saved texture list after normalizing paths and removing duplicates in place.
Reading this list can therefore update the account-wide saved data.
----------------------------------------------------]]
function State:GetCustomTextures()
    SpellStyler_DB = SpellStyler_DB or {}
    SpellStyler_DB.customTextures = SpellStyler_DB.customTextures or {}

    local uniqueTextures = {}
    local writeIndex = 1
    for _, texturePath in ipairs(SpellStyler_DB.customTextures) do
        texturePath = NormalizeCustomTexturePath(texturePath)
        local textureKey = GetCustomTextureKey(texturePath)
        if uniqueTextures[textureKey] == nil then
            uniqueTextures[textureKey] = true
            SpellStyler_DB.customTextures[writeIndex] = texturePath
            writeIndex = writeIndex + 1
        end
    end
    for index = writeIndex, #SpellStyler_DB.customTextures do
        SpellStyler_DB.customTextures[index] = nil
    end

    return SpellStyler_DB.customTextures
end

local DEFAULT_ICON_COLOR = { r = 1, g = 1, b = 1, a = 1 }
local ASSOCIATED_SPELL_KEYS = {
    enabled = true,
    iconTexturePath = true,
    iconColor = true,
}

--[[----------------------------------------------------
Database normalization, tracker resets, and newly discovered spell identities
use this to create one associatedSpellIDs entry: enabled, no custom texture,
and an independent copy of the tracker's icon color.
----------------------------------------------------]]
local function NewAssociatedSpell(trackerConfig)
    return {
        enabled = true,
        iconTexturePath = "",
        iconColor = DeepCopy((trackerConfig and trackerConfig.iconColor) or DEFAULT_ICON_COLOR),
    }
end

local CUSTOM_TEXTURE_KEYS = {
    iconTexturePath = true,
    iconTexturePathOverride = true,
}

--[[----------------------------------------------------
At login, walk saved configuration tables for recognized custom-icon fields
and register their textures in the shared picker. The visited set prevents
revisiting the same table during recursive traversal.
----------------------------------------------------]]
local function ScanSavedDataForCustomTextures(value, visited)
    if type(value) ~= "table" then return end
    visited = visited or {}
    if visited[value] then return end
    visited[value] = true

    for key, child in pairs(value) do
        if CUSTOM_TEXTURE_KEYS[key] then
            State:AddCustomTexture(child)
        elseif type(child) == "table" then
            ScanSavedDataForCustomTextures(child, visited)
        end
    end
end


--[[----------------------------------------------------
Settings controls, add/search views, and frame rendering use this to read the
saved association for one spell ID. When shouldCreate is true, a missing entry
is created from its base spell's association, or defaults, and forced enabled.
----------------------------------------------------]]
function State:GetAssociatedSpellID(trackerConfig, spellID, shouldCreate)
    local associatedSpellIDs = trackerConfig and trackerConfig.associatedSpellIDs
    if type(associatedSpellIDs) ~= "table" or not spellID then return nil end

    local spellKey = tonumber(spellID) or spellID
    local association = associatedSpellIDs[spellKey]
    if association or not shouldCreate then return association end

    local baseSpellID = C_Spell.GetBaseSpell(spellKey)
    local baseAssociation = baseSpellID and associatedSpellIDs[baseSpellID]
    if baseAssociation then
        association = DeepCopy(baseAssociation)
        association.enabled = true
    else
        association = NewAssociatedSpell(trackerConfig)
    end
    associatedSpellIDs[spellKey] = association
    return association
end

--[[----------------------------------------------------
Settings lists and search matching use this to read every spell association
saved on a tracker, keyed by spell ID.
----------------------------------------------------]]
function State:GetAssociatedSpellIDs(trackerConfig)
    return (trackerConfig and trackerConfig.associatedSpellIDs) or {}
end

--[[----------------------------------------------------
When the add-spell view adds or re-enables a spell, create its association if
needed and apply the supplied enabled/iconTexturePath/iconColor updates.
----------------------------------------------------]]
function State:UpdateAssociatedSpells(trackerConfig, spellID, updates)
    local association = self:GetAssociatedSpellID(trackerConfig, spellID, true)
    if not association then return nil end
    for key, value in pairs(updates or {}) do
        if ASSOCIATED_SPELL_KEYS[key] then
            association[key] = value
        end
    end
    return association
end

--[[====================================================
TRACKER CONFIGURATION, SPELL ASSOCIATIONS, AND ENABLEMENT
Read and edit trackers, resolve their spell identities, and refresh live visuals.
====================================================]]

--[[----------------------------------------------------
Frame/buff creation and settings-list builders use this to enumerate one
tracker category in the current spec. Return the saved collection directly
so callers can read the same configuration objects used by other systems.
----------------------------------------------------]]
function State:GetAllTrackerValues(trackerType)
    local db = State:GetDataBase_V2()
    if not db then return {} end
    return db[trackerType]
end

--[[----------------------------------------------------
Renderers, settings controls, and update handlers use this to retrieve one
saved tracker. Ensure its charge-bar defaults, then return the configuration
plus a found flag; a missing entry returns an empty table and false.
----------------------------------------------------]]
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

--[[----------------------------------------------------
After a reset or conditional-override edit changes a tracker's saved settings,
refresh its live visuals through BuffManager for auras or FrameTrackerManager
for spells/items. This helper does not create missing frames.
----------------------------------------------------]]
local function RefreshTrackerVisuals(trackerKey, trackerType)
    if trackerType == "buffs" then
        local buffManager = SpellStyler.BuffManager
        local containerData = buffManager and buffManager.buffContainers[trackerKey]
        local trackerConfig = State:GetSpecificTrackerValue(trackerKey, trackerType)
        if containerData and trackerConfig then
            buffManager:UpdateAura(containerData, trackerConfig)
        end
        return
    end

    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    if FrameTrackerManager then
        FrameTrackerManager.frameController.ApplyStaticFrameProperties(trackerKey, trackerType)
    end
end

--[[----------------------------------------------------
Search-result status checks, settings tracker-type lookup, and removal guards
use this to test whether an exact saved key exists in the current spec/category.
This checks entry presence, not enablement or spell-family associations.
----------------------------------------------------]]
function State:CheckIsAlreadyTracker(trackerKey, trackerType)
    local db = State:GetDataBase_V2()
    return db[trackerType][trackerKey] and true or false
end

--[[----------------------------------------------------
The add-spell search uses this to recognize an already tracked spell family
and show its existing association settings. Return the matching saved key and
configuration, treating numeric and string forms of the base ID alike.
----------------------------------------------------]]
function State:FindSpellTrackerByBaseSpellID(baseSpellID)
    local db = self:GetDataBase_V2()
    local trackerKeyMatch
    local trackerConfigMatch
    for trackerKey, trackerConfig in pairs(db.spells or {}) do
        if tostring(trackerConfig.baseSpellID) == tostring(baseSpellID) then
            trackerKeyMatch = trackerKey
            trackerConfigMatch = trackerConfig
        end
    end
    return trackerKeyMatch, trackerConfigMatch
end

--[[----------------------------------------------------
Provides a broader tracker lookup across each tracker's associatedSpellIDs.
Returns the first matching key/configuration; there are currently no callers
in the addon.
----------------------------------------------------]]
function State:FindSpellTrackerByAssociatedSpellID(spellID)
    if not spellID then return end

    local db = self:GetDataBase_V2()
    --[[----------------------------------------------------
    Within this lookup, recognize an association even if its saved ID is a
    string and the requested spell ID is numeric, or vice versa.
    ----------------------------------------------------]]
    local function matches(value)
        return value == spellID or tostring(value) == tostring(spellID)
    end

    for trackerKey, trackerConfig in pairs(db.spells or {}) do
        for associatedSpellID in pairs(State:GetAssociatedSpellIDs(trackerConfig)) do
            if matches(associatedSpellID) then
                return trackerKey, trackerConfig
            end
        end
    end
end

--[[----------------------------------------------------
Search results, settings lists, and frame-population code use this to check
whether a spell tracker has at least one enabled associated spell.
This checks associatedSpellIDs, not the tracker's separate isEnabled flag.
----------------------------------------------------]]
function State:IsSpellTrackerEnabled(trackerConfig)
    if not trackerConfig or trackerConfig.isItem then return false end
    for _, association in pairs(State:GetAssociatedSpellIDs(trackerConfig)) do
        if association.enabled == true then
            return true
        end
    end
    return false
end

--[[----------------------------------------------------
The disabled-tracker delete action uses this to guard removal. Spells count
as disabled if the tracker flag is false or no association is enabled;
other types use the flag alone, and a missing entry returns false.
----------------------------------------------------]]
function State:IsTrackerValueDisabled(trackerKey, trackerType)
    local db = State:GetDataBase_V2()
    local trackerConfig = db[trackerType] and db[trackerType][trackerKey]
    if not trackerConfig then return false end
    if trackerType == "spells" then
        return trackerConfig.isEnabled == false
    end
    return trackerConfig.isEnabled == false
end

--[[----------------------------------------------------
When the add-tracker UI creates a new spell, item, or aura entry, construct its
default settings and store them under the supplied key/type in the current
spec database. Return the saved configuration; frame creation is separate.
----------------------------------------------------]]
function State:AddTrackerValue(trackerValueConstructorData)
    local db = State:GetDataBase_V2()
    local trackerType = trackerValueConstructorData.trackerType
	if not trackerType then return end
    local entry = AddNewTrackerValueConfig(trackerValueConstructorData)
    db[trackerType][trackerValueConstructorData.trackerKey] = entry
    return db[trackerType][trackerValueConstructorData.trackerKey]
end

--[[----------------------------------------------------
The settings menu's "Reset" button replaces a tracker's saved
configuration using its existing identity/name/icon fields. Re-evaluate
conditions and refresh its visuals if a live tracker already exists.
----------------------------------------------------]]
function State:ResetTrackerValueConfig(trackerKey, trackerType)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local existing = db[trackerType] and db[trackerType][trackerKey]
    if not existing then return end
    -- Rebuild from defaults, preserving identity fields
    local baseSpellID = existing.baseSpellID

    local defaults = AddNewTrackerValueConfig({
        baseSpellID = baseSpellID,
        trackerType = trackerType,
        name = existing.name,
        defaultIconTexturePath = existing.defaultIconTexturePath,
        overrideSpellID = existing.overrideSpellID,
        isItem = existing.isItem,
        associatedSpellIDs = trackerType == "spells" and baseSpellID and {
            [tonumber(baseSpellID) or baseSpellID] = NewAssociatedSpell(),
        } or nil,
    })
    db[trackerType][trackerKey] = defaults
    -- Refresh the live frame if it exists
    if (FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][trackerKey])
        or (trackerType == "buffs" and SpellStyler.BuffManager
            and SpellStyler.BuffManager.buffContainers[trackerKey])
    then
        if SpellStyler.ConditionalEngine then
            SpellStyler.ConditionalEngine:EvaluateAll()
        end
        RefreshTrackerVisuals(trackerKey, trackerType)
    end
end

--[[----------------------------------------------------
Settings inputs and dragging logic read individual saved fields through this
dot-path lookup. Delegates to AccessNestedValue, which can create missing
intermediate tables even though this operation only requests a field value.
----------------------------------------------------]]
function State:GetTrackerValueConfigProperty(trackerKey, trackerType, path)
    local db = State:GetDataBase_V2()
    return State:AccessNestedValue(db[trackerType][trackerKey], path, nil, "get")
end

--[[----------------------------------------------------
Settings inputs, position edits, and settings-copy operations use this to save
a field by its dot-separated path. Register legacy texture fields, refresh
existing aura/spell/item visuals, and re-evaluate conditions for live non-buffs.
----------------------------------------------------]]
function State:SetTrackerValueConfigProperty(trackerKey, trackerType, path, value)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    State:AccessNestedValue(db[trackerType][trackerKey], path, value, "set")
    if path == "iconSettings.iconTexturePath" or path == "iconSettingsOverrides.iconTexturePathOverride" then
        State:AddCustomTexture(value)
    end
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
        FrameTrackerManager.frameController.ApplyStaticFrameProperties(trackerKey, trackerType)
        
        -- Re-evaluate conditionals so variant frame gets proper overrides
        if SpellStyler.ConditionalEngine then
            SpellStyler.ConditionalEngine:EvaluateAll()
        end
    end
end

--[[----------------------------------------------------
When an associated spell's checkbox changes in settings, save its enabled
value in associatedSpellIDs. For spell trackers, create missing frames if any
association remains enabled or destroy the disabled pair.
----------------------------------------------------]]
function State:SetTrackerSpellEnabled(trackerKey, trackerType, spellID, isEnabled)
    if not spellID then return end

    local db = State:GetDataBase_V2()
    local trackerValue = db[trackerType] and db[trackerType][trackerKey]
    if not trackerValue then return end

    local association = State:GetAssociatedSpellID(trackerValue, spellID)
    if not association then return end
    association.enabled = isEnabled == true

    if trackerType == "spells" then
        FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    end
    if trackerType == "spells" and FrameTrackerManager then
        if State:IsSpellTrackerEnabled(trackerValue) then
            FrameTrackerManager.lifecycleController.CreateItemAndSpellTrackerFrames()
        elseif FrameTrackerManager.SpellStyler_frames.spells
            and FrameTrackerManager.SpellStyler_frames.spells[trackerKey]
        then
            local frame = FrameTrackerManager.SpellStyler_frames.spells[trackerKey]
            FrameTrackerManager.utils.ApplyTrackerAlpha(
                frame,
                trackerValue,
                trackerValue.iconSettings and trackerValue.iconSettings.opacity or 1
            )
        end
    end
end

--[[----------------------------------------------------
When the user re-enables an entry from the disabled-trackers view, restore its
tracker flag and request the corresponding live frames/containers. For spells,
also enable every saved associated spell.
----------------------------------------------------]]
function State:ReenableTrackerValue(trackerKey, trackerType)
    local trackerConfig = State:GetSpecificTrackerValue(trackerKey, trackerType)
    if not trackerConfig then return end

    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    trackerConfig.isEnabled = true
    if trackerType == "spells" then
        for _, association in pairs(State:GetAssociatedSpellIDs(trackerConfig)) do
            association.enabled = true
        end
        if FrameTrackerManager then
            FrameTrackerManager.lifecycleController.CreateItemAndSpellTrackerFrames()
        end
    elseif trackerType == "buffs" then
        if SpellStyler.BuffManager then
            SpellStyler.BuffManager:CreateBuffContainers()
        end
    elseif FrameTrackerManager then
        FrameTrackerManager.lifecycleController.CreateItemAndSpellTrackerFrames()
    end
end

--[[----------------------------------------------------
When the user deletes an entry from the disabled-trackers view, remove its
saved configuration only if it exists and is disabled. Detach any remaining
buff container or spell/item frame before deleting the database entry.
----------------------------------------------------]]
function State:RemoveTrackerValue(trackerKey, trackerType)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    if not State:CheckIsAlreadyTracker(trackerKey, trackerType) then return end
    if not State:IsTrackerValueDisabled(trackerKey, trackerType) then return end

    if trackerType == "buffs" then
        local container = SpellStyler.BuffManager
            and SpellStyler.BuffManager.buffContainers[trackerKey]
        if container and container.auraContainer then
            container.auraContainer:SetEnabled(false)
        end
        if container and container.placeHolder then
            SpellStyler.IconSettingsRenderer:DisableDraggingForSpecificFrame(container.placeHolder)
            container.placeHolder:Hide()
        end
        if SpellStyler.BuffManager then
            SpellStyler.BuffManager.buffContainers[trackerKey] = nil
        end
    elseif FrameTrackerManager and FrameTrackerManager.SpellStyler_frames[trackerType] then
        FrameTrackerManager.frameController.DestroyTrackerFrame(trackerKey, trackerType)
    end

    db[trackerType][trackerKey] = nil
end

--[[----------------------------------------------------
When a user releases a dragged settings-section header over another icon in
the settings menu, copy that category's fields from the source tracker to the
target. Deep-copy each block and save through the normal property setter so
the two trackers do not share settings tables and live visuals are refreshed.
----------------------------------------------------]]
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
    
    --[[----------------------------------------------------
    Deep-copy each key from source to target
    Each key gets its own independent table to prevent shared references
    ----------------------------------------------------]]
    for _, key in ipairs(keys) do
        local valueCopy = DeepCopy(sourceConfig[key])
        State:SetTrackerValueConfigProperty(copyInfo.targetTrackerKey, copyInfo.targetTrackerType, key, valueCopy)
    end
end

--[[====================================================
DATABASE MIGRATION AND TALENT-CHANGE HANDLING
Upgrade saved trackers and rebuild trackers after talent changes.
====================================================]]

--[[-----------------------------------------------------
DATABASE MIGRATION
Called once from Main.lua Initialize() on PLAYER_LOGIN.

IMPORTANT: Spell base/override lookups depend on the loaded specialization.
The current implementation performs them while visiting every stored spec;
it does not restrict those lookups to the active spec.

When migrating a saved spell tracker, merge legacy spellVariations and
enabledSpellIDs into numeric-keyed associatedSpellIDs. Existing values win,
legacy values fill missing fields, then defaults complete every association.
    ----------------------------------------------------]]
local function NormalizeAssociatedSpellIDs(trackerValue)
    if trackerValue.isItem then return end

    if type(trackerValue.associatedSpellIDs) ~= "table" then
        trackerValue.associatedSpellIDs = {}
    end
    local associatedSpellIDs = trackerValue.associatedSpellIDs

    local function mergeAssociation(spellID, source)
        if spellID == nil then return end
        local spellKey = tonumber(spellID) or spellID
        local association = associatedSpellIDs[spellKey]
        if type(association) ~= "table" then
            association = {}
            associatedSpellIDs[spellKey] = association
        end
        if type(source) ~= "table" then return end
        for key in pairs(ASSOCIATED_SPELL_KEYS) do
            if association[key] == nil and source[key] ~= nil then
                association[key] = DeepCopy(source[key])
            end
        end
    end

    -- Store keys that successfully convert to a number AND are different than the original key.
    local nonNumericKeys = {}
    for spellID, association in pairs(associatedSpellIDs) do
        local numericSpellID = tonumber(spellID)
        if numericSpellID and numericSpellID ~= spellID then
            nonNumericKeys[spellID] = association
        end
    end
    -- Using that temp table of string keys that were able to be converted to number, delete their entries from trackerValue.associatedSpellIDs and re-add the exact same value under a number key instead. (handled by mergeAssociation)
    for spellID, association in pairs(nonNumericKeys) do
        associatedSpellIDs[spellID] = nil
        mergeAssociation(spellID, association)
    end

    for spellID, isEnabled in pairs(trackerValue.enabledSpellIDs or {}) do
        mergeAssociation(spellID, { enabled = isEnabled ~= false })
    end
    for spellID, variation in pairs(trackerValue.spellVariations or {}) do
        mergeAssociation(spellID, variation)
    end

    local baseSpellID = trackerValue.baseSpellID
    if baseSpellID then
        local iconSettings = trackerValue.iconSettings
        local legacyTexturePath = iconSettings and iconSettings.iconTexturePath
        mergeAssociation(baseSpellID, {
            iconTexturePath = legacyTexturePath ~= "" and legacyTexturePath or nil,
            iconColor = trackerValue.iconColor,
        })
        mergeAssociation(C_Spell.GetOverrideSpell(baseSpellID))
    end

    for _, association in pairs(associatedSpellIDs) do
        if association.enabled == nil then
            association.enabled = true
        end
        if association.iconTexturePath == nil then
            association.iconTexturePath = ""
        end
        if association.iconColor == nil then
            association.iconColor = DeepCopy(trackerValue.iconColor or DEFAULT_ICON_COLOR)
        end
    end

    trackerValue.spellVariations = nil
    trackerValue.enabledSpellIDs = nil
end

--[[----------------------------------------------------
Main's startup initialization calls this before the UI uses saved trackers.
Collect custom textures, move legacy tracker categories, refresh spell IDs,
convert older fields, and backfill defaults across the character's saved specs.
    ----------------------------------------------------]]
function State:MigrateDatabase()
    if not SpellStyler_CharDB or not SpellStyler_CharDB.classSpecializations then return end

    -- Ensure any custom textures that exist on a character anywhere in state, are migrated to the main database (not limited to classes, so that a user can find any custom texture they have added. They just need to log onto a character once and it will pull preexisting custom textures. Other code exists to automatically add custom textures if they are added later)
    ScanSavedDataForCustomTextures(SpellStyler_CharDB)

    local currentSpecID = State:GetCurrentSpecID()
    for specID, specDB in pairs(SpellStyler_CharDB.classSpecializations) do
        -- Ensure destination tables exist
        specDB.spells    = specDB.spells    or {}
        specDB.buffs     = specDB.buffs     or {}
        specDB.essential = specDB.essential or {}
        specDB.utility   = specDB.utility   or {}
        specDB.items     = specDB.items     or {}

        --[[----------------------------------------------------
            Move utility & essential entries into spells - This was from when the addon hooked into the Cooldown Manager.
        ----------------------------------------------------]]
        for _, srcType in ipairs({ "utility", "essential" }) do
            for trackerKey, trackerValue in pairs(specDB[srcType]) do
                if not specDB.spells[trackerKey] then
                    trackerValue.trackerType = "spells"
                    specDB.spells[trackerKey] = trackerValue
                end
                specDB[srcType][trackerKey] = nil
            end
        end

        --[[----------------------------------------------------
            Move items from spells to items table - items were previously stored in spells table with isItem flag
        ----------------------------------------------------]]
        for trackerKey, trackerValue in pairs(specDB.spells) do
            if trackerValue.isItem then
                if not specDB.items[trackerKey] then
                    trackerValue.trackerType = "items"
                    specDB.items[trackerKey] = trackerValue
                end
                specDB.spells[trackerKey] = nil
            end
        end

        --[[----------------------------------------------------
            Ensure all tracker entries have the correct datastructure and all default values filled
            Convert legacy settings and backfill missing configuration fields.
        ----------------------------------------------------]]
        for _, trackerType in ipairs({ "buffs", "spells", "items" }) do
            for trackerKey, trackerValue in pairs(specDB[trackerType]) do
                -- Ensure proper base spellID if it doesnt exist
                if not trackerValue.baseSpellID then
                    trackerValue.baseSpellID = C_Spell.GetBaseSpell(trackerValue.rootSpellID or trackerValue.overrideSpellID or trackerKey)
                end
                if trackerType == "spells" then
                    NormalizeAssociatedSpellIDs(trackerValue)
                end
                -- Change key from "barFillDirection" to "fillOrEmpty"
                if trackerValue.statusBar
                    and trackerValue.statusBar.barFillDirection ~= nil
                    and trackerValue.statusBar.fillOrEmpty == nil
                then
                    trackerValue.statusBar.fillOrEmpty = trackerValue.statusBar.barFillDirection
                    trackerValue.statusBar.barFillDirection = nil
                end


                if trackerValue.statusBar.includeTotemDuration == nil and trackerValue.totemBar and trackerValue.totemBar.attemptToTrack then
                    trackerValue.statusBar.includeTotemDuration = true
                end
                --[[----------------------------------------------------
                Legacy: countText.renderAsStatusBar -> visualChargeBar.displayState
                This migration ensures users who had the old checkbox get proper displayState values
                ----------------------------------------------------]]
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


                    local filters = {}
                    local unit
                    if trackerValue.isNPCDebuff == true then
                        filters[AuraUtil.AuraFilters.Harmful] = true
                        unit = 'target'
                    else
                        filters[AuraUtil.AuraFilters.Helpful] = true
                        unit = 'player'
                    end
                    if trackerValue.auraConfig == nil then
                        trackerValue.auraConfig = {
                            filters = filters,
                            unit = unit
                        }
                    else
                        if not next(trackerValue.auraConfig.filters) then
                            trackerValue.auraConfig.filters = filters
                        end
                        if trackerValue.auraConfig.unit == '' or trackerValue.auraConfig.unit == nil then
                            trackerValue.auraConfig.unit = unit
                        end
                    end
                end
                local defaults = AddNewTrackerValueConfig({
                    baseSpellID            = trackerValue.baseSpellID,
                    trackerType            = trackerType,
                    name                   = C_Spell.GetSpellName(trackerValue.baseSpellID),
                    defaultIconTexturePath = trackerValue.defaultIconTexturePath
                })
                DeepMergeDefaults(trackerValue, defaults)

            end
        end

        if not specDB.profiles then
            specDB.profiles = {
                default = CreateDefaultProfileData(specDB),
            }
            specDB.profileSettings = {
                mode = "single",
                singleProfile = "default",
                talentLoadouts = {},
            }
        else
            specDB.profileSettings = specDB.profileSettings or {
                mode = "single",
                singleProfile = "default",
                talentLoadouts = {},
            }
            specDB.profileSettings.talentLoadouts = specDB.profileSettings.talentLoadouts or {}
            for _, profile in pairs(specDB.profiles) do
                EnsureProfileDataShape(profile)
            end
        end

        if specID == currentSpecID then
            State:ReconcileTalentLoadouts(specID, specDB, true)
        end

    end
end

function State:GetCurrentSpecDatabase()
    local specID = self:GetCurrentSpecID()
    return specID
        and SpellStyler_CharDB
        and SpellStyler_CharDB.classSpecializations
        and SpellStyler_CharDB.classSpecializations[specID]
end

function State:GetProfileNames()
    local specDB = self:GetCurrentSpecDatabase()
    local names = {}
    for name in pairs((specDB and specDB.profiles) or {}) do
        names[#names + 1] = name
    end
    table.sort(names, function(left, right)
        return string.lower(left) < string.lower(right)
    end)
    return names
end

function State:IsProfileNameAvailable(name, excludedName)
    if type(name) ~= "string" or name:match("^%s*$") then
        return false
    end

    local normalized = string.lower(name)
    for _, existingName in ipairs(self:GetProfileNames()) do
        if string.lower(existingName) == normalized
            and string.lower(existingName) ~= string.lower(excludedName or "")
        then
            return false
        end
    end
    return true
end

function State:CreateProfile(name)
    name = type(name) == "string" and strtrim(name) or name
    if not self:IsProfileNameAvailable(name) then
        return nil, "A profile with that name already exists."
    end

    local specDB = self:GetCurrentSpecDatabase()
    if not specDB then return nil, "No active specialization is available." end
    local activeName = self:GetActiveProfileName(specDB)
    local source = specDB.profiles[activeName]
    specDB.profiles[name] = DeepCopy(source)
    return name
end

function State:DeleteProfile(profileName)
    local specDB = self:GetCurrentSpecDatabase()
    if not specDB or type(specDB.profiles) ~= "table" then
        return false, "No active specialization is available."
    end
    if profileName == "default" then
        return false, "The default profile cannot be deleted."
    end
    if type(specDB.profiles[profileName]) ~= "table" then
        return false, "The selected profile does not exist."
    end

    specDB.profiles[profileName] = nil

    local profileSettings = specDB.profileSettings
    if profileSettings.singleProfile == profileName then
        profileSettings.singleProfile = "default"
    end
    for _, loadout in pairs(profileSettings.talentLoadouts or {}) do
        if loadout.profile == profileName then
            loadout.profile = "default"
        end
    end

    self._lastActiveProfileName = self:GetActiveProfileName(specDB)
    return true
end

function State:SetSingleProfile(profileName)
    local specDB = self:GetCurrentSpecDatabase()
    if not specDB or not specDB.profiles[profileName] then return false end
    specDB.profileSettings.singleProfile = profileName
    self._lastActiveProfileName = self:GetActiveProfileName(specDB)
    return true
end

function State:SetProfileMode(mode)
    local specDB = self:GetCurrentSpecDatabase()
    if not specDB or (mode ~= "single" and mode ~= "talent") then return false end
    specDB.profileSettings.mode = mode
    self._lastActiveProfileName = self:GetActiveProfileName(specDB)
    return true
end

function State:SetTalentLoadoutProfile(configID, profileName)
    local specDB = self:GetCurrentSpecDatabase()
    if not specDB or not specDB.profiles[profileName] then return false end
    local loadout = specDB.profileSettings.talentLoadouts[configID]
    if not loadout then return false end
    loadout.profile = profileName
    self._lastActiveProfileName = self:GetActiveProfileName(specDB)
    return true
end

function State:HandleTalentProfileUpdate()
    local specDB = self:GetCurrentSpecDatabase()
    local loadout = self:GetActiveTalentLoadoutInfo()
    if not specDB or not loadout then return false end

    self:ReconcileTalentLoadouts(
        self:GetCurrentSpecID(),
        specDB,
        self:CanRegisterTalentLoadouts()
    )

    local previousProfile = self._lastActiveProfileName
        or self:GetActiveProfileName(specDB)
    local loadoutData = specDB.profileSettings.talentLoadouts[loadout.id]
    if not loadoutData then
        if not self:CanRegisterTalentLoadouts() then
            return false
        end

        loadoutData = {
            name = loadout.name,
            profile = previousProfile,
        }
        specDB.profileSettings.talentLoadouts[loadout.id] = loadoutData
    else
        loadoutData.name = loadout.name
    end

    local activeProfile = self:GetActiveProfileName(specDB)
    local profileChanged = activeProfile ~= self._lastActiveProfileName
    self._lastActiveProfileName = activeProfile
    self._lastTalentConfigID = loadout.id
    return profileChanged
end

local talentProfileEventFrame = CreateFrame("Frame")
talentProfileEventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
talentProfileEventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
talentProfileEventFrame:RegisterEvent("TRAIT_CONFIG_LIST_UPDATED")
talentProfileEventFrame:SetScript("OnEvent", function()
    C_Timer.After(0.1, function()
        local profileChanged = State:HandleTalentProfileUpdate()
        if SpellStyler.ProfileSettingsRenderer
            and SpellStyler.ProfileSettingsRenderer.frame
        then
            SpellStyler.ProfileSettingsRenderer:Refresh()
        end
        if not profileChanged then return end
        FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
        if FrameTrackerManager and FrameTrackerManager.lifecycleController then
            if SpellStyler.BuffManager and SpellStyler.BuffManager.DestroyBuffContainers then
                SpellStyler.BuffManager:DestroyBuffContainers()
                SpellStyler.BuffManager:CreateBuffContainers()
            end
            FrameTrackerManager.lifecycleController.TeardownSpecFrames()
            FrameTrackerManager.lifecycleController.FreshCreateFrames("profile_change")
        end
    end)
end)

--[[----------------------------------------------------
The frame manager calls this shortly after a detected talent-change cast,
after tearing down old trackers. Request a debounced spell/item population
refresh and rebuild buff containers.
----------------------------------------------------]]
function State:HandleTalentChange()
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    --[[----------------------------------------------------
    Frame teardown (Hide + table wipe) was already done synchronously by
    FrameTrackerManager.lifecycleController.TeardownSpecFrames() the moment the talent spell was
    detected. By the time this deferred call runs both tables are empty.
    Reset them again defensively in case HandleTalentChange is ever called
    from a path that didn't go through TeardownSpecFrames.
    ----------------------------------------------------]]

    --[[----------------------------------------------------
    FrameTrackerManager.lifecycleController.TeardownSpecFrames()
    Re-hook all buff cooldown frames
    ----------------------------------------------------]]
    FrameTrackerManager.lifecycleController.FreshCreateFrames("talent_change")

	local specDB = SpellStyler_CharDB.classSpecializations[State:GetCurrentSpecID()]

    if SpellStyler.BuffManager and SpellStyler.BuffManager.DestroyBuffContainers then
        SpellStyler.BuffManager:DestroyBuffContainers()
    end
    SpellStyler.BuffManager:CreateBuffContainers()
end

--[[====================================================
SETTINGS-MENU TRACKER LISTS
Prepare enabled and disabled tracker entries for selection and presentation.
====================================================]]

--[[----------------------------------------------------
Build the grouped display entries used by the settings icon list, drag-copy
targets, relative-frame anchor choices, and container icon selection. Include
enabled auras/items and enabled, known spells, with names/icons and header rows;
ensure charge-bar defaults on the examined tracker configurations.
    ----------------------------------------------------]]
function State:getTrackerValuesListForSettings()
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local listTrackerValues = {}

    --[[----------------------------------------------------
    Resolve the current override's name/icon for settings entries, falling
    back to the stored display values when spell information is unavailable.
    ----------------------------------------------------]]
    local function getCurrentSpellDisplay(baseSpellID, fallbackName, fallbackIcon)
        local currentSpellID = baseSpellID and C_Spell.GetOverrideSpell(baseSpellID) or baseSpellID
        local spellInfo = currentSpellID and C_Spell.GetSpellInfo(currentSpellID)
        return (spellInfo and spellInfo.name) or fallbackName,
            (spellInfo and spellInfo.iconID) or fallbackIcon
    end
    
    for _, trackerType in ipairs({ "buffs" }) do
        local trackerValues = State:GetAllTrackerValues(trackerType)
        local group = {}
        for trackerKey, trackerValue in pairs(trackerValues) do
            local shouldInclude = trackerValue.isEnabled ~= false
            State:EnsureVisualChargeBarDefaults(trackerValue)
            if shouldInclude then
                local displayName, iconTexture = getCurrentSpellDisplay(
                    trackerValue.baseSpellID,
                    trackerValue.name,
                    trackerValue.defaultIconTexturePath
                )
                table.insert(group, {
                    trackerKey = trackerKey,
                    uniqueID = trackerValue.baseSpellID,
                    baseSpellID = trackerValue.baseSpellID,
                    trackerType = trackerValue.trackerType,
                    name = displayName,
                    defaultIconTexturePath = iconTexture,
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
        
        -- Keep entries with all variants unchecked in the settings list. The
        -- variant checkboxes control visibility; Disable controls the entry.
        local shouldInclude = trackerValue.isEnabled ~= false
            and (C_SpellBook.IsSpellKnown(trackerValue.baseSpellID) or C_SpellBook.IsSpellKnown(C_Spell.GetOverrideSpell(trackerValue.baseSpellID)))
        
        if shouldInclude then
            local frame = FrameTrackerManager.SpellStyler_frames["spells"] and FrameTrackerManager.SpellStyler_frames["spells"][trackerKey]
            local displayName, iconTexture = getCurrentSpellDisplay(
                trackerValue.baseSpellID,
                trackerValue.name,
                trackerValue.defaultIconTexturePath
            )
            
            table.insert(spellsGroup, {
                trackerKey = trackerKey,
                uniqueID = trackerValue.baseSpellID,
                baseSpellID = trackerValue.baseSpellID,
                trackerType = "spells",
                name = displayName,
                defaultIconTexturePath = iconTexture,
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
            
            -- For items, use stored name and icon texture
            local displayName = trackerValue.name or "Unknown Item"
            local iconTexture = trackerValue.defaultIconTexturePath
            
            table.insert(itemsGroup, {
                trackerKey = trackerKey,
                uniqueID = trackerValue.baseSpellID,
                baseSpellID = trackerValue.baseSpellID,
                trackerType = "items",
                name = displayName,
                defaultIconTexturePath = iconTexture,
                itemID = trackerValue.itemID,
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

--[[----------------------------------------------------
The add-tracker UI's disabled view uses this sorted list to offer entries for
re-enabling or permanent deletion. Include disabled aura/item flags and spells
with a disabled flag or no enabled associations, retaining each saved config.
----------------------------------------------------]]
function State:GetDisabledTrackerValuesForSettings()
    local disabledValues = {}
    local trackerTypes = { "buffs", "items", "spells" }

    for _, trackerType in ipairs(trackerTypes) do
        for trackerKey, trackerConfig in pairs(State:GetAllTrackerValues(trackerType) or {}) do
            local isDisabled
            if trackerType == "spells" then
                isDisabled = trackerConfig.isEnabled == false
                    or not State:IsSpellTrackerEnabled(trackerConfig)
            else
                isDisabled = trackerConfig.isEnabled == false
            end

            if isDisabled then
                table.insert(disabledValues, {
                    trackerKey = trackerKey,
                    trackerType = trackerType,
                    config = trackerConfig,
                    baseSpellID = trackerConfig.baseSpellID or trackerKey,
                })
            end
        end
    end

    table.sort(disabledValues, function(left, right)
        if left.trackerType ~= right.trackerType then
            return left.trackerType < right.trackerType
        end
        return tostring(left.baseSpellID) < tostring(right.baseSpellID)
    end)

    return disabledValues
end

--[[================================================]
TRACKER CONDITIONS AND PROPERTY OVERRIDES
Manage conditional attachments, their property settings, and evaluation caches.
====================================================]]

--[[----------------------------------------------------
SPECIAL VISIBILITY CONDITIONS
Per-entry CRUD helpers for the specialVisibilityConditions array stored on
each tracker value config.
----------------------------------------------------]]

--[[----------------------------------------------------
When adding a tracker-local conditional-override entry, initialize its display
name, empty property list, and unselected conditional reference. This creates
the attachment settings, not a definition in the account-wide condition library.
----------------------------------------------------]]
local function NewSpecialVisibilityCondition(customName)
    return {
        customName        = customName or "",
        -- Array of { property = "dot.path", value = <string|number|color table> }
        propertyOverrides = {},
        -- Name key from SpellStyler_DB.conditionals that triggers this override
        conditionalName   = "",
    }
end

--[[----------------------------------------------------
The property-override editor uses this to render the condition entries attached
to a selected tracker. Return the saved array or an empty table when absent;
these entries reference, rather than define, the account-wide conditionals.
----------------------------------------------------]]
function State:GetSpecialVisibilityConditions(trackerKey, trackerType)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry then return {} end
    return entry.specialVisibilityConditions or {}
end

--[[----------------------------------------------------
When a user adds a named condition entry in an icon's settings, append the
object that will hold the selected saved conditional and properties to apply
when it passes. Re-evaluate conditions, refresh visuals, and return its index.
----------------------------------------------------]]
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
    RefreshTrackerVisuals(trackerKey, trackerType)
    
    return #entry.specialVisibilityConditions
end

--[[----------------------------------------------------
When a user removes a condition entry from an icon's settings, clear its live
frame's conditional caches and remove the attachment from the tracker. Then
re-evaluate remaining conditions and refresh visuals; the library definition stays.
----------------------------------------------------]]
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
    RefreshTrackerVisuals(trackerKey, trackerType)
end

--[[----------------------------------------------------
Provides a dot-path read of one attached condition's settings, returning nil
if the entry is missing. There are currently no callers in the addon.
----------------------------------------------------]]
function State:GetSpecialVisibilityConditionProperty(trackerKey, trackerType, index, path)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[index] then return nil end
    return State:AccessNestedValue(entry.specialVisibilityConditions[index], path, nil, "get")
end

--[[----------------------------------------------------
Provides dot-path edits for a tracker-local condition entry, clearing frame
caches when its custom name changes before re-evaluating and refreshing.
There are currently no callers in the addon.
----------------------------------------------------]]
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
    RefreshTrackerVisuals(trackerKey, trackerType)
end

--[[----------------------------------------------------
When the user chooses a saved conditional or "(none)" for an override entry,
update its conditional-name reference. Clear the frame's caches because the
generated key changes, then re-evaluate conditions and refresh visuals.
----------------------------------------------------]]
function State:SetSpecialVisibilityConditionConditionalName(trackerKey, trackerType, condIndex, conditionalName)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return end
    
    --[[----------------------------------------------------
    CRITICAL: When conditional name changes, the conditionalKey changes too!
    Must clear ALL caches for this frame to remove old key's property overrides
    ====================================================]]
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
    RefreshTrackerVisuals(trackerKey, trackerType)
end

-- ─── Property-override helpers ───────────────────────────────────────────────

--[[----------------------------------------------------
Provides the saved property/value override list for one tracker-local condition,
or an empty table when absent. There are currently no callers in the addon.
    ----------------------------------------------------]]
function State:GetPropertyOverrides(trackerKey, trackerType, condIndex)
    local db = State:GetDataBase_V2()
    local entry = db[trackerType] and db[trackerType][trackerKey]
    if not entry or not entry.specialVisibilityConditions or not entry.specialVisibilityConditions[condIndex] then return {} end
    return entry.specialVisibilityConditions[condIndex].propertyOverrides or {}
end

--[[----------------------------------------------------
The condition editor's "Add property override" button appends an empty
property/value row to the selected entry. Re-evaluate conditions, refresh the
tracker, and return the new row's index for the editor.
----------------------------------------------------]]
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
    RefreshTrackerVisuals(trackerKey, trackerType)
    return #cond.propertyOverrides
end

--[[----------------------------------------------------
When the user deletes a property row from a condition entry, clear that
condition's evaluation cache and remove the row from saved settings.
Re-evaluate conditions and refresh visuals so the removed override stops applying.
----------------------------------------------------]]
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
    RefreshTrackerVisuals(trackerKey, trackerType)
end

--[[----------------------------------------------------
Property dropdowns, value controls, color pickers, and duration inputs submit
batches of override-field edits here. Save each field, invalidate the affected
condition caches, then re-evaluate and refresh the tracker's appearance.
----------------------------------------------------]]
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
        
        --[[----------------------------------------------------
        Clear evaluation and property override caches for this specific conditional
        This ensures fresh evaluation with the new field value
        ----------------------------------------------------]]
        if frame and SpellStyler.ConditionalEngine then
            SpellStyler.ConditionalEngine:ClearEvaluationCache(frame, conditionalKey)
        end    
    end
    
    
    --[[----------------------------------------------------
    CRITICAL: Re-evaluate conditionals to apply the new property override
    Without this, property overrides are cleared but never re-applied!
    ----------------------------------------------------]]
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end

    -- Trigger frame update to apply the new value
    RefreshTrackerVisuals(trackerKey, trackerType)
end

--[[====================================================
GLOBAL SETTINGS, FONTS, AND VISIBILITY
Resolve shared text preferences and apply global visibility policies.
====================================================]]

--[[----------------------------------------------------
Global settings controls, font resolvers, and visibility checks use this to
access the current spec's shared settings block. Return the live saved table;
"global" here is scoped to the spec database, not the account-wide database.
        ----------------------------------------------------]]
function State:GetGlobalSettings()
    local db = State:GetDataBase_V2()
    return db.globalSettings
end

--[[----------------------------------------------------
When frame or aura text is created/refreshed, resolve the configured font name
to a usable path, honoring global overrides and per-text choices. Use the
existing font path or built-in Friz Quadrata when no selection resolves.
Resolves which font path to use based on priority:
1. Global override (if overrideAllFonts is enabled)
2. Global default (if specificFont is nil or "default")
3. Specific font selection
4. Fallback: current font if available, otherwise Friz Quadrata
----------------------------------------------------]]
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

--[[----------------------------------------------------
When renderers apply fonts to tracker text, select flags using global override,
default, specific, and fallback preferences. Older comma-separated selections
are reduced to a single supported flag before returning it to the renderer.
Resolves which font flags to use based on priority:
1. Global override (if overrideAllFonts is enabled)
2. Global default (if specificFlags is nil or "default")
3. Specific flags selection
4. Fallback: current flags if available, otherwise "OUTLINE"
----------------------------------------------------]]
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
    
    --[[----------------------------------------------------
    Migration: Convert old comma-separated format to new single-value format
    WoW's SetFont only accepts a single flag string, not comma-separated values
    ----------------------------------------------------]]
    if specificFlags and type(specificFlags) == "string" and specificFlags:find(",") then
        --[[----------------------------------------------------
        Extract the first flag from comma-separated list
        Prioritize THICKOUTLINE > OUTLINE > MONOCHROME
        ----------------------------------------------------]]
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

--[[----------------------------------------------------
Frame appearance and visibility handlers use this to decide whether normal
display rules should be overridden while editing. Return true only when the
settings menu is shown and the current spec's show-all option is enabled.
    ----------------------------------------------------]]
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

--[[----------------------------------------------------
Opening/closing settings or changing its show-all option calls this to reapply
static properties on live trackers. Visibility is derived from the menu and
saved option by GetShouldOverrideVisibility; shouldOverride is not read here.
----------------------------------------------------]]
function State:OverrideAllIconsVisible(shouldOverride)
    FrameTrackerManager = FrameTrackerManager or SpellStyler.FrameTrackerManager
    if not FrameTrackerManager or not FrameTrackerManager.SpellStyler_frames then return end
    --[[----------------------------------------------------
    Simply trigger a full update on all frames
    The ApplyVisibility.Icon function already checks the global setting
    ----------------------------------------------------]]
    for trackerType, _ in pairs(FrameTrackerManager.SpellStyler_frames) do
        for trackerKey, frame in pairs(FrameTrackerManager.SpellStyler_frames[trackerType]) do
            FrameTrackerManager.frameController.ApplyStaticFrameProperties(trackerKey, trackerType)
        end
    end
end

--[[----------------------------------------------------
Combat-state events and the global visibility checkbox call this to enforce
hideWhenOutOfCombat on registered spell/item frames. Show or hide the frames
according to current combat state; this does not change their saved enablement.
    ----------------------------------------------------]]
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

--[[====================================================
EQUIPMENT-SLOT TRACKER SYNCHRONIZATION
Keep stable slot-based item trackers aligned with equipped items.
====================================================]]

--[[----------------------------------------------------
EQUIPMENT CHANGE HANDLING
Keeps "Item by Slot" trackers (Core/AddSpells.lua) in sync with whatever
is currently equipped in that slot.
----------------------------------------------------]]

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

--[[----------------------------------------------------
Must produce the same key as Core/AddSpells.lua's getItemSlotTrackerKey
Equipment refresh uses the same normalized slot label as the add-item UI to
locate the saved "Item by Slot" tracker, independent of the currently worn item.
----------------------------------------------------]]
local function GetItemSlotTrackerKey(slotName)
    local key = string.lower(slotName or "")
    key = key:gsub("%s+", "")
    key = key:gsub("[%-%/]+", "")
    return key
end

--[[----------------------------------------------------
On PLAYER_EQUIPMENT_CHANGED, update saved "Item by Slot" trackers to match the
currently equipped item's ID, use-spell ID, name, and icon. Refresh enabled
trackers with existing frames; empty slots retain their stable slot key/name.
----------------------------------------------------]]
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
            if itemID and SpellStyler.GetOwnedItemQuality then
                trackerValue.associatedItemQualities = trackerValue.associatedItemQualities or {}
                SpellStyler.GetOwnedItemQuality(itemID, trackerValue.associatedItemQualities)
            end

            if trackerValue.isEnabled ~= false
                and FrameTrackerManager.SpellStyler_frames.items
                and FrameTrackerManager.SpellStyler_frames.items[trackerKey]
            then
                FrameTrackerManager.frameController.ApplyStaticFrameProperties(trackerKey, "items")
            end
        end
    end
end

local equipmentEventFrame = CreateFrame("Frame")

equipmentEventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

equipmentEventFrame:SetScript("OnEvent", function()
    State:HandleEquipmentChanged()
end)
