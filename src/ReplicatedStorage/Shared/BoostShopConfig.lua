-- BoostShopConfig — the gem-priced field charges sold at the central Hub stall
-- (docs/boost-shop-design.md §1 + decisions 3/6: 40 gems, +50%, stack cap 3 per type).
--
-- One definition shared by the world prompts, the purchase window, and the future server
-- purchase/inventory service, so a price or duration is never restated in two places.
--
-- The Studio names below are how the client finds the authored assets. `StallName` is looked
-- up recursively in Workspace, so the stall keeps working whether it stays inside
-- `BoostShopDraft` or is promoted/moved elsewhere on the Hub pad.

local Attrs = require(script.Parent:WaitForChild("Attrs"))

local BoostShopConfig = {}

BoostShopConfig.StallName = "BoostStall"
BoostShopConfig.PromptName = "ViewPrompt"
BoostShopConfig.HighlightName = "SelectHighlight"
BoostShopConfig.UiContainerName = "BoostShop"
BoostShopConfig.ModalName = "BoostPurchaseConfirm"

-- Studio-authored templates in ReplicatedStorage (unmapped by Rojo, so they are safe from sync).
-- GhostTemplateName is the flat radius disc the placement preview clones and the dropped field
-- reuses; its authored `ReferenceRadius` attribute is the radius its geometry was built at, so
-- code scales Size by (item radius / reference) instead of assuming the authored scale.
BoostShopConfig.GhostTemplateName = "BoostFieldGhost"
BoostShopConfig.PreviewFolderName = "BoostPreviews"
-- Dropped fields are parented to the target plot's sheet under this name prefix.
BoostShopConfig.FieldNamePrefix = "BoostField_"

-- How far a field's disc sits above the floor surface it lands on. ONE value, shared by the
-- placement ghost and the server's drop, because the whole point of the ghost is that the field
-- appears exactly where the preview was: two constants here would be two different heights.
BoostShopConfig.FieldSurfaceLift = 0.1
-- How far off a floor surface a submitted drop point may sit and still be resolved to that floor.
-- The client now sends a point it computed ON the surface plane, so this only has to absorb float
-- error and a plot that shifted between preview and invoke -- not a raycast landing on a roof.
BoostShopConfig.SurfaceToleranceY = 4

-- The ghost carries a copy of the item's own canister STANDING at the centre of its radius disc,
-- so a disc on the ground still says WHICH boost is about to be dropped. The canister keeps its
-- authored rotation (Foot down, Cap up -- its parts are Cylinders turned on end, so the model's
-- pivot carries a 90 degree roll that must be preserved, not flattened) and its lowest point is
-- placed on the surface. Lift nudges it up if the user wants clearance.
BoostShopConfig.GhostItemLift = 0
BoostShopConfig.GhostItemTransparency = 0.35
-- Canister parts that keep their authored look instead of being ghosted. The Neon Core is the
-- item's whole identity -- orange for Power, cyan for Speed -- so fading it with the rest would
-- leave two indistinguishable grey canisters.
BoostShopConfig.GhostItemSolidParts = { Core = true }

-- Sonar ping. The INNER disc sweeps out from the centre and fades as it arrives at the edge; the
-- outer Rim never moves, so the field's true coverage stays readable the whole time. Scaling the
-- whole disc (the first attempt) made the one thing the player is actually deciding -- where the
-- edge falls -- the one thing that would not hold still.
--
-- The ring itself is a `Highlight` on the sweep part with its fill switched off. A Highlight traces
-- its adornee's silhouette, and the sweep is a flat Cylinder, so that silhouette is a circle -- a
-- real ring outline from geometry that already exists, with no union or mesh to author.
--
-- The sweep's own Transparency is the soft wash behind the ring, driven from the values below
-- rather than from the disc's authored resting transparency: the ping is a travelling wave, not the
-- field's body, so it gets to be brighter than the disc it leaves behind. Both are restored to the
-- authored values when the ping stops.
BoostShopConfig.Pulse = {
	SweepPartName = "Fill",
	OutlineName = "PingOutline",
	CorePartName = "Core",
	-- A part cannot be zero-sized, and a ping that starts as a literal point is invisible anyway.
	StartScale = 0.06,

	-- A dropped field is slower and quieter than a ghost: it lives on the plot for minutes, where a
	-- bright quick repeat would nag, while the ghost is on screen for seconds asking for a decision.
	Ghost = { Seconds = 1.8, FillTransparency = 0.55, OutlineTransparency = 0 },
	Field = { Seconds = 3.6, FillTransparency = 0.8, OutlineTransparency = 0.35 },
}
-- Screen-space warning shown while the ghost is somewhere the field cannot go. Authored in Studio
-- (StarterGui.ScreenGui.BoostShop.BoostPlacementWarning); code only sets its text and visibility.
BoostShopConfig.WarningLabelName = "BoostPlacementWarning"
-- Live count of the buildings the field would cover, shown while the ghost is over a plot. This is
-- the number the player is actually deciding on (§12.1), so it is the one thing the ghost has to
-- say out loud.
BoostShopConfig.CoverageLabelName = "BoostPlacementCount"
-- Roblox renders about 31 Highlights at once. The count is always exact; past this many covered
-- buildings the extras simply go un-outlined rather than pushing every other Highlight in the game
-- (field rings, sell hover) out of the budget.
BoostShopConfig.MaxCoverageHighlights = 20
-- The status panel standing over a dropped field: item name, boost strength, and the remaining
-- countdown. One panel per field (a separate gift label would have fought this one for the same
-- anchor point), cloned from a Studio template and driven by the shared WorldTrackedLabels
-- controller. A gifted field credits its sender inline on the name row.
BoostShopConfig.FieldLabelTemplateName = "BoostFieldLabelTemplate"
BoostShopConfig.FieldLabelRows = {
	Name = "ItemName",
	Boost = "Boost",
	Countdown = "Countdown",
}
-- One Power plus one Speed on the same cluster is the DESIGNED case (the x2.25 combo), so their
-- two panels routinely want the same point in space. Each item's panel is lifted by its position in
-- Order, so a pair stacks instead of colliding. Deliberately keyed on the item rather than on
-- whether the panels currently LOOK overlapped: screen overlap changes as the camera orbits, so
-- anything driven by it would merge and split while the player just moves.
BoostShopConfig.FieldLabelStackStuds = 3
-- Rows tinted with the item's own colour, so a stacked pair reads as two distinct boosts at a
-- glance (orange Power, cyan Speed) rather than two identical panels. Empty this table to hand the
-- colours back to Studio.
BoostShopConfig.FieldLabelTintedRows = {
	Boost = true,
	Countdown = true,
}

