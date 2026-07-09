local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local ModalOutsideClose = {}

local POINTER_INPUTS = {
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.UserInputType.Touch] = true,
}

local function contains(root, object)
	return root ~= nil and object ~= nil and (object == root or object:IsDescendantOf(root))
end

local function pointInside(object, x, y)
	if not object or not object:IsA("GuiObject") then
		return false
	end

	local position = object.AbsolutePosition
	local size = object.AbsoluteSize
	return x >= position.X
		and x <= position.X + size.X
		and y >= position.Y
		and y <= position.Y + size.Y
end

local function addRoot(roots, root)
	if typeof(root) == "Instance" then
		table.insert(roots, root)
	end
end

local function collectIgnoreRoots(config)
	local roots = {}

	if typeof(config.ignoreRoots) == "table" then
		for _, root in pairs(config.ignoreRoots) do
			addRoot(roots, root)
		end
	end

	if typeof(config.getIgnoreRoots) == "function" then
		local dynamicRoots = config.getIgnoreRoots()
		if typeof(dynamicRoots) == "table" then
			for _, root in pairs(dynamicRoots) do
				addRoot(roots, root)
			end
		else
			addRoot(roots, dynamicRoots)
		end
	end

	return roots
end

function ModalOutsideClose.bind(config)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	return UserInputService.InputBegan:Connect(function(input)
		if not POINTER_INPUTS[input.UserInputType] then
			return
		end
		if typeof(config.isOpen) == "function" and not config.isOpen() then
			return
		end

		local position = input.Position
		local x = position.X
		local y = position.Y

		if pointInside(config.modal, x, y) then
			return
		end

		local ignoreRoots = collectIgnoreRoots(config)
		for _, root in ipairs(ignoreRoots) do
			if pointInside(root, x, y) then
				return
			end
		end

		for _, object in ipairs(playerGui:GetGuiObjectsAtPosition(x, y)) do
			if contains(config.modal, object) then
				return
			end
			-- Category rule: a click that lands on any active button is "interacting with
			-- the game" (HUD / store / menu controls), not a dismiss — so the control fires
			-- its own function and the modal stays open. Self-maintaining: new buttons are
			-- covered automatically, with no allowlist to drift (the stringly-typed footgun
			-- this codebase keeps hitting). Only clicks on inert background close the modal.
			if object:IsA("GuiButton") and object.Active ~= false then
				return
			end
			for _, root in ipairs(ignoreRoots) do
				if contains(root, object) then
					return
				end
			end
		end

		if typeof(config.close) == "function" then
			config.close()
		end
	end)
end

return ModalOutsideClose
