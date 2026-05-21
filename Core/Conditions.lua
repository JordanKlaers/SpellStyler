-- Conditions.lua
-- Renders the Conditions settings view inside the settings menu

local ADDON_NAME, SpellStyler = ...
SpellStyler.ConditionalCreator = SpellStyler.ConditionalCreator or {}
local ConditionalCreator = SpellStyler.ConditionalCreator

-- ─── Asset paths ────────────────────────────────────────────────────────────
local PLUS_ICON_PATH     = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\PlusIcon.tga"
local AND_ICON_PATH      = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\and.tga"
local OR_ICON_PATH       = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\or.tga"
local PAREN_TEXTURE_PATH = "Interface\\AddOns\\SpellStyler\\Media\\Textures\\parentheses.tga"

-- ─── Layout constants ───────────────────────────────────────────────────────
local ENTRY_SPACING       = 4
local OPERATOR_ROW_H      = 22
local OPERATOR_BUTTON_W   = 45
local OPERATOR_BUTTON_H   = 15
local PAREN_BUTTON_W      = 14
local PAREN_BUTTON_H      = 14
local PAREN_SLOT_W        = PAREN_BUTTON_W + 2
local ROW_HEIGHT          = 20
local PADDING_VERTICAL    = 6

-- ─── Colours ────────────────────────────────────────────────────────────────
local COLOR_AND_ACTIVE     = { 0, 222/255, 0 }
local COLOR_OR_ACTIVE      = { 0, 183/255, 1.0 }
local COLOR_PAREN_INACTIVE = { 0.45, 0.45, 0.45 }
local PAREN_COLORS = {
    { 1.00, 0.20, 0.20 },  -- red
    { 1.00, 0.85, 0.00 },  -- yellow
    { 0.20, 1.00, 0.20 },  -- green
    { 0.20, 0.55, 1.00 },  -- blue
    { 0.75, 0.20, 1.00 },  -- purple
}

-- ─── Misc constants ──────────────────────────────────────────────────────────
local CONDITION_TYPES = { "ComboPoints", "IsSpellUsable", "Charges", "buff" }
local COMPARISON_OPTIONS = {
    { label = "less than",             value = "<"  },
    { label = "less than or equal to", value = "<=" },
    { label = "greater than",          value = ">"  },
    { label = "greater than or equal", value = ">=" },
    { label = "equal to",              value = "==" },
    { label = "not equal to",          value = "~=" },
}
local CHARGE_COMPARISON_OPTIONS = {
    { label = "less than",             value = "<"  },
    { label = "greater than",          value = ">"  },
}
local OPERATOR_TYPE = { AND = "and", OR = "or" }

