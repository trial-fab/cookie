local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("StoreController must be inside a ScreenGui")
	return
end

local shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(shared:WaitForChild("Net"))
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local StoreShell = require(shared:WaitForChild("StoreShell"))
local Names = Net.Names

local store = StoreShell.getActive(screenGui)
if not store then
	warn("StoreController disabled: no store shell (StoreBottom/StoreSide) was found")
	return
end

local buildingPreviews = ReplicatedStorage:WaitForChild("BuildingPreviews")
-- Purchase/Sell are request/response (RemoteFunction): the result returns to the caller, so
-- there is no shared result event to listen on. The fire sites here and in StorePlacement call
-- these helpers (also exposed on ctx); they're forward-declared because their bodies depend on
-- showStatus/updateRow, defined further down.
local invokePurchase, invokeSell, invokeSellAll
local UpgradeConfig = require(shared:WaitForChild("UpgradeConfig"))
local MonetizationConfig = require(shared:WaitForChild("MonetizationConfig"))
local PvpConfig = require(shared:WaitForChild("PvpConfig"))
local NumberFormat = require(shared:WaitForChild("NumberFormat"))
local ProductionFormula = require(shared:WaitForChild("ProductionFormula"))
local GridPlacement = require(shared:WaitForChild("GridPlacement"))
local UiMotion = require(shared:WaitForChild("UiMotion"))
local upgradeCountData = player:WaitForChild("UpgradeCountData")
local cookiesValue = player:WaitForChild("leaderstats"):WaitForChild("Cookies")

local pageContainer = store:FindFirstChild("PageTemplate") or store:FindFirstChild("Frame") or store

local templateBuilding = store:FindFirstChild("Template", true) or store:WaitForChild("Template")
local templateUpgrade = store:FindFirstChild("TemplateUpgrade", true) or store:WaitForChild("TemplateUpgrade")
local templateGearGiver = store:FindFirstChild("TemplateGearGiver", true)
local templateRobuxProduct = store:FindFirstChild("TemplateRobuxProduct", true) or templateGearGiver

local function findDescendantByNames(parent, names)
	for _, name in ipairs(names) do
		local descendant = parent:FindFirstChild(name, true)
		if descendant then
			return descendant
		end
	end

	return nil
end

local toolBar = store:FindFirstChild("ToolBar")
local sellButtonRoot = toolBar and toolBar:FindFirstChild("SellButton", true)
local sellButton = sellButtonRoot
if sellButtonRoot and not sellButtonRoot:IsA("GuiButton") then
	sellButton = sellButtonRoot:FindFirstChild("buildImage", true)
		or sellButtonRoot:FindFirstChildWhichIsA("GuiButton", true)
end
local categoryButton = findDescendantByNames(store, { "BuildingButton", "CategoryButton", "MoveUpgrade" })
local statusLabel = findDescendantByNames(store, { "Status", "Message", "Result" })
local tabBar = store:FindFirstChild("TabBar") or store:WaitForChild("TabBar", 2)
local tabButtons = {
	Building = tabBar and tabBar:FindFirstChild("BuildingsTab"),
	Robux = tabBar and (tabBar:FindFirstChild("RobuxTab") or tabBar:FindFirstChild("GearTab")),
	Upgrade = tabBar and tabBar:FindFirstChild("UpgradesTab"),
}
if tabButtons.Robux and tabButtons.Robux:IsA("TextButton") then
	tabButtons.Robux.Text = "Robux"
end

-- Optional subcategory chips. These are Studio-authored; code only binds/toggles them.
local robuxSubTabs = store:FindFirstChild("RobuxSubTabs")
local robuxSubTabButtons = {
	Boosts = robuxSubTabs and robuxSubTabs:FindFirstChild("BoostsTab"),
	Packs = robuxSubTabs and robuxSubTabs:FindFirstChild("PacksTab"),
	Passes = robuxSubTabs and robuxSubTabs:FindFirstChild("PassesTab"),
}
local upgradeSubTabs = store:FindFirstChild("UpgradeSubTabs") or store:FindFirstChild("UpgradesSubTabs")
local upgradeSubTabButtons = {
	BuildingUpgrades = upgradeSubTabs and findDescendantByNames(upgradeSubTabs, {
		"BuildingUpgradesTab",
		"BuildingUpgradeTab",
		"BuildingTab",
	}),
	PlayerUpgrades = upgradeSubTabs and findDescendantByNames(upgradeSubTabs, {
		"PlayerUpgradesTab",
		"PlayerUpgradeTab",
		"PlayerTab",
		"GeneralUpgradesTab",
		"UtilityUpgradesTab",
	}),
}

local ACTIVE_TAB_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local INACTIVE_TAB_TEXT_COLOR = Color3.fromRGB(140, 141, 145)
-- Tab background: all three tabs (Buildings / Upgrades / Robux) share one translucent blue
-- tint by default; the active tab goes fully transparent so the page-template background
-- (RGB 6,7,9 @ 0.15) reads straight through it, merging the active tab into the content area.
local TAB_BG_COLOR = Color3.fromRGB(119, 139, 179)
local INACTIVE_TAB_BG_TRANSPARENCY = 0.9
local ACTIVE_TAB_BG_TRANSPARENCY = 1
local UPGRADE_TAB_COLOR = Color3.fromRGB(209, 70, 0)
local ROBUX_TAB_COLOR = Color3.fromRGB(5, 142, 109)
local SECTION_TAB_ACTIVE_TRANSPARENCY = 0.9
local SECTION_TAB_INACTIVE_TRANSPARENCY = 1
local SELL_ICON_HOVER_ROTATION = 42
-- The upright hammer asset was shifted upward in the source image to keep its handle in
-- frame. Move that overlay back down while rotating toward the crossed-tools pose so its
-- hammer aligns with the one baked into the build icon before the final crossfade.
local SELL_ICON_DIAGONAL_X_OFFSET = -1
local SELL_ICON_DIAGONAL_Y_OFFSET = 1
local SELL_ICON_ACTIVE_COLOR = Color3.fromRGB(255, 75, 75)
local SELL_ICON_DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)
local SELL_ICON_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SELL_TAB_LAYOUT_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Dev-time placeholder ("?" image) shown in any card preview slot that has no real asset yet,
-- so the final card layout is visible before art exists. Empty out to disable.
local PREVIEW_PLACEHOLDER_ICON = "rbxassetid://82894134527428"
if tabButtons.Building and tabButtons.Building:IsA("TextButton") then
	INACTIVE_TAB_TEXT_COLOR = tabButtons.Building.TextColor3
end

local function setTabActive(button, isActive, activeColor)
	if not button or not button:IsA("GuiButton") then
		return
	end

	button:SetAttribute(Attrs.Active, isActive)
	button.BackgroundColor3 = activeColor or TAB_BG_COLOR
	button.BackgroundTransparency = activeColor
			and (isActive and SECTION_TAB_ACTIVE_TRANSPARENCY or SECTION_TAB_INACTIVE_TRANSPARENCY)
		or (isActive and ACTIVE_TAB_BG_TRANSPARENCY or INACTIVE_TAB_BG_TRANSPARENCY)

	local activeFrame = button:FindFirstChild("Active") or button:FindFirstChild("ActiveLine")
	if activeFrame and activeFrame:IsA("GuiObject") then
		if activeColor then
			activeFrame.BackgroundColor3 = activeColor
		end
		activeFrame.Visible = isActive
	end

	if button:IsA("TextButton") then
		button.TextColor3 = isActive and ACTIVE_TAB_TEXT_COLOR or INACTIVE_TAB_TEXT_COLOR
	end
end

