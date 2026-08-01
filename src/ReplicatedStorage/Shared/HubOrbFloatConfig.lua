-- Levitation for the DORMANT Ancient Core -- the orb as it rests on the Thruster mount, before a
-- player activates it. The activated core already has its own float; this is the state that used to
-- sit dead still on the ring.
--
-- The orb is authored resting ON `MountRing2`, so a bob centred on that rest pose would sink it into
-- the ring on every down leg. `RestLift` is what the orb hovers at in the MIDDLE of its bob, and
-- `Amplitude` is half the travel either side of it -- keep RestLift >= Amplitude and the lowest
-- point never reaches the authored rest.
--
-- DevTuning mirrors these values for live iteration until the feature is baked.

return table.freeze({
	Enabled = true,
	-- Studs above the authored rest pose, at the middle of the bob.
	RestLift = 0.35,
	-- Half the total travel. 0 parks the orb at RestLift without motion.
	Amplitude = 0.3,
	-- One leg of the bob: middle-to-top, or top-to-middle. A full cycle is four of these.
	LegSeconds = 2.2,
})
