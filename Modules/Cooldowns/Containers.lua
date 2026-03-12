-- Containers.lua
-- Creates and manages SpellStyler container frames

local ADDON_NAME, SpellStyler = ...
SpellStyler.Containers = SpellStyler.Containers or {}
local Containers = SpellStyler.Containers

-- ============================================================
-- Texture paths
-- ============================================================
local ADDON_PATH             = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\"
local TEX_BORDER_INNER       = ADDON_PATH .. "border_inner"
local TEX_BORDER_OUTTER      = ADDON_PATH .. "border_outter"
local TEX_EDGE_BORDER_INNER  = ADDON_PATH .. "edge_border_inner"
local TEX_EDGE_BORDER_OUTTER = ADDON_PATH .. "edge_border_outter"
local TEX_BG_CORNER          = ADDON_PATH .. "background_corner"
local TEX_BG_EDGE            = ADDON_PATH .. "background_edge"
local TEX_BG                 = ADDON_PATH .. "background"

-- ============================================================
-- Constants
-- ============================================================
local DEFAULT_ICON_SIZE = 48
local CORNER_SIZE       = 6

-- ============================================================
-- State
-- ============================================================
local activeName      = nil        -- name key of the currently selected container
local containerFrames = {}         -- live Frame objects keyed by container name

-- ============================================================
-- Default config factory
-- ============================================================

--- Returns a fresh default config table for a new container.
--- Mirrors the pattern of AddNewTrackerValueConfig in FrameTrackerManager.
local function AddNewContainerConfig(name)
    return {
        name            = name,
        associatedIcons = {},   -- uniqueIDs of icons assigned to this container
        orientation     = "horizontal",  -- "horizontal" or "vertical"
        columnLimit     = 0,             -- max icons per row when horizontal (0 = unlimited)
        rowLimit        = 0,             -- max icons per column when vertical  (0 = unlimited)
        alignment       = "left",        -- horizontal: left|center|right  vertical: top|center|bottom
        iconWidth       = DEFAULT_ICON_SIZE,  -- width applied to each icon inside this container
        iconHeight      = DEFAULT_ICON_SIZE,  -- height applied to each icon inside this container
    }
end

-- ============================================================
-- DB helpers (public)
-- ============================================================

--- Returns the containers table scoped to the current character + specialization.
--- Structure: { [containerName] = { name, associatedIcons = { uid, ... } } }
function Containers:GetDB()
    SpellStyler_CharDB = SpellStyler_CharDB or {}
    SpellStyler_CharDB.classSpecializations = SpellStyler_CharDB.classSpecializations or {}

    local specID = SpellStyler.FrameTrackerManager and SpellStyler.FrameTrackerManager:GetCurrentSpecID()
    if not specID then return {} end

    if not SpellStyler_CharDB.classSpecializations[specID] then
        SpellStyler_CharDB.classSpecializations[specID] = {}
    end
    local specDB = SpellStyler_CharDB.classSpecializations[specID]
    specDB.containers = specDB.containers or {}
    return specDB.containers
end

function Containers:GetNames()
    local containers = self:GetDB()
    local names = {}
    for name in pairs(containers) do table.insert(names, name) end
    table.sort(names)
    return names
end

-- ============================================================
-- Active name management (public)
-- ============================================================

function Containers:GetActiveName()       return activeName end
function Containers:SetActiveName(name)   activeName = name end
function Containers:GetActiveConfig()
    local containers = self:GetDB()
    return activeName and containers[activeName] or nil
end
function Containers:GetActiveFrame()      return activeName and containerFrames[activeName] or nil end

-- ============================================================
-- Add / Delete (public)
-- ============================================================

--- Creates a new container entry and its live frame. Returns the container name.
function Containers:Add()
    local containers = self:GetDB()
    local count = 0
    for _ in pairs(containers) do count = count + 1 end
    local name = "Container " .. (count + 1)
    -- Ensure name is unique
    while containers[name] do name = name .. "_" end
    containers[name]      = AddNewContainerConfig(name)
    activeName            = name
    containerFrames[name] = self:CreateContainer(UIParent, { name = name })
	Containers:SetEditMode(true)
    return name
end

