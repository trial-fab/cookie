-- StoreUpgradeSubTabs: owns visibility, active state, and section scrolling for
-- the Studio-authored Building / Player chips on the Store's Upgrades page.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiMotion = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiMotion"))
local StoreSubTabScroller = require(script.Parent.StoreSubTabScroller)

local StoreUpgradeSubTabs = {}

function StoreUpgradeSubTabs.new(ctx, options)
	local root = options.root
	local buttons = options.buttons
	local buildingSectionId = options.buildingSectionId
	local playerSectionId = options.playerSectionId
	local sectionIds = options.sectionIds
	local expandedSize = root and root:IsA("GuiObject") and root.Size or nil
	local collapsedSize = expandedSize and UDim2.new(0, 0, expandedSize.Y.Scale, expandedSize.Y.Offset) or nil
	local singleButtonSize = expandedSize
			and UDim2.new(
				expandedSize.X.Scale * 0.5,
				expandedSize.X.Offset * 0.5,
				expandedSize.Y.Scale,
				expandedSize.Y.Offset
			)
		or nil
	local buildingButton = buttons[buildingSectionId]
	local playerButton = buttons[playerSectionId]
	local authoredBuildingButtonSize = buildingButton and buildingButton:IsA("GuiObject") and buildingButton.Size or nil
	local authoredPlayerButtonSize = playerButton and playerButton:IsA("GuiObject") and playerButton.Size or nil

	local M = {}
	local layoutTween = nil
	local layoutTarget = nil
	local layoutSizeTarget = nil
	local buildingSectionAvailable = false
	local upgradesPageActive = false

	if root and collapsedSize then
		root.Size = collapsedSize
		root.Visible = false
	end

	for sectionId, button in pairs(buttons) do
		if button and button:IsA("TextButton") then
			button.Text = options.titleBySection[sectionId]
		end
	end

	local function setActive(sectionId)
		for key, button in pairs(buttons) do
			options.setTabActive(button, key == sectionId, options.activeColor)
		end
	end

	local sectionScroller = StoreSubTabScroller.new(ctx.pageContainer, options.scrollTweenInfo, setActive)

	local function getExpandedTargetSize()
		if options.fitVisibleContent and not buildingSectionAvailable and singleButtonSize then
			return singleButtonSize
		end

		return expandedSize
	end

	local function updateRootLayout()
		if not (root and root:IsA("GuiObject") and expandedSize and collapsedSize) then
			return
		end

		local desiredSize = upgradesPageActive and getExpandedTargetSize() or collapsedSize
		if layoutTarget == upgradesPageActive and layoutSizeTarget == desiredSize then
			return
		end
		layoutTarget = upgradesPageActive
		layoutSizeTarget = desiredSize

		if layoutTween then
			layoutTween:Cancel()
		end

		if upgradesPageActive then
			root.Visible = true
		end

		local tween = UiMotion.create(root, options.layoutTweenInfo, {
			Size = desiredSize,
		})
		layoutTween = tween
		tween.Completed:Connect(function(state)
			if layoutTween == tween and state == Enum.PlaybackState.Completed and not upgradesPageActive then
				root.Visible = false
			end
		end)
		tween:Play()
	end

	local function hasBuildingUpgrade(orderedUpgradeIds)
		for _, upgradeId in ipairs(orderedUpgradeIds) do
			local config = ctx.UpgradeConfig[upgradeId]
			if config and config.TemplateKind == "BuildingUpgrade" then
				return true
			end
		end

		return false
	end

	function M.update(category, orderedUpgradeIds)
		local wasUpgradesPageActive = upgradesPageActive
		upgradesPageActive = category == "Upgrade"
		local wasBuildingSectionAvailable = buildingSectionAvailable
		buildingSectionAvailable = upgradesPageActive and hasBuildingUpgrade(orderedUpgradeIds)

		if buildingButton and buildingButton:IsA("GuiObject") then
			buildingButton.Visible = buildingSectionAvailable
			if authoredBuildingButtonSize then
				buildingButton.Size = authoredBuildingButtonSize
			end
		end

		if playerButton and playerButton:IsA("GuiObject") then
			playerButton.Visible = true
			if authoredPlayerButtonSize then
				playerButton.Size = buildingSectionAvailable and authoredPlayerButtonSize
					or UDim2.new(1, 0, authoredPlayerButtonSize.Y.Scale, authoredPlayerButtonSize.Y.Offset)
			end
		end

		if upgradesPageActive and wasBuildingSectionAvailable ~= buildingSectionAvailable then
			sectionScroller.cancel()
			setActive(buildingSectionAvailable and buildingSectionId or playerSectionId)
		end

		if wasUpgradesPageActive and not upgradesPageActive then
			sectionScroller.cancel()
		end

		if upgradesPageActive then
			setActive(buildingSectionAvailable and buildingSectionId or playerSectionId)
		end

		updateRootLayout()
	end

	local function scrollToRow(sectionId, row)
		if not upgradesPageActive or not ctx.pageContainer:IsA("ScrollingFrame") then
			return
		end
		if sectionId == buildingSectionId and not buildingSectionAvailable then
			return
		end
		if not row or not row:IsA("GuiObject") or not row.Visible then
			return
		end

		sectionScroller.scrollTo(sectionId, row)
	end

	function M.scrollToSection(sectionId, firstRowBySection)
		scrollToRow(sectionId, firstRowBySection[sectionId])
	end

	-- Nudge navigation and subtab navigation intentionally share this exact path.
	M.scrollToRow = scrollToRow

	function M.updateActiveFromCanvas(firstRowBySection)
		if not upgradesPageActive then
			return
		end

		sectionScroller.updateActive(sectionIds, firstRowBySection)
	end

	return M
end

return StoreUpgradeSubTabs
