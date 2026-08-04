-- QuestGuideWorldTrail — the guide trail that links the player to a distant world target.
--
-- Orchestrates three layers over one shared path: the arrows (here), the continuous ground ribbon
-- beneath them (QuestGuideRibbon) and the mote that flies the path on a loop (QuestGuideRunner).
-- All three sample the same heading and the same ground cache, so they never disagree about where
-- the path runs. See QuestGuideTrailConfig for the layout contract (anchored at the target end,
-- fixed spacing, ground-following hover).
--
-- Owns nothing but motion: every visual is a Studio-authored template cloned into a pooled
-- Workspace folder. Clones are CanQuery=false so they never intercept a placement raycast, a
-- ProximityPrompt, or this module's own ground probes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("QuestGuideTrailConfig"))
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local QuestGuideBeacon = require(script.Parent:WaitForChild("QuestGuideBeacon"))
local QuestGuideRibbon = require(script.Parent:WaitForChild("QuestGuideRibbon"))
local QuestGuideRunner = require(script.Parent:WaitForChild("QuestGuideRunner"))

local TUNING_PREFIX = "QuestGuideTrail."
local TUNED_KEYS = {
	"Enabled",
	"Spacing",
	"MaxArrows",
	"TailGap",
	"HeadGap",
	"ArriveRadius",
	"Hover",
	"MaxPitch",
	"BridgeEnabled",
	"BridgeMax",
	"BobHeight",
	"BobSeconds",
	"WaveLength",
	"FadeSpan",

	"CascadeEnabled",
	"CascadeLead",
	"CascadeTail",
	"CascadeColor",
	"CascadeTint",
	"CascadeRest",
	"CascadeScale",
	"CascadeLift",
	"CascadeBurst",
	"CascadeBurstCount",

	"RibbonEnabled",
	"RibbonStep",
	"RibbonMaxNodes",
	"RibbonHover",
	"RibbonRoll",
	"PulseDepth",
	"PulseSeconds",
	"PulseLength",

	"RunnerEnabled",
	"RunnerSeconds",
	"RunnerGap",
	"RunnerHover",
	"RunnerFade",

	"BeaconEnabled",
	"BeaconHeight",
	"BeaconBase",
}

-- How far past one spacing a 3D gap must stretch before it earns a bridge arrow. Kept a constant
-- rather than a tunable: it is the threshold that separates "sloped" from "stepped", not a look
-- value, and BridgeEnabled/BridgeMax already cover the dial the feature actually needs.
local BRIDGE_SLACK = 0.15

local QuestGuideWorldTrail = {}

local function targetPosition(instance)
	if not (instance and instance.Parent) then return nil end
	if instance:IsA("BasePart") then return instance.Position end
	if instance:IsA("Model") then return instance:GetPivot().Position end
	return nil
end

