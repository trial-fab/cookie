-- StoreLayout: store sizing, scroll fit, and viewport-driven auto-resize math. Owns the
-- UIScale (mobile vs desktop) and snaps the store height to the number of rows that fit on
-- screen. The orchestrator calls applyStoreScale / snapStoreToRows / getMaxVisibleRows;
-- StoreCookieStats reads getStoreScale. Pure layout math otherwise — no row/data state.
local Workspace = game:GetService("Workspace")
local MobileScale = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MobileScale"))

local DEFAULT_ITEM_ROW_HEIGHT = 100
local DEFAULT_STORE_SCALE = 1
local MOBILE_STORE_SCALE = 0.74
local MOBILE_STORE_Y_OFFSET = 64
local MOBILE_STORE_MAX_HEIGHT = 100000
local ROW_FIT_TOLERANCE = 0.1

local StoreLayout = {}

function StoreLayout.new(ctx)
	local store = ctx.store
	local pageContainer = ctx.pageContainer
	local storeScale = ctx.storeScale
	local baseStoreSize = ctx.baseStoreSize
	local baseStorePosition = ctx.baseStorePosition
	local basePageContainerSize = ctx.basePageContainerSize
	local baseStoreMinSize = ctx.baseStoreMinSize
	local baseStoreMaxSize = ctx.baseStoreMaxSize
	-- reassigned by applyStoreScale once the constraint is found
	local storeSizeConstraint = ctx.storeSizeConstraint

	local M = {}

	local function getRowHeight(row)
		if row and row:IsA("GuiObject") then
			if row.Size.Y.Offset ~= 0 then
				return row.Size.Y.Offset
			end
			if row.AbsoluteSize.Y > 0 then
				return row.AbsoluteSize.Y / math.max(storeScale.Scale, 0.01)
			end
		end

		return DEFAULT_ITEM_ROW_HEIGHT
	end

	local function getTemplateForCategory(category)
		if category == "Building" then
			return ctx.templateBuilding
		elseif category == "Robux" then
			return ctx.templateRobuxProduct or ctx.templateUpgrade
		end

		return ctx.templateUpgrade
	end

	local function getUDimPixels(value, parentPixels)
		return value.Scale * parentPixels + value.Offset
	end

	local function getStoreVerticalPadding(storeHeight)
		local padding = store:FindFirstChildWhichIsA("UIPadding")
		if not padding or storeHeight <= 0 then
			return 0
		end

		return getUDimPixels(padding.PaddingTop, storeHeight) + getUDimPixels(padding.PaddingBottom, storeHeight)
	end

	local function getStoreScale()
		return math.max(storeScale.Scale, 0.01)
	end
	M.getStoreScale = getStoreScale

	-- Viewport read + the touch/short-side mobile predicate are shared (Shared/MobileScale)
	-- so there is one source of that logic; this sidebar keeps its own 0.74/1 scale constants.
	local function getViewportSize()
		return MobileScale.getViewportSize(store)
	end

	local function shouldUseMobileStoreScale()
		return MobileScale.shouldUseMobile(store)
	end

	local function applyStoreScale()
		local useMobileLayout = shouldUseMobileStoreScale()
		storeScale.Scale = useMobileLayout and MOBILE_STORE_SCALE or DEFAULT_STORE_SCALE

		if store:IsA("GuiObject") then
			store.Position = useMobileLayout
				and UDim2.new(baseStorePosition.X.Scale, baseStorePosition.X.Offset, 0, MOBILE_STORE_Y_OFFSET)
				or baseStorePosition
		end

		local sizeConstraint = storeSizeConstraint or store:FindFirstChildWhichIsA("UISizeConstraint")
		if sizeConstraint then
			storeSizeConstraint = sizeConstraint
			if useMobileLayout then
				local minX = baseStoreMinSize and baseStoreMinSize.X or sizeConstraint.MinSize.X
				local maxX = baseStoreMaxSize and baseStoreMaxSize.X or sizeConstraint.MaxSize.X
				sizeConstraint.MinSize = Vector2.new(minX, 0)
				sizeConstraint.MaxSize = Vector2.new(maxX > 0 and maxX or MOBILE_STORE_MAX_HEIGHT, MOBILE_STORE_MAX_HEIGHT)
			else
				if baseStoreMinSize then
					sizeConstraint.MinSize = baseStoreMinSize
				end
				if baseStoreMaxSize then
					sizeConstraint.MaxSize = baseStoreMaxSize
				end
			end
		end
	end
	M.applyStoreScale = applyStoreScale

	local function getAvailableStoreHeight()
		if not store:IsA("GuiObject") then
			return 0
		end

		local viewportHeight = 0
		local parent = store.Parent
		if parent and parent:IsA("GuiObject") and parent.AbsoluteSize.Y > 0 then
			viewportHeight = parent.AbsoluteSize.Y
		else
			local camera = Workspace.CurrentCamera
			if camera and camera.ViewportSize.Y > 0 then
				viewportHeight = camera.ViewportSize.Y
			else
				viewportHeight = store.AbsoluteSize.Y / getStoreScale()
			end
		end

		if viewportHeight > 0 then
			if shouldUseMobileStoreScale() then
				return math.max(0, (viewportHeight - MOBILE_STORE_Y_OFFSET) / getStoreScale())
			end

			local storeTop = getUDimPixels(baseStorePosition.Y, viewportHeight)
			local availableHeight = math.max(0, (viewportHeight - storeTop) / getStoreScale())

			local sizeConstraint = store:FindFirstChildWhichIsA("UISizeConstraint")
			if sizeConstraint then
				if sizeConstraint.MaxSize.Y > 0 then
					availableHeight = math.min(availableHeight, sizeConstraint.MaxSize.Y)
				end
			end

			return availableHeight
		end

		local availableHeight = getUDimPixels(baseStoreSize.Y, viewportHeight)
		local sizeConstraint = store:FindFirstChildWhichIsA("UISizeConstraint")
		if sizeConstraint then
			if sizeConstraint.MaxSize.Y > 0 then
				availableHeight = math.min(availableHeight, sizeConstraint.MaxSize.Y)
			end
		end

		return availableHeight
	end

	local function getPageHeightForStoreHeight(storeHeight)
		local storeContentHeight = math.max(0, storeHeight - getStoreVerticalPadding(storeHeight))
		return getUDimPixels(basePageContainerSize.Y, storeContentHeight)
	end

	local function getAvailablePageHeight()
		return getPageHeightForStoreHeight(getAvailableStoreHeight())
	end

	local function getPageBaselineHeight()
		if not pageContainer:IsA("GuiObject") then
			return 0
		end

		local parent = pageContainer.Parent
		if parent and parent:IsA("GuiObject") and parent.AbsoluteSize.Y > 0 then
			return getUDimPixels(basePageContainerSize.Y, parent.AbsoluteSize.Y / getStoreScale())
		end

		return pageContainer.AbsoluteSize.Y / getStoreScale()
	end

	local function getPagePaddingPixels(pageHeight)
		local padding = pageContainer:FindFirstChildWhichIsA("UIPadding")
		pageHeight = pageHeight or getPageBaselineHeight()
		if not padding or pageHeight <= 0 then
			return 0
		end

		return getUDimPixels(padding.PaddingTop, pageHeight) + getUDimPixels(padding.PaddingBottom, pageHeight)
	end

	local function getRowGap(pageHeight)
		local layout = pageContainer:FindFirstChildWhichIsA("UIListLayout")
		if not layout then
			return 0
		end

		return getUDimPixels(layout.Padding, pageHeight or getPageBaselineHeight())
	end

	local getPageHeightForRows

	local function getMaxVisibleRows()
		local pageHeight = getAvailablePageHeight()
		local availableHeight = pageHeight - getPagePaddingPixels(pageHeight)
		if availableHeight <= 0 then
			return 1
		end

		local rowHeight = getRowHeight(getTemplateForCategory(ctx.getCurrentCategory()))
		if rowHeight <= 0 then
			rowHeight = DEFAULT_ITEM_ROW_HEIGHT
		end

		local gap = getRowGap(pageHeight)
		local rowCount
		if gap > 0 then
			rowCount = math.max(1, math.floor((availableHeight + gap + ROW_FIT_TOLERANCE) / (rowHeight + gap)))
		else
			rowCount = math.max(1, math.floor((availableHeight + ROW_FIT_TOLERANCE) / rowHeight))
		end

		while rowCount > 1 and getPageHeightForRows(rowCount, pageHeight) > pageHeight + ROW_FIT_TOLERANCE do
			rowCount -= 1
		end

		return rowCount
	end
	M.getMaxVisibleRows = getMaxVisibleRows

	getPageHeightForRows = function(rowCount, pageHeight)
		local rowHeight = getRowHeight(getTemplateForCategory(ctx.getCurrentCategory()))
		if rowHeight <= 0 then
			rowHeight = DEFAULT_ITEM_ROW_HEIGHT
		end

		pageHeight = pageHeight or getAvailablePageHeight()
		local gap = getRowGap(pageHeight)
		return getPagePaddingPixels(pageHeight) + rowCount * rowHeight + math.max(0, rowCount - 1) * gap
	end

	local function getStoreHeightForPageHeight(pageHeight)
		if math.abs(basePageContainerSize.Y.Scale) > 0.0001 then
			local storeContentHeight = (pageHeight - basePageContainerSize.Y.Offset) / basePageContainerSize.Y.Scale
			local padding = store:FindFirstChildWhichIsA("UIPadding")
			if not padding then
				return storeContentHeight
			end

			local paddingScale = padding.PaddingTop.Scale + padding.PaddingBottom.Scale
			local paddingOffset = padding.PaddingTop.Offset + padding.PaddingBottom.Offset
			local storeScaleFactor = math.max(0.0001, 1 - paddingScale)
			return (storeContentHeight + paddingOffset) / storeScaleFactor
		end

		return getAvailableStoreHeight()
	end

	local function snapStoreToRows(rowCount)
		if not (store:IsA("GuiObject") and pageContainer:IsA("GuiObject")) then
			return
		end

		pageContainer.Size = basePageContainerSize

		local availableStoreHeight = getAvailableStoreHeight()
		local useMobileLayout = shouldUseMobileStoreScale()
		local targetPageHeight = getPageHeightForRows(math.max(1, rowCount))
		local targetStoreHeight = getStoreHeightForPageHeight(targetPageHeight)
		if availableStoreHeight > 0 then
			targetStoreHeight = math.min(targetStoreHeight, availableStoreHeight)
		end

		if not useMobileLayout then
			local sizeConstraint = store:FindFirstChildWhichIsA("UISizeConstraint")
			if sizeConstraint then
				if sizeConstraint.MaxSize.Y > 0 then
					targetStoreHeight = math.min(targetStoreHeight, sizeConstraint.MaxSize.Y)
				end
			end
		end

		targetStoreHeight = math.max(0, math.floor(targetStoreHeight + 0.5))

		local currentSize = store.Size
		if currentSize.Y.Scale == 0 and math.abs(currentSize.Y.Offset - targetStoreHeight) < 0.5 then
			return
		end

		store.Size = UDim2.new(baseStoreSize.X.Scale, baseStoreSize.X.Offset, 0, targetStoreHeight)
	end
	M.snapStoreToRows = snapStoreToRows

	return M
end

return StoreLayout
