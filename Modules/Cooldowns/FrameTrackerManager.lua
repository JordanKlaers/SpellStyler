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
---@field isVariantFrame boolean|nil    Whether this is a variant frame


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
    items = {}
}

FrameTrackerManager._driveQueue     = {}
FrameTrackerManager._processCDMQueue = {}
FrameTrackerManager._totemLogQueue  = {}
FrameTrackerManager._pendingFrameCreation = {}  -- Frames waiting to be created after dependency resolution
FrameTrackerManager._totemSpellQueue = {}  -- Queue of spell casts waiting to be matched with PLAYER_TOTEM_UPDATE: { spellID = expirationTime }
FrameTrackerManager._activeTotemSlots = {}  -- Maps active totem slots to frames: { slotIndex = frame }

local isInitialized = false

local function ApplyGlowNotificationSetup(frame, trackerConfig)
    if not SpellStyler.GlowUtil then return end
    local overrideColor = SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, "glowNotification.glowColor")
    local gn = overrideColor or trackerConfig and trackerConfig.glowNotification
    if not gn then return end
    local gc = gn.glowColor or {}
    local cfg = {
        r          = gc.r or 1,
        g          = gc.g or 1,
        b          = gc.b or 1,
        a          = gc.a or 1,
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

function FrameTrackerManager:SetMetaOnBaseAndVariant(frame, key, value)
    frame.meta[key] = value
    local otherFrame = (frame.variantFrame or frame.baseFrame)
    if otherFrame then
        otherFrame.meta[key] = value
    end
end

function FrameTrackerManager:SetPreviousPropertiesOnBaseAndVariant(frame, key, value)
    frame.previousProperties[key] = value
    local otherFrame = (frame.variantFrame or frame.baseFrame)
    if otherFrame then
        otherFrame.previousProperties[key] = value
    end
end

--- Updates collapsible containers when a frame's cooldown state changes.
--- Only processes containers that are marked as collapsible.
--- Uses the new statusBar-based positioning system for visibility and positioning.
--- @param frame table The tracker frame whose state changed
function FrameTrackerManager:UpdateCollapsibleContainers(frame)
    if not frame or not frame._inContainer then return end
    
    local Containers = SpellStyler.Containers
    if not Containers then return end
    
    -- Update visibility for this specific frame using the new statusBar system
    Containers:UpdateContainerFrameVisibility(frame)
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

            -- ── Step 4: Queue the custom SpellStyler frame for creation ──
            local trackerConfig = State:GetSpecificTrackerValue(spellID, trackerType)
            if trackerConfig then
                -- Wipe devNotes before creating frame (fresh start for error tracking)
                State:SetTrackerValueConfigProperty(spellID, trackerType, "devNotes", {})
                -- Queue for creation instead of creating immediately
                table.insert(FrameTrackerManager._pendingFrameCreation, {
                    baseSpellID = spellID,
                    trackerConfig = trackerConfig,
                    trackerType = trackerType
                })
            end
        end
    end

    -- Apply any saved viewer visibility setting
    SpellStyler.Containers:ApplyViewerVisibility("buffs")
    SpellStyler.Containers:ApplyViewerVisibility("essential")
    SpellStyler.Containers:ApplyViewerVisibility("utility")
end

--- Builds a tree structure organizing frames by their anchor dependencies
--- Frames anchored to UIParent are roots, others are organized under their anchor targets
--- @return table Tree structure with frames and their anchor children
function FrameTrackerManager:BuildAnchorDependencyTree()
    local pending = {}
    local tree = {}
    local processed = {}
    
    -- Copy pending frames to working list
    for _, frameData in ipairs(self._pendingFrameCreation) do
        table.insert(pending, frameData)
    end
    
    -- Helper to get anchor target key from a frame's config
    local function GetAnchorKey(frameData)
        local pos = frameData.trackerConfig.position
        if not pos or not pos.relativeToFrame then
            return "UIParent"
        end
        
        local relativeToFrame = pos.relativeToFrame
        -- Handle numeric baseSpellID (new format)
        if type(relativeToFrame) == "number" then
            -- Look up the trackerType for this baseSpellID
            -- Check all tracker types to find where this ID exists
            for _, tType in ipairs({"buffs", "spells", "items"}) do
                if SpellStyler.State then
                    local trackerValue = SpellStyler.State:GetSpecificTrackerValue(relativeToFrame, tType)
                    if trackerValue and trackerValue.trackerType then
                        return tType .. ":" .. relativeToFrame
                    end
                end
            end
            -- If we can't find it, default to UIParent
            return "UIParent"
        elseif type(relativeToFrame) == "string" then
            return relativeToFrame
        elseif type(relativeToFrame) == "table" then
            if relativeToFrame.uniqueID and relativeToFrame.trackerType then
                return relativeToFrame.trackerType .. ":" .. relativeToFrame.uniqueID
            end
        end
        return "UIParent"
    end
    
    -- Helper to get frame key
    local function GetFrameKey(frameData)
        return frameData.trackerType .. ":" .. frameData.baseSpellID
    end
    
    -- Helper to create tree node
    local function CreateTreeNode(frameData)
        return {
            baseSpellID = frameData.baseSpellID,
            trackerConfig = frameData.trackerConfig,
            trackerType = frameData.trackerType,
            anchorChildren = {}
        }
    end
    
    -- First pass: find all frames anchored to UIParent (roots)
    local remainingFrames = {}
    for _, frameData in ipairs(pending) do
        local anchorKey = GetAnchorKey(frameData)
        if anchorKey == "UIParent" or anchorKey == "Mouse" then
            local node = CreateTreeNode(frameData)
            table.insert(tree, node)
            processed[GetFrameKey(frameData)] = node
        else
            table.insert(remainingFrames, frameData)
        end
    end
    
    -- Continue looping until all frames are assigned or we can't make progress
    local maxIterations = 100  -- Prevent infinite loops
    local iteration = 0
    while #remainingFrames > 0 and iteration < maxIterations do
        iteration = iteration + 1
        local stillPending = {}
        local madeProgress = false
        
        for _, frameData in ipairs(remainingFrames) do
            local anchorKey = GetAnchorKey(frameData)
            local parentNode = processed[anchorKey]
            
            if parentNode then
                -- Found the parent, add as child
                local node = CreateTreeNode(frameData)
                table.insert(parentNode.anchorChildren, node)
                processed[GetFrameKey(frameData)] = node
                madeProgress = true
            else
                -- Parent not found yet, keep in pending
                table.insert(stillPending, frameData)
            end
        end
        
        remainingFrames = stillPending
        
        -- If we didn't make progress, we have circular dependencies or invalid anchors
        -- Create these frames as roots anchored to UIParent
        if not madeProgress and #remainingFrames > 0 then
            for _, frameData in ipairs(remainingFrames) do
                local node = CreateTreeNode(frameData)
                table.insert(tree, node)
                processed[GetFrameKey(frameData)] = node
            end
            break
        end
    end
    return tree
end

--- Recursively creates frames from the dependency tree
--- Creates parent frames first, then their anchor children
--- @param tree table The dependency tree structure
function FrameTrackerManager:CreateFramesFromDependencyTree(tree)
    local function CreateNodeAndChildren(node)
        -- Create this frame
        self:CreateCompleteFrame(node.baseSpellID, node.trackerConfig, node.trackerType)
        
        -- Recursively create all anchor children
        for _, childNode in ipairs(node.anchorChildren) do
            CreateNodeAndChildren(childNode)
        end
    end
    
    -- Create all root frames and their descendants
    for _, rootNode in ipairs(tree) do
        CreateNodeAndChildren(rootNode)
    end
    
    -- Clear the pending list
    wipe(self._pendingFrameCreation)
end

function FrameTrackerManager:CreateNonBuffTrackerFrames()
    for _, trackerType in ipairs({ "spells", "items" }) do
        local trackerValues = State:GetAllTrackerValues(trackerType)
        if trackerValues then
            for baseSpellID, trackerConfig in pairs(trackerValues) do
                -- Skip orphan entries: real entries always have trackerType set by AddTrackerValue.
                -- For items, skip the spell known check since items use itemID instead
                local shouldCreate = not FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
                    and trackerConfig.trackerType ~= nil
                    and trackerConfig.isEnabled ~= false
                
                -- If it's a spell, verify it's known; if it's an item, allow it through
                if shouldCreate then
                    if trackerConfig.isItem then
                        -- Item tracker - no spell check needed, items use itemID directly
                        shouldCreate = true
                    else
                        -- Spell tracker - verify spell is known
                        shouldCreate = C_SpellBook.IsSpellKnown(baseSpellID) or C_SpellBook.IsSpellKnown(trackerConfig.overrideSpellID)
                    end
                end
                
                if shouldCreate then
                    -- Wipe devNotes before creating frame (fresh start for error tracking)
                    State:SetTrackerValueConfigProperty(baseSpellID, trackerType, "devNotes", {})
                    -- Queue for creation instead of creating immediately
                    table.insert(FrameTrackerManager._pendingFrameCreation, {
                        baseSpellID = baseSpellID,
                        trackerConfig = trackerConfig,
                        trackerType = trackerType
                    })
                end
            end
        end
    end
end


--- Creates border frame with corners and edges for a status bar
--- @param frame table The parent frame
--- @param key string The field name on frame where the bar is stored
--- @param config table Border configuration: { borderColor = {r,g,b,a}, borderScale = number }
function FrameTrackerManager:CreateBorder(frame, key, config)
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
    frame[key].borderCornerTL:SetVertexColor(config.borderColor.r, config.borderColor.g, config.borderColor.b, config.borderColor.a)
    frame[key].borderCornerTL:SetScale(config.borderScale)

    -- Top-right corner (rotated 270°)
    frame[key].borderCornerTR = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerTR:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerTR:SetPoint("TOPRIGHT", frame[key].border, "TOPRIGHT", 1.5, 1.5)
    frame[key].borderCornerTR:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerTR:SetRotation(3 * math.pi / 2)
    frame[key].borderCornerTR:SetVertexColor(config.borderColor.r, config.borderColor.g, config.borderColor.b, config.borderColor.a)
    frame[key].borderCornerTR:SetScale(config.borderScale)

    -- Bottom-right corner (rotated 180°)
    frame[key].borderCornerBR = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerBR:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerBR:SetPoint("BOTTOMRIGHT", frame[key].border, "BOTTOMRIGHT", 1.5, -1.5)
    frame[key].borderCornerBR:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerBR:SetRotation(math.pi)
    frame[key].borderCornerBR:SetVertexColor(config.borderColor.r, config.borderColor.g, config.borderColor.b, config.borderColor.a)
    frame[key].borderCornerBR:SetScale(config.borderScale)

    -- Bottom-left corner (rotated 90°)
    frame[key].borderCornerBL = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderCornerBL:SetSize(cornerSize, cornerSize)
    frame[key].borderCornerBL:SetPoint("BOTTOMLEFT", frame[key].border, "BOTTOMLEFT", -1.5, -1.5)
    frame[key].borderCornerBL:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_corner.tga")
    frame[key].borderCornerBL:SetRotation(math.pi / 2)
    frame[key].borderCornerBL:SetVertexColor(config.borderColor.r, config.borderColor.g, config.borderColor.b, config.borderColor.a)
    frame[key].borderCornerBL:SetScale(config.borderScale)

    -- Top edge
    frame[key].borderEdgeTop = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderEdgeTop:SetHeight(edgeThickness)
    frame[key].borderEdgeTop:SetPoint("TOPLEFT", frame[key].borderCornerTL, "TOPRIGHT", 0, 0)
    frame[key].borderEdgeTop:SetPoint("TOPRIGHT", frame[key].borderCornerTR, "TOPLEFT", 0, 0)
    frame[key].borderEdgeTop:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line.tga")
    frame[key].borderEdgeTop:SetRotation(0)
    frame[key].borderEdgeTop:SetVertexColor(config.borderColor.r, config.borderColor.g, config.borderColor.b, config.borderColor.a)
    frame[key].borderEdgeTop:SetScale(config.borderScale)

    -- Right edge (vertical)
    frame[key].borderEdgeRight = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderEdgeRight:SetWidth(edgeThickness)
    frame[key].borderEdgeRight:SetPoint("TOPRIGHT", frame[key].borderCornerTR, "BOTTOMRIGHT", 0, 0)
    frame[key].borderEdgeRight:SetPoint("BOTTOMRIGHT", frame[key].borderCornerBR, "TOPRIGHT", 0, 0)
    frame[key].borderEdgeRight:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line_vertical.tga")
    frame[key].borderEdgeRight:SetRotation(math.pi)
    frame[key].borderEdgeRight:SetVertexColor(config.borderColor.r, config.borderColor.g, config.borderColor.b, config.borderColor.a)
    frame[key].borderEdgeRight:SetScale(config.borderScale)

    -- Bottom edge (rotated 180°)
    frame[key].borderEdgeBottom = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderEdgeBottom:SetHeight(edgeThickness)
    frame[key].borderEdgeBottom:SetPoint("BOTTOMRIGHT", frame[key].borderCornerBR, "BOTTOMLEFT", 0, 0)
    frame[key].borderEdgeBottom:SetPoint("BOTTOMLEFT", frame[key].borderCornerBL, "BOTTOMRIGHT", 0, 0)
    frame[key].borderEdgeBottom:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line.tga")
    frame[key].borderEdgeBottom:SetRotation(math.pi)
    frame[key].borderEdgeBottom:SetVertexColor(config.borderColor.r, config.borderColor.g, config.borderColor.b, config.borderColor.a)
    frame[key].borderEdgeBottom:SetScale(config.borderScale)

    -- Left edge (vertical)
    frame[key].borderEdgeLeft = frame[key].border:CreateTexture(nil, "ARTWORK")
    frame[key].borderEdgeLeft:SetWidth(edgeThickness)
    frame[key].borderEdgeLeft:SetPoint("BOTTOMLEFT", frame[key].borderCornerBL, "TOPLEFT", 0, 0)
    frame[key].borderEdgeLeft:SetPoint("TOPLEFT", frame[key].borderCornerTL, "BOTTOMLEFT", 0, 0)
    frame[key].borderEdgeLeft:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\statusBarBorder_line_vertical.tga")
    frame[key].borderEdgeLeft:SetRotation(0)
    frame[key].borderEdgeLeft:SetVertexColor(config.borderColor.r, config.borderColor.g, config.borderColor.b, config.borderColor.a)
    frame[key].borderEdgeLeft:SetScale(config.borderScale)
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
    FrameTrackerManager:CreateBorder(frame, key, {
        borderColor = {
            r = barConfig.borderColor.r or 0,
            g = barConfig.borderColor.g or 0,
            b = barConfig.borderColor.b or 0,
            a = forceHideViaAlpha and 0 or barConfig.borderColor.a or 1
        },
        borderScale = barConfig.borderScale or 1
    })

    -- Show statusBar frame once at creation; visibility controlled by alpha thereafter
    frame[key]:Show()
    -- Initial visibility is controlled by ApplyVisibility.StatusBar during the first DriveFrameUpdate
end

--- Helper to create a single charge anchor StatusBar
local function CreateSingleInvisibleChargeAnchorBar(frame, barName, minValue, maxValue)
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
    for _, barType in ipairs({ 'statusBar', 'visualChargeBar' }) do
        if frame[barType] then 
            frame[barType]:Hide()
            -- frame[barType]:SetAlpha(0)
            
            -- Critical: These textures are parented to the main frame, not[barType]
            -- So hiding[barType] doesn't hide them - must hide explicitly
            if frame[barType].bgTexture then 
                frame[barType].bgTexture:Hide()
                -- frame[barType].bgTexture:SetAlpha(0)
            end
            if frame[barType].fullCoverTexture then 
                frame[barType].fullCoverTexture:Hide()
                -- frame[barType].fullCoverTexture:SetAlpha(0)
            end
            if frame[barType].glowTexture then 
                frame[barType].glowTexture:Hide()
                -- frame[barType].glowTexture:SetAlpha(0)
            end
            
            -- Hide border frame and all its pieces
            if frame[barType].border then
                frame[barType].border:Hide()
                -- frame[barType].border:SetAlpha(0)
            end
            if frame[barType].borderCornerTL then frame[barType].borderCornerTL:Hide() end
            if frame[barType].borderCornerTR then frame[barType].borderCornerTR:Hide() end
            if frame[barType].borderCornerBR then frame[barType].borderCornerBR:Hide() end
            if frame[barType].borderCornerBL then frame[barType].borderCornerBL:Hide() end
            if frame[barType].borderEdgeTop then frame[barType].borderEdgeTop:Hide() end
            if frame[barType].borderEdgeRight then frame[barType].borderEdgeRight:Hide() end
            if frame[barType].borderEdgeBottom then frame[barType].borderEdgeBottom:Hide() end
            if frame[barType].borderEdgeLeft then frame[barType].borderEdgeLeft:Hide() end
        end
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
    
    for _, barType in ipairs({ 'statusBar', 'visualChargeBar' }) do
        if frame[barType] then 
            frame[barType]:Show()
            -- frame[barType]:SetAlpha(0)
            
            -- Critical: These textures are parented to the main frame, not[barType]
            -- So hiding[barType] doesn't Show them - must Show explicitly
            if frame[barType].bgTexture then 
                frame[barType].bgTexture:Show()
                -- frame[barType].bgTexture:SetAlpha(0)
            end
            if frame[barType].fullCoverTexture then 
                frame[barType].fullCoverTexture:Show()
                -- frame[barType].fullCoverTexture:SetAlpha(0)
            end
            if frame[barType].glowTexture then 
                frame[barType].glowTexture:Show()
                -- frame[barType].glowTexture:SetAlpha(0)
            end
            
            -- Show border frame and all its pieces
            if frame[barType].border then
                frame[barType].border:Show()
                -- frame[barType].border:SetAlpha(0)
            end
            if frame[barType].borderCornerTL then frame[barType].borderCornerTL:Show() end
            if frame[barType].borderCornerTR then frame[barType].borderCornerTR:Show() end
            if frame[barType].borderCornerBR then frame[barType].borderCornerBR:Show() end
            if frame[barType].borderCornerBL then frame[barType].borderCornerBL:Show() end
            if frame[barType].borderEdgeTop then frame[barType].borderEdgeTop:Show() end
            if frame[barType].borderEdgeRight then frame[barType].borderEdgeRight:Show() end
            if frame[barType].borderEdgeBottom then frame[barType].borderEdgeBottom:Show() end
            if frame[barType].borderEdgeLeft then frame[barType].borderEdgeLeft:Show() end
        end
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

FrameTrackerManager.InvisibleAnchorController = {
    GetRequiredBarsData = function(trackerConfig)
        local cbdConfig = trackerConfig.chargeBasedDisplay
        local hasChargeBasedDisplay = cbdConfig and cbdConfig.enabled
        local hasChargeBasedConditionPropertyOverride = false
        local conditionalData = nil
        if SpellStyler.ConditionalEngine and trackerConfig.specialVisibilityConditions then
            for _, condition in ipairs(trackerConfig.specialVisibilityConditions) do
                if condition.conditionalName 
                and SpellStyler.ConditionalEngine:ConditionalUsesCharges(condition.conditionalName)
                and condition.propertyOverrides then
                    -- Check if at least one property override has both property and value defined
                    local hasValidOverride = false
                    for _, override in ipairs(condition.propertyOverrides) do
                        if override.property and override.property ~= "" and override.value ~= nil and override.value ~= "" then
                            hasValidOverride = true
                            break
                        end
                    end
                    if hasValidOverride then
                        conditionalData = SpellStyler.ConditionalEngine:GetChargeConditionalData(condition.conditionalName)
                        if conditionalData then
                            hasChargeBasedConditionPropertyOverride = true
                            break
                        end
                    end
                end
            end
        end
        return hasChargeBasedDisplay, hasChargeBasedConditionPropertyOverride, conditionalData
    end,
    CalculateRequiredBarProperties = function(hasChargeBasedDisplay, conditionalData, isVariantFrame, trackerConfig)
        local visibilityValue = hasChargeBasedDisplay and (trackerConfig.chargeBasedDisplay.chargeValue or 1) or nil
        local visibilityOperator = hasChargeBasedDisplay and (trackerConfig.chargeBasedDisplay.displayOperator or ">") or nil
        local visibilityMode = hasChargeBasedDisplay and (trackerConfig.chargeBasedDisplay.displayState and "show" or "hide") or nil
        
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
            A = {min = 0, max = 0, anchor = nil, shouldRender = false},
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
        return constructorValues, caseType
    end,
    CreateBars = function(frame, constructorValues, baseSpellID)
        if not frame.chargeAnchorBarB then
            frame.chargeAnchorBarB = CreateSingleInvisibleChargeAnchorBar(
                frame, "ChargeAnchorBar_" .. baseSpellID .. "_B", constructorValues.B.min, constructorValues.B.max
            )
        end
        
        if not frame.chargeAnchorBarA then
            frame.chargeAnchorBarA = CreateSingleInvisibleChargeAnchorBar(
                frame, "ChargeAnchorBar_" .. baseSpellID .. "_A", constructorValues.A.min, constructorValues.A.max
            )
        end
    end,
    SetBarPropertiesAndFrameAnchor = function(frame, constructorValues, trackerConfig)
        --both bars
        if constructorValues.B.shouldRender and constructorValues.A.shouldRender then
            -- Track which bars are active and their anchor configuration for drag/positioning
            -- Each frame gets its own anchorModeData since base and variant can have different bar setups
            frame.meta.anchorModeData = {
                type = 'both',
                point = constructorValues.B.anchor or 'BOTTOM',  -- Bar B's anchor point (TOP or BOTTOM)
                pointA = constructorValues.A.anchor or 'BOTTOM',  -- Bar A's anchor point (TOP or BOTTOM)
                relativePoint = trackerConfig.position.relativeAnchorPoint or trackerConfig.position.anchorPoint or 'BOTTOM'  -- UIParent's anchor point
            }
            
            frame.chargeAnchorBarB:SetMinMaxValues(constructorValues.B.min, constructorValues.B.max)
            -- Note: Bar B's position to UIParent will be set by SetFramePosition (which calls ClearAllPoints)
            frame.chargeAnchorBarB:Show()

            frame.chargeAnchorBarA:SetMinMaxValues(constructorValues.A.min, constructorValues.A.max)
            frame.chargeAnchorBarA:ClearAllPoints()
            frame.chargeAnchorBarA:SetPoint(constructorValues.A.anchor, frame.chargeAnchorBarB:GetStatusBarTexture(), "TOP", 0, 0)
            frame.chargeAnchorBarA:Show()
            
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", frame.chargeAnchorBarA:GetStatusBarTexture(), "TOP", 0, 0)
        -- just one bar
        elseif constructorValues.A.shouldRender then
            -- Track that only bar A is active and its anchor configuration
            -- Each frame gets its own anchorModeData since base and variant can have different bar setups
            frame.meta.anchorModeData = {
                type = 'barA',
                point = constructorValues.A.anchor or 'BOTTOM',  -- Bar A's anchor point (TOP or BOTTOM)
                relativePoint = trackerConfig.position.relativeAnchorPoint or trackerConfig.position.anchorPoint or 'BOTTOM'  -- UIParent's anchor point
            }
            
            frame.chargeAnchorBarA:SetMinMaxValues(constructorValues.A.min, constructorValues.A.max)
            -- Note: Bar A's position to UIParent will be set by SetFramePosition (which calls ClearAllPoints)
            frame.chargeAnchorBarA:Show()
            
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", frame.chargeAnchorBarA:GetStatusBarTexture(), "TOP", 0, 0)
            
            -- Hide bar B when only bar A is needed
            if frame.chargeAnchorBarB then
                frame.chargeAnchorBarB:Hide()
            end
        else
        -- no bars
            -- Track that no bars are active
            -- Each frame gets its own anchorModeData since base and variant can have different bar setups
            frame.meta.anchorModeData = {
                type = 'none',
                point = nil,
                relativePoint = nil
            }
            
            -- Hide both bars when they're not needed
            if frame.chargeAnchorBarA then
                frame.chargeAnchorBarA:Hide()
                frame.chargeAnchorBarA:ClearAllPoints()
            end
            if frame.chargeAnchorBarB then
                frame.chargeAnchorBarB:Hide()
                frame.chargeAnchorBarB:ClearAllPoints()
            end
            
            -- Critical: Clear frame's anchor points so it's not anchored to hidden bars
            -- This ensures frame is visible when position is set
            frame:ClearAllPoints()
            -- Note: Position cache is cleared at the start of CreateInvisibleAnchorControllerBars
        end
    end,
    FlagAndHideUnusedFrames = function(frame, isVariantFrame, caseType, conditionalData, hasChargeBasedDisplay)
        -- If there's no conditionalData, variant frame should not exist
        if not conditionalData then
            FrameTrackerManager:SetMetaOnBaseAndVariant(frame, 'dualFrameStatus', 'hideVariant')
            if isVariantFrame then
                HideFrameElements(frame)
            else
                ShowFrameElements(frame)
            end
            return
        end
        
        -- Handle frame visibility based on case type (unless skipped for drag operations)
        -- Cases A, B, G, H: Single-frame cases - hide the unused frame
        -- Cases C, D, E, F: Dual-frame cases - ensure both frames are visible (restore if previously hidden)
        
        local shouldHide, hideStatus
        if caseType == "A" or caseType == "G" then
            shouldHide, hideStatus = isVariantFrame, 'hideVariant'
        elseif caseType == "B" or caseType == "H" then
            shouldHide, hideStatus = not isVariantFrame, 'hideBase'
        end
        
        if shouldHide then
            FrameTrackerManager:SetMetaOnBaseAndVariant(frame, 'dualFrameStatus', hideStatus)
            HideFrameElements(frame)
        else
            FrameTrackerManager:SetMetaOnBaseAndVariant(frame, 'dualFrameStatus', nil)
            ShowFrameElements(frame)
        end
    end

}

--- Unified function to create/update charge anchor bars for both visibility and conditionals
--- Handles all 8 cases (A-H) automatically based on configuration
--- This function always creates/updates BOTH bars (A and B) for reusability:
--- - If bars don't exist, they are created
--- - If bars exist, their min/max values and anchor points are updated
--- - Bar B is always anchored to UIParent when shouldRender is true
--- - Bar A is anchored to Bar B's texture (dual-bar) or UIParent (single-bar) based on shouldRender flags
--- - Frame visibility is controlled via dualFrameStatus and Hide/ShowFrameElements
--- @param frame table The tracker frame
--- @param trackerConfig table The tracker configuration
--- @param baseSpellID number The base spell ID
--- @param isVariantFrame boolean Whether this is a variant frame
--- @param skipVisibilityUpdate boolean Whether to skip visibility updates (used during drag)
function FrameTrackerManager:CreateInvisibleAnchorControllerBars(frame, trackerConfig, baseSpellID, isVariantFrame, skipVisibilityUpdate)

    -- Clear position cache to ensure SetFramePosition runs after anchor mode changes
    -- This is critical because toggling charge-based display changes anchor mode (none/barA/both)
    -- without changing position config, but element positioning must be recalculated
    if frame.previousProperties then
        frame.previousProperties.position = nil
    end

    local hasChargeBasedDisplay, hasChargeBasedConditionPropertyOverride, conditionalData = FrameTrackerManager.InvisibleAnchorController.GetRequiredBarsData(trackerConfig)
    local constructorValues, caseType = FrameTrackerManager.InvisibleAnchorController.CalculateRequiredBarProperties(hasChargeBasedDisplay, conditionalData, frame.meta.isVariantFrame, trackerConfig)
    FrameTrackerManager.InvisibleAnchorController.CreateBars(frame, constructorValues, baseSpellID)
    FrameTrackerManager.InvisibleAnchorController.SetBarPropertiesAndFrameAnchor(frame, constructorValues, trackerConfig)
    FrameTrackerManager.InvisibleAnchorController.FlagAndHideUnusedFrames(frame, isVariantFrame, caseType, conditionalData, hasChargeBasedDisplay)
end


--[[
    Minimal data structure for FrameBuilder methods:
    {
        frameName = string,          -- Frame name for CreateFrame
        baseSpellID = number,         -- Base spell ID for registry and status bars
        trackerType = string,         -- Type: "spells", "buffs"
        isVariantFrame = boolean,     -- Whether this is a variant frame
        trackerConfig = table,        -- Complete configuration (contains all settings)
        frame = table|nil            -- Frame reference (nil until Base creates it)
    }
    
    Meta (TrackerFrameMeta) is constructed inside Base() method from the above fields.
    All other values (dimensions, colors, textures, etc.) are derived from 
    trackerConfig or API calls within each FrameBuilder method.
]]

--- Helper function to convert cursor position to UIParent-relative coordinates
--- @param anchorPoint string The anchor point to calculate offset from
--- @return number offsetX, number offsetY
local function GetCursorPositionRelativeToUIParent(anchorPoint)
    local scale = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    
    -- Calculate offset based on anchor point
    if anchorPoint == "CENTER" or not anchorPoint then
        local uiX, uiY = UIParent:GetCenter()
        return x - uiX, y - uiY
    end
    
    local left, bottom, width, height = UIParent:GetRect()
    
    if anchorPoint == "TOPLEFT" then
        return x - left, y - (bottom + height)
    elseif anchorPoint == "BOTTOMLEFT" then
        return x - left, y - bottom
    elseif anchorPoint == "TOPRIGHT" then
        return x - (left + width), y - (bottom + height)
    elseif anchorPoint == "BOTTOMRIGHT" then
        return x - (left + width), y - bottom
    elseif anchorPoint == "TOP" then
        local uiX = UIParent:GetCenter()
        return x - uiX, y - (bottom + height)
    elseif anchorPoint == "BOTTOM" then
        local uiX = UIParent:GetCenter()
        return x - uiX, y - bottom
    elseif anchorPoint == "LEFT" then
        local _, uiY = UIParent:GetCenter()
        return x - left, y - uiY
    elseif anchorPoint == "RIGHT" then
        local _, uiY = UIParent:GetCenter()
        return x - (left + width), y - uiY
    end
    
    -- Default to CENTER
    local uiX, uiY = UIParent:GetCenter()
    return x - uiX, y - uiY
end

--- Resolves relativeToFrame from various formats and sets frame position
--- Handles: numeric baseSpellID, string ("UIParent", "Mouse", frame name), table (frame object or {uniqueID, trackerType}), nil
--- When charge anchor bars are active, positions the appropriate bar instead of the frame
--- @param frame table The frame to position
--- @param trackerConfig table The tracker configuration containing position data
function FrameTrackerManager:SetFramePosition(frame, trackerConfig)
    -- Determine which element should be positioned based on charge anchor mode
    local elementToPosition = frame
    local anchorModeData = frame.meta and frame.meta.anchorModeData
    local useBarAnchorPoint = false  -- Flag to use bar's specific anchor point instead of user's
    local barAnchorPoint = nil
    
    if anchorModeData and anchorModeData.type == "both" and frame.chargeAnchorBarB then
        -- Both bars active: position bar B (anchored to UIParent)
        elementToPosition = frame.chargeAnchorBarB
        useBarAnchorPoint = true
        barAnchorPoint = anchorModeData.point  -- Use the specific anchor point for this bar (TOP or BOTTOM)
    elseif anchorModeData and anchorModeData.type == "barA" and frame.chargeAnchorBarA then
        -- Only bar A active: position bar A (anchored to UIParent)
        elementToPosition = frame.chargeAnchorBarA
        useBarAnchorPoint = true
        barAnchorPoint = anchorModeData.point  -- Use the specific anchor point for this bar (TOP or BOTTOM)
    end
    -- Otherwise position the frame itself (anchorModeData.type == "none" or no bars exist)
    
    -- Get the frame's scale to compensate for position offsets
    -- When SetScale is applied, the x/y offsets are also scaled, so we need to divide by scale
    local frameScale = frame:GetScale() or 1
    
    elementToPosition:ClearAllPoints()
    -- Cancel any existing mouse follow ticker
    if frame.mouseFollowTicker then
        frame.mouseFollowTicker:Cancel()
        frame.mouseFollowTicker = nil
    end
    
    local pos = trackerConfig.position
    if pos and pos.anchorPoint and pos.x and pos.y then
        -- Resolve relativeToFrame to actual frame object
        local relativeFrame = UIParent
        if pos.relativeToFrame then
            if type(pos.relativeToFrame) == "number" then
                -- It's a baseSpellID, look it up
                for _, tType in ipairs({"buffs", "spells", "items"}) do
                    local targetFrame = FrameTrackerManager.SpellStyler_frames[tType] 
                                      and FrameTrackerManager.SpellStyler_frames[tType][pos.relativeToFrame]
                    if targetFrame then
                        relativeFrame = targetFrame
                        break
                    end
                end
            elseif type(pos.relativeToFrame) == "string" then
                if pos.relativeToFrame == "Mouse" then
                    -- Set up mouse following with a ticker (updates ~30 times per second)
                    local anchorPt = useBarAnchorPoint and barAnchorPoint or pos.anchorPoint
                    local relativeAnchorPt = useBarAnchorPoint and (anchorModeData.relativePoint or pos.anchorPoint) or (pos.relativeAnchorPoint or pos.anchorPoint)
                    local mouseX, mouseY = GetCursorPositionRelativeToUIParent(relativeAnchorPt)
                    local xOffset = 0 --frame.meta.isVariantFrame and 50 or 0
                    elementToPosition:SetPoint(
                        anchorPt,
                        UIParent,
                        relativeAnchorPt,
                        (mouseX + (pos.x or 0) + xOffset) / frameScale,
                        (mouseY + (pos.y or 0)) / frameScale
                    )
                    
                    -- Start ticker to continuously update position
                    -- Store references needed for dynamic config lookup
                    frame._mouseAnchorBaseSpellID = frame.meta and frame.meta.baseSpellID
                    frame._mouseAnchorTrackerType = frame._trackerType
                    
                    frame.mouseFollowTicker = C_Timer.NewTicker(0.03, function()
                        if not frame:IsShown() then return end
                        
                        -- Read current config values dynamically so arrow key changes are respected
                        local currentConfig = State:GetSpecificTrackerValue(frame._mouseAnchorBaseSpellID, frame._mouseAnchorTrackerType)
                        if not currentConfig or not currentConfig.position or currentConfig.position.relativeToFrame ~= "Mouse" then
                            -- Config changed, cancel this ticker
                            if frame.mouseFollowTicker then
                                frame.mouseFollowTicker:Cancel()
                                frame.mouseFollowTicker = nil
                            end
                            return
                        end
                        
                        local currentPos = currentConfig.position
                        local currentAnchorPt = useBarAnchorPoint and barAnchorPoint or currentPos.anchorPoint
                        local currentRelativeAnchorPt = useBarAnchorPoint and (anchorModeData.relativePoint or currentPos.anchorPoint) or (currentPos.relativeAnchorPoint or currentPos.anchorPoint)
                        local mx, my = GetCursorPositionRelativeToUIParent(currentRelativeAnchorPt)
                        local currentXOffset = 0 --frame.meta.isVariantFrame and 50 or 0
                        local currentScale = frame:GetScale() or 1
                        elementToPosition:ClearAllPoints()
                        elementToPosition:SetPoint(
                            currentAnchorPt,
                            UIParent,
                            currentRelativeAnchorPt,
                            (mx + (currentPos.x or 0) + currentXOffset) / currentScale,
                            (my + (currentPos.y or 0)) / currentScale
                        )
                    end)
                    return  -- Skip the standard SetPoint at the end
                elseif pos.relativeToFrame == "UIParent" then
                    relativeFrame = UIParent
                else
                    -- Try to resolve as frame name
                    relativeFrame = _G[pos.relativeToFrame] or UIParent
                end
            elseif type(pos.relativeToFrame) == "table" then
                if pos.relativeToFrame.GetObjectType then
                    -- It's already a frame object
                    relativeFrame = pos.relativeToFrame
                elseif pos.relativeToFrame.uniqueID and pos.relativeToFrame.trackerType then
                    -- Legacy format {uniqueID, trackerType}
                    local targetFrame = FrameTrackerManager.SpellStyler_frames[pos.relativeToFrame.trackerType]
                                      and FrameTrackerManager.SpellStyler_frames[pos.relativeToFrame.trackerType][pos.relativeToFrame.uniqueID]
                    if targetFrame then
                        relativeFrame = targetFrame
                    end
                end
            end
        end
        local bonusOffSet = 0 --frame.meta.isVariantFrame and 50 or 0
        local finalAnchorPoint = useBarAnchorPoint and barAnchorPoint or pos.anchorPoint
        local finalRelativeAnchorPoint = useBarAnchorPoint and (anchorModeData.relativePoint or pos.anchorPoint) or (pos.relativeAnchorPoint or pos.anchorPoint)

        elementToPosition:SetPoint(
            finalAnchorPoint, 
            relativeFrame,
            finalRelativeAnchorPoint, 
            ((pos.x or 0) + bonusOffSet) / frameScale, 
            (pos.y or 0) / frameScale
        )
    else
        -- Default position - center with offset
        elementToPosition:SetPoint("CENTER", UIParent, "CENTER", -200 / frameScale, -100 / frameScale)
    end
end

FrameTrackerManager.FrameBuilder = {
    Base = function(data)
        local frame = CreateFrame("Button", data.frameName, UIParent, "BackdropTemplate")
        
        -- Only add base frames to the global registry; variant frames are stored on their base frame
        if not data.isVariantFrame then
            FrameTrackerManager.SpellStyler_frames[data.trackerType][data.baseSpellID] = frame
        end
        
        -- Construct frame metadata from data fields and API calls
        C_Spell.RequestLoadSpellData(data.trackerConfig.overrideSpellID or data.baseSpellID)
        local spellChargesInfo = C_Spell.GetSpellCharges(data.trackerConfig.overrideSpellID or data.baseSpellID)
        local spellInfo = C_Spell.GetSpellInfo(data.trackerConfig.overrideSpellID or data.baseSpellID)
        
        ---@type TrackerFrameMeta
        frame.meta = {
            itemID = data.itemID or nil,
            isVariantFrame = data.isVariantFrame,
            spellName = spellInfo.name,
            baseSpellID = data.baseSpellID,
            trackerType = data.trackerType,
            buffStatus = 'absent',
            isTotem = data.trackerConfig.iconSettings.isTotem,
            activeSpellID = data.trackerConfig.overrideSpellID or data.baseSpellID,
            isSpellWithCharges = spellChargesInfo and spellChargesInfo.maxCharges > 1,
            isDurationActive = false,
            mockCooldownActive = false,
            currentAuraInstanceID = 0,
            customTexture = data.trackerConfig.iconSettings.iconTexturePath ~= '' and data.trackerConfig.iconSettings.iconTexturePath ~= nil and data.trackerConfig.iconSettings.iconTexturePath or nil
        }
        
        -- Store trackerType at top level for easy access (used by mouse anchor ticker)
        frame._trackerType = data.trackerType

        -- This stores previous values so that it only updates values that are different than the previous
        frame.previousProperties = {}
        
        -- Only set the icon's own size when it is not managed by a container.
        local iconW = data.trackerConfig.iconSettings.width or data.trackerConfig.iconSettings.size or 48
        local iconH = data.trackerConfig.iconSettings.height or data.trackerConfig.iconSettings.size or 48
        if not frame._inContainer then
            frame:SetSize(iconW, iconH)
        end
        frame:SetFrameStrata(data.trackerConfig.iconSettings.frameStrataLevel or "MEDIUM")
        frame:SetFrameLevel(data.trackerConfig.iconSettings.frameStrataValue or 100)
        frame:SetMovable(true)
        frame:SetClampedToScreen(false)
        frame:EnableMouse(false)  -- Don't eat mouse clicks - Layout overlay handles that

        -- Set frame position using shared helper
        FrameTrackerManager:SetFramePosition(frame, data.trackerConfig)
        frame:Show()
        return frame
    end,
    Icon = function(data)
        data.frame.iconContainer = CreateFrame('Frame', 'iconContainer_' .. data.frame.meta.activeSpellID, data.frame)
        data.frame.iconContainer:SetAllPoints(data.frame)
        data.frame.iconContainer:SetFrameLevel(data.frame:GetFrameLevel() - 1)
        
        -- Icon texture (created on iconContainer, referenced via frame.icon)
        data.frame.icon = data.frame.iconContainer:CreateTexture(nil, "ARTWORK")
        data.frame.Icon = data.frame.icon

        data.frame.icon:SetAllPoints(data.frame.iconContainer)
        local zoom = data.trackerConfig.iconSettings.zoom and (data.trackerConfig.iconSettings.zoom / 100) or 0
        data.frame.icon:SetTexCoord(0 + zoom, 1 - zoom, 0 + zoom, 1 - zoom)
        
        -- Get icon texture
        local iconTexture = data.frame.meta.customTexture or data.trackerConfig.defaultIconTexturePath
        
        -- For items, defaultIconTexturePath is already the resolved texture path (not itemID)
        -- No conversion needed
        
        data.frame.icon:SetTexture(iconTexture)
        
        -- Apply color (RGB only, alpha goes on iconContainer)
        local color = data.trackerConfig.iconColor or {}
        data.frame.icon:SetVertexColor(
            color.r or 1,
            color.g or 1,
            color.b or 1
        )
        data.frame.iconContainer:SetAlpha(color.a or 1)
        data.frame.icon:SetDesaturated(false)
    end,
    Border = function(data)
        -- Create separate border frame
        data.frame.borderFrame = CreateFrame("Frame", data.frameName .. "_Border", data.frame, "BackdropTemplate")
        
        -- Set frame level to be 1 above the iconContainer
        data.frame.borderFrame:SetFrameLevel(data.frame:GetFrameLevel() + 1)
        
        -- Size border frame: if borderSize > 0, extend outside icon; otherwise match icon size
        local iconW = data.trackerConfig.iconSettings.width or data.trackerConfig.iconSettings.size or 48
        local iconH = data.trackerConfig.iconSettings.height or data.trackerConfig.iconSettings.size or 48
        local borderSize = data.trackerConfig.iconSettings.borderSize or 0
        if borderSize > 0 then
            data.frame.borderFrame:SetSize(iconW + borderSize * 2, iconH + borderSize * 2)
        else
            data.frame.borderFrame:SetSize(iconW, iconH)
            borderSize = borderSize * -1
        end
        data.frame.borderFrame:SetPoint("CENTER", data.frame, "CENTER", 0, 0)
        
        -- Apply backdrop with only edge (no background or insets)
        data.frame.borderFrame:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = borderSize
        })
        data.frame.borderFrame:SetBackdropColor(0,0,0,0)
        data.frame.borderFrame:SetBackdropBorderColor(
            data.trackerConfig.iconSettings.borderColor.r,
            data.trackerConfig.iconSettings.borderColor.g,
            data.trackerConfig.iconSettings.borderColor.b,
            data.trackerConfig.iconSettings.borderColor.a
        )
    end,
    Cooldown = function(data)
        data.frame.cooldown = CreateFrame("Cooldown", data.frameName .. "_Cooldown", data.frame, "CooldownFrameTemplate")
        data.frame.Cooldown = data.frame.cooldown
        data.frame.cooldown:SetAllPoints(data.frame.iconContainer)
        data.frame.cooldown:SetFrameLevel(data.frame.iconContainer:GetFrameLevel() + 1)  -- Above icon texture
        data.frame.cooldown:SetDrawEdge(true)
        data.frame.cooldown:SetDrawBling(false)
        data.frame.cooldown:SetSwipeColor(0, 0, 0, 0.8)
        
        -- Apply sweep and countdown text settings (per-icon overrides tracker-level)
        local hideSweep = data.trackerConfig.iconSettings.hideDefaultSweep
        local showCountdownText = data.trackerConfig.cooldownText.display
        data.frame.cooldown:SetDrawSwipe(hideSweep)
        data.frame.cooldown:SetHideCountdownNumbers(not showCountdownText)
        
        data.frame.cooldown:SetScript("OnShow", function(self)
            FrameTrackerManager:SetMetaOnBaseAndVariant(data.frame, 'isDurationActive', true)
        end)

        data.frame.cooldown:SetScript("OnHide", function(self)
        end)

        data.frame.cooldown:SetScript("OnCooldownDone", function(self)
            FrameTrackerManager:SetMetaOnBaseAndVariant(data.frame, 'isDurationActive', false)
            local gn = data.trackerConfig.glowNotification
            if gn and gn.shouldDisplay then
                if gn.glowStyle == 'thick' then
                    SpellStyler.GlowUtil:PlayProcGlow(data.frame, gn.duration)
                else
                    SpellStyler.GlowUtil:PlayAnts(data.frame, gn.duration)
                end
            end
            -- If mock cooldown is active, disable it and update button text. This setup is in IconSettingsRenderer.lua
            if data.frame.meta.mockCooldownActive then
                FrameTrackerManager:SetMetaOnBaseAndVariant(data.frame, 'mockCooldownActive', false)
                -- Update the mock cooldown button text if it exists and is still valid
                if data.frame._spellStyler_mockCooldownBtn then
                    pcall(function()
                        data.frame._spellStyler_mockCooldownBtn:SetText("Mock Cooldown")
                    end)
                end
            end
            C_Timer.After(0, function()
                SpellStyler.ConditionalEngine:EvaluateAll()
            end)
            
            FrameTrackerManager:DriveFrameUpdate(
                data.frame,
                {
                    resolveDuration = false,
                    syncChargeText = true
                },
                nil,
                "onCooldownDone"
            )
            if data.frame.variantFrame then 
                FrameTrackerManager:DriveFrameUpdate(
                    data.frame.variantFrame,
                    {
                        resolveDuration = false,
                        syncChargeText = true
                    },
                    nil,
                    "onCooldownDone"
                )
            end
        end)
    end,
    CooldownBar = function(data)
        FrameTrackerManager:CreateStatusBar(data.frame, "statusBar", data.trackerConfig, data.baseSpellID, data.trackerType, nil, nil, nil, "statusBar")
    end,
    TotemBar = function(data)
        FrameTrackerManager:CreateStatusBar(data.frame, "totemBar", data.trackerConfig, data.baseSpellID, data.trackerType, nil, nil, nil, "totemBar")
    end,
    Count = function(data)
        data.frame.count = data.frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        data.frame.Count = data.frame.count  -- Masque expects .Count
        -- Apply saved countText settings at creation
        local countCfg = data.trackerConfig.countText
        local countOffX = (countCfg and countCfg.x or 0) - 2
        local countOffY = (countCfg and countCfg.y or 0) + 2
        data.frame.count:SetPoint("BOTTOMRIGHT", data.frame, "BOTTOMRIGHT", countOffX, countOffY)
        data.frame.count:SetJustifyH("RIGHT")
        data.frame.count:SetDrawLayer("OVERLAY", 7)
        if countCfg and countCfg.size then
            local _fontPath, _, _fontFlags = data.frame.count:GetFont()
            local fontPath = State:ResolveFontPath(countCfg.font, _fontPath)
            local fontFlags = State:ResolveFontFlags(countCfg.fontFlags, _fontFlags)
            data.frame.count:SetFont(fontPath, countCfg.size, fontFlags or "OUTLINE")
        end
        if countCfg and countCfg.color then
            data.frame.count:SetTextColor(
                countCfg.color.r or 1,
                countCfg.color.g or 1,
                countCfg.color.b or 1,
                countCfg.color.a or 1
            )
        end
    end,
    Alerts = function(data)
        -- Proc glow overlay (using Blizzard's built-in glow style)
        data.frame.glowFrame = CreateFrame("Frame", data.frameName .. "_Glow", data.frame)
        -- Start by matching the parent frame; BrieflyHighlightFrame may adjust outward offsets
        if data.frame.glowFrame.SetAllPoints then
            data.frame.glowFrame:SetAllPoints(data.frame)
        else
            data.frame.glowFrame:SetPoint("TOPRIGHT", data.frame, "TOPRIGHT", 1, -1)
            data.frame.glowFrame:SetPoint("BOTTOMLEFT", data.frame, "BOTTOMLEFT", 0, 0)
        end
        data.frame.glowFrame:SetFrameLevel(data.frame:GetFrameLevel() + 5)
        data.frame.glowFrame:Hide()

        -- Create the glow texture (yellow spell activation border)
        data.frame.glowTexture = data.frame.glowFrame:CreateTexture(nil, "OVERLAY")
        -- Size the texture slightly larger than the icon so the border's outer pixels are visible
        data.frame.glowTexture:SetPoint("TOPLEFT", data.frame, "TOPLEFT", 0, 0)
        data.frame.glowTexture:SetPoint("BOTTOMRIGHT", data.frame, "BOTTOMRIGHT", 0, 0)
        data.frame.glowTexture:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        data.frame.glowTexture:SetTexCoord(0.1, 0.9, 0.1, 0.9)
        data.frame.glowTexture:SetBlendMode("ADD")
        data.frame.glowTexture:SetVertexColor(1, 1, 0.6, 0.8)

        -- Animated glow ants (the spinning border effect)
        data.frame.glowAnts = data.frame.glowFrame:CreateTexture(nil, "OVERLAY")
        data.frame.glowAnts:SetPoint("TOPLEFT", data.frame, "TOPLEFT", 0, 0)
        data.frame.glowAnts:SetPoint("BOTTOMRIGHT", data.frame, "BOTTOMRIGHT", 0, 0)
        data.frame.glowAnts:SetTexture("Interface\\Cooldown\\star4")
        data.frame.glowAnts:SetTexCoord(0, 1, 0, 1)
        data.frame.glowAnts:SetBlendMode("ADD")
        data.frame.glowAnts:SetVertexColor(1, 1, 0.5, 0.6)
        
        -- Animation group for the glow
        data.frame.glowAnim = data.frame.glowAnts:CreateAnimationGroup()
        data.frame.glowAnim:SetLooping("REPEAT")
        local rotation = data.frame.glowAnim:CreateAnimation("Rotation")
        rotation:SetDegrees(-360)
        rotation:SetDuration(4)

        ApplyGlowNotificationSetup(data.frame, data.trackerConfig)
    end,
    CustomLabel = function(data)
        data.frame.customLabel = data.frame:CreateFontString(nil, "OVERLAY")
        -- Apply saved customLabel settings at creation
        local labelCfg = data.trackerConfig.customLabel
        local labelSize = (labelCfg and labelCfg.size) or 14
        local fontPath = State:ResolveFontPath(labelCfg and labelCfg.font, nil)
        local fontFlags = State:ResolveFontFlags(labelCfg and labelCfg.fontFlags, nil)
        data.frame.customLabel:SetFont(fontPath, labelSize, fontFlags or "OUTLINE")
        local labelX = (labelCfg and labelCfg.x) or 0
        local labelY = (labelCfg and labelCfg.y) or 0
        data.frame.customLabel:SetPoint("CENTER", data.frame, "CENTER", labelX, labelY)
        if labelCfg and labelCfg.color then
            data.frame.customLabel:SetTextColor(
                labelCfg.color.r or 1,
                labelCfg.color.g or 1,
                labelCfg.color.b or 1,
                labelCfg.color.a or 1
            )
        else
            data.frame.customLabel:SetTextColor(1, 1, 1, 1)
        end
        data.frame.customLabel:SetShadowOffset(1, -1)
        data.frame.customLabel:SetShadowColor(0, 0, 0, 1)
        data.frame.customLabel:SetDrawLayer("OVERLAY", 7)
        if labelCfg and labelCfg.display and labelCfg.text and labelCfg.text ~= "" then
            data.frame.customLabel:SetText(labelCfg.text)
            data.frame.customLabel:Show()
        else
            data.frame.customLabel:Hide()
        end
    end,
    VisualChargeBar = function(data)
        -- Create visual charge bar if visualChargeBar config exists
        if data.trackerConfig.visualChargeBar then
            FrameTrackerManager:CreateStatusBar(data.frame, "visualChargeBar", data.trackerConfig, data.baseSpellID, data.trackerType, nil, nil, nil, "visualChargeBar")
        end
    end,
    DisplayCountTicker = function(data)
        -- If the "Replace with Spell Display Count" setting is on, start a ticker
        -- that reads the action-bar display count and writes it into frame.count.
        if data.trackerConfig.countText and data.trackerConfig.countText.useSpellDisplayCount then
            local spellID = data.frame.meta.activeSpellID
            data.frame.count:SetAlpha(1)
            data.frame.count:Show()
            data.frame._displayCountTicker = C_Timer.NewTicker(0.05, function()
                local ab = C_ActionBar.FindSpellActionButtons(spellID)
                if ab and ab[1] then
                    local value = C_ActionBar.GetActionDisplayCount(ab[1])
                    data.frame.count:SetText(value)
                else
                    data.frame.count:SetText("")
                end
            end)
        end
    end,
}

