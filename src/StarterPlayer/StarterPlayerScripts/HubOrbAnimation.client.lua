-- HubOrbAnimation -- per-player dormant/activated presentation for the central Ancient Core.
--
-- Studio owns both poses: the dormant pose is the instances' edit-time state, while
-- HubActivatedCFrame / HubActivatedPivot attributes preserve the user's final authored layout.
-- The server owns the cookie purchase and saved flag. This client only renders that player's
-- state, reveal, independent shell orbits, and core float.
--
-- BOTH states levitate. The activated core bobs on its own float; the dormant core -- authored
-- resting on the Thruster's mount ring -- hovers just clear of it, so the thing a player can walk
-- up the dais and reach reads as held there rather than set down. The dormant assembly moves as one
-- rigid body (core, covers, and the shell cocoon around them), because the cocoon is tight enough
-- that bobbing the core alone would push it through.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local HubCoreConfig = require(Shared:WaitForChild("HubCoreConfig"))
local Net = require(Shared:WaitForChild("Net"))
local NumberFormat = require(Shared:WaitForChild("NumberFormat"))

local DORMANT_FLOAT_PREFIX = "HubOrbFloat."
local DORMANT_FLOAT_KEYS = { "Enabled", "RestLift", "Amplitude", "LegSeconds" }

local ACTIVATED_CFRAME_ATTRIBUTE = "HubActivatedCFrame"
local ACTIVATED_PIVOT_ATTRIBUTE = "HubActivatedPivot"
local ACTIVATED_TRANSPARENCY_ATTRIBUTE = "HubActivatedTransparency"
local ACTIVATED_ENABLED_ATTRIBUTE = "HubActivatedEnabled"

local ORBIT_PERIOD_SECONDS = 24
local ORBIT_RADIUS = 3.6
local ANGLE_WOBBLE = math.rad(4)
local RADIAL_WOBBLE = 0.12
local HEIGHT_WOBBLE = 0.35
local FLOAT_HALF_DISTANCE = 0.25
local FLOAT_LEG_SECONDS = 2.4
local SHELL_COUNT = 5
local PHOTON_RING_COUNT = 2
local PHOTON_RING_BEAM_TRANSPARENCY = 0.16

local POWER_ON_SECONDS = 1.85
local POWER_ON_EXTRA_ORBIT_ANGLE = math.rad(70)
local HUD_REVEAL_SECONDS = 1.65
local HUD_START_SCALE = 0.08
local PROMPT_FEEDBACK_SECONDS = 2

local PHOTON_RING_SETTINGS = {
	{
		Period = 8.5,
		Direction = 1,
		PrecessionAxis = Vector3.new(0.1, 1, 0.05).Unit,
	},
	{
		Period = 11.5,
		Direction = -1,
		PrecessionAxis = Vector3.new(-0.15, 1, 0.2).Unit,
	},
}

local SHELL_SETTINGS = {
	{
		BaseHeight = 0.55,
		AngleLeg = 4.7,
		RadiusLeg = 5.3,
		HeightLeg = 3.1,
		SpinPeriod = 11,
		AngleDirection = 1,
		RadiusDirection = -1,
		HeightDirection = 1,
		SpinDirection = 1,
		SpinAxis = Vector3.new(0.7, 1, 0.2).Unit,
	},
	{
		BaseHeight = -0.35,
		AngleLeg = 6.1,
		RadiusLeg = 4.4,
		HeightLeg = 3.8,
		SpinPeriod = 14,
		AngleDirection = -1,
		RadiusDirection = 1,
		HeightDirection = -1,
		SpinDirection = -1,
		SpinAxis = Vector3.new(-0.3, 0.5, 1).Unit,
	},
	{
		BaseHeight = 0.15,
		AngleLeg = 5.4,
		RadiusLeg = 6.7,
		HeightLeg = 4.5,
		SpinPeriod = 17,
		AngleDirection = 1,
		RadiusDirection = 1,
		HeightDirection = -1,
		SpinDirection = 1,
		SpinAxis = Vector3.new(1, -0.2, 0.4).Unit,
	},
	{
		BaseHeight = -0.6,
		AngleLeg = 7.3,
		RadiusLeg = 5.8,
		HeightLeg = 3.4,
		SpinPeriod = 13,
		AngleDirection = -1,
		RadiusDirection = -1,
		HeightDirection = 1,
		SpinDirection = 1,
		SpinAxis = Vector3.new(0.2, 1, -0.6).Unit,
	},
	{
		BaseHeight = 0.35,
		AngleLeg = 5.9,
		RadiusLeg = 4.9,
		HeightLeg = 4.1,
		SpinPeriod = 19,
		AngleDirection = 1,
		RadiusDirection = -1,
		HeightDirection = -1,
		SpinDirection = -1,
		SpinAxis = Vector3.new(-0.8, 0.3, 1).Unit,
	},
}

