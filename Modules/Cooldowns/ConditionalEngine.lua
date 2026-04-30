-- ConditionalEngine.lua
-- Central system for evaluating Special Visibility Conditions on tracked icons.
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  ARCHITECTURE: ALPHA-AWARE PROPERTY APPLICATION                         │
-- │                                                                         │
-- │  Conditionals apply properties immediately after evaluation, using      │
-- │  cached alpha values from the visibility system to avoid conflicts.     │
-- │                                                                         │
-- │  Flow:                                                                  │
-- │    1. _ExecuteDrive calculates alpha values via GetFrameStateAlphas     │
-- │    2. Alpha values are cached in ConditionalEngine._frameAlphaCache     │
-- │    3. Visibility system applies alpha to frames                         │
-- │    4. When conditionals evaluate (via NotifySourceChanged), they:       │
-- │       a. Read cached alpha values                                       │
-- │       b. Apply property overrides using those alphas                    │
-- │       c. No fighting - conditional colors use visibility-calculated alpha│
-- │                                                                         │
-- │  EXAMPLE: No Charges + Insufficient Power                               │
-- │    Visibility: Calculates alpha=0 (no charges) → caches it              │
-- │    Visibility: Sets icon:SetAlpha(0)                                    │
-- │    Conditional: Evaluates "insufficient power" → TRUE                   │
-- │    Conditional: Sets icon:SetVertexColor(1,1,1, CACHED_ALPHA)           │
-- │    Result: Icon invisible (alpha=0) with white color (no flicker)       │
-- │                                                                         │
-- │  Previously, both systems would fight:                                  │
-- │    - Visibility: icon:SetAlpha(0) because no charges                    │
-- │    - Conditional: triggers UpdateFrame → resets alpha to 1 (config)     │
-- │    - Combat event fires again → alpha back to 0 → flicker               │
-- │                                                                         │
-- │  Now, conditionals USE the visibility system's alpha calculations:      │
-- │    - Visibility manages: when alpha should be 0 vs 1                    │
-- │    - Conditionals manage: color, scale, size                            │
-- │    - When conditionals set color.a, they use cached visibility alpha    │
-- │    - No overlap = no fighting                                           │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  FLOW                                                                   │
-- │                                                                         │
-- │  1.  A WoW event listener observes a game-state change.                │
-- │                                                                         │
-- │  2.  It calls:                                                          │
-- │        ConditionalEngine:NotifySourceChanged("ComboPoints", 4)         │
-- │                                                                         │
-- │  3.  The value is written into liveValues and EvaluateAll() runs.      │
-- │                                                                         │
-- │  4.  EvaluateAll() iterates every tracked icon, evaluates conditionals,│
-- │      and applies property overrides IMMEDIATELY using cached alphas.   │
-- │                                                                         │
-- │  5.  Separately, when _ExecuteDrive runs for a frame update:           │
-- │        a.  GetFrameStateAlphas calculates visibility alphas.           │
-- │        b.  Alphas are cached via CacheFrameAlphas.                     │
-- │        c.  Visibility system applies alphas to frames.                 │
-- │                                                                         │
-- │  6.  When conditionals apply properties (from step 4), they read       │
-- │      the cached alphas and use them, avoiding conflicts.               │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  liveValues — flat key/value table, always fully populated             │
-- │                                                                         │
-- │  liveValues.ComboPoints     = <number>          default 0              │
-- │  liveValues.Health          = <number> %        default 100            │
-- │  liveValues.Power           = <number>          default 0              │
-- │  liveValues.PowerMax        = <number>          default 0              │
-- │  liveValues.PowerType       = <number>          default 0              │
-- │  liveValues.Aura_<id>       = true | false      default false          │
-- │  liveValues.AuraStacks_<id> = <number>          default 0              │
-- │  liveValues.Cooldown_<id>   = <number> secs remaining, default 0      │
-- │                                                                         │
-- │  context — spell-specific evaluation context (passed to EvaluateConditional) │
-- │    context.spellID      = <number>  the spell being evaluated          │
-- │    context.trackerType  = <string>  "spells" or "buffs"                 │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  HOW TO WIRE A NEW SOURCE                                               │
-- │                                                                         │
-- │  Combo points:                                                          │
-- │    local comboPointCount = UnitPower("player", Enum.PowerType.ComboPoints)│
-- │    ConditionalEngine:NotifySourceChanged("ComboPoints", comboPointCount)│
-- │                                                                         │
-- │  Aura active/inactive (spellID 12345):                                 │
-- │    local isAuraActive = C_UnitAuras.GetAuraDataBySpellName(…) ~= nil  │
-- │    ConditionalEngine:NotifySourceChanged("Aura_12345", isAuraActive)   │
-- │                                                                         │
-- │  Cooldown remaining (spellID 12345):                                   │
-- │    local cooldownStartTime, cooldownDuration = GetSpellCooldown(12345) │
-- │    local remainingCooldownSeconds =                                     │
-- │        math.max(0, (cooldownStartTime + cooldownDuration) - GetTime()) │
-- │    ConditionalEngine:NotifySourceChanged("Cooldown_12345",             │
-- │                                          remainingCooldownSeconds)     │
-- └─────────────────────────────────────────────────────────────────────────┘

