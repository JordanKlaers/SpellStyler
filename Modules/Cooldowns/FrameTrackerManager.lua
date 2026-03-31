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
---@field spellChargeCount number       Max charge count (or 1 for non-charge spells)'moreThenOneChargeOnCooldown'
---@field isDurationActive boolean      true while a real cooldown is running
---@field isSpellOffGCD boolean|nil     true if the spell bypasses the GCD
---@field mockCooldownActive boolean    true while a mock cooldown preview is running (settings UI)
---@field canBeCast boolean             true when not on cooldown with all charges consumed
---@field currentAuraInstanceID number  Instance ID of the currently tracked aura (buffs tracker type)
---@field customTexture string|nil         Custom texture of the icon

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


function FrameTrackerManager:ScanAndSaveCurrentCooldownManagerFrames(trackerType)
    local viewer = FrameTrackerManager:GetCooldownManagerViewer(trackerType)
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
                FrameTrackerManager:CreateTrackerFrame(spellID, trackerConfig, trackerType)
            end
        end
    end

    -- Apply any saved viewer visibility setting
    FrameTrackerManager:ApplyViewerVisibility("buffs")
    FrameTrackerManager:ApplyViewerVisibility("essential")
    FrameTrackerManager:ApplyViewerVisibility("utility")
end


--[[
frame {
    icon
    cooldown
    statusBar
}
]]

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
        trackerType = trackerType,
        buffStatus = 'absent',
        -- This is either the baseSpellID or the override spell id (if it changes into something). Use this value when getting cooldown duration objects.
        activeSpellID = trackerConfig.overrideSpellID or baseSpellID,
        -- This helps in conjunction with spellChargeState || spellChargeCount (spellHasCharges) to control the visibility state for count
        isSpellWithCharges = spellChargesInfo and spellChargesInfo.maxCharges > 1,
        -- experimental direct count tracking
        spellChargeCount = spellChargesInfo and spellChargesInfo.maxCharges or 1,
        -- Used to track if the cooldown is active, so that the cooldowns can be updated in response to other spell casts (Holy Shock can reduce the cooldown of judgment)
        isDurationActive = false,
        -- This helps ensure proper resposne for triggering spell cooldowns for offGCD spells - in "SPELL_UPDATE_COOLDOWN"
        isSpellOffGCD = trackerConfig.iconSettings.isSpellOffGCD or false,
        mockCooldownActive = false,
        -- true when not on cooldown with all charges consumed
        canBeCast = true,
        -- instance ID of the currently tracked aura (buffs only)
        currentAuraInstanceID = 0,
        customTexture = trackerConfig.iconSettings.iconTexturePath ~= '' and trackerConfig.iconSettings.iconTexturePath ~= nil and trackerConfig.iconSettings.iconTexturePath or nil
    }
    
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
    frame.cooldown:SetHideCountdownNumbers(not showCountdownText)
    
    frame.cooldown:SetScript("OnShow", function(self)
        frame.meta.isDurationActive = true
    end)

    frame.cooldown:SetScript("OnHide", function(self)
    end)
    

    frame.cooldown:SetScript("OnCooldownDone", function(self)
        frame.meta.isDurationActive = false
        frame.meta.canBeCast = true
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
        if frame.meta.isSpellOffGCD and frame.meta.isSpellWithCharges then
            frame.meta.spellChargeCount = frame.meta.spellChargeCount + 1
        end

        FrameTrackerManager:SetIconVisibility(frame, trackerConfig.iconSettings.iconDisplayState, frame.meta.activeSpellID)
        FrameTrackerManager:SetStatusBarVisibility({
            activeSpellID = frame.meta.activeSpellID,
            spellID = frame.meta.activeSpellID,
            config = trackerConfig,
            customFrame = frame
        })
    end)
    
    -- Create StatusBar for tracker cooldown progress (secret-value compatible)
    -- This uses the new Midnight API that accepts DurationObjects with secrets
    frame.statusBar = CreateFrame("StatusBar", frameName .. "_StatusBar", frame)
    frame.statusBar:SetPoint(trackerConfig.statusBar.anchorSelf or "LEFT", frame, trackerConfig.statusBar.anchorParent or "RIGHT", trackerConfig.statusBar.x or 0, trackerConfig.statusBar.y or 0)
    local _iconW = trackerConfig.iconSettings.width or trackerConfig.iconSettings.size or 48
    local _iconH = trackerConfig.iconSettings.height or trackerConfig.iconSettings.size or 48
    local statusBarWidth = trackerConfig.statusBar and trackerConfig.statusBar.width or (_iconW * 4)
    local statusBarHeight = trackerConfig.statusBar and trackerConfig.statusBar.height or (_iconH / 2)
    frame.statusBar:SetSize(statusBarWidth, statusBarHeight)
    frame.statusBar:SetScale(trackerConfig.statusBar.scale or 1)
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
    -- Shown by UpdateFrame_Duration _Inactive when isFull, hidden when a real cooldown is active.
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
    
    FrameTrackerManager:SetStatusBarContainerVisibility({
        customFrame = frame,
        config = trackerConfig,
        baseSpellID = baseSpellID,
        activeSpellID = trackerConfig.activeSpellID,
        trackerType = trackerType
    })
    frame.statusBar:Hide()  -- Hidden by default, shown when cooldown is active
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

    -- Initially hidden
    frame:Show()

    frame.cooldown:SetDrawSwipe(not trackerConfig.iconSettings.hideDefaultSweep)
    frame.cooldown:SetDrawEdge(not trackerConfig.iconSettings.hideDefaultSweep)
    frame.cooldown:SetHideCountdownNumbers(not trackerConfig.cooldownText.display)
    
    -- If there is an active cooldown, it will handle calling the show or hide methods for the frame using the cooldown event callbacks
    FrameTrackerManager:ApplyCooldownDuration({
        customFrame = frame,
        config = trackerConfig,
        baseSpellID = baseSpellID,
        activeSpellID = trackerConfig.activeSpellID,
        trackerType = trackerType
    })
    -- Resolve charge count text and icon visibility (was referenced in the comment above but never called)
    FrameTrackerManager:UpdateFrame_copyCharges({
        customFrame = frame,
        config = trackerConfig,
        baseSpellID = baseSpellID,
        activeSpellID = trackerConfig.activeSpellID,
        trackerType = trackerType
    })
    FrameTrackerManager:SetStatusBarVisibility({
        customFrame = frame,
        config = trackerConfig,
        activeSpellID = frame.meta.activeSpellID or trackerConfig.overrideSpellID,
        trackerType = trackerType
    })
    -- Attach the glow animation child based on the current glowNotification config.
    -- PlayAnts / PlayProcGlow are intentionally NOT called here; the caller decides
    -- when to trigger the animation.
    ApplyGlowNotificationSetup(frame, trackerConfig)

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
    for trackerType, frames in pairs(FrameTrackerManager.SpellStyler_frames) do
        for baseSpellID, frame in pairs(frames) do
            if frame and not frame._inContainer then
                frame:EnableMouse(true)
                frame:RegisterForDrag("LeftButton")
                
                frame:SetScript("OnDragStart", function(self)
                    self:StartMoving()
                    -- Notify settings panel that this icon was selected
                    if onFrameClickCallback then
                        onFrameClickCallback(baseSpellID, trackerType)
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
                    
                    State:SetTrackerValueConfigProperty(baseSpellID, trackerType, "position", positionData)
                    
                    -- Verify it was saved
                    local saved = State:GetTrackerValueConfigProperty(baseSpellID, trackerType, "position")
                end)
                
                -- Add click handler to select icon in settings
                frame:SetScript("OnMouseDown", function(self, button)
                    if button == "LeftButton" and onFrameClickCallback then
                        onFrameClickCallback(baseSpellID, trackerType)
                    end
                end)
            end
        end
    end
