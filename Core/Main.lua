-- TexCoord Tester UI
local coordFrame
local cornerFrames = {}
local selectedCorner = nil
local posStep = 1

local function UpdateCornerDisplay(corner)
    if not corner then return end
    corner.texture:SetTexCoord(corner.left, corner.right, corner.top, corner.bottom)
    if corner.rotation then
        corner.texture:SetRotation(math.rad(corner.rotation))
    end
    corner.frame:SetSize(corner.width or 100, corner.height or 100)
    corner.inputs.leftBox:SetText(string.format("%.3f", corner.left))
    corner.inputs.rightBox:SetText(string.format("%.3f", corner.right))
    corner.inputs.topBox:SetText(string.format("%.3f", corner.top))
    corner.inputs.bottomBox:SetText(string.format("%.3f", corner.bottom))
    if corner.inputs.widthBox then
        corner.inputs.widthBox:SetText(string.format("%.0f", corner.width or 100))
    end
    if corner.inputs.heightBox then
        corner.inputs.heightBox:SetText(string.format("%.0f", corner.height or 100))
    end
    
end

local function SelectCorner(corner)
    -- Deselect all
    for _, c in ipairs(cornerFrames) do
        c.frame:SetBackdropBorderColor(1, 1, 1, 1)
    end
    selectedCorner = corner
    if corner then
        corner.frame:SetBackdropBorderColor(1, 1, 0, 1) -- Yellow highlight
    end
end

local function CreateCornerFrame(parent, name, point, xOff, yOff, l, r, t, b, rot, width, height)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(width, height)
    frame:SetPoint(point, parent, point, xOff, yOff)
    frame:SetBackdropColor(0.1, 0.1, 0.1, 00)
    frame:SetBackdropBorderColor(1, 1, 1, 0)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(frame)
    tex:SetTexture("Interface\\AddOns\\SpellStyler\\Media\\Textures\\bar_full_plus_cropped")
    tex:SetTexCoord(l,r,t,b)
    local corner = {
        frame = frame,
        texture = tex,
        name = name,
        parent = parent,
        anchorPoint = point,
        anchorX = xOff,
        anchorY = yOff,
        left = l or 0,
        right = r or 1,
        top = t or 0,
        bottom = b or 1,
        rotation = rot or 0,
        width = width,
        height = height,
        inputs = {}
    }
    
    frame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            SelectCorner(corner)
        end
    end)
    
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Get the original anchor points
        local anchorPoint = corner.anchorPoint or "CENTER"
        local parentAnchor = corner.anchorPoint or "CENTER"
        -- Get the parent's anchor position
        local px, py = parent:GetPoint(parentAnchor)
        if not px or not py then px, py = parent:GetLeft(), parent:GetTop() end
        -- Get the child's anchor position
        local fx, fy = self:GetPoint(anchorPoint)
        if not fx or not fy then fx, fy = self:GetLeft(), self:GetTop() end
        -- Calculate new offsets
        local offsetX = fx - px
        local offsetY = fy - py
        -- Re-anchor to parent with new offset and same anchor points
        self:ClearAllPoints()
        self:SetPoint(anchorPoint, parent, parentAnchor, offsetX, offsetY)
        corner.anchorPoint = anchorPoint
        corner.anchorX = offsetX
        corner.anchorY = offsetY
    end)
    
    return corner
end

