-- Drives the Studio-authored near-circular quest progress widget.
-- The missing bottom-right quarter leaves a 270-degree visible arc:
-- 180 degrees on the left, followed by 90 degrees on the upper right.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local EffectsConfig = require(Shared:WaitForChild("QuestProgressEffectsConfig"))
local UiMotion = require(Shared:WaitForChild("UiMotion"))

local QuestProgressPresenter = {}

local PROGRESS_ATTRIBUTE = "Progress"
local EFFECTS_ENABLED_ATTRIBUTE = "EffectsEnabled"
local TUNING_PREFIX = "QuestProgressEffects."
local REFERENCE_SIZE = 44
local EPSILON = 0.001

local TUNING_KEYS = {}
for key in pairs(EffectsConfig) do
	table.insert(TUNING_KEYS, key)
end
table.sort(TUNING_KEYS)

local function resolveGui(root, name)
	local instance = root:FindFirstChild(name, true)
	if instance and instance:IsA("GuiObject") then
		return instance
	end
	return nil
end

local function setSheenPose(sheenBand, center, radius, degrees, rotationOffset)
	local radians = math.rad(degrees)
	sheenBand.Position = UDim2.fromScale(
		(center.X + math.cos(radians) * radius) / REFERENCE_SIZE,
		(center.Y + math.sin(radians) * radius) / REFERENCE_SIZE
	)
	sheenBand.Rotation = degrees + rotationOffset
end

local function sizeFromPixels(width, height)
	height = height or width
	return UDim2.fromScale(width / REFERENCE_SIZE, height / REFERENCE_SIZE)
end

local function positionFromPixels(position)
	return UDim2.fromScale(position.X / REFERENCE_SIZE, position.Y / REFERENCE_SIZE)
end

