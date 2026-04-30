-- ============================================================================
-- SpellStyler FrameTrackerManager.lua
-- Creates positionable highlight clones for tracker buffs
-- Detects active/inactive state via auraInstanceID (no secret value math)
-- ============================================================================

local addonName, SpellStyler = ...
SpellStyler.FrameTrackerManager = SpellStyler.FrameTrackerManager or {}
local FrameTrackerManager = SpellStyler.FrameTrackerManager
local State = SpellStyler.State

local FRAME_PREFIX = "TweaksUI_CustomFrameTracker_"

---@class TrackerFrameMeta
---@field activeSpellID number          The active spell ID (may differ from baseSpellID when a spec overrides the spell)
---@field isSpellWithCharges boolean    true if the spell has more than one max charge
---@field isDurationActive boolean      true while a real cooldown is running
---@field mockCooldownActive boolean    true while a mock cooldown preview is running (settings UI)
---@field currentAuraInstanceID number  Instance ID of the currently tracked aura (buffs tracker type)
---@field customTexture string|nil         Custom texture of the icon



--- @class FrameUpdateContext
--- @field frame table              The tracker frame (replaces data.customFrame)
--- @field config table             From State:GetSpecificTrackerValue
--- @field baseSpellID number
--- @field durationObject? table    Pre-resolved; skips C_Spell lookup in ACD when provided
--- @field forceUpdate? boolean     Clear cooldown/bar before applying


-- ============================================================================
-- STATE
-- ============================================================================
FrameTrackerManager.cooldownManagerFrames = {
    buffs = {}
}

-- Maps cooldownID (stable slot key from GetCooldownID) → baseSpellID (DB key).
-- Built once at scan time; used at runtime so callbacks never call GetSpellID(),
-- which returns a different value once a buff becomes active on that slot.
FrameTrackerManager.cooldownIDToBaseSpellID = {}

FrameTrackerManager.SpellStyler_frames = {
    buffs = {},
    spells = {},
}

-- Per-frame debounce queue for DriveFrameUpdate.
-- Keyed by frame table reference; each entry holds the merged flags, opts, and
-- a list of source strings collected during the current coalesce window.
FrameTrackerManager._driveQueue     = {}
FrameTrackerManager._totemLogQueue  = {}

-- updateFrame is defined in the UPDATE SYSTEM section
local isInitialized = false
------------------------------------------------------------------------
-- GlowUtil wiring helper
-- Reads glowNotification config and calls the appropriate GlowUtil.Setup*.
-- Chooses SetupProcGlow for glowStyle='thick', SetupAnts for everything else.
-- Safe to call when GlowUtil is not yet loaded (no-ops gracefully).
------------------------------------------------------------------------
local function ApplyGlowNotificationSetup(frame, trackerConfig)
    if not SpellStyler.GlowUtil then return end
    local gn = trackerConfig and trackerConfig.glowNotification
    if not gn then return end
    local gc = gn.glowColor or {}
    local cfg = {
        r          = gc.r or 1,
        g          = gc.g or 1,
        b          = gc.b or 1,
        scale      = 1.85,
        desaturated = false,
    }
    if gn.glowStyle == 'thick' then
        SpellStyler.GlowUtil:SetupProcGlow(frame, cfg)
    else
        SpellStyler.GlowUtil:SetupAnts(frame, cfg)
    end
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

function FrameTrackerManager:ScanAndSaveCurrentCooldownManagerFrames(trackerType)
    local viewer = SpellStyler.Containers:GetCooldownManagerViewer(trackerType)
    if not viewer or not viewer.itemFramePool then return end

    -- ── Step 1: Disable and hide all existing custom frames for this tracker type ──
    -- Mark every DB entry as disabled so entries not found in this scan stay hidden.
    -- Frames are destroyed now so CreateTrackerFrame can rebuild cleanly below.
    local existingTrackers = State:GetAllTrackerValues(trackerType)
    if existingTrackers then
        for spellID, trackerValue in pairs(existingTrackers) do
            trackerValue.isEnabled = false
            local frame = FrameTrackerManager.SpellStyler_frames[trackerType][spellID]
            if frame then
                frame:Hide()
                frame:ClearAllPoints()
                FrameTrackerManager.SpellStyler_frames[trackerType][spellID] = nil
            end
        end
    end

    -- Wipe the CDM lookup so it only reflects what is active right now.
    FrameTrackerManager.cooldownManagerFrames[trackerType] = {}
    wipe(FrameTrackerManager.cooldownIDToBaseSpellID)

    
    -- ── Step 2: Enumerate only the currently active pool frames ──
    for cdmFrame in viewer.itemFramePool:EnumerateActive() do
        local spellID = nil
        pcall(function() spellID = cdmFrame:GetSpellID() end)
        -- Grab the stable slot identifier while GetSpellID() still returns the
        -- base value (before any buff activates and mutates it).
        local cooldownID = nil
        pcall(function() cooldownID = cdmFrame:GetCooldownID() end)
        if spellID and not issecretvalue(spellID) then
            -- Bake the stable slot ID onto the frame and into the lookup table so runtime
            -- hook callbacks can resolve the correct baseSpellID without calling GetSpellID().
            if cooldownID then
                FrameTrackerManager.cooldownIDToBaseSpellID[cooldownID] = spellID
            end
            -- Resolve texture from the live icon child; fall back to spell data.
            -- Nothing is written back onto cdmFrame itself.
            local icon = cdmFrame.Icon or cdmFrame.icon
            local spellData = C_Spell.GetSpellInfo(spellID) or {}
            local texture = (icon and icon.GetTexture and icon:GetTexture())
                or spellData.iconID

            -- Keep our own lookup table populated for HookAllBuffCooldownFrames.
            FrameTrackerManager.cooldownManagerFrames[trackerType][spellID] = cdmFrame

            -- ── Step 3: State entry ──
            if State:CheckIsAlreadyTracker(spellID, trackerType) then
                -- Re-enable the existing entry and refresh the default texture.
                -- SetTrackerValueConfigProperty guards on frame existence, so these
                -- calls are safe even though no custom frame exists yet.
                State:SetTrackerValueConfigProperty(spellID, trackerType, 'isEnabled', true)
                State:SetTrackerValueConfigProperty(spellID, trackerType, 'defaultIconTexturePath', texture)
            else
                State:AddTrackerValue({
                    baseSpellID = spellID,
                    overrideSpellID = C_Spell.GetOverrideSpell(spellID),
                    defaultIconTexturePath = texture,
                    name = spellData.name,
                    trackerType = trackerType
                })
            end

            -- ── Step 4: Create the custom SpellStyler frame ──
            local trackerConfig = State:GetSpecificTrackerValue(spellID, trackerType)
            if trackerConfig then
                -- Wipe devNotes before creating frame (fresh start for error tracking)
                State:SetTrackerValueConfigProperty(spellID, trackerType, "devNotes", {})
                FrameTrackerManager:CreateTrackerFrame(spellID, trackerConfig, trackerType)
            end
        end
    end

    -- Apply any saved viewer visibility setting
    SpellStyler.Containers:ApplyViewerVisibility("buffs")
    SpellStyler.Containers:ApplyViewerVisibility("essential")
    SpellStyler.Containers:ApplyViewerVisibility("utility")
end



--- Loops over every non-buffs tracker type in the database and ensures a live
--- tracker frame exists for each entry.  Safe to call multiple times; 
--- CreateTrackerFrame is a no-op when the frame already exists.
function FrameTrackerManager:CreateNonBuffTrackerFrames()
    for _, trackerType in ipairs({ "spells" }) do
        local trackerValues = State:GetAllTrackerValues(trackerType)
        if trackerValues then
            for baseSpellID, trackerConfig in pairs(trackerValues) do
                -- Skip orphan entries: real entries always have trackerType set by AddTrackerValue.
                if not FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                    and trackerConfig.trackerType ~= nil
                    and trackerConfig.isEnabled ~= false
                    and (C_SpellBook.IsSpellKnown(baseSpellID) or C_SpellBook.IsSpellKnown(trackerConfig.overrideSpellID))
                then
                    -- Wipe devNotes before creating frame (fresh start for error tracking)
                    State:SetTrackerValueConfigProperty(baseSpellID, trackerType, "devNotes", {})
                    FrameTrackerManager:CreateTrackerFrame(baseSpellID, trackerConfig, trackerType)
                end
            end
        end
    end
end

