

local ADDON_NAME, SpellStyler = ...
SpellStyler.ConditionalEngine = SpellStyler.ConditionalEngine or {}
local ConditionalEngine = SpellStyler.ConditionalEngine


ConditionalEngine.liveValues = {
    ComboPoints = 0,
    activeBuffs = {},  -- table with spellID as key, true/false as value
    -- Aura_<spellID>       = true|false  (written on first NotifySourceChanged)
    -- AuraStacks_<spellID> = number      (written on first NotifySourceChanged)
    -- Cooldown_<spellID>   = number secs (written on first NotifySourceChanged)
}

--- Mapping of conditionType to whether it requires constant updates.
--- Conditions that require constant updates cannot detect state changes
--- and thus cannot support time-limited property overrides.
--- Add new conditionTypes here as 'true' if they need constant evaluation.
ConditionalEngine.conditionTypeUpdateMapping = {
    ["ComboPoints"] = false,
    ["IsSpellUsable"] = false,
    ["Charges"] = false,
    ["UnitHealth"] = true,  -- Uses secret curve values that can't detect changes
    ["buff"] = false,
}


--- Write a new value into liveValues and immediately re-evaluate all icons.
---
--- @param liveValueKey  string   e.g. "ComboPoints", "Aura_12345", "Cooldown_12345"
--- @param updatedValue  any      the current value for that key
function ConditionalEngine:NotifySourceChanged(liveValueKey, updatedValue)
    self.liveValues[liveValueKey] = updatedValue
    self:EvaluateAll()
end


local comparisonFunctions = {
    ["<"]  = function(leftValue, rightValue) return leftValue <  rightValue end,
    ["<="] = function(leftValue, rightValue) return leftValue <= rightValue end,
    [">"]  = function(leftValue, rightValue) return leftValue >  rightValue end,
    [">="] = function(leftValue, rightValue) return leftValue >= rightValue end,
    ["=="] = function(leftValue, rightValue) return leftValue == rightValue end,
    ["~="] = function(leftValue, rightValue) return leftValue ~= rightValue end,
}

--- @param  original  any
--- @return any
local function deepCopy(original)
    if type(original) ~= "table" then return original end
    local copy = {}
    for key, value in pairs(original) do
        copy[deepCopy(key)] = deepCopy(value)
    end
    return setmetatable(copy, getmetatable(original))
end


--- @param  partiallyResolved  table   mixed list of booleans and entry tables
local function FinalizeResolved(partiallyResolved)
    -- ── Step 1: build a flat token stream ────────────────────────────────────
    local tokens = {}

    for _, item in ipairs(partiallyResolved) do
        if type(item) == "boolean" then
            table.insert(tokens, item)
        elseif type(item) == "table" then
            if item.type == "boundary" then
                for _ = 1, (item.openParens  or 0) do table.insert(tokens, "(") end
                for _ = 1, (item.closeParens or 0) do table.insert(tokens, ")") end

            elseif item.type == "operator" then
                -- close parens belong to the left operand, open parens to the right
                for _ = 1, (item.closeParens or 0) do table.insert(tokens, ")") end
                table.insert(tokens, item.operand)   -- "and" or "or"
                for _ = 1, (item.openParens  or 0) do table.insert(tokens, "(") end
            end
        end
    end
    -- ── Step 2: recursive descent parser ────────────────────────────────────
    --
    --  Grammar (left-to-right, no precedence):
    --    expr    → primary ( ("and"|"or") primary )*
    --    primary → "(" expr ")" | boolean
    --
    local pos = 0

    local function peek()  return tokens[pos + 1] end
    local function advance() pos = pos + 1; return tokens[pos] end

    local parseExpr  -- forward declaration

    local function parsePrimary()
        local t = peek()
        if t == "(" then
            advance()                -- consume "("
            local val = parseExpr()
            advance()                -- consume ")"
            return val
        elseif type(t) == "boolean" then
            return advance()
        else
            return false             -- malformed / empty sub-expression
        end
    end

    parseExpr = function()
        local result = parsePrimary()
        while true do
            local op = peek()
            if op == "and" or op == "or" then
                advance()
                local right = parsePrimary()
                if op == "and" then
                    result = result and right
                else
                    result = result or  right
                end
            else
                break
            end
        end
        return result
    end

    if #tokens == 0 then return false end
    return parseExpr(), tokens
end