-- Pitch comes from the segment to the next arrow toward the target, not from the surface an arrow
-- stands on.
--
-- A surface normal only describes the face underfoot, so an arrow standing on the flat roof of a
-- tall object reads as perfectly level even though its neighbour sits far below it -- which is
-- exactly the vertical gap that opens where the trail steps up over something. Aiming each arrow
-- at where the next one actually is keeps the chain reading as one continuous line up and over,
-- and costs nothing on flat ground, where the segment is level and the pitch falls out at zero.
--
-- Yaw still comes from the flat segment alone. Seating the arrow fully in the surface plane
-- (normal as up) swings it up to 50 degrees off the target on the banked crater wall, because
-- projecting the heading onto a side-tilted plane rotates it in XZ.
--
-- `fromBase`/`aimBase` are the un-animated hover positions, so bob and cascade lift move the arrow
-- without wobbling its aim -- the lift only ever applies to the one arrow the crest is on, and
-- pitching off it would make the whole chain twitch as the cascade went by.
local function arrowCFrame(renderPosition, fromBase, aimBase, fallbackHeading, maxPitch)
	local delta = aimBase - fromBase
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < 1e-3 then
		-- The next point is directly overhead or underfoot, which a zero-length TailGap can
		-- produce at the target end. Hold the path heading and pitch to the clamp, so the arrow
		-- still reads as climbing rather than snapping level.
		local sign = delta.Y >= 0 and 1 or -1
		return CFrame.lookAt(renderPosition, renderPosition + fallbackHeading) * CFrame.Angles(sign * maxPitch, 0, 0)
	end
	local pitch = math.clamp(math.atan2(delta.Y, flat.Magnitude), -maxPitch, maxPitch)
	return CFrame.lookAt(renderPosition, renderPosition + flat.Unit) * CFrame.Angles(pitch, 0, 0)
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
		local spark
		-- Re-seat the pivot on the geometry's own centre before anything positions it. A Model with
		-- no PrimaryPart keeps whatever WorldPivot it was authored with, and the arrow template's
		-- sits half a stud off its union -- along the model's X, which PivotTo maps to the axis
		-- perpendicular to the path. Every arrow was being laid half a stud to one side of the line
		-- the ribbon and the runner both follow. Doing it here rather than in the template keeps it
		-- correct however the asset is re-authored.
		clone.WorldPivot = clone:GetBoundingBox()
		local parts = {}
		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
				descendant.CastShadow = false
				-- A UnionOperation stores its Color property but does not render it unless this
				-- flag is set -- with it off the union draws the colours baked in from the parts it
				-- was built from, which is exactly why the cascade tint had no visible effect. The
				-- trade is that the union then renders ONE uniform colour, so a deliberately
				-- multi-tone union arrow cannot be cascade-tinted at all; that case wants a
				-- Highlight over the model instead.
				if descendant:IsA("UnionOperation") then descendant.UsePartColor = true end
				table.insert(parts, {
					Part = descendant,
					Transparency = descendant.Transparency,
					Color = descendant.Color,
				})
			elseif descendant:IsA("ParticleEmitter") then
				-- Held at zero and fired with Emit(), so a template left streaming does not turn
				-- the whole trail into a permanent particle fountain.
				descendant.Rate = 0
				spark = spark or descendant
			end
		end
		clone.Parent = folder

		local arrow = { Model = clone, Parts = parts, Spark = spark, Flare = -1 }
		pool[index] = arrow
		return arrow
	end

	local function setArrowVisible(arrow, alpha)
		for _, entry in ipairs(arrow.Parts) do
			entry.Part.Transparency = 1 - alpha * (1 - entry.Transparency)
		end
	end

	-- Flare strength for an arrow at `back`, given where the runner currently is.
	--
	-- Asymmetric on purpose. `delta > 0` means the runner is still further from the target than
	-- this arrow, so the arrow comes up over the short CascadeLead; once passed it falls back over
	-- the much longer CascadeTail, leaving a lit tail stretching toward the player. A symmetric
	-- falloff reads as a blob of light sliding along -- the short attack and long decay is what
	-- makes it read as a chase.
	local function cascadeAt(back, runnerBack)
		if runnerBack == nil or tuning.CascadeEnabled == false then return 0 end
		local delta = runnerBack - back
		local width = delta >= 0 and tuning.CascadeLead or tuning.CascadeTail
		if width <= 0 then return 0 end
		local amount = 1 - math.abs(delta) / width
		if amount <= 0 then return 0 end
		-- Squared so the crest stays tight and the shoulders stay dark, rather than lifting half
		-- the trail at once.
		return amount * amount
	end

	-- Colour and scale are stepped, so the arrows outside the cascade window -- almost all of them
	-- -- write nothing at all. Only the handful the runner is currently over cost anything, which
	-- is what keeps this bounded by the width of the flare rather than by MaxArrows.
	local CASCADE_STEPS = 32
	local function setArrowFlare(arrow, flare, visible, runnerBack, runnerPass, back)
		-- Evaluated every frame, ahead of the stepped work below.
		--
		-- The trigger is the runner crossing this arrow -- `approaching` flipping true to false --
		-- rather than the flare clearing a threshold. A threshold is a window in space, and the
		-- runner moves 2 studs a frame at the default speed and 12 at the fastest, so it steps
		-- straight over a 7-stud crest and the arrow never sparks. A sign change has no width and
		-- cannot be missed at any speed or frame rate.
		if arrow.Spark then
			-- An arrow still marked approaching when a pass ends was never crossed, because the
			-- runner stops ON the arrow nearest the target rather than travelling past it. Relying
			-- on a frame landing exactly on the endpoint works only with perfectly uniform frame
			-- times, so in practice that arrow would be the one that never sparks. Firing on
			-- arrival closes it.
			local function fireOnArrival()
				if arrow.Approaching and visible > 0.5 then
					arrow.Spark:Emit(tuning.CascadeBurstCount)
				end
				arrow.Approaching = nil
			end

			if tuning.CascadeBurst == false then
				arrow.Pass, arrow.Approaching = nil, nil
			elseif runnerBack == nil then
				-- Guarded on Pass so this runs once, on the frame the pass ends, rather than every
				-- frame of the rest gap.
				if arrow.Pass ~= nil then
					fireOnArrival()
					arrow.Pass = nil
				end
			else
				if arrow.Pass ~= runnerPass then
					-- Same arrival case reached the other way: at RunnerGap 0 there is no idle
					-- frame between passes, so the wrap is the only place to catch it.
					if arrow.Pass ~= nil then fireOnArrival() end
					-- A pass starts with the runner at the far end, so every arrow is ahead of it.
					-- Seeding true is what lets an arrow the runner begins exactly on top of ever
					-- register as crossed.
					arrow.Pass = runnerPass
					arrow.Approaching = true
				end
				local approaching = runnerBack > back
				-- Visibility-gated so a trail fading out on arrival, or an arrow still ramping in
				-- at the player end, does not throw sparks from something barely drawn.
				if arrow.Approaching and not approaching and visible > 0.5 then
					arrow.Spark:Emit(tuning.CascadeBurstCount)
				end
				arrow.Approaching = approaching
			end
		end

		local quantised = math.floor(flare * CASCADE_STEPS + 0.5)
		if arrow.Flare == quantised then return end
		arrow.Flare = quantised

		local amount = quantised / CASCADE_STEPS
		-- Tinted from the arrow's own authored colour rather than to an absolute one, so an arrow
		-- restyled in Studio still cascades correctly without touching the config. The rest floor
		-- keeps arrows the runner is nowhere near lit enough to read, rather than letting the whole
		-- trail go dark between passes.
		local rest = tuning.CascadeRest
		local tint = (rest + (1 - rest) * amount) * tuning.CascadeTint
		for _, entry in ipairs(arrow.Parts) do
			entry.Part.Color = entry.Color:Lerp(tuning.CascadeColor, tint)
		end
		arrow.Model:ScaleTo(1 + tuning.CascadeScale * amount)
	end

	-- Ground height under an XZ point, cached on a coarse grid. `fallbackY` is the interpolated
	-- path height, used when the probe misses or the frame's cast budget is spent.
	--
	-- The budget is frame-scoped rather than passed along, because the arrows, the ribbon and the
	-- runner all draw from it. Spending it in that order is deliberate: the arrows are the primary
	-- read, so on a frame that cannot afford every probe they get exact ground and the layers
	-- beneath them briefly interpolate.
	local frameBudget = 0
	local function groundAt(x, z, fallbackY)
		local size = Config.GroundCacheStuds
		local key = ("%d,%d"):format(math.floor(x / size), math.floor(z / size))
		local cached = groundCache[key]
		local now = os.clock()
		if cached and now - cached.At < Config.GroundCacheSeconds then
			return cached.Y, cached.Normal
		end
		if frameBudget <= 0 then
			return cached and cached.Y or fallbackY, cached and cached.Normal or Vector3.yAxis
		end

		local origin = Vector3.new(x, fallbackY + Config.ProbeUp, z)
		local result = Workspace:Raycast(origin, Vector3.new(0, -(Config.ProbeUp + Config.ProbeDown), 0), castParams)
		local y = result and result.Position.Y or fallbackY
		local normal = result and result.Normal or Vector3.yAxis
		groundCache[key] = { Y = y, Normal = normal, At = now }
		frameBudget -= 1
		return y, normal
	end

	local layerContext = {
		Config = Config,
		Tuning = tuning,
		Ground = groundAt,
		Folder = function() return folder end,
	}
	local ribbon = QuestGuideRibbon.new(layerContext)
	local runner = QuestGuideRunner.new(layerContext)
	local beacon = QuestGuideBeacon.new(layerContext)

	local function hideFrom(index)
		for slot = index, #pool do
			local arrow = pool[slot]
			if arrow then arrow.Model.Parent = nil end
		end
	end

	local function clear()
		hideFrom(1)
		ribbon.Clear()
		runner.Clear()
		beacon.Clear()
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
		frameBudget = Config.CastBudget
		local now = os.clock()

		-- One description of the path, shared by every layer, so no layer can drift from the
		-- arrows it sits under.
		local path = {
			Origin = origin,
			Goal = goal,
			Heading = heading,
			Distance = distance,
			Span = span,
			Arrive = arrive,
			TailGap = tuning.TailGap,
			HeadGap = tuning.HeadGap,
			FadeSpan = tuning.FadeSpan,
		}

		-- The runner moves first because the arrows phase their cascade off where it actually is.
		-- It costs one ground probe out of the frame budget before the arrows draw from it, which
		-- is the price of the cascade having a visible cause instead of a private clock.
		local runnerBack, runnerPass = runner.Update(path, now)

		-- Arrow 1 sits nearest the target and has no forward neighbour to aim at, so the ground
		-- under the target itself stands in for one. Shares the beacon's probe of the same column,
		-- so after the first frame it is a cache hit rather than a cast.
		local maxPitch = math.rad(tuning.MaxPitch)
		local goalGroundY = groundAt(goal.X, goal.Z, goal.Y)
		local previousBase = Vector3.new(goal.X, goalGroundY + tuning.Hover, goal.Z)

		-- Stations are the nominal arrow slots, evenly spaced across the FLAT path. Bridge arrows
		-- are filled in between them wherever the ground steps: a sheer step leaves neighbouring
		-- stations one spacing apart horizontally but tens of studs apart vertically, with nothing
		-- in the gap. Spacing the fill by the 3D distance restores an even density along the path
		-- the player actually walks, and does nothing at all on flat ground, where the 3D and flat
		-- distances are equal.
		local bridgeMax = tuning.BridgeEnabled == false and 0 or tuning.BridgeMax
		local placed = 0
		local exhausted = false
		local anchorBase, anchorBack

		for station = 1, count do
			-- Distance back from the target, so station 1 holds its place while the player moves.
			local stationBack = tuning.TailGap + (station - 1) * spacing
			local stationAlong = distance - stationBack
			local point = origin + heading * stationAlong
			local fallbackY = origin.Y + (goal.Y - origin.Y) * (stationAlong / distance)
			local groundY = groundAt(point.X, point.Z, fallbackY)
			local stationBase = Vector3.new(point.X, groundY + tuning.Hover, point.Z)

			local fill = 0
			if anchorBase then
				-- BRIDGE_SLACK is a deadzone, not an epsilon. Rounding straight off the ratio makes
				-- any gap a hair over one spacing buy a whole extra arrow and halve the density: an
				-- 11-degree slope measures 10.2 against a spacing of 10 and was doubling the arrow
				-- count across the entire trail. The slack absorbs ordinary slopes, which already
				-- look continuous, and leaves the fill for genuine steps.
				local gap = (stationBase - anchorBase).Magnitude
				fill = math.clamp(math.ceil(gap / spacing - BRIDGE_SLACK) - 1, 0, bridgeMax)
			end

			for sub = 0, fill do
				if placed >= tuning.MaxArrows then exhausted = true; break end
				local arrow = acquire(placed + 1)
				if not arrow then exhausted = true; break end

				local base, back
				if sub < fill then
					-- Straight 3D lerp rather than another ground probe: the point of these is to
					-- span the face of the step, and the ground under them IS the step.
					local t = (sub + 1) / (fill + 1)
					base = anchorBase:Lerp(stationBase, t)
					back = anchorBack + (stationBack - anchorBack) * t
				else
					base, back = stationBase, stationBack
				end

				local along = distance - back
				local flare = cascadeAt(back, runnerBack)
				local phase = (now / tuning.BobSeconds + back / tuning.WaveLength) * math.pi * 2
				local bob = math.sin(phase) * tuning.BobHeight
				-- Lift rides the unquantised flare: the position is rewritten every frame anyway,
				-- so there is nothing to save by stepping it, and smooth beats cheap here.
				local lift = tuning.CascadeLift * flare
				local position = base + Vector3.new(0, bob + lift, 0)

				if arrow.Model.Parent ~= folder then arrow.Model.Parent = folder end
				-- Aimed at the last arrow placed, which is one step closer to the target -- a
				-- bridge arrow as readily as a station, so the climb reads as one line.
				arrow.Model:PivotTo(arrowCFrame(position, base, previousBase, heading, maxPitch))
				previousBase = base

				-- The furthest arrow appears the instant `along` clears HeadGap, so ramp it in over
				-- the next few studs. Deeper arrows sit far past HeadGap and are unaffected.
				local entering = math.clamp((along - tuning.HeadGap) / tuning.FadeSpan, 0, 1)
				local visible = arrive * entering
				setArrowVisible(arrow, visible)
				setArrowFlare(arrow, flare, visible, runnerBack, runnerPass, back)

				placed += 1
			end

			anchorBase, anchorBack = stationBase, stationBack
			if exhausted then break end
		end

		-- Hide from what was actually placed, not from `count`: if the template vanished partway
		-- the unreached arrows would otherwise linger at last frame's positions.
		hideFrom(placed + 1)

		ribbon.Update(path, now)
		beacon.Update(path, now)
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
		-- Before the folder, so each layer drops its own references rather than being left
		-- holding instances the folder has already taken down.
		ribbon.Destroy()
		runner.Destroy()
		beacon.Destroy()
		if folder then folder:Destroy(); folder = nil end
	end

	return trail
end

return QuestGuideWorldTrail
