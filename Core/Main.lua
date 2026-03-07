

-- ============================================================
-- Tab system
-- ============================================================
-- CreateTab(parent, label, width, height, onClickFn)
--   Creates a single tab with both visual states pre-built.
--   The selected layer uses the 3-part atlas texture.
--   The unselected layer is a simple dark backdrop (swap coords
--   here once the unselected atlas slice is known).
--   Returns a Button frame with:
--     tab:SetSelected(bool) -- swaps visual state
--     tab.onTabClick        -- callback field (settable externally)
--
-- SetTabGroupExclusive(tabList)
--   Wires a list of tabs from CreateTab so that clicking one
--   automatically deselects all others in the group.

local function CreateTab(parent, label, width, height, onClickFn)
    height = height or 40
    width  = width  or 100

    local CORNER_W      = 55   -- width of the right-side corner decorations
    local EDGE_H        = 20   -- height of the top/bottom edge strips
    local CORNER_H      = 25   -- height of corner cap frames
    local SEL_SHIFT     = 5    -- px to shift right when selected

    -- Container: full bounding box (face + corner overhang)
    local container = CreateFrame("Button", nil, parent)
    container:SetSize(width + CORNER_W, height)

    -- Content frame shifts right on select; all visuals live here
    local content = CreateFrame("Frame", nil, container)
    content:SetSize(width + CORNER_W, height)
    content:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)

    local function MakePiece(w, h, l, r, t, b, rot)
        local f = CreateFrame("Frame", nil, content)
        f:SetSize(w, h)
        local tex = f:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(f)
        tex:SetTexture(4707839)
        tex:SetTexCoord(l, r, t, b)
        if rot and rot ~= 0 then tex:SetRotation(math.rad(rot)) end
        return f
    end

    -- Top edge fill  (cornerFrames[4]: 0,1, 0.3,0.2, no extra rot)
    local topEdge = MakePiece(width, EDGE_H, 0, 1, 0.3, 0.2, 0)
    topEdge:SetPoint("TOPLEFT", content, "TOPLEFT", -15, 0)

    -- Top-right corner  (cornerFrames[1]: 0,1, 0.800,0.665, no extra rot)
    local topCorner = MakePiece(CORNER_W, CORNER_H, 0, 1, 0.800, 0.665, 0)
    topCorner:SetPoint("TOPLEFT", topEdge, "TOPRIGHT", 0, 1)

    -- Bottom edge fill  (cornerFrames[3]: 0,1, 0.2,0.3, no extra rot)
    local botEdge = MakePiece(width, EDGE_H, 0, 1, 0.2, 0.3, 0)
    botEdge:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", -15, 0)

    -- Bottom-right corner  (cornerFrames[2]: 0,1, 0.665,0.800, no extra rot)
    local botCorner = MakePiece(CORNER_W, CORNER_H, 0, 1, 0.665, 0.800, 0)
    botCorner:SetPoint("BOTTOMLEFT", botEdge, "BOTTOMRIGHT", 0, -1)

    -- Label: on its own frame above all piece child-frames
    -- (child frames always render above their parent's own draw layers in WoW,
    --  so the label must live on a frame with a higher FrameLevel than `content`)
    local labelHolder = CreateFrame("Frame", nil, container)
    labelHolder:SetSize(width, height)
    local labelShift = 15
    labelHolder:SetPoint("LEFT", container, "LEFT", labelShift, 0)
    labelHolder:SetFrameLevel(content:GetFrameLevel() + 2)
    -- Will be kept in sync with content's shift inside SetSelected
    local lbl = labelHolder:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    lbl:SetPoint("LEFT", labelHolder, "LEFT", 0, 0)
    lbl:SetText(label or "")

    -- Selected state: shift content AND labelHolder right together
    function container:SetSelected(selected)
        content:ClearAllPoints()
        -- labelHolder:ClearAllPoints()
        if selected then
            content:SetPoint("TOPLEFT",     container, "TOPLEFT", SEL_SHIFT, 0)
            -- labelHolder:SetPoint("TOPLEFT", container, "TOPLEFT", labelShift, 0)
            lbl:SetTextColor(1, 0.82, 0)
        else
            content:SetPoint("TOPLEFT",     container, "TOPLEFT", 0, 0)
            -- labelHolder:SetPoint("TOPLEFT", container, "TOPLEFT", labelShift, 0)
            lbl:SetTextColor(0.65, 0.65, 0.65)
        end
    end

    container.onTabClick = onClickFn
    container:SetScript("OnClick", function(self)
        if self.onTabClick then self.onTabClick(self) end
    end)

    container:SetSelected(false)
    return container
end

-- Wires a flat list of tabs so clicking one selects it and deselects all others.
-- Each tab's existing onTabClick callback is still called after the state swap.
local function SetTabGroupExclusive(tabList)
    for _, tab in ipairs(tabList) do
        local userCallback = tab.onTabClick
        tab.onTabClick = function(self)
            for _, t in ipairs(tabList) do t:SetSelected(false) end
            self:SetSelected(true)
            if userCallback then userCallback(self) end
        end
    end
end

-- Expose tab helpers to the SpellStyler namespace so other modules can use them
local ADDON_NAME_TABS, SpellStyler_TABS = ...
SpellStyler_TABS.CreateTab            = CreateTab
SpellStyler_TABS.SetTabGroupExclusive = SetTabGroupExclusive

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