-- If a value can be calculated in this function, then just directly call "EvaluateAll", if a value can only be accessed by some event/method in frameTrackerManager, then it must cache that value via SpellStyler.ConditionalEngine:NotifySourceChanged("key", value) which will eventually trigger this method
---
--- @param  conditionalName  string
--- @param  liveValues       table   (ConditionalEngine.liveValues)
--- @param  context          table   { spellID = number, trackerType = string }
--- @return boolean, boolean
local function EvaluateConditional(conditionalName, currentLiveValues, context)
    local conditionalData = SpellStyler_DB
        and SpellStyler_DB.conditionals
        and SpellStyler_DB.conditionals[conditionalName]
    if not conditionalData or not conditionalData.entries or #conditionalData.entries == 0 then
        return false, false
    end
	local requiresConstantUpdate = false

	local partiallyResolved = {}
	for index, conditionStructure in ipairs(conditionalData.entries) do
		if conditionStructure.type == "condition" then
			if conditionStructure.conditionType == "ComboPoints" then
                local power = GetComboPoints("player", "target")
				local comparison = conditionStructure.ComboPoints and conditionStructure.ComboPoints.comparison
				local targetValue = conditionStructure.ComboPoints and conditionStructure.ComboPoints.targetValue
				if comparison and targetValue and comparisonFunctions[comparison] then
					table.insert(partiallyResolved, comparisonFunctions[comparison](power, targetValue))
				else
					table.insert(partiallyResolved, false)
				end
			
			elseif conditionStructure.conditionType == "IsSpellUsable" then
				-- Spell-specific: requires context.spellID
				if context and context.spellID then
					local isUsable, insufficientPower = C_Spell.IsSpellUsable(context.spellID)
					-- Actual state: true if unable to cast due to insufficient power
                    local spellCharges = C_Spell.GetSpellCharges(context.spellID)
                    local canCast
                    local isActiveCooldown
                    if spellCharges and spellCharges.maxCharges and spellCharges.maxCharges > 1 then
                        isActiveCooldown = C_Spell.GetSpellCharges(context.spellID).isActive
                        canCast = isUsable and not isActiveCooldown
                    else
                        isActiveCooldown = C_Spell.GetSpellCooldown(context.spellID).isActive
                        canCast = isUsable and not isActiveCooldown
                    end
					local targetValue = conditionStructure.IsSpellUsable.state
                    if targetValue == 'cooldown' then
                        table.insert(partiallyResolved, isActiveCooldown)
					elseif targetValue == 'able' then
						table.insert(partiallyResolved, canCast)
					elseif targetValue == 'unable' then
						table.insert(partiallyResolved, not canCast)
					elseif targetValue == 'insufficientPower' then
						table.insert(partiallyResolved, not canCast and insufficientPower)
					end
				else
					table.insert(partiallyResolved, false)
				end
            elseif conditionStructure.conditionType == "Charges" then
                table.insert(partiallyResolved, true)
            elseif conditionStructure.conditionType == "UnitHealth" then
                table.insert(partiallyResolved, true)
                requiresConstantUpdate = true
            elseif conditionStructure.conditionType == "buff" then
                -- Check if the specified buff(s) is/are active
                local buffData = conditionStructure.buff
                if buffData and buffData.buffID and buffData.state then
                    local activeBuffs = currentLiveValues.activeBuffs or {}
                    local isActive = false
                    -- Handle both single ID and table of IDs
                    if type(buffData.buffID) == "table" then
                        -- Check if ANY of the buff IDs is active
                        for _, buffID in ipairs(buffData.buffID) do
                            if activeBuffs[buffID] then
                                isActive = true
                                break
                            end
                        end
                    else
                        -- Single buff ID
                        isActive = activeBuffs[buffData.buffID] == true
                    end
                    
                    -- Compare against desired state
                    if buffData.state == "active" then
                        table.insert(partiallyResolved, isActive)
                    elseif buffData.state == "inactive" then
                        table.insert(partiallyResolved, not isActive)
                    else
                        table.insert(partiallyResolved, false)
                    end
                else
                    table.insert(partiallyResolved, false)
                end
			end
            
            -- Check if this conditionType requires constant updates
            if conditionStructure.conditionType and ConditionalEngine.conditionTypeUpdateMapping[conditionStructure.conditionType] then
                requiresConstantUpdate = true
            end
		else
			table.insert(partiallyResolved, deepCopy(conditionStructure))
		end
	end

	local finalizeResolvedValue, middleResolve = FinalizeResolved(partiallyResolved)
    return finalizeResolvedValue, requiresConstantUpdate
end

-- ============================================================================
-- CHARGE CONDITIONAL HELPERS
-- ============================================================================

