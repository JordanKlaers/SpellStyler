

local ADDON_NAME, SpellStyler = ...
SpellStyler.ConditionalEngine = SpellStyler.ConditionalEngine or {}
local ConditionalEngine = SpellStyler.ConditionalEngine


ConditionalEngine.liveValues = {
    ComboPoints = 0,
    -- Aura_<spellID>       = true|false  (written on first NotifySourceChanged)
    -- AuraStacks_<spellID> = number      (written on first NotifySourceChanged)
    -- Cooldown_<spellID>   = number secs (written on first NotifySourceChanged)
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
--- @return boolean
local function EvaluateConditional(conditionalName, currentLiveValues, context)
    local conditionalData = SpellStyler_DB
        and SpellStyler_DB.conditionals
        and SpellStyler_DB.conditionals[conditionalName]
    if not conditionalData or not conditionalData.entries or #conditionalData.entries == 0 then
        return false
    end
	

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
                    if spellCharges.maxCharges and spellCharges.maxCharges > 1 then
                        canCast = isUsable and not C_Spell.GetSpellCharges(context.spellID).isActive
                    else
                        canCast = isUsable and not C_Spell.GetSpellCooldown(context.spellID).isActive
                    end
					local targetValue = conditionStructure.IsSpellUsable.state
					if targetValue == 'able' then
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
			end
		else
			table.insert(partiallyResolved, deepCopy(conditionStructure))
		end
	end

	local finalizeResolvedValue, middleResolve = FinalizeResolved(partiallyResolved)
    return finalizeResolvedValue
end

-- ============================================================================
-- CHARGE CONDITIONAL HELPERS
-- ============================================================================

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
            self._framePropertyOverrides[frame][conditionalKey][override.property] = override.value
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
--- @return any|nil The cached override value, or nil if not set
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
        end
    end
    
    return result
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

--- Applies property overrides from a special visibility condition to a tracker frame.
--- Routes overrides to variant frame only if conditional uses Charges, otherwise to both frames.
--- Caches overrides and triggers the unified update path via UpdateFrame_ConfigurationChanges.
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
    
    -- Apply and cache overrides to all target frames
    for _, targetFrame in ipairs(targetFrames) do
        ConditionalEngine:CacheFramePropertyOverrides(targetFrame, conditionalKey, propertyOverrides)
    end
    
    -- Trigger the unified update path via FrameTrackerManager
    -- Note: Always use base frame for state lookups
    if SpellStyler.FrameTrackerManager then
        SpellStyler.FrameTrackerManager:UpdateFrame_ConfigurationChanges(
            frame.meta.baseSpellID,
            frame.meta.trackerType
        )
        
        -- For visibility-related properties, also trigger ApplyVisibility methods
        -- These use the cached alpha states and override values
        local hasIconOverride = ConditionalEngine:GetPropertyOverride(propertyOverrides, "iconColor")
        local hasStatusBarOverride = ConditionalEngine:GetPropertyOverride(propertyOverrides, "statusBar.color")
        
        if hasIconOverride then
            for _, targetFrame in ipairs(targetFrames) do
                if ConditionalEngine._frameAlphaCache[targetFrame] then
                    SpellStyler.FrameTrackerManager.ApplyVisibility.Icon({
                        displayState = trackerValue.iconSettings.iconDisplayState,
                        whenAvailableToCastAlpha = ConditionalEngine._frameAlphaCache[targetFrame].whenAvailable,
                        whenOnCooldownAlpha = ConditionalEngine._frameAlphaCache[targetFrame].whenActive,
                        customFrame = targetFrame,
                        config = trackerValue
                    })
                end
            end
        end
        
        if hasStatusBarOverride then
            for _, targetFrame in ipairs(targetFrames) do
                if ConditionalEngine._frameAlphaCache[targetFrame] then
                    SpellStyler.FrameTrackerManager.ApplyVisibility.StatusBar({
                        progressBarAlpha = ConditionalEngine._frameAlphaCache[targetFrame].progressBar,
                        fullBarAlpha = ConditionalEngine._frameAlphaCache[targetFrame].fullBar,
                        customFrame = targetFrame,
                        displayState = trackerValue.statusBar.displayState,
                        statusBarConfig = trackerValue.statusBar,
                        config = SpellStyler.State:GetSpecificTrackerValue(frame.meta.baseSpellID, frame.meta.trackerType),
                        isFull = trackerValue.statusBar and trackerValue.statusBar.defaultFillValue == 'full'
                    })
                end
            end
        end
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

function ConditionalEngine:EvaluateAll()
    local State = SpellStyler.State
    if not State then return end
    
    local FrameTrackerManager = SpellStyler.FrameTrackerManager
    if not FrameTrackerManager then return end

    local success, specDatabase = pcall(function() return State:GetDataBase_V2() end)
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
                                -- Generate a unique key for this conditional
                                -- Priority: customName > conditionalName > "Condition {index}"
                                local conditionalKey = specialVisibilityCondition.customName
                                if not conditionalKey or conditionalKey == "" then
                                    conditionalKey = conditionalName
                                end
                                if not conditionalKey or conditionalKey == "" then
                                    conditionalKey = "Condition " .. tostring(conditionalIndex)
                                end
                                
                                local context = { spellID = activeSpellID, trackerType = trackerType }
                                local conditionalResult = EvaluateConditional(conditionalName, self.liveValues, context)
                                -- now that we have evaluated the conditional, save its state so we can see when it changed.
                                if not self._conditionalStates[customFrame] then
                                    self._conditionalStates[customFrame] = {}
                                end
                                if not self._conditionalStates[customFrame][conditionalKey] then
                                    self._conditionalStates[customFrame][conditionalKey] = {}
                                end
                                -- save the most recent evaluation then check if there was a difference
                                local previousConditionalResult = self._conditionalStates[customFrame][conditionalKey].previousConditionalResult
                                if previousConditionalResult ~= conditionalResult and conditionalResult == true then
                                    -- it became true, so all properties can be applied
                                    self:ApplyFramePropertyOverrides(customFrame, conditionalKey, specialVisibilityCondition.propertyOverrides, trackerValue, conditionalName)
                                    for _, override in ipairs(specialVisibilityCondition.propertyOverrides) do
                                        -- if override.property == propertyPath then
                                        --     return override.value
                                        -- end
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
                                                    FrameTrackerManager:UpdateFrame_ConfigurationChanges(baseSpellID, trackerType)
                                                end
                                                -- Otherwise conditional went false already, cache was cleared, do nothing
                                            end)
                                        end 
                                    end
                                else
                                    -- Conditional failed: clear this condition's cached overrides (ALL even the temporary properties)
                                    self:ClearFramePropertyOverrides(customFrame, conditionalKey)
                                    -- Trigger unified update path to revert to state values
                                    if SpellStyler.FrameTrackerManager then
                                        SpellStyler.FrameTrackerManager:UpdateFrame_ConfigurationChanges(
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