local ADDON_NAME, SpellStyler = ...
SpellStyler.ConditionalEngine = SpellStyler.ConditionalEngine or {}
local ConditionalEngine = SpellStyler.ConditionalEngine

-- ============================================================================
-- LIVE VALUES STORE
-- Always fully populated with safe defaults so EvaluateConditional can read
-- any key without a nil check.  NotifySourceChanged just overwrites entries.
-- ============================================================================
ConditionalEngine.liveValues = {
    ComboPoints = 0,
    -- Aura_<spellID>       = true|false  (written on first NotifySourceChanged)
    -- AuraStacks_<spellID> = number      (written on first NotifySourceChanged)
    -- Cooldown_<spellID>   = number secs (written on first NotifySourceChanged)
}

-- ============================================================================
-- SOURCE NOTIFICATION (call this from event listeners)
-- ============================================================================

--- Write a new value into liveValues and immediately re-evaluate all icons.
---
--- @param liveValueKey  string   e.g. "ComboPoints", "Aura_12345", "Cooldown_12345"
--- @param updatedValue  any      the current value for that key
function ConditionalEngine:NotifySourceChanged(liveValueKey, updatedValue)
    self.liveValues[liveValueKey] = updatedValue
    self:EvaluateAll()
end

-- ============================================================================
-- CONDITIONAL EVALUATION
-- ============================================================================

local comparisonFunctions = {
    ["<"]  = function(leftValue, rightValue) return leftValue <  rightValue end,
    ["<="] = function(leftValue, rightValue) return leftValue <= rightValue end,
    [">"]  = function(leftValue, rightValue) return leftValue >  rightValue end,
    [">="] = function(leftValue, rightValue) return leftValue >= rightValue end,
    ["=="] = function(leftValue, rightValue) return leftValue == rightValue end,
    ["~="] = function(leftValue, rightValue) return leftValue ~= rightValue end,
}

--- Recursively copy a table so the result shares no references with the original.
--- Non-table values are returned as-is (they are already value types in Lua).
---
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

--- Expand the partiallyResolved list (booleans + operator/boundary tables) into
--- a flat token stream, then evaluate it via recursive descent — respecting
--- parentheses and AND/OR operators left-to-right.
---
--- Token stream rules:
---   boundary  openParens=N  → N × "("  tokens (before first condition)
---   operator  closeParens=N → N × ")"  tokens (after left operand)
---             operand       → "and" or "or"
---             openParens=N  → N × "("  tokens (before right operand)
---   boundary  closeParens=N → N × ")"  tokens (after last condition)
---   boolean                 → true | false
---
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

