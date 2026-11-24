local addonName, SpellStyler = ...
SpellStyler.SoundPreviewRenderer = SpellStyler.SoundPreviewRenderer or {}
local SoundPreviewRenderer = SpellStyler.SoundPreviewRenderer

local function DisplayName(path)
    local value = tostring(path)
    local fileName = value:match("([^\\/]*)$") or value
    return fileName:gsub("%.[^%.]+$", "")
end

local function PlayPreview(sound)
    local soundManager = SpellStyler.SoundManager
    local wasMuted = soundManager and soundManager:IsSoundMuted(sound)
    if wasMuted then
        soundManager:UnmuteSounds({ [sound] = true })
    end
    pcall(PlaySoundFile, sound, "Master")
    if wasMuted then
        soundManager:MuteSounds({ [sound] = true })
    end
end

function SoundPreviewRenderer:GetAnchorFrame()
    return SpellStyler.TexturePreviewRenderer
        and SpellStyler.TexturePreviewRenderer:GetAnchorFrame()
end

function SoundPreviewRenderer:EnsureOverlay()
    if self.overlay then return self.overlay end

    local overlay = CreateFrame("Frame", "SpellStyler_SoundPreviewOverlay", UIParent, "BackdropTemplate")
    overlay:SetFrameStrata("FULLSCREEN_DIALOG")
    overlay:SetToplevel(true)
    overlay:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    overlay:SetBackdropColor(0.06, 0.06, 0.06, 0.98)
    overlay:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    overlay:EnableMouse(true)
    overlay:Hide()

    local title = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Choose a Sound")
    title:SetTextColor(1, 0.82, 0)

    local subtitle = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", 10, -26)
    subtitle:SetWidth(300)
    subtitle:SetHeight(32)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetWordWrap(true)
    subtitle:SetText("Click the sound name to test.\n\"+\" to select the sound.\n\"x\" to delete the record.")
    subtitle:SetTextColor(0.7, 0.7, 0.7)

    local close = CreateFrame("Button", nil, overlay, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() self:Hide() end)

    local savedSearch = CreateFrame("EditBox", nil, overlay, "InputBoxTemplate")
    savedSearch:SetSize(150, 20)
    savedSearch:SetPoint("TOPLEFT", 10, -62)
    savedSearch:SetAutoFocus(false)
    savedSearch:SetMaxLetters(200)
    overlay.savedSearch = savedSearch

    local savedLabel = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    savedLabel:SetPoint("LEFT", savedSearch, "RIGHT", 6, 0)
    savedLabel:SetText("Filter custom added sounds")
    savedLabel:SetTextColor(0.7, 0.7, 0.7)

    local spellSearch = CreateFrame("EditBox", nil, overlay, "InputBoxTemplate")
    spellSearch:SetSize(150, 20)
    spellSearch:SetPoint("TOPLEFT", 10, -86)
    spellSearch:SetAutoFocus(false)
    spellSearch:SetMaxLetters(100)
    overlay.spellSearch = spellSearch

    local spellLabel = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    spellLabel:SetPoint("LEFT", spellSearch, "RIGHT", 6, 0)
    spellLabel:SetText("Search database by\nspell ID or name")
    spellLabel:SetTextColor(0.7, 0.7, 0.7)

    local scroll = CreateFrame("ScrollFrame", nil, overlay, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -112)
    scroll:SetPoint("BOTTOMRIGHT", -10, 10)
    for _, scrollChild in ipairs({ scroll:GetChildren() }) do
        scrollChild:Hide()
        scrollChild:SetAlpha(0)
    end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(frame, delta)
        frame:SetVerticalScroll(math.max(0, math.min(
            frame:GetVerticalScrollRange(),
            frame:GetVerticalScroll() - delta * 30
        )))
    end)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(300, 1)
    scroll:SetScrollChild(child)
    overlay.scroll = scroll
    overlay.child = child

    self.overlay = overlay
    return overlay
end