--- Creates a StatusBar on `frame`, assigned to `frame[key]`.
--- @param frame table         The tracker frame to attach the status bar to
--- @param key string          The field name on `frame` where the bar will be stored (e.g. "statusBar")
--- @param trackerConfig table Tracker configuration block
--- @param baseSpellID number  Base spell ID (used for SetStatusBarContainerVisibility)
--- @param trackerType string  Tracker type (used for SetStatusBarContainerVisibility)
function FrameTrackerManager:CreateStatusBar(frame, key, trackerConfig, baseSpellID, trackerType, x, y, useBaseTexture)
    local statusBarName = frame:GetName() .. "_" .. key
    frame[key] = CreateFrame("StatusBar", statusBarName, frame)
    frame[key]:SetPoint(trackerConfig.statusBar.anchorSelf or "LEFT", frame, trackerConfig.statusBar.anchorParent or "RIGHT", x or trackerConfig.statusBar.x or 0, y or trackerConfig.statusBar.y or 0)
    local _iconW = trackerConfig.iconSettings.width or trackerConfig.iconSettings.size or 48
    local _iconH = trackerConfig.iconSettings.height or trackerConfig.iconSettings.size or 48
    local statusBarWidth = trackerConfig.statusBar and trackerConfig.statusBar.width or (_iconW * 4)
    local statusBarHeight = trackerConfig.statusBar and trackerConfig.statusBar.height or (_iconH / 2)

    local onlyBarOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.onlyRenderBar")
    local onlyBar = (onlyBarOverride ~= nil) and onlyBarOverride or (trackerConfig.statusBar.onlyRenderBar or false)
    local forceHideViaAlpha = onlyBar or trackerConfig.statusBar.displayState == 'never'
    frame[key]:SetSize(statusBarWidth, statusBarHeight)
    frame[key]:SetScale(trackerConfig.statusBar.scale or 1)
    frame[key]:SetMinMaxValues(0, 1)
    frame[key]:SetValue(0)
    frame[key]:SetFrameLevel(frame:GetFrameLevel() + 3)  -- Base level for status bar
    frame[key]:SetStatusBarColor(
        trackerConfig.statusBar.color.r or 0.2,
        trackerConfig.statusBar.color.g or 0.8,
        trackerConfig.statusBar.color.b or 1,
        0 -- start with an alpha of zero so that GCD doesnt trigger accidentally.
    )
    local statusBarTexture = frame[key]:GetStatusBarTexture()
    if statusBarTexture then
        statusBarTexture:SetDrawLayer("ARTWORK", 0)
    end
    -- Layer 1: Background (darkened fill texture) - BACKGROUND layer, sublayer 0
    -- Parented to main frame (not statusBar) so it renders behind the statusBar frame itself
    frame[key].bgTexture = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
    frame[key].bgTexture:SetAllPoints(frame[key])
    frame[key].bgTexture:Show()  -- Start visible; ApplyVisibility.StatusBar controls actual visibility
    local texture = ""
    if trackerConfig.statusBar.customBarTexture ~= '' and not useBaseTexture then
        texture = trackerConfig.statusBar.customBarTexture
    else
        texture = trackerConfig.statusBar.defaultBarTexture
    end
    frame[key].bgTexture:SetTexture(texture)
    frame[key].bgTexture:SetVertexColor(
        trackerConfig.statusBar.backgroundColor.r,
        trackerConfig.statusBar.backgroundColor.g,
        trackerConfig.statusBar.backgroundColor.b,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.backgroundColor.a
    )  -- Darkened background

    -- Layer 2: Main Fill (active progress) - ARTWORK layer (sublayer 0, above BACKGROUND)
    local barTexture = (trackerConfig.statusBar.customBarTexture and trackerConfig.statusBar.customBarTexture ~= "")
        and trackerConfig.statusBar.customBarTexture
        or trackerConfig.statusBar.defaultBarTexture
    frame[key]:SetStatusBarTexture(barTexture)
    
    
    -- Fill direction is controlled via TimerDirection in SetTimerDuration (ElapsedTime = fills up, RemainingTime = depletes)
    frame[key]:SetReverseFill(false)
    frame[key]:SetOrientation(
        (trackerConfig.statusBar.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL"
    )

    -- Layer 2.5: Full-cover texture (ARTWORK sublayer 1, above the fill at sublayer 0).
    -- Used when defaultFillValue='full' to visually fill the bar without fighting SetTimerDuration.
    -- Shown by UpdateFrame_Duration _Inactive when isFull, hidden when a real cooldown is active.
    frame[key].fullCoverTexture = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    frame[key].fullCoverTexture:SetAllPoints(frame[key])
    frame[key].fullCoverTexture:SetTexture(barTexture)
    frame[key].fullCoverTexture:SetVertexColor(
        trackerConfig.statusBar.color.r or 0.2,
        trackerConfig.statusBar.color.g or 0.8,
        trackerConfig.statusBar.color.b or 1,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.color.a or 0.9
    )
    frame[key].fullCoverTexture:Show()  -- Start visible; alpha controls actual visibility

    -- Layer 3: Glow overlay - OVERLAY layer
    frame[key].glowTexture = frame[key]:CreateTexture(nil, "OVERLAY")
    frame[key].glowTexture:SetPoint("TOPLEFT", frame[key], "TOPLEFT", 0, 0)
    frame[key].glowTexture:SetPoint("BOTTOMRIGHT", frame[key], "BOTTOMRIGHT", 0, 0)
    frame[key].glowTexture:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarGlow.tga")
    frame[key].glowTexture:SetBlendMode("ADD")
    frame[key].glowTexture:SetVertexColor(
        trackerConfig.statusBar.glowColor.r or 1,
        trackerConfig.statusBar.glowColor.g or 1,
        trackerConfig.statusBar.glowColor.b or 1,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.glowColor.a or 0.25
    )  -- Semi-transparent glow
    frame[key].glowTexture:SetDrawLayer("OVERLAY", 7)

    -- Layer 4: Border frame - above overlay (8 pieces: 4 corners + 4 edges)
    frame[key].border = CreateFrame("Frame", nil, frame[key])
    frame[key].border:SetAllPoints(frame[key])
    frame[key].border:SetFrameLevel(frame[key]:GetFrameLevel() + 10)

    local cornerSize = 8
    local edgeThickness = 8

    -- Top-left corner
    frame[key].borderCornerTL = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerTL:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerTL:SetPoint("TOPLEFT", frame[key].border, "TOPLEFT", -1.5, 1.5)
    frame[key].borderCornerTL:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerTL:SetRotation(0)
    frame[key].borderCornerTL:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.borderColor.a or 1
    )
    frame[key].borderCornerTL:SetScale(trackerConfig.statusBar.borderScale or 1)

    -- Top-right corner (rotated 270°)
    frame[key].borderCornerTR = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerTR:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerTR:SetPoint("TOPRIGHT", frame[key].border, "TOPRIGHT", 1.5, 1.5)
    frame[key].borderCornerTR:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerTR:SetRotation(3 * math.pi / 2)
    frame[key].borderCornerTR:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.borderColor.a or 1
    )
    frame[key].borderCornerTR:SetScale(trackerConfig.statusBar.borderScale or 1)

    -- Bottom-right corner (rotated 180°)
    frame[key].borderCornerBR = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerBR:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerBR:SetPoint("BOTTOMRIGHT", frame[key].border, "BOTTOMRIGHT", 1.5, -1.5)
    frame[key].borderCornerBR:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerBR:SetRotation(math.pi)
    frame[key].borderCornerBR:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.borderColor.a or 1
    )
    frame[key].borderCornerBR:SetScale(trackerConfig.statusBar.borderScale or 1)

    -- Bottom-left corner (rotated 90°)
    frame[key].borderCornerBL = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerBL:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerBL:SetPoint("BOTTOMLEFT", frame[key].border, "BOTTOMLEFT", -1.5, -1.5)
    frame[key].borderCornerBL:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerBL:SetRotation(math.pi / 2)
    frame[key].borderCornerBL:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.borderColor.a or 1
    )
    frame[key].borderCornerBL:SetScale(trackerConfig.statusBar.borderScale or 1)

    -- Top edge
    frame[key].borderEdgeTop = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderEdgeTop:SetHeight(edgeThickness)
    frame[key].borderEdgeTop:SetPoint("TOPLEFT", frame[key].borderCornerTL, "TOPRIGHT", 0, 0)
    frame[key].borderEdgeTop:SetPoint("TOPRIGHT", frame[key].borderCornerTR, "TOPLEFT", 0, 0)
    frame[key].borderEdgeTop:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line.tga")
    frame[key].borderEdgeTop:SetRotation(0)
    frame[key].borderEdgeTop:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.borderColor.a or 1
    )
    frame[key].borderEdgeTop:SetScale(trackerConfig.statusBar.borderScale or 1)

    -- Right edge (vertical)
    frame[key].borderEdgeRight = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderEdgeRight:SetWidth(edgeThickness)
    frame[key].borderEdgeRight:SetPoint("TOPRIGHT", frame[key].borderCornerTR, "BOTTOMRIGHT", 0, 0)
    frame[key].borderEdgeRight:SetPoint("BOTTOMRIGHT", frame[key].borderCornerBR, "TOPRIGHT", 0, 0)
    frame[key].borderEdgeRight:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line_vertical.tga")
    frame[key].borderEdgeRight:SetRotation(math.pi)
    frame[key].borderEdgeRight:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.borderColor.a or 1
    )
    frame[key].borderEdgeRight:SetScale(trackerConfig.statusBar.borderScale or 1)

    -- Bottom edge (rotated 180°)
    frame[key].borderEdgeBottom = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderEdgeBottom:SetHeight(edgeThickness)
    frame[key].borderEdgeBottom:SetPoint("BOTTOMRIGHT", frame[key].borderCornerBR, "BOTTOMLEFT", 0, 0)
    frame[key].borderEdgeBottom:SetPoint("BOTTOMLEFT", frame[key].borderCornerBL, "BOTTOMRIGHT", 0, 0)
    frame[key].borderEdgeBottom:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line.tga")
    frame[key].borderEdgeBottom:SetRotation(math.pi)
    frame[key].borderEdgeBottom:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.borderColor.a or 1
    )
    frame[key].borderEdgeBottom:SetScale(trackerConfig.statusBar.borderScale or 1)

    -- Left edge (vertical)
    frame[key].borderEdgeLeft = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderEdgeLeft:SetWidth(edgeThickness)
    frame[key].borderEdgeLeft:SetPoint("BOTTOMLEFT", frame[key].borderCornerBL, "TOPLEFT", 0, 0)
    frame[key].borderEdgeLeft:SetPoint("TOPLEFT", frame[key].borderCornerTL, "BOTTOMLEFT", 0, 0)
    frame[key].borderEdgeLeft:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line_vertical.tga")
    frame[key].borderEdgeLeft:SetRotation(0)
    frame[key].borderEdgeLeft:SetVertexColor(
        trackerConfig.statusBar.borderColor.r or 0,
        trackerConfig.statusBar.borderColor.g or 0,
        trackerConfig.statusBar.borderColor.b or 0,
        forceHideViaAlpha and 0 or trackerConfig.statusBar.borderColor.a or 1
    )
    frame[key].borderEdgeLeft:SetScale(trackerConfig.statusBar.borderScale or 1)

    -- Show statusBar frame once at creation; visibility controlled by alpha thereafter
    frame[key]:Show()
    -- Initial visibility is controlled by ApplyVisibility.StatusBar during the first DriveFrameUpdate
end

--- Creates a charge-based display bar that positions the icon on/off screen based on spell charges.
--- The bar is sized from the icon position to off-screen, and by setting its value to the current
--- charge count, the icon (anchored to the bar) moves to visible or hidden positions.
--- @param frame table The tracker frame to attach the bar to
--- @param trackerConfig table Tracker configuration block
--- @param baseSpellID number Base spell ID
function FrameTrackerManager:CreateChargeBasedDisplayBar(frame, trackerConfig, baseSpellID)
    local cbdConfig = trackerConfig.chargeBasedDisplay
    if not cbdConfig or not cbdConfig.enabled then return end
    
    -- Calculate threshold values based on mode and operator
    -- Normalize all combinations to "show when >= threshold" form
    local mode = cbdConfig.displayState and "show" or "hide"  -- "show" or "hide"
    local operator = cbdConfig.displayOperator or ">="  -- ">=", ">", "<", "<="
    local value = cbdConfig.chargeValue or 1
    
    local low
    local high
    if operator == "<" or operator == ">=" then
        high = value
        low = value - 1
    elseif operator == "<=" or operator == ">" then
        high = value + 1
        low = value
    end

    
    
    -- Create the invisible status bar
    frame.chargeAnchorBar = CreateFrame("StatusBar", "ChargeAnchorBar_" .. baseSpellID, frame, "BackdropTemplate")
    
    local barTexture = (trackerConfig.statusBar.customBarTexture and trackerConfig.statusBar.customBarTexture ~= "")
        and trackerConfig.statusBar.customBarTexture
        or trackerConfig.statusBar.defaultBarTexture
    frame.chargeAnchorBar:SetStatusBarTexture(barTexture)

    local anchorHeight = UIParent:GetHeight() * 2
    
    frame.chargeAnchorBar:SetMinMaxValues(low, high)
    frame.chargeAnchorBar:SetValue(low)  -- Start at max (visible)
    frame.chargeAnchorBar:SetSize(10, anchorHeight)
    frame.chargeAnchorBar:SetOrientation("VERTICAL")  -- Fill vertically, not horizontally
    
    -- Make the bar invisible but functional
    frame.chargeAnchorBar:SetStatusBarColor(1, 1, 1, 0)
    frame.chargeAnchorBar:SetAlpha(0)
    
    frame.chargeAnchorBar:Show()
    frame.chargeAnchorBar:ClearAllPoints()
    
    -- Use BOTTOM anchor point when flipped, TOP when normal
    local barAnchorPoint = "TOP"
    local greater = (operator ~= '<' and operator ~= '<=')
    local lesser = (operator ~= '>' and operator ~= '>=')
    if (mode == 'show' and greater) or (mode == 'hide' and lesser) then
        barAnchorPoint = "TOP"
    elseif (mode == 'show' and lesser) or (mode == 'hide' and greater) then
        barAnchorPoint = "BOTTOM"
    end
    frame.chargeAnchorBar:SetPoint(
        barAnchorPoint,
        UIParent,
        trackerConfig.position.relativeAnchorPoint or trackerConfig.position.anchorPoint,
        trackerConfig.position.x or 0,
        trackerConfig.position.y or 0
    )
    
    -- Store the config for later reference
    frame.chargeAnchorBar._config = {
        mode = mode,
        operator = operator,
        anchorPoint = barAnchorPoint
    }
end

