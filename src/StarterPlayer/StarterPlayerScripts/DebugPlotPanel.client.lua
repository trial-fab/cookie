-- Studio-only test panel: Add/Remove plot buttons that drive the SAME server-side
-- grow/trim logic as a real player join/leave (via TestCommandService -> SheetService).
-- Self-disables outside Studio so it never reaches a live server.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "DebugPlotPanel"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 1000
gui.Parent = playerGui

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = parent
end

local toggle = Instance.new("TextButton")
toggle.Name = "Toggle"
toggle.Size = UDim2.fromOffset(132, 32)
toggle.Position = UDim2.fromOffset(12, 120)
toggle.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
toggle.TextColor3 = Color3.fromRGB(235, 235, 245)
toggle.Font = Enum.Font.GothamBold
toggle.TextSize = 14
toggle.Text = "Plots \u{25B8}"
toggle.AutoButtonColor = true
toggle.Parent = gui
corner(toggle)

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(132, 108)
panel.Position = UDim2.fromOffset(12, 158)
panel.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
panel.Visible = false
panel.Parent = gui
corner(panel)

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 8)
pad.PaddingBottom = UDim.new(0, 8)
pad.PaddingLeft = UDim.new(0, 8)
pad.PaddingRight = UDim.new(0, 8)
pad.Parent = panel

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = panel

local function makeButton(text, color, order, action)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 38)
	b.LayoutOrder = order
	b.BackgroundColor3 = color
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 15
	b.Text = text
	b.Parent = panel
	corner(b)
	b.Activated:Connect(function()
		Net.fireServer(Net.Names.DebugPlot, action)
	end)
	return b
end

makeButton("+ Add plot", Color3.fromRGB(46, 120, 70), 1, "add")
makeButton("\u{2212} Remove plot", Color3.fromRGB(140, 52, 52), 2, "remove")

toggle.Activated:Connect(function()
	panel.Visible = not panel.Visible
	toggle.Text = panel.Visible and "Plots \u{25BE}" or "Plots \u{25B8}"
end)
