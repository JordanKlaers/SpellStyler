To handle visibility, all individual frames could be anchored to a single change bar that uses the set values for visibility.

Each conditional that uses charges would need to identify any overlaps. Every sequential range would be a unique frame.
	if a charge conditional has a range that spans multiple sequential ranges, then its property overrides should apply to each range (each frame associated to a given range).


frames should start by creating the base frame
A new method should be called specifically for processing the conditionals, determining the charge ranges, and creating a frame for each range.
	This includes creating the statusBar with the correct min and max, as well as anchoring this new frame to its charge bar
Only valid property override entries should create a frame.