function FrameTrackerManager:CreateTrackerFrame(baseSpellID, trackerConfig, trackerType)
    if FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] then
        return FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    end
    local frameName = FRAME_PREFIX .. baseSpellID
    --[[
        upon creating the frame, it starts with the overrideSpellID. "meta.activeSpellID" could update even further - for example:
            base = divine toll
            override = sacred weapons
            override again = holy bulwark
    ]]
    local spellChargesInfo = C_Spell.GetSpellCharges(trackerConfig.overrideSpellID or baseSpellID)
    local spellInfo = C_Spell.GetSpellInfo(trackerConfig.overrideSpellID  or baseSpellID)
    local frame = CreateFrame("Button", frameName, UIParent, "BackdropTemplate")
    FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] = frame
    -- Only set the icon's own size when it is not managed by a container.
    -- LayoutContainer resizes and positions frames that are _inContainer.
    if not frame._inContainer then
        local iconW = trackerConfig.iconSettings.width or trackerConfig.iconSettings.size or 48
        local iconH = trackerConfig.iconSettings.height or trackerConfig.iconSettings.size or 48
        frame:SetSize(iconW, iconH)
    end
    frame:SetFrameStrata(trackerConfig.iconSettings.frameStrataLevel or "MEDIUM")
    frame:SetFrameLevel(trackerConfig.iconSettings.frameStrataValue or 100)

    C_Spell.RequestLoadSpellData(trackerConfig.overrideSpellID or baseSpellID)
    ---@type TrackerFrameMeta
    frame.meta = {
        spellName = spellInfo.name,
        baseSpellID = baseSpellID,
        trackerType = trackerType,
        buffStatus = 'absent',
        isTotem = trackerConfig.iconSettings.isTotem,
        -- This is either the baseSpellID or the override spell id (if it changes into something). Use this value when getting cooldown duration objects.
        activeSpellID = trackerConfig.overrideSpellID or baseSpellID,
        -- This helps in conjunction with spellChargeState || spellChargeCount (spellHasCharges) to control the visibility state for count
        isSpellWithCharges = spellChargesInfo and spellChargesInfo.maxCharges > 1,
        -- Used to track if the cooldown is active, so that the cooldowns can be updated in response to other spell casts (Holy Shock can reduce the cooldown of judgment)
        isDurationActive = false,
        mockCooldownActive = false,
        -- instance ID of the currently tracked aura (buffs only)
        currentAuraInstanceID = 0,
        customTexture = trackerConfig.iconSettings.iconTexturePath ~= '' and trackerConfig.iconSettings.iconTexturePath ~= nil and trackerConfig.iconSettings.iconTexturePath or nil
    }
    
    -- Make frame movable for Layout mode
    frame:SetMovable(true)
    --     frame:SetClampedToScreen(false)

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
    local zoom = trackerConfig.iconSettings.zoom and (trackerConfig.iconSettings.zoom / 100) or 0
    frame.icon:SetTexCoord(0 + zoom, 1 - zoom, 0 + zoom, 1 - zoom)
    local iconTexture = frame.meta.customTexture or trackerConfig.defaultIconTexturePath
    frame.icon:SetTexture(iconTexture)
    local _, insufficientPower = C_Spell.IsSpellUsable(frame.meta.activeSpellID)
    local color = (insufficientPower and trackerConfig.iconSettings.insufficientPower and trackerConfig.iconSettings.insufficientPowerIconColor)
        or trackerConfig.iconColor or {}
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
    frame.cooldown:SetHideCountdownNumbers(false)
    frame.cooldown:SetScript("OnShow", function(self)
        frame.meta.isDurationActive = true
    end)

    frame.cooldown:SetScript("OnHide", function(self)
    end)
    

    frame.cooldown:SetScript("OnCooldownDone", function(self)
        frame.meta.isDurationActive = false
        if trackerConfig.glowNotification.shouldDisplay then
            if trackerConfig.glowNotification.glowStyle == 'thick' then
                SpellStyler.GlowUtil:PlayProcGlow(frame, trackerConfig.glowNotification.duration)
            else
                SpellStyler.GlowUtil:PlayAnts(frame, trackerConfig.glowNotification.duration)
            end
        end
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
        
        FrameTrackerManager:DriveFrameUpdate(
            frame,
            {
                resolveDuration = false, --trackerType ~= 'buffs' and true or false,
                syncChargeText = true
            },
            nil,
            "onCooldownDone"
        )
    end)
    
    FrameTrackerManager:CreateStatusBar(frame, "statusBar", trackerConfig, baseSpellID, trackerType)

    -- Create charge-based display bar if enabled
    FrameTrackerManager:CreateChargeBasedDisplayBar(frame, trackerConfig, baseSpellID)

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
    if frame.chargeAnchorBar then
        -- Anchor to charge-based display bar's moving edge
        -- Use the bar's anchor point (TOP for normal, BOTTOM for flipped)
        local barConfig = frame.chargeAnchorBar._config
        -- local textureAnchor = barConfig and barConfig.anchorPoint or "TOP"
        local barAnchorPoint = barConfig and barConfig.needsFlip and "BOTTOM" or "TOP"
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", frame.chargeAnchorBar:GetStatusBarTexture(), barAnchorPoint, 0, 0)
    elseif pos and pos.anchorPoint and pos.x and pos.y then
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

    -- Initially hidden
    frame:Show()

    FrameTrackerManager:DriveFrameUpdate(
        frame,
        {
            resolveDuration = true,
            syncChargeText = true
        },
        nil,
        "createTrackerFrame"
    )

    -- If the "Replace with Spell Display Count" setting is on, start a ticker
    -- that reads the action-bar display count and writes it into frame.count.
    -- This bypasses renderUpdateChargesText and ApplyVisibility.Charges (see _ExecuteDrive).
    if trackerConfig.countText and trackerConfig.countText.useSpellDisplayCount then
        local spellID = frame.meta.activeSpellID
        local statusBarName = 'countStatusBar' .. baseSpellID
        frame.count:SetAlpha(1)
        frame.count:Show()
        frame._displayCountTicker = C_Timer.NewTicker(0.05, function()
            local ab = C_ActionBar.FindSpellActionButtons(spellID)
            if ab and ab[1] then
                local value = C_ActionBar.GetActionDisplayCount(ab[1])
                frame.count:SetText(value)
            else
                frame.count:SetText("")
            end
        end)
    end
    -- Attach the glow animation child based on the current glowNotification config.
    -- PlayAnts / PlayProcGlow are intentionally NOT called here; the caller decides
    -- when to trigger the animation.
    ApplyGlowNotificationSetup(frame, trackerConfig)

    return frame
end

