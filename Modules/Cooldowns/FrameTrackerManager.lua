-- ============================================================================
-- SpellStyler FrameTrackerManager.lua
-- Creates positionable highlight clones for tracker buffs
-- Detects active/inactive state via auraInstanceID (no secret value math)
-- ============================================================================

local addonName, SpellStyler = ...
SpellStyler.FrameTrackerManager = SpellStyler.FrameTrackerManager or {}
local FrameTrackerManager = SpellStyler.FrameTrackerManager
local FRAME_PREFIX = "TweaksUI_CustomFrameTracker_"

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
            iconDisplayState = "always", -- "always", "inactive/cooldownText", "active/available", "never"
            iconTexturePath = "",
            desaturated = false,
            enabled = true,
            size = 48,
            opacity = 1,
            hideDefaultSweep = false,
            trackIndividualChargeCooldown = false
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
            barFillDirection = 'regular', -- 'inverse'
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
function FrameTrackerManager:GetCurrentSpecID()
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local specID = GetSpecializationInfo(specIndex)
    return specID
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
        FrameTrackerManager:UpdateFrame_copyCharges(uniqueID, trackerType)
        if SpellStyler_frames[trackerType][uniqueID].isCooldownSet then
            FrameTrackerManager:UpdateFrame_RealCooldown(uniqueID, trackerType)
        else
            FrameTrackerManager:UpdateFrame_IgnoreGCD(uniqueID, trackerType)
        end
    end
end

function FrameTrackerManager:GetAllTrackerValues(trackerType)
    local db = FrameTrackerManager:GetDataBase_V2()
    return db[trackerType]
end

function FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
    local db = FrameTrackerManager:GetDataBase_V2()
    local iconConfig = db[trackerType][uniqueID] or {}
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
        FrameTrackerManager:UpdateFrame_copyCharges(uniqueID, trackerType)
        if SpellStyler_frames[trackerType][uniqueID].isCooldownSet then
            FrameTrackerManager:UpdateFrame_RealCooldown(uniqueID, trackerType)
        else
            FrameTrackerManager:UpdateFrame_IgnoreGCD(uniqueID, trackerType)
        end
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
                if child.GetBaseSpellID then
                    spellID = child:GetBaseSpellID()
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

                -- Add to database if not already tracker
                if not FrameTrackerManager:CheckIsAlreadyTracker(spellID, trackerType) then
                    FrameTrackerManager:AddTrackerValue({
                        uniqueID = spellID,
                        defaultIconTexturePath = texture,
                        name = spellData.name,
                        trackerType = trackerType
                    })
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
function FrameTrackerManager:ApplyStatusBar_OnlyRenderBar(frame, trackerConfig)
    if not frame.statusBar then return end
    local onlyBar = trackerConfig.statusBar.onlyRenderBar

    -- Background texture uses backgroundColor
    if frame.statusBar.bgTexture then
        local c = trackerConfig.statusBar.backgroundColor
        frame.statusBar.bgTexture:SetVertexColor(c.r or 0, c.g or 0, c.b or 0, onlyBar and 0 or (c.a or 0.65))
    end

    -- Glow overlay uses glowColor
    if frame.statusBar.glowTexture then
        local c = trackerConfig.statusBar.glowColor
        frame.statusBar.glowTexture:SetVertexColor(c.r or 1, c.g or 1, c.b or 1, onlyBar and 0 or (c.a or 0.25))
    end

    -- All 8 border pieces use borderColor
    local bc = trackerConfig.statusBar.borderColor
    local br, bg, bb = bc.r or 0, bc.g or 0, bc.b or 0
    local ba = onlyBar and 0 or (bc.a or 1)
    if frame.statusBar.borderCornerTL then frame.statusBar.borderCornerTL:SetVertexColor(br, bg, bb, ba) end
    if frame.statusBar.borderCornerTR then frame.statusBar.borderCornerTR:SetVertexColor(br, bg, bb, ba) end
    if frame.statusBar.borderCornerBR then frame.statusBar.borderCornerBR:SetVertexColor(br, bg, bb, ba) end
    if frame.statusBar.borderCornerBL then frame.statusBar.borderCornerBL:SetVertexColor(br, bg, bb, ba) end
    if frame.statusBar.borderEdgeTop    then frame.statusBar.borderEdgeTop:SetVertexColor(br, bg, bb, ba)    end
    if frame.statusBar.borderEdgeRight  then frame.statusBar.borderEdgeRight:SetVertexColor(br, bg, bb, ba)  end
    if frame.statusBar.borderEdgeBottom then frame.statusBar.borderEdgeBottom:SetVertexColor(br, bg, bb, ba) end
    if frame.statusBar.borderEdgeLeft   then frame.statusBar.borderEdgeLeft:SetVertexColor(br, bg, bb, ba)   end