end

function FrameTrackerManager:DisableDraggingForAllFrames()
    onFrameClickCallback = nil
    
    for trackerType, frames in pairs(FrameTrackerManager.SpellStyler_frames) do
        for baseSpellID, frame in pairs(frames) do
            if frame then
                frame:EnableMouse(false)
                frame:RegisterForDrag()
                frame:SetScript("OnDragStart", nil)
                frame:SetScript("OnDragStop",  nil)
                frame:SetScript("OnMouseDown", nil)
                
                -- Hide the drag border indicator
                if frame._SpellStyler_dragBorder then
                    frame._SpellStyler_dragBorder:Hide()
                end
            end
        end
    end
end

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

function FrameTrackerManager:ToggleMockCooldown(baseSpellID, trackerType)
    local frame = FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    if not frame then
        return
    end
    
    -- Check if mock cooldown is currently active
    local isMockActive = frame.meta.mockCooldownActive or false
    if isMockActive then
        -- Disable mock cooldown
        frame.meta.mockCooldownActive = false
        if frame.cooldown then
            frame.cooldown:Clear()
        end
        if frame.statusBar then
            local mockDurationObj = C_DurationUtil.CreateDuration()
            mockDurationObj:SetTimeFromEnd(GetTime(), 0.001)
            frame.statusBar:SetTimerDuration(
                mockDurationObj,
                Enum.StatusBarInterpolation.Immediate,
                Enum.StatusBarTimerDirection.RemainingTime
            )
        end
        frame.meta.buffStatus = 'absent'
        FrameTrackerManager:SetStatusBarVisibility({
            customFrame = frame,
            activeSpellID = frame.meta.activeSpellID,
            trackerType = trackerType,
            config = State:GetSpecificTrackerValue(baseSpellID, trackerType),
        })
    else
        -- Enable mock cooldown (15 second duration)
        frame.meta.mockCooldownActive = true
        frame.meta.buffStatus = 'active'
        local mockDuration = 15
        local now = GetTime()
        
        -- Create a proper DurationObject for Apply Cooldown Duration()
        local mockDurationObj = C_DurationUtil.CreateDuration()
        mockDurationObj:SetTimeFromStart(now, mockDuration)
        local config = State:GetSpecificTrackerValue(baseSpellID, trackerType)
        FrameTrackerManager:ApplyCooldownDuration({
            customFrame = frame,
            baseSpellID = baseSpellID,
            trackerType = trackerType,
            activeSpellID = config.activeSpellID,
            config = config,
            durationObject = mockDurationObj
        })
    end
end

function FrameTrackerManager:BrieflyHighlightFrame(baseSpellID, trackerType)
    local f = FrameTrackerManager.SpellStyler_frames and FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
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

