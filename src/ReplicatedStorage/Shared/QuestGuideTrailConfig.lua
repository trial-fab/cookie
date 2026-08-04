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
	Spacing = 10,
	-- Backstop only. Past this the trail spreads its arrows over the whole distance rather than
	-- laying a 40-arrow carpet; inside the crater the fixed spacing never reaches it.
	MaxArrows = 40,
	-- How far short of the target the closest arrow stops, so the trail does not bury the stall.
	TailGap = 1,
	-- How close to the player the furthest arrow may come.
	HeadGap = 4,
	-- Inside this radius the trail fades out entirely -- the player has arrived and the stall's
	-- own prompt takes over.
	ArriveRadius = 10,

	-- Studs the arrow floats above the surface below it.
	Hover = 1,
	-- Cap on how steeply an arrow may tilt toward the next one, in degrees. This is what decides
	-- how a step up onto a tall object reads: too low and the arrow shrugs at a wall it is meant to
	-- be climbing, 90 lets it point straight up. It only bites where the ground actually steps --
	-- on flat ground the segment is level and the pitch is zero regardless of this.
	MaxPitch = 75,

	-- Bridge arrows: extra arrows filling the vertical run where the ground steps up or down.
	--
	-- Arrows are spaced across the FLAT path, so where the trail climbs a tall object the two
	-- arrows either side of the step sit one spacing apart horizontally and tens of studs apart
	-- vertically, with nothing between them. The fill keeps the spacing even in 3D instead, which
	-- turns a bare vertical gap into a visible ramp of arrows -- and is inert on flat ground, where
	-- the 3D and flat distances are identical and no fill is generated.
	BridgeEnabled = true,
	-- Most arrows any one step may spend. Without a cap a sheer cliff would swallow the whole
	-- MaxArrows budget on a single gap and leave no trail past it.
	BridgeMax = 6,
	-- Downward ground probe, measured from `ProbeUp` studs above the expected path height. The
	-- span has to clear a full terrace step in either direction.
	ProbeUp = 24,
	ProbeDown = 120,

	-- Ground heights are cached on an XZ grid of this size, so arrows holding still cost no
	-- casts at all. Entries older than CacheSeconds are re-probed in case the surface moved.
	GroundCacheStuds = 3,
	GroundCacheSeconds = 2,
	-- Ground probes allowed per frame, shared by the arrows, the ribbon and the runner in that
	-- order. A cache miss over budget falls back to the interpolated path height for that frame
	-- instead of stalling. The budget only throttles the initial fill -- because the trail is
	-- anchored at the target end its sample points hold still, so a warmed cache costs no casts.
	CastBudget = 12,

	-- Vertical bob. The phase is driven by each arrow's distance along the path, so the bob
	-- reads as one wave travelling from the player toward the target.
	--
	-- WaveLength was tuned to 200 -- long enough that every arrow bobs in near-unison and the
	-- travelling read is gone. Recorded as tuned, but it means the wave is doing nothing: at this
	-- amplitude over this spacing it was too subtle to see as motion along the path.
	BobHeight = 0.6,
	BobSeconds = 1.6,
	WaveLength = 200,

	-- Studs over which an arrow fades in as it appears at the player end, and over which the
	-- whole trail fades out as the player arrives. Without it, arrows pop in and out.
	FadeSpan = 14,

	-- ---------------------------------------------------------------------------------------
	-- Cascade: the arrows light in sequence as the runner reaches them.
	--
	-- This replaces the travelling bob and the ribbon pulse, both of which failed to read. A wave
	-- spread along a continuous line is too subtle to track at play distance -- the tuning pass
	-- pushed both wavelengths past the length of the whole trail, which is what "I cannot see it"
	-- looks like in numbers. A discrete marker snapping bright does not have that problem, which
	-- is why runway approach lighting works.
	--
	-- The phase comes from the runner's actual position rather than a clock of its own. That is
	-- the whole point: the mote becomes the visible cause of the cascade instead of a third object
	-- sharing the same line, so the layers read as one mechanism.
	-- ---------------------------------------------------------------------------------------
	CascadeEnabled = true,

	-- Studs ahead of the runner over which an arrow comes up, and studs behind over which it falls
	-- back. Deliberately asymmetric: a short attack and a long decay reads as a chase, where a
	-- symmetric falloff reads as a blob of light sliding along.
	CascadeLead = 8,
	CascadeTail = 26,

	-- Peak flare. Tint is how far the arrow's authored colour travels toward CascadeColor, so an
	-- arrow restyled in Studio still cascades correctly without touching these.
	--
	-- On a Neon union the VALUE of the colour is the glow control, so tinting toward white is
	-- literally a glow ramp -- but only if the arrow's rest colour has headroom. The arrow was
	-- authored at full value (HSV V=1.00), where the tint could only desaturate and the glow never
	-- moved; it is now drafted darker so the same cascade climbs V from about 0.35 to 0.90.
	CascadeColor = Color3.fromRGB(255, 255, 255),
	CascadeTint = 0.85,
	-- Floor under the tint, so an arrow the runner is nowhere near still glows enough to read.
	-- Without it the whole trail goes dark during RunnerGap. Applies to tint only -- scale and lift
	-- stay on the raw flare, so a resting arrow sits at its authored size and height.
	CascadeRest = 0.3,
	-- Growth and vertical lift at the crest.
	CascadeScale = 0.18,
	CascadeLift = 1.2,

	-- Spark burst as the crest reaches an arrow. A ParticleEmitter is the only one of the effect
	-- classes here that supports flipbooks, Squash and SpreadAngle, so it is where any genuinely
	-- animated texture work has to live -- beams and trails support none of them.
	--
	-- The emitter lives on the arrow template with Rate held at 0; this fires it with Emit(), so
	-- nothing streams continuously.
	-- Fired when the runner CROSSES an arrow, not when the flare passes a threshold. The crest is
	-- only about 7 studs wide, and the runner covers 2 studs a frame at the default speed and 12 at
	-- the fastest -- measured, it stepped clean over 12 of 30 arrows at the fast end, and a 30fps
	-- client doubles that step. A sign change cannot be stepped over at any speed or frame rate.
	CascadeBurst = true,
	CascadeBurstCount = 8,

	-- ---------------------------------------------------------------------------------------
	-- Ribbon: the continuous ground line the arrows sit above.
	--
	-- Sampled on its OWN polyline rather than beamed arrow-to-arrow. Two reasons: arrows are 12
	-- studs apart, so a straight beam between two of them buries itself in a terrace lip; and the
	-- bob puts adjacent arrows ~120 degrees out of phase, so a beam pinned to them kinks at every
	-- joint. A denser un-bobbed line hugs the ground and leaves the arrows free to bob above it.
	-- ---------------------------------------------------------------------------------------
	-- Off. The continuous line read as flat next to the arrows and never justified itself; the
	-- module stays in place because the beam chain is the only layer that can draw a path where
	-- there is no arrow, but nothing turns it on today.
	RibbonEnabled = false,
	-- Studio-authored Model: a RibbonRoot part holding the styled source Beam. Look (texture,
	-- colour, width, light) is authored there; only geometry and fade are owned here.
	RibbonTemplateName = "QuestGuideRibbon",

	-- Studs between ribbon nodes. Denser than the arrow spacing so the line follows terrain.
	RibbonStep = 6,
	-- Backstop matching MaxArrows: past it the ribbon spreads over the whole span instead.
	RibbonMaxNodes = 64,
	-- Studs the ribbon floats above the surface. Small: this reads as paint on the ground, not
	-- as a second floating line competing with the arrows.
	RibbonHover = 0.35,
	-- Rotation about the path axis, in degrees. 0 lays the ribbon flat in the ground plane.
	-- Exposed because the beam's width axis is fixed by attachment orientation rather than by a
	-- beam property: if a future template wants a standing banner instead, this is the one knob.
	RibbonRoll = 0,
	-- Minimum Beam.Segments per span. Geometrically 2 would do, but the engine divides Segments
	-- by up to 10 at the lowest graphics quality, and a beam that lands under 2 segments vanishes
	-- entirely. 24 survives the divide with room to spare and costs nothing.
	RibbonSegments = 24,

	-- Travelling glow pulse, phase driven by distance along the path so it reads as one wave
	-- running toward the target -- the same construction as the arrows' bob.
	--
	-- This is why the template sets TextureSpeed to 0. A scrolling beam texture cannot carry the
	-- motion across a chain: the engine stops advancing a beam's texture offset while it is
	-- offscreen, so spans drift out of phase and seam visibly at the joints once the camera swings
	-- back, and Beam exposes no TextureOffset to resynchronise them with. Driving the wave from
	-- our own clock is immune to that, and it rides Beam.Brightness -- a plain float, so unlike
	-- the Transparency sequence it allocates nothing per frame.
	-- As with WaveLength, PulseLength was tuned to the top of its range: the crests are now longer
	-- than the whole trail, so the ribbon breathes in unison rather than carrying a wave.
	PulseDepth = 0.7,
	PulseSeconds = 1.6,
	PulseLength = 199,

	-- ---------------------------------------------------------------------------------------
	-- Runner: a single mote that flies the path from the player toward the target on a loop.
	--
	-- This is the one place a Trail belongs. A Trail draws the path its attachments sweep, so it
	-- renders nothing on the arrows (anchored by design) but everything on a moving mote.
	-- ---------------------------------------------------------------------------------------
	RunnerEnabled = true,
	-- Studio-authored Model: a Runner part carrying its two attachments and the styled Trail.
	RunnerTemplateName = "QuestGuideRunner",

	-- Seconds for one pass from the player end to the target end, then the pause before the next.
	RunnerSeconds = 2.4,
	RunnerGap = 1,
	-- Studs the mote flies above the surface. NOTE: this now equals Hover, so the mote flies at
	-- exactly arrow height and passes through them rather than under them.
	RunnerHover = 1,
	-- Below this span a pass is too short to read as travel, so the runner sits out entirely.
	RunnerMinSpan = 24,
	-- Fraction of a pass spent fading in at the start and out at the end, so the mote never pops.
	-- Tuned to the top of its range, which means the mote is only near-opaque at mid-path: a
	-- symptom of it reading as a stray object at the ends rather than as part of the trail.
	RunnerFade = 0.5,

	-- ---------------------------------------------------------------------------------------
	-- Beacon: the light column standing over the target.
	--
	-- The arrows and the ribbon both run along the ground, which is where the crater terraces cut
	-- them off: from under a terrace lip the player can see the line but not its destination. The
	-- beacon is the layer that survives a broken sightline, so it is the only one that does not
	-- follow terrain.
	-- ---------------------------------------------------------------------------------------
	BeaconEnabled = true,
	-- Studio-authored Model: a BeaconRoot part holding the styled column Beam(s). As with the
	-- ribbon, every Beam in it is a layer, so core-and-halo is added in Studio.
	BeaconTemplateName = "QuestGuideBeacon",

	-- Height of the column and how far above the surface it starts. Tall enough to clear a
	-- terrace step from the far side of the crater.
	BeaconHeight = 60,
	BeaconBase = 1,
	-- Same low-graphics-quality Segments guard the ribbon carries.
	BeaconSegments = 24,
})
