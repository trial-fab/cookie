-- StoreUpgradeIconLayout: applies the two approved non-default upgrade icon
-- layouts to existing Studio-authored Icon instances. All other upgrade rows keep
-- their authored presentation without redundant runtime overrides.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("UpgradeIconConfig"))

local StoreUpgradeIconLayout = {}

local function findIcon(row)
	local icon = row and row:FindFirstChild("Icon", true)
	if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
		return icon
	end
	return nil
end

function StoreUpgradeIconLayout.new(_ctx)
	local function apply(row, upgradeId)
		local layout = Config.Layouts[upgradeId]
		local icon = layout and findIcon(row) or nil
		if not icon then
			return
		end

		icon.Position = UDim2.fromScale(layout.Position.X, layout.Position.Y)
		icon.AnchorPoint = layout.Anchor
		icon.Size = UDim2.fromOffset(layout.Size.X, layout.Size.Y)
		icon.ImageColor3 = layout.Color
	end

	return {
		apply = apply,
	}
end

return StoreUpgradeIconLayout