local localPlayer = Players.LocalPlayer
local hub = Workspace:WaitForChild("HubPlazaDraft", 10)
local leaderboard = hub and hub:WaitForChild("LeaderboardSystem", 10)
if not leaderboard then
	warn("HubOrbAnimation: Workspace.HubPlazaDraft.LeaderboardSystem not found")
	return
end

local orbItems = leaderboard:FindFirstChild("OrbItems")
local shellGroup = leaderboard:FindFirstChild("Shells")
if not (orbItems and orbItems:IsA("Model") and shellGroup and shellGroup:IsA("Model")) then
	warn("HubOrbAnimation: LeaderboardSystem.OrbItems or Shells model not found")
	return
end

local photonRingGroup = orbItems:FindFirstChild("PhotonRings")
local core = orbItems:FindFirstChild("OrbCore")
if not (core and core:IsA("BasePart")) then
	warn("HubOrbAnimation: OrbCore not found")
	return
end

local activatedCoreCFrame = core:GetAttribute(ACTIVATED_CFRAME_ATTRIBUTE)
if typeof(activatedCoreCFrame) ~= "CFrame" then
	warn("HubOrbAnimation: Studio activation attributes are missing from OrbCore")
	return
end

local dormantCoreCFrame = core.CFrame

local orbFollowers = {}

local function trackOrbFollower(part, addedAtRuntime)
	if
		not part:IsA("BasePart")
		or part == core
		or orbFollowers[part]
		or (photonRingGroup and part:IsDescendantOf(photonRingGroup))
	then
		return
	end

	local dormantCFrame = part.CFrame
	local activatedCFrame = part:GetAttribute(ACTIVATED_CFRAME_ATTRIBUTE)
	if addedAtRuntime then
		-- DevConsole preview layers are cloned into the already-moving assembly. Convert
		-- their live core-relative pose back into both authored endpoints so they join the
		-- same float/reveal motion without snapping.
		local liveRelativeCFrame = core.CFrame:ToObjectSpace(part.CFrame)
		if typeof(activatedCFrame) ~= "CFrame" then
			activatedCFrame = activatedCoreCFrame * liveRelativeCFrame
		end
		dormantCFrame = dormantCoreCFrame * activatedCoreCFrame:ToObjectSpace(activatedCFrame)
	elseif typeof(activatedCFrame) ~= "CFrame" then
		-- A newly authored cover without a saved activated pose still follows the core at
		-- its current Studio offset. Saved activation attributes remain preferred.
		activatedCFrame = activatedCoreCFrame * dormantCoreCFrame:ToObjectSpace(dormantCFrame)
	end

	-- Only the core-relative poses are kept: both states now place followers off a live core CFrame,
	-- so an absolute dormant pose would be a second truth that the float would immediately outdate.
	orbFollowers[part] = {
		part = part,
		activatedCFrame = activatedCFrame,
		dormantRelativeCFrame = dormantCoreCFrame:ToObjectSpace(dormantCFrame),
		activatedRelativeCFrame = activatedCoreCFrame:ToObjectSpace(activatedCFrame),
	}
end

for _, part in ipairs(orbItems:GetDescendants()) do
	trackOrbFollower(part, false)
end

orbItems.DescendantAdded:Connect(function(descendant)
	trackOrbFollower(descendant, true)
end)
orbItems.DescendantRemoving:Connect(function(descendant)
	if descendant:IsA("BasePart") then
		orbFollowers[descendant] = nil
	end
end)

local photonRings = {}
if photonRingGroup and photonRingGroup:IsA("Model") then
	for index = 1, PHOTON_RING_COUNT do
		local rig = photonRingGroup:FindFirstChild(string.format("PhotonRingRig%02d", index))
		local activatedCFrame = rig and rig:GetAttribute(ACTIVATED_CFRAME_ATTRIBUTE)
		if rig and rig:IsA("BasePart") and typeof(activatedCFrame) == "CFrame" then
			local beams = {}
			for _, descendant in ipairs(rig:GetDescendants()) do
				if descendant:IsA("Beam") then
					table.insert(beams, {
						beam = descendant,
						activatedWidth0 = descendant.Width0,
						activatedWidth1 = descendant.Width1,
					})
				end
			end
			table.insert(photonRings, {
				rig = rig,
				beams = beams,
				dormantCFrame = rig.CFrame,
				activatedRelativeCFrame = activatedCoreCFrame:ToObjectSpace(activatedCFrame),
			})
		else
			warn(string.format("HubOrbAnimation: PhotonRingRig%02d or its activation pose is missing", index))
		end
	end