function FrameTrackerManager:UpdateFrame_ConfigurationChanges(baseSpellID, trackerType)
    local trackerConfig = State:GetSpecificTrackerValue(baseSpellID, trackerType)
    local frame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    
    -- Update icon texture: check override first, then state
    local iconTexOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "iconSettings.iconTexturePath")
    local customTexture = iconTexOverride or (trackerConfig.iconSettings.iconTexturePath ~= "" and trackerConfig.iconSettings.iconTexturePath)
    local texture = customTexture or frame.updatedIconID or trackerConfig.defaultIconTexturePath
    frame.icon:SetTexture(texture)
    local zoom = trackerConfig.iconSettings.zoom and (trackerConfig.iconSettings.zoom / 100) or 0
    frame.icon:SetTexCoord(0 + zoom, 1 - zoom, 0 + zoom, 1 - zoom)
    
 
    -- Update size (skip when the frame is managed by a container; LayoutContainer controls its size)
    if not frame._inContainer then
        local widthOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "iconSettings.width")
        local heightOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "iconSettings.height")
        local iconW = widthOverride or trackerConfig.iconSettings.width or trackerConfig.iconSettings.size or 48
        local iconH = heightOverride or trackerConfig.iconSettings.height or trackerConfig.iconSettings.size or 48
        frame:SetSize(iconW, iconH)
    end

    -- Re-attach the glow animation child with the latest glowNotification config.
    -- This reconstructs the glow child (colour, style, scale) without starting it.
    ApplyGlowNotificationSetup(frame, trackerConfig)

    -- Update opacity: check override first, then state
    -- NOTE: Commented out to avoid conflicts with visibility alpha control in _ExecuteDrive
    -- local opacityOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "iconSettings.opacity")
    -- frame:SetAlpha(opacityOverride or trackerConfig.iconSettings.opacity or 1)

    -- Update frame strata and level
    frame:SetFrameStrata(trackerConfig.iconSettings.frameStrataLevel or "MEDIUM")
    frame:SetFrameLevel(trackerConfig.iconSettings.frameStrataValue or 100)
        
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
            -- Apply font size: check override first, then state
            local sizeOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "cooldownText.size")
            local fontSize = sizeOverride or trackerConfig.cooldownText.size
            local fontPath, _, fontFlags = cdText:GetFont()
            if fontPath and fontSize then
                cdText:SetFont(fontPath, fontSize, fontFlags or "OUTLINE")
            end
            
            -- NOTE: Color moved to ApplyVisibility.CooldownText to handle alpha properly
            
            -- Apply offset: check override first, then state
            local xOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "cooldownText.x")
            local yOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "cooldownText.y")
            cdText:ClearAllPoints()
            cdText:SetPoint("CENTER", frame.cooldown, "CENTER", 
                xOverride or trackerConfig.cooldownText.x or 0, 
                yOverride or trackerConfig.cooldownText.y or 0)
        end)
    end

    -- Manage the Spell Display Count ticker: cancel any existing one, then
    -- start a fresh one if the setting is currently enabled.
    if frame._displayCountTicker then
        frame._displayCountTicker:Cancel()
        frame._displayCountTicker = nil
    end
    if trackerConfig.countText and trackerConfig.countText.useSpellDisplayCount then
        local spellID = frame.meta.activeSpellID
        frame.count:SetAlpha(1)
        frame.count:Show()
        frame._displayCountTicker = C_Timer.NewTicker(0.05, function()
            local ab = C_ActionBar.FindSpellActionButtons(spellID)
            if ab and ab[1] then
                local value = C_ActionBar.GetActionDisplayCount(ab[1])
                frame.count:SetText(value)
            else
                frame.count:SetText("")
            end
        end)
    end

    -- Update custom label
    if frame.customLabel and trackerConfig.customLabel then
        pcall(function()
            -- Set visibility and text: check override first, then state
            local textOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "customLabel.text")
            local labelText = textOverride or trackerConfig.customLabel.text
            
            -- If there's a conditional override with text, force show regardless of display setting
            if textOverride and textOverride ~= "" then
                frame.customLabel:SetText(textOverride)
                frame.customLabel:Show()
            elseif trackerConfig.customLabel.display and labelText and labelText ~= "" then
                frame.customLabel:SetText(labelText)
                frame.customLabel:Show()
            else
                frame.customLabel:Hide()
            end
            
            -- Apply font size: check override first, then state
            local sizeOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "customLabel.size")
            local fontSize = sizeOverride or trackerConfig.customLabel.size
            if fontSize then
                frame.customLabel:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
            end
            
            -- Apply color: check override first, then state
            local colorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "customLabel.color")
            local color = colorOverride or trackerConfig.customLabel.color
            if color then
                frame.customLabel:SetTextColor(
                    color.r or 1,
                    color.g or 1,
                    color.b or 1,
                    color.a or 1
                )
            end
            
            -- Apply offset: check override first, then state
            local xOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "customLabel.x")
            local yOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "customLabel.y")
            frame.customLabel:ClearAllPoints()
            frame.customLabel:SetPoint("CENTER", frame, "CENTER", 
                xOverride or trackerConfig.customLabel.x or 0, 
                yOverride or trackerConfig.customLabel.y or 0)
        end)
    end
    
    -- Update status bar styling
    if frame.statusBar and trackerConfig.statusBar then
        pcall(function()
            -- Apply size: check override first, then state
            local widthOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.width")
            local heightOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.height")
            local width = widthOverride or trackerConfig.statusBar.width or 200
            local height = heightOverride or trackerConfig.statusBar.height or 20
            frame.statusBar:SetSize(width, height)
            
            -- Apply scale: check override first, then state
            local scaleOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.scale")
            frame.statusBar:SetScale(scaleOverride or trackerConfig.statusBar.scale or 1)
            frame.statusBar.bgTexture:SetScale(scaleOverride or trackerConfig.statusBar.scale or 1)

            -- Apply position/anchoring: check override first, then state
            local xOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.x")
            local yOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.y")
            local anchorSelfOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.anchorSelf")
            local anchorParentOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.anchorParent")
            frame.statusBar:ClearAllPoints()
            frame.statusBar:SetPoint(
                anchorSelfOverride or trackerConfig.statusBar.anchorSelf or "LEFT",
                frame,
                anchorParentOverride or trackerConfig.statusBar.anchorParent or "RIGHT",
                xOverride or trackerConfig.statusBar.x or 0,
                yOverride or trackerConfig.statusBar.y or 0
            )

            -- Apply bar texture: check override first, then state (custom overrides default)
            local textureOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.customBarTexture")
            local barTexture = textureOverride
                or (trackerConfig.statusBar.customBarTexture and trackerConfig.statusBar.customBarTexture ~= "" and trackerConfig.statusBar.customBarTexture)
                or trackerConfig.statusBar.defaultBarTexture
            if barTexture then
                frame.statusBar:SetStatusBarTexture(barTexture)
                -- Explicitly set draw layer to ensure proper layering (above background)
                local statusBarTexture = frame.statusBar:GetStatusBarTexture()
                if statusBarTexture then
                    statusBarTexture:SetDrawLayer("ARTWORK", 0)
                end
                -- Keep the full-cover texture in sync with the bar texture
                if frame.statusBar.fullCoverTexture then
                    frame.statusBar.fullCoverTexture:SetTexture(barTexture)
                end
                -- Update background texture too
                if frame.statusBar.bgTexture then
                    frame.statusBar.bgTexture:SetTexture(barTexture)
                end
            end
            
            -- Apply fill color: check override first, then state
            -- Note: Alpha is handled separately by ApplyVisibility.StatusBar
            -- local colorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.color")
            -- local c = colorOverride or trackerConfig.statusBar.color
            -- local r, g, b = c.r or 0.2, c.g or 0.8, c.b or 1
            -- local currentR, currentG, currentB, currentA = frame.statusBar:GetStatusBarColor()
            -- frame.statusBar:SetStatusBarColor(r, g, b, currentA or 0)

            -- Apply orientation
            frame.statusBar:SetOrientation(
                (trackerConfig.statusBar.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL"
            )

            -- Apply fillOrEmpty: 'regular' = normal fill, 'inverse' = SetReverseFill
            local shouldReverse = trackerConfig.statusBar.fillOrEmpty == 'inverse'
            frame.statusBar:SetReverseFill(shouldReverse)

            -- Apply fill style (progressDirection) immediately so a settings change is reflected live
            local fillStyle = (trackerConfig and trackerConfig.statusBar and trackerConfig.statusBar.progressDirection == 'reverse')
            frame.statusBar:SetFillStyle(fillStyle and Enum.StatusBarFillStyle.Reverse or Enum.StatusBarFillStyle.Standard)

            -- Apply rotation: check override first, then state
            local rotationOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.rotation")
            local rotation = rotationOverride or trackerConfig.statusBar.rotation
            if rotation then
                frame.statusBar:SetRotation(math.rad(rotation))
            end
        end)
        -- Called outside pcall so a pcall error can't prevent it from running
        
        local onlyBarOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.onlyRenderBar")
        local onlyBar = (onlyBarOverride ~= nil) and onlyBarOverride or (trackerConfig.statusBar.onlyRenderBar or false)
        if onlyBar or trackerConfig.statusBar.displayState == 'never' then
            frame.statusBar.borderCornerTL:SetVertexColor(0,0,0,0)
            frame.statusBar.borderCornerTR:SetVertexColor(0,0,0,0)
            frame.statusBar.borderCornerBR:SetVertexColor(0,0,0,0)
            frame.statusBar.borderCornerBL:SetVertexColor(0,0,0,0)
            frame.statusBar.borderEdgeTop:SetVertexColor(0,0,0,0)
            frame.statusBar.borderEdgeRight:SetVertexColor(0,0,0,0)
            frame.statusBar.borderEdgeBottom:SetVertexColor(0,0,0,0)
            frame.statusBar.borderEdgeLeft:SetVertexColor(0,0,0,0)
            frame.statusBar.bgTexture:SetVertexColor(0,0,0,0)
            frame.statusBar.glowTexture:SetVertexColor(0,0,0,0)
        elseif trackerConfig.statusBar.displayState == 'always' then
            local borderColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.borderColor")
            local borderColor = borderColorOverride or trackerConfig.statusBar.borderColor
            local backgroundColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.backgroundColor")
            local backgroundColor = backgroundColorOverride or trackerConfig.statusBar.backgroundColor
            local glowColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.glowColor")
            local glowColor = glowColorOverride or trackerConfig.statusBar.glowColor

            frame.statusBar.borderCornerTL:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.statusBar.borderCornerTR:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.statusBar.borderCornerBR:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.statusBar.borderCornerBL:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.statusBar.borderEdgeTop:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.statusBar.borderEdgeRight:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.statusBar.borderEdgeBottom:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.statusBar.borderEdgeLeft:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.statusBar.bgTexture:SetVertexColor(backgroundColor.r, backgroundColor.g, backgroundColor.b, backgroundColor.a)
            frame.statusBar.glowTexture:SetVertexColor(glowColor.r, glowColor.g, glowColor.b, glowColor.a)
        end
        -- to ensure it's not suppressed by errors or overridden
        local borderScaleOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "statusBar.borderScale")
        local borderScale = borderScaleOverride or trackerConfig.statusBar.borderScale or 0.5
        if frame.statusBar.borderCornerTL then frame.statusBar.borderCornerTL:SetScale(borderScale) end
        if frame.statusBar.borderCornerTR then frame.statusBar.borderCornerTR:SetScale(borderScale) end
        if frame.statusBar.borderCornerBR then frame.statusBar.borderCornerBR:SetScale(borderScale) end
        if frame.statusBar.borderCornerBL then frame.statusBar.borderCornerBL:SetScale(borderScale) end
        if frame.statusBar.borderEdgeTop then frame.statusBar.borderEdgeTop:SetScale(borderScale) end
        if frame.statusBar.borderEdgeRight then frame.statusBar.borderEdgeRight:SetScale(borderScale) end
        if frame.statusBar.borderEdgeBottom then frame.statusBar.borderEdgeBottom:SetScale(borderScale) end
        if frame.statusBar.borderEdgeLeft then frame.statusBar.borderEdgeLeft:SetScale(borderScale) end
    end
    
    -- Update or create charge-based display bar if enabled
    -- Destroy existing bar if disabled
    if trackerConfig.chargeBasedDisplay and trackerConfig.chargeBasedDisplay.enabled then
        -- Destroy and recreate to apply new settings
        if frame.chargeAnchorBar then
            frame.chargeAnchorBar:Hide()
            frame.chargeAnchorBar:SetParent(nil)
            frame.chargeAnchorBar = nil
        end
        FrameTrackerManager:CreateChargeBasedDisplayBar(frame, trackerConfig, baseSpellID)
    elseif frame.chargeAnchorBar then
        -- Disabled: remove the bar
        frame.chargeAnchorBar:Hide()
        frame.chargeAnchorBar:SetParent(nil)
        frame.chargeAnchorBar = nil
    end
    
    -- Update position: check override first, then state
    local pos = trackerConfig.position
    if frame.chargeAnchorBar then
        -- Anchor to charge-based display bar's moving edge
        -- Use the bar's anchor point (TOP for normal, BOTTOM for flipped)
        local barConfig = frame.chargeAnchorBar._config
        -- local textureAnchor = barConfig and barConfig.anchorPoint or "TOP"
        local barAnchorPoint = barConfig and barConfig.needsFlip and "BOTTOM" or "TOP"
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", frame.chargeAnchorBar:GetStatusBarTexture(), barAnchorPoint, 0, 0)
    elseif pos and pos.anchorPoint and not frame._inContainer then
        local xOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "position.x")
        local yOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "position.y")
        frame:ClearAllPoints()
        frame:SetPoint(
            pos.anchorPoint, 
            UIParent,
            pos.relativeAnchorPoint or pos.anchorPoint, 
            (pos.x + (xOverride or 0)) or 0, 
            (pos.y + (yOverride or 0)) or 0
        )
    end


    FrameTrackerManager:DriveFrameUpdate(
        frame,
        {
            resolveDuration = true,
            syncChargeText = true
        },
        nil,
        "configurationChanges"
    )

end
-- ============================================================================
-- DRAGGING FUNCTIONS FOR CONFIG MENU
-- Moved to IconSettingsRenderer.lua (SetFrameClickCallback, EnableDraggingForAllFrames, DisableDraggingForAllFrames)
-- ============================================================================

function FrameTrackerManager:GetTrackerFrame(baseSpellID, trackerType)
    return FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] or nil
end

--- Fully destroys a live tracker frame so that no event handlers can ever
--- reach it again. Safe to call even if the frame doesn't exist.
--- Steps:
---   1. Clear the cooldown sweep so OnCooldownDone never fires.
---   2. Hide + ClearAllPoints so it is invisible.
---   3. SetParent(nil) to detach it from the UIParent hierarchy entirely.
---   4. Nil the SpellStyler_frames entry so MatchTrackerFrame / all event
---      handler iterations skip it immediately.
--- The DB entry is NOT touched; callers that want to also remove from the
--- database should call State:RemoveTrackerValue separately.
function FrameTrackerManager:DestroyTrackerFrame(baseSpellID, trackerType)
    local frames = FrameTrackerManager.SpellStyler_frames[trackerType]
    if not frames then return end
    local frame = frames[baseSpellID]
    if not frame then return end

    -- 1. Stop any running cooldown sweep so OnCooldownDone closure never fires.
    if frame.cooldown then
        pcall(function() frame.cooldown:Clear() end)
    end
    -- 2. Make invisible.
    pcall(function() frame:Hide() end)
    pcall(function() frame:ClearAllPoints() end)
    -- 3. Detach from UIParent hierarchy (becomes completely unreachable).
    pcall(function() frame:SetParent(nil) end)
    -- 4. Remove from the event-handler lookup table.
    frames[baseSpellID] = nil
end

-- ============================================================================
-- MOCK COOLDOWN & FRAME HIGHLIGHTING
-- Moved to IconSettingsRenderer.lua: ToggleMockCooldown(), BrieflyHighlightFrame()
-- ============================================================================

-- DO Not Delete: Custom spell Charge tracking that needs to be implemented
function FrameTrackerManager:GetSpellCharges(SpellIdentifier)
  local CdInfo = C_Spell.GetSpellCooldown(SpellIdentifier)

  if not C_Spell.GetSpellCharges(SpellIdentifier).isActive then return 2
  elseif CdInfo.isOnGCD or not CdInfo.isActive then return 1
  else return 0 end
end



-- Set up hooks on BuffIconCooldownViewer to mirror cooldown updates
function FrameTrackerManager:SetupCooldownManagerHooks()
    local viewer = SpellStyler.Containers:GetCooldownManagerViewer("buffs")
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
            if SpellStyler.Containers:GetViewerHidden("buffs") and alpha ~= 0 then
                self._spellStyler_settingViewerAlpha = true
                self:SetAlpha(0)
                self._spellStyler_settingViewerAlpha = false
            end
        end)
    end

    -- Initial scan of existing icons.
    -- hooksecurefunc on Blizzard's protected frames silently fails in combat and
    -- CreateTrackerFrame produces incomplete frames, so defer the full scan until
    -- after combat ends rather than relying on a pcall error that never fires.
    if InCombatLockdown() then
        FrameTrackerManager.AttemptToScanBuffsAfterLeavingCombat = true
    else
        local success, err = pcall(function()
            self:HookAllBuffCooldownFrames("buffs")
        end)
        if err then
            FrameTrackerManager.AttemptToScanBuffsAfterLeavingCombat = true
        end
    end

    -- Apply saved container layouts now that all tracker frames exist
    if SpellStyler.Containers then
        local containers = SpellStyler.Containers:GetDB()
        for containerName in pairs(containers) do
            SpellStyler.Containers:LayoutContainer(containerName)
        end
    end
end

