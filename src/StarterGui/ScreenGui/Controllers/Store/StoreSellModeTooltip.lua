-- StoreSellModeTooltip: publishes the Store toolbar's current Build/Sell mode
-- through the shared cursor tooltip. The StoreController remains the sole owner
-- of sellMode; this module only reads that state and refreshes presentation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local CursorTooltipTuning = require(Shared:WaitForChild("CursorTooltipTuning"))

local StoreSellModeTooltip = {}

function StoreSellModeTooltip.new(ctx)
	local button = ctx.sellButton
	if not (button and button:IsA("GuiObject")) or not ctx.cursorTooltip then
		return {}
	end

	local registration = ctx.cursorTooltip:registerGui(button, {
		trigger = ctx.cursorTooltip.Trigger.Hover,
		getContent = function()
			if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
				return nil
			end
			return CursorTooltipTuning.getHint("StoreBuildSell", ctx.isSellMode())
		end,
	})

	ctx.screenGui:GetAttributeChangedSignal(Attrs.SellMode):Connect(function()
		registration:refresh()
	end)

	return {
		refresh = function()
			registration:refresh()
		end,
	}
end

return StoreSellModeTooltip