function FrameTrackerManager:UpdateFrame_ConfigurationChanges(baseSpellID, trackerType)
    local trackerConfig = State:GetSpecificTrackerValue(baseSpellID, trackerType)
    local frame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    -- Update icon texture
    local customTexture = (trackerConfig.iconSettings.iconTexturePath ~= "" and trackerConfig.iconSettings.iconTexturePath)
    local texture = customTexture or frame.updatedIconID or trackerConfig.defaultIconTexturePath
    frame.icon:SetTexture(texture)
    
    -- Update icon color
    local _, insufficientPower = C_Spell.IsSpellUsable(frame.meta.activeSpellID)
    local color = (insufficientPower and trackerConfig.iconSettings.insufficientPower and trackerConfig.iconSettings.insufficientPowerIconColor)
        or trackerConfig.iconColor or {}
    frame.icon:SetVertexColor(
        color.r or 1,
        color.g or 1,
        color.b or 1,
        color.a or 1
    )
    
    frame.cooldown:SetDrawSwipe(not trackerConfig.iconSettings.hideDefaultSweep)
    frame.cooldown:SetDrawEdge(not trackerConfig.iconSettings.hideDefaultSweep)
    frame.cooldown:SetHideCountdownNumbers(not trackerConfig.cooldownText.display)

    -- Update size (skip when the frame is managed by a container; LayoutContainer controls its size)
    if not frame._inContainer then
        local iconW = trackerConfig.iconSettings.width or trackerConfig.iconSettings.size or 48
        local iconH = trackerConfig.iconSettings.height or trackerConfig.iconSettings.size or 48
        frame:SetSize(iconW, iconH)
    end

    -- Re-attach the glow animation child with the latest glowNotification config.
    -- This reconstructs the glow child (colour, style, scale) without starting it.
    ApplyGlowNotificationSetup(frame, trackerConfig)

    -- Update opacity
    frame:SetAlpha(trackerConfig.iconSettings.opacity or 1)

    -- Update frame strata and level
    frame:SetFrameStrata(trackerConfig.iconSettings.frameStrataLevel or "MEDIUM")
    frame:SetFrameLevel(trackerConfig.iconSettings.frameStrataValue or 100)

    -- Update off-GCD flag; also seed the runtime cache so the event handler
    -- doesn't need to wait for the first cast to know this spell bypasses the GCD.
    frame.meta.isSpellOffGCD = trackerConfig.iconSettings.isSpellOffGCD or false
        
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
            local _iconW = trackerConfig.iconSettings.width or trackerConfig.iconSettings.size or 48
            local _iconH = trackerConfig.iconSettings.height or trackerConfig.iconSettings.size or 48
            local statusBarWidth = trackerConfig.statusBar.width or (_iconW * 4)
            local statusBarHeight = trackerConfig.statusBar.height or _iconH
            frame.statusBar:SetSize(statusBarWidth, statusBarHeight)

            -- Fill direction is driven by TimerDirection in SetTimerDuration; no fill-anchor reversal needed
            frame.statusBar:SetReverseFill(false)
            frame.statusBar:SetOrientation(
                (trackerConfig.statusBar.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL"
            )

            -- Apply fill style (progressDirection) immediately so a settings change is reflected live
            local fillStyle = (trackerConfig and trackerConfig.statusBar and trackerConfig.statusBar.progressDirection == 'reverse')
            local textureRotation = (trackerConfig and trackerConfig.statusBar and trackerConfig.statusBar.textureRotation or 0)
            if textureRotation then
                frame.statusBar:RotateTextures(textureRotation)
            end
            frame.statusBar:SetFillStyle(fillStyle and Enum.StatusBarFillStyle.Reverse or Enum.StatusBarFillStyle.Standard)

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
        FrameTrackerManager:SetStatusBarContainerVisibility({
            baseSpellID = baseSpellID,
            trackerType = trackerType,
            activeSpellID = trackerConfig.activeSpellID,
            config = trackerConfig,
            customFrame = frame
        })
    end
    
    -- Update position
    local pos = trackerConfig.position
    if pos and pos.anchorPoint and not frame._inContainer then
        frame:ClearAllPoints()
        frame:SetPoint(
            pos.anchorPoint, 
            UIParent,
            pos.relativeAnchorPoint or pos.anchorPoint, 
            pos.x or 0, 
            pos.y or 0
        )
    end

    -- Re-apply the timer duration with the latest fillOrEmpty direction and progressDirection.
    -- ApplyCooldownDuration returns immediately when no active duration object is available,
    -- so this is safe to call unconditionally here.
    FrameTrackerManager:ApplyCooldownDuration({
        customFrame = frame,
        config = trackerConfig,
        baseSpellID = baseSpellID,
        activeSpellID = trackerConfig.activeSpellID,
        trackerType = trackerType
    })

    FrameTrackerManager:UpdateFrame_copyCharges({
        customFrame = frame,
        config = trackerConfig,
        baseSpellID = baseSpellID,
        activeSpellID = trackerConfig.activeSpellID,
        trackerType = trackerType
    })
    FrameTrackerManager:SetStatusBarVisibility({
        customFrame = frame,
        config = trackerConfig,
        activeSpellID = trackerConfig.activeSpellID,
        trackerType = trackerType
    })
end




--- @param data ApplyCooldownDurationData
function FrameTrackerManager:UpdateFrame_copyCharges(data)

    if not data.customFrame or not data.config then return end
    if data.customFrame.meta.trackerType == 'buffs' then
        if data.config.countText.display and data.customFrame.meta.currentAuraInstanceID ~= 0 and data.customFrame.meta.currentAuraInstanceID ~= nil then
            data.customFrame.count:SetText(C_UnitAuras.GetAuraApplicationDisplayCount("player", data.customFrame.meta.currentAuraInstanceID, 1))
            data.customFrame.count:Show()
        else
            data.customFrame.count:Hide()
        end
        return
    end
    local charges = C_Spell.GetSpellCharges(data.customFrame.meta.activeSpellID) or {}
    -- If display charges is disabled in the settings, or this is an OffGCD spell with no available charge, or the spell has mutated, is on cooldown AND can be cast (that would mean it turned into a spell with charges and it has 1 charge available and 1 on cooldown. This only works with 2 charges)
    -- Those should all cover zero or 1 charges
    local spellInfo = C_Spell.GetSpellInfo(data.customFrame.meta.activeSpellID)
    if not data.config.countText.display
        or (data.customFrame.meta.isSpellOffGCD == true and data.customFrame.meta.spellChargeCount < 2)
        or (
            -- original spell and doesnt have charges
            data.activeSpellID == data.customFrame.meta.activeSpellID
            and not data.customFrame.meta.isSpellWithCharges
        ) then
        data.customFrame.count:SetText("")
        data.customFrame.count:Hide()
        -- dont forget to control the icon visibility with conditions before exiting early.
        FrameTrackerManager:SetIconVisibility(data.customFrame, data.config.iconSettings.iconDisplayState, data.customFrame.meta.activeSpellID)
        return
    else
        data.customFrame.count:Show()
    end

    
    local success, error = pcall(function()
        local countCfg = data.config.countText
        if countCfg then
            local fontPath, _, fontFlags = data.customFrame.count:GetFont()
            if fontPath and countCfg.size then
                data.customFrame.count:SetFont(fontPath, countCfg.size, fontFlags or "OUTLINE")
            end
            if countCfg.color then
                data.customFrame.count:SetTextColor(
                    countCfg.color.r or 1,
                    countCfg.color.g or 1,
                    countCfg.color.b or 1,
                    countCfg.color.a or 1
                )
            end
            data.customFrame.count:ClearAllPoints()
            data.customFrame.count:SetPoint("BOTTOMRIGHT", data.customFrame, "BOTTOMRIGHT",
                (countCfg.x or 0) - 2,
                (countCfg.y or 0) + 2)
        end
    end)
    local suc, err = pcall(function()
        data.customFrame.count:SetText(charges.currentCharges or 1)
        data.customFrame.count:SetAlpha(charges.currentCharges or 1)
        FrameTrackerManager:SetIconVisibility(data.customFrame, data.config.iconSettings.iconDisplayState, data.customFrame.meta.activeSpellID)
    end)
end


-- Set up hooks on BuffIconCooldownViewer to mirror cooldown updates
function FrameTrackerManager:SetupCooldownManagerHooks()
    local viewer = FrameTrackerManager:GetCooldownManagerViewer("buffs")
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
            if FrameTrackerManager:GetViewerHidden("buffs") and alpha ~= 0 then
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



-- ============================================================================
-- SPELL Cooldown Tracking
-- ============================================================================





--- Resolves the baseSpellID (DB key) for a Blizzard CDM frame using a stable
--- priority chain, replacing the old ResolveLiveCDMSpellID approach.
---
--- Priority order:
---   1. cooldownIDToBaseSpellID[GetCooldownID()] – slot-based,
---      recorded at scan time and never mutated at runtime.
---   2. live GetSpellID()  – last resort; unreliable once the buff
---      is active (Blizzard returns a different ID at that point).
---
--- @param sourceFrame table  The Blizzard CDM frame to resolve for
--- @return number|nil        The resolved baseSpellID, or nil if unresolvable
local function ResolveCDMBaseSpellID(sourceFrame)
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

-- Hook all buffs icon cooldowns to mirror to per-icon frames
function FrameTrackerManager:HookAllBuffCooldownFrames(trackerType)
    
    local viewer = FrameTrackerManager:GetCooldownManagerViewer(trackerType)
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
            
            local function hookCallback(self, donk, a)
                local baseSpellID = ResolveCDMBaseSpellID(self)
                local classSpecialization = State:GetCurrentSpecID()
                --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
                local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
                if hasSpecialization and baseSpellID and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] then
                    if trackerType == "buffs" then
                        pcall(function()
                            --if the icon does NOT have a custom texture, then update it dynamically
                            if not FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID].meta.customTexture then
                                local frame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                                local icon = self.Icon or self.icon
                                local texture = (icon.GetTexture and icon:GetTexture()) or icon.texture or self.spellStyler_texture
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
                        local isFull = config.statusBar.defaultFillValue == 'full'
                        if frame.statusBar.fullCoverTexture then
                            frame.statusBar.fullCoverTexture:Show()
                            if isFull then
                                local c = config.statusBar.color
                                frame.statusBar.fullCoverTexture:SetVertexColor(c.r or 0.2, c.g or 0.8, c.b or 1, c.a or 0.9)
                                frame.statusBar.fullCoverTexture:SetAlpha(1)
                            else
                                frame.statusBar.fullCoverTexture:SetAlpha(0)
                                -- frame.statusBar.fullCoverTexture:Hide()
                            end
                        end
                        FrameTrackerManager:ApplyCooldownDuration({
                            customFrame = frame,
                            baseSpellID = baseSpellID,
                            trackerType = "buffs",
                            config = config,
                            activeSpellID = frame.meta.activeSpellID
                        })
                        FrameTrackerManager:UpdateFrame_copyCharges({
                            baseSpellID = baseSpellID,
                            customFrame = frame,
                            spellID = baseSpellID,
                            activeSpellID = frame.meta.activeSpellID,
                            trackerType = 'buffs',
                            config = config
                        })
                    end
                end
            end

            if cdm_frame.RefreshApplications then hooksecurefunc(cdm_frame, "RefreshApplications", function(self) hookCallback(self, 'RefreshApplications') end) end
            if cdm_frame.RefreshActive then hooksecurefunc(cdm_frame, "RefreshActive", function(self) hookCallback(self, 'RefreshActive') end) end
            if cdm_frame.UpdateShownState then hooksecurefunc(cdm_frame, "UpdateShownState", function(self) hookCallback(self, 'UpdateShownState') end) end

            local sourceCooldown = cdm_frame.Cooldown or cdm_frame.cooldown

            local donkFrame
            if sourceCooldown and not cdm_frame.hasHookedCooldown then
                cdm_frame.hasHookedCooldown = true
                hooksecurefunc(sourceCooldown, "SetCooldown", function(self, start, duration)
                    local classSpecialization = State:GetCurrentSpecID()
                    --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
                    local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
                    if not hasSpecialization then return end
                    local baseSpellID = ResolveCDMBaseSpellID(cdm_frame)
                    local customFrame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                    if not customFrame then return end
                    if trackerType ~= "buffs" then return end  
                    --TODO: Add a setting if you want to "Set buff active as status bar full" which should result in THIS handling the status bar, rather than duration inactive or w/e 
                    customFrame.meta.currentAuraInstanceID = cdm_frame:GetAuraSpellInstanceID() or 0
                    if customFrame.meta.currentAuraInstanceID ~= 0 then
                        customFrame.meta.buffStatus = 'present'
                    else
                        customFrame.meta.buffStatus = 'absent'
                    end
                    local config = State:GetSpecificTrackerValue(baseSpellID, trackerType)
                    -- Apply the duration object to the cooldown frame
                    FrameTrackerManager:ApplyCooldownDuration({
                        customFrame = customFrame,
                        baseSpellID = baseSpellID,
                        trackerType = "buffs",
                        activeSpellID = customFrame.meta.activeSpellID,
                        config = config
                    })
                    FrameTrackerManager:UpdateFrame_copyCharges({
                        baseSpellID = baseSpellID,
                        customFrame = customFrame,
                        spellID = baseSpellID,
                        activeSpellID = customFrame.meta.activeSpellID,
                        trackerType = 'buffs',
                        config = config
                    })
                end)
            end
        end
    end
