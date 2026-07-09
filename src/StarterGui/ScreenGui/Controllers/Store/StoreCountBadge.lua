-- StoreCountBadge: shows the Studio-authored cookieCount badge only after an item is
-- owned. cookieCount stays in the Studio-authored layout, but its X size tweens from
-- zero to its authored width so centered layouts can smoothly re-center the cost/count
-- group. The row's AffordBar is pinned to cookieCost's width in every state so the fill
-- always builds up across the cost from the left edge to the right edge; it never widens to
-- include the count badge.
local TweenService = game:GetService("TweenService")

local COUNT_BADGE_IN_INFO = TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local COUNT_BADGE_OUT_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)

local StoreCountBadge = {}

function StoreCountBadge.new(_ctx)
	local badgesByRow = setmetatable({}, { __mode = "k" })

	local function findChildIgnoreCase(parent, childName)
		if not parent then
			return nil
		end

		local targetName = string.lower(childName)
		for _, child in ipairs(parent:GetChildren()) do
			if string.lower(child.Name) == targetName then
				return child
			end
		end

		return nil
	end

	local function findDescendantIgnoreCase(parent, descendantName)
		local targetName = string.lower(descendantName)
		for _, descendant in ipairs(parent:GetDescendants()) do
			if string.lower(descendant.Name) == targetName then
				return descendant
			end
		end

		return nil
	end

	-- +4px width covers cookieCost's UIStroke, which extends past each edge, so the bar spans
	-- the full stroked cost rather than stopping short inside it.
	local AFFORD_BAR_STROKE_PADDING = 4

	local function getCollapsedAffordBarSize(affordBar, cookieCost)
		local expanded = affordBar.Size
		if cookieCost and cookieCost:IsA("GuiObject") then
			if affordBar.Parent == cookieCost then
				return UDim2.new(1, AFFORD_BAR_STROKE_PADDING, expanded.Y.Scale, expanded.Y.Offset)
			end

			if affordBar.Parent == cookieCost.Parent then
				return UDim2.new(
					cookieCost.Size.X.Scale,
					cookieCost.Size.X.Offset + AFFORD_BAR_STROKE_PADDING,
					expanded.Y.Scale,
					expanded.Y.Offset
				)
			end
		end

		return expanded
	end

	local function getBadge(row)
		local cached = badgesByRow[row]
		if cached and cached.missing then
			return nil
		end
		if cached and cached.cookieCount.Parent then
			return cached
		end

		local list = row:FindFirstChild("List")
		local cookieTab = findChildIgnoreCase(list, "cookieTab") or findDescendantIgnoreCase(row, "cookieTab")
		local cookieCost = cookieTab and findChildIgnoreCase(cookieTab, "cookieCost") or findDescendantIgnoreCase(row, "cookieCost")
		local cookieCount = cookieTab and findChildIgnoreCase(cookieTab, "cookieCount") or findDescendantIgnoreCase(row, "cookieCount")

		if not cookieCount or not cookieCount:IsA("GuiObject") then
			badgesByRow[row] = { missing = true }
			return nil
		end
		if cookieCost and not cookieCost:IsA("GuiObject") then
			cookieCost = nil
		end

		local affordBar = cookieCost and findChildIgnoreCase(cookieCost, "AffordBar") or nil
		if not affordBar then
			affordBar = findDescendantIgnoreCase(row, "AffordBar")
		end
		if affordBar and not affordBar:IsA("GuiObject") then
			affordBar = nil
		end

		local countFrame = findChildIgnoreCase(cookieCount, "countFrame")
		local countLabel = countFrame and findChildIgnoreCase(countFrame, "Count") or findDescendantIgnoreCase(cookieCount, "Count")
		if countLabel and not (countLabel:IsA("TextLabel") or countLabel:IsA("TextButton")) then
			countLabel = nil
		end

		-- Pin the AffordBar to cookieCost's width in both states (never widen to include the
		-- count badge) so the affordability fill always builds up across the cost, left to right.
		local affordBarSize = affordBar and getCollapsedAffordBarSize(affordBar, cookieCost) or nil

		local badge = {
			cookieCount = cookieCount,
			countLabel = countLabel,
			affordBar = affordBar,
			collapsedCookieCountSize = UDim2.new(0, 0, cookieCount.Size.Y.Scale, cookieCount.Size.Y.Offset),
			expandedCookieCountSize = cookieCount.Size,
			collapsedAffordBarSize = affordBarSize,
			expandedAffordBarSize = affordBarSize,
			initialized = false,
			showing = nil,
			tweens = {},
			token = 0,
		}
		cookieCount.ClipsDescendants = true
		badgesByRow[row] = badge
		return badge
	end

	local function cancelTween(badge)
		badge.token += 1
		for _, tween in ipairs(badge.tweens) do
			tween:Cancel()
		end
		table.clear(badge.tweens)
		return badge.token
	end

	local function playTween(badge, object, tweenInfo, goal)
		local tween = TweenService:Create(object, tweenInfo, goal)
		table.insert(badge.tweens, tween)
		tween:Play()
		return tween
	end

	local function setAffordBarExpanded(badge, expanded, animate, tweenInfo)
		if not badge.affordBar or not badge.affordBar.Parent then
			return
		end

		local target = expanded and badge.expandedAffordBarSize or badge.collapsedAffordBarSize
		if not target then
			return
		end

		if animate then
			playTween(badge, badge.affordBar, tweenInfo, { Size = target })
		else
			badge.affordBar.Size = target
		end
	end

	local function setBadgeVisible(badge, show)
		if badge.showing == show and badge.initialized then
			return
		end

		local cookieCount = badge.cookieCount
		local animate = badge.initialized
		local token = cancelTween(badge)
		badge.initialized = true
		badge.showing = show

		if show then
			cookieCount.Visible = true
			if not animate then
				cookieCount.Size = badge.expandedCookieCountSize
				setAffordBarExpanded(badge, true, false)
				return
			end

			cookieCount.Size = badge.collapsedCookieCountSize
			setAffordBarExpanded(badge, false, false)
			playTween(badge, cookieCount, COUNT_BADGE_IN_INFO, {
				Size = badge.expandedCookieCountSize,
			})
			setAffordBarExpanded(badge, true, true, COUNT_BADGE_IN_INFO)
			return
		end

		if not animate then
			cookieCount.Size = badge.collapsedCookieCountSize
			cookieCount.Visible = false
			setAffordBarExpanded(badge, false, false)
			return
		end

		local countTween = playTween(badge, cookieCount, COUNT_BADGE_OUT_INFO, {
			Size = badge.collapsedCookieCountSize,
		})
		setAffordBarExpanded(badge, false, true, COUNT_BADGE_OUT_INFO)
		countTween.Completed:Connect(function(playbackState)
			if token ~= badge.token or playbackState ~= Enum.PlaybackState.Completed then
				return
			end

			cookieCount.Visible = false
			table.clear(badge.tweens)
		end)
	end

	local function updateRow(row, count, countText)
		if not row or not row:IsA("GuiObject") then
			return
		end

		local badge = getBadge(row)
		if not badge then
			return
		end

		if badge.countLabel and badge.countLabel.Parent and type(countText) == "string" then
			badge.countLabel.Text = countText
		end

		setBadgeVisible(badge, type(count) == "number" and count > 0)
	end

	return {
		updateRow = updateRow,
	}
end

return StoreCountBadge