--- Removes the container with the given name (default: activeName).
function Containers:Delete(name)
    name = name or activeName
    local containers = self:GetDB()
    if not containers[name] then return end
    local config = containers[name]  -- read before wiping

    if containerFrames[name] then
        containerFrames[name]:Hide()
        containerFrames[name] = nil
    end
    containers[name] = nil
    if config and config.associatedIcons then
        self:DetachIconsFromContainer(config.associatedIcons)
    end
    -- Move active to any remaining container, or nil
    activeName = next(containers)
end

-- ============================================================
-- Detach icons from a container (public)
-- ============================================================

--- Clears the _inContainer flag and restores ConfigurationChanges for each
--- uniqueID in the provided list.  Callers are responsible for updating
--- associatedIcons in the DB and re-running EnableDraggingForAllFrames.
---
--- @param uniqueIDs  table  Ordered list of uniqueID strings to detach.
function Containers:DetachIconsFromContainer(uniqueIDs)
    local FTM = SpellStyler.FrameTrackerManager
    if not FTM then return end
    for _, uniqueID in ipairs(uniqueIDs) do
        for _, tType in ipairs({"buffs", "essential", "utility"}) do
            local f = FTM:GetTrackerFrame(uniqueID, tType)
            if f then
                f._inContainer = nil
                FTM:UpdateFrame_ConfigurationChanges(uniqueID, tType)
                break
            end
        end
    end
    FTM:EnableDraggingForAllFrames()
end

-- ============================================================
-- Edit-mode toggle (public)
-- ============================================================

--- Called by NewSettings when the settings menu opens or closes.
--- Shows/hides container visuals and enables/disables dragging.
function Containers:SetEditMode(enabled)
    for _, frame in pairs(containerFrames) do
        if enabled then
            frame:SetAlpha(1)
            frame:EnableMouse(true)
        else
            frame:SetAlpha(0)
            frame:EnableMouse(false)
        end
    end
end

-- ============================================================
-- Layout (public)
-- ============================================================

