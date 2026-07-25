-- BoostShopConfig — the gem-priced field charges sold at the central Hub stall
-- (docs/boost-shop-design.md §1 + decisions 3/6: 40 gems, +50%, 5 min, stack cap 1 per type).
--
-- One definition shared by the world prompts, the purchase window, and the future server
-- purchase/inventory service, so a price or duration is never restated in two places.
--
-- The Studio names below are how the client finds the authored assets. `StallName` is looked
-- up recursively in Workspace, so the stall keeps working whether it stays inside
-- `BoostShopDraft` or is promoted/moved elsewhere on the Hub pad.

local Attrs = require(script.Parent:WaitForChild("Attrs"))

local BoostShopConfig = {}

BoostShopConfig.StallName = "BoostStall"
BoostShopConfig.PromptName = "ViewPrompt"
BoostShopConfig.HighlightName = "SelectHighlight"
BoostShopConfig.ModalName = "BoostPurchaseConfirm"

-- Cosmetic ceilings for the window's Duration/Strength bars (§7). Purely presentational:
-- a 5-minute / +50% charge reads as a half-filled bar against these references.
BoostShopConfig.BarReference = {
	DurationSeconds = 600,
	StrengthPercent = 100,
}

BoostShopConfig.Items = {
	PowerField = {
		Id = "PowerField",
		CanisterName = "PowerCanister",
		DisplayName = "Power Field",
		Description = "Drops a field that boosts nearby building production for 5 minutes.",
		PriceGems = 40,
		DurationSeconds = 300,
		StrengthPercent = 50,
		StackCap = 1,
		-- Server-owned inventory count. Absent until the purchase service ships, which reads
		-- as 0 owned (the window's happy path).
		OwnedAttribute = Attrs.PowerFieldCharges,
	},
	SpeedField = {
		Id = "SpeedField",
		CanisterName = "SpeedCanister",
		DisplayName = "Speed Field",
		Description = "Drops a field that speeds up nearby building payouts for 3 minutes.",
		PriceGems = 40,
		-- Shorter than Power on purpose: Speed covers a much wider radius for the same +50%, so
		-- duration is what keeps the two balanced (docs/boost-shop-design.md §12.2).
		DurationSeconds = 180,
		StrengthPercent = 50,
		StackCap = 1,
		OwnedAttribute = Attrs.SpeedFieldCharges,
	},
}

-- Counter order, left to right (PowerCanister x=-4, SpeedCanister x=+4).
BoostShopConfig.Order = { "PowerField", "SpeedField" }

-- The item whose canister model carries `name`, or nil for any other model.
function BoostShopConfig.byCanisterName(name)
	for _, id in ipairs(BoostShopConfig.Order) do
		local item = BoostShopConfig.Items[id]
		if item.CanisterName == name then
			return item
		end
	end
	return nil
end

return BoostShopConfig