end

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
                    FrameTrackerManager:CreateTrackerFrame(baseSpellID, trackerConfig, trackerType)
                end
            end
        end
    end
end

function FrameTrackerManager:Initalize()
    if isInitialized or not hasPlayerEnetedWorld then return end
    isInitialized = true

    FrameTrackerManager:SetupCooldownManagerHooks()
    FrameTrackerManager:CreateNonBuffTrackerFrames()
    C_Timer.After(3, function()
        -- Re-setup hooks in case viewer was recreated
        FrameTrackerManager:SetupCooldownManagerHooks()
        FrameTrackerManager:CreateNonBuffTrackerFrames()
    end)
end



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
            -- The spell and buff share the same spellID, so C_Spell.GetSpellChargeDuration /
            -- C_Spell.GetSpellCooldownDuration here would return the *spell's* cooldown object
            -- instead of the buff's aura duration, causing cross-tracker contamination.
            -- Valid aura durations are always pre-resolved by the Blizzard frame hooks
            -- (hookCallback / SetCooldown hook).  When no live aura is present, bail out
            -- so we don't stamp stale spell-cooldown data onto the buffs frame.
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
                    durationObject = C_Spell.GetSpellChargeDuration(data.customFrame.meta.activeSpellID or data.activeSpellID)
                else
                    durationObject = C_Spell.GetSpellCooldownDuration(data.customFrame.meta.activeSpellID or data.activeSpellID)
                end
            end)
        end
    end
    if data.forceUpdate then
        data.customFrame.cooldown:Clear()
        data.customFrame.statusBar:SetValue(0)
    end
    if e or not durationObject then
        -- Still need to update the visibility if no duration is active
        FrameTrackerManager:SetIconVisibility(data.customFrame, data.config.iconSettings.iconDisplayState, data.customFrame.meta.activeSpellID or data.activeSpellID)
        FrameTrackerManager:SetStatusBarVisibility(data)
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
    

    data.customFrame.meta.buffStatus = 'active'
    local isZero = durationObject and durationObject.IsZero and durationObject:IsZero()
    local isSecret = issecretvalue(isZero)
    if not isSecret and isZero then
        data.customFrame.meta.buffStatus = 'present'
    end
    data.customFrame.cooldown:SetCooldownFromDurationObject(durationObject)
    
    FrameTrackerManager:SetIconVisibility(data.customFrame, data.config.iconSettings.iconDisplayState, data.customFrame.meta.activeSpellID)
    FrameTrackerManager:SetStatusBarVisibility(data)