--- Handles CDM frame callbacks for buff tracking
--- @param cdm_frame table The Blizzard cooldown manager frame
--- @param trackerType string The tracker type ("buffs")
--- @param caller string Debug label for the source of the call
local function ProcessCDMFrameCallback(cdm_frame, trackerType, caller)
    local baseSpellID = FrameTrackerManager:ResolveCDMBaseSpellID(cdm_frame)
    local classSpecialization = State:GetCurrentSpecID()
    --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
    local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
    if hasSpecialization and baseSpellID and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] then
        if trackerType == "buffs" then
            pcall(function()
                --if the icon does NOT have a custom texture, then update it dynamically
                if not FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID].meta.customTexture then
                    local frame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                    local icon = cdm_frame.Icon or cdm_frame.icon
                    local texture = (icon.GetTexture and icon:GetTexture()) or icon.texture or cdm_frame.spellStyler_texture
                    frame.icon:SetTexture(texture)
                end
            end)
            
            local config = State:GetSpecificTrackerValue(baseSpellID, trackerType)
            local frame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
            -- Only trust GetAuraSpellInstanceID() when the Blizzard frame is actually
            -- shown (buff active). When hidden, the frame may still hold a stale
            -- non-zero ID from its previous application, which would incorrectly
            -- make Set Icon Visibility think the buff is still active.
            frame.meta.currentAuraInstanceID = cdm_frame:GetAuraSpellInstanceID() or 0
            if frame.meta.currentAuraInstanceID ~= 0 then
                frame.meta.buffStatus = 'present'
            else
                frame.meta.buffStatus = 'absent'
            end
            -- Guard: config can be nil during spec transitions when a stale CDM frame
            -- fires while the new spec's database hasn't been built yet, or when the
            -- scan picked up an old-spec spell that the new spec doesn't track.
            if not config or not config.statusBar then return end
            FrameTrackerManager:DriveFrameUpdate(
                frame,
                {
                    resolveDuration = true,
                    syncChargeText = true
                },

                nil,
                "hookCallback_" .. caller
            )
        end
    end
end

-- Hook all buffs icon cooldowns to mirror to per-icon frames
function FrameTrackerManager:HookAllBuffCooldownFrames(trackerType)
    
    local viewer = SpellStyler.Containers:GetCooldownManagerViewer(trackerType)
    if not viewer then return end
        
    FrameTrackerManager:ScanAndSaveCurrentCooldownManagerFrames(trackerType)

    for slotIndex, cdm_frame in pairs(FrameTrackerManager.cooldownManagerFrames[trackerType]) do
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
            
            -- Local wrapper that calls the module-level ProcessCDMFrameCallback
            local function hookCallback(self, caller)
                ProcessCDMFrameCallback(self, trackerType, caller)
            end

            if cdm_frame.RefreshApplications then hooksecurefunc(cdm_frame, "RefreshApplications", function(self) hookCallback(self, 'RefreshApplications') end) end
            if cdm_frame.OnAuraInstanceInfoSet then hooksecurefunc(cdm_frame, "OnAuraInstanceInfoSet", function(self) hookCallback(self, 'OnAuraInstanceInfoSet') end) end
            if cdm_frame.SetAuraInstanceInfo then hooksecurefunc(cdm_frame, "SetAuraInstanceInfo", function(self) hookCallback(self, 'OnAuraInstanceInfoSet') end) end
            if cdm_frame.OnUnitAuraAddedEvent then hooksecurefunc(cdm_frame, "OnUnitAuraAddedEvent", function(self) hookCallback(self, 'OnAuraInstanceInfoSet') end) end
            if cdm_frame.OnUnitAuraUpdatedEvent then hooksecurefunc(cdm_frame, "OnUnitAuraUpdatedEvent", function(self) hookCallback(self, 'OnAuraInstanceInfoSet') end) end

            
            local sourceCooldown = cdm_frame.Cooldown or cdm_frame.cooldown
            

            local donkFrame
            if sourceCooldown and not cdm_frame.hasHookedCooldown then
                cdm_frame.hasHookedCooldown = true
                hooksecurefunc(sourceCooldown, "SetCooldown", function(self) hookCallback(cdm_frame, 'SetCooldown_buffs') end)
                -- function(self, start, duration)
                --     if trackerType ~= "buffs" then return end  
                --     local classSpecialization = State:GetCurrentSpecID()
                --     --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
                --     local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
                --     if not hasSpecialization then return end
                --     local baseSpellID = FrameTrackerManager:ResolveCDMBaseSpellID(cdm_frame)
                --     local customFrame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                    
                --     if not customFrame then return end
                --     --TODO: Add a setting if you want to "Set buff active as status bar full" which should result in THIS handling the status bar, rather than duration inactive or w/e 
                --     customFrame.meta.currentAuraInstanceID = cdm_frame:GetAuraSpellInstanceID() or 0
                --     if customFrame.meta.currentAuraInstanceID ~= 0 then
                --         customFrame.meta.buffStatus = 'present'
                --     else
                --         customFrame.meta.buffStatus = 'absent'
                --     end
                --     FrameTrackerManager:DriveFrameUpdate(
                --         customFrame,
                --         {
                --             resolveDuration = true,
                --             syncChargeText = true
                --         },
                --         nil,
                --         "buffSetCooldown"
                --     )
                -- end)
            end
        end
    end
end

-- ============================================================================
-- SPELL Cooldown Tracking
-- ============================================================================



-- ============================================================================
-- INITIALIZATION
-- ============================================================================
local hasPlayerEnetedWorld = false

--- Immediately hides and wipes all live tracker frames and resets the lookup
--- tables. Called synchronously on talent change so that no events fired
--- during the rescan delay can reach stale frames or query the wrong spec DB.
function FrameTrackerManager:TeardownSpecFrames()
    for _, tType in ipairs({"buffs", "essential", "utility", "spells"}) do
        if FrameTrackerManager.SpellStyler_frames[tType] then
            for _, frame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                if frame and frame.Hide then
                    frame:Hide()
                    frame:ClearAllPoints()
                end
            end
        end
    end
    -- Reset the hook-guard flag on every live CDM frame so that HookAllBuffCooldownFrames
    -- creates fresh hooks with a new closure after the next spec scan.
    -- Old hooksecurefunc hooks cannot be removed, but the nil-config guard inside
    -- hookCallback makes stale firings harmless.
    
    if FrameTrackerManager.cooldownManagerFrames["buffs"] then
        for _, cdmFrame in pairs(FrameTrackerManager.cooldownManagerFrames["buffs"]) do
            if cdmFrame then
                cdmFrame._spellStyler_hasHookedFrame = nil
                cdmFrame.hasHookedCooldown = nil
            end
        end
    end
    FrameTrackerManager.cooldownManagerFrames    = { buffs = {} }
    FrameTrackerManager.cooldownIDToBaseSpellID = {}
    FrameTrackerManager.SpellStyler_frames      = { buffs = {}, essential = {}, utility = {}, spells = {} }
end



--- Internal: executes the full DriveFrameUpdate pipeline immediately.
--- Called by DriveFrameUpdate after the coalesce window closes.
--- @param frame   table
--- @param flags   { resolveDuration: boolean, syncChargeText: boolean }
--- @param opts    { durationObject?: table|userdata, forceUpdate?: boolean }
--- @param sources string[]  All source labels collected during the window (for debugging)
function FrameTrackerManager:_ExecuteDrive(frame, flags, opts, sources)
    opts = opts or {}
    local config, foundConfig = State:GetSpecificTrackerValue(frame.meta.baseSpellID, frame.meta.trackerType)
    if not config or not foundConfig then
        local spellName = C_Spell.GetSpellName(frame.meta.activeSpellID) or "Unknown"
        local stateKey = frame.meta.baseSpellID
        local errorMsg = spellName .. " was not found in state. The key used to pull from state is " .. tostring(stateKey) .. ". The active spell id is " .. tostring(frame.meta.activeSpellID) .. ". The tracker type is " .. tostring(frame.meta.trackerType)
        
        -- Try to save error to devNotes if config exists
        pcall(function()
            if config and config.devNotes then
                local devNotes = config.devNotes or {}
                -- Check if error message already exists
                local alreadyExists = false
                for _, note in ipairs(devNotes) do
                    if note == errorMsg then
                        alreadyExists = true
                        break
                    end
                end
                if not alreadyExists then
                    table.insert(devNotes, errorMsg)
                end
                State:SetTrackerValueConfigProperty(frame.meta.baseSpellID, frame.meta.trackerType, "devNotes", devNotes)
            end
        end)
        return
    end

    if flags.resolveDuration then
        FrameTrackerManager:ApplyCooldownDuration({
            customFrame    = frame,
            config         = config,
            baseSpellID    = frame.meta.baseSpellID,
            activeSpellID  = frame.meta.activeSpellID,
            trackerType    = frame.meta.trackerType,
            durationObject = opts.durationObject,
            forceUpdate    = opts.forceUpdate,
        })
    end
    -- Get fundamental alpha states (secret-safe)
    local whenAvailable, whenActive, progressBar, fullBar = FrameTrackerManager:GetFrameStateAlphas(frame)
    
    -- Cache alpha values for conditional engine to reference when applying overrides
    if SpellStyler.ConditionalEngine then
        SpellStyler.ConditionalEngine:CacheFrameAlphas(frame, whenAvailable, whenActive, progressBar, fullBar)
    end

    local useDisplayCount = config.countText and config.countText.useSpellDisplayCount
    if flags.syncChargeText and not useDisplayCount then
        FrameTrackerManager:renderUpdateChargesText({
            customFrame   = frame,
            config        = config,
            baseSpellID   = frame.meta.baseSpellID,
            activeSpellID = frame.meta.activeSpellID,
            trackerType   = frame.meta.trackerType,
            textAlpha     = whenActive
        })
    end
    
    -- Guard: If iconSettings doesn't exist, the config is malformed/incomplete
    -- This can happen during spec transitions, database corruption, or legacy data
    if not config.iconSettings or not config.statusBar or not config.cooldownText then
        local spellName = C_Spell.GetSpellName(frame.meta.activeSpellID) or "Unknown"
        local stateKey = frame.meta.baseSpellID
        local errorMsg = spellName .. " has a malformed configuration entry in state. The key in state is " .. tostring(stateKey) .. ". The active spell id is " .. tostring(frame.meta.activeSpellID) .. ". The tracker type is " .. tostring(frame.meta.trackerType)
        
        -- Save error to devNotes using State method
        pcall(function()
            local devNotes = config.devNotes or {}
            -- Check if error message already exists
            local alreadyExists = false
            for _, note in ipairs(devNotes) do
                if note == errorMsg then
                    alreadyExists = true
                    break
                end
            end
            if not alreadyExists then
                table.insert(devNotes, errorMsg)
            end
            State:SetTrackerValueConfigProperty(frame.meta.baseSpellID, frame.meta.trackerType, "devNotes", devNotes)
        end)
        return
    end
    
    FrameTrackerManager.ApplyVisibility.Icon({
        displayState = config.iconSettings.iconDisplayState,
        whenAvailableToCastAlpha = whenAvailable,
        whenOnCooldownAlpha = whenActive,
        customFrame = frame,
        config = config
    })
    FrameTrackerManager.ApplyVisibility.StatusBar({
        progressBarAlpha = progressBar,
        fullBarAlpha = fullBar,
        customFrame = frame,
        displayState = config.statusBar.displayState,
        statusBarConfig = config.statusBar,
        config = config,
        isFull = config.statusBar and config.statusBar.defaultFillValue == 'full'
    })
    -- NOTE: Charges visibility is now handled within renderUpdateChargesText()
    FrameTrackerManager.ApplyVisibility.CooldownSwipe({
        shouldDisplay = not config.iconSettings.hideDefaultSweep,
        customFrame = frame,
        trackerType = frame.meta.trackerType
    })
    FrameTrackerManager.ApplyVisibility.CooldownText({
        shouldDisplay = config.cooldownText.display,
        customFrame = frame,
        config = config.cooldownText,
        textAlpha = whenActive
    })
    -- NOTE: CustomLabel is handled entirely in UpdateFrame_ConfigurationChanges
    -- It doesn't need to react to cooldown state
