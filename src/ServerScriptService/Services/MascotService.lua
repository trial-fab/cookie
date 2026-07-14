local TweenService = game:GetService("TweenService")

local MascotService = {}

local DEFAULT_SETTINGS = {
	hopHeight = 2.5,
	hopDuration = 0.65,
	stretchAmount = 0.5,
	squashAmount = 0.3,
	eyeSurfacePadding = 0.02,
	eyeSquashForward = 0.6,
	eyeStretchBackward = 0.3,
	idleWiggleAmount = 0.055,
	idleWiggleTime = 0.85,
	colorTweenTime = 0.28,
	revealSpread = 1.3,
	revealHeight = 0.18,
	revealDuration = 1.35,
	turnDuration = 0.3,
	settleTurnDuration = 0.35,
}

local controllers = setmetatable({}, { __mode = "k" })

local function getNumberAttribute(model, name, fallback)
	local value = model:GetAttribute(name)
	if typeof(value) == "number" then
		return value
	end
	model:SetAttribute(name, fallback)
	return fallback
end

local function tweenValue(className, startValue, endValue, duration, onChanged)
	local valueObject = Instance.new(className)
	valueObject.Value = startValue
	local connection = valueObject:GetPropertyChangedSignal("Value"):Connect(function()
		onChanged(valueObject.Value)
	end)
	local tween = TweenService:Create(
		valueObject,
		TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ Value = endValue }
	)
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	valueObject:Destroy()
	onChanged(endValue)
end

local function tweenProgress(duration, onChanged)
	local valueObject = Instance.new("NumberValue")
	valueObject.Value = 0
	local connection = valueObject:GetPropertyChangedSignal("Value"):Connect(function()
		onChanged(valueObject.Value)
	end)
	local tween = TweenService:Create(
		valueObject,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ Value = 1 }
	)
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	valueObject:Destroy()
	onChanged(1)
end

local function lerpNumber(startValue, endValue, alpha)
	return startValue + (endValue - startValue) * alpha
end

local function smoothstep(alpha)
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - 2 * alpha)
end

local function easeInCubic(alpha)
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * alpha
end

local function easeOutCubic(alpha)
	alpha = math.clamp(alpha, 0, 1)
	local inverse = 1 - alpha
	return 1 - inverse * inverse * inverse
end