--- Walk the entries of the named conditional, evaluate each CONDITION node
--- against liveValues (for global state) and context (for spell-specific data),
--- combine them with AND/OR operators, and return whether the overall conditional passes.
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
				local currentValue = ConditionalEngine.liveValues["ComboPoints"]
				local comparison = conditionStructure.ComboPoints and conditionStructure.ComboPoints.comparison
				local targetValue = conditionStructure.ComboPoints and conditionStructure.ComboPoints.targetValue
				if comparison and targetValue and comparisonFunctions[comparison] then
					table.insert(partiallyResolved, comparisonFunctions[comparison](currentValue, targetValue))
				else
					table.insert(partiallyResolved, false)
				end
			
			elseif conditionStructure.conditionType == "IsSpellUsable" then
				-- Spell-specific: requires context.spellID
				if context and context.spellID then
					local isUsable, insufficientPower = C_Spell.IsSpellUsable(context.spellID)
					-- Actual state: true if unable to cast due to insufficient power
					local targetValue = conditionStructure.IsSpellUsable.state
					if targetValue == 'able' then
						table.insert(partiallyResolved, isUsable)
					elseif targetValue == 'unable' then
						table.insert(partiallyResolved, not isUsable)
					elseif targetValue == 'insufficientPower' then
						table.insert(partiallyResolved, not isUsable and insufficientPower)
					end
				else
					table.insert(partiallyResolved, false)
				end
			end
		else
			table.insert(partiallyResolved, deepCopy(conditionStructure))
		end
	end

	local finalizeResolvedValue, middleResolve = FinalizeResolved(partiallyResolved)
    return finalizeResolvedValue
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
--- Caches overrides and triggers the unified update path via UpdateFrame_ConfigurationChanges.
--- @param frame table The tracker frame
--- @param conditionalKey string The unique key for this conditional (name or index-based)
--- @param propertyOverrides table Array of property override definitions
--- @param trackerValue table The tracker's full config from State
function ConditionalEngine:ApplyFramePropertyOverrides(frame, conditionalKey, propertyOverrides, trackerValue)
    if not frame or not conditionalKey or not propertyOverrides or #propertyOverrides == 0 then return end
    
    -- Cache all property overrides so UpdateFrame_ConfigurationChanges can use them
    ConditionalEngine:CacheFramePropertyOverrides(frame, conditionalKey, propertyOverrides)
    
    -- Trigger the unified update path via FrameTrackerManager
    if SpellStyler.FrameTrackerManager then
        SpellStyler.FrameTrackerManager:UpdateFrame_ConfigurationChanges(
            frame.meta.baseSpellID,
            frame.meta.trackerType
        )
        
        -- For visibility-related properties, also trigger ApplyVisibility methods
        -- These use the cached alpha states and override values
        local hasIconOverride = ConditionalEngine:GetPropertyOverride(propertyOverrides, "iconColor")
        local hasStatusBarOverride = ConditionalEngine:GetPropertyOverride(propertyOverrides, "statusBar.color")
        
        if hasIconOverride and ConditionalEngine._frameAlphaCache[frame] then
            SpellStyler.FrameTrackerManager.ApplyVisibility.Icon({
                displayState = trackerValue.iconSettings.iconDisplayState,
                whenAvailableToCastAlpha = ConditionalEngine._frameAlphaCache[frame].whenAvailable,
                whenOnCooldownAlpha = ConditionalEngine._frameAlphaCache[frame].whenActive,
                customFrame = frame,
                config = trackerValue
            })
        end
        
        if hasStatusBarOverride and ConditionalEngine._frameAlphaCache[frame] then
            SpellStyler.FrameTrackerManager.ApplyVisibility.StatusBar({
                progressBarAlpha = ConditionalEngine._frameAlphaCache[frame].progressBar,
                fullBarAlpha = ConditionalEngine._frameAlphaCache[frame].fullBar,
                customFrame = frame,
                displayState = trackerValue.statusBar.displayState,
                statusBarConfig = trackerValue.statusBar,
                config = SpellStyler.State:GetSpecificTrackerValue(frame.meta.baseSpellID, frame.meta.trackerType),
                isFull = trackerValue.statusBar and trackerValue.statusBar.defaultFillValue == 'full'
            })
        end
    end
