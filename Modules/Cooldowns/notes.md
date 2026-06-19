CreateFrame("Button", data.frameName, UIParent, "BackdropTemplate")
	frame:SetSize [SA: AllowedWhenUntainted]
	frame:SetFrameStrata [SA: NotAllowed]
	frame:SetFrameLevel [SA: AllowedWhenTainted]
	frame:SetMovable
	frame:SetClampedToScreen
	frame:EnableMouse
	frame:GetFrameLevel
	frame:SetPoint [SA: AllowedWhenUntainted]
	frame:Show [SA: AllowedWhenTainted]
	frame:Hide [SA: AllowedWhenTainted]
	frame:ClearAllPoints [SA: AllowedWhenUntainted]
	frame:GetName
	frame:SetScale [SA: AllowedWhenUntainted]
	frame:SetAlpha [SA: AllowedWhenTainted]
	frame:SetScript
	frame:CreateTexture
	frame:CreateFontString
	frame:SetParent

CreateFrame('Frame', 'iconContainer_' .. data.frame.meta.activeSpellID, data.frame)
	iconContainer:SetAllPoints [SA: AllowedWhenUntainted]
	iconContainer:SetFrameLevel [SA: AllowedWhenTainted]
	iconContainer:SetSize [SA: AllowedWhenUntainted]
	iconContainer:SetPoint [SA: AllowedWhenUntainted]
	iconContainer:Show [SA: AllowedWhenTainted]
	iconContainer:Hide [SA: AllowedWhenTainted]
	iconContainer:SetAlpha [SA: AllowedWhenTainted]
	iconContainer:CreateTexture
	iconContainer:CreateAnimationGroup
	iconContainer:GetNumRegions
	iconContainer:GetRegions

iconContainer:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints [SA: AllowedWhenUntainted]
	icon:SetTexCoord [SA: AllowedWhenUntainted]
	icon:SetSize [SA: AllowedWhenUntainted]
	icon:SetTexture [SA: AllowedWhenTainted]
	icon:SetRotation [SA: AllowedWhenTainted]
	icon:SetVertexColor [SA: AllowedWhenTainted]
	icon:SetScale [SA: AllowedWhenUntainted]
	icon:SetHeight [SA: AllowedWhenUntainted]
	icon:SetWidth [SA: AllowedWhenUntainted]
	icon:Show [SA: AllowedWhenTainted]
	icon:Hide [SA: AllowedWhenTainted]
	icon:SetDrawLayer
	icon:SetBlendMode
	icon:SetDesaturated [SA: AllowedWhenTainted]
	icon:GetTexture
	icon:CreateAnimationGroup

CreateFrame("StatusBar", statusBarName, frame)
	statusBar:SetPoint [SA: AllowedWhenUntainted]
	statusBar:SetSize [SA: AllowedWhenUntainted]
	statusBar:SetScale [SA: AllowedWhenUntainted]
	statusBar:SetMinMaxValues [SA: AllowedWhenTainted]
	statusBar:SetValue [SA: AllowedWhenTainted]
	statusBar:SetFrameStrata [SA: NotAllowed]
	statusBar:SetFrameLevel [SA: AllowedWhenTainted]
	statusBar:SetStatusBarColor [SA: AllowedWhenTainted]
	statusBar:GetStatusBarTexture
	statusBar:SetStatusBarTexture [SA: AllowedWhenTainted]
	statusBar:SetReverseFill
	statusBar:SetOrientation
	statusBar:Show [SA: AllowedWhenTainted]
	statusBar:Hide [SA: AllowedWhenTainted]
	statusBar:ClearAllPoints [SA: AllowedWhenUntainted]
	statusBar:SetAlpha [SA: AllowedWhenTainted]
	statusBar:SetTimerDuration [SA: AllowedWhenUntainted]
	statusBar:RotateTextures
	statusBar:SetFillStyle

CreateFrame("Cooldown", data.frameName .. "_Cooldown", data.frame, "CooldownFrameTemplate")
	cooldown:SetAllPoints [SA: AllowedWhenUntainted]
	cooldown:SetFrameLevel [SA: AllowedWhenTainted]
	cooldown:SetDrawEdge
	cooldown:SetDrawBling
	cooldown:SetSwipeColor [SA: AllowedWhenTainted]
	cooldown:SetDrawSwipe
	cooldown:SetHideCountdownNumbers
	cooldown:SetScript
	cooldown:Show [SA: AllowedWhenTainted]
	cooldown:Hide [SA: AllowedWhenTainted]
	cooldown:Clear
	cooldown:SetCooldownFromDurationObject [SA: AllowedWhenUntainted]
	cooldown:SetEdgeScale
	cooldown:SetAlpha [SA: AllowedWhenTainted]

frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	fontString:SetPoint [SA: AllowedWhenUntainted]
	fontString:SetJustifyH
	fontString:SetDrawLayer
	fontString:GetFont
	fontString:SetFont [SA: AllowedWhenUntainted]
	fontString:SetTextColor [SA: AllowedWhenTainted]
	fontString:SetText [SA: AllowedWhenTainted]
	fontString:Show [SA: AllowedWhenTainted]
	fontString:Hide [SA: AllowedWhenTainted]
	fontString:SetShadowOffset [SA: AllowedWhenUntainted]
	fontString:SetShadowColor [SA: AllowedWhenTainted]
	fontString:SetAlpha [SA: AllowedWhenTainted]
	fontString:ClearAllPoints [SA: AllowedWhenUntainted]

glowAnts:CreateAnimationGroup()
	animGroup:SetLooping
	animGroup:CreateAnimation