local setSellButtonModeVisual = nil
local function setupSellButtonHover()
	if not sellButton or not sellButton:IsA("ImageButton") then
		return
	end

	local hammerImage = sellButton.HoverImage
	if hammerImage == "" then
		return
	end

	-- Roblox's HoverImage swaps the complete raster instantly. Replace that behavior with
	-- a non-interactive overlay so the crossed-tools image can fade while the hammer rotates
	-- from its matching diagonal angle to upright.
	sellButton.HoverImage = ""
	sellButton.AutoButtonColor = false

	local hammerOverlay = sellButton:FindFirstChild("HammerHoverOverlay")
	if not hammerOverlay then
		hammerOverlay = Instance.new("ImageLabel")
		hammerOverlay.Name = "HammerHoverOverlay"
		hammerOverlay.AnchorPoint = Vector2.new(0.5, 0.5)
		hammerOverlay.Position = UDim2.fromScale(0.5, 0.5)
		hammerOverlay.Size = UDim2.fromScale(1, 1)
		hammerOverlay.BackgroundTransparency = 1
		hammerOverlay.BorderSizePixel = 0
		hammerOverlay.ScaleType = sellButton.ScaleType
		hammerOverlay.ImageColor3 = sellButton.ImageColor3
		hammerOverlay.ZIndex = sellButton.ZIndex + 1
		hammerOverlay.Parent = sellButton
	end

	hammerOverlay.Image = hammerImage
	hammerOverlay.ImageTransparency = 1
	hammerOverlay.Rotation = SELL_ICON_HOVER_ROTATION

	local activeTweens = {}
	local transitionToken = 0
	local function cancelActiveTweens()
		transitionToken += 1
		for _, tween in ipairs(activeTweens) do
			tween:Cancel()
		end
		table.clear(activeTweens)
		return transitionToken
	end

	local function showHammer()
		cancelActiveTweens()
		local baseTween = UiMotion.create(sellButton, SELL_ICON_TWEEN_INFO, {
			ImageTransparency = 1,
		})
		local hammerTween = UiMotion.create(hammerOverlay, SELL_ICON_TWEEN_INFO, {
			ImageTransparency = 0,
			ImageColor3 = SELL_ICON_ACTIVE_COLOR,
			Rotation = 0,
			Position = UDim2.fromScale(0.5, 0.5),
		})
		table.insert(activeTweens, baseTween)
		table.insert(activeTweens, hammerTween)
		baseTween:Play()
		hammerTween:Play()
	end

	local function showBuildIcon()
		local token = cancelActiveTweens()

		-- Keep the hammer visible while it returns to the angle used by the crossed-tools
		-- artwork. Only after that rotation finishes do we crossfade the build icon back in.
		sellButton.ImageTransparency = 1
		hammerOverlay.ImageTransparency = 0
		local rotateTween = UiMotion.create(hammerOverlay, SELL_ICON_TWEEN_INFO, {
			Rotation = SELL_ICON_HOVER_ROTATION,
			Position = UDim2.new(0.5, SELL_ICON_DIAGONAL_X_OFFSET, 0.5, SELL_ICON_DIAGONAL_Y_OFFSET),
		})
		table.insert(activeTweens, rotateTween)
		rotateTween:Play()
		rotateTween.Completed:Connect(function(playbackState)
			if token ~= transitionToken or playbackState ~= Enum.PlaybackState.Completed then
				return
			end

			table.clear(activeTweens)
			local baseTween = UiMotion.create(sellButton, SELL_ICON_TWEEN_INFO, {
				ImageTransparency = 0,
			})
			local hammerTween = UiMotion.create(hammerOverlay, SELL_ICON_TWEEN_INFO, {
				ImageTransparency = 1,
				ImageColor3 = SELL_ICON_DEFAULT_COLOR,
			})
			table.insert(activeTweens, baseTween)
			table.insert(activeTweens, hammerTween)
			baseTween:Play()
			hammerTween:Play()
		end)
	end

	local modeVisualInitialized = false
	setSellButtonModeVisual = function(isSellMode, snap)
		if not modeVisualInitialized then
			modeVisualInitialized = true
			snap = true
		end

		if snap then
			cancelActiveTweens()
			sellButton.ImageTransparency = isSellMode and 1 or 0
			hammerOverlay.ImageTransparency = isSellMode and 0 or 1
			hammerOverlay.ImageColor3 = isSellMode and SELL_ICON_ACTIVE_COLOR or SELL_ICON_DEFAULT_COLOR
			hammerOverlay.Rotation = isSellMode and 0 or SELL_ICON_HOVER_ROTATION
			hammerOverlay.Position = isSellMode and UDim2.fromScale(0.5, 0.5)
				or UDim2.new(0.5, SELL_ICON_DIAGONAL_X_OFFSET, 0.5, SELL_ICON_DIAGONAL_Y_OFFSET)
			return
		end

		if isSellMode then
			showHammer()
		else
			showBuildIcon()
		end
	end
end

setupSellButtonHover()

-- Placement state + the control-pad table live in StorePlacement now; the orchestrator
-- keeps only the row registry, ordering, and the sell/category mode flags.
local rowsByUpgradeId = {}
local orderedUpgradeIds = {}
local firstUpgradeRowBySection = {}
local sellMode = false
screenGui:SetAttribute(Attrs.SellMode, sellMode)
local currentCategory = "Building"
local UPGRADE_SECTION_BUILDING = "BuildingUpgrades"
local UPGRADE_SECTION_PLAYER = "PlayerUpgrades"
local UPGRADE_SUBTAB_TITLES = {
	[UPGRADE_SECTION_BUILDING] = "Building",
	[UPGRADE_SECTION_PLAYER] = "Player",
}
local UPGRADE_SECTION_TITLES = {
	[UPGRADE_SECTION_BUILDING] = "BUILDING",
	[UPGRADE_SECTION_PLAYER] = "PLAYER",
}
local UPGRADE_SECTION_ORDER = {
	[UPGRADE_SECTION_BUILDING] = 1,
	[UPGRADE_SECTION_PLAYER] = 2,
}
local CATEGORY_ORDER = { "Building", "Robux", "Upgrade" }
local upgradeNudge = nil
local countBadge = nil
local buildingTab = tabButtons.Building
local buildingTabFullSize = buildingTab and UDim2.new(0, 100, buildingTab.Size.Y.Scale, buildingTab.Size.Y.Offset)
	or nil

-- Robux subtab reveal sizes: authored width is the expanded state; collapse to zero width.
local robuxSubTabsExpandedSize = robuxSubTabs and robuxSubTabs:IsA("GuiObject") and robuxSubTabs.Size or nil
local robuxSubTabsCollapsedSize = robuxSubTabsExpandedSize
		and UDim2.new(0, 0, robuxSubTabsExpandedSize.Y.Scale, robuxSubTabsExpandedSize.Y.Offset)
	or nil
if robuxSubTabs and robuxSubTabsCollapsedSize then
	robuxSubTabs.Size = robuxSubTabsCollapsedSize
	robuxSubTabs.Visible = false
end
local robuxSubTabsTween = nil
local robuxSubTabsTarget = nil

if buildingTab and buildingTab:IsA("TextButton") then
	local staleBuildingsText = buildingTab:FindFirstChild("BuildingsText")
	if staleBuildingsText then
		staleBuildingsText:Destroy()
	end
	buildingTab.Size = buildingTabFullSize
	buildingTab.Text = "Buildings"
end
local baseStoreSize = store:IsA("GuiObject") and store.Size or UDim2.new()
local baseStorePosition = store:IsA("GuiObject") and store.Position or UDim2.new()
local basePageContainerSize = pageContainer:IsA("GuiObject") and pageContainer.Size or UDim2.new()
local storeSizeConstraint = store:FindFirstChildWhichIsA("UISizeConstraint")
local baseStoreMinSize = storeSizeConstraint and storeSizeConstraint.MinSize or nil
local baseStoreMaxSize = storeSizeConstraint and storeSizeConstraint.MaxSize or nil
local storeScale = store:FindFirstChildOfClass("UIScale")
if not storeScale then
	storeScale = Instance.new("UIScale")
	storeScale.Name = "UIScale"
	storeScale.Parent = store
end

