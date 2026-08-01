-- FloatingRuins -- magnetic levitation presentation for Studio-authored floating slab stacks.
--
-- Studio owns the geometry and the rest pose. Tag each layer Model "FloatingRuin"; tagged layers
-- sharing a parent form one stack, ordered by height, so a player's weight presses down through it.
--
-- The slabs stay anchored and the dip is a client-side CFrame effect rather than real physics.
-- That is deliberate: an unanchored slab sags by however much load it carries, which would close
-- the authored 1-stud gap once a few players piled on, and its simulation would belong to whichever
-- client happened to own the part, so your own footfall would arrive with your ping. Faking it caps
-- the dip and keeps it instant for the player causing it.
--
-- Rotation is authored as an edge lift in studs rather than an angle, because these layers are
-- 4, 8 and 12 studs deep over 1-stud gaps: one shared angle swings the deep slabs three times as
-- far as the shallow one. Each layer derives its own angle from its own size.
--
-- Per-layer Studio attributes, all optional:
--   RuinFloatScale  multiplier on idle drift and sway; 0 pins a grounded layer.
--   RuinLoadScale   multiplier on dip and tilt; 0 pins a grounded layer.
--   RuinFloatPhase  drift phase as a fraction of a cycle. Neighbours are kept 0.25 apart so the
--                   pair can never reach opposite extremes of the drift at the same moment.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local CharacterSupportProbe = require(Shared:WaitForChild("CharacterSupportProbe"))
local Config = require(Shared:WaitForChild("FloatingRuinsConfig"))

local TAG = "FloatingRuin"

local MAX_RENDER_DISTANCE = 320
-- Tilt chases its target without overshoot; only the vertical dip is worth bouncing.
local TILT_SMOOTHING = 9
local EXTRA_PLAYER_SHARE = 0.35
-- Clearance always kept between a slab's lowest corner and the layer below it.
local GAP_MARGIN = 0.05

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local screenGui = playerGui:WaitForChild("ScreenGui", 10)

local function reducedMotionEnabled()
	return screenGui and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
end

local layers = {}
local partToLayer = {}
local stacks = {}
local stacksDirty = true

local contactParams = RaycastParams.new()
contactParams.FilterType = Enum.RaycastFilterType.Include
contactParams.RespectCanCollide = true

local function numberAttribute(instance, name, fallback)
	local value = instance:GetAttribute(name)
	return type(value) == "number" and value or fallback
end

local function bindLayer(model)
	if not model:IsA("Model") or layers[model] then
		return
	end

	local restCFrame, size = model:GetBoundingBox()
	local parts = {}
	local inverse = restCFrame:Inverse()
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, { part = descendant, offset = inverse * descendant.CFrame })
		end
	end
	if #parts == 0 then
		warn(("FloatingRuin %s has no BaseParts to animate"):format(model:GetFullName()))
		return
	end

	-- Offsets are kept in the layer's own frame. A layer's bounding-box CFrame carries whatever
	-- rotation its parts were authored with -- Ruins.Top is turned 180 degrees about Y -- so a
	-- world-space offset fed into a locally-applied tilt would tip the slab away from the player.
	local halfX = math.max(size.X / 2, 0.01)
	local halfZ = math.max(size.Z / 2, 0.01)

	local layer = {
		model = model,
		restCFrame = restCFrame,
		parts = parts,
		halfX = halfX,
		halfY = size.Y / 2,
		halfZ = halfZ,
		tiltAngleX = math.asin(math.clamp(Config.TiltLift / halfZ, 0, 1)),
		tiltAngleZ = math.asin(math.clamp(Config.TiltLift / halfX, 0, 1)),
		swayAngleX = math.asin(math.clamp(Config.SwayLift / halfZ, 0, 1)),
		swayAngleZ = math.asin(math.clamp(Config.SwayLift / halfX, 0, 1)),
		gapBelow = math.huge,
		floatScale = numberAttribute(model, "RuinFloatScale", 1),
		loadScale = numberAttribute(model, "RuinLoadScale", 1),
		phase = numberAttribute(model, "RuinFloatPhase", 0),
		sag = 0,
		sagVelocity = 0,
		tiltX = 0,
		tiltZ = 0,
	}
	layers[model] = layer
	for _, entry in ipairs(parts) do
		partToLayer[entry.part] = layer
	end
	stacksDirty = true
end

local function restoreRestPose(layer)
	for _, entry in ipairs(layer.parts) do
		entry.part.CFrame = layer.restCFrame * entry.offset
	end
end

local function unbindLayer(model)
	local layer = layers[model]
	if not layer then
		return
	end
	layers[model] = nil
	for _, entry in ipairs(layer.parts) do
		partToLayer[entry.part] = nil
	end
	stacksDirty = true
	if model.Parent then
		restoreRestPose(layer)
	end
end

-- Layers that share a parent are one stack, ordered top first so load cascades downward.
local function rebuildStacks()
	stacksDirty = false
	table.clear(stacks)

	local byParent = {}
	local filter = {}
	for model, layer in pairs(layers) do
		local parent = model.Parent
		if parent then
			table.insert(filter, model)
			local group = byParent[parent]
			if not group then
				group = {}
				byParent[parent] = group
				table.insert(stacks, { layers = group, center = Vector3.zero })
			end
			table.insert(group, layer)
		end
	end
	contactParams.FilterDescendantsInstances = filter

	for _, stack in ipairs(stacks) do
		table.sort(stack.layers, function(left, right)
			return left.restCFrame.Position.Y > right.restCFrame.Position.Y
		end)
		local sum = Vector3.zero
		for index, layer in ipairs(stack.layers) do
			sum += layer.restCFrame.Position
			-- Measured against the rest pose of the layer below, which is conservative: bleed only
			-- ever sinks that layer further away.
			local below = stack.layers[index + 1]
			layer.gapBelow = below
					and (layer.restCFrame.Position.Y - layer.halfY) - (below.restCFrame.Position.Y + below.halfY)
				or math.huge
		end
		stack.center = sum / #stack.layers
	end