animGroup:CreateAnimation("Rotation")
	animation:SetDegrees [SA: AllowedWhenTainted]
	animation:SetDuration [SA: AllowedWhenUntainted]

eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
	eventFrame:SetScript

UIParent:GetEffectiveScale
UIParent:GetCenter
UIParent:GetRect

### Tracked Entry Property to WoW API Mapping

| Category | Config Property | Frame API Method | SecretArguments (SA) | Note |
| :--- | :--- | :--- | :--- | :--- |
| **Root** | `scale` | `frame:SetScale` | **AllowedWhenUntainted** | Global tracker scale. |
| | `position.x`, `y` | `frame:SetPoint` | **AllowedWhenUntainted** | Relative position offsets. |
| | `position.anchorPoint`| `frame:SetPoint` | **AllowedWhenUntainted** | Anchor point string. |
| **Icon** | `iconSettings.opacity`| `frame:SetAlpha` | AllowedWhenTainted | Overall frame transparency. |
| | `iconSettings.width` / `height`| `frame:SetSize` | **AllowedWhenUntainted** | Precise pixel dimensions. |
| | `iconSettings.frameStrataLevel`| `frame:SetFrameStrata` | **NotAllowed** | Global UI layer (e.g., MEDIUM). |
| | `iconSettings.frameStrataValue`| `frame:SetFrameLevel` | AllowedWhenTainted | Sub-layer within the strata. |
| | `iconSettings.iconTexturePath` | `icon:SetTexture` | AllowedWhenTainted | Custom icon override. |
| | `iconSettings.zoom` | `icon:SetTexCoord` | **AllowedWhenUntainted** | Edge cropping percentages. |
| | `iconSettings.desaturated` | `icon:SetDesaturated` | AllowedWhenTainted | Grayscale toggle. |
| | `iconColor.r`, `g`, `b` | `icon:SetVertexColor` | AllowedWhenTainted | Tinting the icon. |
| | `iconColor.a` | `iconContainer:SetAlpha` | AllowedWhenTainted | Icon-only transparency. |
| | `iconSettings.hideDefaultSweep`| `cooldown:SetDrawSwipe` | N/A | Toggles radial sweep visibility. |
| | `iconSettings.hideCooldownBling`| `cooldown:SetEdgeScale` | N/A | Scale of the cooldown flash. |
| | `iconSettings.borderSize` | `borderFrame:SetSize` | **AllowedWhenUntainted** | Outer border thickness. |
| | `iconSettings.borderColor` | `borderFrame:SetBackdropBorderColor` | AllowedWhenTainted | Outer border color. |
| **Bars** | `statusBar.displayState` | `statusBar:Show` / `Hide` | AllowedWhenTainted | Toggles bar visibility. |
| (Applies to | `statusBar.width` / `height` | `statusBar:SetSize` | **AllowedWhenUntainted** | Bar pixel dimensions. |
| `statusBar`, | `statusBar.color` | `statusBar:SetStatusBarColor` | AllowedWhenTainted | Fill color. |
| `visualChargeBar`,| `statusBar.customBarTexture` | `statusBar:SetStatusBarTexture` | AllowedWhenTainted | Fill texture. |
| `totemBar`) | `statusBar.barOrientation` | `statusBar:SetOrientation` | N/A | Horizontal vs Vertical. |
| | `statusBar.rotation` | `statusBar:SetRotation` | AllowedWhenTainted | Rotating the bar texture. |
| | `statusBar.backgroundColor` | `bgTexture:SetVertexColor` | AllowedWhenTainted | Empty bar color. |
| | `statusBar.glowColor` | `glowTexture:SetVertexColor` | AllowedWhenTainted | Edge glow color/alpha. |
| | `statusBar.borderColor` | `borderPieces:SetVertexColor` | AllowedWhenTainted | Multi-piece border tinting. |
| | `statusBar.borderScale` | `borderPieces:SetScale` | **AllowedWhenUntainted** | Thickness of the piece-border. |
| | `statusBar.x`, `y` | `statusBar:SetPoint` | **AllowedWhenUntainted** | Position relative to icon. |
| | `statusBar.duration` (Live) | `statusBar:SetTimerDuration` | **AllowedWhenUntainted** | **CRITICAL:** Real-time countdown. |
| **Charges** | `visualChargeBar.minValue` / `maxValue` | `statusBar:SetMinMaxValues` | AllowedWhenTainted | Defines charge thresholds. |
| | `chargeBasedDisplay.chargeValue` (Live) | `anchorBar:SetValue` | AllowedWhenTainted | Input for secret charge count. |
| | `countText.display` | `count:Show` / `Hide` | AllowedWhenTainted | Numerical count visibility. |
| | `countText.color` | `count:SetTextColor` | AllowedWhenTainted | Stack/Charge text color. |
| | `countText.size` | `count:SetFont` | **AllowedWhenUntainted** | Number font size. |
| **Text** | `customLabel.text` | `customLabel:SetText` | AllowedWhenTainted | Custom user text. |
| | `customLabel.font` | `customLabel:SetFont` | **AllowedWhenUntainted** | Font file selection. |
| | `customLabel.color` | `customLabel:SetTextColor` | AllowedWhenTainted | Label color. |
| | `cooldownText.display` | `cooldown:SetHideCountdownNumbers` | N/A | Blizzard numerical sweep. |
| | `cooldownText.color` | `cdText:SetTextColor` | AllowedWhenTainted | Countdown text color. |
| **Misc** | `glowNotification.shouldDisplay` | `glowFrame:Show` / `Hide` | AllowedWhenTainted | Proc notification visibility. |
| | `itemID` | `C_Item.GetItemCooldown` | **AllowedWhenUntainted** | Duration object generation. |