FrameTrackerManager.FrameUpdater = {
    Base = function(data)
        -- Apply frame-level properties (opacity, strata, position)
        local success, error = pcall(function()
            data.frame:SetScale(data.scale or 1)
            data.frame:SetAlpha(data.opacity)
            data.frame:SetFrameStrata(data.frameStrata.level)
            data.frame:SetFrameLevel(data.frameStrata.value)
            
            -- Set frame position using shared helper
            -- if data.frame.previousProperties.position == nil
            --     or data.frame.previousProperties.position.anchorPoint ~= data.trackerConfig.position.anchorPoint
            --     or data.frame.previousProperties.position.relativeToFrame ~= data.trackerConfig.position.relativeToFrame
            --     or data.frame.previousProperties.position.relativeAnchorPoint ~= data.trackerConfig.position.relativeAnchorPoint
            --     or (issecretvalue(data.position.x) or data.position.x ~= data.frame.previousProperties.position.x)
            --     or (issecretvalue(data.position.y) or data.position.y ~= data.frame.previousProperties.position.y)
            -- then
                local positionData = {
                    position = {
                        anchorPoint = data.trackerConfig.position.anchorPoint,
                        relativeToFrame = data.trackerConfig.position.relativeToFrame,
                        relativeAnchorPoint = data.trackerConfig.position.relativeAnchorPoint,
                        x = data.position.x,
                        y = data.position.y
                    }
                }
                FrameTrackerManager:SetFramePosition(data.frame, positionData)
                -- Store a copy, not a reference, so changes are detected
                -- data.frame.previousProperties.position = {
                --     anchorPoint = data.trackerConfig.position.anchorPoint,
                --     relativeToFrame = data.trackerConfig.position.relativeToFrame,
                --     relativeAnchorPoint = data.trackerConfig.position.relativeAnchorPoint,
                --     x = data.position.x,
                --     y = data.position.y
                -- }
            -- end
        end)
    end,
    Icon = function(data)
        if data.icon.displayState == 'never' then
            data.frame.icon:Hide()
        else
            data.frame.icon:Show()
        end
    
        -- Apply icon texture and zoom from pre-computed values
        data.frame.icon:SetTexture(data.icon.texture)
        data.frame.icon:SetTexCoord(0 + data.icon.zoom, 1 - data.icon.zoom, 0 + data.icon.zoom, 1 - data.icon.zoom)

        -- Apply icon color (RGB on icon, alpha on container)
        local color = data.icon.color
        data.frame.icon:SetVertexColor(color.r or 1, color.g or 1, color.b or 1)
        data.frame.iconContainer:SetAlpha(color.a or 1)
        
        -- Apply size (skip when frame is managed by a container)
        if not data.frame._inContainer then
            data.frame:SetSize(data.icon.width, data.icon.height)
        end
    end,
    Border = function(data)
        -- Update border frame if it exists
        if data.frame.borderFrame then
            local suc, err = pcall(function()
                -- Set frame level to be 1 above the iconContainer
                data.frame.borderFrame:SetFrameLevel(data.frame:GetFrameLevel() + 2)
                
                -- Apply border size and color from data (pre-computed or from config)
                local borderSize = (data.border and data.border.size) or data.trackerConfig.iconSettings.borderSize
                local borderColor = (data.border and data.border.color) or data.trackerConfig.iconSettings.borderColor
                
                local iconW = data.trackerConfig.iconSettings.width or data.trackerConfig.iconSettings.size or 48
                local iconH = data.trackerConfig.iconSettings.height or data.trackerConfig.iconSettings.size or 48
                -- Size border frame: if borderSize > 0, extend outside icon; otherwise match icon size

                if data.frame.previousProperties.borderSize ~= borderSize
                    or data.frame.previousProperties.borderColor.r ~= borderColor.r
                    or data.frame.previousProperties.borderColor.g ~= borderColor.g
                    or data.frame.previousProperties.borderColor.b ~= borderColor.b
                    or data.frame.previousProperties.borderColor.a ~= borderColor.a
                then
                    if borderSize > 0 then
                        data.frame.borderFrame:SetSize(iconW + borderSize * 2, iconH + borderSize * 2)
                    else
                        data.frame.borderFrame:SetSize(iconW, iconH)
                        borderSize = borderSize * -1
                    end
                    data.frame.borderFrame.backdropInfo.edgeSize = borderSize
                    
                    data.frame.borderFrame:SetBackdrop({
                        edgeFile = "Interface\\Buttons\\WHITE8x8",
                        edgeSize = borderSize
                    })
                    data.frame.borderFrame:SetBackdropColor(0,0,0,0)
                    data.frame.borderFrame:SetBackdropBorderColor(
                        borderColor.r,
                        borderColor.g,
                        borderColor.b,
                        borderSize ~= 0 and borderColor.a or 0
                    )
                    FrameTrackerManager:SetPreviousPropertiesOnBaseAndVariant(data.frame, 'borderColor', borderColor)
                    FrameTrackerManager:SetPreviousPropertiesOnBaseAndVariant(data.frame, 'borderSize', borderSize)
                end
            end)
        end
    end,
    Alerts = function(data)
        local overrideColor = SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.frame, "glowNotification.glowColor")
        if data.alerts.display == false and not overrideColor then return end
        -- Re-attach the glow animation child with the latest glowNotification config
        ApplyGlowNotificationSetup(data.frame, data.trackerConfig)
        if overrideColor then
           SpellStyler.GlowUtil:PlayProcGlow(data.frame, nil, overrideColor)
        else
            SpellStyler.GlowUtil:StopProcGlow(data.frame) 
        end
        -- SpellStyler.GlowUtil:PlayProcGlow(data.frame, 200)
    end,
    Cooldown = function(data)
        -- Apply icon desaturation setting
        if data.frame.icon and data.cooldownText.desaturated ~= nil then
            pcall(function()
                data.frame.icon:SetDesaturated(data.cooldownText.desaturated)
            end)
        end
        
        -- Apply cooldown swipe and bling settings
        if data.cooldownText.hideDefaultSweep ~= nil then
            pcall(function()
                data.frame.cooldown:SetDrawSwipe(not data.cooldownText.hideDefaultSweep)
            end)
        end
        
        
        if data.cooldownText.hideCooldownBling == true then
            pcall(function()
                data.frame.cooldown:SetEdgeScale(0)
            end)
        end
        
        -- Apply cooldown text positioning and font
        local cdText = data.frame.cooldown.Text or data.frame.cooldown.text
        if data.cooldownText.display == false then
            if cdText then cdText:SetText("") end
        else
            -- Find the cooldown text FontString
            if not cdText then
                for i = 1, data.frame.cooldown:GetNumRegions() do
                    local region = select(i, data.frame.cooldown:GetRegions())
                    if region and region:GetObjectType() == "FontString" then
                        cdText = region
                        break
                    end
                end
            end
            
            if cdText then
                local success, error  = pcall(function()
                    -- Apply font size from pre-computed value
                    local fontPath, _, fontFlags = cdText:GetFont()
                    if data.cooldownText.fontSize then
                        local resolvedFontPath = State:ResolveFontPath(data.cooldownText.font, fontPath)
                        local resolvedFontFlags = State:ResolveFontFlags(data.cooldownText.fontFlags, fontFlags)
                        cdText:SetFont(resolvedFontPath, data.cooldownText.fontSize, resolvedFontFlags or "OUTLINE")
                    end
                    
                    -- Apply position from pre-computed values
                    cdText:ClearAllPoints()
                    cdText:SetPoint("CENTER", data.frame.cooldown, "CENTER", data.cooldownText.x, data.cooldownText.y)
                end)
            end
        end
        
    end,
    
    DisplayCountTicker = function(data)
        -- Cancel existing ticker
        if data.frame._displayCountTicker then
            data.frame._displayCountTicker:Cancel()
            data.frame._displayCountTicker = nil
        end
        
        -- Create new ticker if enabled
        if data.useSpellDisplayCount then
            local spellID = data.frame.meta.activeSpellID
            data.frame.count:SetAlpha(1)
            data.frame.count:Show()
            data.frame._displayCountTicker = C_Timer.NewTicker(0.05, function()
                local ab = C_ActionBar.FindSpellActionButtons(spellID)
                if ab and ab[1] then
                    local value = C_ActionBar.GetActionDisplayCount(ab[1])
                    data.frame.count:SetText(value)
                else
                    data.frame.count:SetText("")
                end
            end)
        end
    end,
    
    CustomLabel = function(data)
        if (not (data.frame.customLabel and data.customLabel)) or data.customLabel.display == false then return end
        
        pcall(function()
            -- Set visibility and text from pre-computed values
            if data.customLabel.textOverride and data.customLabel.textOverride ~= "" then
                -- Override forces show regardless of display setting
                data.frame.customLabel:SetText(data.customLabel.text)
                data.frame.customLabel:Show()
            elseif data.customLabel.display and data.customLabel.text and data.customLabel.text ~= "" then
                data.frame.customLabel:SetText(data.customLabel.text)
                data.frame.customLabel:Show()
            else
                data.frame.customLabel:Hide()
            end
            
            -- Apply font size from pre-computed value
            if data.customLabel.fontSize then
                local fontPath = State:ResolveFontPath(data.customLabel.font, nil)
                local fontFlags = State:ResolveFontFlags(data.customLabel.fontFlags, nil)
                data.frame.customLabel:SetFont(fontPath, data.customLabel.fontSize, fontFlags or "OUTLINE")
            end
            
            -- Apply color from pre-computed value
            if data.customLabel.color then
                data.frame.customLabel:SetTextColor(
                    data.customLabel.color.r or 1,
                    data.customLabel.color.g or 1,
                    data.customLabel.color.b or 1,
                    data.customLabel.color.a or 1
                )
            end
            
            -- Apply position from pre-computed values
            data.frame.customLabel:ClearAllPoints()
            data.frame.customLabel:SetPoint("CENTER", data.frame, "CENTER", data.customLabel.x, data.customLabel.y)
        end)
    end,
    
    StatusBar = function(data)

        for _, component in ipairs({
            data.frame.statusBar,
            data.frame.statusBar.bgTexture,
            data.frame.statusBar.fullCoverTexture,
            data.frame.statusBar.glowTexture,
            data.frame.statusBar.border,
            data.frame.statusBar.borderCornerTL,
            data.frame.statusBar.borderCornerTR,
            data.frame.statusBar.borderCornerBR,
            data.frame.statusBar.borderCornerBL,
            data.frame.statusBar.borderEdgeTop,
            data.frame.statusBar.borderEdgeRight,
            data.frame.statusBar.borderEdgeBottom,
            data.frame.statusBar.borderEdgeLeft
        }) do
            pcall(function()
                if data.statusBar == nil or data.statusBar.displayState == 'never' then component:Hide()
                else component:Show()
                end
            end)
        end

        if not (data.frame.statusBar and data.statusBar and data.statusBar.displayState ~= 'never') then return end
        
        pcall(function()
            -- Apply all properties from pre-computed values
            data.frame.statusBar:SetSize(data.statusBar.width, data.statusBar.height)
            data.frame.statusBar:SetScale(data.statusBar.scale)
            data.frame.statusBar.bgTexture:SetScale(data.statusBar.scale)
            
            data.frame.statusBar:ClearAllPoints()
            data.frame.statusBar:SetPoint(
                data.statusBar.anchorSelf,
                data.frame,
                data.statusBar.anchorParent,
                data.statusBar.x,
                data.statusBar.y
            )
            
            if data.statusBar.texture then
                data.frame.statusBar:SetStatusBarTexture(data.statusBar.texture)
                local statusBarTexture = data.frame.statusBar:GetStatusBarTexture()
                if statusBarTexture then
                    statusBarTexture:SetDrawLayer("ARTWORK", 0)
                end
                if data.frame.statusBar.fullCoverTexture then
                    data.frame.statusBar.fullCoverTexture:SetTexture(data.statusBar.texture)
                end
                if data.frame.statusBar.bgTexture then
                    data.frame.statusBar.bgTexture:SetTexture(data.statusBar.texture)
                end
            end
            
            data.frame.statusBar:SetOrientation(data.statusBar.orientation)
            data.frame.statusBar:SetReverseFill(data.statusBar.reverseFill)
            data.frame.statusBar:SetFillStyle(data.statusBar.fillStyle)
            
            if data.statusBar.rotation then
                data.frame.statusBar:SetRotation(math.rad(data.statusBar.rotation))
            end
        end)
        
        -- Apply border/background visibility from pre-computed values
        if data.statusBar.onlyBar or data.statusBar.displayState == 'never' then
            data.frame.statusBar.borderCornerTL:SetVertexColor(0,0,0,0)
            data.frame.statusBar.borderCornerTR:SetVertexColor(0,0,0,0)
            data.frame.statusBar.borderCornerBR:SetVertexColor(0,0,0,0)
            data.frame.statusBar.borderCornerBL:SetVertexColor(0,0,0,0)
            data.frame.statusBar.borderEdgeTop:SetVertexColor(0,0,0,0)
            data.frame.statusBar.borderEdgeRight:SetVertexColor(0,0,0,0)
            data.frame.statusBar.borderEdgeBottom:SetVertexColor(0,0,0,0)
            data.frame.statusBar.borderEdgeLeft:SetVertexColor(0,0,0,0)
            data.frame.statusBar.bgTexture:SetVertexColor(0,0,0,0)
            data.frame.statusBar.glowTexture:SetVertexColor(0,0,0,0)
        elseif data.statusBar.displayState == 'always' then
            local bc = data.statusBar.borderColor
            local bgc = data.statusBar.backgroundColor
            local gc = data.statusBar.glowColor
            
            data.frame.statusBar.borderCornerTL:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.statusBar.borderCornerTR:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.statusBar.borderCornerBR:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.statusBar.borderCornerBL:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.statusBar.borderEdgeTop:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.statusBar.borderEdgeRight:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.statusBar.borderEdgeBottom:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.statusBar.borderEdgeLeft:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.statusBar.bgTexture:SetVertexColor(bgc.r, bgc.g, bgc.b, bgc.a)
            data.frame.statusBar.glowTexture:SetVertexColor(gc.r, gc.g, gc.b, gc.a)
        end
        
        -- Apply border scale from pre-computed value
        local bs = data.statusBar.borderScale
        if data.frame.statusBar.borderCornerTL then data.frame.statusBar.borderCornerTL:SetScale(bs) end
        if data.frame.statusBar.borderCornerTR then data.frame.statusBar.borderCornerTR:SetScale(bs) end
        if data.frame.statusBar.borderCornerBR then data.frame.statusBar.borderCornerBR:SetScale(bs) end
        if data.frame.statusBar.borderCornerBL then data.frame.statusBar.borderCornerBL:SetScale(bs) end
        if data.frame.statusBar.borderEdgeTop then data.frame.statusBar.borderEdgeTop:SetScale(bs) end
        if data.frame.statusBar.borderEdgeRight then data.frame.statusBar.borderEdgeRight:SetScale(bs) end
        if data.frame.statusBar.borderEdgeBottom then data.frame.statusBar.borderEdgeBottom:SetScale(bs) end
        if data.frame.statusBar.borderEdgeLeft then data.frame.statusBar.borderEdgeLeft:SetScale(bs) end
    end,

    TotemBar = function(data)

        for _, component in ipairs({
            data.frame.totemBar,
            data.frame.totemBar.bgTexture,
            data.frame.totemBar.fullCoverTexture,
            data.frame.totemBar.glowTexture,
            data.frame.totemBar.border,
            data.frame.totemBar.borderCornerTL,
            data.frame.totemBar.borderCornerTR,
            data.frame.totemBar.borderCornerBR,
            data.frame.totemBar.borderCornerBL,
            data.frame.totemBar.borderEdgeTop,
            data.frame.totemBar.borderEdgeRight,
            data.frame.totemBar.borderEdgeBottom,
            data.frame.totemBar.borderEdgeLeft
        }) do
            pcall(function()
                if data.totemBar == nil or data.totemBar.displayState == 'never' then component:Hide()
                else component:Show()
                end
            end)
        end

        if not (data.frame.totemBar and data.totemBar and data.totemBar.displayState ~= 'never') then return end
        
        pcall(function()
            -- Apply all properties from pre-computed values
            data.frame.totemBar:SetSize(data.totemBar.width, data.totemBar.height)
            data.frame.totemBar:SetScale(data.totemBar.scale)
            data.frame.totemBar.bgTexture:SetScale(data.totemBar.scale)
            
            data.frame.totemBar:ClearAllPoints()
            data.frame.totemBar:SetPoint(
                data.totemBar.anchorSelf,
                data.frame,
                data.totemBar.anchorParent,
                data.totemBar.x,
                data.totemBar.y
            )
            
            if data.totemBar.texture then
                data.frame.totemBar:SetStatusBarTexture(data.totemBar.texture)
                local statusBarTexture = data.frame.totemBar:GetStatusBarTexture()
                if statusBarTexture then
                    statusBarTexture:SetDrawLayer("ARTWORK", 0)
                end
                if data.frame.totemBar.fullCoverTexture then
                    data.frame.totemBar.fullCoverTexture:SetTexture(data.totemBar.texture)
                end
                if data.frame.totemBar.bgTexture then
                    data.frame.totemBar.bgTexture:SetTexture(data.totemBar.texture)
                end
            end
            
            data.frame.totemBar:SetOrientation(data.totemBar.orientation)
            data.frame.totemBar:SetReverseFill(data.totemBar.reverseFill)
            data.frame.totemBar:SetFillStyle(data.totemBar.fillStyle)
            
            if data.totemBar.rotation then
                data.frame.totemBar:SetRotation(math.rad(data.totemBar.rotation))
            end
            
            -- Apply bar color (this is the fill color, not controlled by ApplyVisibility)
            -- Check for conditional overrides first
            local barColor = data.totemBar.color or data.trackerConfig.totemBar.color
            if SpellStyler.ConditionalEngine then
                local overrideColor = SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.frame, "totemBar.color")
                if overrideColor then
                    barColor = overrideColor
                end
            end
            data.frame.totemBar:SetValue(0)
            -- Set base bar color (alpha will be controlled by ApplyVisibility)
            data.frame.totemBar:SetStatusBarColor(
                barColor.r or 0.2,
                barColor.g or 0.8,
                barColor.b or 1,
                1
            )
        end)
        
        -- Apply border/background visibility from pre-computed values
        if data.totemBar.onlyBar or data.totemBar.displayState == 'never' then
            data.frame.totemBar.borderCornerTL:SetVertexColor(0,0,0,0)
            data.frame.totemBar.borderCornerTR:SetVertexColor(0,0,0,0)
            data.frame.totemBar.borderCornerBR:SetVertexColor(0,0,0,0)
            data.frame.totemBar.borderCornerBL:SetVertexColor(0,0,0,0)
            data.frame.totemBar.borderEdgeTop:SetVertexColor(0,0,0,0)
            data.frame.totemBar.borderEdgeRight:SetVertexColor(0,0,0,0)
            data.frame.totemBar.borderEdgeBottom:SetVertexColor(0,0,0,0)
            data.frame.totemBar.borderEdgeLeft:SetVertexColor(0,0,0,0)
            data.frame.totemBar.bgTexture:SetVertexColor(0,0,0,0)
            data.frame.totemBar.glowTexture:SetVertexColor(0,0,0,0)
        elseif data.totemBar.displayState == 'always' then
            local bc = data.totemBar.borderColor
            local bgc = data.totemBar.backgroundColor
            local gc = data.totemBar.glowColor
            
            data.frame.totemBar.borderCornerTL:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.totemBar.borderCornerTR:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.totemBar.borderCornerBR:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.totemBar.borderCornerBL:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.totemBar.borderEdgeTop:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.totemBar.borderEdgeRight:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.totemBar.borderEdgeBottom:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.totemBar.borderEdgeLeft:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
            data.frame.totemBar.bgTexture:SetVertexColor(bgc.r, bgc.g, bgc.b, bgc.a)
            data.frame.totemBar.glowTexture:SetVertexColor(gc.r, gc.g, gc.b, gc.a)
        end
        
        -- Apply border scale from pre-computed value
        local bs = data.totemBar.borderScale
        if data.frame.totemBar.borderCornerTL then data.frame.totemBar.borderCornerTL:SetScale(bs) end
        if data.frame.totemBar.borderCornerTR then data.frame.totemBar.borderCornerTR:SetScale(bs) end
        if data.frame.totemBar.borderCornerBR then data.frame.totemBar.borderCornerBR:SetScale(bs) end
        if data.frame.totemBar.borderCornerBL then data.frame.totemBar.borderCornerBL:SetScale(bs) end
        if data.frame.totemBar.borderEdgeTop then data.frame.totemBar.borderEdgeTop:SetScale(bs) end
        if data.frame.totemBar.borderEdgeRight then data.frame.totemBar.borderEdgeRight:SetScale(bs) end
        if data.frame.totemBar.borderEdgeBottom then data.frame.totemBar.borderEdgeBottom:SetScale(bs) end
        if data.frame.totemBar.borderEdgeLeft then data.frame.totemBar.borderEdgeLeft:SetScale(bs) end
        
        -- Apply totem bar visibility based on slot association and live duration
        -- Check if this frame is associated with any totem slot
        local associatedSlot = nil
        for slot, frame in pairs(FrameTrackerManager._activeTotemSlots) do
            if frame == data.frame then
                associatedSlot = slot
                break
            end
        end
        
        -- Calculate alpha values from live totem duration if associated with a slot
        local configAlpha = (data.trackerConfig.totemBar.color and data.trackerConfig.totemBar.color.a) or 1
        local bgConfigAlpha = (data.trackerConfig.totemBar.backgroundColor and data.trackerConfig.totemBar.backgroundColor.a) or 1
        local glowConfigAlpha = (data.trackerConfig.totemBar.glowColor and data.trackerConfig.totemBar.glowColor.a) or 1
        local borderConfigAlpha = (data.trackerConfig.totemBar.borderColor and data.trackerConfig.totemBar.borderColor.a) or 1
        
        local totemBarAlpha = 0
        local fullBarAlpha = data.totemBar.defaultFull and configAlpha or 0  -- Use configAlpha when not active
        local bgAlpha = 0
        local glowAlpha = 0
        local borderAlpha = 0
        
        if associatedSlot then
            local totemDuration = GetTotemDuration(associatedSlot)
            if totemDuration then
                -- Totem is active, evaluate curves for alpha values with their respective config alphas
                totemBarAlpha = totemDuration:EvaluateRemainingDuration(
                    SpellStyler.Util:IsValidCooldownCurve(true, configAlpha)
                )
                fullBarAlpha = totemDuration:EvaluateRemainingDuration(
                    SpellStyler.Util:IsValidCooldownCurve(false, configAlpha)
                )
                bgAlpha = totemDuration:EvaluateRemainingDuration(
                    SpellStyler.Util:IsValidCooldownCurve(true, bgConfigAlpha)
                )
                glowAlpha = totemDuration:EvaluateRemainingDuration(
                    SpellStyler.Util:IsValidCooldownCurve(true, glowConfigAlpha)
                )
                borderAlpha = totemDuration:EvaluateRemainingDuration(
                    SpellStyler.Util:IsValidCooldownCurve(true, borderConfigAlpha)
                )
            else
                -- No duration means totem expired, restore full bar if defaultFull is true
                totemBarAlpha = 0
                fullBarAlpha = data.totemBar.defaultFull and configAlpha or 0
                bgAlpha = 0
                glowAlpha = 0
                borderAlpha = 0
            end
        end
        
        -- Apply visibility using the calculated alphas (or zeros if not associated/active)
        FrameTrackerManager.ApplyVisibility.TotemBar({
            customFrame = data.frame,
            config = data.trackerConfig,
            displayState = data.trackerConfig.totemBar.displayState,
            totemBarConfig = data.trackerConfig.totemBar,
            totemBarAlpha = totemBarAlpha,
            fullBarAlpha = fullBarAlpha,
            bgAlpha = bgAlpha,
            glowAlpha = glowAlpha,
            borderAlpha = borderAlpha,
            isFull = data.trackerConfig.totemBar.defaultFillValue == 'full'
        })
    end,
    
    VisualChargeBar = function(data)
        
        -- If frame doesn't even have a visualChargeBar element, nothing to do
         
        if not data.frame.visualChargeBar then
            return
        end
        
        -- If visualChargeBar is disabled (data.visualChargeBar is nil), hide everything
        
        for _, component in ipairs({
            data.frame.visualChargeBar,
            data.frame.visualChargeBar.bgTexture,
            data.frame.visualChargeBar.fullCoverTexture,
            data.frame.visualChargeBar.glowTexture,
            data.frame.visualChargeBar.border,
            data.frame.visualChargeBar.borderCornerTL,
            data.frame.visualChargeBar.borderCornerTR,
            data.frame.visualChargeBar.borderCornerBR,
            data.frame.visualChargeBar.borderCornerBL,
            data.frame.visualChargeBar.borderEdgeTop,
            data.frame.visualChargeBar.borderEdgeRight,
            data.frame.visualChargeBar.borderEdgeBottom,
            data.frame.visualChargeBar.borderEdgeLeft
        }) do
            local s,e = pcall(function()
                if data.visualChargeBar.displayState == 'never' then
                    component:Hide()
                else component:Show()
                end
            end)
        end
        
        if data.visualChargeBar.displayState == 'never' then
            return
        end
        
        pcall(function()
                -- Apply all properties from pre-computed values
                data.frame.visualChargeBar:SetStatusBarColor(
                    data.visualChargeBar.color.r or 0.2,
                    data.visualChargeBar.color.g or 0.8,
                    data.visualChargeBar.color.b or 1,
                    1
                )
                
                data.frame.visualChargeBar:SetSize(data.visualChargeBar.width, data.visualChargeBar.height)
                data.frame.visualChargeBar:SetScale(data.visualChargeBar.scale)
                data.frame.visualChargeBar.bgTexture:SetScale(data.visualChargeBar.scale)
                
                data.frame.visualChargeBar:ClearAllPoints()
                data.frame.visualChargeBar:SetPoint(
                    data.visualChargeBar.anchorSelf,
                    data.frame,
                    data.visualChargeBar.anchorParent,
                    data.visualChargeBar.x,
                    data.visualChargeBar.y
                )
                
                if data.visualChargeBar.texture then
                    data.frame.visualChargeBar:SetStatusBarTexture(data.visualChargeBar.texture)
                    local statusBarTexture = data.frame.visualChargeBar:GetStatusBarTexture()
                    if statusBarTexture then
                        statusBarTexture:SetDrawLayer("ARTWORK", 0)
                    end
                    if data.frame.visualChargeBar.fullCoverTexture then
                        data.frame.visualChargeBar.fullCoverTexture:SetTexture(data.visualChargeBar.texture)
                    end
                    if data.frame.visualChargeBar.bgTexture then
                        data.frame.visualChargeBar.bgTexture:SetTexture(data.visualChargeBar.texture)
                    end
                end
                
                data.frame.visualChargeBar:SetOrientation(data.visualChargeBar.orientation)
                data.frame.visualChargeBar:SetReverseFill(data.visualChargeBar.reverseFill)
                data.frame.visualChargeBar:SetFillStyle(data.visualChargeBar.fillStyle)
                
                if data.visualChargeBar.rotation then
                    data.frame.visualChargeBar:SetRotation(data.visualChargeBar.rotation)
                end
                
                data.frame.visualChargeBar:SetMinMaxValues(data.visualChargeBar.minValue, data.visualChargeBar.maxValue)
            end)
            
            -- Apply border/background visibility from pre-computed values
            if data.visualChargeBar.onlyBar or data.visualChargeBar.displayState == 'never' then
                data.frame.visualChargeBar.borderCornerTL:SetVertexColor(0,0,0,0)
                data.frame.visualChargeBar.borderCornerTR:SetVertexColor(0,0,0,0)
                data.frame.visualChargeBar.borderCornerBR:SetVertexColor(0,0,0,0)
                data.frame.visualChargeBar.borderCornerBL:SetVertexColor(0,0,0,0)
                data.frame.visualChargeBar.borderEdgeTop:SetVertexColor(0,0,0,0)
                data.frame.visualChargeBar.borderEdgeRight:SetVertexColor(0,0,0,0)
                data.frame.visualChargeBar.borderEdgeBottom:SetVertexColor(0,0,0,0)
                data.frame.visualChargeBar.borderEdgeLeft:SetVertexColor(0,0,0,0)
                data.frame.visualChargeBar.bgTexture:SetVertexColor(0,0,0,0)
                data.frame.visualChargeBar.glowTexture:SetVertexColor(0,0,0,0)
            elseif data.visualChargeBar.displayState == 'always' then
                local bc = data.visualChargeBar.borderColor
                local bgc = data.visualChargeBar.backgroundColor
                local gc = data.visualChargeBar.glowColor
                
                data.frame.visualChargeBar.borderCornerTL:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
                data.frame.visualChargeBar.borderCornerTR:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
                data.frame.visualChargeBar.borderCornerBR:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
                data.frame.visualChargeBar.borderCornerBL:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
                data.frame.visualChargeBar.borderEdgeTop:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
                data.frame.visualChargeBar.borderEdgeRight:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
                data.frame.visualChargeBar.borderEdgeBottom:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
                data.frame.visualChargeBar.borderEdgeLeft:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
                data.frame.visualChargeBar.bgTexture:SetVertexColor(bgc.r, bgc.g, bgc.b, bgc.a)
                data.frame.visualChargeBar.glowTexture:SetVertexColor(gc.r, gc.g, gc.b, gc.a)
            end
            
            -- Apply border scale from pre-computed value
            local bs = data.visualChargeBar.borderScale
            if data.frame.visualChargeBar.borderCornerTL then data.frame.visualChargeBar.borderCornerTL:SetScale(bs) end
            if data.frame.visualChargeBar.borderCornerTR then data.frame.visualChargeBar.borderCornerTR:SetScale(bs) end
            if data.frame.visualChargeBar.borderCornerBR then data.frame.visualChargeBar.borderCornerBR:SetScale(bs) end
            if data.frame.visualChargeBar.borderCornerBL then data.frame.visualChargeBar.borderCornerBL:SetScale(bs) end
            if data.frame.visualChargeBar.borderEdgeTop then data.frame.visualChargeBar.borderEdgeTop:SetScale(bs) end
            if data.frame.visualChargeBar.borderEdgeRight then data.frame.visualChargeBar.borderEdgeRight:SetScale(bs) end
            if data.frame.visualChargeBar.borderEdgeBottom then data.frame.visualChargeBar.borderEdgeBottom:SetScale(bs) end
            if data.frame.visualChargeBar.borderEdgeLeft then data.frame.visualChargeBar.borderEdgeLeft:SetScale(bs) end
    end
}