end



--- @param frame   table    The tracker frame
--- @param flags   { resolveDuration: boolean, syncChargeText: boolean }
--- @param opts?   { durationObject?: table|userdata, forceUpdate?: boolean }
--- @param source? string   Call-site label for debug tracing, e.g. "SPELL_UPDATE_COOLDOWN"
function FrameTrackerManager:DriveFrameUpdate(frame, flags, opts, source)
    local q = FrameTrackerManager._driveQueue
    if not q[frame] then
        -- First call in this window: open the timer.
        q[frame] = {
            flags   = { resolveDuration = flags.resolveDuration, syncChargeText = flags.syncChargeText },
            opts    = opts and { durationObject = opts.durationObject, forceUpdate = opts.forceUpdate } or {},
            sources = { source or "unknown" },
        }
        C_Timer.After(0.005, function()
            local entry = q[frame]
            q[frame] = nil
            if entry then
                FrameTrackerManager:_ExecuteDrive(frame, entry.flags, entry.opts, entry.sources)
            end
        end)
    else
        -- Subsequent call within the same window: merge, don't open a new timer.
        local entry = q[frame]
        -- OR the boolean flags so no step requested by any caller is skipped.
        if flags.resolveDuration then entry.flags.resolveDuration = true end
        if flags.syncChargeText  then entry.flags.syncChargeText  = true end
        -- opts: prefer truthy values from the latest call.
        if opts then
            if opts.durationObject ~= nil then entry.opts.durationObject = opts.durationObject end
            if opts.forceUpdate         then entry.opts.forceUpdate    = true end
        end
        -- Append source label for the debug log.
        table.insert(entry.sources, source or "unknown")
    end
end

--- Calculates fundamental alpha states for a tracker frame using secret-safe Blizzard APIs.
--- Returns raw alpha values representing different states; caller decides which to use.
--- All values are 0-1 and safe to pass directly to SetAlpha() (may be secret values).
--- @param frame table The tracker frame
--- @return number whenAvailable Alpha = 1 when spell/buff is available/inactive, 0 when active/on cooldown
--- @return number whenActive Alpha = 1 when spell/buff is active/on cooldown, 0 when available/inactive  
--- @return number progressBar Alpha = 1 during real cooldown (not GCD), 0 otherwise
--- @return number fullBar Alpha = 1 during GCD/available, 0 during real cooldown
function FrameTrackerManager:GetFrameStateAlphas(frame)
    local trackerType = frame.meta.trackerType
    local activeSpellID = frame.meta.activeSpellID
    
    -- Handle mock cooldown override
    if frame.meta.mockCooldownActive then
        return 0, 1, 1, 0  -- available=0, active=1, progress=1, full=0
    end
    
    -- Buffs: simple aura presence check
    if trackerType == 'buffs' then
        local hasAura = frame.meta.currentAuraInstanceID and frame.meta.currentAuraInstanceID ~= 0
        return hasAura and 0 or 1, hasAura and 1 or 0, hasAura and 1 or 0, hasAura and 0 or 1
    end
    
    -- Spells: use secret-safe charge count or duration curves
    local cooldownInfo = C_Spell.GetSpellCooldown(activeSpellID)
    local chargeInfo = C_Spell.GetSpellCharges(activeSpellID)
    
    -- Determine which duration object to use
    local durationObj = (chargeInfo and chargeInfo.maxCharges > 1)
        and C_Spell.GetSpellChargeDuration(activeSpellID, true)
        or C_Spell.GetSpellCooldownDuration(activeSpellID, true)
    
    local whenAvailableToCast, whenOnCooldown, progressBar, fullBar
    
    -- When isActive == false, spell is reliably available (only reliable indicator)
    if cooldownInfo and cooldownInfo.isActive == false then
        whenAvailableToCast = 1
        whenOnCooldown = 0
    elseif chargeInfo and chargeInfo.maxCharges > 1 then
        -- Charge-based spell: currentCharges secret-normalizes (>=1 becomes 1, 0 stays 0)
        whenAvailableToCast = chargeInfo.currentCharges
        whenOnCooldown = durationObj and durationObj:EvaluateRemainingDuration(SpellStyler.Util:IsValidCooldownCurve(true)) or 0
    else
        -- Non-charge spell: use duration curves
        whenAvailableToCast = durationObj and durationObj:EvaluateRemainingDuration(SpellStyler.Util:IsValidCooldownCurve()) or 1
        whenOnCooldown = durationObj and durationObj:EvaluateRemainingDuration(SpellStyler.Util:IsValidCooldownCurve(true)) or 0
    end
    
    -- Progress/full bar alphas use curves (inverse of each other via different curve objects)
    if durationObj then
        fullBar = durationObj:EvaluateRemainingDuration(SpellStyler.Util:IsValidCooldownCurve())
        progressBar = durationObj:EvaluateRemainingDuration(SpellStyler.Util:IsValidCooldownCurve(true))
    else
        fullBar = 0
        progressBar = 0
    end
    
    return whenAvailableToCast, whenOnCooldown, progressBar, fullBar
end


--- @param data ApplyCooldownDurationData
function FrameTrackerManager:renderUpdateChargesText(data)
    if not data.customFrame or not data.config then return false end
    
    local success, error = pcall(function()
        local countCfg = data.config.countText
        if countCfg then
            -- Apply font size: check override first, then state
            local sizeOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, "countText.size")
            local fontSize = sizeOverride or countCfg.size
            local fontPath, _, fontFlags = data.customFrame.count:GetFont()
            if fontPath and fontSize then
                data.customFrame.count:SetFont(fontPath, fontSize, fontFlags or "OUTLINE")
            end
            
            -- Apply color: check override first, then state
            local colorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, "countText.color")
            local color = colorOverride or countCfg.color
            if color then
                data.customFrame.count:SetTextColor(
                    color.r or 1,
                    color.g or 1,
                    color.b or 1,
                    data.textAlpha or color.a or 1
                )
            end
            
            -- Apply position: check override first, then state
            local xOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, "countText.x")
            local yOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, "countText.y")
            data.customFrame.count:ClearAllPoints()
            data.customFrame.count:SetPoint("BOTTOMRIGHT", data.customFrame, "BOTTOMRIGHT",
                (xOverride or countCfg.x or 0) - 2,
                (yOverride or countCfg.y or 0) + 2)
            
            -- Apply visibility alpha based on display setting and charge count
            if data.customFrame.meta.trackerType == "buffs" then
                if data.config.countText.display then
                    if data.customFrame.meta.currentAuraInstanceID ~= 0 and data.customFrame.meta.currentAuraInstanceID ~= nil then
                        local playerCount = C_UnitAuras.GetAuraApplicationDisplayCount("player", data.customFrame.meta.currentAuraInstanceID, 1)
                        local targetCount = C_UnitAuras.GetAuraApplicationDisplayCount("player", data.customFrame.meta.currentAuraInstanceID, 1)
                        data.customFrame.count:SetText(playerCount or targetCount)
                        if data.config.chargeBasedDisplay.enabled and data.customFrame.chargeAnchorBar then
                            data.customFrame.chargeAnchorBar:SetValue(playerCount or targetCount or 0)
                        end
                    else
                        data.customFrame.count:SetText("")
                        if data.config.chargeBasedDisplay.enabled and data.customFrame.chargeAnchorBar then
                            data.customFrame.chargeAnchorBar:SetValue(0)
                        end
                    end
                end
                if countCfg.display then
                    data.customFrame.count:SetAlpha(1)
                else
                    data.customFrame.count:SetAlpha(0)
                end
            elseif data.customFrame.meta.trackerType == "spells" then
                if not countCfg.display then
                    data.customFrame.count:SetAlpha(0)
                else
                    local chargesData = C_Spell.GetSpellCharges(data.customFrame.meta.activeSpellID)
                    local currentCharges
                    if not chargesData or chargesData.maxCharges == 1 then
                        -- set zero so that spells with only 1 charge dont render the text
                        currentCharges = 0
                    else
                        currentCharges = chargesData.currentCharges
                    end
                    data.customFrame.count:SetText(currentCharges)
                    data.customFrame.count:SetAlpha(currentCharges)
                    if data.config.chargeBasedDisplay.enabled and data.customFrame.chargeAnchorBar then
                        data.customFrame.chargeAnchorBar:SetValue(currentCharges)
                    end
                end
            end
        end
    end)
end

FrameTrackerManager.ApplyVisibility = {
    --[[
        customFrame
        iconDisplayState
    ]]
    Icon = function(context)
        context.customFrame.icon:Show()
        
        -- Check if global override is active (settings menu open with override enabled)
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
        
        -- Determine alpha based on display state
        local alpha
        if shouldOverrideVisibility then
            -- Force visible when settings are open with override enabled
            alpha = 1
        elseif context.displayState == "always" then
            alpha = 1
        elseif context.displayState == "cooldown" or context.displayState == "active" then
            alpha = context.whenOnCooldownAlpha
        elseif context.displayState == "available" or context.displayState == "inactive" then
            alpha = context.whenAvailableToCastAlpha
        else
            alpha = 0
        end
        
        -- Get color from override first, then state
        local iconColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(context.customFrame, "iconColor")
        local color = iconColorOverride or (context.config and context.config.iconColor) or {}
        
        -- Apply color with the appropriate alpha
        context.customFrame.icon:SetVertexColor(
            color.r or 1,
            color.g or 1,
            color.b or 1,
            alpha
        )
    end,
    --[[
    
    ]]
    StatusBar = function(context)
        -- Status bar frame alpha: controls visibility of the entire bar container
        -- When "always", the container is always visible; fill/border/bg alphas handle the details
        local statusBarFrameAlpha = 1
        local statusBarFillAlpha = 0
        local fullBarAlpha = 0
        
        if context.displayState == 'never' then
            statusBarFrameAlpha = 0
            statusBarFillAlpha = 0
            fullBarAlpha = 0
        elseif context.displayState == 'always' then
            statusBarFrameAlpha = 1  -- Container always visible
            statusBarFillAlpha = context.progressBarAlpha
            fullBarAlpha = (context.isFull) and context.fullBarAlpha or 0
        elseif context.displayState == 'active' or context.displayState == 'cooldown' then
            statusBarFrameAlpha = context.progressBarAlpha  -- Only show during active cooldown
            statusBarFillAlpha = context.progressBarAlpha
            fullBarAlpha = 0
        end
        
        local a, b = pcall(function()
            -- Check for cached conditional overrides first, fall back to state values
            local barColor = context.statusBarConfig.color
            if SpellStyler.ConditionalEngine then
                local overrideColor = SpellStyler.ConditionalEngine:GetCachedPropertyOverride(context.customFrame, "statusBar.color")
                if overrideColor then
                    barColor = overrideColor
                end
            end
            
            -- NOTE: Size, scale, and position are handled by UpdateFrame_ConfigurationChanges
            -- NOTE: Show() is called once at creation (CreateStatusBar); visibility controlled by alpha only

            context.customFrame.statusBar:SetAlpha(statusBarFrameAlpha)
            
            context.customFrame.statusBar:SetStatusBarColor(
                barColor.r or 0.2,
                barColor.g or 0.8,
                barColor.b or 1,
                statusBarFillAlpha
            )
            context.customFrame.statusBar.fullCoverTexture:SetVertexColor(
                barColor.r or 0.2,
                barColor.g or 0.8,
                barColor.b or 1,
                fullBarAlpha
            )
        end)
        local s, e = pcall(function()
            local don = context.config.statusBar.onlyRenderBar
        end)
        local onlyBarOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(context.customFrame, "statusBar.onlyRenderBar")
        local onlyBar = (onlyBarOverride ~= nil) and onlyBarOverride or (context.config.statusBar.onlyRenderBar or false)
        if not onlyBar and context.config.statusBar.displayState ~= 'never' and context.config.statusBar.displayState ~= 'always' then
            -- Apply onlyRenderBar setting and visibility state to bg/glow/border
            local spellInfo = C_Spell.GetSpellInfo(context.customFrame.meta.activeSpellID)
            FrameTrackerManager:SetStatusBarContainerVisibility({
                customFrame = context.customFrame,
                config = context.config,
                baseSpellID = context.customFrame.meta.baseSpellID,
                activeSpellID = context.customFrame.meta.activeSpellID,
                trackerType = context.customFrame.meta.trackerType,
                statusBarFillAlpha = statusBarFillAlpha  -- Pass visibility alpha for bg/glow/border
            })
        end
    end,
    --[[
        shouldDisplay
        customFrame
    ]]
    CooldownSwipe = function(context)
        -- Hide swipe for buffs without an aura OR for totems that aren't active
        if not context.shouldDisplay or (context.trackerType == "buffs" and not context.customFrame.meta.isTotemActive and (context.customFrame.meta.currentAuraInstanceID == 0 or context.customFrame.meta.currentAuraInstanceID == nil)) then
            context.customFrame.cooldown:SetDrawEdge(false)
            context.customFrame.cooldown:SetDrawBling(false)
            context.customFrame.cooldown:SetDrawSwipe(false)
        else
            context.customFrame.cooldown:SetDrawEdge(true)
            context.customFrame.cooldown:SetDrawBling(true)
            context.customFrame.cooldown:SetDrawSwipe(true)
            --default to showing the cooldown swipe for buffs. No need to check durationObject stuff. If it shouldnt show, that would be controlled by the "shouldDisplay" property
            if context.trackerType == "buffs" then
                context.customFrame.cooldown:SetAlpha(1)    
            else
                --TODO: See if this actually works - just set display to true and see if it ignores the GCD swipe
                local durationEqualToGCD    = SpellStyler.Util:IsValidCooldownCurve(true)
                local maxSpellCharges = 1
                local spellChargeInfo = C_Spell.GetSpellCharges(context.customFrame.meta.activeSpellID)
                if spellChargeInfo and spellChargeInfo.maxCharges then
                    maxSpellCharges = spellChargeInfo.maxCharges
                end
                local durationObject
                if maxSpellCharges > 1 then
                    durationObject = C_Spell.GetSpellChargeDuration(context.customFrame.meta.activeSpellID, true)
                else
                    durationObject = C_Spell.GetSpellCooldownDuration(context.customFrame.meta.activeSpellID, true)
                end
                local alpha =  durationObject:EvaluateRemainingDuration(durationEqualToGCD)            
                context.customFrame.cooldown:SetAlpha(alpha)
            end
        end
    end,
    --[[
        shouldDisplay
        customFrame
        config (cooldownText config)
        textAlpha (visibility alpha from whenActive)
    ]]
    CooldownText = function(context)
        if not context.shouldDisplay then
            context.customFrame.cooldown:SetHideCountdownNumbers(true)
        else
            context.customFrame.cooldown:SetHideCountdownNumbers(false)
            
            -- Apply color with visibility alpha
            local cdText = context.customFrame.cooldown.Text or context.customFrame.cooldown.text
            if not cdText then
                -- Search regions for FontString
                for i = 1, context.customFrame.cooldown:GetNumRegions() do
                    local region = select(i, context.customFrame.cooldown:GetRegions())
                    if region and region:GetObjectType() == "FontString" then
                        cdText = region
                        break
                    end
                end
            end
            
            if cdText and context.config then
                pcall(function()
                    -- Apply color: check override first, then state
                    local colorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(context.customFrame, "cooldownText.color")
                    local color = colorOverride or context.config.color
                    if color then
                        cdText:SetTextColor(
                            color.r or 1,
                            color.g or 1,
                            color.b or 1,
                            context.textAlpha or color.a or 1
                        )
                    end
                end)
            end
        end
    end,
}

