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


FrameTrackerManager.cooldownManagerFrames = {
    buffs = {}
}

FrameTrackerManager.cooldownIDToBaseSpellID = {}

FrameTrackerManager.SpellStyler_frames = {
    buffs = {},
    spells = {},
}

FrameTrackerManager._driveQueue     = {}
FrameTrackerManager._processCDMQueue = {}
FrameTrackerManager._totemLogQueue  = {}

local isInitialized = false

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

--- Check if a trackerConfig has any conditionals that use charges
--- @param trackerConfig table The tracker configuration to check
--- @return boolean True if any conditional uses charges
local function TrackerHasChargesConditionals(trackerConfig)
    if not trackerConfig or not trackerConfig.specialVisibilityConditions then
        return false
    end
    
    -- Check if ConditionalEngine is available
    if not SpellStyler.ConditionalEngine or not SpellStyler.ConditionalEngine.ConditionalUsesCharges then
        return false
    end
    
    -- Check each conditional to see if any use charges
    for _, condition in ipairs(trackerConfig.specialVisibilityConditions) do
        if condition.conditionalName and SpellStyler.ConditionalEngine:ConditionalUsesCharges(condition.conditionalName) then
            return true
        end
    end
    
    return false
end

function FrameTrackerManager:ScanAndSaveCurrentCooldownManagerFrames(trackerType)
    local viewer = SpellStyler.Containers:GetCooldownManagerViewer(trackerType)
    if not viewer or not viewer.itemFramePool then return end

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
                
                -- CreateFrameMiddleware creates base frame, variant frame (if needed),
                -- sets up charge infrastructure, and drives updates
                FrameTrackerManager:CreateFrameMiddleware(spellID, trackerConfig, trackerType)
            end
        end
    end

    -- Apply any saved viewer visibility setting
    SpellStyler.Containers:ApplyViewerVisibility("buffs")
    SpellStyler.Containers:ApplyViewerVisibility("essential")
    SpellStyler.Containers:ApplyViewerVisibility("utility")
