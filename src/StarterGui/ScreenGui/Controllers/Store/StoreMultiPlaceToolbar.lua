-- StoreMultiPlaceToolbar: binds the persistent StoreBottom toolbar shortcut for
-- the existing Multi-Place preference. The Studio-authored control owns its
-- appearance; this module owns entitlement visibility, input, tooltip content,
-- and synchronization with the Upgrades-row toggle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local CursorTooltipTuning = require(Shared:WaitForChild("CursorTooltipTuning"))

local StoreMultiPlaceIconAnim = require(script.Parent:WaitForChild("StoreMultiPlaceIconAnim"))

local StoreMultiPlaceToolbar = {}

function StoreMultiPlaceToolbar.new(ctx)
	local root = ctx.toolBar and ctx.toolBar:FindFirstChild("MultiPlaceButton")
	if not (root and root:IsA("GuiObject")) then
		warn("[StoreMultiPlaceToolbar] StoreBottom.ToolBar.MultiPlaceButton not found; shortcut disabled")
		return {
			refresh = function() end,
		}
	end

	local hitbox = root:FindFirstChild("Hitbox")
	if not (hitbox and hitbox:IsA("GuiButton")) then
		warn("[StoreMultiPlaceToolbar] MultiPlaceButton.Hitbox not found; shortcut input disabled")
		hitbox = nil
	end

	-- Use a second instance of the exact same animator that owns the Upgrades-row
	-- icon. Each instance tracks one target, while both read the same preference.
	local iconAnimator = StoreMultiPlaceIconAnim.new(ctx)
	local tooltipRegistration = nil

	local function refresh()
		local owned = ctx.multiPlace.isOwned()
		local active = owned and ctx.multiPlace.isEnabled()

		-- Locked players never see or interact with the shortcut, even if an old
		-- saved preference happens to be true.
		root.Visible = owned
		root.Active = owned
		if hitbox then
			hitbox.Active = owned
		end

		iconAnimator.updateRow(root, active)
		if tooltipRegistration then
			tooltipRegistration:refresh()
		end
	end

	if hitbox then
		if ctx.cursorTooltip then
			tooltipRegistration = ctx.cursorTooltip:registerGui(hitbox, {
				trigger = ctx.cursorTooltip.Trigger.Hover,
				getContent = function()
					if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
						return nil
					end
					return CursorTooltipTuning.getHint("MultiPlaceToolbar", ctx.multiPlace.isEnabled())
				end,
			})
		end

		hitbox.Activated:Connect(function()
			if not ctx.multiPlace.isOwned() then
				refresh()
				return
			end

			ctx.multiPlace.setEnabled(not ctx.multiPlace.isEnabled())
			refresh()
		end)
	end

	ctx.screenGui:GetAttributeChangedSignal(Attrs.MultiPlaceEnabled):Connect(refresh)
	refresh()

	return {
		refresh = refresh,
	}
end

return StoreMultiPlaceToolbar
