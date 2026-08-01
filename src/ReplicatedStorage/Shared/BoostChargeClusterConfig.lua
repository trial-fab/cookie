-- Layout for a boost hotbar slot's owned-charge readout.
--
-- The slot says how many charges you hold by how many canisters it SHOWS, not with a number:
-- three charges lay out in the hotbar's own shape (a large canister centred, a smaller one either
-- side), two sit as a symmetric pair, and one is left exactly as the authored single preview.
--
-- Every value is a fraction of the SLOT's size, never a pixel count, so the readout follows the
-- authored slot and the device scale instead of restating the hotbar's geometry here.
--
-- One set of values drives BOTH boost slots: Power and Speed always read identically, which is why
-- there is no per-item table.
--
-- BAKED 2026-07-31 from a live Play session's DevTuningConfiguration, so these are exactly the
-- numbers that were on screen; the BoostChargeCluster registry is gone and this module is read
-- directly. The canisters deliberately OVERLAP at these sizes — they read as a held stack rather
-- than three separate objects, which is what makes the centre's depth lead (BoostChargeCluster's
-- ladder) load-bearing rather than cosmetic.

return table.freeze({
	-- Three charges.
	CenterScale = 0.7,
	FlankScale = 0.6,
	FlankOffsetX = 0.2,
	-- Positive is downward. Level with the centre: the tuning session settled on depth, not height,
	-- as what separates the three.
	FlankOffsetY = 0,

	-- Two charges. With no third canister there is no centre to be the large one, so the pair is one
	-- size, symmetric about the middle, and closer together than the flanks of a full cluster.
	PairScale = 0.7,
	PairOffsetX = 0.1,
	PairOffsetY = 0,
})