end



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
                    
                    -- CreateFrameMiddleware creates base frame, variant frame (if needed),
                    -- sets up charge infrastructure, and drives updates
                    FrameTrackerManager:CreateFrameMiddleware(baseSpellID, trackerConfig, trackerType)
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
function FrameTrackerManager:CreateStatusBar(frame, key, trackerConfig, baseSpellID, trackerType, x, y, useBaseTexture, configKey)
    -- Default to statusBar if no configKey provided (for cooldown bar)
    configKey = configKey or "statusBar"
    
    local barConfig = trackerConfig[configKey]
    if not barConfig then return end
    if configKey ~= 'statusBar' then
        DevTool:AddData({
            frame = frame,
            key = key,
            trackerConfig = trackerConfig,
            baseSpellID = baseSpellID,
            trackerType = trackerType,
            x = x,
            y = y,
            useBaseTexture = useBaseTexture,
            barConfig = barConfig
        }, configKey)
    end
    local statusBarName = frame:GetName() .. "_" .. key
    frame[key] = CreateFrame("StatusBar", statusBarName, frame)
    frame[key]:SetPoint(barConfig.anchorSelf or "LEFT", frame, barConfig.anchorParent or "RIGHT", x or barConfig.x or 0, y or barConfig.y or 0)
    local _iconW = trackerConfig.iconSettings.width or trackerConfig.iconSettings.size or 48
    local _iconH = trackerConfig.iconSettings.height or trackerConfig.iconSettings.size or 48
    local statusBarWidth = barConfig and barConfig.width or (_iconW * 4)
    local statusBarHeight = barConfig and barConfig.height or (_iconH / 2)

    local onlyBarOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, configKey .. ".onlyRenderBar")
    local onlyBar = (onlyBarOverride ~= nil) and onlyBarOverride or (barConfig.onlyRenderBar or false)
    local forceHideViaAlpha = onlyBar or barConfig.displayState == 'never'
    frame[key]:SetSize(statusBarWidth, statusBarHeight)
    frame[key]:SetScale(barConfig.scale or 1)
    
    -- For visualChargeBar, use min/max values from config; otherwise 0-1 for cooldown percentage
    if configKey == "visualChargeBar" then
        frame[key]:SetMinMaxValues(barConfig.minValue or 0, barConfig.maxValue or 5)
    else
        frame[key]:SetMinMaxValues(0, 1)
    end
    frame[key]:SetValue(0)
    -- Use one strata higher than icon to ensure statusBar renders above iconContainer's stacking context
    local iconStrata = trackerConfig.iconSettings.frameStrataLevel or "MEDIUM"
    local strataMap = { BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG" }
    frame[key]:SetFrameStrata(strataMap[iconStrata] or "HIGH")
    frame[key]:SetFrameLevel(frame:GetFrameLevel() + 3)  -- Base level for status bar
    frame[key]:SetStatusBarColor(
        barConfig.color.r or 0.2,
        barConfig.color.g or 0.8,
        barConfig.color.b or 1,
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
    if barConfig.customBarTexture ~= '' and not useBaseTexture then
        texture = barConfig.customBarTexture
    else
        texture = barConfig.defaultBarTexture
    end
    frame[key].bgTexture:SetTexture(texture)
    frame[key].bgTexture:SetVertexColor(
        barConfig.backgroundColor.r,
        barConfig.backgroundColor.g,
        barConfig.backgroundColor.b,
        forceHideViaAlpha and 0 or barConfig.backgroundColor.a
    )  -- Darkened background

    -- Layer 2: Main Fill (active progress) - ARTWORK layer (sublayer 0, above BACKGROUND)
    local barTexture = (barConfig.customBarTexture and barConfig.customBarTexture ~= "")
        and barConfig.customBarTexture
        or barConfig.defaultBarTexture
    frame[key]:SetStatusBarTexture(barTexture)
    
    
    -- Fill direction is controlled via TimerDirection in SetTimerDuration (ElapsedTime = fills up, RemainingTime = depletes)
    frame[key]:SetReverseFill(false)
    frame[key]:SetOrientation(
        (barConfig.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL"
    )

    -- Layer 2.5: Full-cover texture (ARTWORK sublayer 1, above the fill at sublayer 0).
    -- Used when defaultFillValue='full' to visually fill the bar without fighting SetTimerDuration.
    -- Shown by UpdateFrame_Duration _Inactive when isFull, hidden when a real cooldown is active.
    frame[key].fullCoverTexture = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    frame[key].fullCoverTexture:SetAllPoints(frame[key])
    frame[key].fullCoverTexture:SetTexture(barTexture)
    frame[key].fullCoverTexture:SetVertexColor(
        barConfig.color.r or 0.2,
        barConfig.color.g or 0.8,
        barConfig.color.b or 1,
        forceHideViaAlpha and 0 or barConfig.color.a or 0.9
    )
    frame[key].fullCoverTexture:Show()  -- Start visible; alpha controls actual visibility

    -- Layer 3: Glow overlay - OVERLAY layer
    frame[key].glowTexture = frame[key]:CreateTexture(nil, "OVERLAY")
    frame[key].glowTexture:SetPoint("TOPLEFT", frame[key], "TOPLEFT", 0, 0)
    frame[key].glowTexture:SetPoint("BOTTOMRIGHT", frame[key], "BOTTOMRIGHT", 0, 0)
    frame[key].glowTexture:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarGlow.tga")
    frame[key].glowTexture:SetBlendMode("ADD")
    frame[key].glowTexture:SetVertexColor(
        barConfig.glowColor.r or 1,
        barConfig.glowColor.g or 1,
        barConfig.glowColor.b or 1,
        forceHideViaAlpha and 0 or barConfig.glowColor.a or 0.25
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
        barConfig.borderColor.r or 0,
        barConfig.borderColor.g or 0,
        barConfig.borderColor.b or 0,
        forceHideViaAlpha and 0 or barConfig.borderColor.a or 1
    )
    frame[key].borderCornerTL:SetScale(barConfig.borderScale or 1)

    -- Top-right corner (rotated 270°)
    frame[key].borderCornerTR = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerTR:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerTR:SetPoint("TOPRIGHT", frame[key].border, "TOPRIGHT", 1.5, 1.5)
    frame[key].borderCornerTR:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerTR:SetRotation(3 * math.pi / 2)
    frame[key].borderCornerTR:SetVertexColor(
        barConfig.borderColor.r or 0,
        barConfig.borderColor.g or 0,
        barConfig.borderColor.b or 0,
        forceHideViaAlpha and 0 or barConfig.borderColor.a or 1
    )
    frame[key].borderCornerTR:SetScale(barConfig.borderScale or 1)

    -- Bottom-right corner (rotated 180°)
    frame[key].borderCornerBR = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerBR:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerBR:SetPoint("BOTTOMRIGHT", frame[key].border, "BOTTOMRIGHT", 1.5, -1.5)
    frame[key].borderCornerBR:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerBR:SetRotation(math.pi)
    frame[key].borderCornerBR:SetVertexColor(
        barConfig.borderColor.r or 0,
        barConfig.borderColor.g or 0,
        barConfig.borderColor.b or 0,
        forceHideViaAlpha and 0 or barConfig.borderColor.a or 1
    )
    frame[key].borderCornerBR:SetScale(barConfig.borderScale or 1)

    -- Bottom-left corner (rotated 90°)
    frame[key].borderCornerBL = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerBL:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerBL:SetPoint("BOTTOMLEFT", frame[key].border, "BOTTOMLEFT", -1.5, -1.5)
    frame[key].borderCornerBL:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerBL:SetRotation(math.pi / 2)
    frame[key].borderCornerBL:SetVertexColor(
        barConfig.borderColor.r or 0,
        barConfig.borderColor.g or 0,
        barConfig.borderColor.b or 0,
        forceHideViaAlpha and 0 or barConfig.borderColor.a or 1
    )
    frame[key].borderCornerBL:SetScale(barConfig.borderScale or 1)

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

--- Helper to create a single charge anchor StatusBar
local function CreateSingleChargeAnchorBar(frame, barName, minValue, maxValue)
    -- local barName = "ChargeAnchorBar_" .. baseSpellID .. nameSuffix
    local bar = CreateFrame("StatusBar", barName, frame, "BackdropTemplate")
    local anchorHeight = GetScreenHeight() * 2
    bar:SetStatusBarTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarFill.tga")
    bar:SetMinMaxValues(minValue, maxValue)
    bar:SetValue(minValue)
    bar:SetSize(10, anchorHeight)
    bar:SetOrientation("VERTICAL")
    
    -- Debugging if I need to  see the status bars used for the charge based controlls
    -- local borderColor, colorName
    -- if frame.meta.isVariantFrame then
    --     if barName:sub(-2) == "_A" then
    --         borderColor = {1, 0, 0, 1}
    --         colorName = "red"
    --     else
    --         borderColor = {1, 1, 0, 1}
    --         colorName = "yellow"
    --     end
    -- else
    --     if barName:sub(-2) == "_A" then
    --         borderColor = {0, 1, 0, 1}
    --         colorName = "green"
    --     else
    --         borderColor = {0, 0, 1, 1}
    --         colorName = "blue"
    --     end
    -- end
    -- bar:SetStatusBarColor(unpack(borderColor))
    -- bar:SetAlpha(1)
    
    bar:SetStatusBarColor(0,0,0,0)
    bar:SetAlpha(0)
    -- Debugging if I need to  see the status bars used for the charge based controlls
    -- bar:SetBackdrop({
    --     edgeFile = "Interface\\Buttons\\WHITE8x8",
    --     edgeSize = 2
    -- })
    -- bar:SetBackdropBorderColor(unpack(borderColor))
    
    bar:Show()
    bar:ClearAllPoints()

    return bar
end

--- Helper to hide all visible elements of a frame (used when a frame is never active in certain charge cases)
local function HideFrameElements(frame)
    if not frame then return end
    
    -- Hide the frame itself and set alpha to 0
    frame:Hide()
    -- frame:SetAlpha(0)
    
    -- Hide and zero alpha on all icon elements
    if frame.iconContainer then 
        frame.iconContainer:Hide()
        -- frame.iconContainer:SetAlpha(0)
    end
    if frame.icon then 
        frame.icon:Hide()
        -- frame.icon:SetAlpha(0)
    end
    if frame.cooldown then 
        frame.cooldown:Hide()
        -- frame.cooldown:SetAlpha(0)
    end
    
    -- Hide statusBar and all its sub-elements
    if frame.statusBar then 
        frame.statusBar:Hide()
        -- frame.statusBar:SetAlpha(0)
        
        -- Critical: These textures are parented to the main frame, not statusBar
        -- So hiding statusBar doesn't hide them - must hide explicitly
        if frame.statusBar.bgTexture then 
            frame.statusBar.bgTexture:Hide()
            -- frame.statusBar.bgTexture:SetAlpha(0)
        end
        if frame.statusBar.fullCoverTexture then 
            frame.statusBar.fullCoverTexture:Hide()
            -- frame.statusBar.fullCoverTexture:SetAlpha(0)
        end
        if frame.statusBar.glowTexture then 
            frame.statusBar.glowTexture:Hide()
            -- frame.statusBar.glowTexture:SetAlpha(0)
        end
        
        -- Hide border frame and all its pieces
        if frame.statusBar.border then
            frame.statusBar.border:Hide()
            -- frame.statusBar.border:SetAlpha(0)
        end
        if frame.statusBar.borderCornerTL then frame.statusBar.borderCornerTL:Hide() end
        if frame.statusBar.borderCornerTR then frame.statusBar.borderCornerTR:Hide() end
        if frame.statusBar.borderCornerBR then frame.statusBar.borderCornerBR:Hide() end
        if frame.statusBar.borderCornerBL then frame.statusBar.borderCornerBL:Hide() end
        if frame.statusBar.borderEdgeTop then frame.statusBar.borderEdgeTop:Hide() end
        if frame.statusBar.borderEdgeRight then frame.statusBar.borderEdgeRight:Hide() end
        if frame.statusBar.borderEdgeBottom then frame.statusBar.borderEdgeBottom:Hide() end
        if frame.statusBar.borderEdgeLeft then frame.statusBar.borderEdgeLeft:Hide() end
    end
    
    -- Hide count text
    if frame.count then 
        frame.count:SetText("")
        frame.count:Hide()
        -- frame.count:SetAlpha(0)
    end
    
    -- Hide custom label
    if frame.customLabel then 
        frame.customLabel:Hide()
        -- frame.customLabel:SetAlpha(0)
    end
    
    -- Hide glow frame
    if frame.glowFrame then 
        frame.glowFrame:Hide()
        -- frame.glowFrame:SetAlpha(0)
    end
end

--- Helper to restore visibility of all frame elements (inverse of HideFrameElements)
--- Used when settings change and a previously hidden frame needs to become active
local function ShowFrameElements(frame)
    if not frame then return end
    
    -- Show the frame itself and restore alpha to 1
    frame:Show()
    -- frame:SetAlpha(1)
    
    -- Show and restore alpha on all icon elements
    if frame.iconContainer then 
        frame.iconContainer:Show()
        -- frame.iconContainer:SetAlpha(1)
    end
    if frame.icon then 
        frame.icon:Show()
        -- frame.icon:SetAlpha(1)
    end
    if frame.cooldown then 
        frame.cooldown:Show()
        -- frame.cooldown:SetAlpha(1)
    end
    
    -- Show statusBar (note: actual visibility controlled by ApplyVisibility during DriveFrameUpdate)
    if frame.statusBar then 
        frame.statusBar:Show()
        -- frame.statusBar:SetAlpha(1)
        
        -- Show textures parented to main frame
        if frame.statusBar.bgTexture then 
            frame.statusBar.bgTexture:Show()
            -- frame.statusBar.bgTexture:SetAlpha(1)
        end
        if frame.statusBar.fullCoverTexture then 
            frame.statusBar.fullCoverTexture:Show()
            -- frame.statusBar.fullCoverTexture:SetAlpha(1)
        end
        if frame.statusBar.glowTexture then 
            frame.statusBar.glowTexture:Show()
            -- frame.statusBar.glowTexture:SetAlpha(1)
        end
        
        -- Show border frame and all its pieces
        if frame.statusBar.border then
            frame.statusBar.border:Show()
            -- frame.statusBar.border:SetAlpha(1)
        end
        if frame.statusBar.borderCornerTL then frame.statusBar.borderCornerTL:Show() end
        if frame.statusBar.borderCornerTR then frame.statusBar.borderCornerTR:Show() end
        if frame.statusBar.borderCornerBR then frame.statusBar.borderCornerBR:Show() end
        if frame.statusBar.borderCornerBL then frame.statusBar.borderCornerBL:Show() end
        if frame.statusBar.borderEdgeTop then frame.statusBar.borderEdgeTop:Show() end
        if frame.statusBar.borderEdgeRight then frame.statusBar.borderEdgeRight:Show() end
        if frame.statusBar.borderEdgeBottom then frame.statusBar.borderEdgeBottom:Show() end
        if frame.statusBar.borderEdgeLeft then frame.statusBar.borderEdgeLeft:Show() end
    end
    
    -- Show count text (actual visibility controlled by ApplyVisibility during DriveFrameUpdate)
    if frame.count then 
        frame.count:Show()
        -- frame.count:SetAlpha(1)
    end
    
    -- Show custom label (actual visibility controlled by config during DriveFrameUpdate)
    if frame.customLabel then 
        frame.customLabel:Show()
        -- frame.customLabel:SetAlpha(1)
    end
    
    -- Glow frame starts hidden (shown only when proc notification triggers)
    if frame.glowFrame then 
        frame.glowFrame:Hide()
        -- frame.glowFrame:SetAlpha(1)
    end
end

--- Helper to calculate min/max values based on operator and charge value
--- For "<": show when charges < value, so bar range is (value-1, value)
--- For ">": show when charges > value, so bar range is (value, value+1)
local function CalculateBarRange(operator, value)
    if operator == "<" then
        return value - 1, value
    else  -- ">"
        return value, value + 1
    end
end

--- Unified function to create charge anchor bars for both visibility and conditionals
--- Handles all 8 cases (A-H) automatically based on configuration

--- Unified function to create charge anchor bars for both visibility and conditionals
--- Handles all 8 cases (A-H) automatically based on configuration
function FrameTrackerManager:CreateChargeAnchorBars(frame, trackerConfig, baseSpellID, isVariantFrame, skipVisibilityUpdate)
    local cbdConfig = trackerConfig.chargeBasedDisplay
    local hasChargeBasedDisplay = cbdConfig and cbdConfig.enabled
    
    local conditionalData = nil
    if SpellStyler.ConditionalEngine and TrackerHasChargesConditionals(trackerConfig) and trackerConfig.specialVisibilityConditions then
        for _, condition in ipairs(trackerConfig.specialVisibilityConditions) do
            if condition.conditionalName and SpellStyler.ConditionalEngine:ConditionalUsesCharges(condition.conditionalName) then
                conditionalData = SpellStyler.ConditionalEngine:GetChargeConditionalData(condition.conditionalName)
                if conditionalData then break end
            end
        end
    end
    
    if not hasChargeBasedDisplay and not conditionalData then return end
    
    -- Safety guard: Variant frames should ONLY exist when there are property conditionals
    -- If we're processing a variant frame but there are no conditionals, return immediately
    if isVariantFrame and not conditionalData then return end
    
    local visibilityValue = hasChargeBasedDisplay and (cbdConfig.chargeValue or 1) or nil
    local visibilityOperator = hasChargeBasedDisplay and (cbdConfig.displayOperator or ">") or nil
    local visibilityMode = hasChargeBasedDisplay and (cbdConfig.displayState and "show" or "hide") or nil
    
    local variantValue = conditionalData and conditionalData.targetValue or nil
    local variantOperator = conditionalData and conditionalData.comparison or nil
    
    -- Direction logic: show + > means UP, show + < means DOWN, hide + > means DOWN, hide + < means UP
    local visibilityDirectionUp = visibilityOperator and ((visibilityMode == 'show' and visibilityOperator == '>') or
                                  (visibilityMode == 'hide' and visibilityOperator == '<'))
    local variantDirectionUp = variantOperator and (variantOperator == '>')
    
    -- Calculate if visibility shows at lower charge values than variant
    -- Need to consider the operators: < means "below threshold", > means "above threshold"
    local visibilityBelowVariant = false
    if visibilityValue and variantValue and visibilityOperator and variantOperator then
        if visibilityOperator == "<" and variantOperator == ">" then
            -- visibility shows at charges [0, V-1], variant shows at [W+1, inf]
            -- visibility is below if its max (V-1) is strictly less than variant's min (W+1)
            -- Use < (not <=) so touching/overlapping ranges route to dual-bar cases
            visibilityBelowVariant = (visibilityValue - 1) < (variantValue + 1)
        elseif visibilityOperator == ">" and variantOperator == "<" then
            -- visibility shows at charges [V+1, inf], variant shows at [0, W-1]
            -- visibility is below if its min (V+1) is less than or equal to variant's max (W-1)
            -- Use <= to detect overlaps (when they touch at same charge, need dual bars)
            visibilityBelowVariant = (visibilityValue + 1) <= (variantValue - 1)
        elseif visibilityValue == variantValue and visibilityOperator == variantOperator then
            -- Equal thresholds with same operator: both show at same charge range
            -- Only variant frame exists, direction determines which case:
            -- Both DOWN → visibilityBelowVariant = true → Case B
            -- Both UP → visibilityBelowVariant = false → Case H
            visibilityBelowVariant = not (visibilityOperator == ">")
        else
            -- For different values with same operator direction, use simple value comparison
            visibilityBelowVariant = visibilityValue < variantValue
        end
    end
    
    local caseType = "single"
    
    if hasChargeBasedDisplay and conditionalData then
        if visibilityBelowVariant then
            if variantDirectionUp and not visibilityDirectionUp then
                caseType = "A"
            elseif not variantDirectionUp and not visibilityDirectionUp then
                caseType = "B"
            elseif not variantDirectionUp and visibilityDirectionUp then
                caseType = "C"
            elseif variantDirectionUp and visibilityDirectionUp then
                caseType = "D"
            end
        else
            if variantDirectionUp and not visibilityDirectionUp then
                caseType = "E"
            elseif not variantDirectionUp and not visibilityDirectionUp then
                caseType = "F"
            elseif not variantDirectionUp and visibilityDirectionUp then
                caseType = "G"
            elseif variantDirectionUp and visibilityDirectionUp then
                caseType = "H"
            end
        end
    end
    
    local visMinVal, visMaxVal = 0, 0
    if visibilityOperator ~= nil and visibilityValue ~= nil then
        visMinVal, visMaxVal = CalculateBarRange(visibilityOperator, visibilityValue)
    end
    local varMinVal, varMaxVal = 0, 0
    if variantOperator ~= nil and variantValue ~= nil then
        varMinVal, varMaxVal = CalculateBarRange(variantOperator, variantValue)
    end
    
    -- Constructor values: stores min/max, anchor, and render flag for each bar
    -- Bar A: Uses variant values in dual-bar cases, visibility values in single-bar cases
    -- Bar B: Always uses visibility values (only exists in dual-bar cases)
    local constructorValues = {
        A = {min = nil, max = nil, anchor = nil, shouldRender = false},
        B = {min = visMinVal, max = visMaxVal, anchor = nil, shouldRender = false}
    }

    -- Determine which bars to create and their anchors based on case type
    if caseType == "A" and not isVariantFrame then
        -- Case A: Base only, single bar using visibility values
        constructorValues.A.min = visibilityValue - 1
        constructorValues.A.max = visibilityValue
        constructorValues.A.anchor = "BOTTOM"
        constructorValues.A.shouldRender = true
        
    elseif caseType == "B" and isVariantFrame then
        -- Case B: Variant only, single bar using visibility values
        constructorValues.A.min = visibilityValue - 1
        constructorValues.A.max = visibilityValue
        constructorValues.A.anchor = "BOTTOM"
        constructorValues.A.shouldRender = true
        
    elseif caseType == "C" then
        if isVariantFrame then
            -- Case C Variant: Dual bars (B=visibility anchored to UIParent, A=variant chained to B)
            constructorValues.A.min = varMinVal
            constructorValues.A.max = varMaxVal
            constructorValues.A.anchor = "BOTTOM"  -- Chained to barB at TOP
            constructorValues.A.shouldRender = true
            constructorValues.B.anchor = "TOP"
            constructorValues.B.shouldRender = true
        else
            -- Case C Base: Single bar using variant values
            constructorValues.A.min = varMinVal
            constructorValues.A.max = varMaxVal
            constructorValues.A.anchor = "TOP"
            constructorValues.A.shouldRender = true
        end
        
    elseif caseType == "D" then
        if not isVariantFrame then
            -- Case D Base: Dual bars (B=visibility anchored to UIParent, A=variant chained to B)
            constructorValues.A.min = varMinVal
            constructorValues.A.max = varMaxVal
            constructorValues.A.anchor = "BOTTOM"  -- Chained to barB at TOP
            constructorValues.A.shouldRender = true
            constructorValues.B.anchor = "TOP"
            constructorValues.B.shouldRender = true
        else
            -- Case D Variant: Single bar using variant values
            constructorValues.A.min = varMinVal
            constructorValues.A.max = varMaxVal
            constructorValues.A.anchor = "TOP"
            constructorValues.A.shouldRender = true
        end
        
    elseif caseType == "E" then
        if not isVariantFrame then
            -- Case E Base: Single bar using variant values
            constructorValues.A.min = varMinVal
            constructorValues.A.max = varMaxVal
            constructorValues.A.anchor = "BOTTOM"
            constructorValues.A.shouldRender = true
        else
            -- Case E Variant: Dual bars (B=visibility anchored to UIParent, A=variant chained to B)
            constructorValues.A.min = varMinVal
            constructorValues.A.max = varMaxVal
            constructorValues.A.anchor = "BOTTOM"  -- Chained to barB at TOP
            constructorValues.A.shouldRender = true
            constructorValues.B.anchor = "TOP"
            constructorValues.B.shouldRender = true
        end
        
    elseif caseType == "F" then
        if isVariantFrame then
            -- Case F Variant: Single bar using variant values
            constructorValues.A.min = varMinVal
            constructorValues.A.max = varMaxVal
            constructorValues.A.anchor = "BOTTOM"
            constructorValues.A.shouldRender = true
        else
            -- Case F Base: Dual bars (B=visibility anchored to UIParent, A=variant chained to B)
            constructorValues.A.min = varMinVal
            constructorValues.A.max = varMaxVal
            constructorValues.A.anchor = "BOTTOM"  -- Chained to barB at TOP
            constructorValues.A.shouldRender = true
            constructorValues.B.anchor = "TOP"
            constructorValues.B.shouldRender = true
        end
        
    elseif caseType == "G" and not isVariantFrame then
        -- Case G: Base only, single bar using visibility values
        constructorValues.A.min = visMinVal
        constructorValues.A.max = visMaxVal
        constructorValues.A.anchor = "TOP"
        constructorValues.A.shouldRender = true
        
    elseif caseType == "H" and isVariantFrame then
        -- Case H: Variant only, single bar using visibility values
        constructorValues.A.min = visMinVal
        constructorValues.A.max = visMaxVal
        constructorValues.A.anchor = "TOP"
        constructorValues.A.shouldRender = true
        
    elseif hasChargeBasedDisplay and not conditionalData and not isVariantFrame then
        -- Visibility-only: Single bar using visibility values
        constructorValues.A.min = visMinVal
        constructorValues.A.max = visMaxVal
        constructorValues.A.anchor = visibilityDirectionUp and "TOP" or "BOTTOM"
        constructorValues.A.shouldRender = true
        
    elseif not hasChargeBasedDisplay and conditionalData then
        -- Property-only: Single bar using variant values
        constructorValues.A.min = varMinVal
        constructorValues.A.max = varMaxVal
        if isVariantFrame then
            constructorValues.A.anchor = variantDirectionUp and "TOP" or "BOTTOM"
        else
            constructorValues.A.anchor = variantDirectionUp and "BOTTOM" or "TOP"
        end
        constructorValues.A.shouldRender = true
    end

    -- debugging to see the variant frame not overlapped with the base
    local x = 0 --isVariantFrame and -100 or 0
    
    -- Create Bar B first (if needed) - always anchored to UIParent
    if constructorValues.B.shouldRender then
        frame.chargeAnchorBarB = CreateSingleChargeAnchorBar(
            frame, "ChargeAnchorBar_" .. baseSpellID .. "_B", constructorValues.B.min, constructorValues.B.max
        )
        frame.chargeAnchorBarB:SetPoint(constructorValues.B.anchor, UIParent,
            trackerConfig.position.relativeAnchorPoint or trackerConfig.position.anchorPoint,
            ((trackerConfig.position.x + x) or 0), trackerConfig.position.y or 0)
    end
    
    -- Create Bar A (if needed) - anchored to Bar B texture if B exists, otherwise UIParent
    if constructorValues.A.shouldRender then
        frame.chargeAnchorBarA = CreateSingleChargeAnchorBar(
            frame, "ChargeAnchorBar_" .. baseSpellID .. "_A", constructorValues.A.min, constructorValues.A.max
        )
        
        if frame.chargeAnchorBarB then
            -- Dual-bar case: Chain A to B's texture at TOP point
            frame.chargeAnchorBarA:SetPoint(constructorValues.A.anchor, frame.chargeAnchorBarB:GetStatusBarTexture(), "TOP", 0, 0)
        else
            -- Single-bar case: Anchor A to UIParent
            frame.chargeAnchorBarA:SetPoint(constructorValues.A.anchor, UIParent,
                trackerConfig.position.relativeAnchorPoint or trackerConfig.position.anchorPoint,
                ((trackerConfig.position.x + x) or 0), trackerConfig.position.y or 0)
        end
    end
    
    -- Handle frame visibility based on case type (unless skipped for drag operations)
    -- Cases A, B, G, H: Single-frame cases - hide the unused frame
    -- Cases C, D, E, F: Dual-frame cases - ensure both frames are visible (restore if previously hidden)
    
    if caseType == "A" or caseType == "G" then
        if isVariantFrame then
            -- This variant frame will never be shown, hide all its elements
            frame.meta.dualFrameStatus = 'hideVariant'
            HideFrameElements(frame)
        else
            -- Base frame is active, clear any hide flag and restore visibility
            frame.meta.dualFrameStatus = nil
            ShowFrameElements(frame)
        end
    elseif caseType == "B" or caseType == "H" then
        if not isVariantFrame then
            -- This base frame will never be shown, hide all its elements
            -- Set status first so it's available for checks, then hide elements
            frame.meta.dualFrameStatus = 'hideBase'
            HideFrameElements(frame)
        else
            -- Variant frame is active, clear any hide flag and restore visibility
            frame.meta.dualFrameStatus = nil
            ShowFrameElements(frame)
        end
    elseif caseType == "C" or caseType == "D" or caseType == "E" or caseType == "F" then
        -- Dual-frame cases: both frames are active, ensure both are visible
        -- Clear any dualFrameStatus flags from previous configurations
        frame.meta.dualFrameStatus = nil
        ShowFrameElements(frame)
    end
end


function FrameTrackerManager:CreateTrackerFrame(baseSpellID, trackerConfig, trackerType, isVariantFrame)
    -- For variant frames, skip the duplicate check and allow creation
    -- Base frames still check if they already exist
    if not isVariantFrame and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] then
        return FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    end
    
    local frameName = FRAME_PREFIX .. baseSpellID .. (isVariantFrame and "_Variant" or "")
    --[[
        upon creating the frame, it starts with the overrideSpellID. "meta.activeSpellID" could update even further - for example:
            base = divine toll
            override = sacred weapons
            override again = holy bulwark
    ]]
    local spellChargesInfo = C_Spell.GetSpellCharges(trackerConfig.overrideSpellID or baseSpellID)
    local spellInfo = C_Spell.GetSpellInfo(trackerConfig.overrideSpellID  or baseSpellID)
    local frame = CreateFrame("Button", frameName, UIParent, "BackdropTemplate")
    
    -- Only add base frames to the global registry; variant frames are stored on their base frame
    if not isVariantFrame then
        FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] = frame
    end
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
        isVariantFrame = isVariantFrame,
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
    
    -- Icon container (handles opacity/alpha) - set lower frame level so statusBar renders above
    frame.iconContainer = CreateFrame('Frame', 'iconContainer_' .. frame.meta.activeSpellID, frame)
    frame.iconContainer:SetAllPoints(frame)
    frame.iconContainer:SetFrameLevel(frame:GetFrameLevel() - 1)
    
    -- Icon texture (created on iconContainer, referenced via frame.icon)
    frame.icon = frame.iconContainer:CreateTexture(nil, "ARTWORK")
    frame.Icon = frame.icon

    frame.icon:SetAllPoints(frame.iconContainer)
    local zoom = trackerConfig.iconSettings.zoom and (trackerConfig.iconSettings.zoom / 100) or 0
    frame.icon:SetTexCoord(0 + zoom, 1 - zoom, 0 + zoom, 1 - zoom)
    local iconTexture = frame.meta.customTexture or trackerConfig.defaultIconTexturePath
    frame.icon:SetTexture(iconTexture)
    
    -- Apply color (RGB only, alpha goes on iconContainer)
    local _, insufficientPower = C_Spell.IsSpellUsable(frame.meta.activeSpellID)
    local color = (insufficientPower and trackerConfig.iconSettings.insufficientPower and trackerConfig.iconSettings.insufficientPowerIconColor)
        or trackerConfig.iconColor or {}
    frame.icon:SetVertexColor(
        color.r or 1,
        color.g or 1,
        color.b or 1
    )
    
    -- Apply alpha to iconContainer
    frame.iconContainer:SetAlpha(color.a or 1)

    frame.icon:SetDesaturated(false)  -- Initialize as not desaturated
    
    frame.cooldown = CreateFrame("Cooldown", frameName .. "_Cooldown", frame.iconContainer, "CooldownFrameTemplate")
    frame.Cooldown = frame.cooldown
    frame.cooldown:SetAllPoints(frame.iconContainer)
    frame.cooldown:SetFrameLevel(frame.iconContainer:GetFrameLevel() + 1)  -- Above icon texture
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
        C_Timer.After(0, function()
            local spellInfo = C_Spell.GetSpellInfo(frame.meta.activeSpellID)
            local a, insufficientPower = C_Spell.IsSpellUsable(frame.meta.activeSpellID)
            SpellStyler.ConditionalEngine:EvaluateAll()
        end)
        
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
    
    FrameTrackerManager:CreateStatusBar(frame, "statusBar", trackerConfig, baseSpellID, trackerType, nil, nil, nil, "statusBar")
    
    -- Create visual charge bar if visualChargeBar config exists
    if trackerConfig.visualChargeBar and trackerConfig.countText.renderAsStatusBar then
        -- FrameTrackerManager:CreateStatusBar(frame, "visualChargeBar", trackerConfig, baseSpellID, trackerType, nil, nil, nil, "visualChargeBar")
    end

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
    if frame.chargeAnchorBarA then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", frame.chargeAnchorBarA:GetStatusBarTexture(), "TOP", 0, 0)
    elseif pos and pos.anchorPoint and pos.x and pos.y then
        frame:ClearAllPoints()
        -- For variant frames, offset by 100 pixels to the right so both are visible
        local xOffset = 0 --isVariantFrame and 100 or 0
        frame:SetPoint(
            pos.anchorPoint, 
            UIParent,  -- Always use UIParent for simplicity
            pos.relativeAnchorPoint or pos.anchorPoint, 
            (pos.x or 0) + xOffset, 
            pos.y or 0
        )
    else
        -- Default position - center with offset based on slot
        local xOffset = 0 --isVariantFrame and 100 or 0
        frame:SetPoint("CENTER", UIParent, "CENTER", -200 + xOffset, -100)
    end

    -- Initially hidden
    frame:Show()

    -- If the "Replace with Spell Display Count" setting is on, start a ticker
    -- that reads the action-bar display count and writes it into frame.count.
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


--- Helper function to apply property updates to a single frame (base or variant)
--- @param frame table The frame to update
--- @param trackerConfig table The tracker configuration
--- @param baseSpellID number The base spell ID
--- @param trackerType string The tracker type
local function ApplyFramePropertyUpdates(frame, trackerConfig, baseSpellID, trackerType)
    if not frame then return end
    
    -- Update icon texture: check override first, then state
    local iconTexOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "iconSettings.iconTexturePath")
    local customTexture = iconTexOverride or (trackerConfig.iconSettings.iconTexturePath and trackerConfig.iconSettings.iconTexturePath ~= "" and trackerConfig.iconSettings.iconTexturePath) or nil
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
    local opacityOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "iconSettings.opacity")
    frame:SetAlpha(opacityOverride or trackerConfig.iconSettings.opacity or 1)

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
    
    -- Update visual charge bar styling (if visualChargeBar config exists)
    if frame.visualChargeBar and trackerConfig.visualChargeBar and trackerConfig.countText.renderAsStatusBar then
        pcall(function()

            frame.visualChargeBar:SetStatusBarColor(
                trackerConfig.visualChargeBar.color.r or 0.2,
                trackerConfig.visualChargeBar.color.g or 0.8,
                trackerConfig.visualChargeBar.color.b or 1,
                1
            )
            -- Apply size: check override first, then state
            local widthOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.width")
            local heightOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.height")
            local width = widthOverride or trackerConfig.visualChargeBar.width or 200
            local height = heightOverride or trackerConfig.visualChargeBar.height or 20
            frame.visualChargeBar:SetSize(width, height)
            
            -- Apply scale: check override first, then state
            local scaleOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.scale")
            frame.visualChargeBar:SetScale(scaleOverride or trackerConfig.visualChargeBar.scale or 1)
            frame.visualChargeBar.bgTexture:SetScale(scaleOverride or trackerConfig.visualChargeBar.scale or 1)

            -- Apply position/anchoring: check override first, then state
            local xOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.x")
            local yOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.y")
            local anchorSelfOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.anchorSelf")
            local anchorParentOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.anchorParent")
            frame.visualChargeBar:ClearAllPoints()
            frame.visualChargeBar:SetPoint(
                anchorSelfOverride or trackerConfig.visualChargeBar.anchorSelf or "LEFT",
                frame,
                anchorParentOverride or trackerConfig.visualChargeBar.anchorParent or "RIGHT",
                xOverride or trackerConfig.visualChargeBar.x or 0,
                yOverride or trackerConfig.visualChargeBar.y or 0
            )

            -- Apply bar texture: check override first, then state (custom overrides default)
            local textureOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.customBarTexture")
            local barTexture = textureOverride
                or (trackerConfig.visualChargeBar.customBarTexture and trackerConfig.visualChargeBar.customBarTexture ~= "" and trackerConfig.visualChargeBar.customBarTexture)
                or trackerConfig.visualChargeBar.defaultBarTexture
            if barTexture then
                frame.visualChargeBar:SetStatusBarTexture(barTexture)
                -- Explicitly set draw layer to ensure proper layering (above background)
                local statusBarTexture = frame.visualChargeBar:GetStatusBarTexture()
                if statusBarTexture then
                    statusBarTexture:SetDrawLayer("ARTWORK", 0)
                end
                -- Keep the full-cover texture in sync with the bar texture
                if frame.visualChargeBar.fullCoverTexture then
                    frame.visualChargeBar.fullCoverTexture:SetTexture(barTexture)
                end
                -- Update background texture too
                if frame.visualChargeBar.bgTexture then
                    frame.visualChargeBar.bgTexture:SetTexture(barTexture)
                end
            end

            -- Apply orientation
            frame.visualChargeBar:SetOrientation(
                (trackerConfig.visualChargeBar.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL"
            )
            -- Apply fillOrEmpty: 'regular' = normal fill, 'inverse' = SetReverseFill
            local shouldReverse = trackerConfig.visualChargeBar.fillOrEmpty == 'inverse'
            frame.visualChargeBar:SetReverseFill(shouldReverse)

            -- Apply fill style (progressDirection) immediately so a settings change is reflected live
            local fillStyle = (trackerConfig and trackerConfig.visualChargeBar and trackerConfig.visualChargeBar.progressDirection == 'reverse')
            frame.visualChargeBar:SetFillStyle(fillStyle and Enum.StatusBarFillStyle.Reverse or Enum.StatusBarFillStyle.Standard)

            -- Apply rotation: check override first, then state
            local rotationOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.rotation")
            local rotation = rotationOverride or trackerConfig.visualChargeBar.textureRotation
            if rotation then
                frame.visualChargeBar:SetRotation(rotation)
            end
            
            -- Update min/max values based on config
            frame.visualChargeBar:SetMinMaxValues(
                trackerConfig.visualChargeBar.minValue or 0,
                trackerConfig.visualChargeBar.maxValue or 5
            )
        end)
        -- Called outside pcall so a pcall error can't prevent it from running
        
        local onlyBarOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.onlyRenderBar")
        local onlyBar = (onlyBarOverride ~= nil) and onlyBarOverride or (trackerConfig.visualChargeBar.onlyRenderBar or false)
        if onlyBar or trackerConfig.visualChargeBar.displayState == 'never' then
            frame.visualChargeBar.borderCornerTL:SetVertexColor(0,0,0,0)
            frame.visualChargeBar.borderCornerTR:SetVertexColor(0,0,0,0)
            frame.visualChargeBar.borderCornerBR:SetVertexColor(0,0,0,0)
            frame.visualChargeBar.borderCornerBL:SetVertexColor(0,0,0,0)
            frame.visualChargeBar.borderEdgeTop:SetVertexColor(0,0,0,0)
            frame.visualChargeBar.borderEdgeRight:SetVertexColor(0,0,0,0)
            frame.visualChargeBar.borderEdgeBottom:SetVertexColor(0,0,0,0)
            frame.visualChargeBar.borderEdgeLeft:SetVertexColor(0,0,0,0)
            frame.visualChargeBar.bgTexture:SetVertexColor(0,0,0,0)
            frame.visualChargeBar.glowTexture:SetVertexColor(0,0,0,0)
        elseif trackerConfig.visualChargeBar.displayState == 'always' then
            local borderColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.borderColor")
            local borderColor = borderColorOverride or trackerConfig.visualChargeBar.borderColor
            local backgroundColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.backgroundColor")
            local backgroundColor = backgroundColorOverride or trackerConfig.visualChargeBar.backgroundColor
            local glowColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.glowColor")
            local glowColor = glowColorOverride or trackerConfig.visualChargeBar.glowColor

            frame.visualChargeBar.borderCornerTL:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.visualChargeBar.borderCornerTR:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.visualChargeBar.borderCornerBR:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.visualChargeBar.borderCornerBL:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.visualChargeBar.borderEdgeTop:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.visualChargeBar.borderEdgeRight:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.visualChargeBar.borderEdgeBottom:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.visualChargeBar.borderEdgeLeft:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.visualChargeBar.bgTexture:SetVertexColor(backgroundColor.r, backgroundColor.g, backgroundColor.b, backgroundColor.a)
            frame.visualChargeBar.glowTexture:SetVertexColor(glowColor.r, glowColor.g, glowColor.b, glowColor.a)
        end
        -- to ensure it's not suppressed by errors or overridden
        local borderScaleOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "visualChargeBar.borderScale")
        local borderScale = borderScaleOverride or trackerConfig.visualChargeBar.borderScale or 0.5
        if frame.visualChargeBar.borderCornerTL then frame.visualChargeBar.borderCornerTL:SetScale(borderScale) end
        if frame.visualChargeBar.borderCornerTR then frame.visualChargeBar.borderCornerTR:SetScale(borderScale) end
        if frame.visualChargeBar.borderCornerBR then frame.visualChargeBar.borderCornerBR:SetScale(borderScale) end
        if frame.visualChargeBar.borderCornerBL then frame.visualChargeBar.borderCornerBL:SetScale(borderScale) end
        if frame.visualChargeBar.borderEdgeTop then frame.visualChargeBar.borderEdgeTop:SetScale(borderScale) end
        if frame.visualChargeBar.borderEdgeRight then frame.visualChargeBar.borderEdgeRight:SetScale(borderScale) end
        if frame.visualChargeBar.borderEdgeBottom then frame.visualChargeBar.borderEdgeBottom:SetScale(borderScale) end
        if frame.visualChargeBar.borderEdgeLeft then frame.visualChargeBar.borderEdgeLeft:SetScale(borderScale) end
    elseif frame.visualChargeBar and (not trackerConfig.visualChargeBar or not trackerConfig.countText.renderAsStatusBar) then
        -- Hide visualChargeBar if it exists but visualChargeBar config doesn't
        frame.visualChargeBar:SetAlpha(0)
        if frame.visualChargeBar.bgTexture then frame.visualChargeBar.bgTexture:SetAlpha(0) end
        if frame.visualChargeBar.fullCoverTexture then frame.visualChargeBar.fullCoverTexture:SetAlpha(0) end
        if frame.visualChargeBar.glowTexture then frame.visualChargeBar.glowTexture:SetAlpha(0) end
        if frame.visualChargeBar.border then frame.visualChargeBar.border:SetAlpha(0) end
        if frame.visualChargeBar.borderCornerTL then frame.visualChargeBar.borderCornerTL:SetAlpha(0) end
        if frame.visualChargeBar.borderCornerTR then frame.visualChargeBar.borderCornerTR:SetAlpha(0) end
        if frame.visualChargeBar.borderCornerBR then frame.visualChargeBar.borderCornerBR:SetAlpha(0) end
        if frame.visualChargeBar.borderCornerBL then frame.visualChargeBar.borderCornerBL:SetAlpha(0) end
        if frame.visualChargeBar.borderEdgeTop then frame.visualChargeBar.borderEdgeTop:SetAlpha(0) end
        if frame.visualChargeBar.borderEdgeRight then frame.visualChargeBar.borderEdgeRight:SetAlpha(0) end
        if frame.visualChargeBar.borderEdgeBottom then frame.visualChargeBar.borderEdgeBottom:SetAlpha(0) end
        if frame.visualChargeBar.borderEdgeLeft then frame.visualChargeBar.borderEdgeLeft:SetAlpha(0) end
    end
    
    -- NOTE: Charge anchor bars are NOT recreated here to avoid flickering.
    -- They are only created/refreshed when:
    -- 1. Frame is initially created (CreateTrackerFrame)
    -- 2. Charge-related settings are modified (chargeBasedDisplay.* paths)
    -- 3. Conditionals that use charges are added/removed/modified
    -- Use RefreshChargeAnchorBars() to explicitly refresh bars when needed.
    
    local pos = trackerConfig.position
    if frame.chargeAnchorBarA then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", frame.chargeAnchorBarA:GetStatusBarTexture(), "TOP", 0, 0)
    elseif pos and pos.anchorPoint and not frame._inContainer then
        local xOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "position.x")
        local yOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "position.y")
        frame:ClearAllPoints()
        -- For variant frames, offset by 100 pixels to the right so both are visible
        local xOffset = 0 --frame.isVariant and 100 or 0
        frame:SetPoint(
            pos.anchorPoint, 
            UIParent,
            pos.relativeAnchorPoint or pos.anchorPoint, 
            ((pos.x + (xOverride or 0)) or 0) + xOffset, 
            (pos.y + (yOverride or 0)) or 0
        )
    end