end

local shells = table.create(SHELL_COUNT)
local activatedShellCFrames = table.create(SHELL_COUNT)
local dormantShellRelativeCFrames = table.create(SHELL_COUNT)
local shellRelativeRotations = table.create(SHELL_COUNT)
local largestShellCollisionDiameter = 0
for index = 1, SHELL_COUNT do
	local shell = shellGroup:FindFirstChild(string.format("OrbShell%02d", index))
	local activatedCFrame = shell and shell:GetAttribute(ACTIVATED_CFRAME_ATTRIBUTE)
	if not (shell and shell:IsA("BasePart") and typeof(activatedCFrame) == "CFrame") then
		warn(string.format("HubOrbAnimation: OrbShell%02d or its activation pose is missing", index))
		return
	end
	table.insert(shells, shell)
	table.insert(activatedShellCFrames, activatedCFrame)
	table.insert(dormantShellRelativeCFrames, dormantCoreCFrame:ToObjectSpace(shell.CFrame))
	table.insert(shellRelativeRotations, activatedCoreCFrame:ToObjectSpace(activatedCFrame).Rotation)
	largestShellCollisionDiameter = math.max(largestShellCollisionDiameter, shell.Size.Magnitude)
end

local huds = {}
for index = 1, 3 do
	local model = leaderboard:FindFirstChild(string.format("Hud%d", index))
	local activatedPivot = model and model:GetAttribute(ACTIVATED_PIVOT_ATTRIBUTE)
	if not (model and model:IsA("Model") and typeof(activatedPivot) == "CFrame") then
		warn(string.format("HubOrbAnimation: Hud%d or its activation pose is missing", index))
		return
	end

	local record = {
		model = model,
		activatedPivot = activatedPivot,
		activatedRelativePivot = activatedCoreCFrame:ToObjectSpace(activatedPivot),
		activatedScale = model:GetScale(),
		dormantPivot = model:GetPivot(),
		parts = {},
		surfaceGuis = {},
	}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local transparency = descendant:GetAttribute(ACTIVATED_TRANSPARENCY_ATTRIBUTE)
			if typeof(transparency) ~= "number" then
				warn("HubOrbAnimation: missing HUD activation transparency on " .. descendant:GetFullName())
				return
			end
			table.insert(record.parts, {
				part = descendant,
				activatedTransparency = transparency,
			})
		elseif descendant:IsA("SurfaceGui") then
			local enabled = descendant:GetAttribute(ACTIVATED_ENABLED_ATTRIBUTE)
			if typeof(enabled) ~= "boolean" then
				warn("HubOrbAnimation: missing HUD activation state on " .. descendant:GetFullName())
				return
			end
			table.insert(record.surfaceGuis, {
				gui = descendant,
				activatedEnabled = enabled,
			})
		end
	end
	table.insert(huds, record)
end

local prompt = core:FindFirstChild("ActivatePrompt")
if not (prompt and prompt:IsA("ProximityPrompt")) then
	warn("HubOrbAnimation: OrbItems.OrbCore.ActivatePrompt not found")
	return
end
prompt.ActionText = ("Activate %s Cookies"):format(NumberFormat.exact(HubCoreConfig.ActivationCostCookies))
prompt.ObjectText = "Ancient Core"
prompt.HoldDuration = HubCoreConfig.PromptHoldDuration
prompt.MaxActivationDistance = HubCoreConfig.PromptMaxDistance

-- Each shell owns a 72-degree lane and may wobble four degrees either way. Refuse only the
-- continuous orbit if later Studio art grows too large for that mathematical separation.
local minimumAngle = math.pi * 2 / SHELL_COUNT - ANGLE_WOBBLE * 2
local minimumCentreDistance = 2 * (ORBIT_RADIUS - RADIAL_WOBBLE) * math.sin(minimumAngle / 2)
local orbitIsSafe = minimumCentreDistance > largestShellCollisionDiameter
if not orbitIsSafe then
	warn(
		string.format(
			"HubOrbAnimation: orbital lanes are unsafe (%.3f centre distance, %.3f required)",
			minimumCentreDistance,
			largestShellCollisionDiameter
		)
	)
end

