-- StoreMultiPlaceSessionControls: desktop-only affordances for one Multi Place run.
-- The Studio-authored counter follows the cursor in both desktop placement presentations.
-- Classic placement also reuses the center hotbar slot as Cancel at x0 and Done after the
-- first server-confirmed building. HotbarPlacementMode owns face visibility and slot geometry.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local Net = require(Shared:WaitForChild("Net"))
local SettingsConfig = require(Shared:WaitForChild("SettingsConfig"))
local UiMotion = require(Shared:WaitForChild("UiMotion"))

local StoreMultiPlaceSessionControls = {}
local STATE_TRANSITION_SECONDS = 0.2

local function isImage(instance)
	return instance and (instance:IsA("ImageLabel") or instance:IsA("ImageButton"))
end

function StoreMultiPlaceSessionControls.new(ctx, placement)
	local screenGui = ctx.screenGui
	local hotbar = screenGui:FindFirstChild("Hotbar")
	local centerSlot = hotbar and hotbar:FindFirstChild("SlotCenter")
	local hitbox = centerSlot and centerSlot:FindFirstChild("hitbox")
	local face = centerSlot and centerSlot:FindFirstChild("MultiPlaceFace")
	local cancelIcon = face and face:FindFirstChild("CancelIcon")
	local doneIcon = face and face:FindFirstChild("DoneIcon")
	local confirmFace = hotbar
		and hotbar:FindFirstChild("SlotRight")
		and hotbar.SlotRight:FindFirstChild("PlacementFace")
	local counterSource = ctx.cursorTooltip
		and ctx.cursorTooltip:createSource({ priority = ctx.cursorTooltip.Priority.Counter })
	local deviceType = SettingsConfig.GetDeviceType(
		UserInputService.TouchEnabled,
		UserInputService.MouseEnabled,
		RunService:IsStudio() and UserInputService.PreferredInput == Enum.PreferredInput.Touch
	)
	local isDesktop = deviceType == SettingsConfig.DeviceType.PC
	local redColor = face and face.BackgroundColor3
	local greenColor = confirmFace and confirmFace.BackgroundColor3 or Color3.fromRGB(64, 200, 96)
	local showingDone = nil
	local stateTweens = {}

	local function cancelStateTweens()
		for _, tween in ipairs(stateTweens) do
			tween:Cancel()
		end
		table.clear(stateTweens)
	end

	local function sessionActive()
		return isDesktop
			and screenGui:GetAttribute(Attrs.PlacementActive) == true
			and screenGui:GetAttribute(Attrs.MultiPlaceSessionActive) == true
	end

	local function classicSessionActive()
		return sessionActive() and screenGui:GetAttribute(Attrs.PlacementControlsEnabled) ~= true
	end

	local function getCount()
		local value = screenGui:GetAttribute(Attrs.MultiPlaceSessionCount)
		return type(value) == "number" and math.max(0, math.floor(value)) or 0
	end

	local function setDoneState(done, animate)
		done = done == true
		if showingDone == done then
			return
		end
		showingDone = done
		cancelStateTweens()
		if not (face and isImage(cancelIcon) and isImage(doneIcon) and redColor) then
			return
		end

		cancelIcon.Visible = true
		doneIcon.Visible = true
		local goals = {
			face = { BackgroundColor3 = done and greenColor or redColor },
			cancel = { ImageTransparency = done and 1 or 0 },
			done = { ImageTransparency = done and 0 or 1 },
		}
		local duration = STATE_TRANSITION_SECONDS
		if not animate or duration <= 0 then
			face.BackgroundColor3 = goals.face.BackgroundColor3
			cancelIcon.ImageTransparency = goals.cancel.ImageTransparency
			doneIcon.ImageTransparency = goals.done.ImageTransparency
			return
		end

		local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		for instance, goal in pairs({
			[face] = goals.face,
			[cancelIcon] = goals.cancel,
			[doneIcon] = goals.done,
		}) do
			local tween = UiMotion.create(instance, info, goal)
			table.insert(stateTweens, tween)
			tween:Play()
		end
	end

	local function refresh()
		local active = sessionActive()
		local count = getCount()
		if counterSource then
			if active then
				counterSource:show({
					mode = "Counter",
					text = "x" .. tostring(count),
				})
			else
				counterSource:clear()
			end
		end
		local classic = classicSessionActive()
		if classic and hitbox and hitbox:IsA("GuiButton") then
			hitbox.Active = true
			hitbox.Interactable = true
		end
		setDoneState(count > 0, classic and showingDone ~= nil)
	end

	if hitbox and hitbox:IsA("GuiButton") then
		hitbox.Activated:Connect(function()
			if not classicSessionActive() then
				return
			end
			if getCount() > 0 then
				Net.fireServer(Net.Names.PlacementControlUsed, "Finish", "Screen")
				placement.finish()
			else
				Net.fireServer(Net.Names.PlacementControlUsed, "Cancel", "Screen")
				placement.cancel()
			end
		end)
	end

	for _, attribute in ipairs({
		Attrs.PlacementActive,
		Attrs.PlacementControlsEnabled,
		Attrs.MultiPlaceSessionActive,
		Attrs.MultiPlaceSessionCount,
	}) do
		screenGui:GetAttributeChangedSignal(attribute):Connect(refresh)
	end

	if counterSource then
		counterSource:clear()
	end
	setDoneState(false, false)
	refresh()

	return {}
end

return StoreMultiPlaceSessionControls