end

--- Updates frame properties after configuration changes.
--- This is used for property updates that don't require full charge infrastructure rebuild.
--- @param baseSpellID number The base spell ID
--- @param trackerType string The tracker type
function FrameTrackerManager:UpdateFrame_ConfigurationChanges(baseSpellID, trackerType)
    local trackerConfig = State:GetSpecificTrackerValue(baseSpellID, trackerType)
    local baseFrame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    
    if not baseFrame then return end
    
    -- Create visual charge bar if visualChargeBar config exists but bar doesn't exist yet
    if trackerConfig.visualChargeBar then
        if not baseFrame.visualChargeBar then
            self:CreateStatusBar(baseFrame, "visualChargeBar", trackerConfig, baseSpellID, trackerType, nil, nil, nil, "visualChargeBar")
        end
    end
    
    -- Create visual charge bar for variant frame if needed
    if baseFrame.variantFrame and trackerConfig.visualChargeBar then
        if not baseFrame.variantFrame.visualChargeBar then
            self:CreateStatusBar(baseFrame.variantFrame, "visualChargeBar", trackerConfig, baseSpellID, trackerType, nil, nil, nil, "visualChargeBar")
        end
    end
    
    -- Apply property updates to base frame only if it shouldn't be hidden
    if not baseFrame.meta or baseFrame.meta.dualFrameStatus ~= 'hideBase' then
        ApplyFramePropertyUpdates(baseFrame, trackerConfig, baseSpellID, trackerType)
    end
    
    -- Apply property updates to variant frame if it exists and shouldn't be hidden
    if baseFrame.variantFrame and baseFrame.variantFrame.meta and baseFrame.variantFrame.meta.dualFrameStatus ~= 'hideVariant' then
        ApplyFramePropertyUpdates(baseFrame.variantFrame, trackerConfig, baseSpellID, trackerType)
    end
    
    -- Drive frame updates only for frames that shouldn't be hidden
    if not baseFrame.meta or baseFrame.meta.dualFrameStatus ~= 'hideBase' then
        FrameTrackerManager:DriveFrameUpdate(
            baseFrame,
            {
                resolveDuration = true,
                syncChargeText = true
            },
            nil,
            "configurationChanges"
        )
    end
    
    if baseFrame.variantFrame and baseFrame.variantFrame.meta and baseFrame.variantFrame.meta.dualFrameStatus ~= 'hideVariant' then
        FrameTrackerManager:DriveFrameUpdate(
            baseFrame.variantFrame,
            {
                resolveDuration = true,
                syncChargeText = true
            },
            nil,
            "configurationChanges"
        )
    end