--- Checks if a conditional uses any conditionType that requires constant updates.
--- Conditions requiring constant updates cannot detect state changes and thus
--- cannot support time-limited property overrides (duration field).
--- @param conditionalName string The name of the conditional to check
--- @return boolean True if the conditional uses any conditionType requiring constant updates
function ConditionalEngine:ConditionalRequiresConstantUpdate(conditionalName)
    local conditionalData = SpellStyler_DB
        and SpellStyler_DB.conditionals
        and SpellStyler_DB.conditionals[conditionalName]
    if not conditionalData or not conditionalData.entries then
        return false
    end
    
    for _, entry in ipairs(conditionalData.entries) do
        if entry.type == "condition" and entry.conditionType then
            if self.conditionTypeUpdateMapping[entry.conditionType] then
                return true
            end
        end
    end
    
    return false
end

--- Checks if a conditional definition contains a Charges condition.
--- @param conditionalName string The name of the conditional to check
--- @return boolean True if the conditional uses Charges, false otherwise
function ConditionalEngine:ConditionalUsesCharges(conditionalName)
    local conditionalData = SpellStyler_DB
        and SpellStyler_DB.conditionals
        and SpellStyler_DB.conditionals[conditionalName]
    if not conditionalData or not conditionalData.entries then
        return false
    end
    
    for _, entry in ipairs(conditionalData.entries) do
        if entry.type == "condition" and entry.conditionType == "Charges" then
            return true
        end
    end
    
    return false
end

--- Extracts the Charges condition data from a conditional.
--- Returns the comparison operator and target value for use in variant frame creation.
--- @param conditionalName string The name of the conditional
--- @return table|nil { comparison: string, targetValue: number } or nil if no Charges condition exists
function ConditionalEngine:GetChargeConditionalData(conditionalName)
    local conditionalData = SpellStyler_DB
        and SpellStyler_DB.conditionals
        and SpellStyler_DB.conditionals[conditionalName]
    if not conditionalData or not conditionalData.entries then
        return nil
    end
    
    for _, entry in ipairs(conditionalData.entries) do
        if entry.type == "condition" and entry.conditionType == "Charges" and entry.Charges then
            return {
                comparison = entry.Charges.comparison,
                targetValue = entry.Charges.targetValue
            }
        end
    end
    
    return nil
end

--- Checks if a specific specialVisibilityCondition (from a tracker config) uses charges.
--- Used to determine if property overrides should target variant frame only or all frames.
--- @param specialVisibilityCondition table The condition entry from tracker config
--- @return boolean True if this condition uses Charges
function ConditionalEngine:SpecialVisibilityUsesCharges(specialVisibilityCondition)
    if not specialVisibilityCondition or not specialVisibilityCondition.conditionalName then
        return false
    end
    return self:ConditionalUsesCharges(specialVisibilityCondition.conditionalName)
end

--- Checks if a trackerConfig has any conditionals that use charges.
--- Used by FrameTrackerManager to determine if a variant frame is needed.
--- @param trackerConfig table The tracker configuration to check
--- @return boolean True if any conditional uses charges
function ConditionalEngine:TrackerHasChargesConditionals(trackerConfig)
    if not trackerConfig or not trackerConfig.specialVisibilityConditions then
        return false
    end
    
    -- Check each conditional to see if any use charges
    for _, condition in ipairs(trackerConfig.specialVisibilityConditions) do
        if condition.conditionalName and self:ConditionalUsesCharges(condition.conditionalName) then
            return true
        end
    end
    
    return false
end

-- ============================================================================
-- PROPERTY-OVERRIDE APPLICATION
-- ============================================================================

-- In-memory snapshot of original DB values captured just before the first
-- time an override is applied.  Keyed by "<baseSpellID>/<trackerType>/<path>".
-- Cleared per-key when the conditional reverts so a later re-trigger
-- re-captures a fresh original.
ConditionalEngine._originalValues = ConditionalEngine._originalValues or {}

-- Cached visibility alpha values from GetFrameStateAlphas.
-- Keyed by frame reference. Updated by FrameTrackerManager before applying visibility.
-- Structure: { [frame] = { whenAvailable=1, whenActive=0, progressBar=1, fullBar=0 } }
-- Available for conditionals to reference when applying property overrides.
ConditionalEngine._frameAlphaCache = ConditionalEngine._frameAlphaCache or {}