--- Positions all icon frames assigned to the named container.
--- Called whenever icons are added or removed from the container.
function Containers:LayoutContainer(name)
    name = name or activeName
    if not name then return end
    local containers = self:GetDB()
    local config = containers[name]
    if not config then return end

    -- Create the container frame if it doesn't exist yet (e.g. on reload)
    if not containerFrames[name] then
        containerFrames[name] = self:CreateContainer(UIParent, { name = name })
        -- Restore saved position if one exists, otherwise the frame stays at CENTER
        if config.position then
            containerFrames[name]:ClearAllPoints()
            containerFrames[name]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
                config.position.x, config.position.y)
        end
        -- If settings is already open, immediately put this frame into edit mode
        if SpellStyler.settingsMenu and SpellStyler.settingsMenu:IsShown() then
            local f = containerFrames[name]
            f:SetAlpha(1)
            f:EnableMouse(true)
        end
    end
    local containerFrame = containerFrames[name]

    local FTM = SpellStyler.FrameTrackerManager
    if not FTM then return end

    local vertical  = (config.orientation == "vertical")
    local colLimit  = (type(config.columnLimit) == "number" and config.columnLimit >= 1)
                        and math.floor(config.columnLimit) or nil
    local rowLimit  = (type(config.rowLimit)    == "number" and config.rowLimit    >= 1)
                        and math.floor(config.rowLimit)    or nil
    local alignment = config.alignment or (vertical and "top" or "left")
    local N         = #config.associatedIcons

    local PADDING = 5  -- padding around the icon grid on all sides

    local trackerTypes = { "buffs", "essential", "utility" }
    -- Use the container's configured icon size; fall back to DEFAULT_ICON_SIZE.
    local containerIconW = (type(config.iconWidth)  == "number" and config.iconWidth  > 0) and config.iconWidth  or DEFAULT_ICON_SIZE
    local containerIconH = (type(config.iconHeight) == "number" and config.iconHeight > 0) and config.iconHeight or DEFAULT_ICON_SIZE

    -- Compute the grid dimensions so the container can be sized to wrap all icons.
    local numCols, numRows
    if N > 0 then
        if vertical then
            local R = rowLimit or N
            numRows = math.min(N, R)
            numCols = math.ceil(N / numRows)
        else
            local C = colLimit or N
            numCols = math.min(N, C)
            numRows = math.ceil(N / numCols)
        end
    else
        numCols, numRows = 1, 1
    end
    local gridWidth  = numCols * containerIconW + (numCols - 1) * 4
    local gridHeight = numRows * containerIconH + (numRows - 1) * 4
    containerFrame:SetSize(gridWidth + PADDING * 2, gridHeight + PADDING * 2)

    for i, uid in ipairs(config.associatedIcons) do
        for _, tType in ipairs(trackerTypes) do
            local frame = FTM:GetTrackerFrame(uid, tType)
            if frame then
                -- Resize the icon to the container's configured dimensions
                frame:SetSize(containerIconW, containerIconH)
                local iconW = containerIconW
                local iconH = containerIconH
                local idx   = i - 1  -- 0-based for modular arithmetic

                -- Compute 0-based grid position and per-row/col icon count.
                -- Use numCols/numRows (clamped to actual icon count) so that when
                -- there are fewer icons than the configured limit the positions and
                -- alignment offsets reflect the real grid, not the limit.
                local col, row, alignOffsetX, alignOffsetY = 0, 0, 0, 0
                if vertical then
                    -- Fill top-to-bottom; wrap into a new column after numRows rows
                    row         = idx % numRows
                    col         = math.floor(idx / numRows)
                    local iconsInCol = math.min(numRows, N - col * numRows)
                    if alignment == "bottom" then
                        alignOffsetY = (numRows - iconsInCol) * (iconH + 4)
                    elseif alignment == "center" then
                        alignOffsetY = math.floor((numRows - iconsInCol) * (iconH + 4) / 2)
                    end
                else
                    -- Fill left-to-right; wrap into a new row after numCols columns
                    col         = idx % numCols
                    row         = math.floor(idx / numCols)
                    local iconsInRow = math.min(numCols, N - row * numCols)
                    if alignment == "right" then
                        alignOffsetX = (numCols - iconsInRow) * (iconW + 4)
                    elseif alignment == "center" then
                        alignOffsetX = math.floor((numCols - iconsInRow) * (iconW + 4) / 2)
                    end
                end

                frame:ClearAllPoints()
                frame:SetPoint("TOPLEFT", containerFrame, "TOPLEFT",
                    PADDING + col * (iconW + 4) + alignOffsetX,
                    -(PADDING + row * (iconH + 4) + alignOffsetY))

                -- Lock the frame: it moves with the container only
                frame._inContainer = true
                frame:EnableMouse(false)
                frame:RegisterForDrag()
                frame:SetScript("OnDragStart", nil)
                frame:SetScript("OnDragStop",  nil)
                break
            end
        end
    end
end

-- ============================================================
-- Internal frame-building helpers
-- ============================================================

-- Adds a texture to a frame, filling it completely.
-- rotationDeg uses SetRotation — only reliable on SQUARE frames (corners).
local function AddTex(frame, texPath, drawLayer, rotationDeg)
    local tex = frame:CreateTexture(nil, drawLayer or "ARTWORK")
    tex:SetAllPoints(frame)
    tex:SetTexture(texPath)
    if rotationDeg and rotationDeg ~= 0 then
        tex:SetRotation(math.rad(rotationDeg))
    end
    return tex
end

-- UV coord tables for each edge orientation.
-- Uses the 8-arg SetTexCoord form: ULx,ULy, LLx,LLy, URx,URy, LRx,LRy
-- This correctly rotates the texture sampling even on non-square frames,
-- unlike SetRotation which clips when the frame is not square.
local EDGE_UV = {
    top    = {0,0,  0,1,  1,0,  1,1},   -- 0°   – default
    right  = {0,1,  1,1,  0,0,  1,0},   -- 90° CW
    bottom = {1,1,  1,0,  0,1,  0,0},   -- 180°
    left   = {1,0,  0,0,  1,1,  0,1},   -- 90° CCW
}

-- Adds a texture using UV-remapping for rotation — safe for non-square frames.
local function AddTexEdge(frame, texPath, drawLayer, edgeDir)
    local tex = frame:CreateTexture(nil, drawLayer or "ARTWORK")
    tex:SetAllPoints(frame)
    tex:SetTexture(texPath)
    local uv = EDGE_UV[edgeDir] or EDGE_UV.top
    tex:SetTexCoord(uv[1],uv[2], uv[3],uv[4], uv[5],uv[6], uv[7],uv[8])
    return tex
