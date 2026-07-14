-- MonetizationConfig: data-only catalog for the StoreBottom Robux tab.
--
-- Items are grouped into ordered sections (Boosts / Packs / Passes) that the Robux tab
-- renders as side-by-side sections in the horizontal store strip. Each item carries a
-- numeric Price (Robux) used as an immediate fallback until the live MarketplaceService
-- price loads, and a Giftable flag for the (later) gifting phase.
--
-- Server-side receipt grants live in ServerScriptService/Services/MonetizationService.
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
		Id = "DoubleCookies",
		Kind = "DeveloperProduct",
		Category = "Boosts",
		ProductId = nil,
		DisplayName = "Double Cookies",
		Description = "Double your own cookie output for 15 minutes.",
		Price = nil,
		PriceText = "Coming Soon",
		Icon = "",
		Giftable = false,
		Enabled = false,
		LayoutOrder = 10,
	},
	{
		Id = "LuckyFrenzy",
		Kind = "DeveloperProduct",
		Category = "Boosts",
		ProductId = nil,
		DisplayName = "Lucky Frenzy",
		Description = "Boosted golden cookie spawns for 10 minutes.",
		Price = nil,
		PriceText = "Coming Soon",
		Icon = "",
		Giftable = false,
		Enabled = false,
		LayoutOrder = 20,
	},
	{
		Id = "ServerBoost",
		Kind = "DeveloperProduct",
		Category = "Boosts",
		ProductId = 3607454004,
		DisplayName = "Server Boost",
		Description = "Multiply all cookie production for the entire server!",
		Price = 50,
		PriceText = "R$ 50",
		Icon = "rbxassetid://110573372829446",
		Giftable = false,
		Enabled = true,
		LayoutOrder = 30,
	},

	-- ===== Packs =====
	{
		Id = "StarterCookiePack",
		Kind = "DeveloperProduct",
		Category = "Packs",
		ProductId = nil,
		DisplayName = "Starter Cookie Pack",
		Description = "A launch boost for the early bakery climb.",
		Price = nil,
		PriceText = "Coming Soon",
		Icon = "",
		Giftable = true,
		Enabled = false,
		LayoutOrder = 10,
	},
	{
		Id = "CookieVault",
		Kind = "DeveloperProduct",
		Category = "Packs",
		ProductId = nil,
		DisplayName = "Cookie Vault",
		Description = "A larger cookie pack for later upgrades.",
		Price = nil,
		PriceText = "Coming Soon",
		Icon = "",
		Giftable = true,
		Enabled = false,
		LayoutOrder = 20,
	},
	{
		Id = "CookieGalaxy",
		Kind = "DeveloperProduct",
		Category = "Packs",
		ProductId = nil,
		DisplayName = "Cookie Galaxy",
		Description = "A massive cookie stockpile to skip ahead.",
		Price = nil,
		PriceText = "Coming Soon",
		Icon = "",
		Giftable = true,
		Enabled = false,
		LayoutOrder = 30,
	},

	-- ===== Passes =====
	{
		Id = "VipPass",
		Kind = "GamePass",
		Category = "Passes",
		ProductId = nil,
		DisplayName = "VIP",
		Description = "Permanent +25% cookies and a VIP tag.",
		Price = nil,
		PriceText = "Coming Soon",
		Icon = "",
		Giftable = true,
		Enabled = false,
		LayoutOrder = 10,
	},
	{
		Id = "AutoClickerPass",
		Kind = "GamePass",
		Category = "Passes",
		ProductId = nil,
		DisplayName = "Auto-Clicker",
		Description = "Clicks for you automatically, forever.",
		Price = nil,
		PriceText = "Coming Soon",
		Icon = "",
		Giftable = true,
		Enabled = false,
		LayoutOrder = 20,
	},
	{
		Id = "DoubleForever",
		Kind = "GamePass",
		Category = "Passes",
		ProductId = nil,
		DisplayName = "2x Cookies Forever",
		Description = "Permanently double all your cookie production.",
		Price = nil,
		PriceText = "Coming Soon",
		Icon = "",
		Giftable = true,
		Enabled = false,
		LayoutOrder = 30,
	},
	{
		-- Dormant until a real game-pass ID, price, and store presentation are approved.
		-- Once configured, MonetizationService grants InstantWheelSpinEnabled on join/purchase.
		Id = "InstantWheelSpinPass",
		Kind = "GamePass",
		Category = "Passes",
		ProductId = nil,
		DisplayName = "Instant Wheel Spins",
		Description = "Skip the wheel reel animation after a result is rolled.",
		Price = nil,
		PriceText = "Coming Soon",
		Icon = "",
		Giftable = true,
		Enabled = false,
		StoreVisible = false,
		LayoutOrder = 40,
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

function MonetizationConfig.GetVisibleItems()
	local items = {}
	for _, item in ipairs(MonetizationConfig.Items) do
		if item.StoreVisible ~= false then
			table.insert(items, item)
		end
	end

	table.sort(items, sortByLayoutOrder)

	return items
end

-- Returns ordered sections, each as { Id, Title, Order, Items = { ... } }, populated with
-- the visible items whose Category matches. Sections with no visible items are omitted.
function MonetizationConfig.GetSections()
	local itemsBySection = {}
	for _, item in ipairs(MonetizationConfig.GetVisibleItems()) do
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
