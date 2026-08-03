-- QuestGuideTrailConfig — the world arrow trail that walks a player to a distant world target
-- (first use: the Field Trip step that sends them to the Hub boost stall).
--
-- The trail is a line of hovering arrows between the player and the target, anchored at the
-- TARGET end: arrow 0 always sits `TailGap` studs short of the target, and further arrows are
-- laid back toward the player every `Spacing` studs. Anchoring at that end is what makes the
-- trail behave like a path rather than a leash -- the arrows near the shop hold still while you
-- move, and walking away simply adds arrows behind you instead of sliding the whole set.
--
-- Each arrow floats `Hover` studs above whatever surface is beneath it, so the trail steps down
-- the crater terraces instead of cutting through them.
--
-- DevTuning mirrors the values below for live iteration until the feature is baked.

return table.freeze({
	Enabled = true,

	-- Studio-authored assets. The template is an unmapped ReplicatedStorage model so Rojo never
	-- clobbers it; the folder is created in Workspace by the client and holds only clones.
	TemplateName = "QuestGuideArrow",
	FolderName = "QuestGuideTrail",

	-- Distance between arrows. Fixed spacing is the whole point: the count grows as the player
	-- walks away and shrinks as they close in.
	Spacing = 12,
	-- Backstop only. Past this the trail spreads its arrows over the whole distance rather than
	-- laying a 40-arrow carpet; inside the crater the fixed spacing never reaches it.
	MaxArrows = 28,
	-- How far short of the target the closest arrow stops, so the trail does not bury the stall.
	TailGap = 10,
	-- How close to the player the furthest arrow may come.
	HeadGap = 6,
	-- Inside this radius the trail fades out entirely -- the player has arrived and the stall's
	-- own prompt takes over.
	ArriveRadius = 16,

	-- Studs the arrow floats above the surface below it.
	Hover = 3.5,
	-- Downward ground probe, measured from `ProbeUp` studs above the expected path height. The
	-- span has to clear a full terrace step in either direction.
	ProbeUp = 24,
	ProbeDown = 120,

	-- Ground heights are cached on an XZ grid of this size, so arrows holding still cost no
	-- casts at all. Entries older than CacheSeconds are re-probed in case the surface moved.
	GroundCacheStuds = 3,
	GroundCacheSeconds = 2,
	-- Ground probes allowed per frame. A cache miss over budget falls back to the interpolated
	-- path height for that frame instead of stalling.
	CastBudget = 6,

	-- Vertical bob. The phase is driven by each arrow's distance along the path, so the bob
	-- reads as one wave travelling from the player toward the target.
	BobHeight = 0.6,
	BobSeconds = 1.6,
	WaveLength = 36,

	-- Studs over which an arrow fades in as it appears at the player end, and over which the
	-- whole trail fades out as the player arrives. Without it, arrows pop in and out.
	FadeSpan = 14,
})
