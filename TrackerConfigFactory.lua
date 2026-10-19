-- The important boundary is:
--   TrackerDefinitions = metadata and defaults
--   completeState      = the plain tracker object used by the addon
--   template           = a plain subset extracted from completeState
--
-- Runtime code still reads values normally:
--   completeState.iconSettings.width
--   completeState.position.x
--
-- No runtime value becomes { value = ..., template = ... }.
local addonName, SpellStyler = ...
SpellStyler.TrackerConfigFactory = SpellStyler.TrackerConfigFactory or {}
local TrackerConfigFactory = SpellStyler.TrackerConfigFactory



local function DeepCopy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, child in pairs(value) do
        copy[key] = DeepCopy(child)
    end
    return copy
end

local function MergeInto(target, source)
    for key, value in pairs(source or {}) do
        if type(value) == "table" and type(target[key]) == "table" then
            MergeInto(target[key], value)
        else
            target[key] = DeepCopy(value)
        end
    end
end

local function ReadPath(object, path)
    local current = object
    for key in string.gmatch(path, "[^.]+") do
        if current == nil then
            return nil
        end
        current = current[key]
    end
    return current
end

local function WritePath(object, path, value)
    local keys = {}
    for key in string.gmatch(path, "[^.]+") do
        keys[#keys + 1] = key
    end

    local current = object
    for index = 1, #keys - 1 do
        current[keys[index]] = current[keys[index]] or {}
        current = current[keys[index]]
    end
    current[keys[#keys]] = DeepCopy(value)
end

TrackerConfigFactory.IsMetaDefinition = function(value)
    return type(value) == "table" and value.__kind == "field"
end

-- A callable table keeps the default and its copy policy together in the
-- definition layer. Calling it returns only the normal runtime value.
local _ = 'all' -- Local sentinel meaning that a field applies to every tracker type.
local excludedFromTemplate = {} -- Policy sentinel for fields excluded from templates.

local SPELLS_AND_ITEMS = {
    spells = true,
    essential = true,
    utility = true,
    items = true,
}

local ITEMS_AND_AURAS = {
    buffs = true,
    items = true
}

local AURAS_ONLY = {
    buffs = true,
}

local SPELLS_ONLY = {
    spells = true,
}

local ITEMS_ONLY = {
    items = true,
}


--[[
    This produces a meta value that adds additional information
    It has
        - a flag that the value contains additional meta data
        - Whether it should be included when producing a template instance from the tracker type
        - The tracker type the value is used for
]]
local function __(defaultValue, appliesTo, policy)
    local appliesToTrackerType
    if appliesTo == _ then
        appliesToTrackerType = nil
    else
        appliesToTrackerType = appliesTo
    end
    local field = {
        __kind = "field",
        default = defaultValue,
        excludeFromTemplate = policy == excludedFromTemplate,
        appliesTo = appliesToTrackerType
    }

    return setmetatable(field, {
        __call = function(self)
            return DeepCopy(self.default)
        end,
    })
end

local function AppliesTo(field, trackerType)
    if not field.appliesTo then
        return true
    end
    if type(field.appliesTo) == "table" then
        return field.appliesTo[trackerType] == true
    end
    return field.appliesTo == trackerType
end

-- This is the definition source. Defaults and template exclusions are declared
-- beside one another, while the generated state remains a plain Lua table.
local ADDON_NAME, SpellStyler = ...

local TrackerDefinitions = {
    -- __ is used to flag a value with meta inforamtion. Used to associate its trackerType and or if it should be excluded from a template instance. If __ is not used, than the property applies to all tracker types AND should be included in template instances.
    baseSpellID = __(nil, _, excludedFromTemplate),
    itemID = __(nil, ITEMS_ONLY, excludedFromTemplate),
    associatedItemQualities = __({}, ITEMS_ONLY, excludedFromTemplate),
    shouldShowQualityEmblem = __(true, ITEMS_ONLY),
    trackerType = __(nil, _, excludedFromTemplate),
    name = __(nil, _, excludedFromTemplate),
    defaultIconTexturePath = __(nil, _, excludedFromTemplate),
    isItem = __(false, _, excludedFromTemplate),
    isEnabled = __(true, AURAS_ONLY, excludedFromTemplate),
    iconColor = { r = 1, g = 1, b = 1, a = 1 },
    scale = 1,
    position = __({
        anchorPoint = "center",
        relativeToFrame = nil,
        relativeAnchorPoint = "center",
        x = 0,
        y = 0,
    }, _, excludedFromTemplate),
    iconSettings = {
        disableDragging = false,
        iconDisplayState = "always",
        width = 48,
        height = 48,
        opacity = __(1, SPELLS_AND_ITEMS),
        hideDefaultSweep = false,
        hideCooldownBling = false,
        frameStrataLevel = "MEDIUM",
        frameStrataValue = 100,
        zoom = 0,
        borderSize = __(0, SPELLS_AND_ITEMS),
        borderColor = __({ r = 1, g = 1, b = 1, a = 0 }, SPELLS_AND_ITEMS),
        iconTexturePath = "",
    },
    cooldownText = {
        display = true,
        size = 14,
        font = "default",
        fontFlags = "default",
        color = { r = 1, g = 1, b = 1, a = 1 },
        x = 0,
        y = 0,
    },
    countText = {
        display = true,
        size = 12,
        font = "default",
        fontFlags = "default",
        color = { r = 1, g = 1, b = 1, a = 1 },
        x = 0,
        y = 0,
        useSpellDisplayCount = __(false, SPELLS_AND_ITEMS),
    },
    statusBar = {
        includeTotemDuration = __(false, SPELLS_AND_ITEMS),
        displayState = "never",
        defaultBarTexture = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarFill.tga",
        customBarTexture = "",
        onlyRenderBar = __(false, SPELLS_AND_ITEMS),
        barOrientation = "horizontal",
        fillOrEmpty = "regular",
        progressDirection = "standard",
        reverseFill = false,
        defaultFillValue = __("empty", SPELLS_AND_ITEMS),
        color = { r = 0.2, g = 0.8, b = 1, a = 0.9 },
        backgroundColor = __({ r = 0, g = 0, b = 0, a = 0.65 }, SPELLS_AND_ITEMS),
        glowColor = __({ r = 1, g = 1, b = 1, a = 0.25 }, SPELLS_AND_ITEMS),
        borderColor = __({ r = 0, g = 0, b = 0, a = 1 }, SPELLS_AND_ITEMS),
        borderScale = __(0.5, SPELLS_AND_ITEMS),
        scale = 1,
        x = 0,
        y = 0,
        width = 200,
        height = 20,
        anchorParent = "RIGHT",
        anchorSelf = "LEFT",
    },
    visualChargeBar = {
        displayState = "never",
        defaultBarTexture = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarFill.tga",
        customBarTexture = "",
        onlyRenderBar = __(false, SPELLS_AND_ITEMS),
        barOrientation = "horizontal",
        fillOrEmpty = "regular",
        progressDirection = "standard",
        textureRotation = __(0, SPELLS_AND_ITEMS),
        color = { r = 0.2, g = 0.8, b = 1, a = 0.9 },
        backgroundColor = __({ r = 0, g = 0, b = 0, a = 0.65 }, SPELLS_AND_ITEMS),
        glowColor = __({ r = 1, g = 1, b = 1, a = 0.25 }, SPELLS_AND_ITEMS),
        borderColor = __({ r = 0, g = 0, b = 0, a = 1 }, SPELLS_AND_ITEMS),
        borderScale = __(0.5, SPELLS_AND_ITEMS),
        scale = 1,
        x = 0,
        y = 0,
        width = 240,
        height = 24,
        anchorParent = "RIGHT",
        anchorSelf = "LEFT",
        minValue = __(0, SPELLS_AND_ITEMS),
        maxValue = 5,
    },
    auraConfig = __({
        filters = {},
        unit = "player",
    }, AURAS_ONLY),
    auraSpecs = __({}, AURAS_ONLY, excludedFromTemplate),
    isNPCDebuff = __(false, AURAS_ONLY),
    additionalBuffIDs = __({}, AURAS_ONLY),
    associatedSpellIDs = __({}, SPELLS_AND_ITEMS, excludedFromTemplate),
    chargeBasedDisplay = __({
        enabled = false,
        displayState = true,
        displayOperator = ">",
        chargeValue = 0,
    }, SPELLS_AND_ITEMS),
    glowNotification = __({
        shouldDisplay = false,
        glowStyle = "thin",
        duration = 1,
        glowColor = { r = 1, g = 1, b = 1, a = 1 },
    }, SPELLS_AND_ITEMS),
    customLabel = __({
        display = false,
        text = "",
        size = 10,
        x = 0,
        y = 0,
        font = "default",
        fontFlags = "default",
        color = { r = 1, g = 1, b = 1, a = 1 },
    }, SPELLS_AND_ITEMS),
    specialVisibilityConditions = __({}, SPELLS_AND_ITEMS, excludedFromTemplate),
    devNotes = __({}, SPELLS_AND_ITEMS, excludedFromTemplate),
}



local function Materialize(definitions, trackerType)
    local result = {}

    for key, definition in pairs(definitions or {}) do
        if TrackerConfigFactory.IsMetaDefinition(definition) then
            if AppliesTo(definition, trackerType) then
                result[key] = definition()
            end
        elseif type(definition) ~= "table" then
            result[key] = DeepCopy(definition)
        else
            local nested = Materialize(definition, trackerType)
            if next(nested) then
                result[key] = nested
            end
        end
    end

    return result
end

local function WalkDefinitions(definitions, path, callback)
    for key, definition in pairs(definitions or {}) do
        local childPath = path and (path .. "." .. key) or key
        if TrackerConfigFactory.IsMetaDefinition(definition) then
            callback(childPath, definition)
        elseif type(definition) ~= "table" then
            callback(childPath)
        else
            WalkDefinitions(definition, childPath, callback)
        end
    end
end

function TrackerConfigFactory:Create(trackerType, targetObject)
    local config = Materialize(self.definitions, trackerType)
    MergeInto(config, targetObject)
    config.trackerType = trackerType
    return config
end

--[[
    ExtractTemplate:
    copy only if:
        1. the field is not excluded from templates, and
        2. the field applies to the source tracker type
]]
function TrackerConfigFactory:ExtractTemplate(trackerType, trackerConfig)
    local template = {}

    WalkDefinitions(self.definitions, nil, function(path, field)
        if (not field or not field.excludeFromTemplate)
            and (not field or AppliesTo(field, trackerType))
        then
            local value = ReadPath(trackerConfig, path)
            if value ~= nil then
                WritePath(template, path, value)
            end
        end
    end)

    return template
end


--[[
    ApplyTemplate:
    copy only if:
        1. the field is not excluded from templates, and
        2. the field applies to the target tracker type
]]
function TrackerConfigFactory:ApplyTemplate(targetType, targetConfig, template)
    WalkDefinitions(self.definitions, nil, function(path, field)
        if (not field or not field.excludeFromTemplate)
            and (not field or AppliesTo(field, targetType))
        then
            local value = ReadPath(template, path)
            if value ~= nil then
                if field and field.copy then
                    value = field.copy(value, targetType)
                end
                WritePath(targetConfig, path, value)
            end
        end
    end)

    return targetConfig
end

TrackerConfigFactory.definitions = TrackerDefinitions
SpellStyler.TrackerConfigFactory = TrackerConfigFactory