end



--- Applies secret-value alpha–based icon visibility for spells with charges.
--- Must be called after the binary Show/Hide decision so it can override it.
--- 'active'/'cooldown' states are intentionally skipped: those states want the
--- icon visible when all charges are consumed (canBeCast=false), which the
--- binary showSpellIcon path already handles correctly via canBeCast logic.
--- @param frame table            The tracker frame
--- @param iconDisplayState string The configured iconDisplayState setting
--- @param activeSpellID number   The active spell ID to query charges for
function FrameTrackerManager:SetIconVisibility(frame, iconDisplayState, activeSpellID)
    frame.icon:Show()
    if iconDisplayState == 'always' then
        frame.icon:SetAlpha(1)
    elseif iconDisplayState == 'never' then
        frame.icon:SetAlpha(0)
    elseif iconDisplayState == 'inactive' or iconDisplayState == 'available' then
        if frame.meta.trackerType == 'buffs' then
            local buffAlpha = (frame.meta.currentAuraInstanceID == 0 or frame.meta.currentAuraInstanceID == nil) and 1 or 0
            -- If the buff is inactive, the icon will be visible
            frame.icon:SetAlpha(buffAlpha)
        else
            local spellCooldownInfo = C_Spell.GetSpellCooldown(activeSpellID)
            if not spellCooldownInfo.isActive then
                frame.icon:SetAlpha(1)
            else
                local charges = C_Spell.GetSpellCharges(activeSpellID) or {}
                if charges.currentCharges ~= nil then
                    -- 1 or more charges means the spells is available to cast and will be visible - for iconDisplayState == 'available'
                    frame.icon:SetAlpha(charges.currentCharges)
                else
                    -- if the duration is active, check if its the GCD to attempt to "ignore" it by displaying the icon
                    local durationEqualToGCD    = SpellStyler.Util:IsValidCooldownCurve()
                    local alpha =  C_Spell.GetSpellCooldownDuration(activeSpellID):EvaluateRemainingDuration(durationEqualToGCD)
                    -- If the remaining duration IS the same as the GCD, that basically means the spell is avilable to cast, so it will be visible, otherwise alpha would be zero, thus hiding the icon
                    frame.icon:SetAlpha(alpha)
                end
                -- frame.icon:SetAlpha(0)
            end
        end
    elseif iconDisplayState == 'active' or iconDisplayState == 'cooldown' then
        if frame.meta.trackerType == 'buffs' then
            local buffAlpha = ((frame.meta.currentAuraInstanceID ~= 0 and frame.meta.currentAuraInstanceID ~= nil)) and 1 or 0
            -- If the buff is inactive, the icon will be visible
            frame.icon:SetAlpha(buffAlpha)
        else
            local spellCooldownInfo = C_Spell.GetSpellCooldown(activeSpellID)
            if not spellCooldownInfo.isActive then
                frame.icon:SetAlpha(0)
            else
                -- frame.icon:SetAlpha(1)
                local durationNOTEqualToGCD    = SpellStyler.Util:IsValidCooldownCurve(true)
                local durationObj = nil
                pcall(function()
                    local maxSpellCharges = 1
                    local spellChargeInfo = C_Spell.GetSpellCharges(activeSpellID)
                    if spellChargeInfo and spellChargeInfo.maxCharges then
                        maxSpellCharges = spellChargeInfo.maxCharges
                    end
                    if maxSpellCharges > 1 then
                        durationObj = C_Spell.GetSpellChargeDuration(activeSpellID)
                    else
                        durationObj = C_Spell.GetSpellCooldownDuration(activeSpellID)
                    end
                end)
                local alpha = durationObj and durationObj:EvaluateRemainingDuration(durationNOTEqualToGCD) or 0
                -- If the remaining duration IS the same as the GCD, that basically means the spell is avilable to cast, so it will be visible, otherwise alpha would be zero, thus hiding the icon
                frame.icon:SetAlpha(alpha)
            end


            --cant use charges for this setting because they are secret and can not be inversed (having no charges means the spells MUST be on cooldown, but that value of 0 would make it hidden)
        end
    end
