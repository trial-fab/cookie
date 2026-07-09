-- StoreToolbarLayout: owns the Building-tab ToolBar reveal (the vertical Sell / Stats-eye
-- strip) and the matching PageTemplate slide. When Building is the active category the whole
-- ScrollingFrame slides right by the toolbar's width and narrows to match, so its clipped left
-- edge lands on the toolbar's right edge and cards clip there instead of scrolling (visibly,
-- now that the toolbar is translucent) behind it. Switching to another category tweens both
-- back. This lived inline in StoreController until the orchestrator ran out of local registers
-- (Luau's 200-per-function cap); it is a self-contained subsystem, so it moved here.
--
-- Sell-mode bridge: leaving the Building tab cancels sell mode, but the sell button's visual
-- must only snap back AFTER the close tween finishes (or immediately when no animation runs).
-- The orchestrator calls markSellModeVisualResetPending() when it drops sell mode, and this
-- module fires ctx.completeSellButtonVisual() at the right moment.
local TweenService = game:GetService("TweenService")

local TOOLBAR_REVEAL_OPEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TOOLBAR_REVEAL_CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local PAGE_PADDING_LEFT = UDim.new(0, 4)

local StoreToolbarLayout = {}

function StoreToolbarLayout.new(ctx)
	local pageContainer = ctx.pageContainer
	local toolBar = ctx.toolBar
	local buildingTab = ctx.tabButtons and ctx.tabButtons.Building
	local pagePadding = pageContainer
		and pageContainer:IsA("GuiObject")
		and pageContainer:FindFirstChildOfClass("UIPadding")
		or nil

	local buildingTabFullSize = buildingTab
		and UDim2.new(0, 100, buildingTab.Size.Y.Scale, buildingTab.Size.Y.Offset)
		or nil

	local toolBarOpenPosition = toolBar and toolBar:IsA("GuiObject") and toolBar.Position or nil
	local toolBarClosedPosition = nil
	if toolBar and toolBar:IsA("GuiObject") and toolBarOpenPosition then
		local closedOffset = toolBar.Size.X.Offset
		if closedOffset <= 0 then
			closedOffset = 30
		end
		toolBarClosedPosition = UDim2.new(
			toolBarOpenPosition.X.Scale,
			toolBarOpenPosition.X.Offset - closedOffset,
			toolBarOpenPosition.Y.Scale,
			toolBarOpenPosition.Y.Offset
		)
	end

	local basePageContainerSize = pageContainer:IsA("GuiObject") and pageContainer.Size or UDim2.new()
	local basePageContainerPosition = pageContainer:IsA("GuiObject") and pageContainer.Position or UDim2.new()

	local layoutTweens = {}
	local layoutToken = 0
	local layoutTarget = nil
	local pendingSellModeVisualReset = false

	local function completePendingSellModeVisualReset()
		if not pendingSellModeVisualReset then
			return
		end
		pendingSellModeVisualReset = false
		if ctx.completeSellButtonVisual then
			ctx.completeSellButtonVisual()
		end
	end

	-- Horizontal space the toolbar occupies; the page slides right by exactly this much.
	-- Offset-based width (no timing dependency on AbsoluteSize); falls back for scaled toolbars.
	local function getToolBarShift()
		if not (toolBar and toolBar:IsA("GuiObject")) then
			return 0
		end
		if toolBar.Size.X.Scale == 0 then
			return toolBar.Size.X.Offset
		end
		local width = toolBar.AbsoluteSize.X
		return width > 0 and width or toolBar.Size.X.Offset
	end

	local function getPageContainerLayout(showToolBar)
		local shift = showToolBar and getToolBarShift() or 0
		local position = UDim2.new(
			basePageContainerPosition.X.Scale,
			basePageContainerPosition.X.Offset + shift,
			basePageContainerPosition.Y.Scale,
			basePageContainerPosition.Y.Offset
		)
		local size = UDim2.new(
			basePageContainerSize.X.Scale,
			basePageContainerSize.X.Offset - shift,
			basePageContainerSize.Y.Scale,
			basePageContainerSize.Y.Offset
		)
		return position, size
	end

	local function update()
		if buildingTab and buildingTab:IsA("GuiObject") and buildingTabFullSize then
			buildingTab.Size = buildingTabFullSize
		end

		if
			not toolBar
			or not toolBar:IsA("GuiObject")
			or not toolBarOpenPosition
			or not toolBarClosedPosition
			or not (pageContainer and pageContainer:IsA("GuiObject"))
		then
			completePendingSellModeVisualReset()
			return
		end

		if pagePadding then
			pagePadding.PaddingLeft = PAGE_PADDING_LEFT
		end

		local showToolBar = ctx.getCurrentCategory() == "Building"

		if layoutTarget == nil then
			layoutTarget = showToolBar
			toolBar.Position = showToolBar and toolBarOpenPosition or toolBarClosedPosition
			toolBar.Visible = showToolBar
			pageContainer.Position, pageContainer.Size = getPageContainerLayout(showToolBar)
			if not showToolBar then
				completePendingSellModeVisualReset()
			end
			return
		end

		if layoutTarget == showToolBar then
			if showToolBar or not toolBar.Visible then
				completePendingSellModeVisualReset()
			end
			return
		end
		layoutTarget = showToolBar

		layoutToken += 1
		local token = layoutToken
		for _, tween in ipairs(layoutTweens) do
			tween:Cancel()
		end
		table.clear(layoutTweens)

		if showToolBar then
			toolBar.Visible = true
			toolBar.Position = toolBarClosedPosition
		end

		local tweenInfo = showToolBar and TOOLBAR_REVEAL_OPEN_INFO or TOOLBAR_REVEAL_CLOSE_INFO
		local toolBarTween = TweenService:Create(toolBar, tweenInfo, {
			Position = showToolBar and toolBarOpenPosition or toolBarClosedPosition,
		})
		local pagePosition, pageSize = getPageContainerLayout(showToolBar)
		local pageTween = TweenService:Create(pageContainer, tweenInfo, {
			Position = pagePosition,
			Size = pageSize,
		})
		table.insert(layoutTweens, toolBarTween)
		table.insert(layoutTweens, pageTween)
		toolBarTween:Play()
		pageTween:Play()

		if not showToolBar then
			toolBarTween.Completed:Connect(function(playbackState)
				if token == layoutToken and playbackState == Enum.PlaybackState.Completed then
					toolBar.Visible = false
					completePendingSellModeVisualReset()
				end
			end)
		elseif pendingSellModeVisualReset then
			completePendingSellModeVisualReset()
		end
	end

	return {
		update = update,
		markSellModeVisualResetPending = function()
			pendingSellModeVisualReset = true
		end,
	}
end

return StoreToolbarLayout
