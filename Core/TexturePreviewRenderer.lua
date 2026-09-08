local ADDON_NAME, SpellStyler = ...
SpellStyler.TexturePreviewRenderer = SpellStyler.TexturePreviewRenderer or {}
local TexturePreviewRenderer = SpellStyler.TexturePreviewRenderer

-- Blizzard's built-in SpellActivationOverlay proc-glow textures, sourced from the
-- community listfile (rows containing "spellactivationoverlay") filtered down to
-- the actual .blp texture files (excludes .lua/.xml/.db2/.dbc rows).
-- FileDataIDs can be passed directly to Texture:SetTexture() -- see
-- https://warcraft.wiki.gg/wiki/FileDataID
local PREVIEW_TEXTURES = {
    { id = 424570,   name = "spellactivationoverlay_0" },
    { id = 449486,   name = "arcane_missiles" },
    { id = 449487,   name = "blood_surge" },
    { id = 449488,   name = "brain_freeze" },
    { id = 449489,   name = "frozen_fingers" },
    { id = 449490,   name = "hot_streak" },
    { id = 449491,   name = "imp_empowerment" },
    { id = 449492,   name = "nightfall" },
    { id = 449493,   name = "sudden_death" },
    { id = 449494,   name = "sword_and_board" },
    { id = 450913,   name = "art_of_war" },
    { id = 450914,   name = "eclipse_moon" },
    { id = 450915,   name = "eclipse_sun" },
    { id = 450916,   name = "focus_fire" },
    { id = 450917,   name = "genericarc_01" },
    { id = 450918,   name = "genericarc_02" },
    { id = 450919,   name = "genericarc_03" },
    { id = 450920,   name = "genericarc_04" },
    { id = 450921,   name = "genericarc_05" },
    { id = 450922,   name = "genericarc_06" },
    { id = 450923,   name = "generictop_01" },
    { id = 450924,   name = "generictop_02" },
    { id = 450925,   name = "grand_crusader" },
    { id = 450926,   name = "lock_and_load" },
    { id = 450927,   name = "maelstrom_weapon" },
    { id = 450928,   name = "master_marksman" },
    { id = 450929,   name = "natures_grace" },
    { id = 450930,   name = "rime" },
    { id = 450931,   name = "slice_and_dice" },
    { id = 450932,   name = "sudden_doom" },
    { id = 450933,   name = "surge_of_light" },
    { id = 457293,   name = "iconalert" },
    { id = 457294,   name = "iconalertants" },
    { id = 457658,   name = "impact" },
    { id = 458740,   name = "killing_machine" },
    { id = 458741,   name = "molten_core" },
    { id = 459313,   name = "daybreak" },
    { id = 459314,   name = "hand_of_light" },
    { id = 460830,   name = "backlash" },
    { id = 460831,   name = "fury_of_stormrage" },
    { id = 461878,   name = "dark_transformation" },
    { id = 463452,   name = "shooting_stars" },
    { id = 467696,   name = "fulmination" },
    { id = 469752,   name = "serendipity" },
    { id = 510822,   name = "berserk" },
    { id = 510823,   name = "feral_omenofclarity" },
    { id = 511104,   name = "blood_boil" },
    { id = 511105,   name = "necropolis" },
    { id = 511469,   name = "denounce" },
    { id = 592058,   name = "surge_of_darkness" },
    { id = 603338,   name = "dark_tiger" },
    { id = 603339,   name = "white_tiger" },
    { id = 623950,   name = "monk_ox" },
    { id = 623951,   name = "monk_serpent" },
    { id = 623952,   name = "monk_tiger" },
    { id = 627609,   name = "shadow_of_death" },
    { id = 627610,   name = "ultimatum" },
    { id = 656728,   name = "shadow_word_insanity" },
    { id = 774420,   name = "tooth_and_claw" },
    { id = 801266,   name = "backlash_green" },
    { id = 801267,   name = "imp_empowerment_green" },
    { id = 801268,   name = "molten_core_green" },
    { id = 898423,   name = "predatory_swiftness" },
    { id = 962497,   name = "raging_blow" },
    { id = 1001511,  name = "monk_blackoutkick" },
    { id = 1001512,  name = "monk_tigerpalm" },
    { id = 1027131,  name = "arcane_missiles_1" },
    { id = 1027132,  name = "arcane_missiles_2" },
    { id = 1027133,  name = "arcane_missiles_3" },
    { id = 1028091,  name = "monk_ox_2" },
    { id = 1028092,  name = "monk_ox_3" },
    { id = 1028136,  name = "maelstrom_weapon_1" },
    { id = 1028137,  name = "maelstrom_weapon_2" },
    { id = 1028138,  name = "maelstrom_weapon_3" },
    { id = 1028139,  name = "maelstrom_weapon_4" },
    { id = 1029138,  name = "thrill_of_the_hunt_1" },
    { id = 1029139,  name = "thrill_of_the_hunt_2" },
    { id = 1029140,  name = "thrill_of_the_hunt_3" },
    { id = 1030393,  name = "bandits_guile" },
    { id = 1057288,  name = "echo_of_the_elements" },
    { id = 1518303,  name = "predatory_swiftness_green" },
    { id = 2851787,  name = "demonic_core" },
    { id = 2851788,  name = "high_tide" },
    { id = 2888300,  name = "demonic_core_vertical" },
}