local function CreateTexCoordTester()
    if coordFrame then 
        coordFrame:Show()
        return 
    end
    
    wipe(cornerFrames)
    
    coordFrame = CreateFrame("Frame", "ss_TexCoordTester", UIParent, "BackdropTemplate")
    coordFrame:SetSize(100, 400)
    coordFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    coordFrame:SetBackdrop({ 
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        -- edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        -- insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    coordFrame:SetBackdropColor(0, 0, 0, 1)
    coordFrame:EnableMouse(true)
    coordFrame:SetMovable(true)
    coordFrame:RegisterForDrag("LeftButton")
    coordFrame:SetScript("OnDragStart", coordFrame.StartMoving)
    coordFrame:SetScript("OnDragStop", coordFrame.StopMovingOrSizing)
    
    -- Create 8 frames with preset values
    --parent, name, point, xOff, yOff, l, r, t, b, rot, width, height
    cornerFrames[1] = CreateCornerFrame(coordFrame, "TopLeftCorner", "TOPLEFT", -22, 22, 0, 0.28, 0.316, 0.59, 0, 110, 108)
    cornerFrames[2] = CreateCornerFrame(coordFrame, "TopRightCorner", "TOPRIGHT", 68, 28.99, 0.8, 1, 0.002, 0.255, 0, 100, 100)
    cornerFrames[6] = CreateCornerFrame(coordFrame, "Corner1", "BOTTOMRIGHT", 10, -6, 0.34, 0.483, 0.27, 0.42, 90, 68, 68)
    cornerFrames[7] = CreateCornerFrame(coordFrame, "Corner2", "BOTTOMLEFT", -6, -8, 0.34, 0.483, 0.27, 0.42, 0, 68, 68)
    
    -- Create input panel on the right side
    local inputPanel = CreateFrame("Frame", nil, coordFrame, "BackdropTemplate")
    inputPanel:SetSize(380, 750)
    inputPanel:SetPoint("BOTTOM", coordFrame, "BOTTOM", 0, 10)
    -- inputPanel:SetBackdrop({ 
    --     bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    --     edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    --     tile = true, tileSize = 8, edgeSize = 8,
    --     insets = { left = 2, right = 2, top = 2, bottom = 2 }
    -- })
    inputPanel:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    
    local yOffset = -10
    for i, corner in ipairs(cornerFrames) do
        local label = inputPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        label:SetPoint("TOPLEFT", inputPanel, "TOPLEFT", 10, yOffset)
        label:SetText(string.format("%s (Rot:%.0f°)", corner.name, corner.rotation))
        yOffset = yOffset - 20
        
        -- Create 4 input boxes for each corner
        local function CreateInput(labelText, key, xPos, maxVal)
            local lbl = inputPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            lbl:SetPoint("TOPLEFT", inputPanel, "TOPLEFT", xPos, yOffset)
            lbl:SetText(labelText)
            
            local editbox = CreateFrame("EditBox", nil, inputPanel, "InputBoxTemplate")
            editbox:SetSize(50, 20)
            editbox:SetPoint("LEFT", lbl, "RIGHT", 10, 0)
            editbox:SetAutoFocus(false)
            editbox:SetText("0.00")
            editbox:SetScript("OnEnterPressed", function(self)
                local val = tonumber(self:GetText()) or 0
                if maxVal then
                    val = math.max(0, math.min(val, maxVal))
                else
                    val = math.max(0, math.min(val, 1))
                end
                corner[key] = val
                if key == "anchorX" or key == "anchorY" then
                    corner.frame:SetPoint(corner.anchorPoint, corner.parent, corner.anchorPoint, corner.anchorX or 0, corner.anchorY or 0)
                end
                UpdateCornerDisplay(corner)
                self:ClearFocus()
            end)
            editbox:SetScript("OnEscapePressed", function(self)
                self:ClearFocus()
            end)
            
            corner.inputs[key .. "Box"] = editbox
        end
        
        CreateInput("L:", "left", 10)
        CreateInput("R:", "right", 100)
        CreateInput("T:", "top", 190)
        CreateInput("B:", "bottom", 280)
        yOffset = yOffset - 20
        -- Add Width and Height inputs
        CreateInput("W:", "width", 10, 1000)
        CreateInput("H:", "height", 100, 1000)
        
        CreateInput("Y:", "anchorX", 200, 10000)
        CreateInput("X:", "anchorY", 300, 10000)

        yOffset = yOffset - 40
    end
    
    -- Print button
    local printBtn = CreateFrame("Button", nil, inputPanel, "UIPanelButtonTemplate")
    printBtn:SetSize(120, 25)
    printBtn:SetPoint("BOTTOM", inputPanel, "BOTTOM", 0, 10)
    printBtn:SetText("Print Values")
    printBtn:SetScript("OnClick", function()
        print("===== Corner Frame Values =====")
        for _, corner in ipairs(cornerFrames) do
            local x, y = corner.frame:GetCenter()
            local px, py = coordFrame:GetCenter()
            local offsetX = x - px
            local offsetY = y - py
            print(string.format("%s: Offset(%.1f, %.1f) Size(%.0fx%.0f) TexCoord(L:%.3f R:%.3f T:%.3f B:%.3f) Rotation:%.0f", 
                corner.name, offsetX, offsetY, corner.width or 100, corner.height or 100, corner.left, corner.right, corner.top, corner.bottom, corner.rotation))
        end
        print("===============================")
    end)
    
    -- Instruction text
    local instructions = coordFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instructions:SetPoint("TOP", coordFrame, "TOP", 0, -5)
    instructions:SetText("Click a corner to select, then use arrow keys to move")
    
    -- Arrow key handling
    coordFrame:EnableKeyboard(true)
    coordFrame:SetScript("OnKeyDown", function(self, key)
        if not selectedCorner then return end
        local frame = selectedCorner.frame
        local point, relativeTo, relativePoint, xOff, yOff = frame:GetPoint()
        local newX, newY = xOff, yOff
        if key == "UP" then
            newY = yOff + posStep
        elseif key == "DOWN" then
            newY = yOff - posStep
        elseif key == "LEFT" then
            newX = xOff - posStep
        elseif key == "RIGHT" then
            newX = xOff + posStep
        else
            return
        end
        frame:SetPoint(point, relativeTo, relativePoint, newX, newY)
        -- Update anchorX and anchorY to match new offset
        selectedCorner.anchorPoint = point
        selectedCorner.anchorX = newX
        selectedCorner.anchorY = newY
    end)
    
    -- Initialize displays
    for _, corner in ipairs(cornerFrames) do
        UpdateCornerDisplay(corner)
    end
    
    SelectCorner(cornerFrames[1])
end

SLASH_SS_TEXCOORD1 = "/sstexcoord"
SlashCmdList["SS_TEXCOORD"] = function()
    CreateTexCoordTester()
end

SLASH_SS_TEXCOORDHIDE1 = "/sstexcoordhide"
SlashCmdList["SS_TEXCOORDHIDE"] = function()
    if coordFrame then coordFrame:Hide() end
end
-- ============================================================================
-- TweaksUI: Cooldowns - Main
-- Core addon initialization and slash commands
-- Version 3.0.2 - Unified Architecture
-- ============================================================================

local ADDON_NAME, SpellStyler = ...

-- Make SpellStyler accessible globally
_G.SpellStyler = SpellStyler


local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")

local addonLoaded = false
local playerLoggedIn = false

local function Initialize()
    if not addonLoaded or not playerLoggedIn then
        return
    end

    if SpellStyler.MinimapButton then
        SpellStyler.MinimapButton:Initialize()
    end
end

initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        addonLoaded = true
        -- Initialize account-wide DB
        SpellStyler_DB = SpellStyler_DB or {}

        -- Initialize per-character DB
        SpellStyler_CharDB = SpellStyler_CharDB or {}
        SpellStyler_CharDB.classSpecializations = SpellStyler_CharDB.classSpecializations or {}
        Initialize()
    elseif event == "PLAYER_LOGIN" then
        playerLoggedIn = true
        Initialize()
    end
end)



local frameData = {}
local visitiedFrames = {}
local savedTextures = {}

local function extractData(frame, parentFrameName)
    local frameName = ""
    local name = ""
    if frame.GetName then
        pcall(function() name = frame:GetName() or tostring(frame) end)
        if parentFrameName and parentFrameName ~= "" then
            frameName = parentFrameName .. "." .. name
        else
            frameName = name
        end
    end
    if frameName ~= "" then
        local texture = frame and frame.GetTexture and frame:GetTexture() or "no texture"
        local id = frame and frame.GetTextureFileId and frame:GetTextureFileId() or "no file id"
        local path = frame and frame.GetTextureFilePath and frame:GetTextureFilePath() or "no file path"
        if texture ~= "no texture" or id ~= "no file id" or path ~= "no file path" then
            local value = ""
            if texture ~= "no texture" then
                value = texture
            elseif id ~= "no file id" and id ~= path then
                value = id
            elseif path ~= "no file path" then
                value = path
            end
            if value ~= "no texture" or value ~= "no file id" or value ~= "no file path" then
                frameData[frameName] = value

                if not savedTextures[value] then
                    savedTextures[value] = frameName

                end
                return frameName
            end
        end
    end
    return frameName, name
end



-- Utility: List textures of all frames under mouse on Shift+Ctrl+L
local function ListTexturesUnderMouse(frame, parentFrameName)
    local frameName, name = extractData(frame, parentFrameName)
    name = name or ""
    if visitiedFrames[name] then return end 
    visitiedFrames[name] = true
    if string.find(name, "UIParent") then
        return
    end
    if name ~= "" then
        -- Process regions (textures, fontstrings, etc.)
        if frame.GetRegions then
            pcall(function()
                local regions = { frame:GetRegions() }
                for _, region in ipairs(regions) do
                    if region and type(region) == "table" then
                        -- local regionName = extractData(region, frameName)
                        ListTexturesUnderMouse(region, frameName)
                        -- Regions are not frames, so you usually do not recurse further
                    end
                end
            end)
        end
        -- Process child frames
        if frame.GetChildren then
            pcall(function()
                local children = { frame:GetChildren() }
                for _, child in ipairs(children) do
                    if child and type(child) == "table" then
                        -- local childName = extractData(child, frameName)
                        ListTexturesUnderMouse(child, frameName)
                    end
                end
            end)
        end
    end
end

-- Keybind handler: Shift+Ctrl+L
local texScanFrame = CreateFrame("Frame")
texScanFrame:SetPropagateKeyboardInput(true)
texScanFrame:RegisterEvent("PLAYER_LOGIN")
texScanFrame:SetScript("OnEvent", function()
    texScanFrame:SetScript("OnKeyDown", function(self, key)
        if key == "X" and IsShiftKeyDown() and IsControlKeyDown() then
            frameData = {}
            visitiedFrames = {}
            savedTextures = {}
            local frames = C_System.GetFrameStack(0, true)
            for _, frame in ipairs(frames) do
                ListTexturesUnderMouse(frame, "")    
            end
        end
    end)
    texScanFrame:SetScript("OnKeyUp", function(self, key) end)
    texScanFrame:SetScript("OnMouseDown", function() end)
    texScanFrame:SetScript("OnMouseUp", function() end)
    texScanFrame:EnableKeyboard(true)
end)


-- Texture Previewer UI
local previewFrame, upButton, downButton, nameText
local textureKeys = {}
local currentIndex = 1

local function UpdateTexturePreview()
    if not previewFrame or not upButton or not downButton or not nameText then return end
    if #textureKeys == 0 then
        previewFrame.texture:SetTexture(nil)
        nameText:SetText("No textures saved")
        return
    end
    local tex = textureKeys[currentIndex]
    local frameName = savedTextures[tex] or "Unknown"
    previewFrame.texture:SetTexture(tex)
    nameText:SetText("From: " .. frameName)
end

local function CycleTexture(direction)
    if #textureKeys == 0 then return end
    currentIndex = currentIndex + direction
    if currentIndex < 1 then currentIndex = #textureKeys end
    if currentIndex > #textureKeys then currentIndex = 1 end
    UpdateTexturePreview()
end

local function CreateTexturePreviewer()
    if previewFrame then return end
    previewFrame = CreateFrame("Frame", "ss_TexturePreviewer", UIParent, "BackdropTemplate")
    previewFrame:SetSize(400, 400)
    previewFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    --previewFrame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background", edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    previewFrame:SetBackdropColor(0,0,0,0)
    previewFrame:EnableMouse(true)
    previewFrame:SetMovable(true)
    previewFrame:RegisterForDrag("LeftButton")
    previewFrame:SetScript("OnDragStart", previewFrame.StartMoving)
    previewFrame:SetScript("OnDragStop", previewFrame.StopMovingOrSizing)

    previewFrame.texture = previewFrame:CreateTexture(nil, "ARTWORK")
    previewFrame.texture:SetAllPoints(previewFrame)
    previewFrame.texture:SetColorTexture(1,1,1,1)

    upButton = CreateFrame("Button", nil, previewFrame, "UIPanelButtonTemplate")
    upButton:SetSize(24, 24)
    upButton:SetPoint("LEFT", previewFrame, "RIGHT", 4, 16)
    upButton:SetText("▲")
    upButton:SetScript("OnClick", function() CycleTexture(1) end)

    downButton = CreateFrame("Button", nil, previewFrame, "UIPanelButtonTemplate")
    downButton:SetSize(24, 24)
    downButton:SetPoint("LEFT", previewFrame, "RIGHT", 4, -16)
    downButton:SetText("▼")
    downButton:SetScript("OnClick", function() CycleTexture(-1) end)

    nameText = previewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("TOP", previewFrame, "BOTTOM", 0, -8)
    nameText:SetText("")
end

-- Command to open the previewer and load textures
SLASH_SS_PREVIEW1 = "/sspreview"
SlashCmdList["SS_PREVIEW"] = function()
    CreateTexturePreviewer()
    -- Rebuild textureKeys from savedTextures
    wipe(textureKeys)
    for k in pairs(savedTextures) do
        table.insert(textureKeys, k)
    end
    table.sort(textureKeys, function(a, b) return tostring(a) < tostring(b) end)
    currentIndex = 1
    UpdateTexturePreview()
    previewFrame:Show()
end

-- Optionally, hide previewer with /sspreviewhide
SLASH_SS_PREVIEWHIDE1 = "/sspreviewhide"
SlashCmdList["SS_PREVIEWHIDE"] = function()
    if previewFrame then previewFrame:Hide() end
end



