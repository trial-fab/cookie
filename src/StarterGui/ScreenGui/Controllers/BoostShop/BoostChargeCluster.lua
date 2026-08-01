-- BoostChargeCluster: how many charges a boost hotbar slot is holding, said with canisters.
--
-- The slot used to carry one model preview plus a number badge. It now carries up to three
-- previews and no number: one charge is the single centred canister the slot always showed, two is
-- a symmetric pair, and three lays out in the hotbar's own shape — a large canister in the middle
-- with a smaller one either side. Counting three small objects is instant; reading a badge is not.
--
-- Studio owns the viewports (`Preview` plus the drafted `PreviewLeft` / `PreviewRight`); this
-- module owns only which of them are visible, where they sit, and how they stack, all of it in
-- fractions of the slot so the layout survives the mobile scale and any resize of the authored disc.
--
-- The SINGLE-charge pose is the authored one, captured at bind time and restored untouched, so
-- owning one charge looks exactly as it did before this readout existed. That is also why the
-- single pose has no config entry: it is a Studio value, not a code value.
--
-- Each viewport's Camera is created here and assigned to CurrentCamera on purpose — authored
-- Camera instances are stripped in the StarterGui -> PlayerGui replication, so a Studio-authored
-- one renders blank in Play.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("BoostChargeClusterConfig"))

local BoostChargeCluster = {}

-- The shape holds three canisters. A larger stack cap would need a different readout, not more
-- canisters crammed into one 58px disc, so counts past this saturate rather than overflow.
BoostChargeCluster.MaxDisplayed = 3

local CENTER_NAME = "Preview"
local LEFT_NAME = "PreviewLeft"
local RIGHT_NAME = "PreviewRight"

-- Depth ladder, as offsets from the slot's own ZIndex. The baked layout overlaps the canisters, so
-- which one is in front is part of the shape and not a tie to be broken by child order: the large
-- centre reads as the nearest object, and the two behind it stagger rather than sharing a depth.
-- The same ladder gives the two-charge pair a front and a back.
local CENTER_DEPTH = 2
local RIGHT_DEPTH = 1
local LEFT_DEPTH = 0

-- Orbit framing for a slot preview, BAKED from a live tuning session (2026-07-26). Deliberately
-- not StorePreview's front-quarter building pose: a canister is a small vertical object in a small
-- round slot, and it reads best square-on and filling the frame, so the camera ended up at a flat
-- side-on angle with no elevation, pulled in tight (zoom 1) at a wide 60 degree field of view.
local PREVIEW_ANGLE = math.rad(90)
local PREVIEW_ELEVATION = math.rad(0)
local PREVIEW_ZOOM = 1
local PREVIEW_FOV = 60

local function mountPreview(viewport, sourceModel)
	viewport:ClearAllChildren()
	viewport.CurrentCamera = nil

	local world = Instance.new("WorldModel")
	world.Name = "PreviewWorld"
	world.Parent = viewport

	local model = sourceModel:Clone()
	model.Parent = world

	local boundingCFrame, size = model:GetBoundingBox()
	local radius = math.max(size.Magnitude / 2, 0.1)
	local distance = radius * PREVIEW_ZOOM / math.tan(math.rad(PREVIEW_FOV) / 2)
	local direction = CFrame.fromEulerAnglesYXZ(PREVIEW_ELEVATION, PREVIEW_ANGLE, 0).LookVector

	local camera = Instance.new("Camera")
	camera.Name = "PreviewCamera"
	camera.FieldOfView = PREVIEW_FOV
	camera.CFrame = CFrame.lookAt(boundingCFrame.Position - direction * distance, boundingCFrame.Position)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

local function findViewport(slot, name)
	local viewport = slot:FindFirstChild(name)
	return viewport and viewport:IsA("ViewportFrame") and viewport or nil
end