-- Shared context handed to every extracted Store module. Holds instance/service refs,
-- read-only getters for cross-module mutable state (sellMode/currentCategory live as
-- orchestrator upvalues), module handles, and late-bound orchestrator callbacks (assigned
-- further down once their functions exist). Modules only invoke the late-bound fields at
-- runtime, never during construction, so the nil placeholders here are safe.
local ctx = {
	-- instance / service refs
	player = player,
	mouse = mouse,
	screenGui = screenGui,
	store = store,
	pageContainer = pageContainer,
	toolBar = toolBar,
	templateBuilding = templateBuilding,
	templateUpgrade = templateUpgrade,
	templateGearGiver = templateGearGiver,
	templateRobuxProduct = templateRobuxProduct,
	buildingPreviews = buildingPreviews,
	placeholderIcon = PREVIEW_PLACEHOLDER_ICON,
	UpgradeConfig = UpgradeConfig,
	AutoclickerConfig = require(shared:WaitForChild("AutoclickerConfig")),
	DevTuning = require(shared:WaitForChild("DevTuning"):WaitForChild("DevTuning")),
	UpgradePricing = require(shared:WaitForChild("UpgradePricing")),
	UpgradeRequirement = require(shared:WaitForChild("UpgradeRequirement")),
	MonetizationConfig = MonetizationConfig,
	NumberFormat = NumberFormat,
	ProductionFormula = ProductionFormula,
	GridPlacement = GridPlacement,
	Attrs = Attrs,
	upgradeCountData = upgradeCountData,
	cookiesValue = cookiesValue,
	-- Shared row map (stable table identity) so StoreAffordance can look up rows by id.
	rowsByUpgradeId = rowsByUpgradeId,
	sellButton = sellButton,
	categoryButton = categoryButton,
	statusLabel = statusLabel,
	tabBar = tabBar,
	tabButtons = tabButtons,
	storeScale = storeScale,
	baseStoreSize = baseStoreSize,
	baseStorePosition = baseStorePosition,
	basePageContainerSize = basePageContainerSize,
	storeSizeConstraint = storeSizeConstraint,
	baseStoreMinSize = baseStoreMinSize,
	baseStoreMaxSize = baseStoreMaxSize,
	-- getters for orchestrator-owned mutable state (read by StorePlacement)
	isSellMode = function()
		return sellMode
	end,
	getCurrentCategory = function()
		return currentCategory
	end,
	-- module handles (assigned just below)
	format = nil,
	layout = nil,
	preview = nil,
	cookieStats = nil,
	cursorTooltip = nil,
	buildingStatsTooltip = nil,
	multiPlaceToolbar = nil,
	floorPlacement = nil,
	sellModeTooltip = nil,
	placement = nil,
	robuxTab = nil,
	robuxSubTabScroller = nil,
	gooTintedUpgradeIcon = nil,
	upgradeIconLayout = nil,
	-- late-bound orchestrator callbacks (assigned once their definitions exist):
	--   showStatus      -> StorePlacement status messages
	--   isBuildingLocked -> StorePreview locked-silhouette state
	--   openUpgradeCategory/getOwnedCount -> StoreUpgradeNudge
	showStatus = nil,
	completeSellButtonVisual = nil,
	isBuildingLocked = nil,
	startLockedBuildingNameReveal = nil,
	openUpgradeCategory = nil,
	getOwnedCount = nil,
}

ctx.format = require(script.Parent.StoreFormat).new(ctx)

-- Same-name aliases so the orchestrator's existing call sites stay unchanged.
-- (formatRateValue is only used inside StoreFormat, so it is intentionally not aliased.)
local formatNumber = ctx.format.formatNumber
local formatCount = ctx.format.formatCount
local formatMultiplier = ctx.format.formatMultiplier
local getProductionMultiplier = ctx.format.getProductionMultiplier
local getIntegrityText = ctx.format.getIntegrityText
local getMultiplierText = ctx.format.getMultiplierText
local getBuildingProductionRates = ctx.format.getBuildingProductionRates
local getProductionRateText = ctx.format.getProductionRateText
local getTotalProductionRateText = ctx.format.getTotalProductionRateText
local placedProduction

local function showStatus(message)
	if statusLabel and (statusLabel:IsA("TextLabel") or statusLabel:IsA("TextButton")) then
		statusLabel.Text = message
	else
		print(message)
	end
end
-- StorePlacement reports status/cancel/error messages through this.
ctx.showStatus = showStatus

local function setText(row, childName, text)
	local label = row:FindFirstChild(childName, true)
	if label and not (label:IsA("TextLabel") or label:IsA("TextButton")) then
		label = nil
	end

	if not label then
		local targetName = string.lower(childName)
		for _, descendant in ipairs(row:GetDescendants()) do
			if
				string.lower(descendant.Name) == targetName
				and (descendant:IsA("TextLabel") or descendant:IsA("TextButton"))
			then
				label = descendant
				break
			end
		end
	end

	if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
		label.Text = text
	end
end
-- StoreBuildingState (name reveal) and StoreAffordance (Cost/lock text) write row labels through this.
ctx.setText = setText

local function setSectionTitle(row, title)
	local label = row:FindFirstChild("SectionTitle", true)
	if not (label and label:IsA("GuiObject")) then
		return
	end

	if label:IsA("TextLabel") or label:IsA("TextButton") then
		label.Text = title or ""
		label.TextWrapped = false
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.new(0, 0, label.Size.Y.Scale, label.Size.Y.Offset)
	end
	label.Visible = title ~= nil
end

local function setCpmIconVisibility(row, cpm)
	local plusIcon = row:FindFirstChild("imageCPM+", true)
	local minusIcon = row:FindFirstChild("imageCPM-", true)
	local isPositive = cpm > 0
	local isNegative = cpm < 0

	if plusIcon and plusIcon:IsA("GuiObject") then
		plusIcon.Visible = isPositive
	end

	if minusIcon and minusIcon:IsA("GuiObject") then
		minusIcon.Visible = isNegative
	end
end

local function getUpgradeCost(upgradeId, currentCount)
	local config = UpgradeConfig[upgradeId]
	return ctx.UpgradePricing.GetCost(config, currentCount)
end
-- StoreAffordance reads costs through this; getUpgradeCost stays here (also used by sell/refund).
ctx.getUpgradeCost = getUpgradeCost

local function getCountValue(upgradeId)
	local value = upgradeCountData:FindFirstChild(upgradeId)
	if value and value:IsA("IntValue") then
		return value
	end

	return nil
end
ctx.getCountValue = getCountValue

local function getUpgradeCategory(config)
	if config.TemplateKind == "Building" then
		return "Building"
	elseif config.TemplateKind == "Gear" then
		return nil
	end

	return "Upgrade"
end

local function getUpgradeSection(config)
	if config.TemplateKind == "BuildingUpgrade" then
		return UPGRADE_SECTION_BUILDING
	end

	return UPGRADE_SECTION_PLAYER
end

