-- FloatingRuinsConfig -- baked feel values for magnetically levitating ruin stacks.
--
-- Live-tuned in Play on 2026-07-27 and baked from DevTuning; the FloatingRuins registry module
-- has been deleted and FloatingRuins.client.lua reads these directly.
--
-- Studio owns the geometry, the rest pose, and the per-layer RuinFloatScale / RuinLoadScale /
-- RuinFloatPhase attributes. Two values are deliberately not here: contact reach is derived per
-- character from HipHeight so it holds for R6, R15 and scaled avatars; and the clearance kept
-- above the layer below is a structural invariant enforced in the controller, not a feel knob.
--
-- TiltLift and SwayLift are edge displacements in **studs**, not angles. The layers are 4, 8 and
-- 12 studs deep, so one shared angle would swing the deep slabs three times as far as the shallow
-- one; each layer derives its own angle so all of them lift the same distance at the edge.

return {
	FloatAmplitude = 0.2,
	FloatPeriod = 4.5,
	SwayLift = 0.05,
	SagDepth = 0.25,
	SagLimit = 0.6,
	SagStiffness = 90,
	SagDamping = 7,
	TiltLift = 0.3,
	LoadBleed = 0.3,
}
