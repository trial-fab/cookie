-- QuestGuideRunner — the mote that flies the quest path from the player toward the target on a loop.
--
-- This is the one part of the guide trail a Trail belongs on. A Trail draws the path its
-- attachments sweep through the world, so it renders nothing on the arrows (anchored at the target
-- end by design) and everything on a mote that actually travels. It is also the only element that
-- states a direction outright rather than implying one, which is what the arrows' bob wave and the
-- ribbon's texture scroll are both doing indirectly.
--
-- Owns motion and fade only; the mote's look and the Trail's styling are authored in the Studio
-- template.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SequenceFade = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SequenceFade"))

local QuestGuideRunner = {}

function QuestGuideRunner.new(ctx)
	local Config = ctx.Config
	local model
	local part
	local trail
	local authoredPartTransparency
	local authoredTrailKeypoints
	local trailAlpha
	local currentPass
	local warnedMissingTemplate = false

	local function ensurePart()
		if model and model.Parent then return true end

		local folder = ctx.Folder()
		if not folder then return false end

		local source = ReplicatedStorage:FindFirstChild(Config.RunnerTemplateName)
		local sourcePart = source and source:FindFirstChild("Runner")
		local sourceTrail = sourcePart and sourcePart:FindFirstChildWhichIsA("Trail")
		if not (sourcePart and sourcePart:IsA("BasePart") and sourceTrail) then
			if not warnedMissingTemplate then
				warnedMissingTemplate = true
				warn(
					("QuestGuideRunner: no `%s` Model holding a Runner part with a Trail in ReplicatedStorage -- the quest trail runs no mote."):format(
						Config.RunnerTemplateName
					)
				)
			end
			return false
		end

		if model then model:Destroy() end

		model = source:Clone()
		part = model:FindFirstChild("Runner")
		trail = part:FindFirstChildWhichIsA("Trail")
		part.Anchored = true
		part.CanCollide = false
		-- Matching the arrows: nothing in the guide trail may intercept a placement raycast, a
		-- ProximityPrompt, or the trail's own ground probes.
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false

		authoredPartTransparency = part.Transparency
		authoredTrailKeypoints = trail.Transparency.Keypoints
		trailAlpha = nil
		currentPass = nil

		-- Parented hidden and stationary. The clone arrives at the template's own position, and
		-- Update can bail before placing it (a frame landing in the rest gap), so an authored-
		-- visible mote would otherwise flash wherever the template happens to sit.
		part.Transparency = 1
		trail.Enabled = false
		model.Parent = folder
		return true
	end

	local function setAlpha(alpha)
		part.Transparency = 1 - alpha * (1 - authoredPartTransparency)
		trailAlpha = SequenceFade.apply(trail, "Transparency", authoredTrailKeypoints, alpha, trailAlpha)
	end

	local runner = {}

	-- Returns the mote's current distance back from the target and the index of the pass it is on,
	-- or nil when it is not flying. The arrow cascade phases off this rather than off a clock, so
	-- the mote is the visible cause of the arrows lighting rather than a third thing sharing the
	-- same line; the pass index is what lets the arrows tell a new pass from continued travel.
	function runner.Update(path, now)
		local tuning = ctx.Tuning
		-- Below RunnerMinSpan a pass is over before it reads as travel, so the mote sits out and
		-- leaves the short-range case to the arrows.
		if tuning.RunnerEnabled == false or path.Span < Config.RunnerMinSpan then runner.Clear(); return nil end
		if not ensurePart() then return nil end

		local duration = tuning.RunnerSeconds
		local period = duration + tuning.RunnerGap
		local pass = math.floor(now / period)
		local phase = now - pass * period

		if phase > duration then runner.Clear(); return nil end

		-- Flies from the player end of the trail toward the target end: the direction to walk.
		local t = phase / duration
		local back = path.TailGap + path.Span * (1 - t)
		local along = path.Distance - back
		local point = path.Origin + path.Heading * along
		local fallbackY = path.Origin.Y + (path.Goal.Y - path.Origin.Y) * (along / path.Distance)
		local groundY = ctx.Ground(point.X, point.Z, fallbackY)

		local position = Vector3.new(point.X, groundY + tuning.RunnerHover, point.Z)
		part.CFrame = CFrame.lookAt(position, position + path.Heading)

		local fade = tuning.RunnerFade
		local envelope = fade > 0 and math.min(t / fade, (1 - t) / fade, 1) or 1
		setAlpha(path.Arrive * math.clamp(envelope, 0, 1))

		if pass ~= currentPass then
			-- First frame of a pass, so the mote has just jumped from the target end back to the
			-- player end. A Trail draws whatever its attachments sweep, and leaving it live across
			-- that jump would streak a single frame of it straight across the crater. Clearing
			-- here rather than on the way out also covers a zero-length RunnerGap, where the mote
			-- never parks between passes.
			currentPass = pass
			trail.Enabled = false
			trail:Clear()
		else
			trail.Enabled = trailAlpha > 0
		end

		return back, pass
	end

	-- Idempotent: a nil `currentPass` is the parked marker, so resting between passes costs one
	-- comparison a frame rather than a redundant Trail:Clear() on every one of them.
	function runner.Clear()
		if not (part and part.Parent) or currentPass == nil then return end
		trail.Enabled = false
		trail:Clear()
		part.Transparency = 1
		trailAlpha = nil
		-- Dropped so a pass resumed after any pause starts with the same clean-slate handling as
		-- a wrap, instead of inheriting a stale pass index and skipping the clear.
		currentPass = nil
	end

	function runner.Destroy()
		if model then model:Destroy(); model = nil end
		part, trail = nil, nil
	end

	return runner
end

return QuestGuideRunner
