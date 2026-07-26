-- StorePlacementControls: binds the existing Studio-authored Hotbar slot hitboxes to the
-- placement actions. HotbarPlacementMode owns the visual face/geometry swap; this module owns
-- action routing and the visible disabled state of Confirm.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local CursorTooltipTuning = require(Shared:WaitForChild("CursorTooltipTuning"))
local Net = require(Shared:WaitForChild("Net"))
local PlacementControls = require(Shared:WaitForChild("PlacementControls"))

local StorePlacementControls = {}

local function findHitbox(hotbar, slotName)
	local slot = hotbar and hotbar:FindFirstChild(slotName)
	local hitbox = slot and slot:FindFirstChild("hitbox")
	return hitbox and hitbox:IsA("GuiButton") and hitbox or nil
end

function StorePlacementControls.new(ctx, placement)
	local screenGui = ctx.screenGui
	local hotbar = screenGui:FindFirstChild("Hotbar")
	local cancelHitbox = findHitbox(hotbar, "SlotLeft")
	local rotateHitbox = findHitbox(hotbar, "SlotCenter")
	local confirmHitbox = findHitbox(hotbar, "SlotRight")
	local confirmSlot = hotbar and hotbar:FindFirstChild("SlotRight")
	local confirmFace = confirmSlot and confirmSlot:FindFirstChild("PlacementFace")
	local disabledOverlay = confirmFace and confirmFace:FindFirstChild("DisabledOverlay")
	local confirmValid = false
	local purchaseInFlight = false
	local tooltipRegistrations = {}

	-- A boost field runs through the same placement session and the same authored faces, so the
	-- BUILDING actions must go inert while it owns them. Without this the Cancel/Rotate/Confirm
	-- taps reach StorePlacement with no session of its own, which is what used to wedge the hotbar.
	local function isActive()
		return screenGui:GetAttribute(Attrs.PlacementActive) == true
			and PlacementControls.screenControlsActive(screenGui)
			and screenGui:GetAttribute(Attrs.BoostFieldPlacementActive) ~= true
	end

	local function refreshConfirm()
		local active = isActive()
		local enabled = active and confirmValid and not purchaseInFlight
		if active then
			if cancelHitbox then
				cancelHitbox.Active = true
				cancelHitbox.Interactable = true
			end
			if rotateHitbox then
				rotateHitbox.Active = true
				rotateHitbox.Interactable = true
			end
		end
		if disabledOverlay and disabledOverlay:IsA("GuiObject") then
			disabledOverlay.Visible = active and not enabled
		end
		if confirmHitbox and active then
			confirmHitbox.Active = enabled
			confirmHitbox.Interactable = enabled
		end
		-- A controller reaches these faces only through the engine's selected object. Park it on
		-- Confirm while that is a legal action, fall back to Cancel while it is not (an overlapping
		-- spot), and hand the selection back when the session ends.
		if active then
			PlacementControls.setGamepadFocus(enabled and confirmHitbox or cancelHitbox)
		else
			PlacementControls.clearGamepadFocus(confirmHitbox)
			PlacementControls.clearGamepadFocus(cancelHitbox)
		end
		for _, registration in ipairs(tooltipRegistrations) do
			registration:refresh()
		end
	end

	local function registerHint(hitbox, target)
		if not (ctx.cursorTooltip and hitbox) then
			return
		end
		local registration = ctx.cursorTooltip:registerGui(hitbox, {
			trigger = ctx.cursorTooltip.Trigger.Hover,
			getContent = function()
				if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse or not isActive() then
					return nil
				end
				return CursorTooltipTuning.getHint(target, false)
			end,
		})
		if registration then
			table.insert(tooltipRegistrations, registration)
		end
	end

	registerHint(cancelHitbox, "PlacementCancel")
	registerHint(rotateHitbox, "PlacementRotate")
	registerHint(confirmHitbox, "PlacementPlace")

	if cancelHitbox then
		cancelHitbox.Activated:Connect(function()
			if isActive() then
				Net.fireServer(Net.Names.PlacementControlUsed, "Cancel", "Screen")
				placement.cancel()
			end
		end)
	end
	if rotateHitbox then
		rotateHitbox.Activated:Connect(function()
			if isActive() then
				Net.fireServer(Net.Names.PlacementControlUsed, "Rotate", "Screen")
				placement.rotate()
			end
		end)
	end
	if confirmHitbox then
		confirmHitbox.Activated:Connect(function()
			if isActive() and confirmValid and not purchaseInFlight then
				Net.fireServer(Net.Names.PlacementControlUsed, "Confirm", "Screen")
				placement.confirm(true)
			end
		end)
	end

	screenGui:GetAttributeChangedSignal(Attrs.PlacementActive):Connect(refreshConfirm)
	PlacementControls.observe(screenGui, refreshConfirm)

	-- B is the console back button everywhere else in this game (Help, Settings, Profile), so a
	-- placement answers it the same way rather than teaching a second convention.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or input.KeyCode ~= Enum.KeyCode.ButtonB or not isActive() then
			return
		end
		Net.fireServer(Net.Names.PlacementControlUsed, "Cancel", "Gamepad")
		placement.cancel()
	end)

	refreshConfirm()

	return {
		reportKeyboard = function(action)
			if screenGui:GetAttribute(Attrs.PlacementActive) == true then
				Net.fireServer(Net.Names.PlacementControlUsed, action, "Keyboard")
			end
		end,
		setConfirmState = function(valid, inFlight)
			confirmValid = valid == true
			purchaseInFlight = inFlight == true
			refreshConfirm()
		end,
	}
end

return StorePlacementControls