local function getNextCategory(category)
	for index, value in ipairs(CATEGORY_ORDER) do
		if value == category then
			return CATEGORY_ORDER[index % #CATEGORY_ORDER + 1]
		end
	end

	return CATEGORY_ORDER[1]
end

local function getOwnedCount(upgradeId)
	local value = getCountValue(upgradeId)
	if value then
		return value.Value
	end

	local config = UpgradeConfig[upgradeId]
	return config and config.InitialCount or 0
end
ctx.getOwnedCount = getOwnedCount

-- Multi-Place preference lives in StoreMultiPlace; the orchestrator reaches it through
-- ctx.multiPlace.* (no top-level re-alias — that would re-spend the freed register budget).
ctx.multiPlace = require(script.Parent.StoreMultiPlace).new(ctx)

-- The Multi-Place row's duplicating-block icon pose/tween lives in
-- StoreMultiPlaceIconAnim; reached via ctx.multiPlaceIconAnim.* (no re-alias).
ctx.multiPlaceIconAnim = require(script.Parent.StoreMultiPlaceIconAnim).new(ctx)

-- Building lock state + alien-name reveal live in StoreBuildingState; reached via
-- ctx.buildingState.* (no top-level re-alias). ctx.isBuildingLocked (read by StorePreview)
-- and ctx.startLockedBuildingNameReveal keep their names for existing callers.
ctx.buildingState = require(script.Parent.StoreBuildingState).new(ctx)
ctx.isBuildingLocked = ctx.buildingState.isBuildingLocked
ctx.startLockedBuildingNameReveal = ctx.buildingState.startLockedBuildingNameReveal

-- Affordability / near-miss chrome + blocked-tap feedback live in StoreAffordance;
-- reached via ctx.affordance.* (no top-level re-alias).
ctx.affordance = require(script.Parent.StoreAffordance).new(ctx)

-- Sort key: building upgrades line up with their target building's tier so the
-- Upgrades tab reads in progression order rather than alphabetically.
local function getSortCost(config)
	if config.TemplateKind == "BuildingUpgrade" then
		local target = config.TargetBuilding and UpgradeConfig[config.TargetBuilding]
		return target and target.BaseCost or 0
	end

	return ctx.UpgradePricing.GetCost(config, 0) or config.BaseCost or 0
end

local function getSortedUpgradeIds()
	local ids = {}
	for upgradeId, config in pairs(UpgradeConfig) do
		if
			config.StoreVisible ~= false
			and not PvpConfig.IsUpgradePaused(upgradeId)
			and getUpgradeCategory(config) == currentCategory
			and ctx.UpgradeRequirement.ShouldShowInStore(upgradeId, config, getOwnedCount)
		then
			if
				config.TemplateKind ~= "BuildingUpgrade"
				or ctx.buildingState.isBuildingUpgradeRevealed(upgradeId, config)
			then
				-- Sell mode shows only buildings the player actually owns, so the list
				-- reads as "your stuff to sell" rather than the full catalogue.
				local sellableOnly = sellMode and currentCategory == "Building"
				if not sellableOnly or getOwnedCount(upgradeId) > (config.InitialCount or 0) then
					table.insert(ids, upgradeId)
				end
			end
		end
	end

	table.sort(ids, function(left, right)
		local leftConfig = UpgradeConfig[left]
		local rightConfig = UpgradeConfig[right]
		if currentCategory == "Upgrade" then
			local leftSectionOrder = UPGRADE_SECTION_ORDER[getUpgradeSection(leftConfig)] or math.huge
			local rightSectionOrder = UPGRADE_SECTION_ORDER[getUpgradeSection(rightConfig)] or math.huge
			if leftSectionOrder ~= rightSectionOrder then
				return leftSectionOrder < rightSectionOrder
			end
		end

		local leftCost = getSortCost(leftConfig)
		local rightCost = getSortCost(rightConfig)
		if leftCost == rightCost then
			return (leftConfig.DisplayName or left) < (rightConfig.DisplayName or right)
		end

		return leftCost < rightCost
	end)

	return ids
end

-- StoreBottom is the only active shell today, so use the horizontal (bottom-bar) layout
-- strategy. StoreLayout (the vertical sidebar math) is kept for the future sidebar toggle.
ctx.layout = require(script.Parent.StoreLayoutBottom).new(ctx)

-- Same-name aliases so the orchestrator's existing call sites stay unchanged.
-- (getStoreScale is consumed only by StoreCookieStats via ctx.layout, so it is not aliased.)
local applyStoreScale = ctx.layout.applyStoreScale
local snapStoreToRows = ctx.layout.snapStoreToRows
local getMaxVisibleRows = ctx.layout.getMaxVisibleRows

local function getSellRefund(upgradeId, currentCount)
	if currentCount <= 0 then
		return 0
	end

	local previousPurchaseCost = getUpgradeCost(upgradeId, currentCount - 1) or 0
	return math.floor(previousPurchaseCost * 0.5)
end

-- Total refund for selling every owned copy down to InitialCount. Sums the same
-- per-building refund the single sell uses, so this preview matches the authoritative
-- server total exactly (server recomputes on confirm).
local function getSellAllRefund(upgradeId)
	local config = UpgradeConfig[upgradeId]
	local minimum = config and config.InitialCount or 0
	local total = 0
	for count = minimum + 1, getOwnedCount(upgradeId) do
		total += getSellRefund(upgradeId, count)
	end
	return total
end
ctx.getSellAllRefund = getSellAllRefund

local function updateSellButton(snapVisual)
	if setSellButtonModeVisual then
		setSellButtonModeVisual(sellMode, snapVisual)
	end
	if sellButton and (sellButton:IsA("TextButton") or sellButton:IsA("ImageButton")) then
		if sellButton:IsA("TextButton") then
			sellButton.Text = sellMode and "Buy" or "Sell"
		end
	end
end

-- The toolbar/page-slide subsystem lives in its own module (StoreToolbarLayout) to keep the
-- orchestrator under Luau's 200-local-per-function cap. It completes the deferred sell-button
-- reset through this callback once its close tween finishes.
ctx.completeSellButtonVisual = function()
	updateSellButton(true)
end

local storeToolbarLayout = require(script.Parent.StoreToolbarLayout).new(ctx)

ctx.upgradeSubTabs = require(script.Parent.StoreUpgradeSubTabs).new(ctx, {
	root = upgradeSubTabs,
	buttons = upgradeSubTabButtons,
	buildingSectionId = UPGRADE_SECTION_BUILDING,
	playerSectionId = UPGRADE_SECTION_PLAYER,
	sectionIds = { UPGRADE_SECTION_BUILDING, UPGRADE_SECTION_PLAYER },
	titleBySection = UPGRADE_SUBTAB_TITLES,
	activeColor = UPGRADE_TAB_COLOR,
	setTabActive = setTabActive,
	layoutTweenInfo = SELL_TAB_LAYOUT_TWEEN_INFO,
	scrollTweenInfo = SELL_TAB_LAYOUT_TWEEN_INFO,
	fitVisibleContent = true,
})

local function setActiveRobuxSubTab(sectionId)
	for key, button in pairs(robuxSubTabButtons) do
		setTabActive(button, key == sectionId, ROBUX_TAB_COLOR)
	end
end

-- Reveals/hides the Robux subcategory chips with the same clip+Size tween used by the sell tab.
local function updateRobuxSubTabLayout()
	if
		not (robuxSubTabs and robuxSubTabs:IsA("GuiObject") and robuxSubTabsExpandedSize and robuxSubTabsCollapsedSize)
	then
		return
	end

	local showSubTabs = currentCategory == "Robux"
	if robuxSubTabsTarget == showSubTabs then
		return
	end
	robuxSubTabsTarget = showSubTabs

	if robuxSubTabsTween then
		robuxSubTabsTween:Cancel()
	end

	if showSubTabs then
		robuxSubTabs.Visible = true
		-- Default-highlight the leftmost section until the user scrolls.
		if ctx.robuxTab then
			local sections = ctx.robuxTab.getSections()
			if sections[1] then
				setActiveRobuxSubTab(sections[1].Id)
			end
		end
	end

	local tween = UiMotion.create(robuxSubTabs, SELL_TAB_LAYOUT_TWEEN_INFO, {
		Size = showSubTabs and robuxSubTabsExpandedSize or robuxSubTabsCollapsedSize,
	})
	robuxSubTabsTween = tween
	tween.Completed:Connect(function(state)
		if robuxSubTabsTween == tween and state == Enum.PlaybackState.Completed and not showSubTabs then
			robuxSubTabs.Visible = false
		end
	end)
	tween:Play()
end

local function updateCategoryButton()
	if categoryButton and (categoryButton:IsA("TextButton") or categoryButton:IsA("ImageButton")) then
		categoryButton.Visible = not tabBar
		if categoryButton:IsA("TextButton") then
			local nextCategory = getNextCategory(currentCategory)
			categoryButton.Text = nextCategory == "Upgrade" and "Upgrades" or nextCategory
		end
	end

	if store then
		store:SetAttribute(Attrs.CurrentCategory, currentCategory)
	end

	for category, button in pairs(tabButtons) do
		setTabActive(button, category == currentCategory)
	end

	storeToolbarLayout.update()
	if currentCategory ~= "Robux" and ctx.robuxSubTabScroller then
		ctx.robuxSubTabScroller.cancel()
	end
	updateRobuxSubTabLayout()
end

ctx.preview = require(script.Parent.StorePreview).new(ctx)

-- ctx.preview IS the previewInteraction table, so existing previewInteraction.* call
-- sites (here and in the cookie-stats slide) keep working via this alias.
local previewInteraction = ctx.preview
local ensureViewport = ctx.preview.ensureViewport
local clearViewport = ctx.preview.clearViewport
local spinPreviews = ctx.preview.spinPreviews

-- Row icon rendering (level/progression icon + toggle state icon) lives in StoreStateIcon;
-- reached via ctx.stateIcon.* (no top-level re-alias).
ctx.stateIcon = require(script.Parent.StoreStateIcon).new(ctx)
ctx.gooTintedUpgradeIcon = require(script.Parent.StoreGooTintedUpgradeIcon).new(ctx)
ctx.upgradeIconLayout = require(script.Parent.StoreUpgradeIconLayout).new(ctx)

local function updateRow(upgradeId)
	local row = rowsByUpgradeId[upgradeId]
	local config = UpgradeConfig[upgradeId]
	if not row or not config then
		return
	end

	-- Leveled upgrades: one row that levels in place (current level + next cost/effect).
	if config.Levels then
		local levels = config.Levels or {}
		local maxLevels = #levels
		local levelsOwned = getOwnedCount(upgradeId)
		local nextLevel = levels[levelsOwned + 1]
		local displayLevel = math.min(levelsOwned + (nextLevel and 1 or 0), math.max(maxLevels, 1))

		ctx.stateIcon.applyUpgradeIcon(row, config, displayLevel, maxLevels)
		ctx.gooTintedUpgradeIcon.apply(row, config)
		ctx.upgradeIconLayout.apply(row, upgradeId)
		ctx.stateIcon.updateUpgradeStateIcon(row, config, levelsOwned > 0)

		local countText = "Lv " .. levelsOwned
		setText(row, "UpgradeName", config.DisplayName or upgradeId)
		setText(row, "Count", countText)
		if countBadge then
			countBadge.updateRow(row, levelsOwned, countText)
		end

		-- Cumulative output multiplier after the next purchase (-> x2, x4 ...).
		local previewLevels = math.min(levelsOwned + (nextLevel and 1 or 0), maxLevels)
		local cumulativeMultiplier = 1
		for level = 1, previewLevels do
			local levelData = levels[level]
			if levelData and type(levelData.OutputMultiplier) == "number" then
				cumulativeMultiplier *= levelData.OutputMultiplier
			end
		end

		local effectText = nextLevel and nextLevel.EffectText
		if not effectText and config.TemplateKind == "BuildingUpgrade" then
			effectText = formatMultiplier(cumulativeMultiplier)
		end
		effectText = effectText or "LEVEL"

		if not nextLevel then
			local maxText = config.TemplateKind == "BuildingUpgrade"
					and ("MAX " .. formatMultiplier(cumulativeMultiplier))
				or "MAXED"
			setText(row, "UpgradeLabel", maxText)
			setText(
				row,
				"Cost",
				sellMode and config.Sellable ~= false and formatNumber(getSellRefund(upgradeId, levelsOwned)) or "MAXED"
			)
			previewInteraction.setRequirementUi(row, nil, nil)
			ctx.affordance.updateRowAffordability(upgradeId)
			return
		end

		local requiredId, requiredCount, ownedCount = ctx.affordance.getLockedRequirement(upgradeId, config, nextLevel)
		previewInteraction.setRequirementUi(row, requiredId, requiredCount, ownedCount)

		local unlocked = config.TemplateKind ~= "BuildingUpgrade"
			or getOwnedCount(config.TargetBuilding) >= (nextLevel.UnlockCount or 0)
		setText(row, "UpgradeLabel", (unlocked and "NEXT " or "LOCKED ") .. effectText)

		if sellMode and config.Sellable == false then
			setText(row, "Cost", "OWNED")
		elseif sellMode then
			setText(row, "Cost", formatNumber(getSellRefund(upgradeId, levelsOwned)))
		elseif unlocked then
			setText(row, "Cost", formatNumber(nextLevel.Cost))
		else
			setText(row, "Cost", "LOCKED")
		end

		ctx.affordance.updateRowAffordability(upgradeId)
		if upgradeNudge then
			upgradeNudge.updateRow(row, upgradeId)
		end
		return
	end

	local countValue = getCountValue(upgradeId)
	local count = countValue and countValue.Value or (config.InitialCount or 0)
	local cost = getUpgradeCost(upgradeId, count) or 0
	local refund = getSellRefund(upgradeId, count)
	local isMaxed = config.MaxCount and count >= config.MaxCount
	local displayLevel = count + 1
	if isMaxed then
		displayLevel = count
	end
	ctx.stateIcon.applyUpgradeIcon(row, config, displayLevel, config.IconProgressionSteps or config.MaxCount)
	ctx.gooTintedUpgradeIcon.apply(row, config)
	ctx.upgradeIconLayout.apply(row, upgradeId)
	local multiPlaceActive = ctx.multiPlace.isUpgradeId(upgradeId) and ctx.multiPlace.isEnabled()
	local stateIconActive = count > (config.InitialCount or 0)
	if ctx.multiPlace.isUpgradeId(upgradeId) then
		stateIconActive = multiPlaceActive
	end
	ctx.stateIcon.updateUpgradeStateIcon(row, config, stateIconActive)
	if ctx.multiPlace.isUpgradeId(upgradeId) then
		ctx.multiPlaceIconAnim.updateRow(row, multiPlaceActive)
	end

	local displayName = config.DisplayName or upgradeId
	local productionMultiplier = getProductionMultiplier(upgradeId, config)
	local cpm = select(1, getBuildingProductionRates(config, productionMultiplier))

	local buildingLocked = ctx.isBuildingLocked(upgradeId, config)
	if not ctx.buildingState.isNameRevealing(upgradeId) then
		setText(row, "UpgradeName", buildingLocked and ctx.buildingState.getAlienBuildingName(upgradeId) or displayName)
	end
	setText(
		row,
		"UpgradeLabel",
		config.TemplateKind == "Building" and "BUILDING" or config.TemplateKind == "Gear" and "GEAR" or "UPGRADE"
	)
	-- Repeatable stat upgrades (uncapped stacking stats like Clicking Power / Health +2) read
	-- as levels, matching the "Lv N" leveled upgrades. Binary unlock stats (MaxCount == 1) keep
	-- a plain count. This branch only runs for non-Levels configs, so leveled Stat upgrades never
	-- reach here.
	local isRepeatableStat = config.TemplateKind == "Stat" and (config.MaxCount == nil or config.MaxCount > 1)
	local countText
	if ctx.multiPlace.isUpgradeId(upgradeId) and count > (config.InitialCount or 0) then
		countText = multiPlaceActive and "On" or "Off"
	elseif config.TemplateKind == "Building" then
		countText = "x" .. formatCount(count)
	elseif isRepeatableStat then
		countText = "Lv " .. formatCount(count)
	else
		countText = formatCount(count)
	end
	setText(row, "Count", countText)
	if countBadge then
		countBadge.updateRow(row, count, countText)
	end
	setText(row, "CPM", getProductionRateText(config, productionMultiplier))
	local placedTotalCpm = placedProduction and placedProduction.getTotalCpm(upgradeId, config, count)
	setText(
		row,
		"TCPM",
		placedTotalCpm and ctx.format.formatRateValue(placedTotalCpm)
			or getTotalProductionRateText(config, count, productionMultiplier)
	)
	setCpmIconVisibility(row, cpm)
	setText(row, "Health", getIntegrityText(config))
	setText(row, "Multiplier", getMultiplierText(upgradeId, config))
	if isMaxed and not sellMode then
		setText(row, "Cost", "OWNED")
	else
		setText(row, "Cost", formatNumber(sellMode and refund or cost))
	end

	local requiredId, requiredCount, ownedCount = ctx.affordance.getLockedRequirement(upgradeId, config)
	previewInteraction.setRequirementUi(row, requiredId, requiredCount, ownedCount)

	ctx.affordance.updateRowAffordability(upgradeId)
	if upgradeNudge then
		upgradeNudge.updateRow(row, upgradeId)
	end
end

local function updateAllRows()
	for upgradeId in pairs(rowsByUpgradeId) do
		updateRow(upgradeId)
	end
end

placedProduction = require(script.Parent.StorePlacedProduction).new(ctx, function(upgradeId)
	if upgradeId then
		updateRow(upgradeId)
	else
		updateAllRows()
	end
end)

screenGui:GetAttributeChangedSignal(Attrs.MultiPlaceEnabled):Connect(function()
	updateRow(ctx.multiPlace.UPGRADE_ID)
end)
player:GetAttributeChangedSignal(Attrs.MultiPlaceEnabled):Connect(function()
	local value = player:GetAttribute(Attrs.MultiPlaceEnabled)
	if type(value) == "boolean" and screenGui:GetAttribute(Attrs.MultiPlaceEnabled) ~= value then
		screenGui:SetAttribute(Attrs.MultiPlaceEnabled, value)
	end
	updateRow(ctx.multiPlace.UPGRADE_ID)
end)

local observedFormulaSources = {}

local function observeFormulaSource(source)
	if not source or observedFormulaSources[source] then
		return
	end

	observedFormulaSources[source] = true
	source.AttributeChanged:Connect(updateAllRows)
	source.ChildAdded:Connect(function(child)
		observeFormulaSource(child)
		updateAllRows()
	end)
	source.ChildRemoved:Connect(updateAllRows)

	if source:IsA("NumberValue") or source:IsA("IntValue") then
		source:GetPropertyChangedSignal("Value"):Connect(updateAllRows)
	end

	for _, child in ipairs(source:GetChildren()) do
		observeFormulaSource(child)
	end
end

local function observeWorldEventMultipliers()
	local worldEventMultipliers = ReplicatedStorage:FindFirstChild("WorldEventMultipliers")
	if worldEventMultipliers then
		observeFormulaSource(worldEventMultipliers)
	end

	ReplicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == "WorldEventMultipliers" then
			observeFormulaSource(child)
			updateAllRows()
		end
	end)