end


--TODO: Remove the "available" and "inactive" settings from statusbars - doesnt make sense to have this setting
function FrameTrackerManager:SetStatusBarVisibility(data)
    --[[
        Variables to consider
            - Always Show setting
            - Never show setting
            - OnCooldown/Active setting
    ]]
    local fullBarAlpha        = nil --alpha_overlayBar = nil
    local statusBarAlpha      = nil    
    local gcdCurve            = SpellStyler.Util:IsValidCooldownCurve()     -- if the comparison == GCD then return 1
    local gcdCurve_inverse    = SpellStyler.Util:IsValidCooldownCurve(true) -- if the comparison == GCD then return 0
    local isZeroCurve         = SpellStyler.Util:IsZeroDurationCurve()
    local isZeroCurve_inverse = SpellStyler.Util:IsZeroDurationCurve(true)
    local isFull = data.config
                and data.config.statusBar
                and data.config.statusBar.defaultFillValue == 'full'
    local durationObj = nil
    local s, e = pcall(function()
        pcall(function()
            if data.config.trackerType == 'buffs' then
                local auraID = data.customFrame.meta.currentAuraInstanceID
                if auraID and auraID ~= 0 then
                    local s, e = pcall(function()
                        durationObj = C_UnitAuras.GetAuraDuration("player", auraID)
                        if not durationObj then
                            durationObj = C_UnitAuras.GetAuraDuration("target", auraID)
                        end
                    end)
                end
            else
                local maxSpellCharges = 1
                local spellChargeInfo = C_Spell.GetSpellCharges(data.customFrame.meta.activeSpellID)
                if spellChargeInfo and spellChargeInfo.maxCharges then
                    maxSpellCharges = spellChargeInfo.maxCharges
                end
                if maxSpellCharges > 1 then
                    durationObj = C_Spell.GetSpellChargeDuration(data.customFrame.meta.activeSpellID)
                else
                    durationObj = C_Spell.GetSpellCooldownDuration(data.customFrame.meta.activeSpellID)
                end
            end
        end)
        if data.config.statusBar.displayState == 'always' 
            or data.config.statusBar.displayState == 'cooldown'
            or data.config.statusBar.displayState == 'active'
            or data.customFrame.meta.mockCooldownActive
        then
            if data.customFrame.meta.mockCooldownActive then
                fullBarAlpha = 0
                statusBarAlpha = 1
            elseif data.config.trackerType == 'buffs' then
                if data.customFrame.meta.buffStatus == 'absent' then
                    fullBarAlpha = data.config.statusBar.displayState == 'always' and isFull and 1 or 0
                    statusBarAlpha = 0
                else
                    fullBarAlpha = durationObj and durationObj:EvaluateRemainingDuration(isZeroCurve) or 0
                    statusBarAlpha = durationObj and durationObj:EvaluateRemainingDuration(isZeroCurve_inverse) or 1
                end
            elseif durationObj ~= nil then
                fullBarAlpha = durationObj:EvaluateRemainingDuration(gcdCurve)
                statusBarAlpha = durationObj:EvaluateRemainingDuration(gcdCurve_inverse)
            end
        elseif data.config.statusBar.displayState == 'never' then
            fullBarAlpha = 0
            statusBarAlpha = 0
        end
    end)
    local a, b = pcall(function()
        if data.customFrame.statusBar then
            
            -- If its always show, or its
            if data.config.statusBar.displayState == 'always'
                or (
                    (data.config.statusBar.displayState == 'cooldown' or data.config.statusBar.displayState == 'active')
                    and (
                        (data.customFrame.meta.isDurationActive and data.trackerType ~= 'buffs')
                        or ((data.customFrame.meta.buffStatus == 'active' or data.customFrame.meta.buffStatus == 'present') and data.trackerType == 'buffs')
                        or data.customFrame.meta.mockCooldownActive
                    )
                ) then
                data.customFrame.statusBar.fullCoverTexture:Show()
                data.customFrame.statusBar:SetAlpha(1)
                data.customFrame.statusBar:Show()
                if isFull then
                    -- Try to set the alpha over the overlay bar. If using the duraiton object, this will dynamically try to hide or show the overlay and statusBar to essetially not render the GCD. This might cause the cooldown to appear to "skip" to a compelted state, but thats better than it rendering the GCD (potentially over and over)
                    if data.customFrame.statusBar.fullCoverTexture then
                        local c = data.config.statusBar.color
                        data.customFrame.statusBar.fullCoverTexture:SetVertexColor(
                            data.config.statusBar.color.r,
                            data.config.statusBar.color.g,
                            data.config.statusBar.color.b,
                            1
                        )

                        data.customFrame.statusBar.fullCoverTexture:SetAlpha(fullBarAlpha)
                    end
                else
                    data.customFrame.statusBar.fullCoverTexture:SetAlpha(0)
                end
                -- Suppress the bar during GCD by tying its alpha to the curve.
                data.customFrame.statusBar:SetStatusBarColor(
                    data.config.statusBar.color.r or 0.2,
                    data.config.statusBar.color.g or 0.8,
                    data.config.statusBar.color.b or 1,
                    statusBarAlpha
                )
            else
                -- never display
                data.customFrame.statusBar:SetAlpha(0)
                data.customFrame.statusBar.fullCoverTexture:SetAlpha(0)
            end
        end
    end)
