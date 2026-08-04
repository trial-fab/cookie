-- QuestGuideRibbon — the continuous ground line that joins the quest arrow trail into one path.
--
-- Owns geometry and fade only. The Beam's look (texture, colour, width, glow) is authored in the
-- Studio-side template; see QuestGuideTrailConfig for why the ribbon samples its own polyline
-- rather than beaming arrow-to-arrow.
--
-- Every node is an Attachment on ONE anchored root part. Attachment.CFrame is parent-relative and
-- the root is left at the identity CFrame, so a world CFrame can be written straight to a node --
-- 60 nodes cost one part instead of 60.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SequenceFade = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SequenceFade"))

local QuestGuideRibbon = {}

-- Beam lays its curve control points along the attachment's X axis, so X has to be the path
-- direction or the ribbon bends sideways. Taking Z as the surface normal leaves Y -- the width
-- axis -- flat in the ground plane, which is what makes the ribbon read as paint rather than as a
-- standing wall. `heading` is only near-perpendicular to `normal` on a slope, so it is projected
-- back into the plane before use.
local function nodeCFrame(position, heading, normal, roll)
	local forward = heading - normal * heading:Dot(normal)
	if forward.Magnitude < 1e-4 then return nil end
	forward = forward.Unit
	local frame = CFrame.fromMatrix(position, forward, normal:Cross(forward), normal)
	return roll ~= 0 and frame * CFrame.Angles(roll, 0, 0) or frame
end