--- @class ApplyCooldownDurationData
--- @field baseSpellID number
--- @field activeSpellID number
--- @field config table
--- @field trackerType string
--- @field customFrame table
--- @field forceUpdate? boolean
--- @field durationObject? table    -- optional pre-resolved duration object; when set, the C_Spell lookup is skipped
--- @field currentCharges? number   -- caller-supplied charge count for UpdateFrame_ChargeVisibility (0 = on cooldown)
--- @field checkIsValidCooldown? boolean

--- Performs the actual cooldown application work: resolves the duration object,
--- then calls SetTimerDuration, SetCooldown, SetIconVisibility, and SetStatusBarVisibility.
--- Must NOT be called directly from outside this file; use ApplyCooldownDuration instead.
--- @param data ApplyCooldownDurationData
--local function _DoApplyCooldownDuration(data)
function FrameTrackerManager:ApplyCooldownDuration(data)
    local durationObject = data.durationObject  -- optional pre-resolved duration object
    local s, e
    if not durationObject then
        
        if data.trackerType == 'buffs' then
            -- Buffs frames must NEVER fall back to C_Spell cooldown data.
            -- Buffs that are actually totems (Invoke chi-ji) have a preresolved duration object passed. They also have totemSlot, NOT currentAuraInstanceID. So when no duration object for those types of buffs, nothing is applied (which is correct)
            local auraID = data.customFrame.meta.currentAuraInstanceID
            if auraID and auraID ~= 0 then
                s, e = pcall(function()
                    durationObject = C_UnitAuras.GetAuraDuration("player", auraID)
                    if not durationObject then
                        durationObject = C_UnitAuras.GetAuraDuration("target", auraID)
                    end
                end)
            end
        else
            s, e = pcall(function()
                -- try to get spell charge duration first
                local maxSpellCharges = 1
                local spellChargeInfo = C_Spell.GetSpellCharges(data.customFrame.meta.activeSpellID or data.activeSpellID)
                if spellChargeInfo and spellChargeInfo.maxCharges then
                    maxSpellCharges = spellChargeInfo.maxCharges
                end
                if maxSpellCharges > 1 then
                    durationObject = C_Spell.GetSpellChargeDuration(data.customFrame.meta.activeSpellID or data.activeSpellID, true)
                else
                    durationObject = C_Spell.GetSpellCooldownDuration(data.customFrame.meta.activeSpellID or data.activeSpellID, true)
                end
            end)
        end
    end
    if data.forceUpdate then
        data.customFrame.cooldown:Clear()
        data.customFrame.statusBar:SetValue(0)
    end
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
        local spellInfo = C_Spell.GetSpellInfo(data.customFrame.meta.activeSpellID or data.config.overrideSpellID)
        data.customFrame.statusBar:SetTimerDuration(
            durationObject,
            Enum.StatusBarInterpolation.Immediate,
            cdTimerDir
        )
    end
    
    if data.trackerType == 'buffs' then
        data.customFrame.meta.buffStatus = 'active'
        local isZero = durationObject and durationObject.IsZero and durationObject:IsZero()
        local isSecret = issecretvalue(isZero)
        if not isSecret and isZero then
            data.customFrame.meta.buffStatus = 'present'
        end
    end
    data.customFrame.cooldown:SetCooldownFromDurationObject(durationObject)
end



-- When onlyRenderBar is true, hides bg/glow/border by zeroing their alpha.
-- When false, restores each element to its correct config alpha via SetVertexColor.
-- The main fill (SetStatusBarTexture) is never touched.

--- @param data ApplyCooldownDurationData
function FrameTrackerManager:SetStatusBarContainerVisibility(data)
    if not data.customFrame.statusBar then return end
    
    -- Safety check for config structure
    if not data.config or not data.config.statusBar then
        return
    end
    
    -- Use statusBarFrameAlpha if provided (from ApplyVisibility.StatusBar), otherwise default to 1
    -- This ensures bg/glow/border visibility matches the status bar's visibility state
    local visibilityAlpha = data.statusBarFillAlpha

    -- Background texture uses backgroundColor (check override first)
    -- Alpha is: 0 if onlyBar=true, otherwise visibilityAlpha * config alpha
    if data.customFrame.statusBar.bgTexture then
        local bgColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, "statusBar.backgroundColor")
        local c = bgColorOverride or data.config.statusBar.backgroundColor
        local alpha = visibilityAlpha
        data.customFrame.statusBar.bgTexture:SetVertexColor(c.r or 0, c.g or 0, c.b or 0, alpha)
    end

    -- Glow overlay uses glowColor (check override first)
    if data.customFrame.statusBar.glowTexture then
        local glowColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, "statusBar.glowColor")
        local c = glowColorOverride or data.config.statusBar.glowColor
        local alpha = visibilityAlpha
        data.customFrame.statusBar.glowTexture:SetVertexColor(c.r or 1, c.g or 1, c.b or 1, alpha)
    end

    -- All 8 border pieces use borderColor (check override first)
    local borderColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, "statusBar.borderColor")
    local bc = borderColorOverride or data.config.statusBar.borderColor
    local br, bg, bb = bc.r or 0, bc.g or 0, bc.b or 0
    local ba = visibilityAlpha
    if data.customFrame.statusBar.borderCornerTL then data.customFrame.statusBar.borderCornerTL:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderCornerTR then data.customFrame.statusBar.borderCornerTR:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderCornerBR then data.customFrame.statusBar.borderCornerBR:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderCornerBL then data.customFrame.statusBar.borderCornerBL:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderEdgeTop    then data.customFrame.statusBar.borderEdgeTop:SetVertexColor(br, bg, bb, ba)    end
    if data.customFrame.statusBar.borderEdgeRight  then data.customFrame.statusBar.borderEdgeRight:SetVertexColor(br, bg, bb, ba)  end
    if data.customFrame.statusBar.borderEdgeBottom then data.customFrame.statusBar.borderEdgeBottom:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderEdgeLeft   then data.customFrame.statusBar.borderEdgeLeft:SetVertexColor(br, bg, bb, ba)   end
end


--- Resolves the baseSpellID (DB key) for a Blizzard CDM frame using a stable priority chain
---
--- Priority order:
---   1. cooldownIDToBaseSpellID[GetCooldownID()] – slot-based,
---      recorded at scan time and never mutated at runtime.
---   2. live GetSpellID()  – last resort; unreliable once the buff
---      is active (Blizzard returns a different ID at that point).
---
--- @param sourceFrame table  The Blizzard CDM frame to resolve for
--- @return number|nil        The resolved baseSpellID, or nil if unresolvable
function FrameTrackerManager:ResolveCDMBaseSpellID(sourceFrame)
    -- Priority 1: stable slot-based lookup via the cooldownID recorded at scan time
    local cid
    pcall(function()
        cid = sourceFrame.GetCooldownID and sourceFrame:GetCooldownID()
    end)
    if cid and FrameTrackerManager.cooldownIDToBaseSpellID[cid] then
        return FrameTrackerManager.cooldownIDToBaseSpellID[cid]
    end

    -- Priority 2: live GetSpellID (may differ from the DB key when a buff is active)
    local raw = nil
    pcall(function()
        local v = sourceFrame.GetSpellID and sourceFrame:GetSpellID()
        if v and not issecretvalue(v) then raw = v end
    end)
    return raw
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
            baseSpellID
            trackerType,
            config
        }
    ]]
    local currentSpellToBaseSpellID = C_Spell.GetBaseSpell(spellID)
    for _, tType in ipairs({"essential", "utility", "spells"}) do
        if FrameTrackerManager.SpellStyler_frames[tType] then
            for baseSpellID, trackedFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                --match found, update the return data
                if currentSpellToBaseSpellID == baseSpellID then
                    match = {
                        config = State:GetSpecificTrackerValue(baseSpellID, tType),
                        baseSpellID = baseSpellID,
                        activeSpellID = spellID,
                        customFrame = trackedFrame,
                        trackerType = tType
                    }
                    return match
                end
            end
        end
    end
    return match
end