local function createController(model)
	local body = model:FindFirstChild("SlimeBody")
	local eyes = model:FindFirstChild("SlimeEyes")
	local root = model:FindFirstChild("GooRoot")
	local leftEyeRoot = model:FindFirstChild("EyeRootLeft")
	local rightEyeRoot = model:FindFirstChild("EyeRootRight")
	if not (body and eyes and root and leftEyeRoot and rightEyeRoot) then
		warn("MascotService: alien template is missing required body/root parts.")
		return nil
	end
	if not (body:IsA("BasePart") and eyes:IsA("BasePart") and root:IsA("BasePart")) then
		return nil
	end

	local settings = {}
	for name, fallback in pairs(DEFAULT_SETTINGS) do
		settings[name] = getNumberAttribute(model, name, fallback)
		model:GetAttributeChangedSignal(name):Connect(function()
			local value = model:GetAttribute(name)
			if typeof(value) == "number" then
				settings[name] = value
			end
		end)
	end

	local originalRootCFrame = root.CFrame
	local originalRootRotation = originalRootCFrame - originalRootCFrame.Position
	local originalBodyLocalCFrame = originalRootCFrame:ToObjectSpace(body.CFrame)
	local originalEyesLocalCFrame = originalRootCFrame:ToObjectSpace(eyes.CFrame)
	local originalLeftLocal = originalRootCFrame:ToObjectSpace(leftEyeRoot.CFrame)
	local originalRightLocal = originalRootCFrame:ToObjectSpace(rightEyeRoot.CFrame)
	local leftFromBody = originalBodyLocalCFrame:ToObjectSpace(originalLeftLocal)
	local rightFromBody = originalBodyLocalCFrame:ToObjectSpace(originalRightLocal)
	local leftRotation = originalLeftLocal - originalLeftLocal.Position
	local rightRotation = originalRightLocal - originalRightLocal.Position
	local originalEyeAnchorPosition = (leftEyeRoot.Position + rightEyeRoot.Position) * 0.5
	local originalEyeAnchorCFrame = CFrame.new(originalEyeAnchorPosition) * (eyes.CFrame - eyes.Position)
	local eyesFromAnchor = originalEyeAnchorCFrame:ToObjectSpace(eyes.CFrame)
	local originalBodySize = body.Size
	local authoredBodyColor = model:GetAttribute("DefaultBodyColor")
	local authoredEyesColor = model:GetAttribute("DefaultEyesColor")
	local defaultBodyColor = typeof(authoredBodyColor) == "Color3" and authoredBodyColor or body.Color
	local defaultEyesColor = typeof(authoredEyesColor) == "Color3" and authoredEyesColor or eyes.Color
	local currentRootCFrame = originalRootCFrame
	local currentBodySize = originalBodySize
	local currentEyesOffsetY = 0
	local rainbowFlashToken = 0
	local activeRainbowTween = nil
	local motionToken = 0
	local busy = 0
	local visible = true
	local alive = true

	local originalFront = eyes.Position - body.Position
	originalFront = Vector3.new(originalFront.X, 0, originalFront.Z)
	originalFront = originalFront.Magnitude > 0.001 and originalFront.Unit or Vector3.zAxis

	local controller = {}

	function controller.applyPose(rootCFrame)
		if not alive or not model.Parent then
			return
		end
		currentRootCFrame = rootCFrame
		root.CFrame = rootCFrame
		local bodyBase = rootCFrame * originalBodyLocalCFrame
		local bodyRotation = bodyBase - bodyBase.Position
		local bottomY = bodyBase.Position.Y - originalBodySize.Y * 0.5
		body.Size = currentBodySize
		body.CFrame = CFrame.new(bodyBase.Position.X, bottomY + currentBodySize.Y * 0.5, bodyBase.Position.Z)
			* bodyRotation

		local scale = currentBodySize / originalBodySize
		local function eyePosition(offset)
			local scaled = Vector3.new(offset.X * scale.X, offset.Y * scale.Y + currentEyesOffsetY, offset.Z * scale.Z)
			return (body.CFrame * CFrame.new(scaled)).Position
		end

		local leftPosition = eyePosition(leftFromBody.Position)
		local rightPosition = eyePosition(rightFromBody.Position)
		local rootRotation = rootCFrame - rootCFrame.Position
		leftEyeRoot.CFrame = CFrame.new(leftPosition) * rootRotation * leftRotation
		rightEyeRoot.CFrame = CFrame.new(rightPosition) * rootRotation * rightRotation

		local eyeAnchor = (leftPosition + rightPosition) * 0.5
		local faceDirection = Vector3.new(eyeAnchor.X - body.Position.X, 0, eyeAnchor.Z - body.Position.Z)
		if faceDirection.Magnitude > 0.001 then
			local squashAlpha = math.max(0, (originalBodySize.Y - currentBodySize.Y) / originalBodySize.Y)
			local stretchAlpha = math.max(0, (currentBodySize.Y - originalBodySize.Y) / originalBodySize.Y)
			eyeAnchor += faceDirection.Unit * (settings.eyeSurfacePadding + settings.eyeSquashForward * squashAlpha - settings.eyeStretchBackward * stretchAlpha)
		end
		local eyesBase = rootCFrame * originalEyesLocalCFrame
		eyes.CFrame = CFrame.new(eyeAnchor) * (eyesBase - eyesBase.Position) * eyesFromAnchor
	end

	function controller.tweenShape(targetSize, targetEyesOffset, duration)
		local startSize = currentBodySize
		local startOffset = currentEyesOffsetY
		local token = motionToken
		tweenValue("NumberValue", 0, 1, duration, function(alpha)
			if token ~= motionToken then
				return
			end
			currentBodySize = startSize:Lerp(targetSize, alpha)
			currentEyesOffsetY = startOffset + (targetEyesOffset - startOffset) * alpha
			controller.applyPose(currentRootCFrame)
		end)
	end

	function controller.resetShape()
		motionToken += 1
		currentBodySize = originalBodySize
		currentEyesOffsetY = 0
		controller.applyPose(currentRootCFrame)
	end

	function controller.setVisible(nextVisible)
		visible = nextVisible
		local dizzyBirds = model:FindFirstChild("DizzyBirds")
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				if descendant:GetAttribute("MascotBaseTransparency") == nil then
					descendant:SetAttribute("MascotBaseTransparency", descendant.Transparency)
				end
				descendant.Transparency = nextVisible and descendant:GetAttribute("MascotBaseTransparency") or 1
			elseif
				not (dizzyBirds and descendant:IsDescendantOf(dizzyBirds))
				and (
					descendant:IsA("ParticleEmitter")
					or descendant:IsA("Sparkles")
					or descendant:IsA("Light")
					or descendant:IsA("Beam")
					or descendant:IsA("Trail")
					or descendant:IsA("Fire")
					or descendant:IsA("Smoke")
				)
			then
				if descendant:GetAttribute("MascotBaseEnabled") == nil then
					descendant:SetAttribute("MascotBaseEnabled", descendant.Enabled)
				end
				descendant.Enabled = nextVisible and descendant:GetAttribute("MascotBaseEnabled") or false
			end
		end
	end

	function controller.moveTo(cframe)
		controller.applyPose(cframe)
	end

	function controller.revealFromSquash(cframe)
		busy += 1
		controller.applyPose(cframe)
		currentBodySize = Vector3.new(
			originalBodySize.X * settings.revealSpread,
			originalBodySize.Y * settings.revealHeight,
			originalBodySize.Z * settings.revealSpread
		)
		currentEyesOffsetY = -originalBodySize.Y * 0.18
		controller.applyPose(cframe)
		controller.setVisible(true)
		controller.tweenShape(originalBodySize, 0, settings.revealDuration)
		busy -= 1
	end

	function controller.setDizzy(enabled)
		local dizzy = model:FindFirstChild("DizzyBirds")
		if not dizzy then
			return
		end
		for _, descendant in ipairs(dizzy:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
				descendant.Enabled = enabled
			elseif descendant:IsA("BillboardGui") then
				descendant.Enabled = enabled
			elseif descendant:IsA("BasePart") then
				descendant.Transparency = enabled and 0 or 1
			end
		end
	end

	function controller.setColorProgress(progress, animate)
		progress = math.clamp(progress, 0, 1)
		local h, _, _ = defaultBodyColor:ToHSV()
		local dimColor = Color3.fromHSV(h, 0.12, 0.48)
		local targetBody = dimColor:Lerp(defaultBodyColor, progress)
		local targetEyes = Color3.fromRGB(170, 170, 170):Lerp(defaultEyesColor, progress)
		if not animate then
			body.Color = targetBody
			eyes.Color = targetEyes
			return
		end
		local bodyTween = TweenService:Create(body, TweenInfo.new(settings.colorTweenTime), { Color = targetBody })
		local eyesTween = TweenService:Create(eyes, TweenInfo.new(settings.colorTweenTime), { Color = targetEyes })
		bodyTween:Play()
		eyesTween:Play()
	end

	function controller.hopToAuthoredPose(targetCFrame)
		busy += 1
		local start = currentRootCFrame
		local direction = targetCFrame.Position - start.Position
		local flatDirection = Vector3.new(direction.X, 0, direction.Z)
		local travelRotation = currentRootCFrame - currentRootCFrame.Position
		if flatDirection.Magnitude > 0.001 then
			local yaw = math.atan2(flatDirection.X, flatDirection.Z) - math.atan2(originalFront.X, originalFront.Z)
			travelRotation = CFrame.Angles(0, yaw, 0) * originalRootRotation
		end

		local facingCFrame = CFrame.new(start.Position) * travelRotation
		tweenValue("CFrameValue", currentRootCFrame, facingCFrame, settings.turnDuration, function(value)
			controller.applyPose(value)
		end)

		local destination = CFrame.new(targetCFrame.Position) * travelRotation
		local takeoff = math.min(settings.hopDuration * 0.22, 0.2)
		local landing = math.min(settings.hopDuration * 0.18, 0.16)
		controller.tweenShape(
			Vector3.new(
				originalBodySize.X * 0.78,
				originalBodySize.Y * (1 + settings.stretchAmount),
				originalBodySize.Z * 0.78
			),
			originalBodySize.Y * settings.stretchAmount * 0.28,
			takeoff
		)
		tweenValue("CFrameValue", facingCFrame, destination, settings.hopDuration, function(flatCFrame)
			local moved = flatCFrame.Position - facingCFrame.Position
			local alpha = flatDirection.Magnitude > 0.001
					and math.clamp(Vector3.new(moved.X, 0, moved.Z).Magnitude / flatDirection.Magnitude, 0, 1)
				or 1
			controller.applyPose(flatCFrame + Vector3.new(0, math.sin(alpha * math.pi) * settings.hopHeight, 0))
		end)
		controller.tweenShape(
			Vector3.new(
				originalBodySize.X * (1 + settings.squashAmount),
				originalBodySize.Y * 0.72,
				originalBodySize.Z * (1 + settings.squashAmount)
			),
			-originalBodySize.Y * settings.squashAmount * 0.18,
			landing
		)
		controller.tweenShape(originalBodySize, 0, landing)

		local authoredPose = CFrame.new(targetCFrame.Position) * (targetCFrame - targetCFrame.Position)
		tweenValue("CFrameValue", currentRootCFrame, authoredPose, settings.settleTurnDuration, function(value)
			controller.applyPose(value)
		end)
		busy -= 1
	end

	function controller.playRainbow()
		busy += 1
		rainbowFlashToken += 1
		local colors = {
			Color3.fromRGB(255, 70, 70),
			Color3.fromRGB(255, 180, 40),
			Color3.fromRGB(255, 240, 70),
			Color3.fromRGB(70, 230, 100),
			Color3.fromRGB(70, 170, 255),
			Color3.fromRGB(170, 90, 255),
			defaultBodyColor,
		}
		for _, color in ipairs(colors) do
			if not model.Parent then
				break
			end
			if activeRainbowTween then
				activeRainbowTween:Cancel()
			end
			local tween = TweenService:Create(body, TweenInfo.new(0.12), { Color = color })
			activeRainbowTween = tween
			tween:Play()
			tween.Completed:Wait()
		end
		activeRainbowTween = nil
		if alive and body.Parent then
			body.Color = defaultBodyColor
		end
		busy -= 1
	end

	function controller.destroy()
		alive = false
		motionToken += 1
		rainbowFlashToken += 1
		if activeRainbowTween then
			activeRainbowTween:Cancel()
			activeRainbowTween = nil
		end
	end

	function controller.startRainbowRipple()
		rainbowFlashToken += 1
		local token = rainbowFlashToken
		local colors = {
			Color3.fromRGB(255, 70, 70),
			Color3.fromRGB(255, 180, 40),
			Color3.fromRGB(255, 240, 70),
			Color3.fromRGB(70, 230, 100),
			Color3.fromRGB(70, 170, 255),
			Color3.fromRGB(170, 90, 255),
		}

		task.spawn(function()
			local index = 1
			while model.Parent and rainbowFlashToken == token do
				if activeRainbowTween then
					activeRainbowTween:Cancel()
				end
				local tween = TweenService:Create(
					body,
					TweenInfo.new(0.28, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ Color = colors[index] }
				)
				activeRainbowTween = tween
				tween:Play()
				tween.Completed:Wait()
				index = index % #colors + 1
			end
		end)

		return function()
			if rainbowFlashToken == token then
				rainbowFlashToken += 1
			end
			if activeRainbowTween then
				activeRainbowTween:Cancel()
				activeRainbowTween = nil
			end
			local settleTween = TweenService:Create(
				body,
				TweenInfo.new(0.24, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
				{ Color = defaultBodyColor }
			)
			settleTween:Play()
			settleTween.Completed:Wait()
		end
	end

	function controller.jumpInPlace(count)
		busy += 1
		motionToken += 1
		local baseCFrame = currentRootCFrame
		local jumpHeight = settings.hopHeight * 1.45
		local jumpDuration = settings.hopDuration * 2.25
		local recoveryTime = 0.28
		local squashXz = 1 + settings.squashAmount * 1.65
		local squashY = 0.5
		local launchXz = 0.66
		local launchY = 1 + settings.stretchAmount * 1.22
		local fallXz = 0.62
		local fallY = 1 + settings.stretchAmount * 1.34
		local impactXz = 1 + settings.squashAmount * 1.85
		local impactY = 0.46
		local squashEyeOffset = -originalBodySize.Y * settings.squashAmount * 0.18
		local stretchEyeOffset = originalBodySize.Y * settings.stretchAmount * 0.28

		for _ = 1, count do
			if not model.Parent then
				break
			end

			tweenProgress(jumpDuration, function(alpha)
				local xzScale
				local yScale
				local eyeOffsetScale

				if alpha < 0.22 then
					local phase = smoothstep(alpha / 0.22)
					xzScale = lerpNumber(1, squashXz, phase)
					yScale = lerpNumber(1, squashY, phase)
					eyeOffsetScale = lerpNumber(0, squashEyeOffset, phase)
				elseif alpha < 0.4 then
					local phase = easeOutCubic((alpha - 0.22) / 0.18)
					xzScale = lerpNumber(squashXz, launchXz, phase)
					yScale = lerpNumber(squashY, launchY, phase)
					eyeOffsetScale = lerpNumber(squashEyeOffset, stretchEyeOffset, phase)
				elseif alpha < 0.7 then
					local phase = smoothstep((alpha - 0.4) / 0.3)
					xzScale = lerpNumber(launchXz, 0.78, phase)
					yScale = lerpNumber(launchY, 1 + settings.stretchAmount * 0.82, phase)
					eyeOffsetScale = lerpNumber(stretchEyeOffset, stretchEyeOffset * 0.65, phase)
				elseif alpha < 0.92 then
					local phase = easeInCubic((alpha - 0.7) / 0.22)
					xzScale = lerpNumber(0.78, fallXz, phase)
					yScale = lerpNumber(1 + settings.stretchAmount * 0.82, fallY, phase)
					eyeOffsetScale = lerpNumber(stretchEyeOffset * 0.65, stretchEyeOffset, phase)
				else
					local phase = smoothstep((alpha - 0.92) / 0.08)
					xzScale = lerpNumber(fallXz, impactXz, phase)
					yScale = lerpNumber(fallY, impactY, phase)
					eyeOffsetScale = lerpNumber(stretchEyeOffset, squashEyeOffset, phase)
				end

				local airAlpha = math.clamp((alpha - 0.22) / 0.7, 0, 1)
				local heightAlpha = math.sin(airAlpha * math.pi)
				currentBodySize =
					Vector3.new(originalBodySize.X * xzScale, originalBodySize.Y * yScale, originalBodySize.Z * xzScale)
				currentEyesOffsetY = eyeOffsetScale
				controller.applyPose(baseCFrame + Vector3.new(0, heightAlpha * jumpHeight, 0))
			end)

			controller.applyPose(baseCFrame)
			controller.tweenShape(originalBodySize, 0, recoveryTime)
		end

		controller.applyPose(baseCFrame)
		busy -= 1
	end

	function controller.startIdle()
		task.spawn(function()
			local phase = false
			while model.Parent do
				if visible and busy == 0 then
					phase = not phase
					local amount = settings.idleWiggleAmount
					local xz = phase and (1 + amount) or (1 - amount * 0.65)
					local y = phase and (1 - amount * 0.7) or (1 + amount * 0.45)
					controller.tweenShape(
						Vector3.new(originalBodySize.X * xz, originalBodySize.Y * y, originalBodySize.Z * xz),
						phase and -originalBodySize.Y * amount * 0.08 or originalBodySize.Y * amount * 0.05,
						settings.idleWiggleTime
					)
				else
					task.wait(0.1)
				end
			end
		end)
	end

	controller.applyPose(currentRootCFrame)
	controller.startIdle()
	return controller
end

function MascotService.Register(model)
	if controllers[model] then
		return controllers[model]
	end
	local controller = createController(model)
	controllers[model] = controller
	return controller
end

function MascotService.Unregister(model)
	local controller = controllers[model]
	if controller then
		controller.destroy()
	end
	controllers[model] = nil
end

local function getController(model)
	return controllers[model] or MascotService.Register(model)
end

function MascotService.SetVisible(model, visible)
	local controller = getController(model)
	if controller then
		controller.setVisible(visible)
	end
end

function MascotService.MoveToAnchor(model, anchor)
	local controller = getController(model)
	if controller and anchor and anchor:IsA("Attachment") then
		controller.moveTo(anchor.WorldCFrame)
	end
end

function MascotService.RevealFromSquash(model, anchor)
	local controller = getController(model)
	if controller and anchor and anchor:IsA("Attachment") then
		controller.revealFromSquash(anchor.WorldCFrame)
	end
end

function MascotService.HopToAuthoredAnchor(model, anchor)
	local controller = getController(model)
	if controller and anchor and anchor:IsA("Attachment") then
		controller.hopToAuthoredPose(anchor.WorldCFrame)
	end
end

function MascotService.SetDizzy(model, enabled)
	local controller = getController(model)
	if controller then
		controller.setDizzy(enabled)
	end
end

function MascotService.SetColorProgress(model, progress, animate)
	local controller = getController(model)
	if controller then
		controller.setColorProgress(progress, animate)
	end
end

function MascotService.ResetShape(model)
	local controller = getController(model)
	if controller then
		controller.resetShape()
	end
end

function MascotService.PlayRainbow(model)
	local controller = getController(model)
	if controller then
		controller.playRainbow()
	end
end

function MascotService.PlayJoy(model)
	local controller = getController(model)
	if not controller then
		return
	end

	controller.resetShape()
	local stopRainbowRipple = controller.startRainbowRipple()
	controller.jumpInPlace(2)
	stopRainbowRipple()
end

function MascotService.Init()
	print("MascotService initialized")
end

return MascotService
