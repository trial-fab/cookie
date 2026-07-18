-- CursorTooltip: one client-side presenter for information that follows the pointer.
--
-- The module never creates or clones player-facing UI. It binds the persistent
-- Studio-authored ScreenGui child named CursorTooltip.
--
-- Producers publish content through a source handle:
--   local source = CursorTooltip.get(screenGui):createSource({ priority = 200 })
--   source:show({ mode = "Counter", text = "x10" })
--   source:clear()
--
-- GuiObjects can be registered for hover/selection or click-to-toggle presentation:
--   tooltip:registerGui(button, {
--       trigger = tooltip.Trigger.Hover,
--       content = { mode = "Hint", keybind = "V", title = "Build View" },
--   })
-- Click-pinned tooltips dismiss when the player presses outside the registered
-- GuiObject (opt out per registration with dismissOnOutsideClick = false).
--
-- Modes are Studio-authored: when the bound root is a container frame, every direct
-- GuiObject child is one mode and content.mode selects it by name (unknown names fall
-- back to a child named "Hint"). Adding a mode is pure Studio work - author a new
-- named child frame; this module needs no change.
--
-- World-stat controllers remain responsible for hit testing and selection. They can provide
-- getScreenPoint + placement = "Above" when a touch tooltip should follow a world object
-- instead of the mouse; this presenter only renders and positions their published content.
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local CursorTooltipConfig = require(script.Parent:WaitForChild("CursorTooltipConfig"))

local CursorTooltip = {}

CursorTooltip.Priority = {
	BuildingStats = 100,
	Counter = 200,
	Hint = 300,
	Pinned = 400,
}

CursorTooltip.Trigger = {
	Hover = "Hover",
	Click = "Click",
	HoverAndClick = "HoverAndClick",
}

local instances = setmetatable({}, { __mode = "k" })

local function isTextObject(instance)
	return instance and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
end

-- Returns the text object to write to plus the named instance itself, which may be
-- a container (e.g. a keycap frame holding an icon and its overlay label).
local function findTextObject(parent, name)
	if not parent then
		return nil, nil
	end
	if parent.Name == name and isTextObject(parent) then
		return parent, parent
	end
	local object = parent:FindFirstChild(name, true)
	if isTextObject(object) then
		return object, object
	end
	if object then
		local nested = object:FindFirstChildWhichIsA("TextLabel", true)
			or object:FindFirstChildWhichIsA("TextButton", true)
			or object:FindFirstChildWhichIsA("TextBox", true)
		if nested then
			return nested, object
		end
	end
	return nil, nil
end

local function appendText(parts, value)
	if type(value) == "string" and value ~= "" then
		table.insert(parts, value)
	end
end

local function getFallbackText(content)
	if type(content.text) == "string" then
		return content.text
	end

	local parts = {}
	appendText(parts, content.keybind)
	appendText(parts, content.title)
	appendText(parts, content.description)
	if type(content.lines) == "table" then
		for _, line in ipairs(content.lines) do
			appendText(parts, line)
		end
	end
	if type(content.fields) == "table" then
		local names = {}
		for name in pairs(content.fields) do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in ipairs(names) do
			local value = content.fields[name]
			if value ~= nil then
				appendText(parts, tostring(name) .. ": " .. tostring(value))
			end
		end
	end
	return table.concat(parts, "\n")
end

local function resolveContent(candidate)
	if type(candidate) == "function" then
		local ok, result = pcall(candidate)
		if not ok then
			warn("CursorTooltip content provider failed:", result)
			return nil
		end
		candidate = result
	end
	return type(candidate) == "table" and candidate or nil
end

local function findRoot(screenGui)
	local root = screenGui:FindFirstChild("CursorTooltip")
	if root and root:IsA("GuiObject") then
		return root
	end

	return nil
end

