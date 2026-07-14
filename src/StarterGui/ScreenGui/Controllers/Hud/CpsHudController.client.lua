-- CpsHudController — the "watch the number go up" HUD metric (roadmap Phase 3 /
-- spec §9). Logic only: the CpsHud pill is authored in Studio (StarterGui.ScreenGui
-- → CpsHud.Inner.Value). This binds to it and drives the text from the live CpS the
-- server replicates onto the player as the `Cps` attribute (ProductionService.RefreshCps).
-- The rate includes placed buildings and in-session autoclick income.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NumberFormat = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("NumberFormat"))
local Attrs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Attrs"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("CpsHudController must be inside a ScreenGui")
	return
end
if screenGui:GetAttribute("CpsHudControllerRunning") then
	return
end
screenGui:SetAttribute("CpsHudControllerRunning", true)

local player = Players.LocalPlayer

local pill = screenGui:WaitForChild("CpsHud", 10)
if not pill then
	warn("CpsHudController disabled: ScreenGui.CpsHud was not found")
	return
end

local label = pill:FindFirstChild("Value", true)
if not label or not (label:IsA("TextLabel") or label:IsA("TextButton")) then
	warn("CpsHudController disabled: CpsHud.Value label was not found")
	return
end

local function render()
	local cps = player:GetAttribute(Attrs.Cps)
	cps = typeof(cps) == "number" and cps or 0
	label.Text = NumberFormat.rate(cps) .. " /s"
end

player:GetAttributeChangedSignal(Attrs.Cps):Connect(render)
render()
