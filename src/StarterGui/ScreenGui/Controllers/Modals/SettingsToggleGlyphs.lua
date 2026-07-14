local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local CameraZoomMotion = require(shared:WaitForChild("CameraZoomMotion"))
local UiMotion = require(shared:WaitForChild("UiMotion"))

local SettingsToggleGlyphs = {}

local PLACEMENT_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local AUTO_BUILD_ON_FADE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local AUTO_BUILD_OFF_FADE_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local SWIPE_OFFSET = 1.5

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

local function offsetY(position, scaleOffset)
	return UDim2.new(position.X.Scale, position.X.Offset, position.Y.Scale + scaleOffset, position.Y.Offset)
end

local function bindPlacementControls(body, screenGui)
	local row = findRow(body, "PlacementControls")
	local icon = row and row:FindFirstChild("Icon")
	local placement = icon and icon:FindFirstChild("Glyph")
	local cursor = icon and icon:FindFirstChild("Glyph2")
	if not (icon and icon:IsA("GuiObject") and isImage(placement) and isImage(cursor)) then
		return
	end

	local placementRest = placement.Position
	local cursorRest = cursor.Position
	local placementUp = offsetY(placementRest, -SWIPE_OFFSET)
	local cursorDown = offsetY(cursorRest, SWIPE_OFFSET)
	local placementTween
	local cursorTween

	placement.Visible = true
	cursor.Visible = true

	local function refresh(animate)
		if placementTween then
			placementTween:Cancel()
		end
		if cursorTween then
			cursorTween:Cancel()
		end

		local enabled = screenGui:GetAttribute(Attrs.PlacementControlsEnabled) == true
		local placementTarget = enabled and placementRest or placementUp
		local cursorTarget = enabled and cursorDown or cursorRest
		if not animate then
			placement.Position = placementTarget
			cursor.Position = cursorTarget
			return
		end

		placementTween = UiMotion.create(placement, PLACEMENT_TWEEN_INFO, { Position = placementTarget })
		cursorTween = UiMotion.create(cursor, PLACEMENT_TWEEN_INFO, { Position = cursorTarget })
		placementTween:Play()
		cursorTween:Play()
	end

	refresh(false)
	screenGui:GetAttributeChangedSignal(Attrs.PlacementControlsEnabled):Connect(function()
		refresh(true)
	end)
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

function SettingsToggleGlyphs.new(body, screenGui)
	bindPlacementControls(body, screenGui)
	bindAutoBuildMode(body, screenGui)
end

return SettingsToggleGlyphs