end

-- Builds one corner cluster: a CORNER_SIZE square sub-frame with three
-- stacked layers (background_corner / border_outter / border_inner) all
-- sharing the same TOPLEFT anchor.  rotationDeg rotates all three textures.
local function MakeCorner(parent, cornerPoint, rotationDeg)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(CORNER_SIZE, CORNER_SIZE)
    f:SetPoint(cornerPoint, parent, cornerPoint, 0, 0)
    f.texBg     = AddTex(f, TEX_BG_CORNER,     "BACKGROUND", rotationDeg)
    f.texOutter = AddTex(f, TEX_BORDER_OUTTER, "BORDER",     rotationDeg)
    f.texInner  = AddTex(f, TEX_BORDER_INNER,  "ARTWORK",    rotationDeg)
    return f
end

-- Anchor configs per edge: { pointA, relativeToA, pointAtA,  pointB, relativeToB, pointAtB }
local EDGE_ANCHORS = {
    top    = { "TOPLEFT",    "TOPRIGHT",    "TOPRIGHT",   "TOPLEFT"    },
    bottom = { "BOTTOMLEFT", "BOTTOMRIGHT", "BOTTOMRIGHT","BOTTOMLEFT" },
    left   = { "TOPRIGHT",   "BOTTOMRIGHT", "BOTTOMRIGHT","TOPRIGHT"   },
    right  = { "TOPLEFT",    "BOTTOMLEFT",  "BOTTOMLEFT", "TOPLEFT"    },
}

-- Builds one edge piece stretched between two corner frames.
-- edgeDir is 'top'|'right'|'bottom'|'left' and drives both anchoring and UV rotation.
local function MakeEdge(parent, frameA, frameB, edgeDir)
    local anchors = EDGE_ANCHORS[edgeDir]

    local function MakeEdgeLayer(drawLayer)
        local f = CreateFrame("Frame", nil, parent)
        f:SetSize(CORNER_SIZE, CORNER_SIZE)
        f:SetPoint(anchors[1], frameA, anchors[2], 0, 0)
        f:SetPoint(anchors[3], frameB, anchors[4], 0, 0)
        return f
    end

    local f          = MakeEdgeLayer("BACKGROUND")
    local layerInner  = MakeEdgeLayer("BACKGROUND")
    local layerOutter = MakeEdgeLayer("BACKGROUND")

    f.texBg              = AddTexEdge(f,          TEX_BG_EDGE,            "BACKGROUND", edgeDir)
    layerInner.texInner  = AddTexEdge(layerInner,  TEX_EDGE_BORDER_INNER,  "BACKGROUND", edgeDir)
    layerOutter.texOutter = AddTexEdge(layerOutter, TEX_EDGE_BORDER_OUTTER, "BACKGROUND", edgeDir)

    -- Store layer frames on f for external colour access
    f.layerInner  = layerInner
    f.layerOutter = layerOutter
    return f
end

-- ============================================================
-- Public API
-- ============================================================

