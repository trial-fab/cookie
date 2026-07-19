-- Applies the selected goo skin's authored body color to upgrade icon fill layers.
-- Studio owns icon geometry; this module only changes ImageColor3 at runtime.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GooSkinAssets = require(Shared:WaitForChild("GooSkinAssets"))

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

	local function getSelectedBodyColor()
		local model = GooSkinAssets.Resolve(ctx.player:GetAttribute(ctx.Attrs.SelectedGooSkinId))
		local color = model and model:GetAttribute("DefaultBodyColor")
		return typeof(color) == "Color3" and color or WHITE
	end

	function M.apply(row, config)
		if not (row and config and config.IconUsesSelectedGooColor == true) then
			return
		end

		local icon = row:FindFirstChild("Icon", true)
		local slimeIcon = findDirectImage(icon, "IconFill")
		local cursorIcon = findDirectImage(icon, "IconOutline")
		if slimeIcon then
			slimeIcon.ImageColor3 = getSelectedBodyColor()
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
