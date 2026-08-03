-- Focused Mixer-unlock flight. It reacts to the feature's authoritative/player
-- attributes and completes the named presentation signal without knowing quests.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local UiMotion = require(ReplicatedStorage.Shared.UiMotion)

local QuestProgressMixerUnlockVisual = {}
local FLIGHT_SECONDS = 2
local START_HOLD_SECONDS = 0.2
local LANDING_HOLD_SECONDS = 0.35
local RESOLVE_SECONDS = 3
local FADE_SECONDS = 0.22

local function centerOf(instance)
	if instance and instance:IsA("GuiObject") and instance.AbsoluteSize.Magnitude > 0 then
		return instance.AbsolutePosition + instance.AbsoluteSize / 2
	end
	return nil
end

local function playerSheet(player)
	local sheets = Workspace:FindFirstChild("CookieSheets")
	for _, sheet in ipairs(sheets and sheets:GetChildren() or {}) do
		local owner = sheet:FindFirstChild("SheetOwner")
		if owner and owner:IsA("ObjectValue") and owner.Value == player then return sheet end
	end
	return nil
end

function QuestProgressMixerUnlockVisual.new(screenGui, root)
	local player = Players.LocalPlayer
	local flight = root:FindFirstChild("MixerUnlockFlight", true)
	local generation = 0
	local pending = false
	local connections = {}
	if flight and flight:IsA("GuiObject") then flight.Visible = false end

	local function complete()
		if player:GetAttribute(Attrs.MixerUnlocked) == true then
			screenGui:SetAttribute(Attrs.MixerUnlockPresented, true)
		end
	end

	local function play()
		if pending or player:GetAttribute(Attrs.MixerUnlocked) ~= true
			or screenGui:GetAttribute(Attrs.MixerUnlockPresented) == true
		then return end
		if not (flight and flight:IsA("ImageLabel")) then complete(); return end
		pending = true
		generation += 1
		local token = generation
		task.spawn(function()
			local mascot, slot, icon, destination, projected
			local deadline = os.clock() + RESOLVE_SECONDS
			repeat
				local sheet = playerSheet(player)
				mascot = sheet and sheet:FindFirstChild("GooAlien")
				local hotbar = screenGui:FindFirstChild("Hotbar")
				slot = hotbar and hotbar:FindFirstChild("SlotCenter")
				icon = slot and slot:FindFirstChild("icon")
				destination = centerOf(slot)
				local camera = Workspace.CurrentCamera
				if mascot and camera then projected = camera:WorldToViewportPoint(mascot:GetPivot().Position) end
				if mascot and destination and projected and projected.Z > 0
					and screenGui:GetAttribute(Attrs.MixerUnlockSlotReady) == true
				then break end
				task.wait(0.1)
			until os.clock() >= deadline or token ~= generation
			pending = false
			if token ~= generation then return end
			if not (mascot and destination and projected and projected.Z > 0
				and screenGui:GetAttribute(Attrs.MixerUnlockSlotReady) == true and flight.Parent)
			then complete(); return end

			local visual = flight:FindFirstChild("MixerUnlock", true)
			if not (visual and (visual:IsA("ImageLabel") or visual:IsA("ImageButton"))) then visual = flight end
			if visual == flight and visual.Image == "" and icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
				visual.Image = icon.Image
				visual.ImageColor3 = icon.ImageColor3
			end
			flight.AnchorPoint = Vector2.new(0.5, 0.5)
			flight.BackgroundTransparency = 1
			flight.Position = UDim2.fromOffset(projected.X - root.AbsolutePosition.X, projected.Y - root.AbsolutePosition.Y)
			flight.Visible = true
			visual.Visible = true
			visual.ImageTransparency = 0
			task.wait(START_HOLD_SECONDS)
			if token ~= generation or not flight.Parent then return end
			local target = UDim2.fromOffset(destination.X - root.AbsolutePosition.X, destination.Y - root.AbsolutePosition.Y)
			if UiMotion.isReduced(flight) then
				flight.Position = target
				task.wait(FLIGHT_SECONDS)
			else
				local tween = UiMotion.create(flight, TweenInfo.new(FLIGHT_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Position = target })
				tween:Play()
				tween.Completed:Wait()
			end
			if token ~= generation or not flight.Parent then return end
			task.wait(LANDING_HOLD_SECONDS)
			if UiMotion.isReduced(flight) then
				visual.ImageTransparency = 1
			else
				local fade = UiMotion.create(visual, TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { ImageTransparency = 1 })
				fade:Play()
				fade.Completed:Wait()
			end
			if token == generation and flight.Parent then
				flight.Visible = false
				complete()
			end
		end)
	end

	table.insert(connections, player:GetAttributeChangedSignal(Attrs.MixerUnlocked):Connect(play))
	table.insert(connections, screenGui:GetAttributeChangedSignal(Attrs.MixerUnlockSlotReady):Connect(play))
	task.defer(play)
	return {
		destroy = function()
			generation += 1
			pending = false
			if flight and flight:IsA("GuiObject") then flight.Visible = false end
			for _, connection in ipairs(connections) do connection:Disconnect() end
		end,
	}
end

return QuestProgressMixerUnlockVisual
