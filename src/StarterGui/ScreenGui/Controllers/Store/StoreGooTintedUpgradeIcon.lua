-- Applies the selected goo skin's authored body color to upgrade icon fill layers.
-- Studio owns icon geometry; this module only changes ImageColor3 at runtime.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GooSkinColor = require(Shared:WaitForChild("GooSkinColor"))

local StoreGooTintedUpgradeIcon = {}
local WHITE = Color3.fromRGB(255, 255, 255)

local function findDirectImage(icon, name)
	local image = icon and icon:FindFirstChild(name)
	if image and (image:IsA("ImageLabel") or image:IsA("ImageButton")) then
		return image
	end
	return nil
end

function StoreGooTintedUpgradeIcon.new(ctx)
	local M = {}

	function M.apply(row, config)
		if not (row and config and config.IconUsesSelectedGooColor == true) then
			return
		end

		local icon = row:FindFirstChild("Icon", true)
		local slimeIcon = findDirectImage(icon, "IconFill")
		local cursorIcon = findDirectImage(icon, "IconOutline")
		if slimeIcon then
			slimeIcon.ImageColor3 = GooSkinColor.getSelectedBodyColor(ctx.player)
		end
		if cursorIcon then
			cursorIcon.ImageColor3 = WHITE
		end
	end

	function M.observe(callback)
		return ctx.player:GetAttributeChangedSignal(ctx.Attrs.SelectedGooSkinId):Connect(callback)
	end

	return M
end

return StoreGooTintedUpgradeIcon
