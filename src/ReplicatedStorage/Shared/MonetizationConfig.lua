-- MonetizationConfig: data-only catalog for the StoreBottom Robux tab.
--
-- Items are grouped into ordered sections (Boosts / Packs / Passes) that the Robux tab
-- renders as side-by-side sections in the horizontal store strip. Each item carries a
-- numeric Price (Robux) used as an immediate fallback until the live MarketplaceService
-- price loads. Permanent paid goo skins live under Passes for storefront simplicity even
-- though their eventual durable delivery uses developer-product receipts.
--
-- Server-side receipt grants live in ServerScriptService/Services/MonetizationService.
local StoreRobuxIconConfig = require(script.Parent:WaitForChild("StoreRobuxIconConfig"))

local MonetizationConfig = {}

-- Ordered section definitions. GetSections() returns these in Order, each populated with
-- its visible items; empty sections are omitted so the strip never shows a bare header.
MonetizationConfig.Sections = {
	{ Id = "Boosts", Title = "BOOSTS", Order = 10 },
	{ Id = "Packs", Title = "PACKS", Order = 20 },
	{ Id = "Passes", Title = "PASSES", Order = 30 },
}

MonetizationConfig.Items = {
	-- ===== Boosts =====
	{
		Id = "ServerBoost",
		Kind = "DeveloperProduct",
		Category = "Boosts",
		ProductId = 3607454004,
		DisplayName = "Server Boost",
		Description = "Doubles all cookie earnings for everyone in this server for 5 minutes. Additional purchases add 5 minutes.",
		Price = 50,
		PriceText = "R$ 50",
		Icon = "rbxassetid://110573372829446",
		Enabled = true,
		LayoutOrder = 10,
	},

	-- ===== Packs =====
	{
		Id = "StarterPack",
		Kind = "DeveloperProduct",
		Category = "Packs",
		ProductId = nil,
		DisplayName = StoreRobuxIconConfig.StarterPackDisplayName,
		Description = "One-time early cookies and an exclusive goo skin.",
		Price = 199,
		PriceText = "R$ 199",
		Icon = StoreRobuxIconConfig.StarterPackImage,
		Enabled = false,
		StoreVisible = false,
		LayoutOrder = 10,
	},
	{
		Id = "GemPouch",
		Kind = "DeveloperProduct",
		Category = "Packs",
		ProductId = nil,
		DisplayName = "Gem Pouch",
		Description = "Adds 50 gems to your balance.",
		Price = 80,
		PriceText = "R$ 80",
		Icon = "",
		Enabled = false,
		StoreVisible = false,
		LayoutOrder = 20,
	},
	{
		Id = "GemChest",
		Kind = "DeveloperProduct",
		Category = "Packs",
		ProductId = nil,
		DisplayName = "Gem Chest",
		Description = "Adds 180 gems to your balance.",
		Price = 250,
		PriceText = "R$ 250",
		Icon = "",
		Enabled = false,
		StoreVisible = false,
		LayoutOrder = 30,
	},
	{
		Id = "GemVault",
		Kind = "DeveloperProduct",
		Category = "Packs",
		ProductId = nil,
		DisplayName = "Gem Vault",
		Description = "Adds 650 gems to your balance.",
		Price = 800,
		PriceText = "R$ 800",
		Icon = "",
		Enabled = false,
		StoreVisible = false,
		LayoutOrder = 40,
	},

	-- ===== Passes =====
	{
		Id = "VipPass",
		Kind = "GamePass",
		Category = "Passes",
		ProductId = nil,
		DisplayName = "VIP",
		Description = "Permanent VIP tag, cosmetic flair, and a longer offline earnings cap.",
		Price = 499,
		PriceText = "R$ 499",
		Icon = StoreRobuxIconConfig.VipOutlineImage,
		Enabled = false,
		StoreVisible = false,
		LayoutOrder = 10,
	},
	{
		Id = "NovaGooSkin",
		Kind = "DeveloperProduct",
		Category = "Passes",
		ProductId = nil,
		DisplayName = "Nova Goo",
		Description = "Unlocks Nova Goo with a permanent 2x production bonus. Goo bonuses do not stack. Only your strongest applies.",
		Price = 400,
		PriceText = "R$ 400",
		Icon = "",
		Enabled = false,
		StoreVisible = false,
		LayoutOrder = 20,
	},
	{
		Id = "QuasarGooSkin",
		Kind = "DeveloperProduct",
		Category = "Passes",
		ProductId = nil,
		DisplayName = "Quasar Goo",
		Description = "Unlocks Quasar Goo with a permanent 2.25x production bonus. Goo bonuses do not stack. Only your strongest applies.",
		Price = 800,
		PriceText = "R$ 800",
		Icon = "",
		Enabled = false,
		StoreVisible = false,
		LayoutOrder = 30,
	},
}

local function sortByLayoutOrder(left, right)
	local leftOrder = left.LayoutOrder or 0
	local rightOrder = right.LayoutOrder or 0
	if leftOrder == rightOrder then
		return (left.DisplayName or left.Id or "") < (right.DisplayName or right.Id or "")
	end

	return leftOrder < rightOrder
end

function MonetizationConfig.GetVisibleItems(includeUnshipped)
	local items = {}
	for _, item in ipairs(MonetizationConfig.Items) do
		-- Studio may preview the complete greenlit catalog for card-art authoring. Published
		-- servers fail closed so an unfinished product never becomes a player-facing "Soon" card.
		local isLive = item.StoreVisible ~= false and item.Enabled == true and item.ProductId ~= nil
		if includeUnshipped == true or isLive then
			table.insert(items, item)
		end
	end

	table.sort(items, sortByLayoutOrder)

	return items
end

-- Returns ordered sections, each as { Id, Title, Order, Items = { ... } }, populated with
-- the visible items whose Category matches. Sections with no visible items are omitted.
function MonetizationConfig.GetSections(includeUnshipped)
	local itemsBySection = {}
	for _, item in ipairs(MonetizationConfig.GetVisibleItems(includeUnshipped)) do
		local category = item.Category or "Boosts"
		local bucket = itemsBySection[category]
		if not bucket then
			bucket = {}
			itemsBySection[category] = bucket
		end
		table.insert(bucket, item)
	end

	local sections = {}
	for _, section in ipairs(MonetizationConfig.Sections) do
		local bucket = itemsBySection[section.Id]
		if bucket and #bucket > 0 then
			table.sort(bucket, sortByLayoutOrder)
			table.insert(sections, {
				Id = section.Id,
				Title = section.Title,
				Order = section.Order,
				Items = bucket,
			})
		end
	end

	table.sort(sections, function(left, right)
		return (left.Order or 0) < (right.Order or 0)
	end)

	return sections
end

return MonetizationConfig