-- Binds one boost slot. Returns nil when the slot has no authored `Preview` or the item has no
-- canister model, which leaves the caller on the authored `+` placeholder rather than an empty disc.
-- The two flank viewports are optional: without them the slot still shows the single centred
-- canister for any count, which is exactly the pre-cluster behaviour.
function BoostChargeCluster.bind(slot, sourceModel)
	local center = findViewport(slot, CENTER_NAME)
	if not (center and sourceModel) then
		return nil
	end

	local left = findViewport(slot, LEFT_NAME)
	local right = findViewport(slot, RIGHT_NAME)
	local flanks = (left and right) and { left, right } or nil

	local authored = {
		Size = center.Size,
		Position = center.Position,
		AnchorPoint = center.AnchorPoint,
	}

	mountPreview(center, sourceModel)
	if flanks then
		for _, viewport in ipairs(flanks) do
			mountPreview(viewport, sourceModel)
		end
	end

	local count = 0
	local shown = false

	local function place(viewport, scale, offsetX, offsetY)
		viewport.AnchorPoint = Vector2.new(0.5, 0.5)
		viewport.Size = UDim2.fromScale(scale, scale)
		viewport.Position = UDim2.fromScale(0.5 + offsetX, 0.5 + offsetY)
	end

	local function restoreAuthoredCenter()
		center.AnchorPoint = authored.AnchorPoint
		center.Size = authored.Size
		center.Position = authored.Position
	end

	-- HotbarCarousel flattens EVERY descendant's ZIndex onto the slot's whenever it poses a slot, so
	-- the ladder cannot be authored once and left alone — a single spin would drop the centre back
	-- level with the canisters it is supposed to be standing in front of. Re-asserting from each
	-- frame's own ZIndex, rather than only from the slot's, is what makes this ordering-independent:
	-- it corrects the same whether the flatten lands before or after this runs. The writes are
	-- guarded, so the change signal that each one raises settles instead of looping.
	local function applyDepth()
		local base = slot.ZIndex
		if center.ZIndex ~= base + CENTER_DEPTH then
			center.ZIndex = base + CENTER_DEPTH
		end
		if flanks then
			if right.ZIndex ~= base + RIGHT_DEPTH then
				right.ZIndex = base + RIGHT_DEPTH
			end
			if left.ZIndex ~= base + LEFT_DEPTH then
				left.ZIndex = base + LEFT_DEPTH
			end
		end
	end

	local function render()
		local displayed = shown and math.clamp(count, 0, BoostChargeCluster.MaxDisplayed) or 0
		if not flanks then
			restoreAuthoredCenter()
			center.Visible = displayed > 0
			return
		end

		if displayed >= 3 then
			place(center, Config.CenterScale, 0, 0)
			place(left, Config.FlankScale, -Config.FlankOffsetX, Config.FlankOffsetY)
			place(right, Config.FlankScale, Config.FlankOffsetX, Config.FlankOffsetY)
		elseif displayed == 2 then
			-- The pair uses the two FLANK viewports, not the centre one: a pair straddles the middle
			-- of the slot, so nothing should be sitting on it.
			place(left, Config.PairScale, -Config.PairOffsetX, Config.PairOffsetY)
			place(right, Config.PairScale, Config.PairOffsetX, Config.PairOffsetY)
		elseif displayed == 1 then
			restoreAuthoredCenter()
		end

		center.Visible = displayed == 1 or displayed >= 3
		left.Visible = displayed >= 2
		right.Visible = displayed >= 2
		applyDepth()
	end

	local connections = {
		slot:GetPropertyChangedSignal("ZIndex"):Connect(applyDepth),
		center:GetPropertyChangedSignal("ZIndex"):Connect(applyDepth),
	}
	if flanks then
		for _, viewport in ipairs(flanks) do
			table.insert(connections, viewport:GetPropertyChangedSignal("ZIndex"):Connect(applyDepth))
		end
	end

	render()

	return {
		-- `owned` is the raw charge count and `visible` is whether the slot may show anything at all
		-- (a placement or an open store owns the disc instead).
		render = function(owned, visible)
			count = math.max(0, math.floor(tonumber(owned) or 0))
			shown = visible == true
			render()
		end,
		destroy = function()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			table.clear(connections)
		end,
	}
end

return BoostChargeCluster