end

local contacts = {}

-- Ask what each player's footprint is actually standing on rather than assuming a flat top face.
-- The authored slabs are part wedge, so most of the standable surface on a layer sits below its top
-- face; a height band would miss a player low on a ramp. The shared support probe also keeps the
-- load while only a foot remains near an edge, matching the rounded Core's behavior.
local function gatherContacts()
	table.clear(contacts)
	for _, player in ipairs(Players:GetPlayers()) do
		local result = CharacterSupportProbe.find(player.Character, contactParams)
		local layer = result and partToLayer[result.Instance]
		if layer then
			local entry = contacts[layer]
			if not entry then
				entry = { count = 0, sum = Vector3.zero }
				contacts[layer] = entry
			end
			entry.count += 1
			entry.sum += result.Position
		end
	end
end

local elapsed = 0

local function update(deltaTime)
	if stacksDirty then
		rebuildStacks()
	end
	if #stacks == 0 then
		return
	end

	elapsed += deltaTime
	gatherContacts()

	local camera = Workspace.CurrentCamera
	local cameraPosition = camera and camera.CFrame.Position
	local still = reducedMotionEnabled()

	local sagLimit = Config.SagLimit
	local bleed = Config.LoadBleed
	local amplitude = still and 0 or Config.FloatAmplitude
	local swayScale = still and 0 or 1
	local cycle = math.pi * 2 / math.max(Config.FloatPeriod, 0.01)
	local tiltAlpha = 1 - math.exp(-TILT_SMOOTHING * deltaTime)
	local damping = math.exp(-Config.SagDamping * deltaTime)

	for _, stack in ipairs(stacks) do
		if not cameraPosition or (cameraPosition - stack.center).Magnitude <= MAX_RENDER_DISTANCE then
			local carriedSag, carriedTilt = 0, Vector3.zero

			for _, layer in ipairs(stack.layers) do
				local entry = contacts[layer]
				local ownSag, worldTilt = 0, Vector3.zero
				if entry then
					ownSag = Config.SagDepth * (1 + (entry.count - 1) * EXTRA_PLAYER_SHARE)
					local localHit = layer.restCFrame:PointToObjectSpace(entry.sum / entry.count)
					-- Returned as a world direction so it bleeds correctly into layers whose own
					-- authored rotation differs from this one's.
					worldTilt = layer.restCFrame:VectorToWorldSpace(
						Vector3.new(
							math.clamp(localHit.X / layer.halfX, -1, 1),
							0,
							math.clamp(localHit.Z / layer.halfZ, -1, 1)
						)
					)
				end

				-- Bleeding load downward also keeps the gap: the layer beneath sinks and tips with
				-- the one above it rather than being closed in on.
				local totalSag = math.min(ownSag + carriedSag * bleed, sagLimit)
				local totalTilt = worldTilt + carriedTilt * bleed
				carriedSag, carriedTilt = totalSag, totalTilt

				local localTilt = layer.restCFrame:VectorToObjectSpace(totalTilt)
				local targetTiltX = math.clamp(localTilt.Z, -1, 1) * layer.loadScale
				local targetTiltZ = math.clamp(localTilt.X, -1, 1) * layer.loadScale

				local target = -totalSag * layer.loadScale
				layer.sagVelocity += (target - layer.sag) * Config.SagStiffness * deltaTime
				layer.sagVelocity *= damping
				layer.sag += layer.sagVelocity * deltaTime

				layer.tiltX += (targetTiltX - layer.tiltX) * tiltAlpha
				layer.tiltZ += (targetTiltZ - layer.tiltZ) * tiltAlpha

				local theta = (elapsed * cycle) + layer.phase * math.pi * 2
				local drift = math.sin(theta) * amplitude * layer.floatScale
				local angleX = layer.tiltAngleX * layer.tiltX
					+ math.sin(theta) * layer.swayAngleX * swayScale * layer.floatScale
				local angleZ = -layer.tiltAngleZ * layer.tiltZ
					+ math.sin(theta * 0.5 + 2.4) * layer.swayAngleZ * swayScale * layer.floatScale
				local rise = drift + layer.sag

				-- Hard guarantee rather than a parameter budget: whatever the tuning asks for, a
				-- slab's lowest corner never reaches the layer below it. Only the rare extreme --
				-- a crowd bunched on one corner -- is ever scaled back.
				local sinX, sinZ = math.sin(angleX), math.sin(angleZ)
				local cornerDrop = -rise + layer.halfZ * math.abs(sinX) + layer.halfX * math.abs(sinZ)
				local allowance = layer.gapBelow - GAP_MARGIN
				if cornerDrop > allowance then
					-- The drop is linear in the sines, not in the angles, so scale the sines and
					-- take the angle back; scaling the angles directly overshoots, sin being concave.
					local scale = math.max(allowance, 0) / cornerDrop
					rise *= scale
					angleX = math.asin(math.clamp(sinX * scale, -1, 1))
					angleZ = math.asin(math.clamp(sinZ * scale, -1, 1))
				end

				local pivot = layer.restCFrame * CFrame.new(0, rise, 0) * CFrame.Angles(angleX, 0, angleZ)
				for _, part in ipairs(layer.parts) do
					part.part.CFrame = pivot * part.offset
				end
			end
		end
	end
end

for _, model in ipairs(CollectionService:GetTagged(TAG)) do
	bindLayer(model)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(bindLayer)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbindLayer)

RunService.Heartbeat:Connect(update)