-- ─── DB helpers ──────────────────────────────────────────────────────────────
--
-- Canonical storage: a single flat "entries" list that interleaves conditions
-- and operators in evaluation order.
--
--   condition entry:
--     { type="condition", conditionType="ComboPoints"|...,
--       openParens=N,   -- ( before this condition
--       closeParens=N,  -- ) after this condition (used on last condition for trailing parens)
--       <type-specific data fields> }
--
--   operator entry:
--     { type="operator",
--       closeParens=N,    -- ) after the preceding condition
--       operand="and"|"or",
--       openParens=N }    -- ( before the following condition
--
-- Example — ((A and B) or C):
--   { type="condition", conditionType=..., openParens=2, closeParens=0 }
--   { type="operator",  closeParens=1, operand="and", openParens=1 }
--   { type="condition", conditionType=..., openParens=0, closeParens=0 }
--   { type="operator",  closeParens=0, operand="or",  openParens=0 }
--   { type="condition", conditionType=..., openParens=0, closeParens=1 }
--
-- Paren COLORS are computed at render time (never stored in the DB).
-- AND/OR buttons shown whenever N >= 2; paren buttons only when N >= 3.
--

-- Returns the flat entries list, creating it and migrating old formats if needed.
function ConditionalCreator:GetEntries(conditionalName)
    if not conditionalName then return nil end
    SpellStyler_DB = SpellStyler_DB or {}
    SpellStyler_DB.conditionals = SpellStyler_DB.conditionals or {}
    local cd = SpellStyler_DB.conditionals[conditionalName]
    if not cd then
        cd = { entries = {} }
        SpellStyler_DB.conditionals[conditionalName] = cd
    end

    -- Phase 1: migrate from oldest "entryType" format → intermediate conditions[] format.
    -- Only applies when entries use the old "entryType" key (new format uses "type").
    if cd.entries and not cd.conditions
    and cd.entries[1] and cd.entries[1].entryType ~= nil then
        local legacy = {}
        for _, e in ipairs(cd.entries) do
            if e.entryType == "condition" then table.insert(legacy, e) end
        end
        cd.conditions = legacy
        cd.entries = nil
    end

    -- Phase 2: migrate from conditions[] + operatorRows[] → new flat entries format.
    if cd.conditions then
        local newEntries = {}
        local conds = cd.conditions
        local rows  = cd.operatorRows or {}
        local N = #conds
        local leadingOpen   = N >= 3 and #(rows[1]     and rows[1].leftParens   or {}) or 0
        local trailingClose = N >= 3 and #(rows[N + 1] and rows[N + 1].rightParens or {}) or 0
        if N >= 3 then
            table.insert(newEntries, { type="boundary", openParens=leadingOpen })
        end
        for i = 1, N do
            local src = conds[i]
            local condEntry = { type="condition", conditionType=src.type }
            for k, v in pairs(src) do
                if k ~= "type" then condEntry[k] = v end
            end
            table.insert(newEntries, condEntry)
            if i < N then
                local row = rows[i + 1] or {}
                table.insert(newEntries, {
                    type        = "operator",
                    closeParens = #(row.rightParens or {}),
                    operand     = row.operand or OPERATOR_TYPE.AND,
                    openParens  = #(row.leftParens  or {}),
                })
            end
        end
        if N >= 3 then
            table.insert(newEntries, { type="boundary", closeParens=trailingClose })
        end
        cd.entries      = newEntries
        cd.conditions   = nil
        cd.operatorRows = nil
    end

    -- Phase 3: migrate intermediate flat format that stored openParens/closeParens
    -- directly on condition entries → move them to boundary entries.
    cd.entries = cd.entries or {}
    do
        local hasOldCondParens = false
        for _, e in ipairs(cd.entries) do
            if e.type == "condition" and (e.openParens ~= nil or e.closeParens ~= nil) then
                hasOldCondParens = true; break
            end
        end
        if hasOldCondParens then
            local entries = cd.entries
            local N = 0
            for _, e in ipairs(entries) do if e.type == "condition" then N = N + 1 end end
            local firstCond, lastCond
            for _, e in ipairs(entries) do
                if e.type == "condition" then
                    if not firstCond then firstCond = e end
                    lastCond = e
                end
            end
            local leadingOpen   = N >= 3 and (firstCond and firstCond.openParens  or 0) or 0
            local trailingClose = N >= 3 and (lastCond  and lastCond.closeParens  or 0) or 0
            for _, e in ipairs(entries) do
                if e.type == "condition" then
                    e.openParens  = nil
                    e.closeParens = nil
                end
            end
            if N >= 3 then
                -- Only insert boundaries if they don't already exist.
                if entries[1] and entries[1].type ~= "boundary" then
                    table.insert(entries, 1, { type="boundary", openParens=leadingOpen })
                end
                if entries[#entries] and entries[#entries].type ~= "boundary" then
                    table.insert(entries, { type="boundary", closeParens=trailingClose })
                end
            end
        end
    end

    return cd.entries
end

-- Returns a new array containing only the condition entries (as live references).
function ConditionalCreator:GetConditions(conditionalName)
    local entries = self:GetEntries(conditionalName)
    if not entries then return nil end
    local conds = {}
    for _, e in ipairs(entries) do
        if e.type == "condition" then table.insert(conds, e) end
    end
    return conds
end

-- Returns the number of condition entries.
function ConditionalCreator:GetConditionCount(conditionalName)
    local entries = self:GetEntries(conditionalName)
    if not entries then return 0 end
    local n = 0
    for _, e in ipairs(entries) do if e.type == "condition" then n = n + 1 end end
    return n
end

-- ─── Paren helpers ───────────────────────────────────────────────────────────
--
-- Colors are computed purely at render time from the flat entries list.
-- The DB stores only the INTEGER COUNTS (openParens / closeParens).
-- No color data is ever persisted.
--
-- Builds a color map by running innermost-first pair matching over the flat
-- paren sequence derived from entries.  Matched pairs share a color index;
-- unmatched parens each receive their own sequential color (no paren is gray).
-- Returns colorMap[entryIdx][side][parenPos] → PAREN_COLORS index (1-based).
-- `side` is "open" or "close"; parenPos is the 1-based position within
-- that side's count on the given entry.
function ConditionalCreator:ComputeParenColors(entries)
    if not entries then return {} end
    local flat = {}
    for ei, entry in ipairs(entries) do
        if entry.type == "operator" or entry.type == "boundary" then
            for p = 1, (entry.closeParens or 0) do
                table.insert(flat, { ei=ei, side="close", pos=p, color=false, isMatched=false })
            end
            for p = 1, (entry.openParens  or 0) do
                table.insert(flat, { ei=ei, side="open",  pos=p, color=false, isMatched=false })
            end
        end
    end
    -- Innermost-first matching.
    local colorIdx = 1
    local changed  = true
    while changed do
        changed = false
        local lastOpenPos = nil
        for i = 1, #flat do
            if not flat[i].isMatched then
                if flat[i].side == "open" then
                    lastOpenPos = i
                elseif flat[i].side == "close" and lastOpenPos then
                    flat[lastOpenPos].isMatched = true; flat[lastOpenPos].color = colorIdx
                    flat[i].isMatched           = true; flat[i].color           = colorIdx
                    colorIdx = (colorIdx % #PAREN_COLORS) + 1
                    changed = true; break
                end
            end
        end
    end
    -- Unmatched parens each get their own distinct color (no paren is left gray).
    for _, f in ipairs(flat) do
        if not f.isMatched then
            f.color  = colorIdx
            colorIdx = (colorIdx % #PAREN_COLORS) + 1
        end
    end
    -- Build lookup table.
    local colorMap = {}
    for _, f in ipairs(flat) do
        colorMap[f.ei]                = colorMap[f.ei] or {}
        colorMap[f.ei][f.side]        = colorMap[f.ei][f.side] or {}
        colorMap[f.ei][f.side][f.pos] = f.color
    end
    return colorMap
end

-- ─── Condition mutation ──────────────────────────────────────────────────────

function ConditionalCreator:AddCondition(conditionalName)
    local entries = self:GetEntries(conditionalName)
    if not entries then return nil end
    local N = self:GetConditionCount(conditionalName)
    if N == 0 then
        -- [cond1]
        table.insert(entries, { type="condition", conditionType=nil })
    elseif N == 1 then
        -- [cond1] → [cond1, op, cond2]  (no boundaries yet)
        table.insert(entries, { type="operator", closeParens=0, operand=OPERATOR_TYPE.AND, openParens=0 })
        table.insert(entries, { type="condition", conditionType=nil })
    elseif N == 2 then
        -- [cond1, op, cond2] → [bnd_open, cond1, op, cond2, op, cond3, bnd_close]
        table.insert(entries, 1, { type="boundary", openParens=0 })
        table.insert(entries, { type="operator", closeParens=0, operand=OPERATOR_TYPE.AND, openParens=0 })
        table.insert(entries, { type="condition", conditionType=nil })
        table.insert(entries, { type="boundary", closeParens=0 })
    else
        -- N >= 3; boundary entries sit at [1] and [#entries].  Insert before trailing boundary.
        local insertPos = #entries
        table.insert(entries, insertPos, { type="condition", conditionType=nil })
        table.insert(entries, insertPos, { type="operator", closeParens=0, operand=OPERATOR_TYPE.AND, openParens=0 })
    end
    return entries
end

function ConditionalCreator:RemoveConditionAtIndex(conditionalName, condIdx)
    local entries = self:GetEntries(conditionalName)
    if not entries then return nil end
    -- Locate the flat index of the condIdx-th condition.
    local condCount = 0
    local flatIdx   = nil
    for i, e in ipairs(entries) do
        if e.type == "condition" then
            condCount = condCount + 1
            if condCount == condIdx then flatIdx = i; break end
        end
    end
    if not flatIdx then return nil end
    local N = self:GetConditionCount(conditionalName)

    if N == 1 then
        -- Only entry; just clear.
        while #entries > 0 do table.remove(entries) end

    elseif N == 2 then
        -- entries = [cond1, op, cond2]; no boundary entries.
        if condIdx == 1 then
            table.remove(entries, flatIdx + 1) -- op
            table.remove(entries, flatIdx)     -- cond1
        else
            table.remove(entries, flatIdx)     -- cond2
            table.remove(entries, flatIdx - 1) -- op
        end

    elseif N == 3 then
        -- N→2: boundaries must be removed too.  Rebuild from surviving two conditions.
        local conds, ops = {}, {}
        for _, e in ipairs(entries) do
            if     e.type == "condition" then table.insert(conds, e)
            elseif e.type == "operator"  then table.insert(ops,   e) end
        end
        table.remove(conds, condIdx)
        -- Pick operand from whichever operator was adjacent to the removed condition.
        local keepOpIdx = (condIdx == 1) and 2 or 1
        local mergedOp = {
            type="operator", closeParens=0,
            operand=(ops[keepOpIdx] and ops[keepOpIdx].operand or OPERATOR_TYPE.AND),
            openParens=0,
        }
        while #entries > 0 do table.remove(entries) end
        table.insert(entries, conds[1])
        table.insert(entries, mergedOp)
        table.insert(entries, conds[2])

    else
        -- N >= 4; boundary entries stay.
        if condIdx == 1 then
            -- boundary_open stays; remove cond1 + op12.
            table.remove(entries, flatIdx + 1) -- op12
            table.remove(entries, flatIdx)     -- cond1
        elseif condIdx == N then
            -- boundary_close stays; remove cond_N + preceding op.
            table.remove(entries, flatIdx)     -- cond_N
            table.remove(entries, flatIdx - 1) -- op
        else
            -- Middle: merge the two adjacent operators, drop the condition.
            local opBefore = entries[flatIdx - 1]
            local opAfter  = entries[flatIdx + 1]
            local merged = {
                type        = "operator",
                closeParens = (opBefore.closeParens or 0) + (opAfter.closeParens or 0),
                operand     = opBefore.operand or opAfter.operand or OPERATOR_TYPE.AND,
                openParens  = (opBefore.openParens  or 0) + (opAfter.openParens  or 0),
            }
            table.remove(entries, flatIdx + 1)
            table.remove(entries, flatIdx)
            entries[flatIdx - 1] = merged
        end
    end

    return entries
end


-- ─── Drag-and-drop ──────────────────────────────────────────────────────────
--
-- Only condition entries are dragged; operator rows keep their indexed
-- positions between display slots and their data does not move.
--
-- activeDrag holds live state while a drag is in progress:
--   state                - render state table
--   sourceConditionIndex - 1-based index in conditions[] of the dragged entry
--   dropSlot             - target display slot (1..N), recomputed each frame
--   cloneFrame           - floating clone following the cursor
--   placeholderFrame     - ghost at the speculative landing slot
--   offsetX / offsetY    - cursor offset from frame top-left at grab time
--   lastCursorY          - UI-space Y last frame (for direction detection)
--   dragDirection        - "up" | "down" | "neutral"
--
local activeDrag = nil

local dragOverlay = CreateFrame("Frame", "SpellStylerDragOverlay", UIParent)
dragOverlay:SetAllPoints(UIParent)
dragOverlay:SetFrameStrata("FULLSCREEN_DIALOG")
dragOverlay:EnableMouse(true)
dragOverlay:Hide()

local function ComputeDropSlot(state, sourceConditionIndex)
    local N = ConditionalCreator:GetConditionCount(state.selectedConditional)
    if N == 0 then return 1 end
    local _, cursorY = GetCursorPosition()
    local uiY = cursorY / UIParent:GetEffectiveScale()
    local dir = activeDrag and activeDrag.dragDirection or "neutral"
    local slot = 1
    for i = 1, N do
        if i ~= sourceConditionIndex then
            local frame = state.conditionFrames[i]
            if frame then
                local top = frame:GetTop(); local bot = frame:GetBottom()
                if top and bot then
                    local threshold
                    if     dir == "up"   then threshold = bot
                    elseif dir == "down" then threshold = top
                    else                      threshold = (top + bot) * 0.5
                    end
                    if threshold > uiY then slot = slot + 1 end
                end
            end
        end
    end
    return slot
end

local function RepositionForDrag(state)
    if not activeDrag then return end
    local sourceIdx   = activeDrag.sourceConditionIndex
    local dropSlot    = activeDrag.dropSlot
    local placeholder = activeDrag.placeholderFrame
    local conds = ConditionalCreator:GetConditions(state.selectedConditional)
    if not conds then return end
    local N = #conds
    local showOps = (N >= 2)
    local reduced = {}
    for i = 1, N do if i ~= sourceIdx then table.insert(reduced, i) end end
    local final = {}
    for i, idx in ipairs(reduced) do
        if i == dropSlot then table.insert(final, false) end
        table.insert(final, idx)
    end
    if dropSlot > #reduced then table.insert(final, false) end
    local offset = 0
    local function placeFrame(frame, h)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", state.editFrame, "TOPLEFT", 0, -offset)
        frame:SetPoint("RIGHT",   state.editFrame, "RIGHT",   0,  0)
        frame:Show()
        offset = offset + h + ENTRY_SPACING
    end
    if showOps and state.operatorRowFrames[1] then
        local f = state.operatorRowFrames[1]; placeFrame(f, f:GetHeight())
    end
    for displayPos, condIdx in ipairs(final) do
        local frame = (condIdx ~= false) and state.conditionFrames[condIdx] or placeholder
        if frame then placeFrame(frame, frame:GetHeight()) end
        if showOps then
            local opFrame = state.operatorRowFrames[displayPos + 1]
            if opFrame then placeFrame(opFrame, opFrame:GetHeight()) end
        end
    end
    state.plusBtn:ClearAllPoints()
    state.plusBtn:SetPoint("TOPLEFT", state.editFrame, "TOPLEFT", 0, -offset)
    state.editFrame:SetHeight(math.max(offset + 28, 28))
end

local function CreateDragClone(entryFrame, condition)
    local clone = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    clone:SetFrameStrata("TOOLTIP")
    clone:SetSize(entryFrame:GetWidth(), entryFrame:GetHeight())
    clone:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    clone:SetBackdropColor(0.15, 0.15, 0.35, 0.92)
    clone:SetBackdropBorderColor(0.6, 0.6, 1.0, 1.0)
    clone:SetAlpha(0.88)
    local label = clone:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER", clone, "CENTER", 0, 0)
    label:SetText((condition.conditionType and condition.conditionType ~= "") and condition.conditionType or "|cFF888888Condition|r")
    local strip = clone:CreateTexture(nil, "OVERLAY")
    strip:SetPoint("TOPLEFT",    clone, "TOPLEFT",    4, -4)
    strip:SetPoint("BOTTOMLEFT", clone, "BOTTOMLEFT", 4,  4)
    strip:SetWidth(4)
    strip:SetColorTexture(0.5, 0.5, 1.0, 0.7)
    return clone
end

local function CreateDragPlaceholder(entryFrame)
    local ph = CreateFrame("Frame", nil, entryFrame:GetParent(), "BackdropTemplate")
    ph:SetSize(entryFrame:GetWidth(), entryFrame:GetHeight())
    ph:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    ph:SetBackdropColor(0.04, 0.04, 0.18, 0.55)
    ph:SetBackdropBorderColor(0.35, 0.35, 0.6, 0.6)
    return ph
end

function ConditionalCreator:StartDrag(state, sourceConditionIndex, entryFrame, condition)
    if activeDrag then return end
    if self:GetConditionCount(state.selectedConditional) < sourceConditionIndex then return end
    local clone       = CreateDragClone(entryFrame, condition)
    local placeholder = CreateDragPlaceholder(entryFrame)
    local left  = entryFrame:GetLeft()  or 0
    local top   = entryFrame:GetTop()   or 0
    clone:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    local cx, cy  = GetCursorPosition()
    local uiScale = UIParent:GetEffectiveScale()
    activeDrag = {
        state                = state,
        sourceConditionIndex = sourceConditionIndex,
        dropSlot             = sourceConditionIndex,
        cloneFrame           = clone,
        placeholderFrame     = placeholder,
        offsetX              = (cx / uiScale) - left,
        offsetY              = (cy / uiScale) - top,
        lastCursorY          = cy / uiScale,
        dragDirection        = "neutral",
    }
    entryFrame:SetAlpha(0)
    RepositionForDrag(state)
    dragOverlay:Show()
    dragOverlay:Raise()
end

function ConditionalCreator:FinalizeDrag(commit)
    if not activeDrag then return end
    local state     = activeDrag.state
    local sourceIdx = activeDrag.sourceConditionIndex
    local dropSlot  = activeDrag.dropSlot
    local clone     = activeDrag.cloneFrame
    local ph        = activeDrag.placeholderFrame
    dragOverlay:Hide(); clone:Hide(); ph:Hide()
    activeDrag = nil
    if commit then
        local entries = self:GetEntries(state.selectedConditional)
        if entries and sourceIdx ~= dropSlot then
            -- Strip boundary entries temporarily so we only reorder conds+middle ops.
            local leading = (entries[1] and entries[1].type == "boundary") and table.remove(entries, 1) or nil
            local trailing = (#entries > 0 and entries[#entries].type == "boundary") and table.remove(entries, #entries) or nil
            -- Split into conditions and operators, reorder conditions, zip back.
            local conds = {}
            local ops   = {}
            for _, e in ipairs(entries) do
                if     e.type == "condition" then table.insert(conds, e)
                elseif e.type == "operator"  then table.insert(ops,   e) end
            end
            local moved = table.remove(conds, sourceIdx)
            table.insert(conds, dropSlot, moved)
            local idx = 1
            for i = 1, #conds do
                entries[idx] = conds[i]; idx = idx + 1
                if ops[i] then entries[idx] = ops[i]; idx = idx + 1 end
            end
            while #entries > idx - 1 do table.remove(entries) end
            -- Re-attach boundary entries.
            if leading  then table.insert(entries, 1, leading) end
            if trailing then table.insert(entries, trailing)   end
        end
    end
    self:RenderEntries(state)
end

dragOverlay:SetScript("OnUpdate", function()
    if not activeDrag then return end
    local state   = activeDrag.state
    local clone   = activeDrag.cloneFrame
    local cx, cy  = GetCursorPosition()
    local uiScale = UIParent:GetEffectiveScale()
    clone:ClearAllPoints()
    clone:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (cx / uiScale) - activeDrag.offsetX, (cy / uiScale) - activeDrag.offsetY)
    local curUIY = cy / uiScale
    local delta  = curUIY - activeDrag.lastCursorY
    if     delta >  1 then activeDrag.dragDirection = "up"
    elseif delta < -1 then activeDrag.dragDirection = "down"
    end
    activeDrag.lastCursorY = curUIY
    local N = ConditionalCreator:GetConditionCount(state.selectedConditional)
    if N == 0 then return end
    local raw   = ComputeDropSlot(state, activeDrag.sourceConditionIndex)
    local valid = math.max(1, math.min(N, raw))
    if valid ~= activeDrag.dropSlot then
        activeDrag.dropSlot = valid
        RepositionForDrag(state)
    end
end)

dragOverlay:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then ConditionalCreator:FinalizeDrag(true) end
end)

-- ─── Conditional type renderers ──────────────────────────────────────────────
ConditionalCreator.conditionalTypeRenderers = {
    ComboPoints = function(container, condition, vertPadding, onHeightResolved)
        condition.ComboPoints = condition.ComboPoints or {}
        local data = condition.ComboPoints
        local actualLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        actualLabel:SetPoint("TOPLEFT", container, "TOPLEFT", 0, vertPadding)
        actualLabel:SetText("Actual")
        local compDropdown = CreateFrame("Frame", nil, container, "UIDropDownMenuTemplate")
        compDropdown:SetPoint("LEFT", actualLabel, "RIGHT", -12, -2)
        UIDropDownMenu_SetWidth(compDropdown, 100)
        local function RefreshComp()
            local txt = "|cFF888888operator|r"
            for _, opt in ipairs(COMPARISON_OPTIONS) do
                if opt.value == data.comparison then txt = opt.label; break end
            end
            UIDropDownMenu_SetText(compDropdown, txt)
        end
        UIDropDownMenu_Initialize(compDropdown, function(self, level)
            for _, opt in ipairs(COMPARISON_OPTIONS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = opt.label; info.value = opt.value
                info.checked = (data.comparison == opt.value)
                info.func = function(btn) data.comparison = btn.value; RefreshComp() end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        RefreshComp()
        local targetLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        targetLabel:SetPoint("LEFT", compDropdown, "RIGHT", -8, 2)
        targetLabel:SetText("Target:")
        local targetInput = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
        targetInput:SetSize(40, ROW_HEIGHT)
        targetInput:SetPoint("LEFT", targetLabel, "RIGHT", 8, 0)
        targetInput:SetAutoFocus(false); targetInput:SetMaxLetters(2); targetInput:SetNumeric(true)
        if data.targetValue ~= nil then targetInput:SetText(tostring(data.targetValue)) end
        targetInput:SetScript("OnTextChanged", function(self)
            local v = tonumber(self:GetText())
            if v then data.targetValue = math.max(0, math.min(10, v)) end
        end)
        compDropdown:Hide()
        C_Timer.After(0, function()
            if not container:IsShown() then return end
            local _, _, _, h = container:GetBoundsRect()
            compDropdown:Show()
            if h and h > 0 and onHeightResolved then
                container:SetHeight(h); onHeightResolved(h)
            end
        end)
        return 0
    end,
    IsSpellUsable = function(container, condition, vertPadding, onHeightResolved)
        condition.IsSpellUsable = condition.IsSpellUsable or {}
        local data = condition.IsSpellUsable
        
        -- Default comparison to "=="
        if not data.comparison then
            data.comparison = "=="
        end
        
        -- Radio button options
        local options = {
            { value = "able", label = "Able to cast", tooltip = nil },
            { value = "unable", label = "Unable to cast", tooltip = "This could be true due to a variety of reasons, such as on cooldown, out of rage, no power ect." },
            { value = "cooldown", label = "Spell On Cooldown", tooltip = "Slightly different than 'Unable to cast'. This is when the spell is activly on cooldown" },
            { value = "insufficientPower", label = "Unable to cast due to insufficient power (mana, rage, energy, etc.)", tooltip = nil },
        }
        
        local yOffset = vertPadding
        local radioButtons = {}
        
        for i, opt in ipairs(options) do
            -- Create radio button frame
            local radioFrame = CreateFrame("Frame", nil, container)
            radioFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, yOffset)
            radioFrame:SetSize(300, 20)
            
            -- Create check button (radio button)
            local radio = CreateFrame("CheckButton", nil, radioFrame, "UIRadioButtonTemplate")
            radio:SetPoint("LEFT", radioFrame, "LEFT", 0, 0)
            radio:SetChecked(data.state == opt.value)
            
            -- Create label
            local label = radioFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            label:SetPoint("LEFT", radio, "RIGHT", 5, 0)
            label:SetText(opt.label)
            label:SetJustifyH("LEFT")
            label:SetWidth(280)
            
            -- Set up click handler
            radio:SetScript("OnClick", function(self)
                data.state = opt.value
                -- Update all radio buttons
                for _, rb in ipairs(radioButtons) do
                    rb:SetChecked(false)
                end
                self:SetChecked(true)
            end)
            
            -- Add tooltip if provided
            if opt.tooltip then
                radioFrame:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
                    GameTooltip:SetText(opt.tooltip, 1, 1, 1, 1, true)
                    GameTooltip:Show()
                end)
                radioFrame:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
            end
            
            table.insert(radioButtons, radio)
            yOffset = yOffset - 25
        end
        
        -- Calculate final height
        local totalHeight = math.abs(yOffset - vertPadding) + 5
        
        C_Timer.After(0, function()
            if not container:IsShown() then return end
            container:SetHeight(totalHeight)
            if onHeightResolved then
                onHeightResolved(totalHeight)
            end
        end)
        
        return totalHeight
    end,
    Charges = function(container, condition, vertPadding, onHeightResolved)
        condition.Charges = condition.Charges or {}
        local data = condition.Charges
        
        local chargesLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        chargesLabel:SetPoint("TOPLEFT", container, "TOPLEFT", 0, vertPadding)
        chargesLabel:SetText("When charges are")
        
        local compDropdown = CreateFrame("Frame", nil, container, "UIDropDownMenuTemplate")
        compDropdown:SetPoint("LEFT", chargesLabel, "RIGHT", -12, -2)
        UIDropDownMenu_SetWidth(compDropdown, 100)
        
        local function RefreshComp()
            local txt = "|cFF888888operator|r"
            for _, opt in ipairs(CHARGE_COMPARISON_OPTIONS) do
                if opt.value == data.comparison then txt = opt.label; break end
            end
            UIDropDownMenu_SetText(compDropdown, txt)
        end
        
        UIDropDownMenu_Initialize(compDropdown, function(self, level)
            for _, opt in ipairs(CHARGE_COMPARISON_OPTIONS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = opt.label; info.value = opt.value
                info.checked = (data.comparison == opt.value)
                info.func = function(btn)
                    data.comparison = btn.value
                    RefreshComp()
                    -- Re-evaluate all conditionals
                    if SpellStyler.ConditionalEngine then
                        SpellStyler.ConditionalEngine:EvaluateAll()
                    end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        RefreshComp()
        
        local targetInput = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
        targetInput:SetSize(40, ROW_HEIGHT)
        targetInput:SetPoint("LEFT", compDropdown, "RIGHT", -8, 2)
        targetInput:SetAutoFocus(false); targetInput:SetMaxLetters(2); targetInput:SetNumeric(true)
        if data.targetValue ~= nil then targetInput:SetText(tostring(data.targetValue)) end
        targetInput:SetScript("OnTextChanged", function(self)
            local v = tonumber(self:GetText())
            if v then
                data.targetValue = math.max(0, math.min(10, v))
                -- Refresh charge bars for all trackers using this conditional
                if SpellStyler.FrameTrackerManager then
                    C_Timer.After(0.5, function()  -- Debounce to avoid excessive refreshes while typing
                        -- Re-evaluate all conditionals
                        if SpellStyler.ConditionalEngine then
                            SpellStyler.ConditionalEngine:EvaluateAll()
                        end
                    end)
                end
            end
        end)
        
        compDropdown:Hide()
        C_Timer.After(0, function()
            if not container:IsShown() then return end
            local _, _, _, h = container:GetBoundsRect()
            compDropdown:Show()
            if h and h > 0 and onHeightResolved then
                container:SetHeight(h); onHeightResolved(h)
            end
        end)
        
        return 0
    end,
    buff = function(container, condition, vertPadding, onHeightResolved)
        condition.buff = condition.buff or {}
        local data = condition.buff
        
        -- "When" label
        local whenLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        whenLabel:SetPoint("TOPLEFT", container, "TOPLEFT", 0, vertPadding)
        whenLabel:SetText("When")
        
        -- Buff selection dropdown
        local buffDropdown = CreateFrame("Frame", nil, container, "UIDropDownMenuTemplate")
        buffDropdown:SetPoint("LEFT", whenLabel, "RIGHT", -12, -2)
        UIDropDownMenu_SetWidth(buffDropdown, 150)
        
        local function RefreshBuffDropdown()
            local txt = "|cFF888888select buff|r"
            if data.buffID then
                -- Handle both single ID and table of IDs
                local firstID = (type(data.buffID) == "table") and data.buffID[1] or data.buffID
                -- Try to get the buff name
                pcall(function()
                    local buffInfo = C_Spell.GetSpellInfo(firstID)
                    if buffInfo and buffInfo.name then
                        txt = buffInfo.name
                    else
                        txt = "Buff " .. tostring(firstID)
                    end
                end)
            end
            UIDropDownMenu_SetText(buffDropdown, txt)
        end
        
        UIDropDownMenu_Initialize(buffDropdown, function(self, level)
            -- Get all tracked buffs from the database
            local State = SpellStyler.State
            if not State then return end
            
            local db = State:GetDataBase_V2()
            if not db or not db.buffs then return end
            
            -- Build a map of buff names to IDs (combining duplicates)
            local buffsByName = {}
            for buffID, trackerValue in pairs(db.buffs) do
                local buffName = "Buff " .. tostring(buffID)
                pcall(function()
                    local buffInfo = C_Spell.GetSpellInfo(buffID)
                    if buffInfo and buffInfo.name then
                        buffName = buffInfo.name
                    end
                end)
                
                if not buffsByName[buffName] then
                    buffsByName[buffName] = {}
                end
                table.insert(buffsByName[buffName], buffID)
            end
            
            -- Convert to sorted list
            local buffList = {}
            for name, ids in pairs(buffsByName) do
                -- Sort IDs within each name group for consistency
                table.sort(ids)
                -- Store as single ID if only one, or table if multiple
                local value = (#ids == 1) and ids[1] or ids
                table.insert(buffList, { name = name, value = value, ids = ids })
            end
            
            -- Sort by name
            table.sort(buffList, function(a, b) return a.name < b.name end)
            
            -- Add dropdown options
            if #buffList > 0 then
                for _, buff in ipairs(buffList) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = buff.name
                    info.value = buff.value
                    
                    -- Check if current selection matches (handle both single ID and table of IDs)
                    local isChecked = false
                    if type(data.buffID) == "table" and type(buff.value) == "table" then
                        -- Both are tables, compare contents
                        if #data.buffID == #buff.value then
                            isChecked = true
                            for i, id in ipairs(data.buffID) do
                                if id ~= buff.value[i] then
                                    isChecked = false
                                    break
                                end
                            end
                        end
                    else
                        -- Simple comparison (handles single IDs or mixed cases)
                        isChecked = (data.buffID == buff.value)
                    end
                    info.checked = isChecked
                    
                    info.func = function(btn)
                        data.buffID = btn.value
                        RefreshBuffDropdown()
                        -- Re-evaluate all conditionals
                        if SpellStyler.ConditionalEngine then
                            SpellStyler.ConditionalEngine:EvaluateAll()
                        end
                    end
                    UIDropDownMenu_AddButton(info, level)
                end
            else
                local info = UIDropDownMenu_CreateInfo()
                info.text = "|cFF888888(no buffs tracked)|r"
                info.disabled = true
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        RefreshBuffDropdown()
        
        -- "is" label (on second line)
        local isLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        isLabel:SetPoint("TOPLEFT", buffDropdown, "BOTTOMLEFT", 16, -8)
        isLabel:SetText("is")
        
        -- State dropdown (active/inactive)
        local stateDropdown = CreateFrame("Frame", nil, container, "UIDropDownMenuTemplate")
        stateDropdown:SetPoint("LEFT", isLabel, "RIGHT", -12, -2)
        UIDropDownMenu_SetWidth(stateDropdown, 100)
        
        local function RefreshStateDropdown()
            local txt = "|cFF888888state|r"
            if data.state == "active" then
                txt = "active"
            elseif data.state == "inactive" then
                txt = "inactive"
            end
            UIDropDownMenu_SetText(stateDropdown, txt)
        end
        
        UIDropDownMenu_Initialize(stateDropdown, function(self, level)
            local states = {
                { label = "active", value = "active" },
                { label = "inactive", value = "inactive" },
            }
            
            for _, state in ipairs(states) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = state.label
                info.value = state.value
                info.checked = (data.state == state.value)
                info.func = function(btn)
                    data.state = btn.value
                    RefreshStateDropdown()
                    -- Re-evaluate all conditionals
                    if SpellStyler.ConditionalEngine then
                        SpellStyler.ConditionalEngine:EvaluateAll()
                    end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        RefreshStateDropdown()
        
        -- Hide/show dropdowns to measure height
        buffDropdown:Hide()
        stateDropdown:Hide()
        C_Timer.After(0, function()
            if not container:IsShown() then return end
            local _, _, _, h = container:GetBoundsRect()
            buffDropdown:Show()
            stateDropdown:Show()
            if h and h > 0 and onHeightResolved then
                container:SetHeight(h)
                onHeightResolved(h)
            end
        end)
        
        return 0
    end
}


-- ─── Condition entry frame ───────────────────────────────────────────────────
--
-- Creates the bordered frame containing the type-dropdown and type-specific
-- content for one condition.  Height is set provisionally, then refined once
-- GetBoundsRect resolves via a C_Timer.After(0) callback.
-- Returns (frame, provisionalHeight).
--
function ConditionalCreator:CreateConditionFrame(parent, condition, conditionIndex, state)
    local entryFrame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    entryFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    entryFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)

    -- Drag handle: thin strip on left edge, tracks the full frame height.
    local dragHandle = CreateFrame("Frame", nil, entryFrame)
    dragHandle:SetPoint("TOPLEFT",    entryFrame, "TOPLEFT",    3, -3)
    dragHandle:SetPoint("BOTTOMLEFT", entryFrame, "BOTTOMLEFT", 3,  3)
    dragHandle:SetWidth(10)
    dragHandle:EnableMouse(true)
    dragHandle:SetFrameLevel(entryFrame:GetFrameLevel() + 5)
    local handleTex = dragHandle:CreateTexture(nil, "ARTWORK")
    handleTex:SetAllPoints()
    handleTex:SetColorTexture(0.4, 0.4, 0.65, 0.25)
    dragHandle:SetScript("OnEnter", function()
        handleTex:SetColorTexture(0.5, 0.5, 0.9, 0.45)
        GameTooltip:SetOwner(dragHandle, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:SetText("Drag to reorder", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    dragHandle:SetScript("OnLeave", function()
        handleTex:SetColorTexture(0.4, 0.4, 0.65, 0.25)
        GameTooltip:Hide()
    end)
    dragHandle:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            ConditionalCreator:StartDrag(state, conditionIndex, entryFrame, condition)
        end
    end)
    dragHandle:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then ConditionalCreator:FinalizeDrag(true) end
    end)

    local vertPadding      = -6
    local typeDropdown     = CreateFrame("Frame", nil, entryFrame, "UIDropDownMenuTemplate")
    typeDropdown:SetPoint("TOPLEFT", entryFrame, "TOPLEFT", 0, vertPadding)
    UIDropDownMenu_SetWidth(typeDropdown, 130)
    local dropdownHeight   = 32
    local typeContentFrame = nil

    local function RefreshTypeDropdown()
        UIDropDownMenu_SetText(typeDropdown, condition.conditionType or "|cFF888888Type|r")
    end

    local function RenderTypeContent(triggerRerender)
        if typeContentFrame then typeContentFrame:Hide(); typeContentFrame = nil end
        local contentHeight = 0
        local renderer = condition.conditionType and ConditionalCreator.conditionalTypeRenderers[condition.conditionType]
        if renderer then
            typeContentFrame = CreateFrame("Frame", nil, entryFrame)
            typeContentFrame:SetPoint("TOPLEFT", typeDropdown, "BOTTOMLEFT", 24, 0)
            typeContentFrame:SetPoint("RIGHT",   entryFrame,   "RIGHT",      -8, 0)
            -- Store conditional name on frame so block renderers can access it
            typeContentFrame.conditionalName = state and state.selectedConditional
            local capturedGen = state.renderGeneration
            local function onHeightResolved(h)
                if state.renderGeneration ~= capturedGen then return end
                typeContentFrame:SetHeight(h)
                entryFrame:SetHeight(dropdownHeight + h + (2 * -vertPadding) + 2)
                ConditionalCreator:RepositionEntries(state)
            end
            contentHeight = renderer(typeContentFrame, condition, vertPadding, onHeightResolved)
            typeContentFrame:SetHeight(contentHeight)
            typeContentFrame:Show()
        end
        local totalHeight = dropdownHeight + contentHeight + (-vertPadding) + 2
        entryFrame:SetHeight(totalHeight)
        if triggerRerender and state then ConditionalCreator:RenderEntries(state) end
        return totalHeight
    end

    UIDropDownMenu_Initialize(typeDropdown, function(self, level)
        -- Check if a Charges condition already exists
        local hasChargesCondition = false
        if state and state.selectedConditional then
            local conditions = ConditionalCreator:GetConditions(state.selectedConditional)
            if conditions then
                for _, cond in ipairs(conditions) do
                    if cond ~= condition and cond.conditionType == "Charges" then
                        hasChargesCondition = true
                        break
                    end
                end
            end
        end
        
        for _, ct in ipairs(CONDITION_TYPES) do
            local info   = UIDropDownMenu_CreateInfo()
            info.text    = ct; info.value = ct
            info.checked = (condition.conditionType == ct)
            
            -- Disable Charges if one already exists (unless this IS the Charges condition)
            if ct == "Charges" and hasChargesCondition and condition.conditionType ~= "Charges" then
                info.text = ct .. " |cFF888888(limit 1)|r"
                info.disabled = true
                info.tooltipTitle = "Cannot add Charges"
                info.tooltipText = "Only one Charges condition is allowed per conditional."
                info.tooltipOnButton = true
            else
                info.func    = function(btn)
                    condition.conditionType = btn.value; RefreshTypeDropdown(); RenderTypeContent(true)
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    local deleteBtn = CreateFrame("Button", nil, entryFrame, "UIPanelCloseButton")
    deleteBtn:SetSize(18, 18)
    deleteBtn:SetPoint("TOPRIGHT", entryFrame, "TOPRIGHT", -6, -6)
    deleteBtn:SetScript("OnClick", function()
        ConditionalCreator:RemoveConditionAtIndex(state.selectedConditional, conditionIndex)
        ConditionalCreator:RenderEntries(state)
    end)

    RefreshTypeDropdown()
    local totalHeight = RenderTypeContent(false)
    return entryFrame, totalHeight
end

-- ─── Operator row frame ──────────────────────────────────────────────────────
--
-- Builds one operator-row frame.  Signature:
--   closeCount    - number of ) buttons on the left side
--   operand       - "and"|"or"|nil  (nil = paren-only row, no AND/OR buttons)
--   openCount     - number of ( buttons on the right side
--   closeEntryIdx - index into entries[] whose .closeParens this row mutates
--   openEntryIdx  - index into entries[] whose .openParens  this row mutates
--   rowIndex      - visual row slot 1..N+1 (used to set isFirst/isLast + state key)
--   conditionCount, state, outParenButtons
--   colorMap      - from ComputeParenColors()
--
function ConditionalCreator:CreateOperatorRowFrame(editFrame, closeCount, operand, openCount, closeEntryIdx, openEntryIdx, rowIndex, conditionCount, state, outParenButtons, colorMap)
    local isFirst = (rowIndex == 1)
    local isLast  = (rowIndex == conditionCount + 1)

    local rowFrame = CreateFrame("Frame", nil, editFrame)
    rowFrame:SetHeight(OPERATOR_ROW_H)

    -- AND / OR buttons (middle rows only).
    local andButton, orButton
    if not isFirst and not isLast then
        andButton = CreateFrame("Button", nil, rowFrame)
        PixelUtil.SetSize(andButton, OPERATOR_BUTTON_W, OPERATOR_BUTTON_H)
        andButton:SetPoint("CENTER", rowFrame, "CENTER", -(OPERATOR_BUTTON_W / 2 + 5), 0)
        local andTex = andButton:CreateTexture(nil, "ARTWORK")
        andTex:SetAllPoints(); andTex:SetTexture(AND_ICON_PATH)
        local andHL  = andButton:CreateTexture(nil, "HIGHLIGHT")
        andHL:SetAllPoints(); andHL:SetTexture(AND_ICON_PATH); andHL:SetAlpha(0.6)

        orButton = CreateFrame("Button", nil, rowFrame)
        PixelUtil.SetSize(orButton, OPERATOR_BUTTON_W, OPERATOR_BUTTON_H)
        orButton:SetPoint("CENTER", rowFrame, "CENTER", (OPERATOR_BUTTON_W / 2 + 5), 0)
        local orTex = orButton:CreateTexture(nil, "ARTWORK")
        orTex:SetAllPoints(); orTex:SetTexture(OR_ICON_PATH)
        local orHL  = orButton:CreateTexture(nil, "HIGHLIGHT")
        orHL:SetAllPoints(); orHL:SetTexture(OR_ICON_PATH); orHL:SetAlpha(0.6)

        local function RefreshOp()
            local ents = ConditionalCreator:GetEntries(state.selectedConditional)
            local op   = ents and closeEntryIdx and ents[closeEntryIdx]
            if not op or op.operand == OPERATOR_TYPE.AND then
                andTex:SetVertexColor(COLOR_AND_ACTIVE[1], COLOR_AND_ACTIVE[2], COLOR_AND_ACTIVE[3])
                orTex:SetVertexColor(1, 1, 1)
            else
                andTex:SetVertexColor(1, 1, 1)
                orTex:SetVertexColor(COLOR_OR_ACTIVE[1], COLOR_OR_ACTIVE[2], COLOR_OR_ACTIVE[3])
            end
        end
        andButton:SetScript("OnClick", function()
            local ents = ConditionalCreator:GetEntries(state.selectedConditional)
            if ents and closeEntryIdx then ents[closeEntryIdx].operand = OPERATOR_TYPE.AND end
            RefreshOp()
        end)
        orButton:SetScript("OnClick", function()
            local ents = ConditionalCreator:GetEntries(state.selectedConditional)
            if ents and closeEntryIdx then ents[closeEntryIdx].operand = OPERATOR_TYPE.OR end
            RefreshOp()
        end)
        RefreshOp()
    end

    -- ── Closing-paren buttons ─────────────────────────────────────────────────
    -- closeCount active ) buttons + 1 gray "add" button.
    -- Only rendered when there are 3+ conditions and this is not the first row.
    if not isFirst and conditionCount >= 3 then
        for i = 0, closeCount do
            local isActive = (i < closeCount)
            local btn = CreateFrame("Button", nil, editFrame)
            PixelUtil.SetSize(btn, PAREN_BUTTON_W, PAREN_BUTTON_H)
            if andButton then
                btn:SetPoint("TOPRIGHT", andButton, "TOPLEFT", -(5 + i * PAREN_SLOT_W), 0)
            else
                btn:SetPoint("CENTER", rowFrame, "CENTER",
                             -(5 + i * PAREN_SLOT_W + PAREN_BUTTON_W / 2), 0)
            end
            btn:SetFrameLevel(rowFrame:GetFrameLevel() + 6)
            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints(); tex:SetTexture(PAREN_TEXTURE_PATH); tex:SetTexCoord(0.5, 1, 0, 1)
            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(); hl:SetTexture(PAREN_TEXTURE_PATH); hl:SetTexCoord(0.5, 1, 0, 1); hl:SetAlpha(0.5)
            if isActive then
                local ci = colorMap and closeEntryIdx
                    and colorMap[closeEntryIdx]
                    and colorMap[closeEntryIdx]["close"]
                    and colorMap[closeEntryIdx]["close"][i + 1]
                local c = ci and PAREN_COLORS[ci]
                if c then tex:SetVertexColor(c[1], c[2], c[3])
                else tex:SetVertexColor(COLOR_PAREN_INACTIVE[1], COLOR_PAREN_INACTIVE[2], COLOR_PAREN_INACTIVE[3]) end
                btn:SetScript("OnEnter", function()
                    GameTooltip:SetOwner(btn, "ANCHOR_CURSOR_RIGHT")
                    GameTooltip:SetText("Remove closing parenthesis", 1, 1, 1, 1, true); GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                btn:SetScript("OnClick", function()
                    local ents = ConditionalCreator:GetEntries(state.selectedConditional)
                    if ents and closeEntryIdx and (ents[closeEntryIdx].closeParens or 0) > 0 then
                        ents[closeEntryIdx].closeParens = ents[closeEntryIdx].closeParens - 1
                        ConditionalCreator:RefreshParenButtons(state)
                    end
                end)
            else
                tex:SetVertexColor(COLOR_PAREN_INACTIVE[1], COLOR_PAREN_INACTIVE[2], COLOR_PAREN_INACTIVE[3])
                btn:SetScript("OnEnter", function()
                    GameTooltip:SetOwner(btn, "ANCHOR_CURSOR_RIGHT")
                    GameTooltip:SetText("Add closing parenthesis", 1, 1, 1, 1, true); GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                btn:SetScript("OnClick", function()
                    local ents = ConditionalCreator:GetEntries(state.selectedConditional)
                    if ents and closeEntryIdx then
                        ents[closeEntryIdx].closeParens = (ents[closeEntryIdx].closeParens or 0) + 1
                        ConditionalCreator:RefreshParenButtons(state)
                    end
                end)
            end
            table.insert(outParenButtons, btn)
        end
    end

    -- ── Opening-paren buttons ─────────────────────────────────────────────────
    -- openCount active ( buttons + 1 gray "add" button.
    -- Only rendered when there are 3+ conditions and this is not the last row.
    if not isLast and conditionCount >= 3 then
        for i = 0, openCount do
            local isActive = (i < openCount)
            local btn = CreateFrame("Button", nil, editFrame)
            PixelUtil.SetSize(btn, PAREN_BUTTON_W, PAREN_BUTTON_H)
            if orButton then
                btn:SetPoint("TOPLEFT", orButton, "TOPRIGHT", 5 + i * PAREN_SLOT_W, 0)
            else
                btn:SetPoint("CENTER", rowFrame, "CENTER",
                             5 + i * PAREN_SLOT_W + PAREN_BUTTON_W / 2, 0)
            end
            btn:SetFrameLevel(rowFrame:GetFrameLevel() + 6)
            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints(); tex:SetTexture(PAREN_TEXTURE_PATH); tex:SetTexCoord(0, 0.5, 0, 1)
            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(); hl:SetTexture(PAREN_TEXTURE_PATH); hl:SetTexCoord(0, 0.5, 0, 1); hl:SetAlpha(0.5)
            if isActive then
                local ci = colorMap and openEntryIdx
                    and colorMap[openEntryIdx]
                    and colorMap[openEntryIdx]["open"]
                    and colorMap[openEntryIdx]["open"][i + 1]
                local c = ci and PAREN_COLORS[ci]
                if c then tex:SetVertexColor(c[1], c[2], c[3])
                else tex:SetVertexColor(COLOR_PAREN_INACTIVE[1], COLOR_PAREN_INACTIVE[2], COLOR_PAREN_INACTIVE[3]) end
                btn:SetScript("OnEnter", function()
                    GameTooltip:SetOwner(btn, "ANCHOR_CURSOR_RIGHT")
                    GameTooltip:SetText("Remove opening parenthesis", 1, 1, 1, 1, true); GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                btn:SetScript("OnClick", function()
                    local ents = ConditionalCreator:GetEntries(state.selectedConditional)
                    if ents and openEntryIdx and (ents[openEntryIdx].openParens or 0) > 0 then
                        ents[openEntryIdx].openParens = ents[openEntryIdx].openParens - 1
                        ConditionalCreator:RefreshParenButtons(state)
                    end
                end)
            else
                tex:SetVertexColor(COLOR_PAREN_INACTIVE[1], COLOR_PAREN_INACTIVE[2], COLOR_PAREN_INACTIVE[3])
                btn:SetScript("OnEnter", function()
                    GameTooltip:SetOwner(btn, "ANCHOR_CURSOR_RIGHT")
                    GameTooltip:SetText("Add opening parenthesis", 1, 1, 1, 1, true); GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                btn:SetScript("OnClick", function()
                    local ents = ConditionalCreator:GetEntries(state.selectedConditional)
                    if ents and openEntryIdx then
                        ents[openEntryIdx].openParens = (ents[openEntryIdx].openParens or 0) + 1
                        ConditionalCreator:RefreshParenButtons(state)
                    end
                end)
            end
            table.insert(outParenButtons, btn)
        end
    end

    return rowFrame
end


-- ─── Plus button ─────────────────────────────────────────────────────────────
function ConditionalCreator:CreatePlusButton(parent, state)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(24, 24)
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(); tex:SetTexture(PLUS_ICON_PATH)
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetTexture(PLUS_ICON_PATH); hl:SetAlpha(0.6)
    btn:SetScript("OnClick", function()
        ConditionalCreator:AddCondition(state.selectedConditional)
        ConditionalCreator:RenderEntries(state)
    end)
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(btn, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:SetText("Add condition", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

-- ─── Reposition (no rebuild) ─────────────────────────────────────────────────
-- Walks the existing conditionFrames / operatorRowFrames and updates their
-- anchor points to reflect current frame heights.  Safe to call after a single
-- frame's height changes (e.g. after GetBoundsRect resolves).
--
function ConditionalCreator:RepositionEntries(state)
    if not state or not state.editFrame then return end
    local conditions   = self:GetConditions(state.selectedConditional) 
    local N            = conditions and #conditions or 0
    local showOps      = (N >= 2)
    local editFrame    = state.editFrame

    local currentY   = -(ENTRY_SPACING)
    local leftPad    = 0
    local rightPad   = 0

    for i = 1, N do
        -- operator row above condition i
        if showOps and state.operatorRowFrames[i] then
            local rf = state.operatorRowFrames[i]
            rf:ClearAllPoints()
            rf:SetPoint("TOPLEFT",  editFrame, "TOPLEFT",  leftPad,  currentY)
            rf:SetPoint("TOPRIGHT", editFrame, "TOPRIGHT", rightPad, currentY)
            currentY = currentY - OPERATOR_ROW_H - ENTRY_SPACING
        end
        -- condition frame
        if state.conditionFrames[i] then
            local cf = state.conditionFrames[i]
            cf:ClearAllPoints()
            cf:SetPoint("TOPLEFT",  editFrame, "TOPLEFT",  leftPad,  currentY)
            cf:SetPoint("TOPRIGHT", editFrame, "TOPRIGHT", rightPad, currentY)
            local h = cf:GetHeight()
            currentY = currentY - h - ENTRY_SPACING
        end
    end
    -- operator row after last condition
    if showOps and state.operatorRowFrames[N + 1] then
        local rf = state.operatorRowFrames[N + 1]
        rf:ClearAllPoints()
        rf:SetPoint("TOPLEFT",  editFrame, "TOPLEFT",  leftPad,  currentY)
        rf:SetPoint("TOPRIGHT", editFrame, "TOPRIGHT", rightPad, currentY)
        currentY = currentY - OPERATOR_ROW_H - ENTRY_SPACING
    end
    -- plus button
    if state.plusBtn then
        state.plusBtn:ClearAllPoints()
        state.plusBtn:SetPoint("TOP", editFrame, "TOPLEFT",
                               leftPad + 12, currentY - 12)
    end
    -- resize editFrame to content
    editFrame:SetHeight(math.abs(currentY) + 20)
end

-- ─── Paren-only refresh (no condition frames touched) ───────────────────────
-- Tears down and rebuilds operator-row frames and paren buttons only.
-- Condition frames are left exactly as-is, so no GetBoundsRect flicker occurs.
-- Call this instead of RenderEntries when only parenthesis state has changed.
--
function ConditionalCreator:RefreshParenButtons(state)
    if not state or not state.editFrame then return end

    -- Destroy old operator row frames.
    for _, f in pairs(state.operatorRowFrames) do f:Hide() end
    state.operatorRowFrames = {}

    -- Destroy old paren buttons.
    for _, b in pairs(state.parenButtons) do b:Hide() end
    state.parenButtons = {}

    local name     = state.selectedConditional
    local entries  = self:GetEntries(name) or {}
    local colorMap = self:ComputeParenColors(entries)
    local N        = self:GetConditionCount(name)
    local condIdx  = 0

    for ei, entry in ipairs(entries) do
        if entry.type == "condition" then
            condIdx = condIdx + 1
        elseif entry.type == "operator" and N >= 2 then
            local rf = self:CreateOperatorRowFrame(
                state.editFrame, entry.closeParens or 0, entry.operand, entry.openParens or 0,
                ei, ei, condIdx + 1, N, state, state.parenButtons, colorMap)
            state.operatorRowFrames[condIdx + 1] = rf
        elseif entry.type == "boundary" then
            if entry.openParens ~= nil then
                local rf = self:CreateOperatorRowFrame(
                    state.editFrame, 0, nil, entry.openParens or 0,
                    nil, ei, 1, N, state, state.parenButtons, colorMap)
                state.operatorRowFrames[1] = rf
            else
                local rf = self:CreateOperatorRowFrame(
                    state.editFrame, entry.closeParens or 0, nil, 0,
                    ei, nil, N + 1, N, state, state.parenButtons, colorMap)
                state.operatorRowFrames[N + 1] = rf
            end
        end
    end

    self:RepositionEntries(state)
end

-- ─── Full rebuild / render ───────────────────────────────────────────────────
function ConditionalCreator:RenderEntries(state)
    if not state or not state.editFrame then return end
    state.renderGeneration = (state.renderGeneration or 0) + 1

    local editFrame = state.editFrame

    -- Destroy old condition frames.
    for _, f in pairs(state.conditionFrames) do f:Hide() end
    state.conditionFrames = {}

    -- Destroy old operator row frames.
    -- Use pairs (not ipairs) because operatorRowFrames is sparse when N < 3:
    -- e.g. for N=2 only index 2 is set, so ipairs would stop at index 1.
    for _, f in pairs(state.operatorRowFrames) do f:Hide() end
    state.operatorRowFrames = {}

    -- Destroy old paren buttons.
    for _, b in pairs(state.parenButtons) do b:Hide() end
    state.parenButtons = {}

    local name      = state.selectedConditional
    local entries   = self:GetEntries(name) or {}
    local colorMap  = self:ComputeParenColors(entries)
    local N         = self:GetConditionCount(name)
    local condIdx   = 0

    -- Build frames (no positioning yet).
    for ei, entry in ipairs(entries) do
        if entry.type == "condition" then
            condIdx = condIdx + 1
            local cf = self:CreateConditionFrame(editFrame, entry, condIdx, state)
            state.conditionFrames[condIdx] = cf
        elseif entry.type == "operator" and N >= 2 then
            local rf = self:CreateOperatorRowFrame(
                editFrame, entry.closeParens or 0, entry.operand, entry.openParens or 0,
                ei, ei, condIdx + 1, N, state, state.parenButtons, colorMap)
            state.operatorRowFrames[condIdx + 1] = rf
        elseif entry.type == "boundary" then
            if entry.openParens ~= nil then
                -- Leading boundary: paren-only row before the first condition.
                local rf = self:CreateOperatorRowFrame(
                    editFrame, 0, nil, entry.openParens or 0,
                    nil, ei, 1, N, state, state.parenButtons, colorMap)
                state.operatorRowFrames[1] = rf
            else
                -- Trailing boundary: paren-only row after the last condition.
                local rf = self:CreateOperatorRowFrame(
                    editFrame, entry.closeParens or 0, nil, 0,
                    ei, nil, N + 1, N, state, state.parenButtons, colorMap)
                state.operatorRowFrames[N + 1] = rf
            end
        end
    end

    -- Plus button (create once, reuse via state).
    if not state.plusBtn then
        state.plusBtn = self:CreatePlusButton(editFrame, state)
    end
    if state.selectedConditional then
        state.plusBtn:Show()
    else
        state.plusBtn:Hide()
    end

    -- Place everything.
    self:RepositionEntries(state)
end

-- ─── Edit-area scaffold ──────────────────────────────────────────────────────
-- Creates a scroll-able content pane anchored below `inputBox`.
-- Returns the innermost editable frame that RenderEntries should target.
--
function ConditionalCreator:CreateEditArea(parentFrame, inputBox)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parentFrame)
    scrollFrame:SetPoint("TOP",    inputBox,    "BOTTOM",  0,  -8)
    scrollFrame:SetPoint("LEFT",   parentFrame, "LEFT",    16,   0)
    scrollFrame:SetPoint("RIGHT",  parentFrame, "RIGHT",   -16,   0)
    scrollFrame:SetPoint("BOTTOM", parentFrame, "BOTTOM",  0,   8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(scrollFrame:GetWidth())
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)

    scrollFrame:SetScript("OnSizeChanged", function(self, w)
        content:SetWidth(w)
    end)

    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local max     = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, current - delta * 20)))
    end)

    return scrollFrame, content
end

-- ─── Conditional selection dropdown ─────────────────────────────────────────
function ConditionalCreator:CreateConditionalDropdown(parentFrame, state)
    local label = parentFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 14, -14)
    label:SetText("Conditional:")

    local dd = CreateFrame("Frame", "SpellStylerConditionalDropdown", parentFrame, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", label, "TOPRIGHT", 4, 4)
    UIDropDownMenu_SetWidth(dd, 160)

    local deleteBtn = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate")
    deleteBtn:SetSize(60, 22)
    -- UIDropDownMenuTemplate adds ~20 px of internal right padding.
    deleteBtn:SetPoint("LEFT", dd, "RIGHT", -20, 2)
    deleteBtn:SetText("Delete")
    deleteBtn:SetEnabled(false)

    local function Refresh()
        local sel = state.selectedConditional
        UIDropDownMenu_SetText(dd, sel and sel or "|cFF888888Select...|r")
        deleteBtn:SetEnabled(sel ~= nil)
        ConditionalCreator:RenderEntries(state)
    end

    state.refreshDropdown = Refresh

    deleteBtn:SetScript("OnClick", function()
        local sel = state.selectedConditional
        if not sel then return end
        StaticPopupDialogs["SPELLSTYLER_DELETE_CONDITIONAL"] = {
            text         = 'Delete conditional "' .. sel .. '"? This cannot be undone.',
            button1      = "Delete",
            button2      = "Cancel",
            OnAccept     = function()
                local db = SpellStyler_DB and SpellStyler_DB.conditionals
                if db then db[sel] = nil end
                -- Default to another existing conditional, or nil if none remain.
                local remaining = nil
                if db then
                    for k in pairs(db) do remaining = k; break end
                end
                state.selectedConditional = remaining
                Refresh()
            end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("SPELLSTYLER_DELETE_CONDITIONAL")
    end)

    UIDropDownMenu_Initialize(dd, function(self, level)
        -- "New" entry.
        local newInfo    = UIDropDownMenu_CreateInfo()
        newInfo.text     = "|cFF00FF00New conditional...|r"
        newInfo.notCheckable = true
        newInfo.func     = function()
            StaticPopupDialogs["SPELLSTYLER_NEW_CONDITIONAL"] = {
                text         = "Enter a name for the new conditional:",
                button1      = "Create",
                button2      = "Cancel",
                hasEditBox   = true,
                maxLetters   = 40,
                OnAccept     = function(self)
                    local txt = strtrim(self.EditBox:GetText())
                    if txt == "" then return end
                    local db = SpellStyler_DB.conditionals or {}
                    SpellStyler_DB.conditionals = db
                    if not db[txt] then db[txt] = { conditions = {}, operatorRows = {} } end
                    state.selectedConditional = txt
                    Refresh()
                end,
                timeout = 0, whileDead = true, hideOnEscape = true,
                enterClicksFirstButton = true,
            }
            StaticPopup_Show("SPELLSTYLER_NEW_CONDITIONAL")
        end
        UIDropDownMenu_AddButton(newInfo, level)

        -- Existing conditionals.
        local db = SpellStyler_DB and SpellStyler_DB.conditionals or {}
        for name, _ in pairs(db) do
            local info   = UIDropDownMenu_CreateInfo()
            info.text    = name; info.value = name
            info.checked = (state.selectedConditional == name)
            info.func    = function(btn)
                state.selectedConditional = btn.value; Refresh()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    Refresh()
    return dd, label
end

-- ─── Public entry point ──────────────────────────────────────────────────────
-- Called once with the parentFrame (the settings view panel).  Builds the full
-- Conditions UI and attaches it.  Compatible with the SpellStyler settings
-- renderer protocol: `RenderConditionsView(parentFrame)`.
--
function ConditionalCreator:RenderConditionsView(parentFrame)
    -- Clear any existing children we created last time.
    if parentFrame._conditionsViewBuilt then return end
    parentFrame._conditionsViewBuilt = true

    local state = {
        selectedConditional = nil,
        conditionFrames     = {},
        operatorRowFrames   = {},
        parenButtons        = {},
        editFrame           = nil,
        plusBtn             = nil,
        refreshDropdown     = function() end,
        renderGeneration    = 0,
    }

    local dd, ddLabel = self:CreateConditionalDropdown(parentFrame, state)

    local _, editFrame = self:CreateEditArea(parentFrame, dd)
    state.editFrame = editFrame
end