end

function FrameTrackerManager:CreateTrackerFrame(uniqueID, trackerConfig, trackerType)
    if SpellStyler_frames[trackerType][uniqueID] then
        return SpellStyler_frames[trackerType][uniqueID]
    end
    local frameName = FRAME_PREFIX .. uniqueID
    local spellChargesInfo = C_Spell.GetSpellCharges(uniqueID)
    local spellInfo = C_Spell.GetSpellInfo(uniqueID)
    local frame = CreateFrame("Button", frameName, UIParent, "BackdropTemplate")
    frame:SetSize(trackerConfig.iconSettings.size, trackerConfig.iconSettings.size)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(100)
    
    if spellChargesInfo and spellChargesInfo.maxCharges > 1 then
        frame.isSpellWithCharges = true
    else
        frame.isSpellWithCharges = false
    end
    frame.spellName = spellInfo.name
    frame.trackIndividualChargeCooldown = trackerConfig.iconSettings.trackIndividualChargeCooldown or false
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
    local texture = (trackerConfig.iconSettings.iconTexturePath ~= "" and trackerConfig.iconSettings.iconTexturePath) or trackerConfig.defaultIconTexturePath
    frame.icon:SetTexture(texture)    
    local color = trackerConfig.iconColor or {}
    frame.icon:SetVertexColor(
        color.r or 1,
        color.g or 1,
        color.b or 1,
        color.a or 1
    )
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
    
    if (frame.isSpellWithCharges) then
        frame.spellHasCharges = true
    end
    -- Store settings on cooldown for hooks to use
    frame.cooldown._TUI_hideSweep = hideSweep
    frame.cooldown._TUI_showCountdownText = showCountdownText
    frame.cooldown:SetScript("OnCooldownDone", function(self)
        local spellInfo = C_Spell.GetSpellInfo(self.uniqueID)
        -- frame.isCooldownDataApplied = false
        frame.realCooldownActive = false
        
        -- If mock cooldown is active, disable it and update button text. This setup is in IconSettingsRenderer.lua
        if frame._spellStyler_mockCooldownActive then
            frame._spellStyler_mockCooldownActive = false
            
            -- Update the mock cooldown button text if it exists and is still valid
            if frame._spellStyler_mockCooldownBtn then
                pcall(function()
                    frame._spellStyler_mockCooldownBtn:SetText("Mock Cooldown")
                end)
            end
        end
        if (frame.isSpellWithCharges) then
            frame.spellHasCharges = true
        end
        C_Timer.After(0, function()
            -- must occur one update cycle after this callback so the text is updated on the bilzzard frame
            FrameTrackerManager:UpdateFrame_copyCharges(uniqueID, trackerType)
            FrameTrackerManager:UpdateFrame_IgnoreGCD(uniqueID, trackerType)
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
    -- Shown by UpdateFrame_IgnoreGCD when isFull, hidden when a real cooldown is active.
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
    
    frame.statusBar:Hide()  -- Hidden by default, shown when cooldown is active
    FrameTrackerManager:ApplyStatusBar_OnlyRenderBar(frame, trackerConfig)

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
    
    -- Initialize cooldown state flags
    frame.isCooldownDataApplied = false
    frame.isActualCooldown = false
    frame.isOnGCD = true
    frame.isBuffActive = false
    
    frame.trackerType = trackerType
    frame.uniqueID = uniqueID
    frame.cooldown.uniqueID = uniqueID
    -- Initially hidden
    frame:Show()
    
    SpellStyler_frames[trackerType][uniqueID] = frame
    FrameTrackerManager:UpdateFrame_IgnoreGCD(uniqueID, trackerType)
    -- Note: Layout registration happens in RegisterWithLayout(), called from EnableHighlight()
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
            if frame then
                frame:EnableMouse(true)
                frame:RegisterForDrag("LeftButton")
                
                -- Store the original scripts if they don't exist
                if not frame._SpellStyler_originalDragStart then
                    frame._SpellStyler_originalDragStart = frame:GetScript("OnDragStart")
                    frame._SpellStyler_originalDragStop = frame:GetScript("OnDragStop")
                    frame._SpellStyler_originalMouseDown = frame:GetScript("OnMouseDown")
                end
                
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
                
                -- Restore original scripts if they exist
                if frame._SpellStyler_originalDragStart then
                    frame:SetScript("OnDragStart", frame._SpellStyler_originalDragStart)
                end
                if frame._SpellStyler_originalDragStop then
                    frame:SetScript("OnDragStop", frame._SpellStyler_originalDragStop)
                end
                if frame._SpellStyler_originalMouseDown then
                    frame:SetScript("OnMouseDown", frame._SpellStyler_originalMouseDown)
                end
                
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
    local isMockActive = frame._spellStyler_mockCooldownActive or false
    if isMockActive then
        -- Disable mock cooldown
        frame._spellStyler_mockCooldownActive = false
        if frame.cooldown then
            frame.cooldown:Clear()
        end
        if frame.statusBar then
            local mockDurationObj = C_DurationUtil.CreateDuration()
            mockDurationObj:SetTimeFromEnd(GetTime(), 0)
            frame.statusBar:SetTimerDuration(
                mockDurationObj,
                Enum.StatusBarInterpolation.ExponentialEaseOut,
                Enum.StatusBarTimerDirection.RemainingTime
            )
        end
        FrameTrackerManager:UpdateFrame_IgnoreGCD(uniqueID, trackerType)
    else
        -- Enable mock cooldown (30 second duration)
        frame._spellStyler_mockCooldownActive = true
        local mockDuration = 30
        local now = GetTime()
        local startTime = now - (mockDuration * 0.5)  -- Start halfway through
        
        -- Create a proper DurationObject for SetCooldownFromDurationObject
        local mockDurationObj = C_DurationUtil.CreateDuration()
        mockDurationObj:SetTimeFromStart(startTime, mockDuration)
        
        -- Try SetCooldownFromDurationObject first (Midnight API), fall back to SetCooldown if not available
        if frame.cooldown then
            local setSuccess = false
            if frame.cooldown.SetCooldownFromDurationObject then
                local success, error = pcall(function()
                    frame.cooldown:SetCooldownFromDurationObject(mockDurationObj)
                end)
                setSuccess = success
            end
            -- If SetCooldownFromDurationObject doesn't exist or failed, fall back to SetCooldown
            if not setSuccess and frame.cooldown.SetCooldown then
                local success, error = pcall(function()
                    frame.Cooldown:SetCooldown(startTime, mockDuration)
                end)
            end
        end
        
        if frame.statusBar and frame.statusBar.SetTimerDuration then
            pcall(function()
                local timerCfg = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
                local timerDir = (timerCfg and timerCfg.statusBar and timerCfg.statusBar.barFillDirection == 'inverse')
                    and Enum.StatusBarTimerDirection.ElapsedTime
                    or  Enum.StatusBarTimerDirection.RemainingTime
                frame.statusBar:SetTimerDuration(
                    mockDurationObj,
                    Enum.StatusBarInterpolation.ExponentialEaseOut,
                    timerDir
                )
            end)
        end
        FrameTrackerManager:UpdateFrame_RealCooldown(uniqueID, trackerType)
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


function FrameTrackerManager:UpdateFrame_IgnoreGCD(uniqueID, trackerType)
    local trackerConfig = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
    local frame = SpellStyler_frames[trackerType][uniqueID] 
    frame.isCooldownSet = false
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
        local spellInfo = C_Spell.GetSpellInfo(uniqueID)
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
        if frame.spellHasCharges and trackerConfig.iconSettings.iconDisplayState ~= 'never' then
            frame.icon:Show()
            frame.count:Show()
        end
        FrameTrackerManager:UpdateFrame_copyCharges(uniqueID, trackerType)
    end)
    FrameTrackerManager:ApplyStatusBar_OnlyRenderBar(frame, trackerConfig)
end

function FrameTrackerManager:UpdateFrame_RealCooldown(uniqueID, trackerType)
    local trackerConfig = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
    local frame = SpellStyler_frames[trackerType][uniqueID] 
    frame.isCooldownSet = true
    local showstatusBar = (
        trackerConfig.statusBar.displayState == "always"
        or trackerConfig.statusBar.displayState == "active"
        or trackerConfig.statusBar.displayState == "cooldown"
    )
    local showSpellIcon = (
        trackerConfig.iconSettings.iconDisplayState == 'always'
        or trackerConfig.iconSettings.iconDisplayState == 'cooldown'
        or trackerConfig.iconSettings.iconDisplayState == 'active'
    )
    local suc, err = pcall(function()
        FrameTrackerManager:UpdateFrame_copyCharges(uniqueID, trackerType)
        if showstatusBar then
            -- local buffTimerCfg = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
            -- local buffTimerDir = (buffTimerCfg and buffTimerCfg.statusBar and buffTimerCfg.statusBar.barFillDirection == 'inverse')
            --     and Enum.StatusBarTimerDirection.ElapsedTime
            --     or  Enum.StatusBarTimerDirection.RemainingTime
            -- local durationObj = C_DurationUtil.CreateDuration()
            -- durationObj:SetTimeSpan(GetTime(), frame.statusBar.durationData.endTime)
            -- -- frame.statusBar:SetValue(1, Enum.StatusBarInterpolation.Immediate)
            -- frame.statusBar:SetTimerDuration(
            --     durationObj,
            --     Enum.StatusBarInterpolation.Immediate, --ExponentialEaseOut,
            --     buffTimerDir
            -- )
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
        if frame.spellHasCharges and trackerConfig.iconSettings.iconDisplayState ~= 'never' then
            frame.count:Show()
            frame.icon:Show()
        end
        -- A real cooldown is active; hide the full-cover overlay so the timer-driven fill shows through.
        if frame.statusBar.fullCoverTexture then
            -- C_Timer.After(0.15, function()
                frame.statusBar.fullCoverTexture:Hide()
            -- end)
        end
    end)
    FrameTrackerManager:ApplyStatusBar_OnlyRenderBar(frame, trackerConfig)
end


function FrameTrackerManager:UpdateFrame_ConfigurationChanges(uniqueID, trackerType)
    local trackerConfig = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
    local sourceFrame = cooldownManagerFrames[trackerType][uniqueID]
    local frame = SpellStyler_frames[trackerType][uniqueID]
    FrameTrackerManager:UpdateFrame_AuraEvent(uniqueID)
    if frame.isCooldownSet then
        FrameTrackerManager:UpdateFrame_RealCooldown(uniqueID, trackerType)
    else
        FrameTrackerManager:UpdateFrame_IgnoreGCD(uniqueID, trackerType)
    end
    -- Update icon texture
    local texture = (trackerConfig.iconSettings.iconTexturePath ~= "" and trackerConfig.iconSettings.iconTexturePath) or trackerConfig.defaultIconTexturePath
    frame.icon:SetTexture(texture)
    
    -- Update icon color
    local color = trackerConfig.iconColor or {}
    frame.icon:SetVertexColor(
        color.r or 1,
        color.g or 1,
        color.b or 1,
        color.a or 1
    )
    
    -- Update size
    frame:SetSize(trackerConfig.iconSettings.size, trackerConfig.iconSettings.size)
    
    -- Update opacity
    frame:SetAlpha(trackerConfig.iconSettings.opacity or 1)
        
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
        FrameTrackerManager:ApplyStatusBar_OnlyRenderBar(frame, trackerConfig)
    end
    
    -- Update position
    local pos = trackerConfig.position
    if pos and pos.anchorPoint then
        frame:ClearAllPoints()
        frame:SetPoint(
            pos.anchorPoint, 
            UIParent,
            pos.relativeAnchorPoint or pos.anchorPoint, 
            pos.x or 0, 
            pos.y or 0
        )
    end
end

function FrameTrackerManager:UpdateFrame_copyCharges(uniqueID, trackerType)
    local frame = SpellStyler_frames[trackerType][uniqueID]
    local sourceFrame = cooldownManagerFrames[trackerType][uniqueID]
    local config = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
    local spellInfo = C_Spell.GetSpellInfo(uniqueID)
    -- If display charges is disabled, hide the count text and bail out early
    if not config.countText.display then
        frame.count:SetText("")
        frame.count:Hide()
        return
    end
    pcall(function()
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
    local sourceCountFS = sourceFrame.Count or sourceFrame.count
    if not sourceCountFS and sourceFrame.GetChildren then
        local suc, err = pcall(function()
            for i = 1, sourceFrame:GetNumChildren() do
                local child = select(i, sourceFrame:GetChildren())
                if child then
                    local childCount = child.Count or child.count
                    if childCount then
                        sourceCountFS = childCount
                        break
                    end
                end
            end
        end)
    end
    if sourceCountFS and sourceCountFS.GetText then
        local suc, err = pcall(function()
            if config.countText.display then
                frame.count:SetText(sourceCountFS:GetText())
            end
            -- Use SetAlphaFromBoolean for visibility (handles secret booleans)
            if sourceCountFS.IsShown and frame.count.SetAlphaFromBoolean then                
                frame.count:SetAlphaFromBoolean(sourceCountFS:IsShown(), 1, 1)
            end
        end)
    else
        local suc, err = pcall(function() frame.count:SetText(C_Spell.GetSpellCharges(uniqueID).currentCharges) end)
    end
    if config.countText.display then
        frame.count:Show()
    else
        frame.count:Hide()
    end
end

function FrameTrackerManager:UpdateFrame_AuraEvent(uniqueID)
    local frame = SpellStyler_frames["buffs"][uniqueID]
    if not frame then
        return
    end
    local sourceFrame = cooldownManagerFrames["buffs"][uniqueID]
    local config = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, "buffs")
    local auraInstanceID = nil
    if sourceFrame then
        pcall(function()
            auraInstanceID = sourceFrame.auraInstanceID
        end)
    end
   
    if auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then       
        local success, err = pcall(function()
            if config.countText.display then
                frame.count:SetText(C_UnitAuras.GetAuraApplicationDisplayCount("player", auraInstanceID, 2))
            end
        end)
    elseif sourceFrame then
        FrameTrackerManager:UpdateFrame_copyCharges(uniqueID, 'buffs')
    end

    local isBuffShown = sourceFrame and sourceFrame:IsShown() or false
    if isBuffShown then
        if config.iconSettings.iconDisplayState == 'always' or config.iconSettings.iconDisplayState == 'active' or config.iconSettings.iconDisplayState == 'cooldown' then
            frame.Icon:Show()
        else
            frame.Icon:Hide()
        end
    else
        frame.count:SetText("")
        if config.iconSettings.iconDisplayState == 'always' or config.iconSettings.iconDisplayState == 'inactive' or config.iconSettings.iconDisplayState == 'available' then
            frame.Icon:Show()
        else
            frame.Icon:Hide()
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
        
        hooksecurefunc(viewer, "Layout", function()
            -- After Layout, scan icons and set up cooldown hooks
            --layout updates happen at unexpected times - even when changing forms on druid. This causes issues with the data bound to frames and cooldown tracking. Updating must happen manually if the user wants to see new or removed frames after updating the cooldown manager. 
            C_Timer.After(0, function()
                self:HookAllBuffCooldownFrames(trackerType)
                FrameTrackerManager:ApplyViewerVisibility(trackerType)
            end)
        end)

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
-- SPELL CHARGE TRACKING
-- ============================================================================
-- Overview:
--   Spells with charges (e.g. Charge, Roll, Ice Nova) have a special problem:
--   OnCooldownDone fires only when ALL charges finish recharging. If you cast
--   twice and the first charge comes back while the second is still recharging,
--   OnCooldownDone is never fired for that intermediate recharge. This section
--   handles detecting each individual charge recharge cycle.
--
-- Approach — anonymous "ghost" cooldown frames via AcquireChargeFrame:
--   When SetCooldown fires on the source Blizzard frame for a spell with charges,
--   and C_Spell.GetSpellChargeDuration returns a valid DurationObject, we create
--   (or reuse from pool) an invisible Cooldown frame and call
--   SetCooldownFromDurationObject on it with that duration. We never read the
--   start/duration args from SetCooldown (they are secret in combat). The
--   DurationObject is passed directly to the frame engine with no Lua-side
--   arithmetic, keeping it combat-safe. When that ghost frame's OnCooldownDone
--   fires, we know one recharge cycle just completed, so we increment the
--   available charge count and update the display.
--
--   Multiple ghost frames can exist simultaneously — one per recharge cycle in
--   flight. Each is fully independent: casting twice quickly creates two ghost
--   frames, each tracking its own recharge. Frames are never destroyed; they are
--   returned to the chargeTrackerPool and reused on the next cast.
--
-- Status bar vs. icon cooldown swipe:
--   The StatusBar uses SetTimerDuration (Midnight API) which accepts DurationObjects
--   directly and is NOT triggered by GCD entries, so it can safely show the per-
--   charge recharge progress. The icon's Cooldown frame (the swipe/sweep visual)
--   uses SetCooldown, which is hooked by the GCD and WILL fire on every GCD — this
--   means the swipe cannot reliably distinguish a real cast from a GCD tick, so
--   it may flash on every GCD while charges are recharging. The swipe is best
--   hidden (hideDefaultSweep=true) for charge-based spells, relying on the
--   StatusBar for recharge progress instead.
--
-- TODO: Add a per-tracker config toggle (e.g. iconSettings.ignoreChargesForCooldown)
--   When false (default, current behaviour): charge-aware mode. The icon and
--   statusBar show as available whenever at least one charge exists, and the ghost
--   frame approach drives per-recharge-cycle cooldown display.
--   When true (ignore charges): treat the spell exactly like a non-charge spell.
--   The charge count text still displays, but the cooldown swipe and statusBar only
--   activate when ALL charges are spent (i.e. spellHasCharges == false / the normal
--   SPELL_UPDATE_COOLDOWN → realCooldownActive path). This is useful for spells
--   where the user doesn't care about tracking individual recharge timers and just
--   wants a "it's on cooldown" indicator.
-- ============================================================================

local chargeTrackerPool = {}

local function AcquireChargeFrame(customFrame, durationObj, onDone)
    local f = table.remove(chargeTrackerPool) -- reuse if available
    if not f then
        f = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
        f:Hide()  -- invisible; only used for the timer callback
    end
    f:SetDrawEdge(false)
    f:SetDrawSwipe(false)
    f:SetDrawBling(false)
    f:SetHideCountdownNumbers(true)
    f:SetCooldownFromDurationObject(durationObj)
    f:SetScript("OnCooldownDone", function(self)
        self:SetScript("OnCooldownDone", nil)
        self:Clear()
        table.insert(chargeTrackerPool, self)  -- return to pool
        onDone()
    end)
    return f
end


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
            --cdm_frame:SetAlpha(0)
            
            -- Hook SetAlpha with recursion guard
            hooksecurefunc(cdm_frame, 'SetAlpha', function(self, alpha)
                if not self._spellStyler_settingAlpha and alpha ~= 0 then
                    self._spellStyler_settingAlpha = true
                    --self:SetAlpha(0)
                    self._spellStyler_settingAlpha = false
                end
            end)
            
            local function hookCallback(self)
                local uniqueID = self.spellStyler_spellID
                if uniqueID and SpellStyler_frames[trackerType][uniqueID] then
                    -- For buffs, track active state based on visibility
                    local isShown = false
                    pcall(function() 
                        isShown = self:IsShown()
                    end)
                    if trackerType == "buffs" then
                        SpellStyler_frames[trackerType][uniqueID].isBuffActive = isShown
                        local durationObj = nil
                        pcall(function()
                            durationObj = C_UnitAuras.GetAuraDuration("player", self:GetAuraSpellInstanceID())
                            if durationObj then
                                local spellInfo = C_Spell.GetSpellInfo(uniqueID)
                                local frame = SpellStyler_frames[trackerType][uniqueID]
                                frame.cooldown:SetCooldownFromDurationObject(durationObj)
                                local buffTimerCfg = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
                                local buffTimerDir = (buffTimerCfg and buffTimerCfg.statusBar and buffTimerCfg.statusBar.barFillDirection == 'inverse')
                                    and Enum.StatusBarTimerDirection.ElapsedTime
                                    or  Enum.StatusBarTimerDirection.RemainingTime
                                frame.statusBar:SetTimerDuration(
                                    durationObj,
                                    Enum.StatusBarInterpolation.ExponentialEaseOut,
                                    buffTimerDir
                                )
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
            if sourceCooldown and not cdm_frame.hasHookedCooldown then
                cdm_frame.hasHookedCooldown = true
                hooksecurefunc(sourceCooldown, "SetCooldown", function(self, start, duration)
                    local suc, err = pcall(function()
                        local uniqueID = self.spellStyler_spellID
                        local customFrame = SpellStyler_frames[trackerType][uniqueID]
                        if not customFrame then return end
                        local spellInfo = C_Spell.GetSpellInfo(uniqueID)
                        -- if not customFrame.isCooldownDataApplied then
                        local durationObj = nil
                        local wasSpellCharge = false
                        if customFrame.isSpellWithCharges and customFrame.trackIndividualChargeCooldown == true then
                            pcall(function()
                                local s, e = pcall(function() durationObj = C_Spell.GetSpellChargeDuration(uniqueID) end)
                                if durationObj then
                                    customFrame.realCooldownActive = true
                                    customFrame.cooldown:SetCooldown(start, duration) --SetCooldown is more accurate than trying to use durationObj for both. SetCooldown is also the only one with a callback that can be hooked into for when its done
                                    
                                    AcquireChargeFrame(customFrame, durationObj, function()
                                        if not customFrame.spellHasCharges then
                                            customFrame.spellHasCharges = true
                                        end
                                    end)
                                    if customFrame.statusBar and customFrame.statusBar.SetTimerDuration then
                                        local cdTimerCfg = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
                                        local cdTimerDir = (cdTimerCfg and cdTimerCfg.statusBar and cdTimerCfg.statusBar.barFillDirection == 'inverse')
                                            and Enum.StatusBarTimerDirection.ElapsedTime
                                            or  Enum.StatusBarTimerDirection.RemainingTime
                                        customFrame.statusBar:SetTimerDuration(
                                            durationObj,
                                            Enum.StatusBarInterpolation.Immediate,
                                            cdTimerDir
                                        )
                                    end
                                    FrameTrackerManager:UpdateFrame_RealCooldown(uniqueID, trackerType)
                                end
                            end)
                        end
                        if not customFrame.realCooldownActive and not customFrame.isSpellWithCharges then
                            local success, error = pcall(function()
                            -- customFrame.cooldown:SetCooldown(start, duration)
                                if trackerType == "buffs" then
                                    local succ, erro = pcall(function() durationObj = C_UnitAuras.GetAuraDuration("player", cdm_frame:GetAuraSpellInstanceID()) end)
                                else
                                    local s1, err2 = pcall(function() durationObj = C_Spell.GetSpellCooldownDuration(uniqueID) end)
                                end
                                if durationObj then
                                    customFrame.cooldown:SetCooldown(start, duration) --SetCooldown is more accurate than trying to use durationObj for both. SetCooldown is also the only one with a callback that can be hooked into for when its done
                                    if customFrame.statusBar and customFrame.statusBar.SetTimerDuration then
                                        local cdTimerCfg = FrameTrackerManager:GetSpecificTrackerValue(uniqueID, trackerType)
                                        local cdTimerDir = (cdTimerCfg and cdTimerCfg.statusBar and cdTimerCfg.statusBar.barFillDirection == 'inverse')
                                            and Enum.StatusBarTimerDirection.ElapsedTime
                                            or  Enum.StatusBarTimerDirection.RemainingTime
                                        customFrame.statusBar:SetTimerDuration(
                                            durationObj,
                                            Enum.StatusBarInterpolation.Immediate,
                                            cdTimerDir
                                        )
                                    end
                                end                                
                            end)
                            if success then
                                if trackerType == 'buffs' then
                                    --buffs dont have GCD for their applications so assume this is a valid duration for the buff
                                    customFrame.realCooldownActive = true
                                    FrameTrackerManager:UpdateFrame_RealCooldown(uniqueID, trackerType)
                                else
                                    --assume this is a GCD untill the "SPELL_UPDATE_COOLDOWN" confirms its a real cast. "real casts" also only happen when the last charge of a spell is cast, so the best we can do for now is copying the charges onto the custom frame
                                    FrameTrackerManager:UpdateFrame_IgnoreGCD(uniqueID, trackerType)
                                end
                            end
                        end
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

-- Event frame for UNIT_AURA and PLAYER_ENTERING_WORLD
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        hasPlayerEnetedWorld = true
        FrameTrackerManager:Initalize()
    end
    if event == "SPELL_UPDATE_COOLDOWN" then
        local spellID, baseSpellID, category, startRecoveryCategory = ...
        if not spellID then
            return
        end
        local spellInfo = C_Spell.GetSpellInfo(spellID)
        local baseSpellID = C_SpellBook.FindBaseSpellByID(spellID)
        -- Check if we're tracking this spell in any tracker type
        for _, trackerType in ipairs({"buffs", "essential", "utility"}) do
            local customFrame = SpellStyler_frames[trackerType][baseSpellID]
            if not customFrame then
                customFrame = SpellStyler_frames[trackerType][spellID]
            end
            if customFrame then
                local success, error = pcall(function()
                    local cooldownInfo = C_Spell.GetSpellCooldown(spellID)
                    if cooldownInfo.isOnGCD == false then
                        if (customFrame.isSpellWithCharges) then
                            customFrame.spellHasCharges = false
                        end
                        customFrame.realCooldownActive = true
                        FrameTrackerManager:UpdateFrame_RealCooldown(baseSpellID or spellID, trackerType)
                    end
                end)
                break
            end
        end
    end
end)


