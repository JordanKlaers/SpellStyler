local _, SpellStyler = ...

SpellStyler.ProfileSettingsRenderer = SpellStyler.ProfileSettingsRenderer or {}
local Renderer = SpellStyler.ProfileSettingsRenderer
local State = SpellStyler.State

local function CreateDropdown(parent, width)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dropdown, width or 150)
    return dropdown
end

local function CreateSeparator(parent, anchor, xOffset, yOffset)
    local separator = parent:CreateTexture(nil, "ARTWORK")
    separator:SetColorTexture(0.55, 0.55, 0.55, 0.55)
    separator:SetHeight(1)
    separator:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", xOffset or 0, yOffset or -8)
    separator:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
    return separator
end

local function SetDropdownEnabled(dropdown, enabled)
    if enabled then
        UIDropDownMenu_EnableDropDown(dropdown)
    else
        UIDropDownMenu_DisableDropDown(dropdown)
    end
end

local function RefreshFrames()
    local manager = SpellStyler.FrameTrackerManager
    if not manager or not manager.lifecycleController then return end
    if SpellStyler.BuffManager and SpellStyler.BuffManager.DestroyBuffContainers then
        SpellStyler.BuffManager:DestroyBuffContainers()
    end
    manager.lifecycleController.TeardownSpecFrames()
    manager.lifecycleController.FreshCreateFrames("profile_settings")
    if SpellStyler.BuffManager then
        SpellStyler.BuffManager:CreateBuffContainers()
        if SpellStyler.settingsMenu and SpellStyler.settingsMenu:IsShown() then
            SpellStyler.BuffManager:EnablePlaceholderDragging(true)
        end
    end
end

