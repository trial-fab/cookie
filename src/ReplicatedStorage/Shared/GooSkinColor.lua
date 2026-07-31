-- Shared selected-goo color lookup for UI that reflects the player's active skin.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(script.Parent.Attrs)
local GooSkinAssets = require(script.Parent.GooSkinAssets)

local GooSkinColor = {}
local WHITE = Color3.fromRGB(255, 255, 255)

function GooSkinColor.getSelectedBodyColor(player)
	local skinId = player and player:GetAttribute(Attrs.SelectedGooSkinId)
	local model = GooSkinAssets.Resolve(skinId)
	local color = model and model:GetAttribute("DefaultBodyColor")
	return typeof(color) == "Color3" and color or WHITE
end

return GooSkinColor