function QuestProgressPresenter.bind(root)
	if not (root and root:IsA("GuiObject")) then
		return nil
	end

	local screenGui = root:FindFirstAncestorOfClass("ScreenGui")
	local playerGui = screenGui and screenGui.Parent
	local settingsGui = playerGui and playerGui:FindFirstChild("ScreenGui")
	local reducedMotionGui = if settingsGui and settingsGui:IsA("ScreenGui") then settingsGui else screenGui
	local progressMask = root:FindFirstChild("ProgressMask", true)
	local leftHalf = progressMask and progressMask:FindFirstChild("LeftHalf")
	local rightHalf = progressMask and progressMask:FindFirstChild("RightHalf")
	local leftImage = leftHalf and leftHalf:FindFirstChild("FillImage")
	local rightImage = rightHalf and rightHalf:FindFirstChild("FillImage")
	local leftGradient = leftImage and leftImage:FindFirstChild("ProgressGradient")
	local rightGradient = rightImage and rightImage:FindFirstChild("ProgressGradient")
	local percent = root:FindFirstChild("Percent", true)

	if
		not (leftGradient and leftGradient:IsA("UIGradient"))
		or not (rightGradient and rightGradient:IsA("UIGradient"))
		or not (percent and percent:IsA("TextLabel"))
	then
		warn("Quest progress disabled: the Studio-authored mask or percent label is incomplete")
		return nil
	end

	local visibleArcDegrees = tonumber(root:GetAttribute("VisibleArcDegrees")) or 270
	local leftArcDegrees = tonumber(root:GetAttribute("LeftArcDegrees")) or 180
	local rightArcDegrees = tonumber(root:GetAttribute("RightArcDegrees")) or 90
	local effectScale = root:FindFirstChild("EffectScale", true)
	local shimmer = root:FindFirstChild("Shimmer", true)
	local burst = root:FindFirstChild("CompletionBurst", true)
	local sheenBand = shimmer and resolveGui(shimmer, "SheenBand")
	local sheenGradient = sheenBand and sheenBand:FindFirstChild("SheenGradient")
	local particles = {}
	if burst then
		for _, child in ipairs(burst:GetChildren()) do
			if child:IsA("GuiObject") and child.Name:match("^Particle%d+$") then
				table.insert(particles, child)
			end
		end
		table.sort(particles, function(a, b)
			return a.Name < b.Name
		end)
	end

	local tuning = {}
	for _, key in ipairs(TUNING_KEYS) do
		tuning[key] = DevTuning.get(TUNING_PREFIX .. key)
	end

	local connections = {}
	local observations = {}
	local pulseTweens = {}
	local burstTweens = {}
	local sheenElapsed = 0
	local sheenActive = false
	local sheenProgress = 0
	local pendingCompletionSheen = false
	local previewTriggerWasActive = false
	local lastAutomaticSheenProgress = 0
	local currentProgress = 0
	local progressTweenActive = false
	local progressTweenElapsed = 0
	local progressTweenStart = 0
	local progressTweenTarget = 0
	local progressTweenEffectStart = 0
	local destroyed = false

	local function getCenter()
		return Vector2.new(tuning.SheenCenterX, tuning.SheenCenterY)
	end

	local function isReduced()
		return reducedMotionGui ~= nil and reducedMotionGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
	end

	local function effectsEnabled()
		return tuning.EffectsEnabled == true and root:GetAttribute(EFFECTS_ENABLED_ATTRIBUTE) ~= false
	end

	local function hideShimmer()
		sheenActive = false
		pendingCompletionSheen = false
		if sheenBand then
			sheenBand.Visible = false
		end
	end

	local function cancelTweens(tweens)
		for _, tween in ipairs(tweens) do
			tween:Cancel()
		end
		table.clear(tweens)
	end

	local function applyEffectStyles()
		if sheenBand then
			sheenBand.Size = sizeFromPixels(tuning.SheenLength, tuning.SheenWidth)
			sheenBand.BackgroundColor3 = Color3.new(1, 1, 1)
			sheenBand.BackgroundTransparency = 0
		end
		if sheenGradient and sheenGradient:IsA("UIGradient") then
			local coreHalf = math.clamp(tuning.SheenCoreWidth, 0, 0.9) / 2
			if coreHalf <= EPSILON then
				sheenGradient.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, tuning.SheenEdgeColor),
					ColorSequenceKeypoint.new(0.5, tuning.SheenCenterColor),
					ColorSequenceKeypoint.new(1, tuning.SheenEdgeColor),
				})
				sheenGradient.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, tuning.SheenEdgeTransparency),
					NumberSequenceKeypoint.new(0.5, tuning.SheenCenterTransparency),
					NumberSequenceKeypoint.new(1, tuning.SheenEdgeTransparency),
				})
			else
				sheenGradient.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, tuning.SheenEdgeColor),
					ColorSequenceKeypoint.new(0.5 - coreHalf, tuning.SheenCenterColor),
					ColorSequenceKeypoint.new(0.5 + coreHalf, tuning.SheenCenterColor),
					ColorSequenceKeypoint.new(1, tuning.SheenEdgeColor),
				})
				sheenGradient.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, tuning.SheenEdgeTransparency),
					NumberSequenceKeypoint.new(0.5 - coreHalf, tuning.SheenCenterTransparency),
					NumberSequenceKeypoint.new(0.5 + coreHalf, tuning.SheenCenterTransparency),
					NumberSequenceKeypoint.new(1, tuning.SheenEdgeTransparency),
				})
			end
		end

		for index, particle in ipairs(particles) do
			local isEven = index % 2 == 0
			local size = if isEven then tuning.BurstEvenSize else tuning.BurstOddSize
			particle.Size = sizeFromPixels(size)
			particle.BackgroundColor3 = if isEven then tuning.BurstSecondaryColor else tuning.BurstPrimaryColor
		end
	end

	local function playSheen(restart)
		if
			currentProgress <= 0
			or isReduced()
			or not effectsEnabled()
			or tuning.SheenEnabled ~= true
			or not sheenBand
		then
			hideShimmer()
			return
		end
		if sheenActive and restart ~= true then
			return
		end

		if restart == true then
			pendingCompletionSheen = false
		end
		sheenElapsed = 0
		sheenActive = true
		sheenProgress = currentProgress
		sheenBand.Visible = true
	end

	local function playPulse(scaleAmount)
		if
			isReduced()
			or not effectsEnabled()
			or tuning.PulseEnabled ~= true
			or not (effectScale and effectScale:IsA("UIScale"))
		then
			return
		end

		cancelTweens(pulseTweens)
		effectScale.Scale = 1
		local grow = UiMotion.create(
			effectScale,
			TweenInfo.new(tuning.PulseGrowSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = scaleAmount }
		)
		table.insert(pulseTweens, grow)
		grow.Completed:Connect(function(playbackState)
			if destroyed or playbackState ~= Enum.PlaybackState.Completed then
				return
			end
			local settle = UiMotion.create(
				effectScale,
				TweenInfo.new(tuning.PulseSettleSeconds, tuning.PulseSettleStyle, Enum.EasingDirection.Out),
				{ Scale = 1 }
			)
			table.insert(pulseTweens, settle)
			settle:Play()
		end)
		grow:Play()
	end

	local function hideBurst()
		local center = getCenter()
		for _, particle in ipairs(particles) do
			particle.Visible = false
			particle.BackgroundTransparency = 1
			particle.Position = positionFromPixels(center)
		end
	end

	local function playCompletionBurst()
		if isReduced() or not effectsEnabled() or tuning.BurstEnabled ~= true or #particles == 0 then
			return
		end

		cancelTweens(burstTweens)
		local center = getCenter()
		local particleCount = math.clamp(math.round(tuning.BurstParticleCount), 1, #particles)
		for index, particle in ipairs(particles) do
			if index > particleCount then
				particle.Visible = false
				continue
			end

			local degrees = tuning.BurstStartDegrees + (index - 1) / particleCount * 360
			local radians = math.rad(degrees)
			local distance = if index % 2 == 0 then tuning.BurstEvenDistance else tuning.BurstOddDistance
			particle.Position = positionFromPixels(center)
			particle.BackgroundTransparency = tuning.BurstStartTransparency
			particle.Visible = true

			local tween = UiMotion.create(
				particle,
				TweenInfo.new(tuning.BurstDuration, tuning.BurstEasingStyle, Enum.EasingDirection.Out),
				{
					Position = UDim2.fromScale(
						(center.X + math.cos(radians) * distance) / REFERENCE_SIZE,
						(center.Y + math.sin(radians) * distance) / REFERENCE_SIZE
					),
					BackgroundTransparency = 1,
				}
			)
			table.insert(burstTweens, tween)
			if index == particleCount then
				tween.Completed:Connect(function()
					if not destroyed then
						hideBurst()
					end
				end)
			end
			tween:Play()
		end
	end

	local function applyProgress(progress)
		progress = math.clamp(tonumber(progress) or 0, 0, 1)
		currentProgress = progress

		local filledDegrees = progress * visibleArcDegrees
		local leftFilled = math.clamp(filledDegrees, 0, leftArcDegrees)
		local rightFilled = math.clamp(filledDegrees - leftArcDegrees, 0, rightArcDegrees)

		leftGradient.Enabled = leftFilled < leftArcDegrees - EPSILON
		leftGradient.Rotation = 180 + leftFilled
		rightGradient.Enabled = rightFilled < rightArcDegrees - EPSILON
		rightGradient.Rotation = rightFilled
		percent.Text = string.format("%d%%", math.floor(progress * 100 + 0.5))
	end

	local function playProgressEndEffects(previousProgress, progress)
		if progress > previousProgress + EPSILON then
			local progressStep = math.max(tuning.SheenProgressStep, EPSILON)
			local reachedCompletion = progress >= 1 and previousProgress < 1
			local reachedSheenStep = progress - lastAutomaticSheenProgress + EPSILON >= progressStep
			if reachedCompletion or reachedSheenStep then
				lastAutomaticSheenProgress = progress
				if reachedCompletion and sheenActive then
					pendingCompletionSheen = true
				else
					playSheen(false)
				end
			end
			if reachedCompletion then
				playCompletionBurst()
			end
		end
	end

	local function finishProgressTween()
		if not progressTweenActive then
			return
		end
		progressTweenActive = false
		applyProgress(progressTweenTarget)
		playProgressEndEffects(progressTweenEffectStart, progressTweenTarget)
	end

	local function render(progress, animate)
		progress = math.clamp(tonumber(progress) or 0, 0, 1)
		if not animate then
			progressTweenActive = false
			applyProgress(progress)
			return
		end
		local previousProgress = currentProgress
		if progress < previousProgress - EPSILON then
			progressTweenActive = false
			applyProgress(progress)
			lastAutomaticSheenProgress = progress
			pendingCompletionSheen = false
			return
		end
		if progress <= previousProgress + EPSILON then
			return
		end

		playPulse(if progress >= 1 then tuning.CompletionPulseScale else tuning.PulseScale)
		if animate and not isReduced() and effectsEnabled() and tuning.ProgressTweenSeconds > EPSILON then
			hideShimmer()
			progressTweenActive = true
			progressTweenElapsed = 0
			progressTweenStart = previousProgress
			progressTweenTarget = progress
			progressTweenEffectStart = previousProgress
			return
		end

		progressTweenActive = false
		applyProgress(progress)
		if animate then
			playProgressEndEffects(previousProgress, progress)
		end
	end

	local shimmerConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if destroyed then
			return
		end

		if progressTweenActive then
			if isReduced() or not effectsEnabled() then
				finishProgressTween()
			else
				local duration = math.max(tuning.ProgressTweenSeconds, EPSILON)
				progressTweenElapsed = math.min(progressTweenElapsed + deltaTime, duration)
				local alpha = TweenService:GetValue(
					math.clamp(progressTweenElapsed / duration, 0, 1),
					tuning.ProgressTweenEasingStyle,
					Enum.EasingDirection.Out
				)
				applyProgress(progressTweenStart + (progressTweenTarget - progressTweenStart) * alpha)
				if progressTweenElapsed >= duration then
					finishProgressTween()
				end
			end
		end

		if not sheenActive then
			return
		end

		if
			not root.Visible
			or currentProgress <= 0
			or isReduced()
			or not effectsEnabled()
			or tuning.SheenEnabled ~= true
		then
			hideShimmer()
			return
		end

		local sweepSeconds = math.max(tuning.SheenSweepSeconds, 0.01)
		sheenElapsed += deltaTime
		if sheenElapsed >= sweepSeconds then
			sheenActive = false
			sheenBand.Visible = false
			if pendingCompletionSheen then
				pendingCompletionSheen = false
				playSheen(false)
			end
			return
		end

		local phase = TweenService:GetValue(
			math.clamp(sheenElapsed / sweepSeconds, 0, 1),
			tuning.SheenEasingStyle,
			Enum.EasingDirection.InOut
		)
		local completedDegrees = sheenProgress * visibleArcDegrees
		local pathDegrees = if tuning.SheenReverse then completedDegrees * (1 - phase) else completedDegrees * phase
		local center = getCenter()
		local degrees = tuning.SheenStartDegrees + pathDegrees
		setSheenPose(sheenBand, center, tuning.SheenRadius, degrees, tuning.SheenTangentOffsetDegrees)
	end)
	table.insert(connections, shimmerConnection)

	table.insert(
		connections,
		root:GetAttributeChangedSignal(PROGRESS_ATTRIBUTE):Connect(function()
			render(root:GetAttribute(PROGRESS_ATTRIBUTE), true)
		end)
	)
	table.insert(
		connections,
		root:GetAttributeChangedSignal(EFFECTS_ENABLED_ATTRIBUTE):Connect(function()
			if not effectsEnabled() then
				hideShimmer()
				hideBurst()
				finishProgressTween()
				if effectScale and effectScale:IsA("UIScale") then
					effectScale.Scale = 1
				end
			end
		end)
	)
	if reducedMotionGui then
		table.insert(
			connections,
			reducedMotionGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
				if isReduced() then
					hideShimmer()
					hideBurst()
					finishProgressTween()
					if effectScale and effectScale:IsA("UIScale") then
						effectScale.Scale = 1
					end
				end
			end)
		)
	end

	applyEffectStyles()
	render(root:GetAttribute(PROGRESS_ATTRIBUTE) or root:GetAttribute("PreviewProgress"), false)
	lastAutomaticSheenProgress = currentProgress
	hideBurst()

	for _, key in ipairs(TUNING_KEYS) do
		local tuningKey = key
		table.insert(
			observations,
			DevTuning.observe(TUNING_PREFIX .. tuningKey, function(value)
				tuning[tuningKey] = value
				applyEffectStyles()
				if not effectsEnabled() or tuning.SheenEnabled ~= true then
					hideShimmer()
				end
				if tuningKey == "PreviewProgress" and tuning.PreviewProgressEnabled then
					root:SetAttribute(PROGRESS_ATTRIBUTE, value)
				elseif tuningKey == "PreviewProgressEnabled" and value == true then
					root:SetAttribute(PROGRESS_ATTRIBUTE, tuning.PreviewProgress)
				elseif tuningKey == "SheenPreviewTrigger" then
					local isActive = value == true
					if isActive and not previewTriggerWasActive then
						playSheen(true)
					end
					previewTriggerWasActive = isActive
				end
			end)
		)
	end

	return {
		render = function(progress, animate)
			render(progress, animate == true)
		end,
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			progressTweenActive = false
			cancelTweens(pulseTweens)
			cancelTweens(burstTweens)
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			for _, observation in ipairs(observations) do
				observation:Disconnect()
			end
			hideShimmer()
			hideBurst()
			if effectScale and effectScale:IsA("UIScale") then
				effectScale.Scale = 1
			end
		end,
	}
end

return QuestProgressPresenter
