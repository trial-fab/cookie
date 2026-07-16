-- DevTuningController: thin orchestrator for the allowlisted, runtime-built admin panel.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GUI_NAME = "DevTuningGui"
local ADMIN_USER_IDS = {
	[10748851] = true,
}

local player = Players.LocalPlayer
local shared = ReplicatedStorage:WaitForChild("Shared")
local devTuningFolder = shared:WaitForChild("DevTuning")
local DevTuning = require(devTuningFolder:WaitForChild("DevTuning"))
local Policy = require(devTuningFolder:WaitForChild("Policy"))

if not DevTuning.Enabled or not Policy.isAllowedUserId(player.UserId, ADMIN_USER_IDS) then
	return
end

local playerGui = player:WaitForChild("PlayerGui")
local existing = playerGui:FindFirstChild(GUI_NAME)
if existing then
	local oldShutdown = existing:FindFirstChild("Shutdown")
	if oldShutdown and oldShutdown:IsA("BindableEvent") then
		oldShutdown:Fire()
	end
	existing:Destroy()
end

local ctx = {
	player = player,
	playerGui = playerGui,
	guiName = GUI_NAME,
	DevTuning = DevTuning,
	Net = require(shared:WaitForChild("Net")),
	catalog = DevTuning.getCatalog(),
	connections = {},
	observations = {},
	groups = {},
	rows = {},
	pending = {},
}
ctx.panelBuilder = require(script.Parent:WaitForChild("DevTuningPanel"))
ctx.controls = require(script.Parent:WaitForChild("DevTuningControls"))
ctx.window = require(script.Parent:WaitForChild("DevTuningWindow"))

local cleaned = false
local function cleanup()
	if cleaned then
		return
	end
	cleaned = true
	for _, observation in ipairs(ctx.observations) do
		observation:Disconnect()
	end
	for _, connection in ipairs(ctx.connections) do
		connection:Disconnect()
	end
	table.clear(ctx.observations)
	table.clear(ctx.connections)
end

ctx.panelBuilder.create(ctx)
ctx.window.attach(ctx)
ctx.controls.mount(ctx)
table.insert(ctx.connections, ctx.shutdown.Event:Connect(cleanup))
table.insert(ctx.connections, script.Destroying:Connect(cleanup))
