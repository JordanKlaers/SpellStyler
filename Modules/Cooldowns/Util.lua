local addonName, SpellStyler = ...
SpellStyler.Util = SpellStyler.Util or {}
local Util = SpellStyler.Util

--[[
	If the comparison duration == the GCD duration AND inverse == false, the result would be 1
	If the comparison duration ~= the GCD duration AND inverse == false, the result would be 0

	inverse == true just swaps whats said above
]]
function Util:IsValidCooldownCurve(inverse)
    --dummy GCD spell is never secret
    local GCD = C_Spell.GetSpellCooldown(61304)
    --should we use :GetSpellCooldownDuration() instead?

    local inGCD  = inverse and 0 or 1
    local outGCD = inverse and 1 or 0

    local C = C_CurveUtil.CreateCurve()
    C:SetType(Enum.LuaCurveType.Step)
    C:AddPoint(0, inGCD)
    --anything greater than 0 should fail (:GetRemainingDuration() seems to return x.nnn values so we assume? the comparisson is also limited to ms.)
    C:AddPoint(.0001, outGCD)

    --duration > 0 means GCD is in effect
    if(GCD.duration > 0) then
        local gt = math.floor(((GCD.startTime + GCD.duration) - GetTime())*1000 + .5)/1000

        --to allow for slight deviation we map GCD+-.001 to true
        if(gt > .001) then
            C:AddPoint(gt-.001, inGCD)
        else
            C:AddPoint(gt, inGCD)
        end
        C:AddPoint(gt+.001, inGCD)
        C:AddPoint(gt+.0011, outGCD)
    end

    return C
end

--[[
    If duration == 0 AND inverse == false → returns 1  (spell available)
    If duration  > 0 AND inverse == false → returns 0  (spell on cooldown)

    inverse == true swaps the above:
    If duration == 0 → returns 0
    If duration  > 0 → returns 1
]]
function Util:IsZeroDurationCurve(inverse)
    local onZero    = inverse and 0 or 1
    local onNonZero = inverse and 1 or 0

    local C = C_CurveUtil.CreateCurve()
    C:SetType(Enum.LuaCurveType.Step)
    C:AddPoint(0, onZero)
    C:AddPoint(.0001, onNonZero)
    return C
end