function FrameTrackerManager:Initalize()
    if isInitialized or not hasPlayerEnetedWorld then return end
    isInitialized = true

    FrameTrackerManager:SetupCooldownManagerHooks()
    FrameTrackerManager:CreateNonBuffTrackerFrames()
    
    -- Evaluate all conditionals after frames are created
    if SpellStyler.ConditionalEngine then
        C_Timer.After(0.1, function()
            SpellStyler.ConditionalEngine:EvaluateAll()
        end)
    end
    
    C_Timer.After(3, function()
        -- Re-setup hooks in case viewer was recreated
        FrameTrackerManager:SetupCooldownManagerHooks()
        FrameTrackerManager:CreateNonBuffTrackerFrames()
        
        -- Re-evaluate conditionals after delayed setup
        if SpellStyler.ConditionalEngine then
            SpellStyler.ConditionalEngine:EvaluateAll()
        end
    end)
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
eventFrame:RegisterEvent("SPELL_DATA_LOAD_RESULT")
eventFrame:RegisterEvent("SPELL_UPDATE_USABLE")
eventFrame:RegisterEvent("UNIT_POWER_UPDATE")
eventFrame:RegisterEvent("PLAYER_TOTEM_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        hasPlayerEnetedWorld = true
        FrameTrackerManager:Initalize()
    end
    if event == "PLAYER_LEAVING_WORLD" then
        hasPlayerEnetedWorld = false
    end

    if event == "SPELL_DATA_LOAD_RESULT" then
        local spellID, success = ...
        for _, tType in ipairs({"essential", "utility", "spells"}) do
            if FrameTrackerManager.SpellStyler_frames[tType] then
                for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                    if baseSpellID == spellID or C_Spell.GetBaseSpell(spellID) == baseSpellID then
                        -- Stupid ass shit to make the frame cache the correct value of charges. Holy shock shows a max charge of 1, but then later provides 2. This delay should hopefully ensure it apply the correct value.
                        C_Timer.After(1, function()
                            local config = State:GetSpecificTrackerValue(baseSpellID, tType)
                            local spellChargesInfo = C_Spell.GetSpellCharges(config.overrideSpellID)
                            local spellInfo = C_Spell.GetSpellInfo(config.overrideSpellID)
                            customFrame.meta.spellName = spellInfo.name
                            customFrame.meta.isSpellWithCharges = spellChargesInfo and spellChargesInfo.maxCharges > 1

                            FrameTrackerManager:DriveFrameUpdate(
                                customFrame, {
                                    resolveDuration = true,
                                    syncChargeText = true
                                },
                                nil,
                                'spellDataLoaded'
                            )
                        end)
                    end
                end
            end
        end
    end

    local classSpecialization = State:GetCurrentSpecID()
    --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
    local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
    if (event ~= "UNIT_SPELLCAST_SUCCEEDED") and (hasPlayerEnetedWorld == false or not hasSpecialization) then
        return
    end


    if event == "PLAYER_TOTEM_UPDATE" then
        -- local slot = ...
        -- local haveTotem, totemName, startTime, duration, icon, modRate, spellID = GetTotemInfo(slot)
        -- local matchedFrameBySlot
        -- for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames["buffs"]) do
        --     if customFrame.meta.isTotem then --totemSlot ~= nil and customFrame.meta.totemSlot ~= 0 and customFrame.meta.totemSlot == slot then
        --         matchedFrameBySlot = customFrame
        --     end
        -- end
        -- local totemDuration = GetTotemDuration(slot)
        -- if matchedFrameBySlot then
        --     -- Duration objects are nil when the totem is not active. Attempt to use this as the indicator for totem type buffs
        --     matchedFrameBySlot.meta.isTotemActive = totemDuration ~= nil
        --     matchedFrameBySlot.meta.buffStatus = totemDuration ~= nil and 'active' or 'absent'
        --     FrameTrackerManager:DriveFrameUpdate(
        --         matchedFrameBySlot,
        --         {
        --             resolveDuration = true,
        --             syncChargeText = true
        --         },
        --         {
        --             durationObject = totemDuration
        --         },
        --         'PLAYER_TOTEM_UPDATE'
        --     )
        -- end
    end

    if event == "SPELL_UPDATE_CHARGES" then
        for _, tType in ipairs({"essential", "utility", "spells"}) do
            if FrameTrackerManager.SpellStyler_frames[tType] then
                for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                    local match = FrameTrackerManager:MatchTrackerFrame(baseSpellID)
                    if match and match.customFrame.meta.isSpellWithCharges then
                        local isActive = C_Spell.GetSpellCharges(match.customFrame.meta.activeSpellID).isActive
                        -- clear any active cooldown and reapply (This helps when a spell gains its final charge in the middle of a cooldown. It will clear, rather than compeltely the cooldown duration that means nothing at that point)
                        if not isActive then
                            if match.customFrame and match.customFrame.cooldown then match.customFrame.cooldown:Clear() end
                            if match.customFrame and match.customFrame.statusBar then match.customFrame.statusBar:SetValue(0) end
                            FrameTrackerManager:DriveFrameUpdate(
                                customFrame, {
                                    resolveDuration = false,
                                    syncChargeText = true
                                },
                                nil,
                                'spellupdateCharges'
                            )
                        else
                            FrameTrackerManager:DriveFrameUpdate(
                                customFrame, {
                                    resolveDuration = true,
                                    syncChargeText = true
                                },
                                nil,
                                'spellupdateCharges'
                            )
                        end
                    end
                end
            end
        end
    end
    if event == "UNIT_POWER_UPDATE" then
        local unitTarget, powerType = ...
        if unitTarget == "player" then
            local power = GetComboPoints("player", "target")
            SpellStyler.ConditionalEngine:NotifySourceChanged("ComboPoints", power)
            for _, tType in ipairs({"spells", "buffs"}) do
                if FrameTrackerManager.SpellStyler_frames[tType] then
                    for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                        local config = SpellStyler.State:GetSpecificTrackerValue(baseSpellID, tType)
                        if config.iconSettings.insufficientPower then
                            local _, insufficientPower = C_Spell.IsSpellUsable(customFrame.meta.activeSpellID)
                            local color = (insufficientPower and config.iconSettings.insufficientPower and config.iconSettings.insufficientPowerIconColor)
                                or config.iconColor or {}
                            customFrame.icon:SetVertexColor(
                                color.r or 1,
                                color.g or 1,
                                color.b or 1,
                                color.a or 1
                            )

                            FrameTrackerManager:DriveFrameUpdate(
                                customFrame,
                                {
                                    resolveDuration = false,
                                    syncChargeText = false
                                },
                                nil,
                                'unitPowerUpdate'
                            )
                        end
                    end
                end
            end
        end
    end

    if event == "UNIT_AURA" then
        local unitTarget, updateInfo = ...
        if unitTarget ~= "player" then return end
        -- Build a set of every aura instance ID that was explicitly removed.
        local removedAuraSet = {}
        if updateInfo and updateInfo.removedAuraInstanceIDs then
            for _, auraID in ipairs(updateInfo.removedAuraInstanceIDs) do
                removedAuraSet[auraID] = true
            end
        end

        --If an aura has been removed, its possible it was something that could modify a spells cooldown rate. The only way to respond (correctl update the duration and its ModRate, is to reapply, for any active cooldown)
        for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames["spells"]) do
            if customFrame.meta.isDurationActive then
                FrameTrackerManager:DriveFrameUpdate(
                    customFrame,
                    {
                        resolveDuration = true,
                        syncChargeText = true
                    },
                    nil,
                    "respondingToPotentialModRateChange"
                )
            end
        end

        -- Also treat an aura as removed when Blizzard reports a full update
        -- (isFullUpdate = true) — in that case refresh all CDM frames to let
        -- them update their currentAuraInstanceID from the Blizzard frames.
        local isFullUpdate = updateInfo and updateInfo.isFullUpdate
        
        if isFullUpdate then
            -- On full update, call ProcessCDMFrameCallback for each CDM frame to refresh state
            for slotIndex, cdm_frame in pairs(FrameTrackerManager.cooldownManagerFrames["buffs"]) do
                ProcessCDMFrameCallback(cdm_frame, "buffs", "UNIT_AURA_fullUpdate")
            end
        end
        
        -- Handle explicit removals
        for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames["buffs"]) do
            local currentAuraInstanceID = customFrame.meta.currentAuraInstanceID or 0
            local shouldClear = removedAuraSet[currentAuraInstanceID]
            if shouldClear then
                customFrame.meta.currentAuraInstanceID = 0 --clear
                customFrame.meta.buffStatus = 'absent'
                customFrame.cooldown:Clear()
                customFrame.statusBar:SetValue(0)
                FrameTrackerManager:DriveFrameUpdate(
                    customFrame,
                    {
                        resolveDuration = false,
                        syncChargeText = true
                    },
                    nil,
                    "unitAura_explicitRemoval"
                )
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
                if (match.trackerType ~= 'buffs') then
                    --only reapply data for non-buffs. The buffs should be using the hooks to update their data
                    match.customFrame.meta.activeSpellID = C_Spell.GetOverrideSpell(match.baseSpellID)
                    
                    match.customFrame.cooldown:Clear()
                    match.customFrame.cooldown:Hide()
                    FrameTrackerManager:DriveFrameUpdate(
                        match.customFrame,
                        {
                            resolveDuration = true,
                            syncChargeText = true
                        },
                        nil,
                        "spellUpdateIcon"
                    )
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
                    -- Immediately hide and wipe old frames so that events fired
                    -- during the rescan delay don't reach stale frames or look up
                    -- old spells against the already-switched spec DB.
                    FrameTrackerManager:TeardownSpecFrames()
                    C_Timer.After(0.1, function()
                        State:HandleTalentChange()
                    end)
                    return
                end
                local classSpecialization = State:GetCurrentSpecID()
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

                            -- Attempt to update charges if it mutated into a spell with charges
                            -- FrameTrackerManager:renderUpdateChargesText(match)
                            FrameTrackerManager:DriveFrameUpdate(
                                match.customFrame,
                                {
                                    resolveDuration = false,
                                    syncChargeText = true
                                },
                                nil,
                                "unitSpellcastSucceeded_spellOverwritten"
                            )
                        else
                            local spellInfo = C_Spell.GetSpellInfo(spellID)
                            -- FrameTrackerManager:ApplyCooldownDuration(match)
                            FrameTrackerManager:DriveFrameUpdate(
                                match.customFrame,
                                {
                                    resolveDuration = true,
                                    syncChargeText = true
                                },
                                nil,
                                "unitSpellcastSucceeded_spellUnchanged"
                            )
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
                local isActive
                pcall(function()
                    if frameMatchData.customFrame.meta.isSpellWithCharges then
                        isActive = C_Spell.GetSpellCharges(frameMatchData.customFrame.meta.activeSpellID).isActive
                    else
                        isActive = C_Spell.GetSpellCooldown(frameMatchData.customFrame.meta.activeSpellID).isActive
                    end
                end)
                if isActive and frameMatchData.customFrame.meta.trackerType ~= 'buffs' then
                    -- FrameTrackerManager:ApplyCooldownDuration(frameMatchData)
                    FrameTrackerManager:DriveFrameUpdate(
                        frameMatchData.customFrame,
                        {
                            resolveDuration = true,
                            syncChargeText = true
                        },
                        nil,
                        "spellUpdateCooldown_updateOtherSpellsOnCooldown"
                    )
                end

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
                    return
                end
                -- FrameTrackerManager:ApplyCooldownDuration(frameMatchData)
                FrameTrackerManager:DriveFrameUpdate(
                    frameMatchData.customFrame,
                    {
                        resolveDuration = true,
                        syncChargeText = true
                    },
                    nil,
                    "spellUpdateCooldown_updateEventSpell"
                )
            end)
        end
    end
end)

-- ============================================================================
-- GLOBAL VISIBILITY — combat state event frame
-- Fires ApplyGlobalVisibility when the player enters or leaves combat so the
-- "Hide when out of combat" setting takes effect immediately.
-- ============================================================================
local globalVisibilityFrame = CreateFrame("Frame")
globalVisibilityFrame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- entering combat
globalVisibilityFrame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- leaving combat
globalVisibilityFrame:SetScript("OnEvent", function(self, event)
    State:ApplyGlobalVisibility()
end)