--- Cache the visibility alpha values for a frame so conditionals can reference them.
--- Called by FrameTrackerManager in _ExecuteDrive after calculating alphas.
--- @param frame table The tracker frame
--- @param whenAvailable number Alpha when spell/buff is available/inactive
--- @param whenActive number Alpha when spell/buff is active/on cooldown
--- @param progressBar number Alpha for progress bar during cooldown
--- @param fullBar number Alpha for full bar during GCD/available
function ConditionalEngine:CacheFrameAlphas(frame, whenAvailable, whenActive, progressBar, fullBar)
    if not frame then return end
    self._frameAlphaCache[frame] = {
        whenAvailable = whenAvailable,
        whenActive = whenActive,
        progressBar = progressBar,
        fullBar = fullBar
    }
end

-- Active conditional property overrides per frame, organized by conditional name.
-- 
-- PRIORITY SYSTEM:
-- When a conditional passes, its property overrides are cached here.
-- FrameTrackerManager.ApplyVisibility methods check this cache FIRST,
-- falling back to state values only when no override is cached.
-- 
-- MULTIPLE CONDITIONS:
-- Each frame can have multiple active conditions, each with their own overrides.
-- Organized by conditional name (customName, or conditionalName, or index as fallback).
-- If multiple conditions set the same property, iteration order determines which wins.
-- 
-- LIFECYCLE:
-- 1. Conditional evaluates and passes → ApplyFramePropertyOverrides applies + caches with conditional name
-- 2. Every _ExecuteDrive → ApplyVisibility methods check cache for values
-- 3. Conditional fails → ClearFramePropertyOverrides(frame, conditionalKey) removes ONLY that condition's overrides
-- 4. Next _ExecuteDrive → ApplyVisibility methods use remaining conditional values or state values
-- 
-- DEBUGGING:
-- Use: /dump SpellStyler.ConditionalEngine:DebugGetFrameOverrides(frame)
-- Structure: { [frame] = { ["My Custom Condition"] = { ["statusBar.color"] = {r=1, g=0, b=0, a=1}, ... } } }
ConditionalEngine._framePropertyOverrides = ConditionalEngine._framePropertyOverrides or {}

--- Cache property overrides for a frame from a specific conditional.
--- These values take priority over state when ApplyVisibility methods run.
--- Multiple conditions on the same frame can each cache their own overrides.
--- @param frame table The tracker frame
--- @param conditionalKey string Unique identifier for this condition (customName, conditionalName, or index)
--- @param propertyOverrides table Array of { property = string, value = any }
function ConditionalEngine:CacheFramePropertyOverrides(frame, conditionalKey, propertyOverrides)
    if not frame or not conditionalKey or not propertyOverrides then return end
    
    -- Initialize frame's cache if needed
    if not self._framePropertyOverrides[frame] then
        self._framePropertyOverrides[frame] = {}
    end
    
    -- Initialize this conditional's slot if needed
    if not self._framePropertyOverrides[frame][conditionalKey] then
        self._framePropertyOverrides[frame][conditionalKey] = {}
    end
    
    -- Store each override by its property path for this specific conditional
    for _, override in ipairs(propertyOverrides) do
        if override.property and override.value ~= nil then
            self._framePropertyOverrides[frame][conditionalKey][override.property] = {
                value = override.value,
                baseAlpha = override.baseAlpha or nil,
                cloneAlpha = override.cloneAlpha or nil
            }
        end
    end
end

--- Get a cached property override value for a frame.
--- Checks ALL active conditionals for this property. If multiple conditionals set it,
--- iteration order determines which wins (unpredictable with string keys - use with caution).
--- Returns the override value if set, nil otherwise.
--- Used by ApplyVisibility methods to check for active conditional overrides.
--- @param frame table The tracker frame
--- @param propertyPath string Property path like "statusBar.color"
--- @return any|nil, number|nil, number|nil, boolean|nil --The cached override value, or nil if not set
function ConditionalEngine:GetCachedPropertyOverride(frame, propertyPath)
    if not frame or not self._framePropertyOverrides[frame] then
        return nil
    end
    
    local result = nil
    
    -- Iterate through all conditionals for this frame
    -- Note: With string keys, order is unpredictable if multiple conditions set same property
    for conditionalKey, overrides in pairs(self._framePropertyOverrides[frame]) do
        if overrides[propertyPath] ~= nil then
            result = overrides[propertyPath]
            return result.value, result.baseAlpha, result.cloneAlpha, ConditionalEngine:CanPropertyBeSecret(propertyPath)
        end
    end
    
    return nil 
end

