local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local CameraZoomMotion = require(shared:WaitForChild("CameraZoomMotion"))
local UiMotion = require(shared:WaitForChild("UiMotion"))

local SettingsToggleGlyphs = {}

local AUTO_BUILD_ON_FADE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local AUTO_BUILD_OFF_FADE_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local PLACEMENT_CONTROLS_SLIDE_INFO = TweenInfo.new(0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function findRow(body, rowName)
	local row = body:FindFirstChild(rowName, true)
	if row and row:IsA("GuiObject") then
		return row
	end
	return nil
end

local function isImage(instance)
	return instance and (instance:IsA("ImageLabel") or instance:IsA("ImageButton"))
end

local function bindAutoBuildMode(body, screenGui)
	local row = findRow(body, "AutoBuildMode")
	local icon = row and row:FindFirstChild("Icon")
	local tools = icon and icon:FindFirstChild("Glyph")
	local camera = icon and icon:FindFirstChild("Glyph2")
	if not (isImage(tools) and isImage(camera)) then
		return
	end

	local toolsRestTransparency = tools.ImageTransparency
	local cameraRestTransparency = camera.ImageTransparency
	local cameraRestSize, cameraZoomSize = CameraZoomMotion.prepare(camera)
	local toolsTween
	local cameraFadeTween
	local cameraZoomTween

	tools.Visible = true
	camera.Visible = true

	local function refresh(animate)
		if toolsTween then
			toolsTween:Cancel()
		end
		if cameraFadeTween then
			cameraFadeTween:Cancel()
		end
		if cameraZoomTween then
			cameraZoomTween:Cancel()
		end

		local enabled = screenGui:GetAttribute(Attrs.AutoBuildMode) == true
		local toolsTransparency = enabled and 1 or toolsRestTransparency
		local cameraSize = enabled and cameraRestSize or cameraZoomSize
		local cameraTransparency = enabled and cameraRestTransparency or 1
		if not animate then
			tools.ImageTransparency = toolsTransparency
			camera.Size = cameraSize
			camera.ImageTransparency = cameraTransparency
			return
		end

		local zoomInfo = enabled and CameraZoomMotion.DEACTIVATE_INFO or CameraZoomMotion.ACTIVATE_INFO
		local fadeInfo = enabled and AUTO_BUILD_ON_FADE_INFO or AUTO_BUILD_OFF_FADE_INFO
		toolsTween = UiMotion.create(tools, fadeInfo, { ImageTransparency = toolsTransparency })
		cameraFadeTween = UiMotion.create(camera, fadeInfo, { ImageTransparency = cameraTransparency })
		cameraZoomTween = UiMotion.create(camera, zoomInfo, { Size = cameraSize })
		toolsTween:Play()
		cameraFadeTween:Play()
		cameraZoomTween:Play()
	end

	refresh(false)
	screenGui:GetAttributeChangedSignal(Attrs.AutoBuildMode):Connect(function()
		refresh(true)
	end)
end

local function bindPlacementControls(body, screenGui)
	local row = findRow(body, "PlacementControls")
	local icon = row and row:FindFirstChild("Icon")
	local controls = icon and icon:FindFirstChild("PlacementControls")
	local cursor = icon and icon:FindFirstChild("Cursor")
	if not (isImage(controls) and isImage(cursor)) then
		return
	end

	local controlsTween
	local cursorTween
	local center = UDim2.fromScale(0.5, 0.5)
	local above = UDim2.fromScale(0.5, -0.5)
	local below = UDim2.fromScale(0.5, 1.5)

	controls.Visible = true
	cursor.Visible = true

	local function refresh(animate)
		if controlsTween then
			controlsTween:Cancel()
		end
		if cursorTween then
			cursorTween:Cancel()
		end

		local enabled = screenGui:GetAttribute(Attrs.PlacementControlsEnabled) == true
		local controlsTarget = enabled and center or above
		local cursorTarget = enabled and below or center
		if not animate then
			controls.Position = controlsTarget
			cursor.Position = cursorTarget
			return
		end

		controlsTween = UiMotion.create(controls, PLACEMENT_CONTROLS_SLIDE_INFO, {
			Position = controlsTarget,
		})
		cursorTween = UiMotion.create(cursor, PLACEMENT_CONTROLS_SLIDE_INFO, {
			Position = cursorTarget,
		})
		controlsTween:Play()
		cursorTween:Play()
	end

	refresh(false)
	screenGui:GetAttributeChangedSignal(Attrs.PlacementControlsEnabled):Connect(function()
		refresh(true)
	end)
end

function SettingsToggleGlyphs.new(body, screenGui)
	bindAutoBuildMode(body, screenGui)
	bindPlacementControls(body, screenGui)
end

return SettingsToggleGlyphs
