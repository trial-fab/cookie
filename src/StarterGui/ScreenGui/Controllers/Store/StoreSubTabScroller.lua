-- StoreSubTabScroller: shared smooth horizontal section navigation for Store subtabs.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiMotion = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiMotion"))

local StoreSubTabScroller = {}

function StoreSubTabScroller.new(pageContainer, tweenInfo, setActive)
	local M = {}
	local scrollTween = nil
	local scrollLimitX = nil
	local enforcingScrollLimit = false
	local baseCanvasSize = pageContainer:IsA("ScrollingFrame") and pageContainer.CanvasSize or UDim2.new(0, 0, 0, 0)
	local baseElasticBehavior = pageContainer:IsA("ScrollingFrame") and pageContainer.ElasticBehavior or nil

	local function getWindowWidth()
		return pageContainer.AbsoluteWindowSize.X > 0 and pageContainer.AbsoluteWindowSize.X
			or pageContainer.AbsoluteSize.X
	end

	local function getRightPadding()
		local padding = pageContainer:FindFirstChildOfClass("UIPadding")
		if not padding then
			return 0
		end

		return padding.PaddingRight.Scale * pageContainer.AbsoluteSize.X + padding.PaddingRight.Offset
	end

	local function getItemLeftInset(item)
		local stroke = item:FindFirstChildOfClass("UIStroke")
		return stroke and math.max(0, stroke.Thickness) or 0
	end

	local function getNaturalScrollLimit(currentX, windowWidth)
		local contentRight = 0
		for _, child in ipairs(pageContainer:GetChildren()) do
			if child:IsA("GuiObject") and child.Visible then
				local childRight = child.AbsolutePosition.X
					- pageContainer.AbsolutePosition.X
					+ currentX
					+ child.AbsoluteSize.X
				contentRight = math.max(contentRight, childRight)
			end
		end

		return math.max(0, math.ceil(contentRight + getRightPadding() - windowWidth))
	end

	local function enforceScrollLimit()
		if enforcingScrollLimit or not scrollLimitX or pageContainer.CanvasPosition.X <= scrollLimitX then
			return
		end

		enforcingScrollLimit = true
		pageContainer:ResetScrollVelocity()
		pageContainer.CanvasPosition = Vector2.new(scrollLimitX, pageContainer.CanvasPosition.Y)
		enforcingScrollLimit = false
	end

	if pageContainer:IsA("ScrollingFrame") then
		pageContainer:GetPropertyChangedSignal("CanvasPosition"):Connect(enforceScrollLimit)
	end

	function M.cancel()
		if scrollTween then
			scrollTween:Cancel()
			scrollTween = nil
		end
		if pageContainer:IsA("ScrollingFrame") then
			scrollLimitX = nil
			pageContainer:ResetScrollVelocity()
			pageContainer.CanvasSize = baseCanvasSize
			if baseElasticBehavior then
				pageContainer.ElasticBehavior = baseElasticBehavior
			end
		end
	end

	function M.scrollTo(sectionId, item)
		if not pageContainer:IsA("ScrollingFrame") then
			return
		end
		if not item or not item:IsA("GuiObject") or not item.Visible then
			return
		end

		local current = pageContainer.CanvasPosition
		local itemLeft = item.AbsolutePosition.X - pageContainer.AbsolutePosition.X + current.X
		-- Keep the card's authored border fully inside the clipped viewport. Store cards
		-- currently use a 2px UIStroke, so their visual left edge lands at the leftmost
		-- usable position instead of being clipped at x = 0.
		local targetX = math.max(0, itemLeft - getItemLeftInset(item))
		local windowWidth = getWindowWidth()
		local naturalScrollLimit = getNaturalScrollLimit(current.X, windowWidth)
		local rightmostScrollX = math.max(targetX, naturalScrollLimit)
		local requiredCanvasWidth = math.ceil(rightmostScrollX + windowWidth)
		local target = Vector2.new(targetX, current.Y)

		M.cancel()
		scrollLimitX = rightmostScrollX
		pageContainer.ElasticBehavior = Enum.ElasticBehavior.Never
		pageContainer.CanvasSize = UDim2.new(0, requiredCanvasWidth, baseCanvasSize.Y.Scale, baseCanvasSize.Y.Offset)
		setActive(sectionId)

		local tween = UiMotion.create(pageContainer, tweenInfo, {
			CanvasPosition = target,
		})
		scrollTween = tween
		tween.Completed:Connect(function()
			if scrollTween == tween then
				scrollTween = nil
				setActive(sectionId)
			end
		end)
		tween:Play()
	end

	function M.updateActive(sections, itemSource, sectionIdKey)
		if scrollTween or not pageContainer:IsA("ScrollingFrame") then
			return
		end

		local viewLeft = pageContainer.AbsolutePosition.X
		local bestSection, bestDistance
		for _, section in ipairs(sections) do
			local sectionId = sectionIdKey and section[sectionIdKey] or section
			local item
			if type(itemSource) == "function" then
				item = itemSource(sectionId)
			else
				item = itemSource[sectionId]
			end
			if item and item:IsA("GuiObject") and item.Visible then
				local distance = math.abs(item.AbsolutePosition.X - viewLeft)
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

return StoreSubTabScroller
