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

Version 0.2.2

Slightly less techincal summary:
	- Changing talents should auto update
	- Porting should not throw an error

Slightly more technical summary:
	- check for the talent change and update spell id to reload the necessary parts of the addon to respond to changing talents
	- adds a check for having a valid talent spec before doing anything. Porting can cause the spec to be null for a moment that would throw errors

Version 0.2.3

	- Fixed a bug when changing specs that was missed in previous patch

Version 0.2.4

	- Implements the desaturated setting that was not hooked up

Version 0.3.0

Slightly less techincal summary:
	- Buffs should correctly update their icon if they have dynamic icons
	- Spells should correctly update in response to other spells that would reduce their cooldown, specifically when their cooldown is completely reset

Slightly more technical summary:
	- Buffs check the CDM frame to see pull the icon texture to keep it updated on changes
	- Spells had an incorrect check for detecting updates. The condition checks for a less strict difference to determine if the frame should be updated (have its cooldown data reapplied)

Version 0.4.0

Slightly less technical summary:
	- Spell icon updates, spells turning into other spells, spell charges and spell cooldowns should all behave more reliably

Slightly more technical summary:
	- Spells now check for the override spell id to pull the correct cooldown data as well as charges.
	- Spells use the OnShow and and OnHide events for their cooldown frames to more reliaby process valid cooldowns. (SPELL_UPDATE_COOLDOWN and 'OnCooldownDone' are still used as well. SPELL_UDPATE_COOLDOWN reliably detects when a spell have zero remaining charges which works for spell with and without charges)

Version 0.4.1

Slightly less technical summary:
	- Spells no longer need to be tagged as off GCD
	- Buffs should more consistently apply the correct visibility state.
	- Added Settings for status bars to rotate the texture. This should allow for custom textures to better support custom fill directions. Rotating the texture while changing the orientation and fill direction can help. Reach out to me if you have issues.

Slightly more technical summary:
	- Small update to the conditional for off GCD spells results in them no longer needing to be flagged.
	- Buffs for some reason, had some that were unreliable in using the CDM IsShown() for controlling their visibliity. Updated to also consider the presence of an auraInstanceID as an indiication the buff is active.
	- Identified spells that can be off GCD AND have charges. This was not handled correctly. Updates have been made to manually track spell charges only for spells off the GCD. (This assumes those spells can not regain charges outside of the typical cooldown end event on the cooldown frame).
	- Charges now use the "SPELL_UPDATE_CHARGES" event to update the charges text

Version 0.4.2

Slightly less technical summary:
	- Fixed a bug with charges and their display state when spells mutate into other spells

Slightly more technical summary:
	- Updated the condition for hiding spell charges to include the new off gcd manually spell charge tracking nonsense

Version 0.4.3

Slightly less technical summary:
	- Spells now control visibility through the charges rather than the previous convoluted system

Slightly more technical summary:
	- By using SetAlpha on the icon frame, passing the current spell charges, the icon visibility is controlled with better consistency. This speficially solves (among other things) things like: a spell with charges having its cooldown duration reduced beyond the end of the current duration. For example, at 0 avaiable charges of holy shock, 0.5 seconds on the remaining cooldown duration. Casting Shield of the righteous would reduce the cooldown INTO the next charge, completely skippng the "OnCooldownDone" hook that would help determin if a spell could be cast again - thus causing issues with the visibility conditions.
	- Only the icon uses this updated solution and only for the specific icon visibility states that match the capabilities of the SetAlpha solution. This means you could still show the icon only when its unavailable (althought slightly less reliable)

Version 0.4.4

Slightly less technical summary:
	- Spells that dynamically update their cooldown should no longer apply invalid durations
	- Additional updates to ensure spells apply the correct visibility conditions

Slightly more technical summary:
	- Use the OnShow callback of a cooldown frame to validate the duration before applying to the real frame.
	- Apply charges in more methods to ensure the frame can update its visibility conditions in all cases

Version 0.4.5

Slightly less technical summary:
	- Spells properly cache their charges when first loading into the game

Slightly more technical summary:
	- Basically just delayed the spell charge cache upon entering the world

Version 0.4.6
	- Adds glow notifications and reverts a very niche bugfix that actucally caused GCD swipes to show, which is disgusting.

Version 0.4.7
	- Missed a setting for the glow notification menu

Version 0.4.8

Slightly less technical summary:
	- Spells with an active cooldown that would apply the gcd, will just end the cooldown instead (to avoid rendering the gcd)
	- Buffs properly end their duration when the buff is over - instead of reapplying the spell duration (when the buff and spell id's match)

Slightly more technical summary:
	- As a solution for spells with charges, they would attempted to reapply the cooldown after one completes. Its been updated to NOT do that for buff frames, as they should be completely controlled by the hook on the blizzard frame.
	- Uses the curve with elvaluate remaining duration to check if the cooldown that will be applied is equal to the GCD. If thats the case, (only for spells that are activly on cooldown) it will instead just end the cooldown early. This happens as a side affect of accounting for spells that can have their cooldown duration reduced by other spells. In order to keep that working, and ALSO not show the GCD, skipping it by ending the cooldown duration is easiest currently.

Version 0.5.0

Adds global visibility condition for out of combat - to hide icons

Version 0.5.1

Slightly less technical summary:
	- Buff status bars properly show the duration

Slightly more technical summary:
	- Accidently set the inverse values for display state and didnt notice. Oops

Version 1.0.0

	- Buffs are still tracked by the cooldown manager
	- Spells are completely detached from the cooldown manager and you can track any personal spell