--- Helper function to apply property updates to a single frame (base or variant)
--- Computes all property values (including overrides) and delegates to FrameUpdater methods
--- @param baseSpellID number The base spell ID
--- @param trackerType string The tracker type
--- @param frame? table The frame to update
--- @param skipConditionalEval? boolean Skip ConditionalEngine evaluation (for recursive calls)
function FrameTrackerManager:ApplyStaticFrameProperties(baseSpellID, trackerType, frame, skipConditionalEval)
    
    local frame = frame or FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    local trackerConfig = State:GetSpecificTrackerValue(baseSpellID, trackerType)
    if not frame then
        error("ApplyStaticFrameProperties called with nil frame for spell " .. tostring(baseSpellID))
    end
    
    
    -- Set up/Update charge anchor bars (this sets dualFrameStatus flag)
    self:CreateInvisibleAnchorControllerBars(frame, trackerConfig, baseSpellID, frame.meta.isVariantFrame or false, false)
    
    -- Early return if this frame should be hidden based on dualFrameStatus
    local isVariantFrame = frame.isVariantFrame or frame.meta.isVariantFrame
    if isVariantFrame and frame.meta.dualFrameStatus == 'hideVariant' then
        return
    elseif not isVariantFrame and frame.meta.dualFrameStatus == 'hideBase' then
        self:ApplyStaticFrameProperties(baseSpellID, trackerType, frame.variantFrame)
        return
    end
    -- Helper to get conditional override
    local function getOverride(path)
        return SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(frame, path)
    end
    
    -- Build comprehensive data object with all pre-computed property values
    local data = {
        frame = frame,
        trackerConfig = trackerConfig,  -- Keep for special checks
        baseSpellID = baseSpellID,
        trackerType = trackerType,
        scale = trackerConfig.scale or 1,
        -- Icon properties
        icon = {
            displayState = trackerConfig.iconSettings.iconDisplayState,
            texture = (function()
                local override = getOverride("iconSettings.iconTexturePath")
                local custom = override or (trackerConfig.iconSettings.iconTexturePath ~= "" and trackerConfig.iconSettings.iconTexturePath) or nil
                local texture = custom or frame.updatedIconID or trackerConfig.defaultIconTexturePath
                
                -- For items, defaultIconTexturePath is already the resolved texture path (not itemID)
                -- No conversion needed
                
                return texture
            end)(),
            zoom = trackerConfig.iconSettings.zoom and (trackerConfig.iconSettings.zoom) or 0,
            width = getOverride("iconSettings.width") or trackerConfig.iconSettings.width or trackerConfig.iconSettings.size or 48,
            height = getOverride("iconSettings.height") or trackerConfig.iconSettings.height or trackerConfig.iconSettings.size or 48,
            color = getOverride("iconColor") or trackerConfig.iconColor or {r=1, g=1, b=1},
            alpha = getOverride("iconAlpha") or trackerConfig.iconAlpha or 1
        },
        alerts = {
            display = trackerConfig.glowNotification.shouldDisplay
        },
        -- Opacity
        opacity = getOverride("iconSettings.opacity") or trackerConfig.iconSettings.opacity or 1,
        
        -- Frame strata
        frameStrata = {
            level = trackerConfig.iconSettings.frameStrataLevel or "MEDIUM",
            value = trackerConfig.iconSettings.frameStrataValue or 100
        },
        
        -- Cooldown text properties
        cooldownText = {
            display = trackerConfig.cooldownText.display,
            fontSize = getOverride("cooldownText.size") or trackerConfig.cooldownText.size,
            font = trackerConfig.cooldownText.font,
            fontFlags = trackerConfig.cooldownText.fontFlags,
            x = getOverride("cooldownText.x") or trackerConfig.cooldownText.x or 0,
            y = getOverride("cooldownText.y") or trackerConfig.cooldownText.y or 0,
            hideDefaultSweep = trackerConfig.iconSettings.hideDefaultSweep,
            hideCooldownBling = trackerConfig.iconSettings.hideCooldownBling,
            desaturated = trackerConfig.iconSettings.desaturated
        },
        
        -- Display count ticker
        useSpellDisplayCount = trackerConfig.countText and trackerConfig.countText.useSpellDisplayCount,
        
        -- Custom label properties
        customLabel = {
            display = trackerConfig.customLabel,
            textOverride = getOverride("customLabel.text"),
            text = getOverride("customLabel.text") or trackerConfig.customLabel.text,
            fontSize = getOverride("customLabel.size") or trackerConfig.customLabel.size,
            font = trackerConfig.customLabel.font,
            fontFlags = trackerConfig.customLabel.fontFlags,
            color = getOverride("customLabel.color") or trackerConfig.customLabel.color,
            x = getOverride("customLabel.x") or trackerConfig.customLabel.x or 0,
            y = getOverride("customLabel.y") or trackerConfig.customLabel.y or 0
        },
        
        -- Status bar properties
        statusBar = {
            displayState = trackerConfig.statusBar.displayState,
            width = getOverride("statusBar.width") or trackerConfig.statusBar.width or 200,
            height = getOverride("statusBar.height") or trackerConfig.statusBar.height or 20,
            scale = getOverride("statusBar.scale") or trackerConfig.statusBar.scale or 1,
            x = getOverride("statusBar.x") or trackerConfig.statusBar.x or 0,
            y = getOverride("statusBar.y") or trackerConfig.statusBar.y or 0,
            anchorSelf = getOverride("statusBar.anchorSelf") or trackerConfig.statusBar.anchorSelf or "LEFT",
            anchorParent = getOverride("statusBar.anchorParent") or trackerConfig.statusBar.anchorParent or "RIGHT",
            texture = (function()
                local override = getOverride("statusBar.customBarTexture")
                return override or (trackerConfig.statusBar.customBarTexture ~= "" and trackerConfig.statusBar.customBarTexture) or trackerConfig.statusBar.defaultBarTexture
            end)(),
            orientation = (trackerConfig.statusBar.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL",
            reverseFill = trackerConfig.statusBar.fillOrEmpty == 'inverse',
            fillStyle = (trackerConfig.statusBar.progressDirection == 'reverse') and Enum.StatusBarFillStyle.Reverse or Enum.StatusBarFillStyle.Standard,
            rotation = getOverride("statusBar.rotation") or trackerConfig.statusBar.rotation,
            onlyBar = (function()
                local override = getOverride("statusBar.onlyRenderBar")
                return (override ~= nil) and override or (trackerConfig.statusBar.onlyRenderBar or false)
            end)(),
            borderColor = getOverride("statusBar.borderColor") or trackerConfig.statusBar.borderColor,
            backgroundColor = getOverride("statusBar.backgroundColor") or trackerConfig.statusBar.backgroundColor,
            glowColor = getOverride("statusBar.glowColor") or trackerConfig.statusBar.glowColor,
            borderScale = getOverride("statusBar.borderScale") or trackerConfig.statusBar.borderScale or 0.5
        },

        totemBar = {
            displayState = trackerConfig.totemBar.displayState,
            width = getOverride("totemBar.width") or trackerConfig.totemBar.width or 200,
            height = getOverride("totemBar.height") or trackerConfig.totemBar.height or 20,
            scale = getOverride("totemBar.scale") or trackerConfig.totemBar.scale or 1,
            x = getOverride("totemBar.x") or trackerConfig.totemBar.x or 0,
            y = getOverride("totemBar.y") or trackerConfig.totemBar.y or 0,
            anchorSelf = getOverride("totemBar.anchorSelf") or trackerConfig.totemBar.anchorSelf or "LEFT",
            anchorParent = getOverride("totemBar.anchorParent") or trackerConfig.totemBar.anchorParent or "RIGHT",
            texture = (function()
                local override = getOverride("totemBar.customBarTexture")
                return override or (trackerConfig.totemBar.customBarTexture ~= "" and trackerConfig.totemBar.customBarTexture) or trackerConfig.totemBar.defaultBarTexture
            end)(),
            orientation = (trackerConfig.totemBar.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL",
            reverseFill = trackerConfig.totemBar.fillOrEmpty == 'inverse',
            fillStyle = (trackerConfig.totemBar.progressDirection == 'reverse') and Enum.StatusBarFillStyle.Reverse or Enum.StatusBarFillStyle.Standard,
            rotation = getOverride("totemBar.rotation") or trackerConfig.totemBar.rotation,
            onlyBar = (function()
                local override = getOverride("totemBar.onlyRenderBar")
                return (override ~= nil) and override or (trackerConfig.totemBar.onlyRenderBar or false)
            end)(),
            borderColor = getOverride("totemBar.borderColor") or trackerConfig.totemBar.borderColor,
            backgroundColor = getOverride("totemBar.backgroundColor") or trackerConfig.totemBar.backgroundColor,
            glowColor = getOverride("totemBar.glowColor") or trackerConfig.totemBar.glowColor,
            borderScale = getOverride("totemBar.borderScale") or trackerConfig.totemBar.borderScale or 0.5,
            defaultFull = (function()
                local override = getOverride("totemBar.defaultFillValue")
                return (override ~= nil) and override == 'full' or trackerConfig.totemBar and trackerConfig.totemBar.defaultFillValue == 'full'
            end)()
        },
        
        -- Visual charge bar properties
        visualChargeBar = {
            displayState = trackerConfig.visualChargeBar.displayState,
            color = trackerConfig.visualChargeBar.color,
            width = getOverride("visualChargeBar.width") or trackerConfig.visualChargeBar.width or 200,
            height = getOverride("visualChargeBar.height") or trackerConfig.visualChargeBar.height or 20,
            scale = getOverride("visualChargeBar.scale") or trackerConfig.visualChargeBar.scale or 1,
            x = getOverride("visualChargeBar.x") or trackerConfig.visualChargeBar.x or 0,
            y = getOverride("visualChargeBar.y") or trackerConfig.visualChargeBar.y or 0,
            anchorSelf = getOverride("visualChargeBar.anchorSelf") or trackerConfig.visualChargeBar.anchorSelf or "LEFT",
            anchorParent = getOverride("visualChargeBar.anchorParent") or trackerConfig.visualChargeBar.anchorParent or "RIGHT",
            texture = (function()
                local override = getOverride("visualChargeBar.customBarTexture")
                return override or (trackerConfig.visualChargeBar.customBarTexture ~= "" and trackerConfig.visualChargeBar.customBarTexture) or trackerConfig.visualChargeBar.defaultBarTexture
            end)(),
            orientation = (trackerConfig.visualChargeBar.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL",
            reverseFill = trackerConfig.visualChargeBar.fillOrEmpty == 'inverse',
            fillStyle = (trackerConfig.visualChargeBar.progressDirection == 'reverse') and Enum.StatusBarFillStyle.Reverse or Enum.StatusBarFillStyle.Standard,
            rotation = getOverride("visualChargeBar.rotation") or trackerConfig.visualChargeBar.textureRotation,
            minValue = trackerConfig.visualChargeBar.minValue or 0,
            maxValue = trackerConfig.visualChargeBar.maxValue or 5,
            onlyBar = (function()
                local override = getOverride("visualChargeBar.onlyRenderBar")
                return (override ~= nil) and override or (trackerConfig.visualChargeBar.onlyRenderBar or false)
            end)(),
            borderColor = getOverride("visualChargeBar.borderColor") or trackerConfig.visualChargeBar.borderColor,
            backgroundColor = getOverride("visualChargeBar.backgroundColor") or trackerConfig.visualChargeBar.backgroundColor,
            glowColor = getOverride("visualChargeBar.glowColor") or trackerConfig.visualChargeBar.glowColor,
            borderScale = getOverride("visualChargeBar.borderScale") or trackerConfig.visualChargeBar.borderScale or 0.5
        },
        
        -- Position properties
        position = {
            useChargeAnchor = frame.chargeAnchorBarA ~= nil,
            anchorPoint = trackerConfig.position and trackerConfig.position.anchorPoint,
            relativeAnchorPoint = trackerConfig.position and (trackerConfig.position.relativeAnchorPoint or trackerConfig.position.anchorPoint),
            x = getOverride("position.x") or (trackerConfig.position and trackerConfig.position.x) or 0,
            y = getOverride("position.y") or (trackerConfig.position and trackerConfig.position.y) or 0
        }
    }
    -- Call each FrameUpdater method to apply pre-computed properties
    FrameTrackerManager.FrameUpdater.Base(data)
    FrameTrackerManager.FrameUpdater.Icon(data)
    FrameTrackerManager.FrameUpdater.Border(data)
    FrameTrackerManager.FrameUpdater.Alerts(data)
    FrameTrackerManager.FrameUpdater.Cooldown(data)
    FrameTrackerManager.FrameUpdater.DisplayCountTicker(data)
    FrameTrackerManager.FrameUpdater.CustomLabel(data)
    FrameTrackerManager.FrameUpdater.StatusBar(data)
    FrameTrackerManager.FrameUpdater.TotemBar(data)
    FrameTrackerManager.FrameUpdater.VisualChargeBar(data)

    FrameTrackerManager:DriveFrameUpdate(
        frame,
        {
            resolveDuration = true,
            syncChargeText = true
        },
        nil,
        "staticFramePropertyUpdates"
    )
    
    -- Recursively update variant frame if it exists (visibility is handled by early returns above)
    if not frame.isVariantFrame and frame.variantFrame then
        self:ApplyStaticFrameProperties(baseSpellID, trackerType, frame.variantFrame)
    end
end


--- Middleware for creating tracker frames with proper charge infrastructure.
--- Use this instead of calling CreateTrackerFrame directly when creating new frames.
--- @param baseSpellID number The base spell ID
--- @param trackerConfig table The tracker configuration
--- @param trackerType string The tracker type
--- @return table baseFrame The created base frame
function FrameTrackerManager:CreateCompleteFrame(baseSpellID, trackerConfig, trackerType)
    -- Guard: Don't create duplicate frames for the same baseSpellID
    if FrameTrackerManager.SpellStyler_frames[trackerType] and FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] then
        return FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID]
    end
    
    local BuildFrame = function(frameMeta)
        local Frame = FrameTrackerManager.FrameBuilder.Base(frameMeta)
        frameMeta.frame = Frame
        if frameMeta.isVariantFrame then
            Frame.isVariantFrame = true
            Frame.meta.isVariantFrame = true
        end 
        FrameTrackerManager.FrameBuilder.Icon(frameMeta)
        FrameTrackerManager.FrameBuilder.Border(frameMeta)
        FrameTrackerManager.FrameBuilder.Cooldown(frameMeta)
        FrameTrackerManager.FrameBuilder.CooldownBar(frameMeta)
        FrameTrackerManager.FrameBuilder.TotemBar(frameMeta)
        FrameTrackerManager.FrameBuilder.Count(frameMeta)
        FrameTrackerManager.FrameBuilder.Alerts(frameMeta)
        FrameTrackerManager.FrameBuilder.CustomLabel(frameMeta)
        FrameTrackerManager.FrameBuilder.VisualChargeBar(frameMeta)
        FrameTrackerManager.FrameBuilder.DisplayCountTicker(frameMeta)
        -- Only register base frames in global registry; variant frames stored on their base frame
        if not frameMeta.isVariantFrame then
            FrameTrackerManager.SpellStyler_frames[trackerType][baseSpellID] = Frame
        end
        return Frame
    end
    local spellInfo = C_Spell.GetSpellInfo(baseSpellID)
    local dataBaseFrame = {
        frameName = "SpellStyler_" .. spellInfo.name .. "_" .. baseSpellID .. "_" .. trackerType,
        baseSpellID = baseSpellID,
        trackerType = trackerType,
        isVariantFrame = false,
        trackerConfig = trackerConfig,
        itemID = trackerConfig.itemID or nil
    }
    local baseFrame = BuildFrame(dataBaseFrame)
    
    -- Create variant frame
    local dataVariantFrame = {
        frameName = "SpellStyler_" .. spellInfo.name .. "_VariantFrame",
        baseSpellID = baseSpellID,
        trackerType = trackerType,
        isVariantFrame = true,
        trackerConfig = trackerConfig,
        itemID = trackerConfig.itemID or nil
    }
    
    local variantFrame = BuildFrame(dataVariantFrame)
    baseFrame.variantFrame = variantFrame
    variantFrame.baseFrame = baseFrame


    self:CreateInvisibleAnchorControllerBars(baseFrame, trackerConfig, baseSpellID, false, false)
    self:CreateInvisibleAnchorControllerBars(baseFrame.variantFrame, trackerConfig, baseSpellID, true, false)
    
    -- Apply initial properties to base and variant frames
    self:ApplyStaticFrameProperties(baseSpellID, trackerType)
    return baseFrame
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
            FrameTrackerManager:SetMetaOnBaseAndVariant(frame, 'currentAuraInstanceID', cdm_frame:GetAuraSpellInstanceID() or 0)
            if frame.meta.currentAuraInstanceID ~= 0 then
                FrameTrackerManager:SetMetaOnBaseAndVariant(frame, 'buffStatus', 'present')
            else
                FrameTrackerManager:SetMetaOnBaseAndVariant(frame, 'buffStatus', 'absent')
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
-- TOTEM SPELL QUEUE MANAGEMENT
-- ============================================================================

--- Adds a spell to the totem tracking queue with a 200ms expiration window.
--- @param spellID number The spell ID to track
function FrameTrackerManager:AddSpellToTotemQueue(spellID)
    local expirationTime = GetTime() + 0.2  -- 200ms window
    FrameTrackerManager._totemSpellQueue[spellID] = expirationTime
end

--- Removes expired entries from the totem spell queue.
--- @return number Count of expired entries removed
function FrameTrackerManager:CleanupExpiredTotemQueueEntries()
    local currentTime = GetTime()
    local removedCount = 0
    
    for spellID, expirationTime in pairs(FrameTrackerManager._totemSpellQueue) do
        if currentTime > expirationTime then
            FrameTrackerManager._totemSpellQueue[spellID] = nil
            removedCount = removedCount + 1
        end
    end
    
    return removedCount
end

--- Removes a specific spell from the totem queue and cleans up any expired entries.
--- @param spellID number The spell ID to remove
function FrameTrackerManager:RemoveSpellFromTotemQueue(spellID)
    FrameTrackerManager._totemSpellQueue[spellID] = nil
    FrameTrackerManager:CleanupExpiredTotemQueueEntries()
end

--- Checks if there are any spells in the totem queue (non-expired).
--- @return number|nil The first valid spell ID found, or nil if queue is empty
function FrameTrackerManager:GetNextTotemQueueSpell()
    FrameTrackerManager:CleanupExpiredTotemQueueEntries()
    
    local currentTime = GetTime()
    for spellID, expirationTime in pairs(FrameTrackerManager._totemSpellQueue) do
        if currentTime <= expirationTime then
            return spellID
        end
    end
    
    return nil
end

--- Clears the totem bar for a tracker frame when a totem expires.
--- @param frame table The tracker frame
function FrameTrackerManager:ClearTotemBarDuration(frame)
    if not frame or not frame.totemBar then
        return
    end
    
    local config = State:GetSpecificTrackerValue(frame.meta.baseSpellID, frame.meta.trackerType)
    if not config or not config.totemBar then
        return
    end
    
    local success, error = pcall(function()
        -- Clear the totem bar
        frame.totemBar:SetValue(0)
        
        -- Mark totem as inactive in metadata and clear slot
        if frame.meta then
            frame.meta.isTotemActive = false
            frame.meta.totemSlot = nil
        end
        
        -- Calculate fullBarAlpha: should be visible when inactive if defaultFillValue is 'full' (inverse behavior)
        local isFull = config.totemBar and config.totemBar.defaultFillValue == 'full'
        local configAlpha = (config.totemBar.color and config.totemBar.color.a) or 1
        local fullBarAlpha = isFull and configAlpha or 0  -- Show full bar when inactive if defaultFillValue is 'full'
        
        -- Apply visual state with zero alpha (no duration)
        FrameTrackerManager.ApplyVisibility.TotemBar({
            customFrame = frame,
            config = config,
            displayState = config.totemBar.displayState,
            totemBarConfig = config.totemBar,
            totemBarAlpha = 0,  -- No duration = 0 alpha
            fullBarAlpha = fullBarAlpha,  -- Full bar visible when inactive if defaultFillValue is 'full'
            bgAlpha = 0,  -- No duration = no bg visibility
            glowAlpha = 0,  -- No duration = no glow visibility
            borderAlpha = 0,  -- No duration = no border visibility
            isFull = isFull
        })
    end)
end

--- Applies a totem duration object specifically to the totemBar of a tracker frame.
--- This function ONLY handles duration application - all visual properties are handled
--- by FrameUpdater.TotemBar and ApplyVisibility.TotemBar.
--- @param frame table The tracker frame
--- @param totemDuration table|userdata The totem duration object from GetTotemDuration
function FrameTrackerManager:ApplyTotemBarDuration(frame, totemDuration)
    if not frame or not frame.totemBar then
        return
    end
    
    local config = State:GetSpecificTrackerValue(frame.meta.baseSpellID, frame.meta.trackerType)
    if not config or not config.totemBar then
        return
    end
    
    local success, error = pcall(function()
        -- Determine timer direction based on config
        local timerDir = (config.totemBar.fillOrEmpty == 'inverse')
            and Enum.StatusBarTimerDirection.ElapsedTime
            or Enum.StatusBarTimerDirection.RemainingTime
        
        -- Mark totem as active in metadata
        if frame.meta then
            frame.meta.isTotemActive = true
        end
        
        -- Clear and apply the totem duration
        frame.totemBar:SetValue(0)
        frame.totemBar:SetTimerDuration(
            totemDuration,
            Enum.StatusBarInterpolation.Immediate,
            timerDir
        )
        
        -- Evaluate the duration to get alpha values (like statusBar progressBar/fullBar alpha)
        -- This allows bg/border/glow to sync with the actual duration state
        local configAlpha = (config.totemBar.color and config.totemBar.color.a) or 1
        local bgConfigAlpha = (config.totemBar.backgroundColor and config.totemBar.backgroundColor.a) or 1
        local glowConfigAlpha = (config.totemBar.glowColor and config.totemBar.glowColor.a) or 1
        local borderConfigAlpha = (config.totemBar.borderColor and config.totemBar.borderColor.a) or 1
        
        local totemBarAlpha = 1  -- Default to full visibility (progress)
        local fullBarAlpha = 0  -- Default to no full bar
        local bgAlpha = 1
        local glowAlpha = 1
        local borderAlpha = 1
        
        if totemDuration then
            -- Use the same curve evaluation as statusBar progressBar
            totemBarAlpha = totemDuration:EvaluateRemainingDuration(
                SpellStyler.Util:IsValidCooldownCurve(true, configAlpha)
            )
            -- Calculate fullBar alpha using inverse curve (fills when NOT active, like statusBar)
            fullBarAlpha = totemDuration:EvaluateRemainingDuration(
                SpellStyler.Util:IsValidCooldownCurve(false, configAlpha)
            )
            -- Calculate separate alphas for bg/glow/border with their config alphas
            bgAlpha = totemDuration:EvaluateRemainingDuration(
                SpellStyler.Util:IsValidCooldownCurve(true, bgConfigAlpha)
            )
            glowAlpha = totemDuration:EvaluateRemainingDuration(
                SpellStyler.Util:IsValidCooldownCurve(true, glowConfigAlpha)
            )
            borderAlpha = totemDuration:EvaluateRemainingDuration(
                SpellStyler.Util:IsValidCooldownCurve(true, borderConfigAlpha)
            )
        end
        
        -- Apply visual state after duration is set, passing the duration-based alphas
        FrameTrackerManager.ApplyVisibility.TotemBar({
            customFrame = frame,
            config = config,
            displayState = config.totemBar.displayState,
            totemBarConfig = config.totemBar,
            totemBarAlpha = totemBarAlpha,  -- Duration-based alpha for progress
            fullBarAlpha = fullBarAlpha,  -- Duration-based alpha for full bar
            bgAlpha = bgAlpha,
            glowAlpha = glowAlpha,
            borderAlpha = borderAlpha,
            isFull = config.totemBar and config.totemBar.defaultFillValue == 'full'
        })
    end)
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
    for _, tType in ipairs({"buffs", "essential", "utility", "spells", "items"}) do
        if FrameTrackerManager.SpellStyler_frames[tType] then
            for donk, frame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                if frame and frame.Hide then
                    frame:Hide()
                    frame:ClearAllPoints()
                    frame:SetSize(0, 0)
                    frame:SetParent(nil)
                    
                    -- Also hide variant frame if it exists
                    if frame.variantFrame then
                        frame.variantFrame:Hide()
                        frame.variantFrame:ClearAllPoints()
                        frame.variantFrame:SetSize(0, 0)
                        frame.variantFrame:SetParent(nil)
                    end
                    FrameTrackerManager.SpellStyler_frames[tType][donk] = 'cleared  ' .. donk
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
    FrameTrackerManager.SpellStyler_frames      = { buffs = {}, essential = {}, utility = {}, spells = {}, items = {} }
    FrameTrackerManager._activeTotemSlots       = {}  -- Clear active totem slot tracking on spec change
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
            itemID         = frame.meta.itemID,
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

    -- Get current charges first (needed for ApplyCooldownDuration)
    local currentCharges = nil
    local useDisplayCount = config.countText and config.countText.useSpellDisplayCount
    if flags.syncChargeText and not useDisplayCount then
        currentCharges = FrameTrackerManager:renderUpdateChargesText({
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

    FrameTrackerManager.ApplyVisibility.VisualChargeBar({
        progressBarAlpha = progressBar,
        fullBarAlpha = fullBar,
        charges = currentCharges,
        customFrame = frame,
        displayState = config.visualChargeBar.displayState,
        visualChargeBar = config.visualChargeBar,
        config = config
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
        textAlpha = whenActive,
        activeSpellID = frame.meta.activeSpellID,
        
    })
    
    -- Update collapsible container visibility if frame is in a container
    FrameTrackerManager:UpdateCollapsibleContainers(frame)
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
    local config = State:GetSpecificTrackerValue(frame.meta.baseSpellID, frame.meta.trackerType)
    
    -- Handle mock cooldown override
    if frame.meta.mockCooldownActive then
        return 0, 1, 1, 0  -- available=0, active=1, progress=1, full=0
    end
    
    local statusBarAlpha = (config and config.statusBar and config.statusBar.color and config.statusBar.color.a) or 1
    
    -- Buffs: simple aura presence check
    if trackerType == 'buffs' then
        local hasAura = frame.meta.currentAuraInstanceID and frame.meta.currentAuraInstanceID ~= 0
        
        return hasAura and 0 or 1, 
               hasAura and 1 or 0, 
               hasAura and statusBarAlpha or 0, 
               hasAura and 0 or statusBarAlpha
    end
    
    -- Items: build duration object on the fly and check cooldown state
    if config and config.isItem and frame.meta.itemID then
        local durationObj = FrameTrackerManager:GetItemDurationObject(frame.meta.itemID)
        
        local whenAvailableToCast, whenOnCooldown, progressBar, fullBar
        
        if durationObj and not durationObj:IsZero() then
            -- Item is on cooldown
            whenAvailableToCast = 0
            whenOnCooldown = 1
            progressBar = statusBarAlpha  -- Items have full progress bar during cooldown
            fullBar = 0
        else
            -- Item is available
            whenAvailableToCast = 1
            whenOnCooldown = 0
            progressBar = 0
            fullBar = statusBarAlpha
        end
        
        return whenAvailableToCast, whenOnCooldown, progressBar, fullBar
    end

    -- Spells: use secret-safe charge count or duration curves
    local cooldownInfo = C_Spell.GetSpellCooldown(activeSpellID)
    local chargeInfo = C_Spell.GetSpellCharges(activeSpellID)
    
    -- Determine which duration object to use
    local durationObj = (chargeInfo and chargeInfo.maxCharges > 1)
        and C_Spell.GetSpellChargeDuration(activeSpellID, true)
        or C_Spell.GetSpellCooldownDuration(activeSpellID, true)
    
    local whenAvailableToCast, whenOnCooldown, progressBar, fullBar
    

    if chargeInfo and chargeInfo.maxCharges > 1 then
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
        fullBar = durationObj:EvaluateRemainingDuration(SpellStyler.Util:IsValidCooldownCurve(false, statusBarAlpha))
        progressBar = durationObj:EvaluateRemainingDuration(SpellStyler.Util:IsValidCooldownCurve(true, statusBarAlpha))
    else
        fullBar = 0
        progressBar = 0
    end
    
    return whenAvailableToCast, whenOnCooldown, progressBar, fullBar
end


--- @param data ApplyCooldownDurationData
--- @return number? currentCharges The current charge count (secret value for spells, aura applications for buffs)
function FrameTrackerManager:renderUpdateChargesText(data)
    if not data.customFrame or not data.config then return nil end
    
    local chargesReturnValue = nil
    local success, error = pcall(function()
        local countCfg = data.config.countText
        if countCfg then
            -- Apply font size: check override first, then state
            local sizeOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, "countText.size")
            local fontSize = sizeOverride or countCfg.size
            local fontPath, _, fontFlags = data.customFrame.count:GetFont()
            if fontSize then
                local resolvedFontPath = State:ResolveFontPath(countCfg.font, fontPath)
                local resolvedFontFlags = State:ResolveFontFlags(countCfg.fontFlags, fontFlags)
                data.customFrame.count:SetFont(resolvedFontPath, fontSize, resolvedFontFlags or "OUTLINE")
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
                    chargesReturnValue = auraCountAsNumber
                    if data.config.countText.display then
                        data.customFrame.count:SetText(playerCount or targetCount)
                    else
                        data.customFrame.count:SetText("")
                    end

                    local s,e = pcall(function() data.customFrame.visualChargeBar:SetValue(auraCountAsNumber) end)

                    -- Apply alpha based on displayState setting (cannot check currentCharges as it may be secret)
                    local displayState = data.config.visualChargeBar.displayState
                    local barAlpha
                    if displayState == "always" then
                        barAlpha = 1
                    elseif displayState == "available" then
                        barAlpha = auraCountAsNumber
                    else
                        barAlpha = 0 --this would be when displayState == never
                    end
                    data.customFrame.visualChargeBar:SetAlpha(barAlpha)
                    -- Also update status bar color alpha (SetAlpha doesn't override vertex color alpha)
                    local color = data.config.visualChargeBar.color
                    data.customFrame.visualChargeBar:SetStatusBarColor(color.r, color.g, color.b, barAlpha)
                    if data.customFrame.visualChargeBar.fullCoverTexture then
                        data.customFrame.visualChargeBar.fullCoverTexture:SetVertexColor(color.r, color.g, color.b, barAlpha)
                    end

                    if data.config.chargeBasedDisplay.enabled or (SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:TrackerHasChargesConditionals(data.config)) then
                        local chargeValue = auraCountAsNumber or 0
                        if data.customFrame.chargeAnchorBarA then
                            data.customFrame.chargeAnchorBarA:SetValue(chargeValue)
                            if data.customFrame.chargeAnchorBarB then
                                data.customFrame.chargeAnchorBarB:SetValue(chargeValue)
                            end
                        end
                    end
                else
                    
                    local s,e = pcall(function() data.customFrame.visualChargeBar:SetValue(0) end)
                    local statusBarAlpha = data.config.visualChargeBar.displayState == 'always' and 1 or 0
                    data.customFrame.visualChargeBar:SetAlpha(statusBarAlpha)
                    local color = data.config.visualChargeBar.color
                    data.customFrame.visualChargeBar:SetStatusBarColor(color.r, color.g, color.b, statusBarAlpha)
                    if data.customFrame.visualChargeBar.fullCoverTexture then
                        data.customFrame.visualChargeBar.fullCoverTexture:SetVertexColor(color.r, color.g, color.b, statusBarAlpha)
                    end
                    data.customFrame.count:SetText("")
                    if data.config.chargeBasedDisplay.enabled or (SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:TrackerHasChargesConditionals(data.config)) then
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
            elseif data.customFrame.meta.trackerType == "spells" or data.customFrame.meta.trackerType == "items" then
                if not countCfg.display then
                    data.customFrame.count:SetAlpha(0)
                elseif data.customFrame.meta.trackerType == "items" then
                    -- Items don't have charges, hide count text
                    data.customFrame.count:SetAlpha(0)
                else
                    -- Spells: show charge count for multi-charge spells
                    local chargesData = C_Spell.GetSpellCharges(data.customFrame.meta.activeSpellID)
                    local currentCharges
                    if not chargesData or chargesData.maxCharges == 1 then
                        -- set zero so that spells with only 1 charge dont render the text
                        currentCharges = 0
                    else
                        currentCharges = chargesData.currentCharges
                    end
                    chargesReturnValue = currentCharges
                    data.customFrame.count:SetText(currentCharges)
                    data.customFrame.count:SetAlpha(currentCharges)
                    if data.config.chargeBasedDisplay.enabled or (SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:TrackerHasChargesConditionals(data.config)) then
                        if data.customFrame.chargeAnchorBarA then
                            data.customFrame.chargeAnchorBarA:SetValue(currentCharges)
                            if data.customFrame.chargeAnchorBarB then
                                data.customFrame.chargeAnchorBarB:SetValue(currentCharges)
                            end
                        end
                    end
                    
                    -- Update visualChargeBar if visualChargeBar config exists
                    data.customFrame.visualChargeBar:SetValue(currentCharges)
                    local s,e = pcall(function() data.customFrame.visualChargeBar:SetValue(currentCharges) end)
                    -- Apply alpha based on displayState setting (cannot check currentCharges as it may be secret)
                    local displayState = data.config.visualChargeBar.displayState
                    local barAlpha
                    if displayState == "always" then
                        barAlpha = 1
                    elseif displayState == "available" then
                        barAlpha = currentCharges
                    else
                        barAlpha = 0
                    end
                    data.customFrame.visualChargeBar:SetAlpha(barAlpha)
                    -- Also update status bar color alpha (SetAlpha doesn't override vertex color alpha)
                    local color = data.config.visualChargeBar.color
                    data.customFrame.visualChargeBar:SetStatusBarColor(color.r, color.g, color.b, barAlpha)
                    if data.customFrame.visualChargeBar.fullCoverTexture then
                        data.customFrame.visualChargeBar.fullCoverTexture:SetVertexColor(color.r, color.g, color.b, barAlpha)
                    end
                end
            end
        end
    end)
    return chargesReturnValue
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
            },
            'statusBar'
        )
        end
    end,
    VisualChargeBar = function(context)
        -- Status bar frame alpha: controls visibility of the entire bar container
        -- When "always", the container is always visible; fill/border/bg alphas handle the details
        local progressBarFrameAlpha = 1
        local progressBarFillAlpha = 0
        -- the full bar alpha should always be zero because its based on charges, and a full bar would be equivalent to max charges
        local fullBarAlpha = 0
        
        if context.displayState == 'never' then
            progressBarFrameAlpha = 0
            progressBarFillAlpha = 0
        elseif context.displayState == 'always' then
            progressBarFrameAlpha = 1  -- Container always visible
            progressBarFillAlpha = 1
        elseif context.displayState == 'active' or context.displayState == 'cooldown' then
            progressBarFrameAlpha = context.charges
            progressBarFillAlpha = context.charges
        end
        
        local a, b = pcall(function()
            -- Check for cached conditional overrides first, fall back to state values
            local barColor = context.visualChargeBar.color
            if SpellStyler.ConditionalEngine then
                local overrideColor = SpellStyler.ConditionalEngine:GetCachedPropertyOverride(context.customFrame, "statusBar.color")
                if overrideColor then
                    barColor = overrideColor
                end
            end
            context.customFrame.visualChargeBar:SetAlpha(progressBarFrameAlpha)
            
            context.customFrame.visualChargeBar:SetStatusBarColor(
                barColor.r or 0.2,
                barColor.g or 0.8,
                barColor.b or 1,
                progressBarFillAlpha
            )
            context.customFrame.visualChargeBar.fullCoverTexture:Hide()
        end)
        local onlyBarOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(context.customFrame, "visualChargeBar.onlyRenderBar")
        local onlyBar = (onlyBarOverride ~= nil) and onlyBarOverride or (context.config.visualChargeBar.onlyRenderBar or false)
        if not onlyBar and context.config.visualChargeBar.displayState ~= 'never' and context.config.visualChargeBar.displayState ~= 'always' then
            -- Apply onlyRenderBar setting and visibility state to bg/glow/border
            FrameTrackerManager:SetStatusBarContainerVisibility(
                {
                    customFrame = context.customFrame,
                    config = context.config,
                    baseSpellID = context.customFrame.meta.baseSpellID,
                    activeSpellID = context.customFrame.meta.activeSpellID,
                    trackerType = context.customFrame.meta.trackerType,
                    statusBarFillAlpha = progressBarFillAlpha  -- Pass visibility alpha for bg/glow/border
                },
                'visualChargeBar'
            )
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
                -- Check if this is an item tracker
                local config = State:GetSpecificTrackerValue(context.customFrame.meta.baseSpellID, context.customFrame.meta.trackerType)
                if config and config.isItem then
                    -- Items: always show at full alpha during cooldown (no GCD for items)
                    context.customFrame.cooldown:SetAlpha(1)
                else
                    -- Spell tracker: hide during GCD using duration curves
                    local durationEqualToGCD = SpellStyler.Util:IsValidCooldownCurve(true)
                    local durationObject
                    local maxSpellCharges = 1
                    local spellChargeInfo = C_Spell.GetSpellCharges(context.customFrame.meta.activeSpellID)
                    if spellChargeInfo and spellChargeInfo.maxCharges then
                        maxSpellCharges = spellChargeInfo.maxCharges
                    end
                    if maxSpellCharges > 1 then
                        durationObject = C_Spell.GetSpellChargeDuration(context.customFrame.meta.activeSpellID, true)
                    else
                        durationObject = C_Spell.GetSpellCooldownDuration(context.customFrame.meta.activeSpellID, true)
                    end
                    
                    local alpha = durationObject and durationObject:EvaluateRemainingDuration(durationEqualToGCD) or 0
                    context.customFrame.cooldown:SetAlpha(alpha)
                end
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
    --[[
        customFrame
        config
        displayState
        totemBarConfig
        totemBarAlpha - duration-based alpha from curve evaluation (progress bar)
        fullBarAlpha - duration-based alpha for full cover texture
        bgAlpha - duration-based alpha for background (evaluated with bg config alpha)
        glowAlpha - duration-based alpha for glow (evaluated with glow config alpha)
        borderAlpha - duration-based alpha for border (evaluated with border config alpha)
        isFull - whether defaultFillValue is 'full'
    ]]
    TotemBar = function(context)
        -- Use duration-based alpha from context (like statusBar uses progressBarAlpha/fullBarAlpha)
        local totemBarAlpha = context.totemBarAlpha or 0
        local totemBarFrameAlpha = 1
        local totemBarFillAlpha = 0
        local fullBarAlpha = 0
        
        if context.displayState == 'never' then
            totemBarFrameAlpha = 0
            totemBarFillAlpha = 0
            fullBarAlpha = 0
        elseif context.displayState == 'always' then
            totemBarFrameAlpha = 1
            totemBarFillAlpha = totemBarAlpha
            fullBarAlpha = (context.isFull) and (context.fullBarAlpha or 0) or 0
        elseif context.displayState == 'active' or context.displayState == 'cooldown' then
            -- Only show during active totem (like statusBar shows during cooldown)
            totemBarFrameAlpha = totemBarAlpha
            totemBarFillAlpha = totemBarAlpha
            fullBarAlpha = 0
        end
        
        pcall(function()
            -- Check for cached conditional overrides first
            local barColor = context.totemBarConfig.color
            if SpellStyler.ConditionalEngine then
                local overrideColor = SpellStyler.ConditionalEngine:GetCachedPropertyOverride(context.customFrame, "totemBar.color")
                if overrideColor then
                    barColor = overrideColor
                end
            end
            
            context.customFrame.totemBar:SetAlpha(totemBarFrameAlpha)
            
            -- Set bar fill color with visibility alpha from duration
            context.customFrame.totemBar:SetStatusBarColor(
                barColor.r or 0.2,
                barColor.g or 0.8,
                barColor.b or 1,
                totemBarFillAlpha
            )
            
            -- Set full cover texture (like statusBar)
            if context.customFrame.totemBar.fullCoverTexture then
                context.customFrame.totemBar.fullCoverTexture:SetVertexColor(
                    barColor.r or 0.2,
                    barColor.g or 0.8,
                    barColor.b or 1,
                    fullBarAlpha
                )
            end
        end)
        
        -- Apply background, glow, and border visibility (like statusBar logic)
        local onlyBarOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(context.customFrame, "totemBar.onlyRenderBar")
        local onlyBar = (onlyBarOverride ~= nil) and onlyBarOverride or (context.config.totemBar.onlyRenderBar or false)
        
        -- Match statusBar conditional: exclude 'never' AND 'always' states
        if not onlyBar and context.config.totemBar.displayState ~= 'never' and context.config.totemBar.displayState ~= 'always' then
            FrameTrackerManager:SetStatusBarContainerVisibility({
                customFrame = context.customFrame,
                config = context.config,
                baseSpellID = context.customFrame.meta.baseSpellID,
                activeSpellID = context.customFrame.meta.activeSpellID,
                trackerType = context.customFrame.meta.trackerType,
                statusBarFillAlpha = totemBarFillAlpha,
                bgAlpha = context.bgAlpha,
                glowAlpha = context.glowAlpha,
                borderAlpha = context.borderAlpha
            }, 'totemBar')
        end
    end,
}

--- Creates and returns a duration object for an item cooldown
--- @param itemID number The item ID to get cooldown for
--- @return table|nil durationObject The duration object, or nil if item has no cooldown or on error
function FrameTrackerManager:GetItemDurationObject(itemID)
    if not itemID then return nil end
    
    local durationObject = nil
    local success, error = pcall(function()
        local startTimeSeconds, durationSeconds, enableCooldownTimer = C_Item.GetItemCooldown(itemID)
        if startTimeSeconds and durationSeconds and durationSeconds > 0 then
            durationObject = C_DurationUtil.CreateDuration()
            durationObject:SetTimeFromStart(startTimeSeconds, durationSeconds)
        end
    end)
    
    if error or not durationObject then
        return nil
    end
    
    return durationObject
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
        elseif data.config and data.config.isItem then
            -- Items: create duration object using GetItemDurationObject
            s, e = pcall(function()
                durationObject = FrameTrackerManager:GetItemDurationObject(data.itemID)
            end)
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
        FrameTrackerManager:SetMetaOnBaseAndVariant(data.customFrame, "buffStatus", 'active')
        local isZero = durationObject and durationObject.IsZero and durationObject:IsZero()
        local isSecret = issecretvalue(isZero)
        if not isSecret and isZero then
            FrameTrackerManager:SetMetaOnBaseAndVariant(data.customFrame, "buffStatus", 'present')
        end
    end
    data.customFrame.cooldown:SetCooldownFromDurationObject(durationObject)
end



-- When onlyRenderBar is true, hides bg/glow/border by zeroing their alpha.
-- When false, restores each element to its correct config alpha via SetVertexColor.
-- The main fill (SetStatusBarTexture) is never touched.

--- @param data ApplyCooldownDurationData
function FrameTrackerManager:SetStatusBarContainerVisibility(data, key)
    if not data.customFrame[key] then return end
    
    -- Safety check for config structure
    if not data.config or not data.config[key] then
        return
    end
    
    -- Use pre-calculated alphas if provided (for totemBar), otherwise fall back to statusBarFillAlpha
    -- For totemBar: bg/glow/border alphas are calculated with their config alphas in the curve evaluation
    -- For statusBar: we use the bar alpha for all elements (legacy behavior)
    local bgAlpha = data.bgAlpha or data.statusBarFillAlpha
    local glowAlpha = data.glowAlpha or data.statusBarFillAlpha
    local borderAlpha = data.borderAlpha or data.statusBarFillAlpha

    -- Background texture uses backgroundColor (check override first)
    if data.customFrame[key].bgTexture then
        local bgColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, key .. ".backgroundColor")
        local c = bgColorOverride or data.config[key].backgroundColor
        data.customFrame[key].bgTexture:SetVertexColor(c.r or 0, c.g or 0, c.b or 0, bgAlpha)
    end

    -- Glow overlay uses glowColor (check override first)
    if data.customFrame[key].glowTexture then
        local glowColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, key .. ".glowColor")
        local c = glowColorOverride or data.config[key].glowColor
        data.customFrame[key].glowTexture:SetVertexColor(c.r or 1, c.g or 1, c.b or 1, glowAlpha)
    end

    -- All 8 border pieces use borderColor (check override first)
    local borderColorOverride = SpellStyler.ConditionalEngine and SpellStyler.ConditionalEngine:GetCachedPropertyOverride(data.customFrame, key .. ".borderColor")
    local bc = borderColorOverride or data.config[key].borderColor
    local br, bg, bb = bc.r or 0, bc.g or 0, bc.b or 0
    if data.customFrame[key].borderCornerTL then data.customFrame[key].borderCornerTL:SetVertexColor(br, bg, bb, borderAlpha) end
    if data.customFrame[key].borderCornerTR then data.customFrame[key].borderCornerTR:SetVertexColor(br, bg, bb, borderAlpha) end
    if data.customFrame[key].borderCornerBR then data.customFrame[key].borderCornerBR:SetVertexColor(br, bg, bb, borderAlpha) end
    if data.customFrame[key].borderCornerBL then data.customFrame[key].borderCornerBL:SetVertexColor(br, bg, bb, borderAlpha) end
    if data.customFrame[key].borderEdgeTop    then data.customFrame[key].borderEdgeTop:SetVertexColor(br, bg, bb, borderAlpha)    end
    if data.customFrame[key].borderEdgeRight  then data.customFrame[key].borderEdgeRight:SetVertexColor(br, bg, bb, borderAlpha)  end
    if data.customFrame[key].borderEdgeBottom then data.customFrame[key].borderEdgeBottom:SetVertexColor(br, bg, bb, borderAlpha) end
    if data.customFrame[key].borderEdgeLeft   then data.customFrame[key].borderEdgeLeft:SetVertexColor(br, bg, bb, borderAlpha)   end
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
    for _, tType in ipairs({"essential", "utility", "spells", "items"}) do
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

    -- Queue all frames for creation (buffs + spells/items)
    FrameTrackerManager:SetupCooldownManagerHooks()
    FrameTrackerManager:CreateNonBuffTrackerFrames()
    
    -- Build dependency tree and create frames in correct order
    local tree = FrameTrackerManager:BuildAnchorDependencyTree()
    FrameTrackerManager:CreateFramesFromDependencyTree(tree)
    
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
        
        -- Build dependency tree and create frames in correct order
        local delayedTree = FrameTrackerManager:BuildAnchorDependencyTree()
        FrameTrackerManager:CreateFramesFromDependencyTree(delayedTree)
        
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
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("UNIT_TARGET")
eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")