end

-- Renders every row of the active section into the scrolling PageTemplate. The store
-- grows to fit the section but is clamped to the rows that fit on screen; past that the
-- ScrollingFrame scrolls. The UIListLayout positions rows by LayoutOrder, so we assign
-- LayoutOrder from the current sort and let layout handle placement.
local function renderRows()
	ctx.upgradeSubTabs.update(currentCategory, orderedUpgradeIds)
	local visibleByUpgradeId = {}
	table.clear(firstUpgradeRowBySection)
	for index, upgradeId in ipairs(orderedUpgradeIds) do
		visibleByUpgradeId[upgradeId] = true
		local row = rowsByUpgradeId[upgradeId]
		if row and row:IsA("GuiObject") then
			row.LayoutOrder = index
			if currentCategory == "Upgrade" then
				local sectionId = getUpgradeSection(UpgradeConfig[upgradeId])
				local isFirstInSection = firstUpgradeRowBySection[sectionId] == nil
				if isFirstInSection then
					firstUpgradeRowBySection[sectionId] = row
				end
				setSectionTitle(row, isFirstInSection and UPGRADE_SECTION_TITLES[sectionId] or nil)
			else
				setSectionTitle(row, nil)
			end
		end
	end

	local visibleRowCount = #orderedUpgradeIds
	if currentCategory == "Robux" and ctx.robuxTab then
		visibleRowCount = ctx.robuxTab.getVisibleCount()
	end
	snapStoreToRows(math.min(visibleRowCount, getMaxVisibleRows()))

	for upgradeId, row in pairs(rowsByUpgradeId) do
		local isVisible = visibleByUpgradeId[upgradeId] == true
		row.Visible = isVisible
		if isVisible then
			ensureViewport(row, UpgradeConfig[upgradeId])
			ctx.affordance.updateRowAffordability(upgradeId)
			if upgradeNudge then
				upgradeNudge.updateRow(row, upgradeId)
			end
		else
			if upgradeNudge then
				upgradeNudge.hideRow(row)
			end
			clearViewport(row)
		end
	end

	if ctx.robuxTab then
		ctx.robuxTab.render(currentCategory == "Robux")
	end