function Renderer:Render(parent)
    if self.frame then
        self.frame:SetParent(parent)
        self.frame:SetAllPoints(parent)
        return self.frame
    end

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    self.frame = frame

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -16)
    title:SetText("Profiles")

    local description = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    description:SetWidth(330)
    description:SetJustifyH("LEFT")
    description:SetText("Choose one profile for this specialization or assign profiles to individual talent loadouts.")

    local singleButton = CreateFrame("CheckButton", nil, frame, "UIRadioButtonTemplate")
    singleButton:SetPoint("TOPLEFT", description, "BOTTOMLEFT", -2, -4)
    singleButton.text:SetText("Use one profile for this specialization")

    local talentButton = CreateFrame("CheckButton", nil, frame, "UIRadioButtonTemplate")
    talentButton:SetPoint("TOPLEFT", singleButton, "BOTTOMLEFT", 0, -2)
    talentButton.text:SetText("Use profiles based on talent loadout")

    local modeSeparator = CreateSeparator(frame, talentButton, 4, -8)

    local createLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    createLabel:SetPoint("TOPLEFT", modeSeparator, "BOTTOMLEFT", 0, -8)
    createLabel:SetText("Create profile by cloning the active profile")

    local nameBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    nameBox:SetSize(150, 22)
    nameBox:SetPoint("TOPLEFT", createLabel, "BOTTOMLEFT", 4, -8)
    nameBox:SetAutoFocus(false)

    local createButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    createButton:SetSize(100, 22)
    createButton:SetPoint("LEFT", nameBox, "RIGHT", 16, 0)
    createButton:SetText("Create")

    local selectedProfileForDeletion
    local deleteDropdown = CreateDropdown(frame)
    deleteDropdown:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", -24, -8)

    local deleteButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    deleteButton:SetSize(100, 22)
    deleteButton:SetPoint("LEFT", deleteDropdown, "RIGHT", -6, 2)
    deleteButton:SetText("Delete")

    local errorText = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
    errorText:SetPoint("TOPLEFT", deleteDropdown, "BOTTOMLEFT", 28, -5)
    errorText:SetWidth(270)
    errorText:SetJustifyH("LEFT")

    local activeProfileTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    activeProfileTitle:SetPoint("TOPLEFT", errorText, "BOTTOMLEFT", -2, -8)
    activeProfileTitle:SetText("Active profile")

    local activeProfileSeparator = CreateSeparator(frame, activeProfileTitle, 0, -8)

    local specializationLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    specializationLabel:SetPoint("TOPLEFT", activeProfileSeparator, "BOTTOMLEFT", 0, -8)
    specializationLabel:SetWidth(150)
    specializationLabel:SetJustifyH("LEFT")

    local singleDropdown = CreateDropdown(frame)
    singleDropdown:SetPoint("TOPLEFT", specializationLabel, "TOPRIGHT", -16, 0)

    local loadoutTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    loadoutTitle:SetPoint("TOPLEFT", specializationLabel, "BOTTOMLEFT", 0, -18)
    loadoutTitle:SetText("Talent loadouts")

    local loadoutScrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    loadoutScrollFrame:SetPoint("TOPLEFT", loadoutTitle, "BOTTOMLEFT", 0, -4)
    loadoutScrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 16)

    local loadoutScrollChild = CreateFrame("Frame", nil, loadoutScrollFrame)
    loadoutScrollChild:SetSize(290, 1)
    loadoutScrollFrame:SetScrollChild(loadoutScrollChild)

    local loadoutRows = {}

    local function SetSectionVisualState(element, enabled)
        element:SetAlpha(enabled and 1 or 0.45)
    end

    local function GetSpecializationName()
        local specIndex = GetSpecialization()
        local name
        if specIndex then
            local _, specName = GetSpecializationInfo(specIndex)
            name = specName
        end
        return name or "Current specialization"
    end

    local function GetProfileNames()
        return State:GetProfileNames()
    end

    local function IsSelectedDeletionProfileValid()
        if not selectedProfileForDeletion then
            return false
        end
        for _, profileName in ipairs(GetProfileNames()) do
            if profileName == selectedProfileForDeletion then
                return profileName ~= "default"
            end
        end
        return false
    end

    local function InitializeDropdown(dropdown, selected, onSelect)
        UIDropDownMenu_Initialize(dropdown, function(_, level)
            for _, profileName in ipairs(GetProfileNames()) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = profileName
                info.checked = profileName == selected()
                info.func = function()
                    onSelect(profileName)
                    UIDropDownMenu_SetText(dropdown, profileName)
                    Renderer:Refresh()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    local function CreateLoadoutRow(index)
        local row = CreateFrame("Frame", nil, loadoutScrollChild)
        row:SetSize(310, 28)
        row:EnableMouse(true)
        if index == 1 then
            row:SetPoint("TOPLEFT", loadoutScrollChild, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", loadoutRows[index - 1], "BOTTOMLEFT", 0, -3)
        end

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.name:SetWidth(135)
        row.name:SetJustifyH("LEFT")

        row.dropdown = CreateDropdown(row, 150)
        row.dropdown:SetPoint("LEFT", row.name, "RIGHT", 0, 0)
        row:SetScript("OnEnter", function(self)
            if not self.isActiveTalentLoadout then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("This is the active talent loadout", 1, 1, 1)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        loadoutRows[index] = row
        return row
    end

    local function RefreshLoadouts(talentMode)
        local specDB = State:GetCurrentSpecDatabase()
        State:ReconcileTalentLoadouts(
            State:GetCurrentSpecID(),
            specDB,
            State:CanRegisterTalentLoadouts()
        )
        local profileSettings = specDB and specDB.profileSettings
        local loadouts = profileSettings and profileSettings.talentLoadouts or {}
        local index = 0

        for configID, loadout in pairs(loadouts) do
            index = index + 1
            local row = loadoutRows[index] or CreateLoadoutRow(index)
            row:Show()
            SetSectionVisualState(row, profileSettings and profileSettings.mode == "talent")
            row.isActiveTalentLoadout = tostring(configID) == tostring(State:GetActiveTalentConfigID())
            if row.isActiveTalentLoadout then
                row.name:SetTextColor(0, 1, 0)
            else
                row.name:SetTextColor(1, 1, 1)
            end
            row.name:SetText(loadout.name or tostring(configID))
            local selected = function()
                local current = State:GetCurrentSpecDatabase()
                local currentLoadout = current
                    and current.profileSettings.talentLoadouts[configID]
                return currentLoadout and currentLoadout.profile
            end
            InitializeDropdown(row.dropdown, selected, function(profileName)
                State:SetTalentLoadoutProfile(configID, profileName)
                if State:GetActiveTalentConfigID() == configID then
                    RefreshFrames()
                end
            end)
            UIDropDownMenu_SetText(row.dropdown, loadout.profile or "default")
            SetDropdownEnabled(row.dropdown, talentMode)
        end

        for i = index + 1, #loadoutRows do
            loadoutRows[i]:Hide()
        end

        loadoutScrollChild:SetHeight(math.max(1, index * 31))
    end

    function self:Refresh()
        local specDB = State:GetCurrentSpecDatabase()
        local settings = specDB and specDB.profileSettings or {}
        local mode = settings.mode or "single"
        local singleMode = mode == "single"
        local talentMode = mode == "talent"
        if selectedProfileForDeletion then
            local selectedStillExists = false
            for _, profileName in ipairs(GetProfileNames()) do
                if profileName == selectedProfileForDeletion then
                    selectedStillExists = true
                    break
                end
            end
            if not selectedStillExists then
                selectedProfileForDeletion = nil
            end
        end
        singleButton:SetChecked(mode == "single")
        talentButton:SetChecked(mode == "talent")

        specializationLabel:SetText(GetSpecializationName())
        local selectedProfile = settings.singleProfile or "default"
        UIDropDownMenu_SetText(singleDropdown, selectedProfile)
        SetSectionVisualState(activeProfileTitle, singleMode)
        SetSectionVisualState(specializationLabel, singleMode)
        SetSectionVisualState(singleDropdown, singleMode)
        SetDropdownEnabled(singleDropdown, singleMode)
        SetSectionVisualState(loadoutTitle, talentMode)
        InitializeDropdown(singleDropdown, function()
            local current = State:GetCurrentSpecDatabase()
            return current and current.profileSettings.singleProfile
        end, function(profileName)
            State:SetSingleProfile(profileName)
            RefreshFrames()
        end)

        InitializeDropdown(deleteDropdown, function()
            return selectedProfileForDeletion
        end, function(profileName)
            selectedProfileForDeletion = profileName
        end)
        UIDropDownMenu_SetText(deleteDropdown, selectedProfileForDeletion or "Select profile")
        deleteButton:SetEnabled(IsSelectedDeletionProfileValid())

        RefreshLoadouts(talentMode)
    end

    singleButton:SetScript("OnClick", function()
        State:SetProfileMode("single")
        RefreshFrames()
        self:Refresh()
    end)
    talentButton:SetScript("OnClick", function()
        State:SetProfileMode("talent")
        RefreshFrames()
        self:Refresh()
    end)
    createButton:SetScript("OnClick", function()
        local profileName = strtrim(nameBox:GetText() or "")
        local created, errorMessage = State:CreateProfile(profileName)
        if not created then
            errorText:SetText(errorMessage or "Unable to create profile.")
            return
        end
        errorText:SetText("")
        nameBox:SetText("")
        self:Refresh()
    end)
    deleteButton:SetScript("OnClick", function()
        if not IsSelectedDeletionProfileValid() then
            return
        end
        local deleted, errorMessage = State:DeleteProfile(selectedProfileForDeletion)
        if not deleted then
            errorText:SetText(errorMessage or "Unable to delete profile.")
            return
        end
        selectedProfileForDeletion = nil
        errorText:SetText("")
        RefreshFrames()
        self:Refresh()
    end)

    frame:SetScript("OnShow", function()
        self:Refresh()
    end)
    self:Refresh()
    return frame
end