local orbitPhase = Instance.new("NumberValue")
orbitPhase.Name = "OrbitPhase"
orbitPhase.Parent = script

local shellMotion = table.create(SHELL_COUNT)
for index = 1, SHELL_COUNT do
	local motion = {}
	for _, field in ipairs({ "Angle", "Radius", "Height", "Spin" }) do
		local value = Instance.new("NumberValue")
		value.Name = string.format("Shell%02d%s", index, field)
		value.Parent = script
		motion[field] = value
	end
	shellMotion[index] = motion
end

local floatOffset = Instance.new("NumberValue")
floatOffset.Name = "FloatOffset"
floatOffset.Parent = script

local dormantFloatOffset = Instance.new("NumberValue")
dormantFloatOffset.Name = "DormantFloatOffset"
dormantFloatOffset.Parent = script

local photonRingPhases = {}
for index = 1, #photonRings do
	local phase = Instance.new("NumberValue")
	phase.Name = string.format("PhotonRing%02dPhase", index)
	phase.Parent = script
	table.insert(photonRingPhases, phase)
end

local orbitTween
local floatTween
local dormantFloatTween
local dormantFloatRunning = false
local dormantFloatTuning = {}
for _, key in ipairs(DORMANT_FLOAT_KEYS) do
	dormantFloatTuning[key] = DevTuning.get(DORMANT_FLOAT_PREFIX .. key)
end
local shellTweens = {}
local photonRingTweens = {}
local revealTweens = {}
local revealConnections = {}
local ambientRunning = false
local revealInProgress = false
local activationInFlight = false
local revealGeneration = 0

local function setHudPresentation(record, visible)
	for _, entry in ipairs(record.parts) do
		entry.part.Transparency = visible and entry.activatedTransparency or 1
	end
	for _, entry in ipairs(record.surfaceGuis) do
		entry.gui.Enabled = visible and entry.activatedEnabled or false
	end
end

local function setHudFade(record, alpha)
	alpha = math.clamp(alpha, 0, 1)
	for _, entry in ipairs(record.parts) do
		entry.part.Transparency = 1 + (entry.activatedTransparency - 1) * alpha
	end
	local showGui = alpha >= 0.22
	for _, entry in ipairs(record.surfaceGuis) do
		entry.gui.Enabled = showGui and entry.activatedEnabled or false
	end
end

local function cancelTweens(tweens)
	for _, tween in ipairs(tweens) do
		tween:Cancel()
	end
	table.clear(tweens)
end

local function setPhotonRingPresentation(alpha)
	alpha = math.clamp(alpha, 0, 1)
	for _, record in ipairs(photonRings) do
		for _, entry in ipairs(record.beams) do
			entry.beam.Enabled = alpha > 0
			entry.beam.Transparency = NumberSequence.new(1 + (PHOTON_RING_BEAM_TRANSPARENCY - 1) * alpha)
			entry.beam.Width0 = entry.activatedWidth0 * alpha
			entry.beam.Width1 = entry.activatedWidth1 * alpha
		end
	end
end

local function applyPhotonRingPose(liveCoreCFrame)
	for index, record in ipairs(photonRings) do
		local relative = record.activatedRelativeCFrame
		local settings = PHOTON_RING_SETTINGS[index]
		local precession = CFrame.fromAxisAngle(settings.PrecessionAxis, photonRingPhases[index].Value)
		record.rig.CFrame = liveCoreCFrame * CFrame.new(relative.Position) * precession * relative.Rotation
	end
end

local function stopAmbient(resetMotion)
	ambientRunning = false
	if orbitTween then
		orbitTween:Cancel()
		orbitTween = nil
	end
	if floatTween then
		floatTween:Cancel()
		floatTween = nil
	end
	cancelTweens(shellTweens)
	cancelTweens(photonRingTweens)
	if resetMotion ~= false then
		orbitPhase.Value = 0
		floatOffset.Value = 0
		for _, motion in ipairs(shellMotion) do
			motion.Angle.Value = 0
			motion.Radius.Value = 0
			motion.Height.Value = 0
			motion.Spin.Value = 0
		end
		for _, phase in ipairs(photonRingPhases) do
			phase.Value = 0
		end
	end
end

local function cancelReveal()
	revealGeneration += 1
	revealInProgress = false
	cancelTweens(revealTweens)
	for _, connection in ipairs(revealConnections) do
		connection:Disconnect()
	end
	table.clear(revealConnections)
end

