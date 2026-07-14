local CameraZoomMotion = {}

CameraZoomMotion.SCALE = 6
CameraZoomMotion.ACTIVATE_TIME = 0.45
CameraZoomMotion.DEACTIVATE_TIME = 0.45
CameraZoomMotion.ACTIVATE_INFO =
	TweenInfo.new(CameraZoomMotion.ACTIVATE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
CameraZoomMotion.DEACTIVATE_INFO =
	TweenInfo.new(CameraZoomMotion.DEACTIVATE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut)

local function scaleUDim2(size, factor)
	return UDim2.new(size.X.Scale * factor, size.X.Offset * factor, size.Y.Scale * factor, size.Y.Offset * factor)
end

local function centerPosition(position, size, anchor)
	return UDim2.new(
		position.X.Scale + (0.5 - anchor.X) * size.X.Scale,
		position.X.Offset + (0.5 - anchor.X) * size.X.Offset,
		position.Y.Scale + (0.5 - anchor.Y) * size.Y.Scale,
		position.Y.Offset + (0.5 - anchor.Y) * size.Y.Offset
	)
end

function CameraZoomMotion.prepare(guiObject)
	local restSize = guiObject.Size
	guiObject.Position = centerPosition(guiObject.Position, restSize, guiObject.AnchorPoint)
	guiObject.AnchorPoint = Vector2.new(0.5, 0.5)
	return restSize, scaleUDim2(restSize, CameraZoomMotion.SCALE)
end

return CameraZoomMotion
