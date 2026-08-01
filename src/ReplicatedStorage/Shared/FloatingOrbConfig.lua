-- Levitation for tagged orbs. Today that means the glowing Core of a dropped boost field, one for
-- Power and one for Speed, treated identically.
--
-- The core's normalized rest pose sits on the floor the field landed on. A fresh placement starts
-- at the canister's authored Core height and carries an offset back to that same normalized pose.
-- Either way it lifts clear of the six-stud buildings and bobs there, while the ring and disc stay
-- on the ground where the coverage has to stay legible.
--
-- HoverHeight is measured from the rest pose, so it is one number against the ground the field
-- actually landed on, and a floor higher up carries the same clearance without restating anything.
--
-- Live-tuned values approved and baked on 2026-08-01. Runtime code reads this module directly.

return table.freeze({
	Enabled = true,
	-- Studs above the rest pose. Production buildings top out about six studs over their floor.
	HoverHeight = 9,
	-- Studs either side of the hover point. Small: the core is barely over a stud across, so travel
	-- that would read as a gentle drift on a big object reads as a bounce on this one.
	Amplitude = 0.4,
	-- One full up-and-down cycle.
	CycleSeconds = 3,

	-- A player standing on the core presses it down with the same capped, springy fake-physics
	-- model as FloatingRuins. Extra players share part of the first player's weight rather than
	-- multiplying it outright, so a crowd cannot bury the orb in the buildings below.
	SagDepth = 1.5,
	SagLimit = 1.5,
	SagStiffness = 95,
	SagDamping = 12,

	-- Freshly dropped fields arrive as the same complete canister shown by the placement ghost.
	-- The cap opens first, then the core rises while the disposable casing fades. Restored fields
	-- do not carry that casing and therefore start directly in their floating pose.
	PlacementLidDegrees = 110,
	PlacementLidSeconds = 1,
	PlacementRiseDelay = 0.1,
	PlacementRiseSeconds = 3,
	-- The Core grows with the same eased progress as its rise and keeps this final scale afterward.
	CoreFinalScale = 2,
	PlacementFadeDelay = 1.3,
	PlacementFadeSeconds = 0.5,
})