end

local function refreshCategory()
	if currentCategory ~= "Building" and sellMode then
		sellMode = false
		screenGui:SetAttribute(Attrs.SellMode, false)
		storeToolbarLayout.markSellModeVisualResetPending()
	end

	orderedUpgradeIds = currentCategory == "Robux" and {} or getSortedUpgradeIds()
	updateCategoryButton()
	if pageContainer:IsA("ScrollingFrame") then
		pageContainer.CanvasPosition = Vector2.zero
	end
	renderRows()
	updateAllRows()
end

local function scrollToUpgradeRow(upgradeId)
	if not upgradeId then
		return
	end

	local row = rowsByUpgradeId[upgradeId]
	local config = UpgradeConfig[upgradeId]
	if not row or not row.Visible or not row:IsA("GuiObject") or not config then
		return
	end

	ctx.upgradeSubTabs.scrollToRow(getUpgradeSection(config), row)
end

ctx.openUpgradeCategory = function(targetUpgradeId)
	currentCategory = "Upgrade"
	refreshCategory()
	task.spawn(function()
		-- Let UIListLayout resolve the newly-visible upgrade rows before reading the
		-- target card's AbsolutePosition in StoreSubTabScroller.
		RunService.Heartbeat:Wait()
		scrollToUpgradeRow(targetUpgradeId)
	end)
end

-- Horizontal twin of scrollToUpgradeRow: scrolls the strip so the first card of a Robux
-- section sits at the left edge, and highlights that section's chip.
local function scrollRobuxToSection(sectionId)
	if currentCategory ~= "Robux" or not pageContainer:IsA("ScrollingFrame") or not ctx.robuxTab then
		return
	end

	local card = ctx.robuxTab.getFirstCardOfSection(sectionId)
	if not card or not card:IsA("GuiObject") or not card.Visible then
		return
	end

	ctx.robuxSubTabScroller.scrollTo(sectionId, card)
end

local pageRefreshQueued = false
local function schedulePageRefresh()
	if pageRefreshQueued then
		return
	end

	pageRefreshQueued = true
	task.defer(function()
		pageRefreshQueued = false
		if #orderedUpgradeIds > 0 or currentCategory == "Robux" then
			renderRows()
		end
	end)
end

-- §4a: building-upgrade rows reveal/hide as target buildings are first owned, so
-- recompute the ordered list (not just row text) when counts change on this tab.
local orderingRefreshQueued = false
local function scheduleOrderingRefresh()
	if orderingRefreshQueued then
		return
	end

	orderingRefreshQueued = true
	task.defer(function()
		orderingRefreshQueued = false
		orderedUpgradeIds = getSortedUpgradeIds()
		renderRows()
	end)
end

ctx.cursorTooltip = require(shared:WaitForChild("CursorTooltip")).get(screenGui)
ctx.multiPlaceToolbar = require(script.Parent.StoreMultiPlaceToolbar).new(ctx)
ctx.sellModeTooltip = require(script.Parent.StoreSellModeTooltip).new(ctx)
ctx.floorPlacement = require(script.Parent.StoreFloorPlacement).new(ctx)
ctx.placement = require(script.Parent.StorePlacement).new(ctx)
ctx.placementControls = require(script.Parent.StorePlacementControls).new(ctx, ctx.placement)
ctx.multiPlaceSessionControls = require(script.Parent.StoreMultiPlaceSessionControls).new(ctx)
upgradeNudge = require(script.Parent.StoreUpgradeNudge).new(ctx)
countBadge = require(script.Parent.StoreCountBadge).new(ctx)
screenGui:GetAttributeChangedSignal(Attrs.UpgradeRemindersEnabled):Connect(updateAllRows)

-- createRow's Building rows start placement through this alias.
local startPlacement = ctx.placement.start

ctx.cookieStats = require(script.Parent.StoreCookieStats).new(ctx)

local setupCookieStatsSlide = ctx.cookieStats.setup
local updateStatsSlideHover = ctx.cookieStats.updateHover

ctx.storeDescription = require(script.Parent.StoreDescription).new(ctx)

-- Placed-building inspection is independent; Stats Eye only locks Store-card stats open.
ctx.buildingStatsTooltip = require(script.Parent.StoreBuildingStatsTooltip).new(ctx)
ctx.statsEye = require(script.Parent.StatsEyeController).new(ctx)

-- Centered "Sell all N X?" confirmation. Its Confirm button calls
-- ctx.invokeSellAll (bound near the bottom, resolved lazily at click time).
ctx.sellConfirm = require(script.Parent.StoreSellConfirm).new(ctx)
local sellConfirm = ctx.sellConfirm

ctx.robuxTab = require(script.Parent.StoreRobuxTab).new(ctx)
ctx.robuxSubTabScroller =
	require(script.Parent.StoreSubTabScroller).new(pageContainer, SELL_TAB_LAYOUT_TWEEN_INFO, setActiveRobuxSubTab)