-- The dormant assembly is rigid: the covers and the shell cocoon keep their authored offsets from
-- the core, so the whole thing rises and settles together instead of the core drifting out of its
-- own shell. Photon rings stay parked -- they are presented at zero while dormant.
local function applyDormantPose()
	if not core.Parent then
		return
	end
	local liveCoreCFrame = dormantCoreCFrame * CFrame.new(0, dormantFloatOffset.Value, 0)
	core.CFrame = liveCoreCFrame
	for _, record in pairs(orbFollowers) do
		record.part.CFrame = liveCoreCFrame * record.dormantRelativeCFrame
	end
	for index, shell in ipairs(shells) do
		shell.CFrame = liveCoreCFrame * dormantShellRelativeCFrames[index]
	end
end

local function stopDormantFloat()
	dormantFloatRunning = false
	if dormantFloatTween then
		dormantFloatTween:Cancel()
		dormantFloatTween = nil
	end
	dormantFloatOffset.Value = 0
end

-- Only the tween drives the pose from here. Stopping resets the offset first, and setDormantPose
-- re-applies the rest pose itself, so a reset can never repose the orb mid-reveal.
dormantFloatOffset:GetPropertyChangedSignal("Value"):Connect(function()
	if dormantFloatRunning then
		applyDormantPose()
	end
end)

local function setDormantPose()
	stopAmbient()
	stopDormantFloat()
	applyDormantPose()
	for _, record in ipairs(photonRings) do
		record.rig.CFrame = record.dormantCFrame
	end
	setPhotonRingPresentation(0)
	for _, record in ipairs(huds) do
		record.model:ScaleTo(record.activatedScale)
		record.model:PivotTo(record.dormantPivot)
		setHudPresentation(record, false)
	end
end

local function setActivatedOrbStaticPose()
	core.CFrame = activatedCoreCFrame
	for _, record in pairs(orbFollowers) do
		record.part.CFrame = record.activatedCFrame
	end
	applyPhotonRingPose(activatedCoreCFrame)
	setPhotonRingPresentation(1)
	for index, shell in ipairs(shells) do
		shell.CFrame = activatedShellCFrames[index]
	end
end

local function setActivatedStaticPose()
	setActivatedOrbStaticPose()
	for _, record in ipairs(huds) do
		record.model:ScaleTo(record.activatedScale)
		record.model:PivotTo(record.activatedPivot)
		setHudPresentation(record, true)
	end
end

local function applyAmbientPose()
	if not ambientRunning or not core.Parent then
		return
	end

	local liveCoreCFrame = activatedCoreCFrame * CFrame.new(0, floatOffset.Value, 0)
	core.CFrame = liveCoreCFrame
	for _, record in pairs(orbFollowers) do
		record.part.CFrame = liveCoreCFrame * record.activatedRelativeCFrame
	end
	applyPhotonRingPose(liveCoreCFrame)

	for index, shell in ipairs(shells) do
		local settings = SHELL_SETTINGS[index]
		local motion = shellMotion[index]
		local baseAngle = (index - 1) * math.pi * 2 / SHELL_COUNT
		local angle = orbitPhase.Value + baseAngle + motion.Angle.Value
		local radius = ORBIT_RADIUS + motion.Radius.Value
		local height = settings.BaseHeight + motion.Height.Value
		local orbitFrame = CFrame.Angles(0, angle, 0) * CFrame.new(0, height, radius)
		local selfRotation = CFrame.fromAxisAngle(settings.SpinAxis, motion.Spin.Value)
		shell.CFrame = liveCoreCFrame * orbitFrame * selfRotation * shellRelativeRotations[index]
	end
end

orbitPhase:GetPropertyChangedSignal("Value"):Connect(applyAmbientPose)
for _, phase in ipairs(photonRingPhases) do
	phase:GetPropertyChangedSignal("Value"):Connect(applyAmbientPose)
end

