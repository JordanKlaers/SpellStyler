Spells
	- Set icon visibility based on available state
	- Set custom textures for any/all individual instances of the spells
	- Set position, size, opacity, scale, texture zoom, custom anchor points
	- Set config for the cooldown, including: hiding the cooldown swipe, text size, rendering a bar for the duration, setting a custom texture for the duration bar, duration bar size/color/orientiation ect.
	- Hiding the spell visually when its stack are above or below a set value
	- Display a glow when the spell is available to cast, or gains a charge
	- Set config for charge display, including: font size and style, rendering a bar for the charges, set a custom texture for the bar, bar size/color/orientation ect.
	- Custom label to display whatever text you want, such as the keybind
	- enable display of the spell only when its active spell ID is enabled. For example beacon of light can change into becaon of virtue for holy paladins. This settings allows you to only display the tracker for one or the other version of the spell based on whats active.

Templates
	- Save the settings for a specific spell to a template to easily apply all applicable settings to other spells, items, or auras

Auras
	- Same icon settings as spells
	- Toggle to set which spec the aura should be enabled on
	- Set configuration for the aura, such as the flags for the aura, and specific spell id's to attempt to track. Multiple spell id's will trigger the aura for any that are active. If you have a custom texture, only that texture will display. With no custom texture, then the icon for the active spellID will display
	- Set config for the aura duration similar to spell cooldowns
	- Set config for the aura stacks similar to spell stacks

Items
	Almost identical settings to spells with a few item specific settings such as displaying the item quality emblem. Items also automatically track items that have different qualities, so if you run out of three start and have two star in your bag for a health pot, it will update the stack count and quality emblem when you run out of the three star version.

Containers
	- Group icon display with custom columns/rows orientation and icon sizes
	- Enable collapsable containers to hide icons not available to cast

Utility
	- Hide all icons out of combat
	- Set global font styles for icons

Conditionals
	- Create conditionals for:
		- combo points
		- Is Spell Usable, including [ able to cast, unable to cast, spell on cooldown, and unable to cast due to insufficient power ]
		- Charge count
		- Unit health
	Conditionals can then be used on spells to set any of the properties when the conditional passes.
	Conditionals are quite limited in the current system but if you want more let me know and I can add (or explain why its not possible)

Profiles
	- Set entier tracking configuration to apply either, one profile for the whole specialization, or a unique profile for each talent loadout for the specialization.