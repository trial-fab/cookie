-- QuestGuideBeacon — the light column standing over a distant world guide target.
--
-- The ribbon and the arrows both run along the ground, which is exactly where the crater terraces
-- block them: below a terrace lip a player can see the line they are following but not the place
-- it ends. The beacon is the part of the guide that survives broken sightlines, so it is the only
-- layer that deliberately does not hug terrain.
--
-- Its pulse is read from the ribbon's wave at the target end rather than run on its own clock, so
-- the column flares as each ribbon crest arrives instead of blinking independently of it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SequenceFade = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SequenceFade"))

local QuestGuideBeacon = {}

-- Attachment X is the axis Beam lays its curve control points along, so a column wants X pointing
-- up. Width is handled by FaceCamera on the template -- a beacon has to read from every angle,
-- which is the one place in this feature where camera-facing is right and flat is wrong.
local function columnCFrame(position)
	return CFrame.fromMatrix(position, Vector3.yAxis, Vector3.xAxis)
end

function QuestGuideBeacon.new(ctx)
	local Config = ctx.Config
	local model
	local root
	local layers = {}
	local base, top
	local alpha
	local warnedMissingTemplate = false

	local function ensureRoot()
		if model and model.Parent then return true end

		local folder = ctx.Folder()
		if not folder then return false end

		local source = ReplicatedStorage:FindFirstChild(Config.BeaconTemplateName)
		local sourceRoot = source and source:FindFirstChild("BeaconRoot")
		local sourceBeam = sourceRoot and sourceRoot:FindFirstChildWhichIsA("Beam")
		if not (sourceRoot and sourceRoot:IsA("BasePart") and sourceBeam) then
			if not warnedMissingTemplate then
				warnedMissingTemplate = true
				warn(
					("QuestGuideBeacon: no `%s` Model holding a BeaconRoot part with a Beam in ReplicatedStorage -- the quest target stands unmarked."):format(
						Config.BeaconTemplateName
					)
				)
			end
			return false
		end

		if model then model:Destroy() end
		table.clear(layers)

		model = source:Clone()
		root = model:FindFirstChild("BeaconRoot")
		root.Anchored = true
		root.CanCollide, root.CanQuery, root.CanTouch = false, false, false
		root.CastShadow = false
		root.Transparency = 1
		root.CFrame = CFrame.identity

		base = Instance.new("Attachment")
		base.Name = "Base"
		base.Parent = root
		top = Instance.new("Attachment")
		top.Name = "Top"
		top.Parent = root

		-- Same layering contract as the ribbon: every Beam in the template is a layer, so a core
		-- and a halo are added in Studio rather than here.
		for _, child in ipairs(root:GetChildren()) do
			if child:IsA("Beam") then
				child.Segments = math.max(child.Segments, Config.BeaconSegments)
				child.Attachment0 = base
				child.Attachment1 = top
				child.Enabled = false
				table.insert(layers, { Beam = child, Keypoints = child.Transparency.Keypoints, Brightness = child.Brightness })
			end
		end

		alpha = nil
		model.Parent = folder
		return true
	end

	local beacon = {}

	function beacon.Update(path, now)
		local tuning = ctx.Tuning
		if tuning.BeaconEnabled == false then beacon.Clear(); return end
		if not ensureRoot() then return end

		-- Planted on the ground under the target rather than at the target's own pivot, so a sign
		-- anchor mounted part way up a post does not leave the column floating.
		local groundY = ctx.Ground(path.Goal.X, path.Goal.Z, path.Goal.Y)
		local foot = Vector3.new(path.Goal.X, groundY + tuning.BeaconBase, path.Goal.Z)
		base.CFrame = columnCFrame(foot)
		top.CFrame = columnCFrame(foot + Vector3.yAxis * tuning.BeaconHeight)

		-- The ribbon's wave sampled where it meets the target, so the column answers each crest
		-- that arrives instead of pulsing to a clock of its own.
		local wave = math.sin((now / tuning.PulseSeconds + path.TailGap / tuning.PulseLength) * math.pi * 2)
		local pulse = 1 - tuning.PulseDepth * (0.5 + 0.5 * wave)

		for _, layer in ipairs(layers) do
			alpha = SequenceFade.apply(layer.Beam, "Transparency", layer.Keypoints, path.Arrive, alpha)
			layer.Beam.Enabled = alpha > 0
			layer.Beam.Brightness = layer.Brightness * pulse
		end
	end

	function beacon.Clear()
		if not (model and model.Parent) then return end
		for _, layer in ipairs(layers) do
			layer.Beam.Enabled = false
		end
	end

	function beacon.Destroy()
		if model then model:Destroy(); model = nil end
		root, base, top = nil, nil, nil
		table.clear(layers)
	end

	return beacon
end

return QuestGuideBeacon