local function newPresenter(screenGui)
	local root = findRoot(screenGui)
	local entries = {}
	local sequence = 0
	local activeSource = nil
	local activeContent = nil
	local renderConnection = nil

	local presenter = {
		Priority = CursorTooltip.Priority,
		Trigger = CursorTooltip.Trigger,
	}

	local lastFollowPoint = nil

	local positionProviderWarned = false
	local function getFollowPoint()
		if activeContent and type(activeContent.getScreenPoint) == "function" then
			local ok, result = pcall(activeContent.getScreenPoint)
			if ok and typeof(result) == "Vector2" then
				return result, activeContent.placement == "Above" and "Above" or "Cursor"
			end
			if not ok and not positionProviderWarned then
				positionProviderWarned = true
				warn("CursorTooltip screen-position provider failed:", result)
			end
			return nil, nil
		end

		local point = UserInputService:GetMouseLocation()
		if not screenGui.IgnoreGuiInset then
			point -= GuiService:GetGuiInset()
		end
		return point, "Cursor"
	end

	local function updatePosition(force)
		if not (root and root.Parent and root.Visible) then
			if not (root and root.Parent and activeContent) then
				return
			end
		end

		local point, placement = getFollowPoint()
		if not point then
			root.Visible = false
			return
		end
		if not force and point == lastFollowPoint and root.Visible then
			return
		end
		lastFollowPoint = point

		-- Cursor hints flip to the opposite side before clamping. World-anchored
		-- panels stay above their target and clamp at the viewport edge so a camera
		-- pitch change cannot make the entire panel jump below the building.
		local camera = Workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(math.huge, math.huge)
		local size = root.AbsoluteSize
		local x
		local y
		if placement == "Above" then
			x = point.X - size.X / 2
			y = point.Y - CursorTooltipConfig.OffsetY - size.Y
		else
			x = point.X + CursorTooltipConfig.OffsetX
			if x + size.X > viewport.X then
				x = point.X - CursorTooltipConfig.OffsetX - size.X
			end
			y = point.Y + CursorTooltipConfig.OffsetY
			if y + size.Y > viewport.Y then
				y = point.Y - CursorTooltipConfig.OffsetY - size.Y
			end
		end
		x = math.clamp(x, 0, math.max(0, viewport.X - size.X))
		y = math.clamp(y, 0, math.max(0, viewport.Y - size.Y))
		root.Position = UDim2.fromOffset(math.round(x), math.round(y))
		root.Visible = true
	end

	local function setFollowing(active)
		if active and not renderConnection then
			renderConnection = RunService.RenderStepped:Connect(function()
				updatePosition(false)
			end)
		elseif not active and renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
			lastFollowPoint = nil
		end
	end

	local function setNamedText(container, name, value)
		local label, named = findTextObject(container, name)
		if label then
			local text = value == nil and "" or tostring(value)
			label.Text = text
			-- Empty values collapse the whole named element (label or its container)
			-- instead of leaving blank keycaps/rows in layouts.
			local target = (named and named:IsA("GuiObject")) and named or label
			target.Visible = text ~= ""
		end
		return label
	end

	local function renderContent(content)
		if not root then
			return
		end
		activeContent = content
		positionProviderWarned = false

		local modeName = type(content.mode) == "string" and content.mode or "Hint"
		local selected = root
		if not isTextObject(root) then
			local match = nil
			local fallback = nil
			for _, child in ipairs(root:GetChildren()) do
				if child:IsA("GuiObject") then
					if child.Name == modeName then
						match = child
					elseif child.Name == "Hint" then
						fallback = child
					end
				end
			end
			match = match or fallback
			if match then
				for _, child in ipairs(root:GetChildren()) do
					if child:IsA("GuiObject") then
						child.Visible = child == match
					end
				end
				selected = match
			end
		end

		local fallbackText = getFallbackText(content)
		if isTextObject(selected) then
			selected.Text = fallbackText
		else
			local primary = setNamedText(selected, "Text", fallbackText)
			if not primary and modeName == "Counter" then
				setNamedText(selected, "Counter", fallbackText)
			end
			setNamedText(selected, "Keybind", content.keybind)
			setNamedText(selected, "Title", content.title)
			setNamedText(selected, "Description", content.description)
			if type(content.fields) == "table" then
				for name, value in pairs(content.fields) do
					setNamedText(selected, name, value)
				end
			end
		end

		root.Visible = true
		setFollowing(true)
		updatePosition(true)
		-- AbsoluteSize settles a frame after a text/mode change; reposition once more.
		task.defer(updatePosition, true)
	end

	local function chooseActive()
		local bestSource = nil
		local bestRecord = nil
		for source, record in pairs(entries) do
			if
				not bestRecord
				or record.priority > bestRecord.priority
				or (record.priority == bestRecord.priority and record.sequence > bestRecord.sequence)
			then
				bestSource = source
				bestRecord = record
			end
		end
		return bestSource, bestRecord
	end

	local function refresh()
		local source, record = chooseActive()
		activeSource = source
		if record then
			renderContent(record.content)
		elseif root then
			activeContent = nil
			root.Visible = false
			setFollowing(false)
		end
	end

	function presenter:createSource(options)
		options = options or {}
		local source = {}
		local handle = {}
		local destroyed = false
		local defaultPriority = type(options.priority) == "number" and options.priority or 0

		function handle:show(content)
			if destroyed then
				return
			end
			content = resolveContent(content)
			if not content then
				handle:clear()
				return
			end

			sequence += 1
			entries[source] = {
				content = content,
				priority = type(content.priority) == "number" and content.priority or defaultPriority,
				sequence = sequence,
			}
			refresh()
		end

		function handle:clear()
			if entries[source] then
				entries[source] = nil
				refresh()
			end
		end

		function handle:isActive()
			return activeSource == source
		end

		function handle:destroy()
			if destroyed then
				return
			end
			destroyed = true
			handle:clear()
		end

		return handle
	end

	function presenter:registerGui(guiObject, options)
		options = options or {}
		if not (guiObject and guiObject:IsA("GuiObject")) then
			return nil
		end

		local trigger = options.trigger or CursorTooltip.Trigger.Hover
		local hoverEnabled = trigger == CursorTooltip.Trigger.Hover or trigger == CursorTooltip.Trigger.HoverAndClick
		local clickEnabled = (trigger == CursorTooltip.Trigger.Click or trigger == CursorTooltip.Trigger.HoverAndClick)
			and guiObject:IsA("GuiButton")
		local dismissOnOutsideClick = options.dismissOnOutsideClick ~= false
		local defaultPriority = trigger == CursorTooltip.Trigger.Click and CursorTooltip.Priority.Pinned
			or CursorTooltip.Priority.Hint
		local source = presenter:createSource({
			priority = type(options.priority) == "number" and options.priority or defaultPriority,
		})
		local connections = {}
		local activeReasons = {}
		local clickedOpen = false
		local pointerOver = false
		local outsideConnection = nil
		local disconnected = false
		local refreshRegistration

		local function isPressInside(position)
			local topLeft = guiObject.AbsolutePosition
			local size = guiObject.AbsoluteSize
			return position.X >= topLeft.X
				and position.X <= topLeft.X + size.X
				and position.Y >= topLeft.Y
				and position.Y <= topLeft.Y + size.Y
		end

		-- Runs only while a click-pinned tooltip is open: any press that is not on
		-- the registered GuiObject dismisses it (presses on the object are left to
		-- Activated so the toggle still works).
		local function setOutsideWatch(active)
			if active and not outsideConnection then
				outsideConnection = UserInputService.InputBegan:Connect(function(input)
					local inputType = input.UserInputType
					if
						inputType ~= Enum.UserInputType.MouseButton1
						and inputType ~= Enum.UserInputType.MouseButton2
						and inputType ~= Enum.UserInputType.Touch
					then
						return
					end
					if pointerOver or isPressInside(input.Position) then
						return
					end
					clickedOpen = false
					refreshRegistration()
				end)
			elseif not active and outsideConnection then
				outsideConnection:Disconnect()
				outsideConnection = nil
			end
		end

		refreshRegistration = function()
			if clickedOpen or next(activeReasons) ~= nil then
				source:show(options.getContent or options.content)
			else
				source:clear()
			end
			setOutsideWatch(clickEnabled and dismissOnOutsideClick and clickedOpen)
		end

		local function setReason(reason, active)
			activeReasons[reason] = active and true or nil
			refreshRegistration()
		end

		table.insert(
			connections,
			guiObject.MouseEnter:Connect(function()
				pointerOver = true
				if hoverEnabled then
					setReason("Mouse", true)
				end
			end)
		)
		table.insert(
			connections,
			guiObject.MouseLeave:Connect(function()
				pointerOver = false
				if hoverEnabled then
					setReason("Mouse", false)
				end
			end)
		)

		if hoverEnabled then
			table.insert(
				connections,
				guiObject.SelectionGained:Connect(function()
					setReason("Selection", true)
				end)
			)
			table.insert(
				connections,
				guiObject.SelectionLost:Connect(function()
					setReason("Selection", false)
				end)
			)
		end

		if clickEnabled then
			table.insert(
				connections,
				guiObject.Activated:Connect(function()
					clickedOpen = not clickedOpen
					refreshRegistration()
				end)
			)
		end

		local registration = {}

		function registration:show()
			clickedOpen = true
			refreshRegistration()
		end

		function registration:clear()
			clickedOpen = false
			table.clear(activeReasons)
			setOutsideWatch(false)
			source:clear()
		end

		function registration:refresh()
			refreshRegistration()
		end

		function registration:disconnect()
			if disconnected then
				return
			end
			disconnected = true
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			table.clear(connections)
			registration:clear()
			source:destroy()
		end

		guiObject.Destroying:Once(function()
			registration:disconnect()
		end)

		return registration
	end

	function presenter:isAvailable()
		return root ~= nil
	end

	if root then
		root.AnchorPoint = Vector2.new(0, root.AnchorPoint.Y)
		root.Active = false
		if isTextObject(root) then
			root.TextXAlignment = Enum.TextXAlignment.Left
		end
		root.Visible = false
		root.Destroying:Once(function()
			setFollowing(false)
			root = nil
		end)
	else
		warn("CursorTooltip disabled: ScreenGui.CursorTooltip was not found")
	end

	return presenter
end

function CursorTooltip.get(screenGui)
	if not (screenGui and screenGui:IsA("ScreenGui")) then
		error("CursorTooltip.get requires a ScreenGui", 2)
	end

	local presenter = instances[screenGui]
	if not presenter then
		presenter = newPresenter(screenGui)
		instances[screenGui] = presenter
	end
	return presenter
end

return CursorTooltip