local function createRow(upgradeId, index)
	local config = UpgradeConfig[upgradeId]
	if not config then
		return
	end
	if not getUpgradeCategory(config) then
		return
	end

	local template = templateUpgrade
	if config.TemplateKind == "Building" then
		template = templateBuilding
	elseif config.TemplateKind == "Gear" then
		template = templateGearGiver
	end
	if not template then
		template = templateUpgrade
	end

	local row = template:Clone()
	row.Name = upgradeId
	row.Visible = false
	row:SetAttribute("GeneratedByStoreController", true)
	row:SetAttribute("StoreTemplate", nil)
	row.Parent = pageContainer

	if row:IsA("GuiObject") then
		row.LayoutOrder = index
	end

	local catch = row:FindFirstChild("Catch", true)
	if catch and (catch:IsA("TextButton") or catch:IsA("ImageButton")) then
		local function activateRow()
			if sellMode and config.TemplateKind == "Building" then
				-- Card = sell-all (with confirm); clicking a placed building still sells one.
				local quantity = getOwnedCount(upgradeId) - (config.InitialCount or 0)
				if quantity <= 0 then
					return
				end
				sellConfirm.open(upgradeId)
				return
			elseif sellMode then
				invokeSell(upgradeId)
				return
			end

			if ctx.multiPlace.isUpgradeId(upgradeId) and ctx.multiPlace.isOwned() then
				ctx.multiPlace.setEnabled(not ctx.multiPlace.isEnabled())
				updateRow(upgradeId)
				return
			end

			-- Buy mode: gate before spawning the placement ghost or firing the purchase, so a
			-- building the player can't afford/unlock never enters placement (the core fix).
			-- A blocked tap flashes the number that explains why. Requirement gates also
			-- pulse only the required-building preview, not the full widget/card.
			local blockContainer = ctx.affordance.getPurchaseBlock(upgradeId, config)
			if blockContainer then
				local blockWidget = row:FindFirstChild(blockContainer, true)
				ctx.affordance.flashNumberText(blockWidget)
				if blockContainer == "Requirement" then
					ctx.affordance.pulseRequirementPreview(blockWidget)
				end
				if blockContainer == "cookieCost" then
					local liveCount = store:FindFirstChild("LiveCookieCount", true)
					local amountLabel = liveCount and liveCount:FindFirstChild("Amount", true)
					if amountLabel and (amountLabel:IsA("TextLabel") or amountLabel:IsA("TextButton")) then
						ctx.affordance.flashNumberText(amountLabel)
					end
				end
				return
			end

			if config.TemplateKind == "Building" then
				startPlacement(upgradeId)
			else
				invokePurchase(upgradeId)
			end
		end

		setupCookieStatsSlide(row, upgradeId, activateRow)
		ctx.storeDescription.setup(row, upgradeId)
		catch.MouseButton1Click:Connect(activateRow)
	else
		warn("Store row missing Catch button for " .. upgradeId)
	end

	rowsByUpgradeId[upgradeId] = row
	updateRow(upgradeId)
end

local function hideTemplates()
	templateUpgrade.Visible = false
	if templateGearGiver then
		templateGearGiver.Visible = false
	end
	if templateRobuxProduct and templateRobuxProduct:IsA("GuiObject") then
		templateRobuxProduct.Visible = false
	end

	if templateBuilding and templateBuilding:IsA("GuiObject") then
		templateBuilding.Visible = false
	end
end

local function clearGeneratedRows()
	for _, parent in ipairs({ pageContainer, store:FindFirstChild("Frame"), store }) do
		if parent then
			for _, child in ipairs(parent:GetChildren()) do
				if child:GetAttribute("GeneratedByStoreController") then
					child:Destroy()
				end
			end
		end
	end
end

clearGeneratedRows()
hideTemplates()

local creationIndex = 0
for upgradeId in pairs(UpgradeConfig) do
	creationIndex += 1
	createRow(upgradeId, creationIndex)
end

applyStoreScale()
refreshCategory()
updateSellButton()
observeWorldEventMultipliers()
ctx.gooTintedUpgradeIcon.observe(function()
	updateRow(ctx.AutoclickerConfig.UnlockUpgradeId)
end)
ctx.DevTuning.observe(ctx.AutoclickerConfig.UnlockCostTuningId, function()
	if currentCategory == "Upgrade" then
		scheduleOrderingRefresh()
	else
		updateRow(ctx.AutoclickerConfig.UnlockUpgradeId)
	end
end)

if pageContainer:IsA("GuiObject") then
	pageContainer:GetPropertyChangedSignal("AbsoluteSize"):Connect(schedulePageRefresh)
end

if store:IsA("GuiObject") then
	store:GetPropertyChangedSignal("Visible"):Connect(schedulePageRefresh)
	store:GetPropertyChangedSignal("AbsoluteSize"):Connect(schedulePageRefresh)
end

local function connectTemplateResize(template)
	if not template or not template:IsA("GuiObject") then
		return
	end

	template:GetPropertyChangedSignal("Size"):Connect(schedulePageRefresh)
	template:GetPropertyChangedSignal("AbsoluteSize"):Connect(schedulePageRefresh)
end

connectTemplateResize(templateBuilding)
connectTemplateResize(templateGearGiver)
connectTemplateResize(templateUpgrade)
connectTemplateResize(templateRobuxProduct)

local viewportScaleConnection = nil
local function connectViewportScale()
	if viewportScaleConnection then
		viewportScaleConnection:Disconnect()
		viewportScaleConnection = nil
	end

	local camera = Workspace.CurrentCamera
	if camera then
		viewportScaleConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			applyStoreScale()
			schedulePageRefresh()
		end)
	end
end

connectViewportScale()
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	applyStoreScale()
	schedulePageRefresh()
	connectViewportScale()
end)

RunService.RenderStepped:Connect(function()
	ctx.buildingState.updateBuildingNameReveals()
	updateStatsSlideHover()
	ctx.placement.tick()
	-- Skip the spin entirely while the store shell is hidden (nothing to see), and cull to
	-- on-screen cards via pageContainer while it is open — a closed store retains its built
	-- building viewports in the spinner registry, so an ungated loop would keep re-rendering
	-- heavy off-screen models every frame.
	if store.Visible then
		spinPreviews(pageContainer)
	end
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	ctx.placement.handleInputChanged(input, gameProcessed)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	ctx.placement.handleInputBegan(input, gameProcessed)
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	ctx.placement.handleInputEnded(input, gameProcessed)
end)

if sellButton and (sellButton:IsA("TextButton") or sellButton:IsA("ImageButton")) then
	sellButton.MouseButton1Click:Connect(function()
		if currentCategory ~= "Building" then
			return
		end

		sellMode = not sellMode
		screenGui:SetAttribute(Attrs.SellMode, sellMode)
		updateSellButton()
		-- refreshCategory re-runs the sort so the owned-only filter is applied (or
		-- cleared) immediately, not just on the next category switch.
		refreshCategory()
		if sellMode and currentCategory == "Building" then
			showStatus("Click a card to sell all, or a placed building to sell one.")
		end
	end)
end

if categoryButton and (categoryButton:IsA("TextButton") or categoryButton:IsA("ImageButton")) then
	categoryButton.MouseButton1Click:Connect(function()
		currentCategory = getNextCategory(currentCategory)
		refreshCategory()
	end)
end

for category, button in pairs(tabButtons) do
	if button and (button:IsA("TextButton") or button:IsA("ImageButton")) then
		button.MouseButton1Click:Connect(function()
			currentCategory = category
			refreshCategory()
		end)
	end
end

-- Upgrades subcategory chips scroll the strip to their section.
for sectionId, button in pairs(upgradeSubTabButtons) do
	if button and (button:IsA("TextButton") or button:IsA("ImageButton")) then
		button.MouseButton1Click:Connect(function()
			if currentCategory ~= "Upgrade" then
				currentCategory = "Upgrade"
				refreshCategory()
				task.defer(function()
					ctx.upgradeSubTabs.scrollToSection(sectionId, firstUpgradeRowBySection)
				end)
				return
			end
			ctx.upgradeSubTabs.scrollToSection(sectionId, firstUpgradeRowBySection)
		end)
	end
end