--- Clear all cached property overrides for a specific conditional on a frame.
--- Called when a conditional stops passing to revert its overrides.
--- Other conditions' overrides remain active.
--- @param frame table The tracker frame
--- @param conditionalKey string Unique identifier for the condition to clear
function ConditionalEngine:ClearFramePropertyOverrides(frame, conditionalKey)
    if not frame or not conditionalKey then return end
    if not self._framePropertyOverrides[frame] then return end
    
    self._framePropertyOverrides[frame][conditionalKey] = nil
    
    -- Clean up empty cache entries
    local hasAny = false
    for _ in pairs(self._framePropertyOverrides[frame]) do
        hasAny = true
        break
    end
    if not hasAny then
        self._framePropertyOverrides[frame] = nil
    end
end

--- Clear ALL cached property overrides for a frame (all conditionals).
--- Used when a frame is destroyed or reset.
--- @param frame table The tracker frame
function ConditionalEngine:ClearAllFramePropertyOverrides(frame)
    if not frame then return end
    self._framePropertyOverrides[frame] = nil
end

--- Debug helper: Get all active property overrides for a frame.
--- Returns a table of { [conditionalKey] = { propertyPath = value, ... } }, or nil if no overrides.
--- Shows which conditionals are currently overriding which properties.
--- Usage: /dump SpellStyler.ConditionalEngine:DebugGetFrameOverrides(frame)
--- @param frame table The tracker frame
--- @return table|nil Active overrides organized by conditional name/key, or nil if none
function ConditionalEngine:DebugGetFrameOverrides(frame)
    if not frame or not self._framePropertyOverrides[frame] then
        return nil
    end
    -- Return a deep copy so debug inspection doesn't modify the cache
    local copy = {}
    for conditionalKey, overrides in pairs(self._framePropertyOverrides[frame]) do
        copy[conditionalKey] = {}
        for propPath, value in pairs(overrides) do
            copy[conditionalKey][propPath] = value
        end
    end
    return copy
end

--- Helper to find a property value in the overrides array
--- @param propertyOverrides table Array of { property = string, value = any }
--- @param propertyPath string The property path to search for
--- @return any|nil The value if found, nil otherwise
function ConditionalEngine:GetPropertyOverride(propertyOverrides, propertyPath)
    for _, override in ipairs(propertyOverrides) do
        if override.property == propertyPath then
            return override.value
        end
    end
    return nil
end

--- Extracts UnitHealth condition config from a conditional definition.
--- @param conditionalName string The name of the conditional
--- @return table|nil UnitHealth config { unit, comparison, targetValue, healthType } or nil
function ConditionalEngine:GetUnitHealthConfig(conditionalName)
    local conditionalData = SpellStyler_DB
        and SpellStyler_DB.conditionals
        and SpellStyler_DB.conditionals[conditionalName]
    if not conditionalData or not conditionalData.entries then
        return nil
    end
    
    for _, entry in ipairs(conditionalData.entries) do
        if entry.type == "condition" and entry.conditionType == "UnitHealth" and entry.UnitHealth then
            return entry.UnitHealth
        end
    end
    
    return nil
end

--- Calculates a curve-based value for UnitHealth conditionals.
--- Uses WoW's secret curve system to map health values to numeric outputs.
--- @param healthConfig table The UnitHealth config { unit, comparison, targetValue, healthType }
--- @param override table The property override definition
--- @return any The computed value (or original override.value if not applicable)
function ConditionalEngine:CalculateCurveValue(healthConfig, overrideValue, baseValue, isColor)
    -- Only apply curve calculation to color properties
    if UnitExists(healthConfig.unit) then
        if isColor then
            local calculatedValue_r, calculatedValue_g, calculatedValue_b, calculatedValue_a = UnitHealthPercent(healthConfig.unit, true, SpellStyler.Util:CurveComparison(healthConfig.targetValue, overrideValue, baseValue, healthConfig.comparison, true)):GetRGBA()
            return {
                r = calculatedValue_r,
                g = calculatedValue_g,
                b = calculatedValue_b,
                a = calculatedValue_a
            }
        else
            local calculatedValue = 1
            calculatedValue = UnitHealthPercent(healthConfig.unit, true, SpellStyler.Util:CurveComparison(healthConfig.targetValue, overrideValue, baseValue, healthConfig.comparison))
            return calculatedValue
        end
    else
        return baseValue
    end
end

