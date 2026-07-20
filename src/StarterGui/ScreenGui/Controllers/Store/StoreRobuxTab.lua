-- StoreRobuxTab: renders the StoreBottom Robux tab from Shared/MonetizationConfig.
--
-- Cards are grouped into ordered sections (Boosts / Packs / Passes). Each section's title is
-- shown over the first card of the section; cards within a section sit side-by-side and the
-- whole strip scrolls horizontally. Prices use a Studio-authored RobuxIcon ImageLabel beside a
-- bare number (PriceAmount), matching the cookie/GC currency-icon convention; the live price is
-- fetched once per product via MarketplaceService and cached. The gift button is present but
-- inert until the gifting phase lands.
--
-- This module only binds to Studio-authored UI. StoreController passes TemplateRobuxProduct
-- when present, or the old TemplateGearGiver as a temporary shell fallback. The render path
-- degrades gracefully: if the template lacks the new children (SectionTitle / RobuxIcon /
-- PriceAmount / GiftButton) it falls back to the legacy Price/Cost text + buy-button label.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local NumberFormat = require(Shared:WaitForChild("NumberFormat"))

local StoreRobuxTab = {}

function StoreRobuxTab.new(ctx)
	local pageContainer = ctx.pageContainer
	local template = ctx.templateRobuxProduct
	local MonetizationConfig = ctx.MonetizationConfig
	local iconPresenter = require(script.Parent.StoreRobuxIconPresenter).new()

	local M = {}
	local rowsByItemId = {}
	local firstCardBySection = {}
	local priceCache = {}
	local warnedMissingTemplate = false

	local function getItems()
		if MonetizationConfig and MonetizationConfig.GetVisibleItems then
			return MonetizationConfig.GetVisibleItems()
		end

		return {}
	end

	-- Returns ordered sections { Id, Title, Items }. Falls back to a single untitled section
	-- when the config predates GetSections.
	local function getSections()
		if MonetizationConfig and MonetizationConfig.GetSections then
			return MonetizationConfig.GetSections()
		end

		local items = getItems()
		if #items == 0 then
			return {}
		end

		return { { Id = "All", Title = "", Items = items } }
	end

	function M.getVisibleCount()
		return #getItems()
	end

	function M.getSections()
		return getSections()
	end

	function M.getFirstCardOfSection(sectionId)
		return firstCardBySection[sectionId]
	end

	local function setText(row, childName, text)
		local label = row:FindFirstChild(childName, true)
		if label and not (label:IsA("TextLabel") or label:IsA("TextButton")) then
			label = nil
		end

		if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
			label.Text = text or ""
		end
	end

	local function setIcon(row, image)
		local icon = row:FindFirstChild("ProductIcon", true) or row:FindFirstChild("Icon", true)
		if not (icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton"))) then
			return
		end

		-- Fall back to the dev placeholder ("?" image) when the item has no real icon yet.
		local resolved = (image ~= nil and image ~= "") and image or ctx.placeholderIcon
		icon.Image = resolved or ""
		icon.Visible = resolved ~= nil and resolved ~= ""
	end

	-- Shows the section title on the first card of a section, hides it on the rest.
	local function setSectionTitle(row, title)
		local label = row:FindFirstChild("SectionTitle", true)
		if not (label and label:IsA("GuiObject")) then
			return
		end

		if label:IsA("TextLabel") or label:IsA("TextButton") then
			label.Text = title or ""
		end
		label.Visible = title ~= nil
	end

	-- Fetches the live Robux price once per product, caches it, and applies via callback.
	local function fetchLivePrice(item, apply)
		if not item.ProductId then
			return
		end

		local cached = priceCache[item.ProductId]
		if cached ~= nil then
			apply(cached)
			return
		end

		task.spawn(function()
			local infoType = item.Kind == "GamePass" and Enum.InfoType.GamePass or Enum.InfoType.Product
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(item.ProductId, infoType)
			end)
			if ok and info and info.PriceInRobux then
				priceCache[item.ProductId] = info.PriceInRobux
				apply(info.PriceInRobux)
			end
		end)
	end

	-- Drives the RobuxIcon + bare-number price. Returns true when the new price UI exists, so the
	-- caller can skip the legacy Price/Cost text fallback.
	local function updatePrice(row, item)
		local amount = row:FindFirstChild("PriceAmount", true)
		if not (amount and (amount:IsA("TextLabel") or amount:IsA("TextButton"))) then
			return false
		end

		local robuxIcon = row:FindFirstChild("RobuxIcon", true)

		if item.Enabled ~= true then
			amount.Text = "Soon"
			if robuxIcon and robuxIcon:IsA("GuiObject") then
				robuxIcon.Visible = false
			end
			return true
		end

		if robuxIcon and robuxIcon:IsA("GuiObject") then
			robuxIcon.Visible = true
		end

		local immediate = priceCache[item.ProductId] or item.Price
		amount.Text = immediate and NumberFormat.exact(immediate) or "…"

		fetchLivePrice(item, function(price)
			if amount and amount.Parent then
				amount.Text = NumberFormat.exact(price)
			end
		end)

		return true
	end

	local function resolveButton(row)
		local button = row:FindFirstChild("BuyButton", true) or row:FindFirstChild("Catch", true)
		if button and (button:IsA("TextButton") or button:IsA("ImageButton")) then
			return button
		end

		return nil
	end

	local function updateButton(button, item, hasPriceUI)
		if not button then
			return
		end

		button.AutoButtonColor = item.Enabled == true
		button.Active = true
		if button:IsA("TextButton") then
			-- When the icon+number price UI is present the button is just a container, so clear
			-- its own text to avoid double-drawing the price behind the children.
			button.Text = hasPriceUI and "" or (item.PriceText or "Soon")
		end
	end

	-- Gap (px) between the BuyButton and the GiftButton when gifting is shown. Adjust freely.
	local GIFT_BUTTON_PADDING = 2

	-- Shows/hides the gift button and, when shown, shrinks the BuyButton by the gift's width
	-- plus GIFT_BUTTON_PADDING so the two tile cleanly with no overlap (BuyButton is
	-- left-anchored inside ActionRow, GiftButton right-anchored).
	local function updateActionLayout(row, item)
		local giftVisible = item.Giftable == true

		local gift = row:FindFirstChild("GiftButton", true)
		if gift and gift:IsA("GuiObject") then
			gift.Visible = giftVisible
		end

		local buy = resolveButton(row)
		if buy and buy:IsA("GuiObject") then
			local reserved = 0
			if giftVisible and gift and gift:IsA("GuiObject") then
				reserved = gift.Size.X.Offset + GIFT_BUTTON_PADDING
			end
			buy.Size = UDim2.new(1, -reserved, buy.Size.Y.Scale, buy.Size.Y.Offset)
		end
	end

	local function hideProgressChrome(row)
		local affordBar = row:FindFirstChild("AffordBar", true)
		if affordBar and affordBar:IsA("GuiObject") then
			affordBar.Visible = false
		end
	end

	local function updateRow(row, item)
		setText(row, "ProductName", item.DisplayName or item.Id or "Robux Item")
		setText(row, "UpgradeName", item.DisplayName or item.Id or "Robux Item")
		setText(row, "Description", item.Description or "")
		setIcon(row, item.Icon)
		iconPresenter.bind(row, item)
		hideProgressChrome(row)
		updateActionLayout(row, item)

		local hasPriceUI = updatePrice(row, item)
		if not hasPriceUI then
			setText(row, "Price", item.PriceText or "Coming Soon")
			setText(row, "Cost", item.PriceText or "Coming Soon")
		end

		updateButton(resolveButton(row), item, hasPriceUI)
	end

	local function promptPurchase(item)
		local localPlayer = Players.LocalPlayer
		local ok, err = pcall(function()
			if item.Kind == "GamePass" then
				MarketplaceService:PromptGamePassPurchase(localPlayer, item.ProductId)
			else
				MarketplaceService:PromptProductPurchase(localPlayer, item.ProductId)
			end
		end)

		if not ok and ctx.showStatus then
			ctx.showStatus("Could not open the purchase prompt.")
			warn("Robux purchase prompt failed for " .. tostring(item.Id) .. ": " .. tostring(err))
		end
	end

	local function createRow(item, key)
		if not template then
			return nil
		end

		local row = template:Clone()
		row.Name = "Robux_" .. tostring(item.Id or key)
		row.Visible = false
		row:SetAttribute("GeneratedByStoreController", true)
		row:SetAttribute("StoreTemplate", nil)
		row.Parent = pageContainer

		local button = resolveButton(row)
		if button then
			button.MouseButton1Click:Connect(function()
				if item.Enabled == true and item.ProductId then
					promptPurchase(item)
					return
				end

				if ctx.showStatus then
					ctx.showStatus((item.DisplayName or "This item") .. " is coming soon.")
				end
			end)
		end

		-- Gift button is inert until the gifting phase lands.
		local gift = row:FindFirstChild("GiftButton", true)
		if gift and (gift:IsA("ImageButton") or gift:IsA("TextButton")) then
			gift.AutoButtonColor = false
			gift.MouseButton1Click:Connect(function()
				if ctx.showStatus then
					ctx.showStatus("Gifting coming soon!")
				end
			end)
		end

		rowsByItemId[key] = row
		return row
	end

	function M.render(active)
		iconPresenter.setActive(active)

		if template and template:IsA("GuiObject") then
			template.Visible = false
		end

		if not active then
			for _, row in pairs(rowsByItemId) do
				if row:IsA("GuiObject") then
					row.Visible = false
				end
			end
			return
		end

		if not template then
			if not warnedMissingTemplate then
				warn(
					"Robux tab is missing StoreBottom.TemplateRobuxProduct; create it in Studio to show monetization cards."
				)
				warnedMissingTemplate = true
			end
			if ctx.showStatus then
				ctx.showStatus("Robux shop coming soon.")
			end
			return
		end

		local visibleById = {}
		table.clear(firstCardBySection)

		for sectionIndex, section in ipairs(getSections()) do
			for itemIndex, item in ipairs(section.Items) do
				local key = item.Id or (section.Id .. "_" .. itemIndex)
				visibleById[key] = true

				local row = rowsByItemId[key] or createRow(item, key)
				if row and row:IsA("GuiObject") then
					-- sectionIndex*100 keeps sections contiguous and ordered in the horizontal
					-- UIListLayout; itemIndex orders cards within a section.
					row.LayoutOrder = sectionIndex * 100 + itemIndex
					row.Visible = true

					local isFirstInSection = itemIndex == 1
					setSectionTitle(row, isFirstInSection and section.Title or nil)
					if isFirstInSection then
						firstCardBySection[section.Id] = row
					end

					updateRow(row, item)
				end
			end
		end

		for key, row in pairs(rowsByItemId) do
			if row:IsA("GuiObject") and not visibleById[key] then
				row.Visible = false
			end
		end
	end

	return M
end

return StoreRobuxTab