local function startAmbient(preserveMotion)
	stopAmbient(not preserveMotion)
	if not preserveMotion then
		setActivatedStaticPose()
	end
	if not orbitIsSafe then
		if preserveMotion then
			setActivatedOrbStaticPose()
		else
			setActivatedStaticPose()
		end
		return
	end

	ambientRunning = true
	setPhotonRingPresentation(1)
	if not preserveMotion then
		for index, motion in ipairs(shellMotion) do
			local settings = SHELL_SETTINGS[index]
			motion.Angle.Value = -ANGLE_WOBBLE * settings.AngleDirection
			motion.Radius.Value = -RADIAL_WOBBLE * settings.RadiusDirection
			motion.Height.Value = -HEIGHT_WOBBLE * settings.HeightDirection
			motion.Spin.Value = 0
		end
		floatOffset.Value = -FLOAT_HALF_DISTANCE
	end
	applyAmbientPose()

	orbitTween = TweenService:Create(
		orbitPhase,
		TweenInfo.new(ORBIT_PERIOD_SECONDS, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
		{ Value = orbitPhase.Value + math.pi * 2 }
	)
	orbitTween:Play()

	for index, phase in ipairs(photonRingPhases) do
		local settings = PHOTON_RING_SETTINGS[index]
		local tween = TweenService:Create(
			phase,
			TweenInfo.new(settings.Period, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
			{ Value = phase.Value + settings.Direction * math.pi * 2 }
		)
		table.insert(photonRingTweens, tween)
		tween:Play()
	end

	for index, motion in ipairs(shellMotion) do
		local settings = SHELL_SETTINGS[index]
		local angleGoal = motion.Angle.Value * settings.AngleDirection <= 0 and ANGLE_WOBBLE * settings.AngleDirection
			or -ANGLE_WOBBLE * settings.AngleDirection
		local radiusGoal = motion.Radius.Value * settings.RadiusDirection <= 0
				and RADIAL_WOBBLE * settings.RadiusDirection
			or -RADIAL_WOBBLE * settings.RadiusDirection
		local heightGoal = motion.Height.Value * settings.HeightDirection <= 0
				and HEIGHT_WOBBLE * settings.HeightDirection
			or -HEIGHT_WOBBLE * settings.HeightDirection
		local tweens = {
			TweenService:Create(
				motion.Angle,
				TweenInfo.new(settings.AngleLeg, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Value = angleGoal }
			),
			TweenService:Create(
				motion.Radius,
				TweenInfo.new(settings.RadiusLeg, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Value = radiusGoal }
			),
			TweenService:Create(
				motion.Height,
				TweenInfo.new(settings.HeightLeg, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Value = heightGoal }
			),
			TweenService:Create(
				motion.Spin,
				TweenInfo.new(settings.SpinPeriod, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
				{ Value = motion.Spin.Value + settings.SpinDirection * math.pi * 2 }
			),
		}
		for _, tween in ipairs(tweens) do
			table.insert(shellTweens, tween)
			tween:Play()
		end
	end

	if preserveMotion then
		floatOffset.Value = 0
		floatTween = TweenService:Create(
			floatOffset,
			TweenInfo.new(FLOAT_LEG_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Value = FLOAT_HALF_DISTANCE }
		)
		floatTween.Completed:Connect(function(playbackState)
			if playbackState ~= Enum.PlaybackState.Completed or not ambientRunning then
				return
			end
			floatTween = TweenService:Create(
				floatOffset,
				TweenInfo.new(FLOAT_LEG_SECONDS * 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Value = -FLOAT_HALF_DISTANCE }
			)
			floatTween:Play()
		end)
		floatTween:Play()
	else
		floatTween = TweenService:Create(
			floatOffset,
			TweenInfo.new(FLOAT_LEG_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Value = FLOAT_HALF_DISTANCE }
		)
		floatTween:Play()
	end
end

local playerGui = localPlayer:WaitForChild("PlayerGui")
local screenGui = playerGui:WaitForChild("ScreenGui", 10)

local function reducedMotionEnabled()
	return screenGui and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
end

local function settleActivatedPose()
	if reducedMotionEnabled() then
		stopAmbient()
		setActivatedStaticPose()
	else
		startAmbient()
	end
end

-- One reversing Sine tween rather than a per-frame drift: some clients freeze per-frame writes on
-- an idle window, and a levitating object that stops levitating while you read the leaderboard is
-- worse than one that never moved.
local function startDormantFloat()
	stopDormantFloat()
	if dormantFloatTuning.Enabled ~= true or reducedMotionEnabled() then
		applyDormantPose()
		return
	end

	local lift = dormantFloatTuning.RestLift
	local amplitude = dormantFloatTuning.Amplitude
	dormantFloatRunning = true
	if amplitude <= 0 then
		dormantFloatOffset.Value = lift
		applyDormantPose()
		return
	end

	-- Starts at the bottom of the travel, so the orb rises off the ring on the first leg instead of
	-- appearing already lifted and sinking toward it.
	dormantFloatOffset.Value = lift - amplitude
	applyDormantPose()
	dormantFloatTween = TweenService:Create(
		dormantFloatOffset,
		TweenInfo.new(
			math.max(dormantFloatTuning.LegSeconds, 0.05),
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut,
			-1,
			true
		),
		{ Value = lift + amplitude }
	)
	dormantFloatTween:Play()
end

local function settleDormantPose()
	setDormantPose()
	startDormantFloat()
end

local function revealHudAssembly(generation)
	local progress = Instance.new("NumberValue")
	progress.Value = 0
	progress.Parent = script
	local connection = progress:GetPropertyChangedSignal("Value"):Connect(function()
		if generation ~= revealGeneration then
			return
		end
		local alpha = progress.Value
		local expansion = TweenService:GetValue(alpha, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		local spinAlpha = TweenService:GetValue(alpha, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		local assemblySpin = CFrame.Angles(0, math.pi * 2 * spinAlpha, 0)

		for _, record in ipairs(huds) do
			local relative = record.activatedRelativePivot
			local scale = HUD_START_SCALE + (record.activatedScale - HUD_START_SCALE) * expansion
			local pivot = activatedCoreCFrame
				* assemblySpin
				* CFrame.new(relative.Position * expansion)
				* relative.Rotation
			record.model:ScaleTo(scale)
			record.model:PivotTo(pivot)
			setHudFade(record, expansion)
		end
	end)
	table.insert(revealConnections, connection)

	local tween = TweenService:Create(
		progress,
		TweenInfo.new(HUD_REVEAL_SECONDS, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut),
		{ Value = 1 }
	)
	table.insert(revealTweens, tween)
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	progress:Destroy()
	if generation == revealGeneration then
		for _, record in ipairs(huds) do
			record.model:ScaleTo(record.activatedScale)
			record.model:PivotTo(record.activatedPivot)
			setHudPresentation(record, true)
		end
	end
end

local function applyPowerOnPose(alpha)
	local elapsed = alpha * POWER_ON_SECONDS
	local coreAlpha = TweenService:GetValue(alpha, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local openAlpha = TweenService:GetValue(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local orbitSpeed = math.pi * 2 / ORBIT_PERIOD_SECONDS
	local phase = orbitSpeed * elapsed + POWER_ON_EXTRA_ORBIT_ANGLE * math.sin(alpha * math.pi / 2)
	local liveCoreCFrame = dormantCoreCFrame:Lerp(activatedCoreCFrame, coreAlpha)

	core.CFrame = liveCoreCFrame
	for _, record in pairs(orbFollowers) do
		local relative = record.dormantRelativeCFrame:Lerp(record.activatedRelativeCFrame, coreAlpha)
		record.part.CFrame = liveCoreCFrame * relative
	end
	for index, phaseValue in ipairs(photonRingPhases) do
		local settings = PHOTON_RING_SETTINGS[index]
		phaseValue.Value = settings.Direction * math.pi * 2 * elapsed / settings.Period
	end
	applyPhotonRingPose(liveCoreCFrame)
	setPhotonRingPresentation(math.clamp((alpha - 0.12) / 0.5, 0, 1))
	orbitPhase.Value = phase
	floatOffset.Value = 0

	for index, shell in ipairs(shells) do
		local settings = SHELL_SETTINGS[index]
		local motion = shellMotion[index]
		motion.Angle.Value = -ANGLE_WOBBLE * settings.AngleDirection * alpha
		motion.Radius.Value = -RADIAL_WOBBLE * settings.RadiusDirection * alpha
		motion.Height.Value = -HEIGHT_WOBBLE * settings.HeightDirection * alpha
		motion.Spin.Value = settings.SpinDirection * math.pi * 2 * elapsed / settings.SpinPeriod

		local baseAngle = (index - 1) * math.pi * 2 / SHELL_COUNT
		local angle = phase + baseAngle + motion.Angle.Value
		local radius = ORBIT_RADIUS + motion.Radius.Value
		local height = settings.BaseHeight + motion.Height.Value
		local targetFrame = CFrame.Angles(0, angle, 0)
			* CFrame.new(0, height, radius)
			* CFrame.fromAxisAngle(settings.SpinAxis, motion.Spin.Value)
			* shellRelativeRotations[index]
		local dormantFrame = dormantShellRelativeCFrames[index]
		local position = dormantFrame.Position:Lerp(targetFrame.Position, openAlpha)
		local rotation = dormantFrame.Rotation:Lerp(targetFrame.Rotation, coreAlpha)
		shell.CFrame = liveCoreCFrame * CFrame.new(position) * rotation
	end
end

local function playReveal()
	cancelReveal()
	stopAmbient()
	setDormantPose()
	revealInProgress = true
	local generation = revealGeneration
	prompt.Enabled = false

	local progress = Instance.new("NumberValue")
	progress.Value = 0
	progress.Parent = script
	local connection = progress:GetPropertyChangedSignal("Value"):Connect(function()
		if generation == revealGeneration then
			applyPowerOnPose(progress.Value)
		end
	end)
	table.insert(revealConnections, connection)
	local powerOnTween = TweenService:Create(
		progress,
		TweenInfo.new(POWER_ON_SECONDS, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut),
		{ Value = 1 }
	)
	table.insert(revealTweens, powerOnTween)
	powerOnTween:Play()
	powerOnTween.Completed:Wait()
	connection:Disconnect()
	progress:Destroy()

	if generation ~= revealGeneration or localPlayer:GetAttribute(Attrs.HubCoreActivated) ~= true then
		return
	end

	applyPowerOnPose(1)
	if reducedMotionEnabled() then
		stopAmbient()
		setActivatedOrbStaticPose()
	else
		-- Preserve the exact phase, wobble, and self-spin produced by the power-on frame. The
		-- ambient tweens continue from those live values, so no shell can pause or jump here.
		startAmbient(true)
	end
	revealHudAssembly(generation)

	if generation ~= revealGeneration or localPlayer:GetAttribute(Attrs.HubCoreActivated) ~= true then
		return
	end
	if reducedMotionEnabled() then
		stopAmbient()
		setActivatedOrbStaticPose()
	elseif not ambientRunning then
		startAmbient()
	end
	revealInProgress = false
	table.clear(revealTweens)
	table.clear(revealConnections)
end

local defaultActionText = prompt.ActionText
local defaultObjectText = prompt.ObjectText

local function promptShouldBeEnabled()
	return not activationInFlight
		and not revealInProgress
		and localPlayer:GetAttribute(Attrs.HubCoreActivated) == false
		and localPlayer:GetAttribute(Attrs.StoryStep) == HubCoreConfig.RequiredStoryStep
end

local function refreshPrompt()
	prompt.ActionText = defaultActionText
	prompt.ObjectText = defaultObjectText
	prompt.Enabled = promptShouldBeEnabled()
end

local feedbackGeneration = 0
local function showPromptFeedback(message)
	feedbackGeneration += 1
	local generation = feedbackGeneration
	prompt.ObjectText = tostring(message)
	prompt.ActionText = "Try Again"
	prompt.Enabled = true
	task.delay(PROMPT_FEEDBACK_SECONDS, function()
		if generation == feedbackGeneration then
			refreshPrompt()
		end
	end)
end

prompt.Triggered:Connect(function()
	if not promptShouldBeEnabled() then
		return
	end
	activationInFlight = true
	prompt.Enabled = false

	task.spawn(function()
		local ok, result = pcall(Net.invoke, Net.Names.ActivateHubCore)
		if ok and type(result) == "table" and result.success and result.activated then
			revealInProgress = true
			activationInFlight = false
			playReveal()
			return
		end

		activationInFlight = false
		local message = ok and type(result) == "table" and result.message or "Activation failed. Try again."
		showPromptFeedback(message)
	end)
end)

local function refreshState()
	if localPlayer:GetAttribute(Attrs.HubCoreActivated) == true then
		if not activationInFlight and not revealInProgress then
			cancelReveal()
			settleActivatedPose()
		end
	else
		cancelReveal()
		settleDormantPose()
	end
	refreshPrompt()
end

localPlayer:GetAttributeChangedSignal(Attrs.HubCoreActivated):Connect(refreshState)
localPlayer:GetAttributeChangedSignal(Attrs.StoryStep):Connect(refreshPrompt)
if screenGui then
	screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
		if revealInProgress then
			return
		end
		if localPlayer:GetAttribute(Attrs.HubCoreActivated) == true then
			settleActivatedPose()
		else
			settleDormantPose()
		end
	end)
end
leaderboard.AncestryChanged:Connect(function(_, parent)
	if not parent then
		cancelReveal()
		stopAmbient()
		stopDormantFloat()
	end
end)

-- Live tuning re-settles only the state it can actually be seen in; an activated core is somewhere
-- else entirely and must not be dragged back to the mount by a slider.
for _, key in ipairs(DORMANT_FLOAT_KEYS) do
	local tuningKey = key
	DevTuning.observe(DORMANT_FLOAT_PREFIX .. tuningKey, function(value)
		dormantFloatTuning[tuningKey] = value
		if not revealInProgress and localPlayer:GetAttribute(Attrs.HubCoreActivated) ~= true then
			settleDormantPose()
		end
	end)
end

refreshState()
