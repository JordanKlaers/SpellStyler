local addonName, SpellStyler = ...
SpellStyler.Util = SpellStyler.Util or {}
local Util = SpellStyler.Util

function Util:IsValidCooldownCurve()
    --dummy GCD spell is never secret
    local GCD = C_Spell.GetSpellCooldown(61304)
    --should we use :GetSpellCooldownDuration() instead?

    local C = C_CurveUtil.CreateCurve()
    C:SetType(Enum.LuaCurveType.Step)
    C:AddPoint(0, 1)
    --anything greater than 0 should fail (:GetRemainingDuration() seems to return x.nnn values so we assume? the comparisson is also limited to ms.)
    C:AddPoint(.0001, 0)

    --duration > 0 means GCD is in effect
    if(GCD.duration > 0) then
        local gt = math.floor(((GCD.startTime + GCD.duration) - GetTime())*1000 + .5)/1000

        --to allow for slight deviation we map GCD+-.001 to true
        if(gt > .001) then
            C:AddPoint(gt-.001, 1)
        else
            C:AddPoint(gt, 1)
        end
        C:AddPoint(gt+.001, 1)
        C:AddPoint(gt+.0011, 0)
    end

    return C
end