function QuestGuideRibbon.new(ctx)
	local Config = ctx.Config
	local nodes = {}
	local beams = {}
	local beamSources = {}
	local root
	local warnedMissingTemplate = false

	local function releasePools()
		table.clear(nodes)
		table.clear(beams)
		table.clear(beamSources)
	end

	local function ensureRoot()
		if root and root.Parent then return true end

		local folder = ctx.Folder()
		if not folder then return false end

		local source = ReplicatedStorage:FindFirstChild(Config.RibbonTemplateName)
		local sourceRoot = source and source:FindFirstChild("RibbonRoot")
		local sourceBeam = sourceRoot and sourceRoot:FindFirstChildWhichIsA("Beam")
		if not (sourceRoot and sourceRoot:IsA("BasePart") and sourceBeam) then
			if not warnedMissingTemplate then
				warnedMissingTemplate = true
				warn(
					("QuestGuideRibbon: no `%s` Model holding a RibbonRoot part with a Beam in ReplicatedStorage -- the quest trail draws arrows only."):format(
						Config.RibbonTemplateName
					)
				)
			end
			return false
		end

		-- A stale root means the pools point at destroyed instances, so they are dropped rather
		-- than reused.
		if root then root:Destroy() end
		releasePools()

		root = sourceRoot:Clone()
		root.Name = "RibbonRoot"
		root.Anchored = true
		root.CanCollide = false
		root.CanQuery = false
		root.CanTouch = false
		root.CastShadow = false
		root.Transparency = 1
		root.CFrame = CFrame.identity

		-- Every Beam under the root is a layer, and each span clones all of them. That is what
		-- makes the usual core-and-halo build a Studio-only change: drop a second wider, dimmer
		-- Beam into the template and the ribbon picks it up with no code change here. Separate
		-- the layers with ZOffset so they stack instead of z-fighting.
		table.clear(beamSources)
		for _, child in ipairs(root:GetChildren()) do
			if child:IsA("Beam") then
				-- Sources stay parented as the styling reference but must never render: they hold
				-- no attachments, and disabling them stops a template left Enabled from flashing
				-- a stray beam at the root's position.
				child.Enabled = false
				table.insert(beamSources, child)
			end
		end

		root.Parent = folder
		return true
	end

	local function acquireNode(index)
		local existing = nodes[index]
		if existing then return existing end
		local attachment = Instance.new("Attachment")
		attachment.Name = ("Node%02d"):format(index)
		attachment.Parent = root
		nodes[index] = attachment
		return attachment
	end

	local function acquireBeam(index)
		local existing = beams[index]
		if existing then return existing end

		local layers = table.create(#beamSources)
		for order, source in ipairs(beamSources) do
			local clone = source:Clone()
			clone.Name = ("Ribbon%02d_%s"):format(index, source.Name)
			-- Geometrically two segments would draw this span, but the engine divides Segments by
			-- up to 10 at the lowest graphics quality and a beam that lands below two segments
			-- vanishes outright. The floor is a correctness guard, so an authored value may raise
			-- it, never lower it.
			clone.Segments = math.max(clone.Segments, Config.RibbonSegments)
			clone.Enabled = false
			clone.Parent = root
			layers[order] = {
				Beam = clone,
				Keypoints = source.Transparency.Keypoints,
				Brightness = clone.Brightness,
			}
		end

		local entry = { Layers = layers, Alpha = -1 }
		beams[index] = entry
		return entry
	end

	-- Every layer of a span shares one alpha, so they quantise identically and either all skip the
	-- rebuild or all take it. Enabled is re-asserted each frame rather than only on a change, so a
	-- span coming back from hidden does not stay dark at an unchanged alpha.
	local function setBeamAlpha(entry, alpha)
		local applied = entry.Alpha
		for _, layer in ipairs(entry.Layers) do
			applied = SequenceFade.apply(layer.Beam, "Transparency", layer.Keypoints, alpha, entry.Alpha)
			layer.Beam.Enabled = applied > 0
		end
		entry.Alpha = applied
	end

	local function hideBeamsFrom(index)
		for slot = index, #beams do
			for _, layer in ipairs(beams[slot].Layers) do
				layer.Beam.Enabled = false
			end
		end
	end

	local ribbon = {}

	function ribbon.Update(path, now)
		local tuning = ctx.Tuning
		if tuning.RibbonEnabled == false then ribbon.Clear(); return end
		if not ensureRoot() then return end

		local spacing = tuning.RibbonStep
		local count = math.floor(path.Span / spacing) + 1
		if count > tuning.RibbonMaxNodes then
			count = tuning.RibbonMaxNodes
			spacing = count > 1 and path.Span / (count - 1) or spacing
		end
		if count < 2 then ribbon.Clear(); return end

		local roll = math.rad(tuning.RibbonRoll)
		local hover = tuning.RibbonHover
		local placed = 0
		local previousAlpha

		for index = 1, count do
			-- Laid back from the target end, matching the arrows: node 1 is the one nearest the
			-- target and holds still while the player moves.
			local back = path.TailGap + (index - 1) * spacing
			local along = path.Distance - back
			local point = path.Origin + path.Heading * along
			local fallbackY = path.Origin.Y + (path.Goal.Y - path.Origin.Y) * (along / path.Distance)

			local groundY, normal = ctx.Ground(point.X, point.Z, fallbackY)
			local frame = nodeCFrame(Vector3.new(point.X, groundY + hover, point.Z), path.Heading, normal, roll)
			if not frame then break end
			acquireNode(index).CFrame = frame

			local alpha = path.Arrive * math.clamp((along - path.HeadGap) / path.FadeSpan, 0, 1)
			-- Keyed on having a preceding node rather than on the index, so a node that failed to
			-- resolve a frame cannot leave a span reaching back to nothing.
			if previousAlpha then
				local entry = acquireBeam(index - 1)
				-- A span is only as visible as its dimmer end, otherwise the last span reaches
				-- past the fading head node into nothing.
				setBeamAlpha(entry, math.min(alpha, previousAlpha))

				-- Phase from distance along the path, so a crest holds its place in the world and
				-- the wave travels down the ribbon toward the target instead of blinking in unison.
				local wave = math.sin((now / tuning.PulseSeconds + back / tuning.PulseLength) * math.pi * 2)
				local pulse = 1 - tuning.PulseDepth * (0.5 + 0.5 * wave)
				for _, layer in ipairs(entry.Layers) do
					-- Attachment0 is the node further from the target, so an authored directional
					-- texture reads toward the target rather than back at the player.
					layer.Beam.Attachment0 = nodes[index]
					layer.Beam.Attachment1 = nodes[index - 1]
					layer.Beam.Brightness = layer.Brightness * pulse
				end
				placed = index - 1
			end
			previousAlpha = alpha
		end

		hideBeamsFrom(placed + 1)
	end

	function ribbon.Clear()
		hideBeamsFrom(1)
	end

	function ribbon.Destroy()
		if root then root:Destroy(); root = nil end
		releasePools()
	end

	return ribbon
end

return QuestGuideRibbon