function ConditionalEngine:CanPropertyBeSecret(property)
    local secretAllowed = {
        ['iconSettings.opacity'] = true,                 -- frame:SetAlpha
        ['iconSettings.frameStrataValue'] = true,        -- frame:SetFrameLevel
        ['iconSettings.iconTexturePath'] = true,         -- icon:SetTexture
        ['iconSettings.desaturated'] = true,             -- icon:SetDesaturated
        ['iconColor'] = true,                          -- icon:SetVertexColor
        ['iconColor.r'] = true,                          -- icon:SetVertexColor
        ['iconColor.g'] = true,                          -- icon:SetVertexColor
        ['iconColor.b'] = true,                          -- icon:SetVertexColor
        ['iconColor.a'] = true,                          -- iconContainer:SetAlpha
        ['iconSettings.borderColor'] = true,             -- borderFrame:SetBackdropBorderColor
        ['statusBar.displayState'] = true,               -- statusBar:Show / Hide
        ['statusBar.color'] = true,                      -- statusBar:SetStatusBarColor
        ['statusBar.customBarTexture'] = true,           -- statusBar:SetStatusBarTexture
        ['statusBar.rotation'] = true,                   -- statusBar:SetRotation
        ['statusBar.backgroundColor'] = true,            -- bgTexture:SetVertexColor
        ['statusBar.glowColor'] = true,                  -- glowTexture:SetVertexColor
        ['statusBar.borderColor'] = true,                -- borderPieces:SetVertexColor
        ['visualChargeBar.minValue'] = true,             -- statusBar:SetMinMaxValues
        ['visualChargeBar.maxValue'] = true,             -- statusBar:SetMinMaxValues
        ['chargeBasedDisplay.chargeValue'] = true,       -- anchorBar:SetValue
        ['countText.display'] = true,                    -- count:Show / Hide
        ['countText.color'] = true,                      -- count:SetTextColor
        ['customLabel.text'] = true,                     -- customLabel:SetText
        ['customLabel.color'] = true,                    -- customLabel:SetTextColor
        ['cooldownText.color'] = true,                   -- cdText:SetTextColor
        ['glowNotification.shouldDisplay'] = true        -- glowFrame:Show / Hide
    }
    return secretAllowed[property] or false
end


--- Applies property overrides from a special visibility condition to a tracker frame.
--- Routes overrides to variant frame only if conditional uses Charges, otherwise to both frames.
--- Computes dynamic curve values for UnitHealth conditionals before caching.
--- Caches overrides and triggers the unified update path via ApplyStaticFrameProperties.
--- @param frame table The tracker frame (base frame)
--- @param conditionalKey string The unique key for this conditional (name or index-based)
--- @param propertyOverrides table Array of property override definitions
--- @param trackerValue table The tracker's full config from State  
--- @param conditionalName string The name of the conditional being applied
function ConditionalEngine:ApplyFramePropertyOverrides(frame, conditionalKey, propertyOverrides, trackerValue, conditionalName)
    if not frame or not conditionalKey or not propertyOverrides or #propertyOverrides == 0 then return end
    
    local usesCharges = self:ConditionalUsesCharges(conditionalName or "")
    local targetFrames = {}
    
    if usesCharges then
        -- Charges conditional: apply to variant frame only
        if frame.variantFrame then
            table.insert(targetFrames, frame.variantFrame)
        end
    else
        -- Non-charges conditional: apply to all frames (base + variant if exists)
        table.insert(targetFrames, frame)
        if frame.variantFrame then
            table.insert(targetFrames, frame.variantFrame)
        end
    end
    
    -- COMPUTE dynamic curve values before caching
    -- If this conditional uses UnitHealth, automatically apply curve calculation to all overrides
    local computedOverrides = {}
    local healthConfig = self:GetUnitHealthConfig(conditionalName or "")
    local usesUnitHealth = (healthConfig ~= nil)
    
    for _, override in ipairs(propertyOverrides) do
        local overrideValue = override.value

        --[[
            If a property is passed to a method that does NOT accept secret values when tainted, then a special implementation is requried
                - 
        ]]

        -- Automatically use curve calculation for all property overrides when UnitHealth conditional is used
        if usesUnitHealth and healthConfig then
            local baseValueDefault = nil
            if override.property == 'glowNotification.glowColor' then
                -- This specific property needs to have 0 be the default alpha, since this is a "requiresConstantUpdate" property (it cant destinguish true false) AND its also weird because it needs to support the "display notification when spell becomes available"
                local stateValue = SpellStyler.State:AccessNestedValue(trackerValue, override.property, nil, 'get')
                baseValueDefault = {
                    r = stateValue.r,
                    g = stateValue.g,
                    b = stateValue.b,
                    a = 0
                }
            else
                baseValueDefault = SpellStyler.State:AccessNestedValue(trackerValue, override.property, nil, 'get')
                -- curves can only accept numbers, ensure its a number being passed (TODO: remove or create solution for unsupported methods that are called as a result of the property override options)
                local valueAsNumber = tonumber(overrideValue)
                if valueAsNumber ~= nil  then
                    overrideValue = valueAsNumber
                end
            end

            local isColor = (override.property and string.lower(override.property):find("color")) ~= nil
            overrideValue = self:CalculateCurveValue(healthConfig, overrideValue, baseValueDefault, isColor or false)
        end
        
        table.insert(computedOverrides, {
            property = override.property,
            value = overrideValue,
            duration = override.duration  -- Preserve duration for temporary overrides
        })
    end
    if frame.meta.baseSpellID == 116670 then
        -- DevTool:AddData(computedOverrides, "caching property overrides onto frame")
    end
    -- Apply and cache COMPUTED overrides to all target frames
    for _, targetFrame in ipairs(targetFrames) do
        ConditionalEngine:CacheFramePropertyOverrides(targetFrame, conditionalKey, computedOverrides)
    end
    
    -- Trigger the unified update path via FrameTrackerManager
    -- Note: Always use base frame for state lookups
    if SpellStyler.FrameTrackerManager then
        SpellStyler.FrameTrackerManager:ApplyStaticFrameProperties(
            frame.meta.baseSpellID,
            frame.meta.trackerType
        )
    end
