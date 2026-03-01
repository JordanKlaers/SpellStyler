# SpellStyler Changelog

## [Unreleased] - 2026-02-25

Version 0.1.0

Slightly less technical summary:
	- Channeled spells, spells with charges, and off GCD spells should apply cooldown more consistently/correctly.
	- A setting has been added in Icon Settings to flag a spell as off GCD. Please ensure you flag both channeled spells and off gcd spells for correct perforamcne. I have not found a way but Ill double check if that can be identified automatically.

Slightly more technical summary:
- `SPELL_UPDATE_COOLDOWN` no longer fires incorrectly during channeled spells.
- 'SPELL_UPDATE_COOLDOWN' was used to pull spell data for handling when to show the cooldown (helpful for ignoring GCD). Channeled spells are abled to pull data from UnitChannelInfo to the star and stop channeling events are more reliable for displaying cooldowns there. Additionally, channeled spells no longer allow cooldown data to be applied to anything while channeling. This helped resolve 0 duration cooldown data added to random spells. Additionally, 'SPELL_UPDATE_COOLDOWN' events are ignored during channeling for the same reason.
- Spells that are inherently off the GCD (self-buff procs, etc.) now correctly trigger a real cooldown display. Previously, `isOnGCD == nil` was mishandled and these spells could be ignored.
- A setting has been added in Icon Settings to flag a spell as off GCD. Check this for spells that bypass the GCD (e.g. self-buff procs). The spell will be pre-cached as off-GCD from load, so the first cast is tracked correctly without needing to observe it first.

- Channeled spells are handled via "UNIT_SPELLCAST_CHANNEL_STOP" and "UNIT_SPELLCAST_CHANNEL_START". They block all other responses to cooldown handling if not the spell being channeled.
- Spells with charges successfully display cooldown data for each charge because "GetSpellChargeDuration" only returns an object in the "SetCooldown" hook when a charge is on cooldown. That plus, leveraging the "onCooldownDone" callback from a ghost frame using the same cooldown duration and "UNIT_SPELLCAST_CHANNEL_STOP" only firing when the last available charge is spent, will help track if the spell has zero or more charges. This enables the spell to have display in an "available" state, while also displaying the cooldown information.
- Spell off the GCD require the setting to flag them, as well as explicitly looking for nil from "C_Spell.GetSpellCooldown(spellID).isOnGCD" in "SPELL_UPDATE_COOLDOWN". This paired with channeled spells blocking the handling/events ensures that off the gcd spells will still respond correctly when displaying their cooldown information.


Version 0.1.1

Slightly less technical summary:
	Spells with charges should not display the cooldown swipe for GCDs

Slightly more technical summary:
	Updates the spell charge tracking to use the duration object instead of the "start" and "duration" from the hook. This helps ignore GCD because C_Spell.GetSpellChargeDuration(uniqueID) does not account for GCD.

Version 0.1.2
	- fixes issue with the show hide automatiocally depending on combat, for the settings menu

Version 0.2.0

Slightly less techincal summary:
	- Spells that turn into other spells, and spells that reduce the cooldown of spells should now update correctly.
	- settings only require manually flagging off gcd spells. Previous settings that have been removed are now auto detected.

Slightly more technical summary:
	- Only buffs are hooked into the cooldown manager now. All other spells use "SPELL_UPDATE_COOLDOWN", and "UNIT_SPELLCAST_SUCCEEDED" to process all spell tracking.
	- "SPELL_UPDATE_ICON" uses a match on base spell id to process tracking cooldowns for spells that turn into other spells (like avenging crusader into crusader strike)

Version 0.2.1

Slightly less techincal summary:
	- The update button now correctly updates the icon list in the settings menu, and new frames are immediately draggable.
	- Spending a Buff will remove the cooldown timer on the buff and update its view conditions correctly

Slightly more technical summary:
	- UNIT_AURA contains non secret values for the buff that has been removed. Saving the aura instance ID onto the frame allows identifying a match so the buff can have its state updated correctly.