local ICON_SIZE   = 64
local ICONS_PER_ROW = 4
local ICON_PAD    = 10

--- Resolves the frame that the icon-settings scroll panel currently occupies,
--- so the texture picker can be sized/positioned to match it.
function TexturePreviewRenderer:GetAnchorFrame()
    local contentFrame = SpellStyler.settingsContentFrame
    return contentFrame and contentFrame._ssSettingsPanel
end

--- Builds (once) the overlay frame used to preview/select textures.
--- Lazily created so it doesn't exist until the first time it's needed.
function TexturePreviewRenderer:EnsureOverlay()
    if self.overlay then return self.overlay end

    local overlay = CreateFrame("Frame", "SpellStyler_TexturePreviewOverlay", UIParent, "BackdropTemplate")
    -- Always render above the settings menu (which uses "DIALOG"), regardless of parentage.
    overlay:SetFrameStrata("FULLSCREEN_DIALOG")
    overlay:SetToplevel(true)
    overlay:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    overlay:SetBackdropColor(0.06, 0.06, 0.06, 0.98)
    overlay:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    overlay:EnableMouse(true)
    overlay:Hide()

    local title = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", overlay, "TOPLEFT", 10, -8)
    title:SetText("Choose a Texture")
    title:SetTextColor(1, 0.82, 0)

    local closeBtn = CreateFrame("Button", nil, overlay, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        TexturePreviewRenderer:Hide()
    end)

    local scrollFrame = CreateFrame("ScrollFrame", nil, overlay, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", overlay, "TOPLEFT", 10, -32)
    scrollFrame:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -28, 10)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = (ICON_SIZE + ICON_PAD) * 1.5
        self:SetVerticalScroll(math.max(0, math.min(maxScroll, current - (delta * step))))
    end)

    local scrollBar = _G[scrollFrame:GetName() and (scrollFrame:GetName() .. "ScrollBar") or nil] or scrollFrame.ScrollBar
    if scrollBar then
        scrollBar:Hide()
        scrollBar.Show = function() end
    end

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)

    overlay.scrollFrame = scrollFrame
    overlay.scrollChild = scrollChild

    self.overlay = overlay
    return overlay
end

--- (Re)builds the icon grid, wiring each button's OnClick to the provided
--- callback with the chosen texture's FileDataID.
function TexturePreviewRenderer:BuildGrid(scrollChild, onSelect)
    for _, child in ipairs({ scrollChild:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end

    local col, row = 0, 0
    for _, entry in ipairs(PREVIEW_TEXTURES) do
        local btn = CreateFrame("Button", nil, scrollChild, "BackdropTemplate")
        btn:SetSize(ICON_SIZE, ICON_SIZE)
        btn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT",
            col * (ICON_SIZE + ICON_PAD),
            -(row * (ICON_SIZE + ICON_PAD))
        )
        btn:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("TOPLEFT", 1, -1)
        tex:SetPoint("BOTTOMRIGHT", -1, 1)
        tex:SetTexture(entry.id)

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.25)

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(entry.name, 1, 1, 1)
            GameTooltip:AddLine("FileDataID: " .. entry.id, 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        btn:SetScript("OnClick", function()
            if onSelect then onSelect(entry.id) end
            TexturePreviewRenderer:Hide()
        end)

        col = col + 1
        if col >= ICONS_PER_ROW then
            col = 0
            row = row + 1
        end
    end

    local totalRows = math.ceil(#PREVIEW_TEXTURES / ICONS_PER_ROW)
    scrollChild:SetSize(
        ICONS_PER_ROW * (ICON_SIZE + ICON_PAD),
        math.max(totalRows * (ICON_SIZE + ICON_PAD), 1)
    )
end

--- Shows the texture picker, sized/positioned over the current icon-settings
--- panel (if open) without touching that panel's own contents. `onSelect`
--- is called with the chosen texture's FileDataID when the user clicks an icon.
function TexturePreviewRenderer:Show(onSelect)
    local overlay = self:EnsureOverlay()
    local anchor = self:GetAnchorFrame()

    overlay:ClearAllPoints()
    if anchor then
        overlay:SetAllPoints(anchor)
        -- Auto-hide the picker if the settings panel it's covering gets hidden/rebuilt.
        if not anchor._ssTexturePreviewHooked then
            anchor._ssTexturePreviewHooked = true
            anchor:HookScript("OnHide", function()
                TexturePreviewRenderer:Hide()
            end)
        end
    else
        overlay:SetSize(340, 420)
        overlay:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    self:BuildGrid(overlay.scrollChild, onSelect)
    overlay:Show()
end

function TexturePreviewRenderer:Hide()
    if self.overlay then
        self.overlay:Hide()
    end
end
