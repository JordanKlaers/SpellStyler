local ADDON_NAME, SpellStyler = ...
SpellStyler.AddSpells = SpellStyler.AddSpells or {}
local AddSpells = SpellStyler.AddSpells

local PLUS_ICON_PATH = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\PlusIcon"

-- ============================================================================
-- Spell data gathering
-- ============================================================================

--- Scans the player spellbook and returns a flat list of spells that belong to
--- the current spec or to the General tab (_specID == "none").
--- Each entry: { spellID, name, iconID, isPassive }
function AddSpells:GetCurrentSpecSpells()
    local currentSpecID = SpellStyler.State and SpellStyler.State.GetCurrentSpecID
        and SpellStyler.State:GetCurrentSpecID()

    local spells = {}
    local seen = {}   -- deduplicate by spellID

    local numLines = C_SpellBook.GetNumSpellBookSkillLines()
    for i = 1, numLines do
        local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(i)
        if lineInfo and not lineInfo.isGuild then
            local specID = lineInfo.specID  -- nil for General, number for spec tabs
            local isGeneral  = (specID == nil)
            local isCurrentSpec = currentSpecID and (specID == currentSpecID)

            if isGeneral or isCurrentSpec then
                local offset = lineInfo.itemIndexOffset
                local count  = lineInfo.numSpellBookItems
                for j = offset + 1, offset + count do
                    local info = C_SpellBook.GetSpellBookItemInfo(j, Enum.SpellBookSpellBank.Player)
					local donk = C_SpellBook.GetSpellBookItemLevelLearned(j, Enum.SpellBookSpellBank.Player)
                    if info
                        and not info.isOffSpec
                        and info.itemType == Enum.SpellBookItemType.Spell then
                        local sid = info.spellID or info.actionID
                        if sid and not seen[sid] then
                            seen[sid] = true
                            -- Use C_Spell.GetSpellInfo for authoritative icon/name
                            local si = C_Spell.GetSpellInfo(sid)
                            if si then
                                local cooldownMS = GetSpellBaseCooldown(sid)
                                if cooldownMS and cooldownMS > 0 then
                                    table.insert(spells, {
                                        spellID   = sid,
                                        name      = si.name,
                                        iconID    = si.iconID,
                                        isPassive = info.isPassive,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return spells
end

-- ============================================================================
-- Plus button (icon column entry)
-- ============================================================================

--- Creates and returns the plus icon button to be placed in the icon scroll child.
--- Caller is responsible for SetPoint positioning.
function AddSpells:CreatePlusButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(40, 40)
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(btn)
    tex:SetTexture(PLUS_ICON_PATH)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Add Spell", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp")
    return btn
end

-- ============================================================================
-- Add Spells view (right panel)
-- ============================================================================

local ICON_SIZE   = 36
local ICON_PAD    = 4
local ICONS_PER_ROW = 6

--- Renders the "Add Spell" view into the given parent panel.
--- Follows the same clear-and-rebuild pattern as RenderConfigControlsForSpecificIcon.
function AddSpells:RenderAddSpellsView(parent)
    if not parent then return end

    if parent.currentControlsContainer then
        parent.currentControlsContainer:Hide()
        parent.currentControlsContainer:SetParent(nil)
        parent.currentControlsContainer = nil
    end

    local container = CreateFrame("Frame", nil, parent)
    container:SetAllPoints()
    container:EnableMouse(true)
    parent.currentControlsContainer = container

    -- ── Selection state ────────────────────────────────────────────────
    local selectedSpell = nil
    local selectedBtn   = nil
    local addBtn        = nil  -- forward-declared so closures can reference it
    -- Forward-declared so the addBtn OnClick closure can reference them
    -- (Lua closures only capture locals that are in scope at definition time)
    local gridSF
    local gridButtons
    local lastFilter = ""
    local FilterAndLayoutSafe

    local function Deselect()
        if selectedBtn and SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:StopAnts(selectedBtn)
        end
        selectedSpell = nil
        selectedBtn   = nil
        if addBtn then addBtn:Disable() end
    end

    local function SelectSpell(spell, btn)
        -- deselect old
        if selectedBtn and SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:StopAnts(selectedBtn)
        end
        selectedSpell = spell
        selectedBtn   = btn
        if SpellStyler.GlowUtil then
            SpellStyler.GlowUtil:SetupAnts(btn, { r = 1, g = 0.82, b = 0 })
            SpellStyler.GlowUtil:PlayAnts(btn)
        end
        if addBtn then addBtn:Enable() end
    end

    -- clicking empty space deselects
    container:SetScript("OnMouseDown", function() Deselect() end)

    -- ── Static header UI ───────────────────────────────────────────────
    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -16)
    title:SetText("|cFFFFD700Add Spell|r")

    local subtitle = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Showing class and current spec spells.")
    subtitle:SetTextColor(0.7, 0.7, 0.7)

    -- Search / spell-ID input
    local PREVIEW_SIZE = 30
    local editBox = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
    editBox:SetSize(160, 22)
    editBox:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -14)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(100)

    -- Lookup preview icon (right of editBox, hidden until a match is found)
    local previewBtn = CreateFrame("Button", nil, container)
    previewBtn:SetSize(PREVIEW_SIZE, PREVIEW_SIZE)
    previewBtn:SetPoint("LEFT", editBox, "RIGHT", 8, 0)
    previewBtn:EnableMouse(true)
    previewBtn:RegisterForClicks("LeftButtonUp")
    previewBtn:Hide()

    local previewTex = previewBtn:CreateTexture(nil, "ARTWORK")
    previewTex:SetAllPoints()
    previewTex:SetTexCoord(0, 1, 0, 1)
    local previewHL = previewBtn:CreateTexture(nil, "HIGHLIGHT")
    previewHL:SetAllPoints()
    previewHL:SetColorTexture(1, 1, 1, 0.25)

    local previewSpell = nil  -- current spell shown in previewBtn

    previewBtn:SetScript("OnEnter", function(self)
        if previewSpell then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(previewSpell.spellID)
            GameTooltip:Show()
        end
    end)
    previewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    previewBtn:SetScript("OnClick", function(self)
        if previewSpell then SelectSpell(previewSpell, self) end
    end)

    -- Add button (disabled until a spell is selected)
    addBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 22)
    addBtn:SetPoint("LEFT", previewBtn, "RIGHT", 8, (PREVIEW_SIZE - 22) / 2)
    addBtn:SetText("Add")
    addBtn:Disable()
    addBtn:SetScript("OnClick", function()
        if not selectedSpell then return end
        local FTM   = SpellStyler.FrameTrackerManager
        local State = SpellStyler.State

        -- 1. Persist to DB
        local trackerConfig = State:AddTrackerValue({
            baseSpellID             = C_Spell.GetBaseSpell(selectedSpell.spellID),
			overrideSpellID			= C_Spell.GetOverrideSpell(selectedSpell.spellID),
            trackerType		        = "spells",
            name            		= selectedSpell.name,
            defaultIconTexturePath  = selectedSpell.iconID,
        })
        if not trackerConfig then return end

        -- 2. Create the live tracker frame
        FTM:CreateTrackerFrame(selectedSpell.spellID, trackerConfig, "spells")

        -- 3. Remove from the grid so it can't be added twice
        local addedID = selectedSpell.spellID
        for i = #gridButtons, 1, -1 do
            if gridButtons[i].spell.spellID == addedID then
                gridButtons[i].btn:Hide()
                table.remove(gridButtons, i)
            end
        end
        FilterAndLayoutSafe(lastFilter, gridSF:GetWidth())

        -- 4. Clear selection
        Deselect()

        -- 5. Refresh the icon list in the settings panel so the new spell appears
        if SpellStyler.settingsContentFrame then
            SpellStyler.IconSettingsRenderer:RenderIconControlView(SpellStyler.settingsContentFrame)
            if FTM.EnableDraggingForAllFrames then
                FTM:EnableDraggingForAllFrames()
            end
        end
    end)

    -- ESC: clear search text first, then deselect on second press
    editBox:SetScript("OnEscapePressed", function(self)
        if self:GetText() ~= "" then
            self:SetText("")
        else
            Deselect()
        end
        self:ClearFocus()
    end)

    -- ── Separator ──────────────────────────────────────────────────────
    local sep = container:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", editBox, "BOTTOMLEFT", -2, -10)
    sep:SetPoint("RIGHT",   container, "RIGHT", -12, 0)

    -- ── Grid scroll frame ──────────────────────────────────────────────
    local ICONS_PER_ROW_GRID = 6
    local GRID_GAP = 5
    -- Extra space so the ScrollFrame clip boundary doesn't cut the glow ring
    local GLOW_PAD = 16

    gridSF = CreateFrame("ScrollFrame", nil, container)
    -- Extend left and up by GLOW_PAD; icons are offset to compensate below
    gridSF:SetPoint("TOPLEFT",  sep, "BOTTOMLEFT",  -GLOW_PAD,  -(8 + GLOW_PAD))
    gridSF:SetPoint("TOPRIGHT", sep, "BOTTOMRIGHT",  4,          -(8 + GLOW_PAD))
    gridSF:SetPoint("BOTTOM",   container, "BOTTOM",  0,           8)

    local gridChild = CreateFrame("Frame", nil, gridSF)
    gridSF:SetScrollChild(gridChild)

    -- ── Build buttons for every spell ─────────────────────────────────
    local spells = AddSpells:GetCurrentSpecSpells()
    -- Each entry: { btn = Frame, spell = spellEntry }
    gridButtons = {}

    local State = SpellStyler.State
    for _, spell in ipairs(spells) do
        -- Skip spells that are already tracked in any tracker type
        local alreadyTracked = State:CheckIsAlreadyTracker(spell.spellID, "buffs")
            or State:CheckIsAlreadyTracker(spell.spellID, "essential")
            or State:CheckIsAlreadyTracker(spell.spellID, "utility")
            or State:CheckIsAlreadyTracker(spell.spellID, "spells")
        if not alreadyTracked then
        local capturedSpell = spell
        local btn = CreateFrame("Button", nil, gridChild)
        btn:EnableMouse(true)
        btn:RegisterForClicks("LeftButtonUp")

        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture(spell.iconID)
        tex:SetTexCoord(0, 1, 0, 1)

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.25)

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(capturedSpell.spellID)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        btn:SetScript("OnClick", function(self)
            SelectSpell(capturedSpell, self)
        end)

        table.insert(gridButtons, { btn = btn, spell = capturedSpell })
        end  -- if not alreadyTracked
    end  -- for _, spell

    -- ── Layout / search filter ─────────────────────────────────────────
    local currentIconSize = 36
    -- (lastFilter and FilterAndLayoutSafe are forward-declared above)

    FilterAndLayoutSafe = function(filterText, availableWidth)
        filterText     = filterText or ""
        availableWidth = availableWidth or gridSF:GetWidth()
        lastFilter     = filterText

        -- availableWidth is the full SF width (includes GLOW_PAD on the left);
        -- subtract GLOW_PAD so icon sizing matches the original visual width.
        local iconWidth = availableWidth - GLOW_PAD
        local lower = filterText:lower()
        local col, row = 0, 0
        local iconSize = math.floor(
            (iconWidth - (ICONS_PER_ROW_GRID - 1) * GRID_GAP) / ICONS_PER_ROW_GRID
        )
        if iconSize < 1 then return end
        currentIconSize = iconSize
        gridChild:SetWidth(availableWidth)

        local matchCount = 0
        for _, entry in ipairs(gridButtons) do
            local btn = entry.btn
            local matches = (filterText == "")
                or entry.spell.name:lower():find(lower, 1, true)
            if matches then
                btn:SetSize(iconSize, iconSize)
                btn:ClearAllPoints()
                -- Offset by GLOW_PAD so icons align visually with the separator
                btn:SetPoint("TOPLEFT", gridChild, "TOPLEFT",
                    GLOW_PAD + col * (iconSize + GRID_GAP),
                    -(GLOW_PAD + row * (iconSize + GRID_GAP))
                )
                btn:Show()
                col = col + 1
                if col >= ICONS_PER_ROW_GRID then col = 0; row = row + 1 end
                matchCount = matchCount + 1
            else
                btn:Hide()
            end
        end

        local totalRows = math.ceil(matchCount / ICONS_PER_ROW_GRID)
        gridChild:SetHeight(math.max(GLOW_PAD + totalRows * (iconSize + GRID_GAP), 1))
    end

    -- ── Lookup icon update (direct spell-ID or name lookup) ────────────
    local function UpdateLookupIcon(text)
        if not text or text == "" then
            previewBtn:Hide()
            previewSpell = nil
            -- stop glow if previewBtn was selected
            if selectedBtn == previewBtn then Deselect() end
            return
        end
        local sid = tonumber(text)
        local si  = sid and C_Spell.GetSpellInfo(sid)
        if not si then
            -- try name lookup
            si = C_Spell.GetSpellInfo(text)
            if si then sid = si.spellID end
        end
        if si and sid then
            previewSpell = { spellID = sid, name = si.name, iconID = si.iconID }
            previewTex:SetTexture(si.iconID)
            previewBtn:Show()
            -- If the previously glow-selected btn was this preview icon,
            -- re-apply glow since SetupAnts was called on it before Show
            if selectedBtn == previewBtn then
                SpellStyler.GlowUtil:SetupAnts(previewBtn, { r = 1, g = 0.82, b = 0 })
                SpellStyler.GlowUtil:PlayAnts(previewBtn)
            end
        else
            previewSpell = nil
            previewBtn:Hide()
            if selectedBtn == previewBtn then Deselect() end
        end
    end

    -- ── Wire editBox ───────────────────────────────────────────────────
    editBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        UpdateLookupIcon(text)
        FilterAndLayoutSafe(text, gridSF:GetWidth())
    end)

    -- ── Scroll + resize ────────────────────────────────────────────────
    gridSF:SetScript("OnMouseWheel", function(self, delta)
        local cur  = self:GetVerticalScroll()
        local max  = self:GetVerticalScrollRange()
        local step = (currentIconSize + GRID_GAP) * 2
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * step)))
    end)

    gridSF:SetScript("OnSizeChanged", function(self, width)
        FilterAndLayoutSafe(lastFilter, width)
    end)

    -- Initial layout
    local initWidth = gridSF:GetWidth()
    if initWidth and initWidth > 0 then
        FilterAndLayoutSafe("", initWidth)
    end
end