function SoundPreviewRenderer:BuildRows(entries, onSelect)
    local child = self.overlay.child
    for _, frame in ipairs({ child:GetChildren() }) do
        frame:Hide()
        frame:SetParent(nil)
    end

    local y = 0
    for _, entry in ipairs(entries) do
        if entry.kind == "header" then
            local header = CreateFrame("Frame", nil, child)
            header:SetSize(290, 22)
            header:SetPoint("TOPLEFT", entry.indent or 0, -y)
            local headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            headerText:SetPoint("LEFT")
            headerText:SetText(entry.label)
            headerText:SetTextColor(1, 0.82, 0)
            y = y + 22
        else
            local indent = entry.indent or 0
            local rowWidth = 300 - indent
            local hasRemoveButton = entry.isCustom
            local rowHeight = 22
            local row = CreateFrame("Frame", nil, child)
            row:SetSize(rowWidth, rowHeight)
            row:SetPoint("TOPLEFT", indent, -y)
            local soundName = CreateFrame("Button", nil, row)
            soundName:SetSize(rowWidth - (hasRemoveButton and 56 or 28), rowHeight)
            soundName:SetPoint("TOPLEFT")
            soundName:SetScript("OnClick", function() PlayPreview(entry.value) end)

            local soundLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            soundLabel:SetPoint("TOPLEFT")
            soundLabel:SetSize(rowWidth - (hasRemoveButton and 56 or 28), rowHeight)
            soundLabel:SetText(entry.label)
            soundLabel:SetJustifyH("LEFT")
            soundLabel:SetWordWrap(true)
            rowHeight = math.max(rowHeight, soundLabel:GetStringHeight() + 2)
            row:SetHeight(rowHeight)
            soundName:SetHeight(rowHeight)
            soundLabel:SetHeight(rowHeight)

            local select = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            select:SetSize(24, 20)
            select:SetPoint("RIGHT", hasRemoveButton and -28 or 0, 0)
            select:SetText("+")
            select:SetScript("OnClick", function()
                if onSelect then onSelect(entry.value) end
                self:Hide()
            end)
            
            if entry.isCustom then
                local remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                remove:SetSize(24, 20)
                remove:SetPoint("RIGHT")
                remove:SetText("x")
                remove:SetScript("OnClick", function()
                    SpellStyler.State:RemoveCustomSound(entry.value)
                    self:Refresh(onSelect)
                end)
            end
            y = y + rowHeight
        end
    end
    child:SetHeight(math.max(y, 1))
end

function SoundPreviewRenderer:Refresh(onSelect)
    local overlay = self.overlay
    if not overlay then return end

    local entries = {}
    local spellFilter = string.lower(overlay.spellSearch:GetText() or "")
    local pathFilter = string.lower(overlay.savedSearch:GetText() or "")
    if spellFilter == "" then
        for _, path in ipairs(SpellStyler.State:GetCustomSounds()) do
            if pathFilter == "" or string.find(string.lower(tostring(path)), pathFilter, 1, true) then
                entries[#entries + 1] = {
                    label = DisplayName(path),
                    value = path,
                    isCustom = true,
                }
            end
        end
    end

    if spellFilter ~= "" then
        local numericID = tonumber(spellFilter)
        local spellID
        local spellInfo
        if numericID then
            spellID = numericID
        else
            spellInfo = C_Spell.GetSpellInfo(overlay.spellSearch:GetText())
            spellID = spellInfo and spellInfo.spellID
        end

        local sounds = spellID and SpellStyler.SpellSoundMap
            and SpellStyler.SpellSoundMap[spellID]
        if sounds then
            entries[#entries + 1] = {
                kind = "header",
                label = (spellInfo and spellInfo.name or ("Spell ID " .. tostring(spellID))),
            }
            local soundIDs = {}
            if type(sounds) == "table" then
                for _, soundID in pairs(sounds) do
                    soundIDs[#soundIDs + 1] = soundID
                end
                table.sort(soundIDs, function(left, right)
                    return tostring(left) < tostring(right)
                end)
            else
                soundIDs[1] = sounds
            end
            for _, soundID in ipairs(soundIDs) do
                local fileName = SpellStyler.SpellSoundFileNames
                    and SpellStyler.SpellSoundFileNames[tonumber(soundID)]
                    or "unknown filename"
                entries[#entries + 1] = {
                    label = DisplayName(fileName),
                    value = soundID,
                }
            end
        end
    end

    self:BuildRows(entries, onSelect)
end

function SoundPreviewRenderer:Show(onSelect)
    local overlay = self:EnsureOverlay()
    local anchor = self:GetAnchorFrame()
    overlay:ClearAllPoints()
    if anchor then
        overlay:SetAllPoints(anchor)
        if not anchor._ssSoundPreviewHooked then
            anchor._ssSoundPreviewHooked = true
            anchor:HookScript("OnHide", function() self:Hide() end)
        end
    else
        overlay:SetSize(340, 420)
        overlay:SetPoint("CENTER")
    end

    overlay.savedSearch:SetText("")
    overlay.spellSearch:SetText("")
    overlay.savedSearch:SetScript("OnTextChanged", function() self:Refresh(onSelect) end)
    overlay.spellSearch:SetScript("OnTextChanged", function() self:Refresh(onSelect) end)
    self:Refresh(onSelect)
    overlay:Show()
end

function SoundPreviewRenderer:Hide()
    if self.overlay then self.overlay:Hide() end
end