local function eventHandlers(event, frame, meta)
    if event == "SPELL_DATA_LOAD_RESULT" then
        FrameTrackerManager:SetMetaOnBaseAndVariant(frame, "spellName", meta.spellName)
        FrameTrackerManager:SetMetaOnBaseAndVariant(frame, "isSpellWithCharges", meta.isSpellWithCharges)
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
        if frame and frame.cooldown then frame.cooldown:Clear() end
        if frame and frame.statusBar then frame.statusBar:SetValue(0) end
        FrameTrackerManager:DriveFrameUpdate(
            frame, {
                resolveDuration = true,
                syncChargeText = true
            },
            nil,
            'spellupdateCharges'
        )
        -- local isActive = C_Spell.GetSpellCharges(frame.meta.activeSpellID).isActive
        -- -- clear any active cooldown and reapply (This helps when a spell gains its final charge in the middle of a cooldown. It will clear, rather than compeltely the cooldown duration that means nothing at that point)
        -- if not isActive then
        -- else
        --     FrameTrackerManager:DriveFrameUpdate(
        --         frame, {
        --             resolveDuration = true,
        --             syncChargeText = true
        --         },
        --         nil,
        --         'spellupdateCharges'
        --     )
        -- end
    end
    if event == "UNIT_POWER_UPDATE" then
    end
    if event == "UNIT_AURA" then
        FrameTrackerManager:SetMetaOnBaseAndVariant(frame, "currentAuraInstanceID", 0)
        FrameTrackerManager:SetMetaOnBaseAndVariant(frame, "buffStatus", 'absent')
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
        FrameTrackerManager:SetMetaOnBaseAndVariant(frame, "activeSpellID", meta.activeSpellID)
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
    for _, tType in ipairs({"essential", "utility", "spells", "buffs", "items"}) do
        if FrameTrackerManager.SpellStyler_frames[tType] then
            for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
                -- Update configuration changes first
                FrameTrackerManager:ApplyStaticFrameProperties(baseSpellID, tType)
                
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

    if event == "PLAYER_FOCUS_CHANGED" or event == "PLAYER_TARGET_CHANGED" then
        SpellStyler.ConditionalEngine:EvaluateAll()
    end


    if event == "UNIT_HEALTH" or event == "UNIT_TARGET" then
        local unitTarget = ...
        if unitTarget == 'player' or unitTarget == 'focus' or unitTarget == 'target' then
            SpellStyler.ConditionalEngine:EvaluateAll()
        end
    end

    if event == "PLAYER_TOTEM_UPDATE" then
        local slot = ...
        local totemDuration = GetTotemDuration(slot)

        -- If there is no duration in this slot, CLEAR the associated frame and remove the binding/saved frame
        if not totemDuration then
            local frame = FrameTrackerManager._activeTotemSlots[slot]
            if frame then
                if frame.meta.dualFrameStatus ~= 'hideBase' then
                    FrameTrackerManager:ClearTotemBarDuration(frame)
                end
                if frame.variantFrame and frame.meta.dualFrameStatus ~= 'hideVariant' then
                    FrameTrackerManager:ClearTotemBarDuration(frame.variantFrame)
                end
            end
            FrameTrackerManager._activeTotemSlots[slot] = nil
        end
        -- Use a small delay to let the spell queue populate
        C_Timer.After(0.01, function()
            -- Step 1: Check if there's a queued spell that should be associated with this slot
            local queuedSpellID = FrameTrackerManager:GetNextTotemQueueSpell()
            if queuedSpellID then
                local match = FrameTrackerManager:MatchTrackerFrame(queuedSpellID)
                if match and match.customFrame then
                    
                    -- If this slot already has a different frame, clear its totem bar first
                    local existingFrame = FrameTrackerManager._activeTotemSlots[slot]
                    if existingFrame and existingFrame ~= match.customFrame then
                        if existingFrame.meta.dualFrameStatus ~= 'hideBase' then
                            FrameTrackerManager:ClearTotemBarDuration(existingFrame)
                        end
                        if existingFrame.variantFrame and existingFrame.meta.dualFrameStatus ~= 'hideVariant' then
                            FrameTrackerManager:ClearTotemBarDuration(existingFrame.variantFrame)
                        end
                    end
                    
                    -- Associate this frame with this slot and store slot on frame
                    FrameTrackerManager._activeTotemSlots[slot] = match.customFrame
                    -- Store slot number on frame metadata for later retrieval
                    FrameTrackerManager:SetMetaOnBaseAndVariant(match.customFrame, "totemSlot", slot)
                    FrameTrackerManager:RemoveSpellFromTotemQueue(queuedSpellID)
                end
            end
            
            -- Step 2: Apply or clear duration for whatever frame is in this slot
            local frame = FrameTrackerManager._activeTotemSlots[slot]
            if frame then
                if totemDuration then
                    -- Totem is active (or just started), apply the duration
                    if frame.meta.dualFrameStatus ~= 'hideBase' then
                        FrameTrackerManager:ApplyTotemBarDuration(frame, totemDuration)
                    end
                    if frame.variantFrame and frame.meta.dualFrameStatus ~= 'hideVariant' then
                        FrameTrackerManager:ApplyTotemBarDuration(frame.variantFrame, totemDuration)
                    end
                end
            end
        end)
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
        -- This handles combo points AND mana ect. which are used by the IsSpellUsable conditional type
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
        for _, tType in ipairs({"spells", "items"}) do
            if FrameTrackerManager.SpellStyler_frames[tType] then
                for baseSpellID, customFrame in pairs(FrameTrackerManager.SpellStyler_frames[tType]) do
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
                        if override ~= spellID and not match.customFrame.meta.isItem then
                            local spellInfoUpdate = C_Spell.GetSpellInfo(override)
                            --The spell that was cast, is not equal to the active spell (likely due to changing via its cast). Wait for the spell cast to match the active in order to apply to correct/active cooldown
                            --Save the override spell onto the frame though to be able to check future casts
                            FrameTrackerManager:SetMetaOnBaseAndVariant(match.customFrame, "activeSpellID", override)

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
                            
                            -- Check if this spell should track totem duration
                            if match.config and match.config.totemBar and match.config.totemBar.attemptToTrack then
                                FrameTrackerManager:AddSpellToTotemQueue(spellID)
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
                    FrameTrackerManager:SetMetaOnBaseAndVariant(frameMatchData.customFrame, "activeSpellID", overrideSpellID)
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
