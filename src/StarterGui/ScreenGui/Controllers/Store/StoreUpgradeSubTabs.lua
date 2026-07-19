-- StoreUpgradeSubTabs: owns visibility, active state, and section scrolling for
-- the Studio-authored Building / Player chips on the Store's Upgrades page.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiMotion = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiMotion"))

local StoreUpgradeSubTabs = {}

function StoreUpgradeSubTabs.new(ctx, options)
	local root = options.root
	local buttons = options.buttons
	local buildingSectionId = options.buildingSectionId
	local playerSectionId = options.playerSectionId
	local sectionIds = options.sectionIds
	local expandedSize = root and root:IsA("GuiObject") and root.Size or nil
	local collapsedSize = expandedSize and UDim2.new(0, 0, expandedSize.Y.Scale, expandedSize.Y.Offset) or nil

	local M = {}
	local layoutTween = nil
	local layoutTarget = nil
	local sectionScrollTween = nil
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
		upgradesPageActive = category == "Upgrade"
		local wasBuildingSectionAvailable = buildingSectionAvailable
		buildingSectionAvailable = upgradesPageActive and hasBuildingUpgrade(orderedUpgradeIds)

		local buildingButton = buttons[buildingSectionId]
		if buildingButton and buildingButton:IsA("GuiObject") then
			buildingButton.Visible = buildingSectionAvailable
		end

		local playerButton = buttons[playerSectionId]
		if playerButton and playerButton:IsA("GuiObject") then
			playerButton.Visible = true
		end

		if upgradesPageActive and wasBuildingSectionAvailable ~= buildingSectionAvailable then
			if sectionScrollTween then
				sectionScrollTween:Cancel()
				sectionScrollTween = nil
			end
			setActive(buildingSectionAvailable and buildingSectionId or playerSectionId)
		end

		if not (root and root:IsA("GuiObject") and expandedSize and collapsedSize) then
			return
		end

		if layoutTarget == upgradesPageActive then
			return
		end
		layoutTarget = upgradesPageActive

		if layoutTween then
			layoutTween:Cancel()
		end

		if not upgradesPageActive and sectionScrollTween then
			sectionScrollTween:Cancel()
			sectionScrollTween = nil
		end

		if upgradesPageActive then
			root.Visible = true
			setActive(buildingSectionAvailable and buildingSectionId or playerSectionId)
		end

		local tween = UiMotion.create(root, options.layoutTweenInfo, {
			Size = upgradesPageActive and expandedSize or collapsedSize,
		})
		layoutTween = tween
		tween.Completed:Connect(function(state)
			if layoutTween == tween and state == Enum.PlaybackState.Completed and not upgradesPageActive then
				root.Visible = false
			end
		end)
		tween:Play()
	end

	function M.scrollToSection(sectionId, firstRowBySection)
		if not upgradesPageActive or not ctx.pageContainer:IsA("ScrollingFrame") then
			return
		end
		if sectionId == buildingSectionId and not buildingSectionAvailable then
			return
		end

		local row = firstRowBySection[sectionId]
		if not row or not row:IsA("GuiObject") or not row.Visible then
			return
		end

		local current = ctx.pageContainer.CanvasPosition
		local rowLeft = row.AbsolutePosition.X - ctx.pageContainer.AbsolutePosition.X + current.X
		local maxX = math.max(0, ctx.pageContainer.AbsoluteCanvasSize.X - ctx.pageContainer.AbsoluteSize.X)
		local target = Vector2.new(math.clamp(rowLeft - 8, 0, maxX), current.Y)

		if sectionScrollTween then
			sectionScrollTween:Cancel()
		end
		setActive(sectionId)

		local tween = UiMotion.create(ctx.pageContainer, options.scrollTweenInfo, {
			CanvasPosition = target,
		})
		sectionScrollTween = tween
		tween.Completed:Connect(function()
			if sectionScrollTween == tween then
				sectionScrollTween = nil
				setActive(sectionId)
			end
		end)
		tween:Play()
	end

	function M.updateActiveFromCanvas(firstRowBySection)
		if not upgradesPageActive or sectionScrollTween then
			return
		end

		local viewLeft = ctx.pageContainer.AbsolutePosition.X
		local bestSection, bestDistance
		for _, sectionId in ipairs(sectionIds) do
			local row = firstRowBySection[sectionId]
			if row and row:IsA("GuiObject") and row.Visible then
				local distance = math.abs(row.AbsolutePosition.X - viewLeft)
				if not bestDistance or distance < bestDistance then
					bestDistance = distance
					bestSection = sectionId
				end
			end
		end

		if bestSection then
			setActive(bestSection)
		end
	end

	return M
end

return StoreUpgradeSubTabs