--- Creates a container frame built from the SpellStyler border/background
--- textures.  The initial size matches the default icon size (48x48).
---
--- @param parent  Frame|nil  Parent frame; defaults to UIParent.
--- @param config  table|nil  Optional overrides:
---                   .width  (number)  Inner width  (default 48)
---                   .height (number)  Inner height (default 48)
---                   .name   (string)  Identifier stored on frame.containerName
--- @return Frame  The new container frame.
function Containers:CreateContainer(parent, config)
    config = config or {}
    local width  = config.width  or DEFAULT_ICON_SIZE
    local height = config.height or DEFAULT_ICON_SIZE

    local frame = CreateFrame("Frame", nil, parent or UIParent)
    frame:SetSize(width, height)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetMovable(true)
    -- Mouse / drag are off by default; enabled only when settings is open via SetEditMode(true)
    frame:EnableMouse(false)
    -- Use OnMouseDown/OnMouseUp instead of OnDragStart/OnDragStop to avoid WoW's
    -- built-in drag deadzone, which causes a noticeable delay before movement starts.
    frame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            self:StopMovingOrSizing()
            -- Persist position so it survives reloads
            local containers = SpellStyler.Containers:GetDB()
            local cfg = containers[self.containerName]
            if cfg then
                cfg.position = { x = self:GetLeft(), y = self:GetBottom() }
            end
            -- Re-anchor all bound icons relative to the container's new position
            Containers:LayoutContainer(self.containerName)
        end
    end)

    frame.containerName = config.name or "Container"

    -- ---- Corners -----------------------------------------------------------
    --  TL:   0°  |  TR: -90° (CW)  |  BR: 180°  |  BL: 90° (CCW)
    --  All three textures within each corner share the frame's TOPLEFT anchor.
    local cornerTL = MakeCorner(frame, "TOPLEFT",      0)
    local cornerTR = MakeCorner(frame, "TOPRIGHT",   -90)
    local cornerBR = MakeCorner(frame, "BOTTOMRIGHT", 180)
    local cornerBL = MakeCorner(frame, "BOTTOMLEFT",   90)

    -- ---- Edges -------------------------------------------------------------
    --  Top:    from cornerTL TOPRIGHT    → cornerTR BOTTOMRIGHT  (0°)
    --  Right:  from cornerTR BOTTOMLEFT  → cornerBR TOPRIGHT     (-90°, CW)
    --  Bottom: from cornerBL TOPRIGHT    → cornerBR BOTTOMLEFT   (180°)
    --  Left:   from cornerTL BOTTOMLEFT  → cornerBL TOPRIGHT      (90°, CCW)
    local edgeTop    = MakeEdge(frame, cornerTL, cornerTR, "top")
    local edgeRight  = MakeEdge(frame, cornerTR, cornerBR, "right")
    local edgeBottom = MakeEdge(frame, cornerBL, cornerBR, "bottom")
    local edgeLeft   = MakeEdge(frame, cornerTL, cornerBL, "left")

    -- ---- Background fill ---------------------------------------------------
    --  TOPLEFT  anchored to BOTTOMRIGHT of the TL corner.
    --  BOTTOMRIGHT anchored to TOPLEFT of the BR corner.
    --  This spans the full inner area between all four corners.
    local bgFill = CreateFrame("Frame", nil, frame)
    bgFill:SetPoint("TOPLEFT",     cornerTL, "BOTTOMRIGHT", 0,  0)
    bgFill:SetPoint("BOTTOMRIGHT", cornerBR, "TOPLEFT",     0,  0)
    bgFill.texBg = AddTex(bgFill, TEX_BG, "BACKGROUND", 0)

    -- ---- Default colours ---------------------------------------------------
    local OR, OG, OB = 55/255, 217/255, 255/255   -- outer edge
    local IR, IG, IB = 227/255, 1.0,    1.0        -- inner edge
    local BR, BG, BB, BA = 0.694, 0.953, 1.0, 0.605 -- background

    for _, c in ipairs({ cornerTL, cornerTR, cornerBR, cornerBL }) do
        c.texOutter:SetVertexColor(OR, OG, OB, 1)
        c.texInner:SetVertexColor(IR, IG, IB, 1)
        c.texBg:SetVertexColor(BR, BG, BB, BA)
    end
    for _, e in ipairs({ edgeTop, edgeRight, edgeBottom, edgeLeft }) do
        e.layerOutter.texOutter:SetVertexColor(OR, OG, OB, 1)
        e.layerInner.texInner:SetVertexColor(IR, IG, IB, 1)
        e.texBg:SetVertexColor(BR, BG, BB, BA)
    end
    bgFill.texBg:SetVertexColor(BR, BG, BB, BA)

    -- Store sub-frame references for external access
    frame.cornerTL   = cornerTL
    frame.cornerTR   = cornerTR
    frame.cornerBR   = cornerBR
    frame.cornerBL   = cornerBL
    frame.edgeTop    = edgeTop
    frame.edgeRight  = edgeRight
    frame.edgeBottom = edgeBottom
    frame.edgeLeft   = edgeLeft
    frame.bgFill     = bgFill

    -- Fully transparent and non-interactive by default.
    -- Call Containers:SetEditMode(true) (when settings is open) to reveal and enable drag.
    frame:SetAlpha(0)

    return frame
end