end

--- Apply (or revert) property overrides for one SVC entry on an icon.
--- 
--- NOTE: This function writes to the DB and triggers UpdateFrame_ConfigurationChanges.
--- It is kept for compatibility with settings UI changes where we want to persist
--- overrides to the database. For the render pipeline, use ApplyActiveOverridesToFrame
--- instead, which applies overrides directly to frames without DB updates.
---
--- `conditionalPassed` = true  → write each override value into the tracker
---                                config (snapshots the original first).
--- `conditionalPassed` = false → restore every previously-snapshotted original
---                                and discard the snapshot.
---
--- @param  baseSpellID          number
--- @param  trackerType          string
--- @param  propertyOverrides    table   array of { property=string, value=any }
--- @param  conditionalPassed    boolean
local function ApplyPropertyOverrides(baseSpellID, trackerType, propertyOverrides, conditionalPassed)
    local State = SpellStyler.State
    if not State then return end
    if not propertyOverrides or #propertyOverrides == 0 then return end

    if conditionalPassed then
        for _, override in ipairs(propertyOverrides) do
            local path = override.property
            if path and path ~= "" then
                local snapshotKey = baseSpellID .. "/" .. trackerType .. "/" .. path
                -- Capture the canonical original only on the first application.
                if ConditionalEngine._originalValues[snapshotKey] == nil then
                    ConditionalEngine._originalValues[snapshotKey] =
                        State:GetTrackerValueConfigProperty(baseSpellID, trackerType, path)
                end
                State:SetTrackerValueConfigProperty(baseSpellID, trackerType, path, override.value)
            end
        end
    else
        for _, override in ipairs(propertyOverrides) do
            local path = override.property
            if path and path ~= "" then
                local snapshotKey = baseSpellID .. "/" .. trackerType .. "/" .. path
                local original = ConditionalEngine._originalValues[snapshotKey]
                if original ~= nil then
                    State:SetTrackerValueConfigProperty(baseSpellID, trackerType, path, original)
                    ConditionalEngine._originalValues[snapshotKey] = nil
                end
            end
        end
    end
end

-- ============================================================================
-- CENTRAL EVALUATION PASS
-- Called automatically by NotifySourceChanged after every data update.
-- Can also be called manually (e.g. after the player changes a conditional
-- in the settings UI) to force a fresh pass.
-- 
-- Evaluates conditionals and applies property overrides immediately.
-- Uses cached alpha values from GetFrameStateAlphas to avoid conflicts
-- with the visibility system.
-- ============================================================================

--- For every tracked icon in the current spec's database, check each Special
--- Visibility Condition entry, and if all required data is available, evaluate
--- the associated conditional and apply property overrides immediately.
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
                local specialVisibilityConditions = trackerValue.specialVisibilityConditions
                if specialVisibilityConditions and #specialVisibilityConditions > 0 then
                    -- Get the actual frame to access activeSpellID
                    local customFrame = FrameTrackerManager.SpellStyler_frames[trackerType]
                        and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                    
                    if customFrame then
                        local activeSpellID = (customFrame.meta and customFrame.meta.activeSpellID) or baseSpellID
                        
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
                                local conditionalPassed = EvaluateConditional(conditionalName, self.liveValues, context)
                                
                                if conditionalPassed then
                                    -- Conditional passed: cache overrides and trigger unified update path
                                    self:ApplyFramePropertyOverrides(customFrame, conditionalKey, specialVisibilityCondition.propertyOverrides, trackerValue)
                                else
                                    -- Conditional failed: clear this condition's cached overrides
                                    self:ClearFramePropertyOverrides(customFrame, conditionalKey)
                                    -- Trigger unified update path to revert to state values
                                    if SpellStyler.FrameTrackerManager then
                                        SpellStyler.FrameTrackerManager:UpdateFrame_ConfigurationChanges(
                                            baseSpellID,
                                            trackerType
                                        )
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