end

--- Creates/destroys charge anchor bars and variant frames as needed.
--- This method checks if bars exist and destroys them, then recreates them properly.
--- Always call this followed by UpdateFrame_ConfigurationChanges when settings change.
--- @param baseSpellID number The base spell ID
--- @param trackerType string The tracker type
function FrameTrackerManager:CreateChargeAnchorBarInfrastructure(baseSpellID, trackerType)
    local trackerConfig = State:GetSpecificTrackerValue(baseSpellID, trackerType)
    if not trackerConfig then return end
    
    local baseFrame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    if not baseFrame then return end
    
    -- ================================================================
    -- STEP 1: DESTROY EXISTING CHARGE BARS ON BASE FRAME
    -- ================================================================
    if baseFrame.chargeAnchorBarA then
        baseFrame.chargeAnchorBarA:Hide()
        baseFrame.chargeAnchorBarA:ClearAllPoints()
        baseFrame.chargeAnchorBarA = nil
    end
    if baseFrame.chargeAnchorBarB then
        baseFrame.chargeAnchorBarB:Hide()
        baseFrame.chargeAnchorBarB:ClearAllPoints()
        baseFrame.chargeAnchorBarB = nil
    end
    
    -- Clear any stale dualFrameStatus flags on base frame
    if baseFrame.meta then
        baseFrame.meta.dualFrameStatus = nil
    end
    
    -- Restore base frame visibility in case it was previously hidden
    ShowFrameElements(baseFrame)
    
    -- ================================================================
    -- STEP 2: CHECK IF VARIANT FRAME IS NEEDED
    -- ================================================================
    local shouldHaveVariant = TrackerHasChargesConditionals(trackerConfig)
    
    -- ================================================================
    -- STEP 3: HANDLE VARIANT FRAME LIFECYCLE
    -- ================================================================
    if baseFrame.variantFrame and not shouldHaveVariant then
        -- Variant exists but is no longer needed - destroy it completely
        local variantFrame = baseFrame.variantFrame
        
        -- Clear ConditionalEngine cache for this frame before destroying
        if SpellStyler.ConditionalEngine then
            SpellStyler.ConditionalEngine:ClearAllFramePropertyOverrides(variantFrame)
        end
        
        -- Destroy charge anchor bars on variant
        if variantFrame.chargeAnchorBarA then
            variantFrame.chargeAnchorBarA:Hide()
            variantFrame.chargeAnchorBarA:ClearAllPoints()
            variantFrame.chargeAnchorBarA = nil
        end
        if variantFrame.chargeAnchorBarB then
            variantFrame.chargeAnchorBarB:Hide()
            variantFrame.chargeAnchorBarB:ClearAllPoints()
            variantFrame.chargeAnchorBarB = nil
        end
        
        -- Destroy variant frame completely
        variantFrame:Hide()
        variantFrame:ClearAllPoints()
        if variantFrame.iconContainer then variantFrame.iconContainer:Hide() end
        if variantFrame.statusBar then variantFrame.statusBar:Hide() end
        if variantFrame.count then variantFrame.count:Hide() end
        if variantFrame.customLabel then variantFrame.customLabel:Hide() end
        if variantFrame.glowFrame then variantFrame.glowFrame:Hide() end
        
        baseFrame.variantFrame = nil
        baseFrame.variants = nil
        variantFrame.variants = nil
        
    elseif baseFrame.variantFrame and shouldHaveVariant then
        -- Variant exists and is still needed - just clear its bars (REUSE frame to preserve ConditionalEngine cache)
        local variantFrame = baseFrame.variantFrame
        
        if variantFrame.chargeAnchorBarA then
            variantFrame.chargeAnchorBarA:Hide()
            variantFrame.chargeAnchorBarA:ClearAllPoints()
            variantFrame.chargeAnchorBarA = nil
        end
        if variantFrame.chargeAnchorBarB then
            variantFrame.chargeAnchorBarB:Hide()
            variantFrame.chargeAnchorBarB:ClearAllPoints()
            variantFrame.chargeAnchorBarB = nil
        end
        
        -- Clear any stale dualFrameStatus flags on variant frame
        if variantFrame.meta then
            variantFrame.meta.dualFrameStatus = nil
        end
        
        -- Restore variant frame visibility
        ShowFrameElements(variantFrame)
    end

    
    -- ================================================================
    -- STEP 4: CREATE VARIANT FRAME IF NEEDED (but doesn't exist yet)
    -- ================================================================
    if shouldHaveVariant and not baseFrame.variantFrame then
        local variantFrame = self:CreateTrackerFrame(baseSpellID, trackerConfig, trackerType, true)
        baseFrame.variantFrame = variantFrame
        variantFrame.isVariant = true
        variantFrame.baseFrame = baseFrame
        baseFrame.variants = {baseFrame, variantFrame}
        variantFrame.variants = baseFrame.variants
    end
    
    -- ================================================================
    -- STEP 5: CREATE CHARGE ANCHOR BARS ON BASE FRAME
    -- ================================================================
    self:CreateChargeAnchorBars(baseFrame, trackerConfig, baseSpellID, false, false)
    
    -- Position base frame
    local pos = trackerConfig.position
    if baseFrame.chargeAnchorBarA then
        baseFrame:ClearAllPoints()
        baseFrame:SetPoint("CENTER", baseFrame.chargeAnchorBarA:GetStatusBarTexture(), "TOP", 0, 0)
    elseif pos and pos.anchorPoint and not baseFrame._inContainer then
        local xOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(baseFrame, "position.x")
        local yOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(baseFrame, "position.y")
        baseFrame:ClearAllPoints()
        baseFrame:SetPoint(
            pos.anchorPoint, 
            UIParent,
            pos.relativeAnchorPoint or pos.anchorPoint, 
            ((pos.x + (xOverride or 0)) or 0), 
            (pos.y + (yOverride or 0)) or 0
        )
    end
    
    -- ================================================================
    -- STEP 6: CREATE CHARGE ANCHOR BARS ON VARIANT FRAME IF IT EXISTS
    -- ================================================================
    if baseFrame.variantFrame then
        self:CreateChargeAnchorBars(baseFrame.variantFrame, trackerConfig, baseSpellID, true, false)
        
        -- Position variant frame (shares same position as base frame)
        if baseFrame.variantFrame.chargeAnchorBarA then
            baseFrame.variantFrame:ClearAllPoints()
            baseFrame.variantFrame:SetPoint("CENTER", baseFrame.variantFrame.chargeAnchorBarA:GetStatusBarTexture(), "TOP", 0, 0)
        elseif pos and pos.anchorPoint and not baseFrame.variantFrame._inContainer then
            local xOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(baseFrame.variantFrame, "position.x")
            local yOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(baseFrame.variantFrame, "position.y")
            baseFrame.variantFrame:ClearAllPoints()
            baseFrame.variantFrame:SetPoint(
                pos.anchorPoint, 
                UIParent,
                pos.relativeAnchorPoint or pos.anchorPoint, 
                ((pos.x + (xOverride or 0)) or 0), 
                (pos.y + (yOverride or 0)) or 0
            )
        end
    end
end

--- Middleware for creating tracker frames with proper charge infrastructure.
--- Use this instead of calling CreateTrackerFrame directly when creating new frames.
--- @param baseSpellID number The base spell ID
--- @param trackerConfig table The tracker configuration
--- @param trackerType string The tracker type
--- @return table baseFrame The created base frame
function FrameTrackerManager:CreateFrameMiddleware(baseSpellID, trackerConfig, trackerType)
    -- Create base frame (CreateTrackerFrame no longer creates charge bars internally)
    local baseFrame = self:CreateTrackerFrame(baseSpellID, trackerConfig, trackerType, false)
    
    if not baseFrame then return nil end
    
    -- Create variant frame if TrackerHasChargesConditionals, destroy/create all charge bars
    self:CreateChargeAnchorBarInfrastructure(baseSpellID, trackerType)
    
    -- Apply configuration changes to both frames
    self:UpdateFrame_ConfigurationChanges(baseSpellID, trackerType)
    
    -- Drive initial update to populate base frame with data (cooldown, charges, etc.)
    self:DriveFrameUpdate(
        baseFrame,
        {
            resolveDuration = true,
            syncChargeText = true
        },
        nil,
        "CreateFrameMiddleware_baseFrame"
    )
    
    -- Drive initial update for variant frame if it exists
    if baseFrame.variantFrame then
        self:DriveFrameUpdate(
            baseFrame.variantFrame,
            {
                resolveDuration = true,
                syncChargeText = true
            },
            nil,
            "CreateFrameMiddleware_variantFrame"
        )
    end
    
    return baseFrame
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

--- Internal: executes the actual CDM frame processing after the debounce window closes.
--- Called by ProcessCDMFrameCallback after coalescing multiple rapid-fire hook invocations.
--- @param cdm_frame table The Blizzard cooldown manager frame
--- @param trackerType string The tracker type ("buffs")
--- @param callers table Array of caller labels collected during the debounce window
local function _ExecuteProcessCDM(cdm_frame, trackerType, callers)
    local baseSpellID = FrameTrackerManager:ResolveCDMBaseSpellID(cdm_frame)
    local classSpecialization = State:GetCurrentSpecID()
    --its necessary to have a valid class specialization. Sometimes (like taking a portal) can cause it to return 0 resulting in a bad call to the database.
    local hasSpecialization = classSpecialization and classSpecialization ~= 0 and classSpecialization ~= '0'
    if hasSpecialization and baseSpellID and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] then
        -- Track active buffs for conditional engine
        if trackerType == "buffs" then
            local customFrame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
            if customFrame and customFrame.meta and customFrame.meta.currentAuraInstanceID and customFrame.meta.currentAuraInstanceID ~= 0 then
                -- Buff is active
                if SpellStyler.ConditionalEngine then
                    local activeBuffs = SpellStyler.ConditionalEngine.liveValues.activeBuffs or {}
                    activeBuffs[baseSpellID] = true
                    SpellStyler.ConditionalEngine:NotifySourceChanged("activeBuffs", activeBuffs)
                end
            end
        end
        -- Skip if mock cooldown is active
        local frame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
        if frame.meta.mockCooldownActive then
            return
        end
        
        if trackerType == "buffs" then
            pcall(function()
                --if the icon does NOT have a custom texture, then update it dynamically
                if not FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID].meta.customTexture then
                    local frame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                    local icon = cdm_frame.Icon or cdm_frame.icon
                    local texture = (icon.GetTexture and icon:GetTexture()) or icon.texture or cdm_frame.spellStyler_texture
                    if frame.meta.dualFrameStatus ~= 'hideBase' then frame.icon:SetTexture(texture) end
                    if frame.variantFrame and frame.meta.dualFrameStatus ~= 'hideVariant' then frame.variantFrame.icon:SetTexture(texture) end
                end
            end)
            
            local config = State:GetSpecificTrackerValue(baseSpellID, trackerType)
            local frame = FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
            -- Only trust GetAuraSpellInstanceID() when the Blizzard frame is actually
            -- shown (buff active). When hidden, the frame may still hold a stale
            -- non-zero ID from its previous application, which would incorrectly
            -- make Set Icon Visibility think the buff is still active.
            frame.meta.currentAuraInstanceID = cdm_frame:GetAuraSpellInstanceID() or 0
            if frame.variantFrame then frame.variantFrame.meta.currentAuraInstanceID = frame.meta.currentAuraInstanceID end
            if frame.meta.currentAuraInstanceID ~= 0 then
                frame.meta.buffStatus = 'present'
                if frame.variantFrame then frame.variantFrame.meta.buffStatus = 'present' end
            else
                frame.meta.buffStatus = 'absent'
                if frame.variantFrame then frame.variantFrame.meta.buffStatus = 'absent' end
            end

            if SpellStyler.ConditionalEngine then
                local activeBuffs = SpellStyler.ConditionalEngine.liveValues.activeBuffs or {}
                activeBuffs[baseSpellID] = frame.meta.currentAuraInstanceID ~= 0
                SpellStyler.ConditionalEngine:NotifySourceChanged("activeBuffs", activeBuffs)
            end

            -- Guard: config can be nil during spec transitions when a stale CDM frame
            -- fires while the new spec's database hasn't been built yet, or when the
            -- scan picked up an old-spec spell that the new spec doesn't track.
            if not config or not config.statusBar then return end
            
            -- Build combined caller string for debugging
            local callerStr = table.concat(callers, ", ")
            
            if frame.meta.dualFrameStatus ~= 'hideBase' then
                FrameTrackerManager:DriveFrameUpdate(
                    frame,
                    {
                        resolveDuration = true,
                        syncChargeText = true
                    },

                    nil,
                    "hookCallback_" .. callerStr
                )
            end
            if frame.variantFrame and frame.meta.dualFrameStatus ~= 'hideVariant' then 
                FrameTrackerManager:DriveFrameUpdate(
                    frame.variantFrame,
                    {
                        resolveDuration = true,
                        syncChargeText = true
                    },

                    nil,
                    "hookCallback_" .. callerStr
                )
            end
        end
    end