end


-- When onlyRenderBar is true, hides bg/glow/border by zeroing their alpha.
-- When false, restores each element to its correct config alpha via SetVertexColor.
-- The main fill (SetStatusBarTexture) is never touched.

--- @param data ApplyCooldownDurationData
function FrameTrackerManager:SetStatusBarContainerVisibility(data)
    if not data.customFrame.statusBar then return end
    local onlyBar = data.config.statusBar.onlyRenderBar

    -- Background texture uses backgroundColor
    if data.customFrame.statusBar.bgTexture then
        local c = data.config.statusBar.backgroundColor
        data.customFrame.statusBar.bgTexture:SetVertexColor(c.r or 0, c.g or 0, c.b or 0, onlyBar and 0 or (c.a or 0.65))
    end

    -- Glow overlay uses glowColor
    if data.customFrame.statusBar.glowTexture then
        local c = data.config.statusBar.glowColor
        data.customFrame.statusBar.glowTexture:SetVertexColor(c.r or 1, c.g or 1, c.b or 1, onlyBar and 0 or (c.a or 0.25))
    end

    -- All 8 border pieces use borderColor
    local bc = data.config.statusBar.borderColor
    local br, bg, bb = bc.r or 0, bc.g or 0, bc.b or 0
    local ba = onlyBar and 0 or (bc.a or 1)
    if data.customFrame.statusBar.borderCornerTL then data.customFrame.statusBar.borderCornerTL:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderCornerTR then data.customFrame.statusBar.borderCornerTR:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderCornerBR then data.customFrame.statusBar.borderCornerBR:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderCornerBL then data.customFrame.statusBar.borderCornerBL:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderEdgeTop    then data.customFrame.statusBar.borderEdgeTop:SetVertexColor(br, bg, bb, ba)    end
    if data.customFrame.statusBar.borderEdgeRight  then data.customFrame.statusBar.borderEdgeRight:SetVertexColor(br, bg, bb, ba)  end
    if data.customFrame.statusBar.borderEdgeBottom then data.customFrame.statusBar.borderEdgeBottom:SetVertexColor(br, bg, bb, ba) end
    if data.customFrame.statusBar.borderEdgeLeft   then data.customFrame.statusBar.borderEdgeLeft:SetVertexColor(br, bg, bb, ba)   end
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
                            customFrame.meta.spellChargeCount = spellChargesInfo and spellChargesInfo.maxCharges or 1
                            FrameTrackerManager:UpdateFrame_copyCharges({
                                baseSpellID = baseSpellID,
                                customFrame = customFrame,
                                activeSpellID = customFrame.meta.activeSpellID or config.overrideSpellID,
                                spellID = baseSpellID,
                                trackerType = tType,
                                config = config
                            })
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

    if event == "SPELL_UPDATE_CHARGES" then
        for _, tType in ipairs({"essential", "utility", "spells"}) do
            if FrameTrackerManager.SpellStyler_frames[tType] then
                for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                    local match = FrameTrackerManager:MatchTrackerFrame(baseSpellID)
                    if match then
                        -- clear any active cooldown and reapply (This helps when a spell gains its final charge in the middle of a cooldown. It will clear, rather than compeltely the cooldown duration that means nothing at that point)
                        if match.customFrame and match.customFrame.cooldown then match.customFrame.cooldown:Clear() end
                        if match.customFrame and match.customFrame.statusBar then match.customFrame.statusBar:SetValue(0) end
                        FrameTrackerManager:ApplyCooldownDuration(match)
                        FrameTrackerManager:UpdateFrame_copyCharges(match)
                    end
                end
            end
        end
    end
    if event == "UNIT_POWER_UPDATE" then
        local unitTarget, powerType = ...
        if unitTarget == "player" then
            for _, tType in ipairs({"spells", "buffs"}) do
                if FrameTrackerManager.SpellStyler_frames[tType] then
                    for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                        local config = SpellStyler.State:GetSpecificTrackerValue(baseSpellID, tType)
                        if config.iconSettings.insufficientPower then
                            local _, insufficientPower = C_Spell.IsSpellUsable(customFrame.meta.activeSpellID)
                            if tType == "buffs" then DevTool:AddData({insufficientPower = insufficientPower}, "spell - " .. customFrame.meta.activeSpellID) end
                            local color = (insufficientPower and config.iconSettings.insufficientPower and config.iconSettings.insufficientPowerIconColor)
                                or config.iconColor or {}
                            customFrame.icon:SetVertexColor(
                                color.r or 1,
                                color.g or 1,
                                color.b or 1,
                                color.a or 1
                            )
                            FrameTrackerManager:SetIconVisibility(customFrame, config.iconSettings.iconDisplayState, customFrame.meta.activeSpellID)
                        end
                    end
                end
            end
        end
    end
    if event == "SPELL_UPDATE_USABLE" then
        for _, tType in ipairs({"spells"}) do
            if FrameTrackerManager.SpellStyler_frames[tType] then
                for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                    local match = FrameTrackerManager:MatchTrackerFrame(baseSpellID)
                    if match then
                        local spellCooldownInfo = C_Spell.GetSpellCooldown(match.customFrame.meta.activeSpellID)
                        if not spellCooldownInfo.isActive then
                            if match.customFrame and match.customFrame.cooldown then match.customFrame.cooldown:Clear() end
                            if match.customFrame and match.customFrame.statusBar then match.customFrame.statusBar:SetValue(0) end    
                            FrameTrackerManager:SetIconVisibility(match.customFrame, match.config.iconSettings.iconDisplayState, match.customFrame.meta.activeSpellID or match.activeSpellID)
                            FrameTrackerManager:SetStatusBarVisibility(match)
                            FrameTrackerManager:UpdateFrame_copyCharges(match)
                            return
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
        -- Also treat an aura as removed when Blizzard reports a full update
        -- (isFullUpdate = true) — in that case any active tracked aura that is
        -- no longer present in the live aura data should be cleared.
        local isFullUpdate = updateInfo and updateInfo.isFullUpdate
        
        for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames["buffs"]) do
            local currentAuraInstanceID = customFrame.meta.currentAuraInstanceID or 0
            local shouldClear = removedAuraSet[currentAuraInstanceID]
            -- On a full update, verify the tracked aura still exists; clear if not.
            if not shouldClear and isFullUpdate and currentAuraInstanceID ~= 0 then
                local stillActive = C_UnitAuras.GetAuraDataByAuraInstanceID("player", currentAuraInstanceID)
                if not stillActive then
                    shouldClear = true
                end
            end
            if shouldClear then
                customFrame.meta.currentAuraInstanceID = 0 --clear
                customFrame.meta.buffStatus = 'absent'
                customFrame.cooldown:Clear()
                customFrame.statusBar:SetValue(0)
                local config = State:GetSpecificTrackerValue(baseSpellID, 'buffs')
                FrameTrackerManager:SetIconVisibility(
                    customFrame,
                    config.iconSettings.iconDisplayState,
                    customFrame.meta.activeSpellID or baseSpellID
                )
                FrameTrackerManager:SetStatusBarVisibility({
                    activeSpellID = customFrame.meta.activeSpellID,
                    customFrame = customFrame,
                    trackerType = 'buffs',
                    config = config
                })
                FrameTrackerManager:UpdateFrame_copyCharges({
                    baseSpellID = baseSpellID,
                    activeSpellID = baseSpellID,
                    customFrame = customFrame,
                    spellID = baseSpellID,
                    trackerType = 'buffs',
                    config = config
                })
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
                    -- When the spell Icon changes, its possible the spell itsself has changed. Clear any active cooldown and attempt to reapply. This might be effective like when crusader strike changes back into avenging crusader (which would still be on cooldown)
                    FrameTrackerManager:ApplyCooldownDuration(match)
                    -- If the spell mutates back into the original, its possible the cooldown frame show/hide events dont fire if the mutated spell was on cooldown when it changes back to the original. Doube check is "isDurationActive" to call the method if needed
                    if match.customFrame.meta.isDurationActive then
                        FrameTrackerManager:UpdateFrame_Duration_Active(match)
                    end
                    -- Re-evaluate the charge count text last. UpdateFrame_Duration_Active can call
                    -- frame.count:Show() unconditionally, which would leave stale charge text (e.g. "2"
                    -- from Crusader Strike) visible after the spell reverts to its chargeless original.
                    FrameTrackerManager:UpdateFrame_copyCharges(match)
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
                            FrameTrackerManager:UpdateFrame_copyCharges(match)
                        else
                            local spellInfo = C_Spell.GetSpellInfo(spellID)
                            FrameTrackerManager:ApplyCooldownDuration(match)
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
                if frameMatchData.customFrame.meta.isDurationActive and frameMatchData.customFrame.meta.trackerType ~= 'buffs' then
                    FrameTrackerManager:ApplyCooldownDuration(frameMatchData)
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

                if (frameMatchData.customFrame.meta.isSpellOffGCD == true) and frameMatchData.customFrame.meta.isSpellWithCharges then
                    --[[
                        ignore off GCD spells with charges. This event cant destinguish if the spell still have available charges.
                        Attempt to Manually track charges - If anyone reports an error with charges - check if the spell is off GCD - if so, change to using "SPELL_UPDATE_CHARGES" and SetAlpha to controll visibility
                        Also set on the frame the type of spell this is
                    ]]
                    frameMatchData.customFrame.meta.isSpellOffGCD = true
                    frameMatchData.customFrame.meta.spellChargeCount = frameMatchData.customFrame.meta.spellChargeCount - 1
                    if frameMatchData.customFrame.meta.spellChargeCount == 0 then
                        frameMatchData.customFrame.meta.canBeCast = false    
                    end
                else
                    -- If the spell is on GCD, but cooldownInfo.isOnGCD == false, then it was a valid cast, or its off the gcd but can only be cast once.
                    frameMatchData.customFrame.meta.canBeCast = false
                end
                FrameTrackerManager:ApplyCooldownDuration(frameMatchData)
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