-- Robux subcategory chips scroll the strip to their section.
for sectionId, button in pairs(robuxSubTabButtons) do
	if button and (button:IsA("TextButton") or button:IsA("ImageButton")) then
		button.MouseButton1Click:Connect(function()
			scrollRobuxToSection(sectionId)
		end)
	end
end

-- While on the Robux tab, highlight the chip for whichever section is nearest the left edge.
if pageContainer:IsA("ScrollingFrame") and robuxSubTabs then
	pageContainer:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		if currentCategory ~= "Robux" or not ctx.robuxTab then
			return
		end

		ctx.robuxSubTabScroller.updateActive(ctx.robuxTab.getSections(), ctx.robuxTab.getFirstCardOfSection, "Id")
	end)
end

-- While on the Upgrades tab, highlight the chip for whichever section is nearest the left edge.
if pageContainer:IsA("ScrollingFrame") and upgradeSubTabs then
	pageContainer:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		ctx.upgradeSubTabs.updateActiveFromCanvas(firstUpgradeRowBySection)
	end)
end

local function onUpgradeCountChanged(upgradeId)
	updateRow(upgradeId)
	if ctx.multiPlace.isUpgradeId(upgradeId) and ctx.multiPlaceToolbar then
		ctx.multiPlaceToolbar.refresh()
	end

	-- Buying the first of a building flips its preview out of the silhouette state,
	-- so rebuild the viewport if the row is on screen.
	local changedRow = rowsByUpgradeId[upgradeId]
	if changedRow and changedRow.Visible then
		ensureViewport(changedRow, UpgradeConfig[upgradeId])
	end

	-- Buying a building upgrade changes the target building's CPM/TCPM/Multiplier
	-- display, so refresh that building's row too.
	local config = UpgradeConfig[upgradeId]
	if config and config.TemplateKind == "BuildingUpgrade" and config.TargetBuilding then
		updateRow(config.TargetBuilding)
	end

	-- Buying/selling a building changes building-upgrade requirement counters.
	for dependentId, dependentConfig in pairs(UpgradeConfig) do
		if dependentConfig.TemplateKind == "BuildingUpgrade" and dependentConfig.TargetBuilding == upgradeId then
			updateRow(dependentId)
		end
	end

	-- A building's count crossing a threshold can reveal/lock its upgrade row, so
	-- re-evaluate the Upgrades tab ordering while it's the one on screen.
	if currentCategory == "Upgrade" then
		scheduleOrderingRefresh()
	end

	-- Buying the gating building (e.g. Research Facility) unlocks dependents (Portal):
	-- refresh their rows so the near-miss lock text/bar clears in place.
	for dependentId, dependentConfig in pairs(UpgradeConfig) do
		local requirement = dependentConfig.UnlockRequirement
		if type(requirement) == "table" and ctx.UpgradeRequirement.GetRequiredId(requirement) == upgradeId then
			updateRow(dependentId)
		end
	end
end

for upgradeId in pairs(UpgradeConfig) do
	local countValue = getCountValue(upgradeId)
	if countValue then
		countValue.Changed:Connect(function()
			onUpgradeCountChanged(upgradeId)
		end)
	end
end

upgradeCountData.ChildAdded:Connect(function(child)
	if child:IsA("IntValue") then
		child.Changed:Connect(function()
			onUpgradeCountChanged(child.Name)
		end)
		onUpgradeCountChanged(child.Name)
	end
end)

-- Apply a Purchase/Sell request/response result (the return value of Net.invoke). Mirrors the
-- old shared-result-event handler: surface the message and refresh the affected row. The server
-- echoes upgradeId back so the building-sell path (which sends an Instance) knows which row.
local function applyPurchaseResult(result)
	result = result or {}
	showStatus(result.message or (result.success and "Purchased." or "Purchase failed."))

	if result.success and result.upgradeId == ctx.multiPlace.UPGRADE_ID then
		ctx.multiPlace.setPreference(true)
	end

	if result.upgradeId then
		updateRow(result.upgradeId)
	end

	-- A successful sell can drop a building's count to its floor; re-sort so the now-empty
	-- card leaves the owned-only list (covers both single and bulk sells).
	if result.success and sellMode and currentCategory == "Building" then
		refreshCategory()
		if #orderedUpgradeIds == 0 then
			showStatus("No buildings left to sell.")
		end
	end
end

-- InvokeServer blocks the calling thread, so spawn it: the input handler stays responsive and
-- the result is applied when the round-trip completes.
function invokePurchase(upgradeId, placementCFrame, callback, placementFloorId)
	task.spawn(function()
		local result = Net.invoke(Names.PurchaseUpgrade, upgradeId, placementCFrame, placementFloorId)
		applyPurchaseResult(result)
		if callback then
			callback(result)
		end
	end)
end

function invokeSell(upgradeIdOrBuilding)
	task.spawn(function()
		applyPurchaseResult(Net.invoke(Names.SellUpgrade, upgradeIdOrBuilding))
	end)
end

function invokeSellAll(upgradeId)
	task.spawn(function()
		applyPurchaseResult(Net.invoke(Names.SellAll, upgradeId))
	end)
end

ctx.invokePurchase = invokePurchase
ctx.invokeSell = invokeSell
ctx.invokeSellAll = invokeSellAll

-- §9 near-miss: the affordability bars track the live cookie balance, so refresh
-- the on-screen rows whenever it changes (clicks and production ticks both fire).
cookiesValue.Changed:Connect(function()
	for upgradeId, row in pairs(rowsByUpgradeId) do
		if row.Visible then
			ctx.affordance.updateRowAffordability(upgradeId)
		end
	end
end)

-- First purchase of a building flips it from locked → unlocked server-side; when the
-- replicated set changes, drop the silhouette + progress bar on the affected rows.
player:GetAttributeChangedSignal(Attrs.UnlockedBuildingsJson):Connect(function()
	local previouslyLocked = {}
	for upgradeId, config in pairs(UpgradeConfig) do
		if config.TemplateKind == "Building" then
			previouslyLocked[upgradeId] = ctx.isBuildingLocked(upgradeId, config)
		end
	end

	ctx.buildingState.refreshUnlockedBuildings()
	for upgradeId, row in pairs(rowsByUpgradeId) do
		if row.Visible then
			local config = UpgradeConfig[upgradeId]
			updateRow(upgradeId)
			ensureViewport(row, config)
			if config and previouslyLocked[upgradeId] and not ctx.isBuildingLocked(upgradeId, config) then
				ctx.buildingState.startBuildingNameReveal(upgradeId, row, config.DisplayName or upgradeId)
			end
		end
	end
end)

-- Equipping/unequipping a skin changes a building's skin multiplier (WheelService
-- publishes it as a NumberValue per building under EquippedSkinData). The production
-- formula already reads it, but the row's Multiplier/CPM/TCPM text is only recomputed
-- on demand — so refresh the affected building's row when its skin value changes.
local function refreshBuildingFromSkin(buildingId)
	if rowsByUpgradeId[buildingId] then
		updateRow(buildingId)
	end
end

local function watchSkinValue(value)
	if not (value:IsA("NumberValue") or value:IsA("IntValue")) then
		return
	end
	value.Changed:Connect(function()
		refreshBuildingFromSkin(value.Name)
	end)
	refreshBuildingFromSkin(value.Name)
end

local function watchEquippedSkinData(folder)
	for _, child in ipairs(folder:GetChildren()) do
		watchSkinValue(child)
	end
	folder.ChildAdded:Connect(watchSkinValue)
	folder.ChildRemoved:Connect(function(child)
		refreshBuildingFromSkin(child.Name)
	end)
end

local existingSkinData = player:FindFirstChild("EquippedSkinData")
if existingSkinData then
	watchEquippedSkinData(existingSkinData)
end
player.ChildAdded:Connect(function(child)
	if child.Name == "EquippedSkinData" then
		watchEquippedSkinData(child)
	end
end)

-- Goo skins apply their strongest owned bonus universally, so every visible producer row
-- needs refreshed when that one attribute changes.
player:GetAttributeChangedSignal(Attrs.GooSkinMultiplier):Connect(function()
	for upgradeId, row in pairs(rowsByUpgradeId) do
		if row.Visible then
			updateRow(upgradeId)
		end
	end
end)