end

--- Handles CDM frame callbacks for buff tracking with debouncing.
--- Multiple rapid calls for the same CDM frame are coalesced into a single execution.
--- @param cdm_frame table The Blizzard cooldown manager frame
--- @param trackerType string The tracker type ("buffs")
--- @param caller string Debug label for the source of the call
local function ProcessCDMFrameCallback(cdm_frame, trackerType, caller)
    local q = FrameTrackerManager._processCDMQueue
    if not q[cdm_frame] then
        -- First call in this window: open the timer.
        q[cdm_frame] = {
            trackerType = trackerType,
            callers = { caller or "unknown" }
        }
        C_Timer.After(0.005, function()
            local entry = q[cdm_frame]
            if entry then
                _ExecuteProcessCDM(cdm_frame, entry.trackerType, entry.callers)
                q[cdm_frame] = nil
            end
        end)
    else
        -- Subsequent call within the same window: merge.
        local entry = q[cdm_frame]
        -- Append caller label for debugging
        table.insert(entry.callers, caller or "unknown")
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
                
                if data.customFrame.meta.currentAuraInstanceID ~= 0 and data.customFrame.meta.currentAuraInstanceID ~= nil then
                    local playerCount = C_UnitAuras.GetAuraApplicationDisplayCount("player", data.customFrame.meta.currentAuraInstanceID, 1)
                    local targetCount = C_UnitAuras.GetAuraApplicationDisplayCount("target", data.customFrame.meta.currentAuraInstanceID, 1)
                    local playerAuraData =        C_UnitAuras.GetAuraDataByAuraInstanceID("player", data.customFrame.meta.currentAuraInstanceID)
                    local targetAuraData =        C_UnitAuras.GetAuraDataByAuraInstanceID("target", data.customFrame.meta.currentAuraInstanceID)
                    local auraCountAsNumber =   (playerAuraData and playerAuraData.applications) or (targetAuraData and targetAuraData.applications) or 0
                    if data.config.countText.display then
                        data.customFrame.count:SetText(playerCount or targetCount)
                    else
                        data.customFrame.count:SetText("")
                    end

                    if data.customFrame.visualChargeBar and data.config.visualChargeBar and data.config.countText.renderAsStatusBar then
                        local s,e = pcall(function() data.customFrame.visualChargeBar:SetValue(auraCountAsNumber) end)
                        if e then
                            DevTool:AddData({
                                e = e,
                                playerAuraData = playerAuraData,
                                targetAuraData = targetAuraData,
                                auraCountAsNumber = auraCountAsNumber
                            }, "buff e")
                        else
                            DevTool:AddData({
                                e = e,
                                playerAuraData = playerAuraData,
                                targetAuraData = targetAuraData,
                                auraCountAsNumber = auraCountAsNumber
                            }, "buff no e")
                        end
                        -- Apply alpha based on displayState setting (cannot check currentCharges as it may be secret)
                        local displayState = data.config.visualChargeBar.displayState
                        local barAlpha
                        if displayState == "always" then
                            barAlpha = 1
                        elseif displayState == "available" or displayState == "inactive" then
                            barAlpha = auraCountAsNumber  -- Blizzard clamps secret values automatically
                        elseif displayState == "never" then
                            barAlpha = 0
                        else
                            barAlpha = 1  -- Default to always visible
                        end
                        data.customFrame.visualChargeBar:SetAlpha(barAlpha)
                    end

                    if data.config.chargeBasedDisplay.enabled or TrackerHasChargesConditionals(data.config) then
                        local chargeValue = auraCountAsNumber or 0
                        if data.customFrame.chargeAnchorBarA then
                            data.customFrame.chargeAnchorBarA:SetValue(chargeValue)
                            if data.customFrame.chargeAnchorBarB then
                                data.customFrame.chargeAnchorBarB:SetValue(chargeValue)
                            end
                        end
                    end
                else
                    if data.customFrame.visualChargeBar and data.config.visualChargeBar and data.config.countText.renderAsStatusBar then
                        local s,e = pcall(function() data.customFrame.visualChargeBar:SetValue(0) end)
                    end
                    data.customFrame.count:SetText("")
                    if data.config.chargeBasedDisplay.enabled or TrackerHasChargesConditionals(data.config) then
                        if data.customFrame.chargeAnchorBarA then
                            data.customFrame.chargeAnchorBarA:SetValue(0)
                            if data.customFrame.chargeAnchorBarB then
                                data.customFrame.chargeAnchorBarB:SetValue(0)
                            end
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
                    if data.config.chargeBasedDisplay.enabled or TrackerHasChargesConditionals(data.config) then
                        if data.customFrame.chargeAnchorBarA then
                            data.customFrame.chargeAnchorBarA:SetValue(currentCharges)
                            if data.customFrame.chargeAnchorBarB then
                                data.customFrame.chargeAnchorBarB:SetValue(currentCharges)
                            end
                        end
                    end
                    
                    -- Update visualChargeBar if visualChargeBar config exists
                    if data.customFrame.visualChargeBar and data.config.visualChargeBar and data.config.countText.renderAsStatusBar then
                        data.customFrame.visualChargeBar:SetValue(currentCharges)
                        local s,e = pcall(function() data.customFrame.visualChargeBar:SetValue(currentCharges) end)
                        -- Apply alpha based on displayState setting (cannot check currentCharges as it may be secret)
                        local displayState = data.config.visualChargeBar.displayState
                        local barAlpha
                        if displayState == "always" then
                            barAlpha = 1
                        elseif displayState == "available" or displayState == "inactive" then
                            barAlpha = currentCharges  -- Blizzard clamps secret values automatically
                        elseif displayState == "never" then
                            barAlpha = 0
                        else
                            barAlpha = 1  -- Default to always visible
                        end
                        data.customFrame.visualChargeBar:SetAlpha(barAlpha)
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
        
        -- Apply RGB color to icon texture
        context.customFrame.icon:SetVertexColor(
            color.r or 1,
            color.g or 1,
            color.b or 1,
            alpha
        )
        
        -- Apply combined alpha to iconContainer: dynamicAlpha * colorAlpha * opacitySettings
        local colorAlpha = color.a or 1
        context.customFrame.iconContainer:SetAlpha(colorAlpha)
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
    -- Skip duration resolution if mock cooldown is active BUT we don't have a pre-provided duration
    -- (If we have a durationObject, we're SETTING the mock cooldown, so we should continue)
    if data.customFrame and data.customFrame.meta and data.customFrame.meta.mockCooldownActive and not data.durationObject then
        return
    end
    
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
eventFrame:RegisterEvent("PLAYER_ALIVE")


local function eventHandlers(event, frame, meta)
    if event == "SPELL_DATA_LOAD_RESULT" then
        frame.meta.spellName = meta.spellName
        frame.meta.isSpellWithCharges = meta.isSpellWithCharges
        FrameTrackerManager:DriveFrameUpdate(
            frame, {
                resolveDuration = true,
                syncChargeText = true
            },
            nil,
            'spellDataLoaded'
        )
    end
    if event == "SPELL_UPDATE_CHARGES" then
        local isActive = C_Spell.GetSpellCharges(frame.meta.activeSpellID).isActive
        -- clear any active cooldown and reapply (This helps when a spell gains its final charge in the middle of a cooldown. It will clear, rather than compeltely the cooldown duration that means nothing at that point)
        if not isActive then
            if frame and frame.cooldown then frame.cooldown:Clear() end
            if frame and frame.statusBar then frame.statusBar:SetValue(0) end
            FrameTrackerManager:DriveFrameUpdate(
                frame, {
                    resolveDuration = false,
                    syncChargeText = true
                },
                nil,
                'spellupdateCharges'
            )
        else
            FrameTrackerManager:DriveFrameUpdate(
                frame, {
                    resolveDuration = true,
                    syncChargeText = true
                },
                nil,
                'spellupdateCharges'
            )
        end
    end
    if event == "UNIT_POWER_UPDATE" then
    end
    if event == "UNIT_AURA" then
        frame.meta.currentAuraInstanceID = 0 --clear
        frame.meta.buffStatus = 'absent'
        frame.cooldown:Clear()
        frame.statusBar:SetValue(0)
        FrameTrackerManager:DriveFrameUpdate(
            frame,
            {
                resolveDuration = false,
                syncChargeText = true
            },
            nil,
            "unitAura_explicitRemoval"
        )
    end
    if event == "SPELL_UPDATE_ICON" then
        frame.meta.activeSpellID = meta.activeSpellID
        frame.cooldown:Clear()
        frame.cooldown:Hide()
        FrameTrackerManager:DriveFrameUpdate(
            frame,
            {
                resolveDuration = true,
                syncChargeText = true
            },
            nil,
            "spellUpdateIcon"
        )
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
    end
    if event == "SPELL_UPDATE_COOLDOWN" then
    end
end

local function forceUpdateAllFrames()
    for _, tType in ipairs({"essential", "utility", "spells", "buffs"}) do
        if FrameTrackerManager.SpellStyler_frames[tType] then
            for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                -- Update configuration changes first
                FrameTrackerManager:UpdateFrame_ConfigurationChanges(baseSpellID, tType)
                
                -- Drive frame update for base frame
                if customFrame.meta.dualFrameStatus ~= 'hideBase' then
                    FrameTrackerManager:DriveFrameUpdate(
                        customFrame,
                        {
                            resolveDuration = true,
                            syncChargeText = true
                        },
                        nil,
                        "forceUpdateAllFrames"
                    )
                end
                
                -- Drive frame update for variant frame if it exists
                if customFrame.variantFrame and customFrame.meta.dualFrameStatus ~= 'hideVariant' then
                    FrameTrackerManager:DriveFrameUpdate(
                        customFrame.variantFrame,
                        {
                            resolveDuration = true,
                            syncChargeText = true
                        },
                        nil,
                        "forceUpdateAllFrames"
                    )
                end
            end
        end
    end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        hasPlayerEnetedWorld = true
        FrameTrackerManager:Initalize()
        pcall(forceUpdateAllFrames)
    end
    if event == "PLAYER_ALIVE" then
        pcall(forceUpdateAllFrames)
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
                            if customFrame.meta.dualFrameStatus ~= 'hideBase' then
                                eventHandlers(event, customFrame, {
                                    spellName = spellInfo.name,
                                    isSpellWithCharges = spellChargesInfo and spellChargesInfo.maxCharges > 1
                                })
                            end
                            if customFrame.variantFrame and customFrame.meta.dualFrameStatus ~= 'hideVariant' then
                                eventHandlers(event, customFrame.variantFrame, {
                                    spellName = spellInfo.name,
                                    isSpellWithCharges = spellChargesInfo and spellChargesInfo.maxCharges > 1
                                })
                            end
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
                    -- Skip if mock cooldown is active
                    if not customFrame.meta.mockCooldownActive then
                        local match = FrameTrackerManager:MatchTrackerFrame(baseSpellID)
                        if match and match.customFrame.meta.isSpellWithCharges then
                            if match.customFrame.meta.dualFrameStatus ~= 'hideBase' then eventHandlers("SPELL_UPDATE_CHARGES", match.customFrame, nil) end
                            if match.customFrame.variantFrame and match.customFrame.meta.dualFrameStatus ~= 'hideVariant' then eventHandlers("SPELL_UPDATE_CHARGES", match.customFrame.variantFrame, nil) end
                        end
                    end
                end
            end
        end
    end
    if event == "UNIT_POWER_UPDATE" then
        local unitTarget, powerType = ...
        if unitTarget == "player" then
            SpellStyler.ConditionalEngine:EvaluateAll()
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
            -- Skip if mock cooldown is active
            if customFrame.meta.isDurationActive and not customFrame.meta.mockCooldownActive then
                if customFrame.meta.dualFrameStatus ~= 'hideBase' then
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
                if customFrame.variantFrame and customFrame.meta.dualFrameStatus ~= 'hideVariant' then
                    FrameTrackerManager:DriveFrameUpdate(
                        customFrame.variantFrame,
                        {
                            resolveDuration = true,
                            syncChargeText = true
                        },
                        nil,
                        "respondingToPotentialModRateChange"
                    )
                end
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
            -- Skip if mock cooldown is active
            if not (customFrame.meta.mockCooldownActive) then
                local currentAuraInstanceID = customFrame.meta.currentAuraInstanceID or 0
                local shouldClear = removedAuraSet[currentAuraInstanceID]
                if shouldClear then
                    -- Track buff removal for conditional engine
                    if SpellStyler.ConditionalEngine then
                        local activeBuffs = SpellStyler.ConditionalEngine.liveValues.activeBuffs or {}
                        activeBuffs[baseSpellID] = false
                        SpellStyler.ConditionalEngine:NotifySourceChanged("activeBuffs", activeBuffs)
                    end
                    
                    if customFrame.meta.dualFrameStatus ~= 'hideBase' then eventHandlers("UNIT_AURA", customFrame, nil) end
                    if customFrame.variantFrame and customFrame.meta.dualFrameStatus ~= 'hideVariant' then eventHandlers("UNIT_AURA", customFrame.variantFrame, nil) end
                end
            end
        end
    end
    if event == "SPELL_UPDATE_ICON" then
        local spellID = ...
        if not spellID then return end
        pcall(function()
            local match = FrameTrackerManager:MatchTrackerFrame(spellID)
            if match then
                -- Skip if mock cooldown is active
                if match.customFrame.meta.mockCooldownActive then
                    return
                end
                
                local spellInfo = C_Spell.GetSpellInfo(spellID)
                if match.config.iconSettings.iconTexturePath == nil or match.config.iconSettings.iconTexturePath == '' then
                    match.customFrame.icon:SetTexture(spellInfo.iconID)
                    if match.customFrame.variantFrame then match.customFrame.variantFrame.icon:SetTexture(spellInfo.iconID) end
                end
                if (match.trackerType ~= 'buffs') then
                    --only reapply data for non-buffs. The buffs should be using the hooks to update their data
                    if match.customFrame.meta.dualFrameStatus ~= 'hideBase' then eventHandlers("SPELL_UPDATE_ICON", match.customFrame, { activeSpellID = C_Spell.GetOverrideSpell(match.baseSpellID) })  end
                    if match.customFrame.variantFrame and match.customFrame.meta.dualFrameStatus ~= 'hideVariant' then eventHandlers("SPELL_UPDATE_ICON", match.customFrame, { activeSpellID = C_Spell.GetOverrideSpell(match.baseSpellID) }) end
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
                DevTool:AddData({
                    unitTarget = unitTarget,
                    castGUID = castGUID,
                    spellID = spellID,
                    castBarID = castBarID
                }, "what was cast")
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
                        -- Skip if mock cooldown is active
                        if match.customFrame.meta.mockCooldownActive then
                            return
                        end
                        
                        local override = C_Spell.GetOverrideSpell(spellID)
                        if override ~= spellID then
                            local spellInfoUpdate = C_Spell.GetSpellInfo(override)
                            --The spell that was cast, is not equal to the active spell (likely due to changing via its cast). Wait for the spell cast to match the active in order to apply to correct/active cooldown
                            --Save the override spell onto the frame though to be able to check future casts
                            match.customFrame.meta.activeSpellID = override
                            if match.customFrame.variantFrame then
                                match.customFrame.variantFrame.meta.activeSpellID = override
                            end

                            -- Attempt to update charges if it mutated into a spell with charges
                            if match.customFrame.meta.dualFrameStatus ~= 'hideBase' then
                                FrameTrackerManager:DriveFrameUpdate(
                                    match.customFrame,
                                    {
                                        resolveDuration = false,
                                        syncChargeText = true
                                    },
                                    nil,
                                    "unitSpellcastSucceeded_spellOverwritten"
                                )
                            end
                            if match.customFrame.variantFrame and match.customFrame.meta.dualFrameStatus ~= 'hideVariant' then
                                FrameTrackerManager:DriveFrameUpdate(
                                    match.customFrame.variantFrame,
                                    {
                                        resolveDuration = false,
                                        syncChargeText = true
                                    },
                                    nil,
                                    "unitSpellcastSucceeded_spellOverwritten"
                                )
                            end
                        else
                            local spellInfo = C_Spell.GetSpellInfo(spellID)
                            -- FrameTrackerManager:ApplyCooldownDuration(match)
                            if match.customFrame.meta.dualFrameStatus ~= 'hideBase' then
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
                            if match.customFrame.variantFrame and match.customFrame.meta.dualFrameStatus ~= 'hideVariant' then
                                FrameTrackerManager:DriveFrameUpdate(
                                    match.customFrame.variantFrame,
                                    {
                                        resolveDuration = true,
                                        syncChargeText = true
                                    },
                                    nil,
                                    "unitSpellcastSucceeded_spellUnchanged"
                                )
                            end
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
            -- Skip if mock cooldown is active
            if frameMatchData.customFrame.meta.mockCooldownActive then
                return
            end
            
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
                    if frameMatchData.customFrame.meta.dualFrameStatus ~= 'hideBase' then
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
                    if frameMatchData.customFrame.variantFrame and frameMatchData.customFrame.meta.dualFrameStatus ~= 'hideVariant' then
                        FrameTrackerManager:DriveFrameUpdate(
                            frameMatchData.customFrame.variantFrame,
                            {
                                resolveDuration = true,
                                syncChargeText = true
                            },
                            nil,
                            "spellUpdateCooldown_updateOtherSpellsOnCooldown"
                        )
                    end
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
                    if frameMatchData.customFrame.variantFrame then
                        frameMatchData.customFrame.variantFrame.meta.activeSpellID = overrideSpellID
                    end
                    return
                end
                -- FrameTrackerManager:ApplyCooldownDuration(frameMatchData)
                if frameMatchData.customFrame.meta.dualFrameStatus ~= 'hideBase' then 
                    FrameTrackerManager:DriveFrameUpdate(
                        frameMatchData.customFrame,
                        {
                            resolveDuration = true,
                            syncChargeText = true
                        },
                        nil,
                        "spellUpdateCooldown_updateEventSpell"
                    )
                end
                if frameMatchData.customFrame.variantFrame and frameMatchData.customFrame.meta.dualFrameStatus ~= 'hideVariant' then
                    FrameTrackerManager:DriveFrameUpdate(
                        frameMatchData.customFrame.variantFrame,
                        {
                            resolveDuration = true,
                            syncChargeText = true
                        },
                        nil,
                        "spellUpdateCooldown_updateEventSpell"
                    )
                end
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