end



ConditionalEngine._conditionalStates = ConditionalEngine._conditionalStates or {}
setmetatable(ConditionalEngine._conditionalStates, { __mode = "k" })  -- Weak keys = auto cleanup

-- Structure: 
-- {
--   [frame] = {
--     [conditionalKey] = {
--       lastResult = true/false,
--       lastChangeTime = GetTime(),
--       temporaryOverrides = { ... }  -- for time-limited overrides
--     }
--   }
-- }
function ConditionalEngine:ClearEvaluationCache(frame, conditionalKey)
    -- Clear evaluation state to force re-evaluation
    if self._conditionalStates[frame] then
        self._conditionalStates[frame][conditionalKey] = {
            previousConditionalResult = nil
        }
    end
    
    -- CRITICAL: Also clear property override caches for this conditional
    -- Without this, old property values persist even after settings change
    self:ClearFramePropertyOverrides(frame, conditionalKey)
    if frame.variantFrame then
        self:ClearFramePropertyOverrides(frame.variantFrame, conditionalKey)
    end
end

--- Clears ALL conditional caches for a frame (both evaluation and property overrides).
--- Used when conditional name changes or major settings updates occur.
--- @param frame table The tracker frame
function ConditionalEngine:ClearAllConditionalCaches(frame)
    if not frame then return end
    
    -- Clear evaluation states
    if self._conditionalStates[frame] then
        self._conditionalStates[frame] = nil
    end
    
    -- Clear property overrides
    self:ClearAllFramePropertyOverrides(frame)
    if frame.variantFrame then
        self:ClearAllFramePropertyOverrides(frame.variantFrame)
    end
end

--- Generates a conditional key using the same priority logic as EvaluateAll.
--- Priority: customName > conditionalName > "Condition {index}"
--- Used by State.lua to ensure key consistency across all cache operations.
--- @param specialVisibilityCondition table The conditional config entry
--- @param conditionalIndex number The conditional's index in the array
--- @return string The generated conditional key
function ConditionalEngine:GenerateConditionalKey(specialVisibilityCondition, conditionalIndex)
    if not specialVisibilityCondition then return "Condition " .. tostring(conditionalIndex or 0) end
    
    local conditionalKey = specialVisibilityCondition.customName
    if not conditionalKey or conditionalKey == "" then
        conditionalKey = specialVisibilityCondition.conditionalName
    end
    if not conditionalKey or conditionalKey == "" then
        conditionalKey = "Condition " .. tostring(conditionalIndex or 0)
    end
    
    return conditionalKey
end