-- Named ImageLabels in the building tooltips, flagged on when a field covers the hovered building.
-- Only their VISIBILITY is code's: the artwork and colour are authored in Studio like any other
-- icon in this game, so changing either is a Studio edit and never a code change.
BoostShopConfig.TooltipBoostIcons = {
	Power = "PowerBoostIcon",
	Speed = "SpeedBoostIcon",
	TitleName = "Title",
	-- The icons chain off the END of the building name, which is why code owns their X: the name is
	-- auto-sized, so "just past it" is a different pixel for every building. Gap from the name to
	-- the first icon, then between icons. Their Y stays exactly as authored in Studio.
	TitleGap = 8,
	IconGap = 2,
}
BoostShopConfig.Warnings = {
	OffPlot = "Place the field on an unlocked floor.",
	Duplicate = "This floor already has that field.",
}

-- Cosmetic ceilings for the window's Duration/Strength bars (§7). Purely presentational:
-- a 5-minute / +50% charge reads as a half-filled bar against these references.
BoostShopConfig.BarReference = {
	DurationSeconds = 600,
	StrengthPercent = 100,
}

-- What a field's strength actually multiplies. Power raises each payout; Speed raises how OFTEN
-- the payout happens. Both come to the same cookies per second (§12.2) but feel different in play,
-- and naming the effect here keeps production from having to know which item is which.
BoostShopConfig.Effect = {
	Output = "Output",
	Frequency = "Frequency",
}

BoostShopConfig.Items = {
	PowerField = {
		Id = "PowerField",
		Effect = BoostShopConfig.Effect.Output,
		CanisterName = "PowerCanister",
		DisplayName = "Power Field",
		Description = "Boosts production from nearby buildings by 50% for 5 minutes.",
		PriceGems = 40,
		DurationSeconds = 300,
		StrengthPercent = 50,
		StackCap = 3,
		-- Tight radius: Power is the surgical option, aimed at one dense cluster (§12.2).
		-- Sized against the real plot: the buildable Base is 132 x 36 studs (6-stud grid cells),
		-- so 9 = an 18-stud/3-cell disc — a cluster, not the plot.
		Radius = 9,
		FieldColor = Color3.fromRGB(255, 138, 60),
		-- Server-owned inventory count. Absent until the purchase service ships, which reads
		-- as 0 owned (the window's happy path).
		OwnedAttribute = Attrs.PowerFieldCharges,
	},
	SpeedField = {
		Id = "SpeedField",
		Effect = BoostShopConfig.Effect.Frequency,
		CanisterName = "SpeedCanister",
		DisplayName = "Speed Field",
		Description = "Makes nearby buildings pay out 50% faster for 3 minutes.",
		PriceGems = 40,
		-- Shorter than Power on purpose: Speed covers a much wider radius for the same +50%, so
		-- duration is what keeps the two balanced (docs/boost-shop-design.md §12.2).
		DurationSeconds = 180,
		StrengthPercent = 50,
		StackCap = 3,
		-- Broad radius, offset by the shorter duration above so neither field dominates (§12.2).
		-- 15 = a 30-stud/5-cell disc: wide across the plot's 36-stud depth without spilling past it.
		Radius = 15,
		FieldColor = Color3.fromRGB(60, 190, 255),
		OwnedAttribute = Attrs.SpeedFieldCharges,
	},
}

-- Counter order, left to right (PowerCanister x=-4, SpeedCanister x=+4).
BoostShopConfig.Order = { "PowerField", "SpeedField" }

-- Radius, DurationSeconds, and StrengthPercent above are BAKED (2026-07-26): the BoostFields
-- DevTuning registry and its Shared/BoostFieldTuning seam are gone, and these values are read
-- directly. This module stays a leaf that never requires DevTuning, so both the client and the
-- server can read it from anywhere.

-- StrengthPercent as the factor production multiplies by. Power applies it to output; Speed applies
-- the same factor to payout FREQUENCY, which is why the two are worth an identical amount per
-- second and differ only in how the cookies arrive (§12.2).
function BoostShopConfig.GetStrengthMultiplier(item)
	return 1 + (item.StrengthPercent or 0) / 100
end

-- m:ss. Shared by the purchase window (advertising a charge's length) and the field panel's live
-- countdown, so the two can never disagree about how a duration reads.
function BoostShopConfig.FormatDuration(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local minutes = math.floor(seconds / 60)
	return ("%d:%02d"):format(minutes, seconds - minutes * 60)
end

-- The item whose canister model carries `name`, or nil for any other model.
function BoostShopConfig.byCanisterName(name)
	for _, id in ipairs(BoostShopConfig.Order) do
		local item = BoostShopConfig.Items[id]
		if item.CanisterName == name then
			return item
		end
	end
	return nil
end

return BoostShopConfig
