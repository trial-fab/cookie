-- QuestGuideWorldTrail — the arrow trail that links the player to a distant world guide target.
--
-- Owns nothing but motion: the arrow itself is a Studio-authored template cloned into a pooled
-- Workspace folder. See QuestGuideTrailConfig for the layout contract (arrows anchored at the
-- target end, fixed spacing, ground-following hover).
--
-- Clones are CanQuery=false so they never intercept a placement raycast, a ProximityPrompt, or
-- this module's own ground probes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("QuestGuideTrailConfig"))
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))

local TUNING_PREFIX = "QuestGuideTrail."
local TUNED_KEYS = {
	"Enabled",
	"Spacing",
	"MaxArrows",
	"TailGap",
	"HeadGap",
	"ArriveRadius",
	"Hover",
	"BobHeight",
	"BobSeconds",
	"WaveLength",
	"FadeSpan",
}

local QuestGuideWorldTrail = {}

local function targetPosition(instance)
	if not (instance and instance.Parent) then return nil end
	if instance:IsA("BasePart") then return instance.Position end
	if instance:IsA("Model") then return instance:GetPivot().Position end
	return nil
end

-- Steep ground must never cost the arrow its aim, so yaw comes from the flat heading alone and
-- the surface normal only supplies pitch. Seating the arrow fully in the surface plane instead
-- (normal as up) swings it up to 50 degrees off the target on the banked crater wall, because
-- projecting the heading onto a side-tilted plane rotates it in XZ.
local MAX_PITCH = math.rad(55)

local function arrowCFrame(position, heading, normal)
	local pitch = math.clamp(math.asin(math.clamp(-normal:Dot(heading), -1, 1)), -MAX_PITCH, MAX_PITCH)
	return CFrame.lookAt(position, position + heading) * CFrame.Angles(pitch, 0, 0)
end