function ConditionalEngine:EvaluateAll()
    local State = SpellStyler.State
    if not State then return end
    
    local FrameTrackerManager = SpellStyler.FrameTrackerManager
    if not FrameTrackerManager then return end

    local success, specDatabase = State:GetDataBase_V2()
    if not success or not specDatabase then return end

    for _, trackerType in ipairs({ "spells", "buffs" }) do
        local trackerTypeDatabase = specDatabase[trackerType]
        if trackerTypeDatabase then
            for baseSpellID, trackerValue in pairs(trackerTypeDatabase) do
                -- check if the database for the spell/frame has any conditionas associated to it
                local specialVisibilityConditions = trackerValue.specialVisibilityConditions
                if specialVisibilityConditions and #specialVisibilityConditions > 0 then
                    -- Get the actual frame to access activeSpellID - the activeSpellID is required when evaluating the conditional
                    local customFrame = FrameTrackerManager.SpellStyler_frames[trackerType]
                        and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                    
                    if customFrame then
                        local activeSpellID = (customFrame.meta and customFrame.meta.activeSpellID) or baseSpellID
                        local spellInfo = C_Spell.GetSpellInfo(activeSpellID)
                        
                        -- Variant frame lifecycle is managed by RebuildChargeInfrastructure
                        -- Do NOT manage it here or it will get out of sync with charge bars
                        
                        -- now loop over each condition and see if it has properties assigned that might need to be updated if the condition is true
                        for conditionalIndex, specialVisibilityCondition in ipairs(specialVisibilityConditions) do
                            local conditionalName = specialVisibilityCondition.conditionalName
                            
                            if conditionalName and conditionalName ~= ""
                            and specialVisibilityCondition.propertyOverrides
                            and #specialVisibilityCondition.propertyOverrides > 0 then
                                -- Generate conditional key using helper for consistency
                                -- IMPORTANT: This must match the key generation in State.lua
                                local conditionalKey = self:GenerateConditionalKey(specialVisibilityCondition, conditionalIndex)
                                
                                local context = { spellID = activeSpellID, trackerType = trackerType }
                                local conditionalResult, requiresConstantUpdate = EvaluateConditional(conditionalName, self.liveValues, context)
                                -- now that we have evaluated the conditional, save its state so we can see when it changed.
                                if not self._conditionalStates[customFrame] then
                                    self._conditionalStates[customFrame] = {}
                                end
                                if not self._conditionalStates[customFrame][conditionalKey] then
                                    self._conditionalStates[customFrame][conditionalKey] = {}
                                end
                                
                                -- save the most recent evaluation then check if there was a difference
                                local previousConditionalResult = self._conditionalStates[customFrame][conditionalKey].previousConditionalResult
                                
                                if (previousConditionalResult ~= conditionalResult and conditionalResult == true) or (conditionalResult == true and requiresConstantUpdate) then
                                    -- it became true, so all properties can be applied
                                    self:ApplyFramePropertyOverrides(customFrame, conditionalKey, specialVisibilityCondition.propertyOverrides, trackerValue, conditionalName)
                                    

                                    -- Unable to do temporary property override when a condition requires constant updates (because its unable to decern between true and false, like checking unit health with a curve object (values are secret))
                                    --[[
                                        If a conditional requires constant updates due to its result being a secret value, then what that means is:
                                            Some  properties are passed to methods that do not support secret values, therefore a secret frame (not the whole thing, just the component that is having a property updated) will need a second isntance, with the new property value, and it will use alpha, to show the correct  version (almost like the charge based conditional properties, but a second frame, rather than the statusBar anchor approach)
                                    ]]
                                    if not requiresConstantUpdate then
                                        for _, override in ipairs(specialVisibilityCondition.propertyOverrides) do
                                            -- Creat the timer for the specific property override IF its a temporaryOverride property
                                            if override.duration ~= nil and override.duration > 0 then
                                                C_Timer.After(override.duration, function()
                                                    -- Check if conditional is still true AND property overrides still exist
                                                    if self._conditionalStates[customFrame] 
                                                        and self._conditionalStates[customFrame][conditionalKey]
                                                        and self._conditionalStates[customFrame][conditionalKey].previousConditionalResult
                                                        and self._framePropertyOverrides[customFrame]
                                                        and self._framePropertyOverrides[customFrame][conditionalKey] then
                                                        -- Still true, safe to remove this property
                                                        self._framePropertyOverrides[customFrame][conditionalKey][override.property] = nil
                                                        -- Trigger update
                                                        FrameTrackerManager:ApplyStaticFrameProperties(baseSpellID, trackerType)
                                                    end
                                                    -- Otherwise conditional went false already, cache was cleared, do nothing
                                                end)
                                            end 
                                        end
                                    end
                                elseif previousConditionalResult ~= conditionalResult and conditionalResult == false then
                                    -- Conditional failed: clear this condition's cached overrides (ALL even the temporary properties)
                                    self:ClearFramePropertyOverrides(customFrame, conditionalKey)
                                    -- Trigger unified update path to revert to state values
                                    if SpellStyler.FrameTrackerManager then
                                        SpellStyler.FrameTrackerManager:ApplyStaticFrameProperties(
                                            baseSpellID,
                                            trackerType
                                        )
                                    end
                                end
                                -- make sure to save the current value so we can detect when it changes next time
                                self._conditionalStates[customFrame][conditionalKey].previousConditionalResult = conditionalResult
                            end
                        end
                    end
                end
            end
        end
    end
end
