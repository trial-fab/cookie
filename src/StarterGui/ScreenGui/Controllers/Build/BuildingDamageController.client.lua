local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local pickaxeTools = {
	PickAxe = true,
	["PA High Tech"] = true,
}
local lastDamageFiredAt = 0 
local disableLegacyPickaxeScripts

local function playPickaxeSwing(tool)
	if tool:GetAttribute("SwingingPickaxe") then
		return
	end

	tool:SetAttribute("SwingingPickaxe", true)
	task.spawn(function()
		local originalGrip = tool.Grip
		local swingGrip = originalGrip * CFrame.Angles(math.rad(-70), 0, math.rad(8))
		local swingOut = TweenService:Create(tool, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Grip = swingGrip,
		})
		local swingBack = TweenService:Create(tool, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Grip = originalGrip,
		})

		swingOut:Play()
		swingOut.Completed:Wait()
		if tool.Parent then
			swingBack:Play()
			swingBack.Completed:Wait()
		end
		if tool.Parent then
			tool.Grip = originalGrip
		end
		tool:SetAttribute("SwingingPickaxe", false)
	end)
end

local function fireDamageAtMouse()
	if os.clock() - lastDamageFiredAt < 0.08 then
		return
	end

	local character = player.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if not tool or not pickaxeTools[tool.Name] then
		return
	end

	disableLegacyPickaxeScripts(tool)
	if mouse.Target then
		lastDamageFiredAt = os.clock()
		playPickaxeSwing(tool)
		Net.fireServer(Net.Names.DamageBuilding, mouse.Target, mouse.Hit.Position)
	end
end

disableLegacyPickaxeScripts = function(tool)
	if not tool or not tool:IsA("Tool") or not pickaxeTools[tool.Name] then
		return
	end

	for _, descendant in ipairs(tool:GetDescendants()) do
		if descendant:IsA("LocalScript") and descendant.Name == "PickaxeScript" then
			descendant.Disabled = true
		end
	end

	if not tool:GetAttribute("WatchingLegacyPickaxeScripts") then
		tool:SetAttribute("WatchingLegacyPickaxeScripts", true)
		tool.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("LocalScript") and descendant.Name == "PickaxeScript" then
				descendant.Disabled = true
			end
		end)
		tool.Activated:Connect(fireDamageAtMouse)
	end
end

local function watchToolContainer(container)
	if not container then
		return
	end

	for _, child in ipairs(container:GetChildren()) do
		disableLegacyPickaxeScripts(child)
	end

	container.ChildAdded:Connect(function(child)
		disableLegacyPickaxeScripts(child)
	end)
end

local function watchCharacter(character)
	watchToolContainer(character)
end

watchToolContainer(player:WaitForChild("Backpack"))
if player.Character then
	watchCharacter(player.Character)
end
player.CharacterAdded:Connect(watchCharacter)

mouse.Button1Down:Connect(fireDamageAtMouse)