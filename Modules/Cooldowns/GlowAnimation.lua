

------------------------------------------------------------------------
-- GlowUtil
-- Utility for attaching glow animations to any frame.
--
-- USAGE (two-step):
--   1. Call Setup once when the frame is created / spell config changes.
--      This attaches the hidden glow child and applies colour/size.
--   2. Call Play whenever you want the animation to run.
--      Pass an optional duration (seconds); omit to loop indefinitely.
--
-- config keys shared by both Setup functions:
--   r, g, b        vertex colour  (default 1, 1, 1)
--   desaturated    boolean        (default false)
--   scale          size multiplier relative to frame width (default 1.85)
------------------------------------------------------------------------

local addonName, SpellStyler = ...
SpellStyler.GlowUtil = SpellStyler.GlowUtil or {}
local GlowUtil = SpellStyler.GlowUtil


-- ── Marching-ants (flipbook ring) ────────────────────────────────────

--- Attach a marching-ants glow to `frame`.  Call once; re-call to
--- reconfigure colour/scale (the old child is replaced).
function GlowUtil:SetupAnts(frame, config)
    config = config or {}
    local scale = config.scale or 1.85
    local w, h  = frame:GetWidth(), frame:GetHeight()

    -- Remove any previous instance
    if frame._antsGlow then frame._antsGlow:Hide() end

    local holder = CreateFrame("Frame", nil, frame)
    holder:SetPoint("CENTER")
    holder:SetSize(w, h)
    holder:SetFrameLevel(frame:GetFrameLevel() + 4)

    local flip = holder:CreateTexture(nil, "OVERLAY")
    holder.Flipbook = flip
    flip:SetAtlas("rotationhelper_ants_flipbook")
    flip:SetSize(w * scale, h * scale)
    flip:SetPoint("CENTER")
    -- Desaturate by default so vertex color is applied against neutral grey,
    -- not the blue tones baked into the atlas art. Pass desaturated=false
    -- explicitly if you want the raw atlas colour instead.
    -- local desat = (config.desaturated ~= nil) and config.desaturated or true
    flip:SetDesaturated(true)
    flip:SetVertexColor(config.r or 1, config.g or 1, config.b or 1, 1)

    local ag = flip:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    flip.Anim = ag

    local fa = ag:CreateAnimation("FlipBook")
    fa:SetDuration(1)   fa:SetOrder(0)
    fa:SetFlipBookRows(6)   fa:SetFlipBookColumns(5)   fa:SetFlipBookFrames(30)
    fa:SetFlipBookFrameWidth(0)   fa:SetFlipBookFrameHeight(0)

    holder:Hide()
    frame._antsGlow = holder
end

--- Start the ants animation.  `duration` (seconds) is optional;
--- omit it to loop until StopAnts is called.
function GlowUtil:PlayAnts(frame, duration)
    local holder = frame._antsGlow
    if not holder then return end
    holder:Show()
    holder.Flipbook.Anim:Play()
    if duration then
        C_Timer.After(duration, function() GlowUtil:StopAnts(frame) end)
    end
end

--- Stop and hide the ants animation.
function GlowUtil:StopAnts(frame)
    local holder = frame._antsGlow
    if not holder then return end
    holder.Flipbook.Anim:Stop()
    holder:Hide()
end

-- ── Proc-loop (radial halo flipbook) ─────────────────────────────────

--- Attach a proc-glow halo to `frame`.  Call once; re-call to
--- reconfigure colour/scale (the old child is replaced).
function GlowUtil:SetupProcGlow(frame, config)
    config = config or {}
    local scale = config.scale or 1.85
    local w, h  = frame:GetWidth(), frame:GetHeight()

    -- Remove any previous instance
    if frame._procGlow then frame._procGlow:Hide() end

    local holder = CreateFrame("Frame", "proc_glow_frame_holder", frame)
    holder:SetPoint("CENTER")
    holder:SetSize(w * scale, h * scale)
    holder:SetFrameLevel(frame:GetFrameLevel() + 5)
    holder.meta = {
        config = config
    }

    local tex = holder:CreateTexture("proc_glow_texture", "OVERLAY")
    holder.ProcLoopFlipbook = tex
    tex:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
    tex:SetAllPoints(holder)
    -- Desaturate by default so vertex color is applied against neutral grey,
    -- not the yellow tones baked into the atlas art. Pass desaturated=false
    -- explicitly if you want the raw atlas colour instead.
    tex:SetDesaturated(true)
    tex:SetVertexColor(config.r or 1, config.g or 1, config.b or 1, config.a or 1)

    local ag = tex:CreateAnimationGroup("proc_glow_animation_group")
    ag:SetLooping("REPEAT")
    holder.ProcLoop = ag

    local aa = ag:CreateAnimation("Alpha", "proc_glow_alpha")
    aa:SetDuration(0.001)   aa:SetOrder(0)
    aa:SetFromAlpha(1)      aa:SetToAlpha(1)

    local af = ag:CreateAnimation("FlipBook", "proc_glow_alpha")
    af:SetChildKey("ProcLoopFlipbook")
    af:SetDuration(1)   af:SetOrder(0)
    af:SetFlipBookRows(6)   af:SetFlipBookColumns(5)   af:SetFlipBookFrames(30)
    af:SetFlipBookFrameWidth(0)   af:SetFlipBookFrameHeight(0)

    holder:SetScript("OnHide", function()
        if holder.ProcLoop:IsPlaying() then holder.ProcLoop:Stop() end
    end)

    holder:Hide()
    frame._procGlow = holder
end

--- Start the proc-glow animation.  `duration` (seconds) is optional;
--- omit it to loop until StopProcGlow is called.
function GlowUtil:PlayProcGlow(frame, duration, overrideColor)
    local holder = frame._procGlow
    if not holder then return end
    holder:SetAlpha(overrideColor and overrideColor.a or holder.meta.config.a)
    if overrideColor then
        holder.ProcLoopFlipbook:SetVertexColor(overrideColor.r, overrideColor.g, overrideColor.b)
    end
    holder:Show()
    holder.ProcLoop:Play()
    pcall(function()
        if duration then
            C_Timer.After(duration, function() GlowUtil:StopProcGlow(frame) end)
        end
    end)
end

--- Stop and hide the proc-glow animation.
function GlowUtil:StopProcGlow(frame)
    local holder = frame._procGlow
    if not holder then return end
    holder.ProcLoop:Stop()
    holder:Hide()
end
