local addonName, SpellStyler = ...
SpellStyler.BuffManager = SpellStyler.BuffManager or {}
local BuffManager = SpellStyler.BuffManager
local State = SpellStyler.State

-- ============================================================================
-- FRAME STORAGE
-- Stores buff containers and slots created by the BuffManager
-- ============================================================================
BuffManager.buffContainers = {}
BuffManager.buffSlots = {}



function BuffManager:CreateStatusBar(frame, key, trackerConfig)
    local configKey = key
    
    local barConfig = trackerConfig[configKey]
    if not barConfig then return end
    local statusBarName = "buffStatusBar" .. trackerConfig.name
    local bar = CreateFrame("StatusBar", statusBarName, frame)
    bar:SetPoint(barConfig.anchorSelf or "LEFT", frame, barConfig.anchorParent or "RIGHT", barConfig.x or 0, barConfig.y or 0)
    local _iconW = trackerConfig.iconSettings.width or trackerConfig.iconSettings.size or 48
    local _iconH = trackerConfig.iconSettings.height or trackerConfig.iconSettings.size or 48
    local statusBarWidth = barConfig and barConfig.width or (_iconW * 4)
    local statusBarHeight = barConfig and barConfig.height or (_iconH / 2)

    bar:SetSize(statusBarWidth, statusBarHeight)
    bar:SetScale(barConfig.scale or 1)

    bar:SetValue(0)
    -- Use one strata higher than icon to ensure statusBar renders above iconContainer's stacking context
    local iconStrata = trackerConfig.iconSettings.frameStrataLevel or "MEDIUM"
    local strataMap = { BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG" }
    bar:SetFrameStrata(strataMap[iconStrata] or "HIGH")
    bar:SetFrameLevel(frame:GetFrameLevel() + 3)  -- Base level for status bar

    
    local statusBarTexture = bar:GetStatusBarTexture()
    if statusBarTexture then
        statusBarTexture:SetDrawLayer("ARTWORK", 0)
    end
    
    local barTexture = (barConfig.customBarTexture and barConfig.customBarTexture ~= "")
        and barConfig.customBarTexture
        or barConfig.defaultBarTexture
	if barTexture then
    	bar:SetStatusBarTexture(barTexture)
	end
    bar:SetStatusBarColor(
        barConfig.color.r or 0.2,
        barConfig.color.g or 0.8,
        barConfig.color.b or 1,
        barConfig.color.a or 1 -- start with an alpha of zero so that GCD doesnt trigger accidentally.
    )
    
    -- Fill direction is controlled via TimerDirection in SetTimerDuration (ElapsedTime = fills up, RemainingTime = depletes)
    bar:SetReverseFill(false)
    bar:SetOrientation(
        (barConfig.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL"
    )
    -- Show statusBar frame once at creation; visibility controlled by alpha thereafter
    -- bar:Show()

	return bar
end


-- ============================================================================
-- BUFF CONTAINER CREATION
-- Creates a single container and slot for each buff in the State
-- ============================================================================
local function CreateBuffContainers()
    local buffs = State:GetAllTrackerValues("buffs")
    
    if not buffs then
        return
    end
    
    
    for baseSpellID, buffConfig in pairs(buffs) do
        -- Only create if enabled
		if BuffManager.buffContainers[baseSpellID] then
			BuffManager:UpdateAura(BuffManager.buffContainers[baseSpellID], buffConfig)
		end
		BuffManager:CreateSingleAuraContainer(baseSpellID, buffConfig)
    end
end

function BuffManager:CreateSingleAuraContainer(baseSpellID, buffConfig)
	if buffConfig.isEnabled ~= false then
		-- Create container frame
		local auraContainer = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
		auraContainer:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

		local options = {
			initializeFrame = function(button, isPlaceholder, buffC)
				local buffConfigObj = buffC or buffConfig
				local inputs = {
					frameStrata = buffConfigObj.iconSettings.frameStrataLevel or "MEDIUM",
					frameStrataLevel = buffConfigObj.iconSettings.frameStrataValue or 100,
					width = buffConfigObj.iconSettings.width or buffConfigObj.iconSettings.size or 48,
					height = buffConfigObj.iconSettings.height or buffConfigObj.iconSettings.size or 48,
					zoom = buffConfigObj.iconSettings.zoom and (buffConfigObj.iconSettings.zoom / 100) or 0,
					iconTexture = buffConfigObj.iconSettings.iconTexturePath ~= nil and buffConfigObj.iconSettings.iconTexturePath ~= "" and buffConfigObj.iconSettings.iconTexturePath or buffConfigObj.defaultIconTexturePath,
					color = buffConfigObj.iconColor or {
						r = 0,
						g = 0,
						b = 0,
						a = 1
					},
					drawSweep = not buffConfigObj.iconSettings.hideDefaultSweep,
					drawBling = not buffConfigObj.iconSettings.hideCooldownBling,
					scale = buffConfigObj.scale or 1,
					opacity = buffConfigObj.iconSettings.opacity  or 1,
					displayCooldownText = buffConfigObj.cooldownText.display or false,
					cooldownTextSize = buffConfigObj.cooldownText.fontSize or 12,
					cooldownTextFont = buffConfigObj.cooldownText.font,
					cooldownTextFontFlags = buffConfigObj.cooldownText.fontFlags,
					cooldownTextX = buffConfigObj.cooldownText.x,
					cooldownTextY = buffConfigObj.cooldownText.y,
					countText = buffConfigObj.countText
				}
				--[[ =========================================================
					Base
				========================================================= ]]
				button:SetSize(inputs.width, inputs.height)
				button:SetScale(inputs.scale or 1)
				button:SetFrameStrata(inputs.frameStrata)
				button:SetFrameLevel(inputs.frameStrataLevel)
				--button:SetPoint()

				--[[ =========================================================
					Icon
				========================================================= ]]

				local icon = button:CreateTexture(nil, "ARTWORK")
				
				icon:SetAllPoints(button)
				icon:SetTexCoord(0 + inputs.zoom, 1 - inputs.zoom, 0 + inputs.zoom, 1 - inputs.zoom)
				
				button.icon = icon
				if isPlaceholder or inputs.iconTexture then
					icon:SetTexture(inputs.iconTexture) -- If there is a custom texture, use this instead and DONT hook it up. This allows the icon to remain as is after being set
				else
					button:SetIcon(icon) -- If not custom texture exists in the settings, let blizzard handle what the icon should be
				end

				icon:SetVertexColor(
					inputs.color.r,
					inputs.color.g,
					inputs.color.b,
					buffConfig.iconSettings.iconDisplayState == 'never' and 0 or inputs.color.a
				)
				
				icon:SetDesaturated(false)
				
				--[[ =========================================================
					Cooldown (swipe and text)
				========================================================= ]]
				local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
				
				cooldown:SetAllPoints()
				cooldown:SetDrawEdge(inputs.drawSweep)
				cooldown:SetDrawSwipe(inputs.drawSweep)
				cooldown:SetDrawBling(inputs.drawBling)
				cooldown:SetSwipeColor(0, 0, 0, 0.8)
				cooldown:SetHideCountdownNumbers(not inputs.displayCooldownText)
				local cdText = cooldown.Text or cooldown.text
				if inputs.displayCooldownText then
					-- Find the cooldown text FontString
					if not cdText then
						for i = 1, cooldown:GetNumRegions() do
							local region = select(i, cooldown:GetRegions())
							if region and region:GetObjectType() == "FontString" then
								cdText = region
								break
							end
						end
					end
					
					if cdText then
						-- Apply font size from pre-computed value
						local fontPath, _, fontFlags = cdText:GetFont()
						local resolvedFontPath = State:ResolveFontPath(inputs.cooldownTextFont, fontPath)
						local resolvedFontFlags = State:ResolveFontFlags(inputs.cooldownTextFontFlags, fontFlags)
						cdText:SetFont(resolvedFontPath, inputs.cooldownTextSize, resolvedFontFlags or "OUTLINE")
						
						-- Apply position from pre-computed values
						cdText:ClearAllPoints()
						cdText:SetPoint("CENTER", cooldown, "CENTER", inputs.cooldownTextX, inputs.cooldownTextY)
					end
				end
				button.cooldown = cooldown
				if not isPlaceholder then
					button:SetDurationCooldown(cooldown)
				end

				--[[ =========================================================
					Cooldown Duration Bar
				========================================================= ]]
				local durationBar = BuffManager:CreateStatusBar(button, 'statusBar', buffConfig)
				button.durationBar = durationBar
				if durationBar then
					if buffConfig['statusBar'].displayState == 'never' then
						durationBar:SetValue(0)
						durationBar:SetStatusBarColor(0, 0, 0, 0)
					else
						durationBar:SetStatusBarColor(
							buffConfig['statusBar'].color.r or 0.2,
							buffConfig['statusBar'].color.g or 0.8,
							buffConfig['statusBar'].color.b or 1,
							buffConfig['statusBar'].color.a or 1 -- start with an alpha of zero so that GCD doesnt trigger accidentally.
						)
					end
					if isPlaceholder then
						durationBar:SetValue(1)
					elseif buffConfig['statusBar'].displayState ~= 'never' then
						button:SetDurationBar(durationBar, {
							direction = Enum.StatusBarTimerDirection.RemainingTime,
							interpolation = Enum.StatusBarInterpolation.Smooth
						})
					end
					
				end

				local chargeBar = BuffManager:CreateStatusBar(button, 'visualChargeBar', buffConfig)
				-- SetApplicationBar makes the bar track buff stacks automatically
				-- The value is secret and updated by Blizzard's code
				button.chargeBar = chargeBar
				if chargeBar then
					if buffConfig['visualChargeBar'].displayState == 'never' then
						chargeBar:SetValue(0)
						chargeBar:SetStatusBarColor(0, 0, 0, 0)
					else
						chargeBar:SetStatusBarColor(
							buffConfig['visualChargeBar'].color.r or 0.2,
							buffConfig['visualChargeBar'].color.g or 0.8,
							buffConfig['visualChargeBar'].color.b or 1,
							buffConfig['visualChargeBar'].color.a or 1 -- start with an alpha of zero so that GCD doesnt trigger accidentally.
						)
					end
					if isPlaceholder then
						chargeBar:SetValue(buffConfig.visualChargeBar.maxValue or 4)
					elseif buffConfig['visualChargeBar'].displayState ~= 'never' then
						button:SetApplicationBar(chargeBar, {
							maxApplications = buffConfig.visualChargeBar.maxValue or 4,  -- Adjust based on buff max stacks
							interpolation = Enum.StatusBarInterpolation.Smooth
						})
					end	
				end


				button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
				local countOffX = (inputs.countText.x or 0) - 2
				local countOffY = (inputs.countText.y or 0) + 2
				button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", countOffX, countOffY)
				button.count:SetJustifyH("RIGHT")
				button.count:SetDrawLayer("OVERLAY", 7)
				
				local _fontPath, _, _fontFlags = button.count:GetFont()
				local fontPath = SpellStyler.State:ResolveFontPath(inputs.countText.font, _fontPath)
				local fontFlags = SpellStyler.State:ResolveFontFlags(inputs.countText.fontFlags, _fontFlags)
				button.count:SetFont(fontPath, inputs.countText.size, fontFlags or "OUTLINE")
				if inputs.countText and inputs.countText.color then
					button.count:SetTextColor(
						inputs.countText.color.r or 1,
						inputs.countText.color.g or 1,
						inputs.countText.color.b or 1,
						inputs.countText.display and (inputs.countText.color.a or 1) or 0
					)
				end
				if isPlaceholder then
					button.count:SetText("00")
				else
					button:SetApplicationCount(button.count, {})
				end

				--[[ =========================================================
					Glow Frame (for click highlight effect)
				========================================================= ]]
				if isPlaceholder then
					button.glowFrame = CreateFrame("Frame", nil, button)
					button.glowFrame:SetAllPoints(button)
					button.glowFrame:SetFrameLevel(button:GetFrameLevel() + 5)
					button.glowFrame:Hide()
					
					-- Glow texture (main glow effect)
					button.glowTexture = button.glowFrame:CreateTexture(nil, "OVERLAY")
					button.glowTexture:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
					button.glowTexture:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
					button.glowTexture:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
					button.glowTexture:SetTexCoord(0.1, 0.9, 0.1, 0.9)
					button.glowTexture:SetBlendMode("ADD")
					button.glowTexture:SetVertexColor(1, 1, 0.6, 0.8)
					
					-- Animated glow (marching ants)
					button.glowAnts = button.glowFrame:CreateTexture(nil, "OVERLAY")
					button.glowAnts:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
					button.glowAnts:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
					button.glowAnts:SetTexture("Interface\\Cooldown\\star4")
					button.glowAnts:SetTexCoord(0, 1, 0, 1)
					button.glowAnts:SetBlendMode("ADD")
					button.glowAnts:SetVertexColor(1, 1, 0.5, 0.6)
					
					-- Animation for marching ants
					button.glowAnim = button.glowAnts:CreateAnimationGroup()
					button.glowAnim:SetLooping("REPEAT")
					local rotation = button.glowAnim:CreateAnimation("Rotation")
					rotation:SetDuration(2)
					rotation:SetDegrees(360)
				end
			end,
			candidateFilters = {
				isFromPlayerOrPlayerPet = true,
				includeSpellIDs = {
					[baseSpellID] = true,
				}
			}
		}
		if buffConfig.additionalBuffIDs then
			for _, buffId in ipairs(buffConfig.additionalBuffIDs) do
				options.candidateFilters.includeSpellIDs[buffId] = true
			end
		end

		-- Determine aura type and unit based on isNPCDebuff setting
		local auraType = (buffConfig.isNPCDebuff == true) and AuraUtil.AuraFilters.Harmful or AuraUtil.AuraFilters.Helpful
		local unitToTrack = (buffConfig.isNPCDebuff == true) and "target" or "player"
		
		-- Add slot and position the container
		local slotFrame = auraContainer:AddAuraSlot(buffConfig.name, auraType .. "|" .. AuraUtil.AuraFilters.Player, options)
		
		-- Position the slot frame using buffConfig position
		local posX = buffConfig.position and buffConfig.position.x or 0
		local posY = buffConfig.position and buffConfig.position.y or 0
		pcall(function()
			slotFrame:SetScale(buffConfig.scale or 1)
			slotFrame:SetPoint("CENTER", UIParent, "CENTER", posX / (buffConfig.scale or 1), posY / (buffConfig.scale or 1))
		end)

		
		auraContainer:SetUnit(unitToTrack)
		-- Create placeholder frame for dragging in settings menu
		local placeHolder = CreateFrame("Button", 'buffPlaceholder_' .. buffConfig.name, UIParent, "BackdropTemplate")
		options.initializeFrame(placeHolder, true)
		placeHolder:SetPoint("CENTER", UIParent, "CENTER", posX / (buffConfig.scale or 1), posY / (buffConfig.scale or 1))

		
		-- Hide placeholder by default
		placeHolder:Hide()
		
		-- Make placeholder movable (interactions will be handled by IconSettingsRenderer)
		placeHolder:SetMovable(true)
		
		-- Store reference to baseSpellID for drag callback and metadata
		placeHolder._baseSpellID = baseSpellID
		placeHolder._draggingEnabled = false
		
		placeHolder.meta = {
			isVariantFrame = false,
			spellName = buffConfig.name,
			baseSpellID = baseSpellID,
			trackerType = 'buffs',
			activeSpellID = buffConfig.activeSpellID or baseSpellID,
			mockCooldownActive = false
		}
		
		-- Store metadata on slotFrame for interactions
		slotFrame._baseSpellID = baseSpellID
		slotFrame._interactionsEnabled = false
		
		-- Store the container
		BuffManager.buffContainers[baseSpellID] = {
			slotName = buffConfig.name,
			auraContainer = auraContainer,
			slotFrame = slotFrame,
			placeHolder = placeHolder,
			options = options,
			auraType = auraType,
			unitToTrack = unitToTrack
		}
	end
end


function BuffManager:UpdateAura(aura, trackerValue)
	--[[
		{
			slotName = buffConfig.name,
			auraContainer = auraContainer,
			slotFrame = slotFrame,
			placeHolder = placeHolder,
			buffConfig = buffConfig
		}
	]]
	local currentSpecID = SpellStyler.State:GetCurrentSpecID()
	if trackerValue.isEnabled and trackerValue.auraSpecs[currentSpecID] then
		aura.auraContainer:SetEnabled(true)
	else
		aura.auraContainer:SetEnabled(false)
	end

	local inputs = {
		frameStrata = trackerValue.iconSettings.frameStrataLevel or "MEDIUM",
		frameStrataLevel = trackerValue.iconSettings.frameStrataValue or 100,
		width = trackerValue.iconSettings.width or trackerValue.iconSettings.size or 48,
		height = trackerValue.iconSettings.height or trackerValue.iconSettings.size or 48,
		zoom = (trackerValue.iconSettings.zoom and (trackerValue.iconSettings.zoom / 100)) or 0,
		iconTexture = trackerValue.iconSettings.iconTexturePath ~= nil and trackerValue.iconSettings.iconTexturePath ~= "" and trackerValue.iconSettings.iconTexturePath or trackerValue.defaultIconTexturePath,
		color = trackerValue.iconColor or {
			r = 0,
			g = 0,
			b = 0,
			a = 1
		},
		drawSweep = not trackerValue.iconSettings.hideDefaultSweep,
		drawBling = not trackerValue.iconSettings.hideCooldownBling,
		scale = trackerValue.scale or 1,
		opacity = trackerValue.iconSettings.opacity  or 1,
		posX = trackerValue.position and trackerValue.position.x or 0,
		posY = trackerValue.position and trackerValue.position.y or 0,
		displayCooldownText = trackerValue.cooldownText.display or false,
		cooldownTextSize = trackerValue.cooldownText.fontSize or 12,
		cooldownTextFont = trackerValue.cooldownText.font,
		cooldownTextFontFlags = trackerValue.cooldownText.fontFlags,
		cooldownTextX = trackerValue.cooldownText.x,
		cooldownTextY = trackerValue.cooldownText.y,
		countText = trackerValue.countText
	}
	
	local function update(frame, isPlaceholder)
		if isPlaceholder and trackerValue.isEnabled and trackerValue.auraSpecs[currentSpecID] and (SpellStyler.settingsMenu and SpellStyler.settingsMenu:IsShown()) then
			frame:Show()
		elseif isPlaceholder and (not trackerValue.isEnabled or not trackerValue.auraSpecs[currentSpecID] or not (SpellStyler.settingsMenu and SpellStyler.settingsMenu:IsShown())) then
			frame:Hide()
		end

		-- Base Frame Properties
		frame:SetSize(inputs.width, inputs.height)
		frame:SetScale(inputs.scale)
		frame:SetFrameStrata(inputs.frameStrata)
		frame:SetFrameLevel(inputs.frameStrataLevel)
		frame:SetPoint("CENTER", UIParent, "CENTER", inputs.posX / inputs.scale, inputs.posY / inputs.scale)
		
		-- Icon Properties
		if frame.icon then
			frame.icon:SetTexCoord(0 + inputs.zoom, 1 - inputs.zoom, 0 + inputs.zoom, 1 - inputs.zoom)
			if isPlaceholder or inputs.iconTexture then
				if frame.ClearIcon then frame:ClearIcon() end
				frame.icon:SetTexture(inputs.iconTexture)
			else
				if frame.SetIcon then frame:SetIcon(frame.icon) end
			end
			frame.icon:SetVertexColor(inputs.color.r, inputs.color.g, inputs.color.b, trackerValue.iconSettings.iconDisplayState == 'never' and 0 or inputs.color.a)
			frame.icon:SetDesaturated(false)
		end
		
		-- Cooldown Properties
		if frame.cooldown then
			frame.cooldown:SetDrawEdge(inputs.drawSweep)
			frame.cooldown:SetDrawSwipe(inputs.drawSweep)
			frame.cooldown:SetDrawBling(inputs.drawBling)
			frame.cooldown:SetHideCountdownNumbers(not inputs.displayCooldownText)
			
			-- Update cooldown text if it should be displayed
			if inputs.displayCooldownText then
				local cdText = frame.cooldown.Text or frame.cooldown.text
				if not cdText then
					for i = 1, frame.cooldown:GetNumRegions() do
						local region = select(i, frame.cooldown:GetRegions())
						if region and region:GetObjectType() == "FontString" then
							cdText = region
							break
						end
					end
				end
				
				if cdText then
					local fontPath, _, fontFlags = cdText:GetFont()
					local resolvedFontPath = State:ResolveFontPath(inputs.cooldownTextFont, fontPath)
					local resolvedFontFlags = State:ResolveFontFlags(inputs.cooldownTextFontFlags, fontFlags)
					cdText:SetFont(resolvedFontPath, inputs.cooldownTextSize, resolvedFontFlags or "OUTLINE")
					cdText:ClearAllPoints()
					cdText:SetPoint("CENTER", frame.cooldown, "CENTER", inputs.cooldownTextX, inputs.cooldownTextY)
				end
			end
		end

		-- Status Bar Properties
		local function updateStatusBar(barFrame, config)
			if barFrame and trackerValue.isEnabled and trackerValue.auraSpecs[currentSpecID] then
				if isPlaceholder then
					barFrame:Show()
				end
				barFrame:ClearAllPoints()
				barFrame:SetPoint(config.anchorSelf or "LEFT", frame, config.anchorParent or "RIGHT", config.x or 0, config.y or 0)
				barFrame:SetSize(config.width, config.height)
				barFrame:SetScale(config.scale or 1)

				if config.displayState == 'never' then
					if isPlaceholder then barFrame:SetValue(0) end
					barFrame:SetStatusBarColor(0, 0, 0, 0)
				else
					barFrame:SetStatusBarColor(
						config.color.r or 0.2,
						config.color.g or 0.8,
						config.color.b or 1,
						config.color.a or 1
					)
					if isPlaceholder then  barFrame:SetValue(1) end
				end

				if frame.SetApplicationBar then
					frame:SetApplicationBar(barFrame, {
						maxApplications = config.maxValue or 4,  -- Adjust based on buff max stacks
						interpolation = Enum.StatusBarInterpolation.Smooth
					})
				end

				local barTexture = (config.customBarTexture and config.customBarTexture ~= "")
					and config.customBarTexture
					or config.defaultBarTexture
				if barTexture then 
					barFrame:SetStatusBarTexture(barTexture)
				end
				barFrame:SetReverseFill(false)
				barFrame:SetOrientation(
					(config.barOrientation == 'vertical') and "VERTICAL" or "HORIZONTAL"
				)
			else
				if isPlaceholder then
					barFrame:Hide()
				end
			end
		end
		
		-- Update duration bar if configured
		local barConfig = trackerValue['statusBar']
		if barConfig and frame.durationBar then
			updateStatusBar(frame.durationBar, barConfig)
		end
		
		-- Update charge bar if configured
		local chargeBarConfig = trackerValue['visualChargeBar']
		if chargeBarConfig and frame.chargeBar then
			updateStatusBar(frame.chargeBar, chargeBarConfig)
		end

		-- Update spell charge text
		local countOffX = (inputs.countText.x or 0) - 2
		local countOffY = (inputs.countText.y or 0) + 2
		frame.count:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", countOffX, countOffY)
		frame.count:SetJustifyH("RIGHT")
		frame.count:SetDrawLayer("OVERLAY", 7)
		
		local _fontPath, _, _fontFlags = frame.count:GetFont()
		local fontPath = SpellStyler.State:ResolveFontPath(inputs.countText.font, _fontPath)
		local fontFlags = SpellStyler.State:ResolveFontFlags(inputs.countText.fontFlags, _fontFlags)
		frame.count:SetFont(fontPath, inputs.countText.size, fontFlags or "OUTLINE")
		if inputs.countText and inputs.countText.color and frame.count then
			frame.count:SetTextColor(
				inputs.countText.color.r or 1,
				inputs.countText.color.g or 1,
				inputs.countText.color.b or 1,
				inputs.countText.display and (inputs.countText.color.a or 1) or 0
			)
		end
	end
	
	update(aura.slotFrame, false)
	update(aura.placeHolder, true)
	aura.auraContainer:UpdateAllAuras()
end
-- ============================================================================
-- BUFF FRAME HIGHLIGHT
-- Briefly highlight a buff frame (like glow on spell/item icons)
-- ============================================================================
function BuffManager:BrieflyHighlightBuff(baseSpellID)
    local container = BuffManager.buffContainers[baseSpellID]
    if not container or not container.placeHolder then return end
    
    local f = container.placeHolder
    if not f.glowFrame then return end
    
    local duration = 2
    local fadeIn = 0.5
    local fadeOut = 0.5
    
    -- Ensure glowFrame covers the frame
    if f.glowFrame.SetAllPoints then
        f.glowFrame:SetAllPoints(f)
    end
    
    -- Size the glow elements to be proportional to the icon size
    local width = 48
    if f.icon and f.icon.GetWidth then
        width = f.icon:GetWidth() or width
    elseif f.GetWidth then
        width = f:GetWidth() or width
    end
    local offset = 0
    pcall(function() offset = math.max(8, math.floor(width * 0.22)) end)
    
    -- Anchor glow textures to the glowFrame so they can extend outward
    if f.glowTexture then
        f.glowTexture:ClearAllPoints()
        f.glowTexture:SetPoint("TOPLEFT", f.glowFrame, "TOPLEFT", -offset, offset)
        f.glowTexture:SetPoint("BOTTOMRIGHT", f.glowFrame, "BOTTOMRIGHT", offset, -offset)
    end
    if f.glowAnts then
        local antsOffset = math.max(4, math.floor(offset * 0.5))
        f.glowAnts:ClearAllPoints()
        f.glowAnts:SetPoint("TOPLEFT", f.glowFrame, "TOPLEFT", -antsOffset, antsOffset)
        f.glowAnts:SetPoint("BOTTOMRIGHT", f.glowFrame, "BOTTOMRIGHT", antsOffset, -antsOffset)
    end
    
    if f.glowFrame then
        f.glowFrame:SetAlpha(0)
        f.glowFrame:Show()
        if UIFrameFadeIn then
            UIFrameFadeIn(f.glowFrame, fadeIn, 0, 1)
        else
            f.glowFrame:SetAlpha(1)
        end
    end
    
    if f.glowAnim and f.glowAnim.Play then
        f.glowAnim:Play()
    end
    
    C_Timer.After(duration - fadeOut, function()
        if f.glowAnim and f.glowAnim.Stop then f.glowAnim:Stop() end
        if f.glowFrame then
            if UIFrameFadeOut then
                UIFrameFadeOut(f.glowFrame, fadeOut, f.glowFrame:GetAlpha() or 1, 0)
                C_Timer.After(fadeOut, function()
                    if f.glowFrame then f.glowFrame:Hide() end
                end)
            else
                f.glowFrame:Hide()
            end
        end
    end)
end

-- ============================================================================
-- BUFF MOCK COOLDOWN
-- Toggle mock cooldown on placeholder for testing (settings menu only)
-- ============================================================================
function BuffManager:ToggleMockCooldown(baseSpellID)
    local container = BuffManager.buffContainers[baseSpellID]
    if not container or not container.placeHolder then return end
    
    local placeHolder = container.placeHolder
    
    -- Check if mock cooldown is currently active
    local isMockActive = placeHolder.meta and placeHolder.meta.mockCooldownActive or false
    
    if isMockActive then
        -- Disable mock cooldown
        placeHolder.meta.mockCooldownActive = false
        
        -- Clear cooldown from placeholder
        if placeHolder.cooldown then
            placeHolder.cooldown:Clear()
        end
        
        -- Clear duration bar
        if placeHolder.durationBar then
            placeHolder.durationBar:SetValue(0)
        end
    else
        -- Enable mock cooldown (15 second duration)
        placeHolder.meta.mockCooldownActive = true
        
        local mockDuration = 15
        local now = GetTime()
        
        -- Apply cooldown to placeholder's cooldown frame
        if placeHolder.cooldown then
            placeHolder.cooldown:SetCooldown(now, mockDuration)
        end
        
        -- Apply duration to placeholder's duration bar
        if placeHolder.durationBar then
            placeHolder.durationBar:SetMinMaxValues(0, mockDuration)
            placeHolder.durationBar:SetValue(mockDuration)
            
            -- Animate the bar countdown
            local startTime = now
            local function updateBar()
                if not placeHolder.meta.mockCooldownActive then return end
                
                local elapsed = GetTime() - startTime
                local remaining = math.max(0, mockDuration - elapsed)
                
                if placeHolder.durationBar then
                    placeHolder.durationBar:SetValue(remaining)
                end
                
                if remaining > 0 then
                    C_Timer.After(0.05, updateBar)
                else
                    placeHolder.meta.mockCooldownActive = false
                end
            end
            updateBar()
        end
    end
    
    return not isMockActive  -- Return new state
end

-- ============================================================================
-- BUFF INTERACTION HANDLERS
-- Buffs now use the same EnableDraggingForSpecificFrame/DisableDraggingForSpecificFrame
-- methods as spells and items for consistency (via EnablePlaceholderDragging).
-- ============================================================================

-- ============================================================================
-- PLACEHOLDER VISIBILITY AND DRAGGING CONTROL
-- Enable/disable dragging on buff placeholders (for settings menu)
-- Uses IconSettingsRenderer methods for consistency with spells/items
-- ============================================================================
function BuffManager:EnablePlaceholderDragging(enable)
	local currentSpecID = SpellStyler.State:GetCurrentSpecID()
    for baseSpellID, containerData in pairs(BuffManager.buffContainers) do
        if containerData.placeHolder then
            containerData.placeHolder._draggingEnabled = enable
			local trackerValue = SpellStyler.State:GetSpecificTrackerValue(baseSpellID, 'buffs')
            if enable and trackerValue.isEnabled and trackerValue.auraSpecs[currentSpecID] then
                -- Show placeholder when enabling
                containerData.placeHolder:Show()
                
                -- Check if dragging is disabled in settings
                local isDraggingDisabled = SpellStyler.State:GetTrackerValueConfigProperty(baseSpellID, 'buffs', 'iconSettings.disableDragging')
                if not isDraggingDisabled then
                    -- Use the same dragging system as spells/items
                    SpellStyler.IconSettingsRenderer:EnableDraggingForSpecificFrame(containerData.placeHolder)
                end
            else
                -- Disable dragging first
                SpellStyler.IconSettingsRenderer:DisableDraggingForSpecificFrame(containerData.placeHolder)
                
                -- Then hide placeholder when disabling
                containerData.placeHolder:Hide()
            end
        end
    end
end

-- ============================================================================
-- BUFF CONTAINER CLEANUP
-- Destroys all buff containers and slots
-- ============================================================================
local function DestroyBuffContainers()
    for baseSpellID, container in pairs(BuffManager.buffContainers) do
        if container then
            container:Hide()
            container:SetParent(nil)
        end
    end
    
    BuffManager.buffContainers = {}
    BuffManager.buffSlots = {}
end

-- ============================================================================
-- BUFF SETUP METHOD
-- Public method to setup buffs (triggered by keybind)
-- ============================================================================
function BuffManager:SetupBuffs()
    
    -- Recreate containers
    -- DestroyBuffContainers()
    CreateBuffContainers()
end


function BuffManager:DisableAllAuras()
	for baseSpellID, containerData in pairs(BuffManager.buffContainers) do
        if containerData.auraContainer then
			containerData.auraContainer:SetEnabled(false)
			containerData.placeHolder:Hide()
        end
    end
end
function BuffManager:EnableAllAuras()
	for baseSpellID, containerData in pairs(BuffManager.buffContainers) do
        if containerData.auraContainer then
			local trackerValue = SpellStyler.State:GetSpecificTrackerValue(baseSpellID, 'buffs')
			BuffManager:UpdateAura(containerData, trackerValue)
        end
    end
end


-- ============================================================================
-- REFRESH ALL BUFF AURAS
-- Calls UpdateAllAuras on all buff containers to refresh displayed buffs
-- ============================================================================
function BuffManager:RefreshAllBuffAuras(auraUnitType, auraUnitIdentifier)
    for baseSpellID, containerData in pairs(BuffManager.buffContainers) do
        if containerData.auraContainer then
			local shouldUpdateHarmfulTargetAuras = auraUnitType ~= nil and auraUnitIdentifier ~= nil and containerData.auraType == auraUnitType and containerData.unitToTrack == auraUnitIdentifier
			local shouldUpdateAll = auraUnitType == nil or auraUnitIdentifier == nil
			if shouldUpdateHarmfulTargetAuras or shouldUpdateAll then
            	containerData.auraContainer:UpdateAllAuras()
			end
        end
    end
end

-- ============================================================================
-- EVENT FRAME
-- Handles game events for buff management
-- ============================================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_UNGHOST")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
eventFrame:RegisterEvent("UNIT_EXITING_VEHICLE")
eventFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
eventFrame:RegisterEvent("UNIT_ENTERING_VEHICLE")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")


local hasPlayerEnteredWorld = false

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        hasPlayerEnteredWorld = true
        CreateBuffContainers()
        -- Refresh auras after containers are created
        C_Timer.After(0.5, function()
            BuffManager:RefreshAllBuffAuras()
        end)
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" then
        -- Refresh when changing zones
        if hasPlayerEnteredWorld then
            BuffManager:RefreshAllBuffAuras()
        end
	elseif event == "PLAYER_DEAD"
		or event == "UNIT_ENTERING_VEHICLE"
		or event == "UNIT_ENTERED_VEHICLE" then
		if hasPlayerEnteredWorld then
            BuffManager:DisableAllAuras()
        end
    elseif
		event == "UNIT_EXITING_VEHICLE"
		or event == "PLAYER_ENTERING_WORLD"
		or event == "ZONE_CHANGED_NEW_AREA"
		or event == "UNIT_EXITED_VEHICLE"
		or event == "PLAYER_ALIVE"
		or event == "PLAYER_UNGHOST" then
        -- Refresh when dying or resurrecting
        if hasPlayerEnteredWorld then
			BuffManager:EnableAllAuras()
            BuffManager:RefreshAllBuffAuras()
        end
	elseif event == "PLAYER_TARGET_CHANGED" then
		BuffManager:RefreshAllBuffAuras(AuraUtil.AuraFilters.Harmful, 'target')
    end
end)

-- ============================================================================
-- KEYBIND HANDLER
-- Shift+Ctrl+X to trigger buff setup
-- ============================================================================
pcall(function()
    local keybindFrame = CreateFrame("Frame")
    keybindFrame:SetPropagateKeyboardInput(true)
    keybindFrame:RegisterEvent("PLAYER_LOGIN")
    
    keybindFrame:SetScript("OnEvent", function()
        keybindFrame:SetScript("OnKeyDown", function(self, key)
            if key == "X" and IsShiftKeyDown() and IsControlKeyDown() then
                BuffManager:SetupBuffs()
            end
        end)
    end)
end)