function QuestGuideWorldTrail.new()
	local player = Players.LocalPlayer
	local tuning = {}
	local observers = {}
	for _, key in ipairs(TUNED_KEYS) do
		tuning[key] = Config[key]
		table.insert(observers, DevTuning.observe(TUNING_PREFIX .. key, function(value)
			tuning[key] = value
		end))
	end

	local pool = {}
	local folder
	local connection
	local activeTarget
	local groundCache = {}

	local castParams = RaycastParams.new()
	castParams.FilterType = Enum.RaycastFilterType.Exclude
	castParams.IgnoreWater = true

	-- Characters are excluded so an arrow never rides on someone's head. Rebuilt on a timer
	-- rather than per frame: a 60-player server would otherwise allocate a filter list every
	-- frame to describe a set that changes on join/respawn.
	local filterRefreshedAt = -math.huge
	local function refreshCastFilter()
		local now = os.clock()
		if now - filterRefreshedAt < 0.5 then return end
		filterRefreshedAt = now
		local excluded = {}
		for _, other in ipairs(Players:GetPlayers()) do
			if other.Character then table.insert(excluded, other.Character) end
		end
		castParams.FilterDescendantsInstances = excluded
	end

	local warnedMissingTemplate = false
	local function template()
		local found = ReplicatedStorage:FindFirstChild(Config.TemplateName)
		if found and found:IsA("Model") then return found end
		if not warnedMissingTemplate then
			warnedMissingTemplate = true
			warn(
				("QuestGuideWorldTrail: no `%s` Model in ReplicatedStorage -- the quest arrow trail is invisible."):format(
					Config.TemplateName
				)
			)
		end
		return nil
	end

	local function acquire(index)
		local existing = pool[index]
		if existing then return existing end

		local source = template()
		if not source then return nil end

		local clone = source:Clone()
		clone.Name = ("Arrow%02d"):format(index)
		local parts = {}
		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
				descendant.CastShadow = false
				table.insert(parts, { Part = descendant, Transparency = descendant.Transparency })
			end
		end
		clone.Parent = folder

		local arrow = { Model = clone, Parts = parts }
		pool[index] = arrow
		return arrow
	end

	local function setArrowVisible(arrow, alpha)
		for _, entry in ipairs(arrow.Parts) do
			entry.Part.Transparency = 1 - alpha * (1 - entry.Transparency)
		end
	end

	-- Ground height under an XZ point, cached on a coarse grid. `fallbackY` is the interpolated
	-- path height, used when the probe misses or the frame's cast budget is spent.
	local function groundAt(x, z, fallbackY, budget)
		local size = Config.GroundCacheStuds
		local key = ("%d,%d"):format(math.floor(x / size), math.floor(z / size))
		local cached = groundCache[key]
		local now = os.clock()
		if cached and now - cached.At < Config.GroundCacheSeconds then
			return cached.Y, cached.Normal, budget
		end
		if budget <= 0 then
			return cached and cached.Y or fallbackY, cached and cached.Normal or Vector3.yAxis, budget
		end

		local origin = Vector3.new(x, fallbackY + Config.ProbeUp, z)
		local result = Workspace:Raycast(origin, Vector3.new(0, -(Config.ProbeUp + Config.ProbeDown), 0), castParams)
		local y = result and result.Position.Y or fallbackY
		local normal = result and result.Normal or Vector3.yAxis
		groundCache[key] = { Y = y, Normal = normal, At = now }
		return y, normal, budget - 1
	end

	local function hideFrom(index)
		for slot = index, #pool do
			local arrow = pool[slot]
			if arrow then arrow.Model.Parent = nil end
		end
	end

	local function clear()
		hideFrom(1)
	end

	local function step()
		if tuning.Enabled == false then clear(); return end

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local goal = targetPosition(activeTarget)
		if not (root and goal) then clear(); return end

		local origin = root.Position
		local flat = Vector3.new(goal.X - origin.X, 0, goal.Z - origin.Z)
		local distance = flat.Magnitude
		if distance < 1e-3 then clear(); return end

		local arrive = math.clamp((distance - tuning.ArriveRadius) / tuning.FadeSpan, 0, 1)
		if arrive <= 0 then clear(); return end

		-- Heading points from the player toward the target; arrows are laid back from the target.
		local heading = flat.Unit
		local span = distance - tuning.TailGap - tuning.HeadGap
		if span < 0 then clear(); return end

		local spacing = tuning.Spacing
		local count = math.floor(span / spacing) + 1
		if count > tuning.MaxArrows then
			count = tuning.MaxArrows
			spacing = count > 1 and span / (count - 1) or spacing
		end

		refreshCastFilter()
		local budget = Config.CastBudget
		local now = os.clock()

		local placed = 0
		for index = 1, count do
			local arrow = acquire(index)
			if not arrow then break end

			-- Distance back from the target, so arrow 1 holds its place while the player moves.
			local back = tuning.TailGap + (index - 1) * spacing
			local along = distance - back
			local point = origin + heading * along
			local fallbackY = origin.Y + (goal.Y - origin.Y) * (along / distance)

			local groundY, normal
			groundY, normal, budget = groundAt(point.X, point.Z, fallbackY, budget)

			local phase = (now / tuning.BobSeconds + back / tuning.WaveLength) * math.pi * 2
			local bob = math.sin(phase) * tuning.BobHeight
			local position = Vector3.new(point.X, groundY + tuning.Hover + bob, point.Z)

			if arrow.Model.Parent ~= folder then arrow.Model.Parent = folder end
			arrow.Model:PivotTo(arrowCFrame(position, heading, normal))

			-- The furthest arrow appears the instant `along` clears HeadGap, so ramp it in over
			-- the next few studs. Deeper arrows sit far past HeadGap and are unaffected.
			local entering = math.clamp((along - tuning.HeadGap) / tuning.FadeSpan, 0, 1)
			setArrowVisible(arrow, arrive * entering)

			placed = index
		end

		-- Hide from what was actually placed, not from `count`: if the template vanished partway
		-- the unreached arrows would otherwise linger at last frame's positions.
		hideFrom(placed + 1)
	end

	local trail = {}

	function trail.Start(instance)
		trail.Stop()
		if not targetPosition(instance) then return nil end

		folder = Workspace:FindFirstChild(Config.FolderName)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = Config.FolderName
			folder.Parent = Workspace
		end

		activeTarget = instance
		table.clear(groundCache)
		-- step() parents exactly the arrows this frame needs and hides the rest, so a restart
		-- never shows a stale pooled arrow.
		step()
		connection = RunService.Heartbeat:Connect(step)
		return trail.Stop
	end

	function trail.Stop()
		if connection then connection:Disconnect(); connection = nil end
		activeTarget = nil
		clear()
	end

	function trail.Destroy()
		trail.Stop()
		for _, observer in ipairs(observers) do observer:Disconnect() end
		table.clear(observers)
		for _, arrow in ipairs(pool) do arrow.Model:Destroy() end
		table.clear(pool)
		if folder then folder:Destroy(); folder = nil end
	end

	return trail
end

return QuestGuideWorldTrail
