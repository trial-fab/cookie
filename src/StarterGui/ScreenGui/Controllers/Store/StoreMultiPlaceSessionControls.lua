-- StoreMultiPlaceSessionControls: PC classic-placement affordances.
-- The cursor counter is Multi-Place-only. With screen controls off, the center hotbar face stays
-- Cancel-only while the ghost follows the mouse in both single placement and Multi-Place.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local CursorTooltipTuning = require(Shared:WaitForChild("CursorTooltipTuning"))
local Net = require(Shared:WaitForChild("Net"))
local SettingsConfig = require(Shared:WaitForChild("SettingsConfig"))

local StoreMultiPlaceSessionControls = {}

local function isImage(instance)
	return instance and (instance:IsA("ImageLabel") or instance:IsA("ImageButton"))
end

function StoreMultiPlaceSessionControls.new(ctx)
	local screenGui = ctx.screenGui
	local hotbar = screenGui:FindFirstChild("Hotbar")
	local centerSlot = hotbar and hotbar:FindFirstChild("SlotCenter")
	local hitbox = centerSlot and centerSlot:FindFirstChild("hitbox")
	local face = centerSlot and centerSlot:FindFirstChild("MultiPlaceFace")
	local cancelIcon = face and face:FindFirstChild("CancelIcon")
	local doneIcon = face and face:FindFirstChild("DoneIcon")
	local cancelColor = face and face.BackgroundColor3
	local counterSource = ctx.cursorTooltip
		and ctx.cursorTooltip:createSource({ priority = ctx.cursorTooltip.Priority.Counter })
	local deviceType = SettingsConfig.GetDeviceType(
		UserInputService.TouchEnabled,
		UserInputService.MouseEnabled,
		RunService:IsStudio() and UserInputService.PreferredInput == Enum.PreferredInput.Touch
	)
	local isDesktop = deviceType == SettingsConfig.DeviceType.PC
	local tooltipRegistration = nil

	local function placementSessionActive()
		return isDesktop
			and screenGui:GetAttribute(Attrs.PlacementActive) == true
	end

	local function multiPlaceSessionActive()
		return placementSessionActive()
			and screenGui:GetAttribute(Attrs.MultiPlaceSessionActive) == true
	end

	local function classicSessionActive()
		return placementSessionActive() and screenGui:GetAttribute(Attrs.PlacementControlsEnabled) ~= true
	end

	local function refresh()
		local active = multiPlaceSessionActive()
		if counterSource then
			if active then
				local count = screenGui:GetAttribute(Attrs.MultiPlaceSessionCount)
				count = type(count) == "number" and math.max(0, math.floor(count)) or 0
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
		if face and cancelColor then
			face.BackgroundColor3 = cancelColor
		end
		if isImage(cancelIcon) then
			cancelIcon.Visible = true
			cancelIcon.ImageTransparency = 0
		end
		if isImage(doneIcon) then
			doneIcon.Visible = false
		end
		if tooltipRegistration then
			tooltipRegistration:refresh()
		end
	end

	if hitbox and hitbox:IsA("GuiButton") then
		if ctx.cursorTooltip then
			tooltipRegistration = ctx.cursorTooltip:registerGui(hitbox, {
				trigger = ctx.cursorTooltip.Trigger.Hover,
				getContent = function()
					if
						UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse
						or not classicSessionActive()
					then
						return nil
					end
					return CursorTooltipTuning.getHint("PlacementCancel", false)
				end,
			})
		end
		hitbox.Activated:Connect(function()
			if classicSessionActive() then
				Net.fireServer(Net.Names.PlacementControlUsed, "Cancel", "Screen")
				ctx.placement.cancel()
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

	refresh()
	return {}
end

return StoreMultiPlaceSessionControls
