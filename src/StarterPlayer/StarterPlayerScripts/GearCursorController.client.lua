local Players = game:GetService("Players")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local connectedTools = {}

local function clearCursor()
	if mouse then
		mouse.Icon = ""
	end
end

local function connectTool(tool)
	if not tool:IsA("Tool") or connectedTools[tool] then
		return
	end

	connectedTools[tool] = true
	tool.Unequipped:Connect(clearCursor)
	tool.Destroying:Connect(clearCursor)
end

local function connectContainer(container)
	for _, child in ipairs(container:GetChildren()) do
		connectTool(child)
	end

	container.ChildAdded:Connect(connectTool)
end

local backpack = player:WaitForChild("Backpack")
connectContainer(backpack)

if player.Character then
	connectContainer(player.Character)
end

player.CharacterAdded:Connect(connectContainer)
