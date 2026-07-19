-- Dedicated touch building-stat presenter. CursorTooltip retains its original pointer
-- positioning; world projection, distance scale, safe-inset correction, and StoreBottom
-- layering live only here against the Studio-authored ScreenGui.BuildingTooltip root.
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local StoreBuildingTooltipPresenter = {}

local function isTextObject(instance)
	return instance and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
end

local function findTextObject(parent, name)
	local object = parent and parent:FindFirstChild(name, true)
	if isTextObject(object) then
		return object, object
	end
	if object then
		local nested = object:FindFirstChildWhichIsA("TextLabel", true)
			or object:FindFirstChildWhichIsA("TextButton", true)
			or object:FindFirstChildWhichIsA("TextBox", true)
		return nested, object
	end
	return nil, nil
end

local function setNamedText(root, name, value)
	local label, named = findTextObject(root, name)
	if not label then
		return
	end
	local text = value == nil and "" or tostring(value)
	label.Text = text
	local target = named and named:IsA("GuiObject") and named or label
	target.Visible = text ~= ""
end

function StoreBuildingTooltipPresenter.new(screenGui)
	local root = screenGui:FindFirstChild("BuildingTooltip")
	local scale = root and root:FindFirstChild("WorldScale")
	local activeContent = nil
	local renderConnection = nil
	local destroyed = false
	local positionProviderWarned = false
	local scaleProviderWarned = false

	local presenter = {}

	local function clearConnection()
		if renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end
	end

	local function updatePosition()
		if destroyed or not (root and root.Parent and activeContent) then
			return
		end

		local contentScale = 1
		if type(activeContent.getScale) == "function" then
			local ok, result = pcall(activeContent.getScale)
			if ok and type(result) == "number" then
				contentScale = math.clamp(result, 0.05, 4)
			elseif not ok and not scaleProviderWarned then
				scaleProviderWarned = true
				warn("BuildingTooltip scale provider failed:", result)
			end
		end
		if scale and scale:IsA("UIScale") then
			scale.Scale = contentScale
		end

		local point = nil
		if type(activeContent.getScreenPoint) == "function" then
			local ok, result = pcall(activeContent.getScreenPoint)
			if ok and typeof(result) == "Vector2" then
				point = result
			elseif not ok and not positionProviderWarned then
				positionProviderWarned = true
				warn("BuildingTooltip position provider failed:", result)
			end
		end
		if not point then
			root.Visible = false
			return
		end

		local camera = Workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(math.huge, math.huge)
		local size = root.AbsoluteSize
		local gap = math.max(0, tonumber(activeContent.offsetY) or 0)
		local x = math.clamp(point.X - size.X / 2, 0, math.max(0, viewport.X - size.X))
		local y = math.clamp(point.Y - gap - size.Y, 0, math.max(0, viewport.Y - size.Y))
		local desiredPosition = Vector2.new(math.round(x), math.round(y))
		root.Position = UDim2.fromOffset(desiredPosition.X, desiredPosition.Y)

		-- DeviceSafeInsets transforms root offsets. Compensate against the actual rendered
		-- position so the panel bottom remains at the requested world-point gap.
		local correction = desiredPosition - root.AbsolutePosition
		if correction.Magnitude >= 0.5 then
			root.Position = UDim2.fromOffset(
				desiredPosition.X + math.round(correction.X),
				desiredPosition.Y + math.round(correction.Y)
			)
		end
		root.Visible = true
	end

	function presenter:show(content)
		if destroyed or not root or type(content) ~= "table" then
			presenter:clear()
			return
		end
		activeContent = content
		positionProviderWarned = false
		scaleProviderWarned = false
		setNamedText(root, "Title", content.title)
		if type(content.fields) == "table" then
			for name, value in pairs(content.fields) do
				setNamedText(root, name, value)
			end
		end
		root.Visible = true
		if not renderConnection then
			renderConnection = RunService.RenderStepped:Connect(updatePosition)
		end
		updatePosition()
		task.defer(updatePosition)
	end

	function presenter:clear()
		activeContent = nil
		clearConnection()
		if root then
			root.Visible = false
		end
	end

	function presenter:destroy()
		if destroyed then
			return
		end
		destroyed = true
		activeContent = nil
		clearConnection()
		if root then
			root.Visible = false
		end
	end

	if root and root:IsA("GuiObject") then
		root.AnchorPoint = Vector2.zero
		root.Active = false
		root.Visible = false
		root.Destroying:Once(function()
			clearConnection()
			root = nil
		end)
	else
		warn("BuildingTooltip disabled: ScreenGui.BuildingTooltip was not found")
		root = nil
	end

	return presenter
end

return StoreBuildingTooltipPresenter
