-- StoreAffordance — §9 "near-miss" affordability chrome + blocked-tap feedback.
--
--   • getRowAffordability: affordable(bool), progress(0..1), lockText — the single source of
--     truth for whether a row's next purchase is reachable and how close it is.
--   • updateRowAffordability: drives the AffordBar (progress silhouette) and fades every blue
--     (0,170,255) accent in a row when the next purchase is out of reach; in sell mode it
--     recolours the accents red instead.
--   • getLockedRequirement: the gating building + owned/required counts for a locked row
--     (mirrors UpgradeService.Purchase). Shared by the affordance chrome and getPurchaseBlock.
--   • getPurchaseBlock: which explanatory widget ("Requirement"/"cookieCost") blocks a buy tap.
--   • flashNumberText / pulseRequirementPreview: the red flash + preview pulse on a blocked tap.
--
-- Extracted from StoreController's main chunk (Luau 200-local cap). The orchestrator reaches
-- it through ctx.affordance.* — no top-level re-aliases (see WORKFLOW.md "Code organization").
--
-- ctx deps: getOwnedCount, getUpgradeCost, UpgradeConfig, cookiesValue, setText,
-- rowsByUpgradeId, isSellMode, isBuildingLocked.

local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))

-- The fade is applied as a SOLID pre-blended colour (= what one 0.6-transparent blue over the
-- dark panel composites to), not stacked transparency, so overlapping filler frames read as one
-- uniform layer instead of doubling up darker.
local NEAR_MISS = {
	BLUE = Color3.fromRGB(0, 170, 255),
	SELL_RED = Color3.fromRGB(255, 75, 75), -- matches SELL_ICON_ACTIVE_COLOR in StoreController
	FADE = 0.6,
	PANEL = Color3.fromRGB(17, 19, 27),
}
NEAR_MISS.FADED_BLUE = NEAR_MISS.PANEL:Lerp(NEAR_MISS.BLUE, 1 - NEAR_MISS.FADE)
local BLUE_ACCENT_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ── blocked-tap feedback ─────────────────────────────────────────────────────
local REQUIREMENT_PREVIEW_PULSE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
local REQUIREMENT_PREVIEW_PULSE_SCALE = 1.06
local NUMBER_FLASH_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local NUMBER_FLASH_COLOR = Color3.fromRGB(255, 72, 72)

local function isNearMissBlue(color)
	return math.abs(color.R - 0) < 0.02 and math.abs(color.G - 0.666667) < 0.02 and math.abs(color.B - 1) < 0.02
end

local function isInsideUpgradeNudge(object)
	return object.Name == "UpgradeNudge" or object:FindFirstAncestor("UpgradeNudge") ~= nil
end

local StoreAffordance = {}

function StoreAffordance.new(ctx)
	local getOwnedCount = ctx.getOwnedCount
	local getUpgradeCost = ctx.getUpgradeCost
	local UpgradeConfig = ctx.UpgradeConfig
	local cookiesValue = ctx.cookiesValue
	local setText = ctx.setText
	local rowsByUpgradeId = ctx.rowsByUpgradeId

	-- Gating building + owned/required for a locked row (nil,nil,nil when unlocked).
	local function getLockedRequirement(upgradeId, config, nextLevel)
		local requirement = config.UnlockRequirement
		if type(requirement) == "table" then
			local requiredId = requirement.Building or requirement.TargetBuilding
			local requiredCount = requirement.Count or 1
			local ownedCount = type(requiredId) == "string" and getOwnedCount(requiredId) or 0
			if type(requiredId) == "string" and requiredCount > 0 and ownedCount < requiredCount then
				return requiredId, requiredCount, ownedCount
			end
		end

		if config.TemplateKind == "BuildingUpgrade" and nextLevel then
			local requiredCount = nextLevel.UnlockCount or 0
			local ownedCount = getOwnedCount(config.TargetBuilding)
			if requiredCount > 0 and ownedCount < requiredCount then
				return config.TargetBuilding, requiredCount, ownedCount
			end
		end

		return nil, nil, nil
	end

	-- Returns affordable(bool), progress(0..1), lockText(string or nil).
	local function getRowAffordability(upgradeId)
		local config = UpgradeConfig[upgradeId]
		if not config then
			return true, 1, nil
		end

		local count = getOwnedCount(upgradeId)

		-- Generic ownership gate (mirrors UpgradeService.Purchase): show how close the
		-- gating building is and mark the row as locked.
		local requirement = config.UnlockRequirement
		if type(requirement) == "table" then
			local requiredId = requirement.Building or requirement.TargetBuilding
			local requiredCount = requirement.Count or 1
			if type(requiredId) == "string" and requiredCount > 0 then
				local owned = getOwnedCount(requiredId)
				if owned < requiredCount then
					return false, math.clamp(owned / requiredCount, 0, 1), "LOCKED"
				end
			end
		end

		-- Leveled building upgrade still below its ownership threshold: the row's Cost
		-- text shows LOCKED while the progress bar tracks the target-building count.
		if config.Levels and config.TemplateKind == "BuildingUpgrade" then
			local nextLevel = config.Levels[count + 1]
			if nextLevel then
				local need = nextLevel.UnlockCount or 0
				if need > 0 then
					local owned = getOwnedCount(config.TargetBuilding)
					if owned < need then
						return false, math.clamp(owned / need, 0, 1), nil
					end
				end
			end
		end

		-- Affordability: progress toward the next purchase cost.
		local cost = getUpgradeCost(upgradeId, count)
		if not cost or cost <= 0 then
			return true, 1, nil -- maxed / free
		end

		local cookies = cookiesValue.Value
		if cookies >= cost then
			return true, 1, nil
		end

		return false, math.clamp(cookies / cost, 0, 1), nil
	end

	-- Binds to the Studio-authored Template > List > cookieTab > cookieCost >
	-- AffordBar > Fill hierarchy on the cloned row. The descendant fallbacks keep the
	-- other store templates working if they place the same widgets at a different depth.
	local affordanceUiByRow = setmetatable({}, { __mode = "k" })
	local function getAffordanceUi(row)
		local cached = affordanceUiByRow[row]
		if cached then
			return cached.bar, cached.fill
		end

		local list = row:FindFirstChild("List")
		local cookieTab = list and list:FindFirstChild("cookieTab")
		local cookieCost = cookieTab and cookieTab:FindFirstChild("cookieCost")
		local bar = cookieCost and cookieCost:FindFirstChild("AffordBar")

		if not bar then
			cookieCost = row:FindFirstChild("cookieCost", true)
			bar = cookieCost and cookieCost:FindFirstChild("AffordBar", true)
		end
		if not bar then
			bar = row:FindFirstChild("AffordBar", true)
		end
		if bar and not bar:IsA("GuiObject") then
			bar = nil
		end

		local fill = bar and bar:FindFirstChild("Fill", true)
		if fill and not fill:IsA("GuiObject") then
			fill = nil
		end

		affordanceUiByRow[row] = { bar = bar, fill = fill }
		return bar, fill
	end

	-- The blue accents to fade are discovered once per row and cached with their
	-- original transparency (the AffordBar/Fill are excluded so the progress bar never
	-- fades). max(orig, FADE) keeps template placeholders that were invisible invisible.
	-- ImageLabel/ImageButton accents use ImageColor3, while borders and UIStrokes have
	-- their own colour properties, so cache those separately from ordinary backgrounds.
	local blueAccentsByRow = setmetatable({}, { __mode = "k" })
	local blueAccentStateByRow = setmetatable({}, { __mode = "k" })
	local blueAccentTweensByRow = setmetatable({}, { __mode = "k" })

	local function getBlueAccents(row)
		local cached = blueAccentsByRow[row]
		if cached then
			return cached
		end

		local accents = { backgrounds = {}, borders = {}, images = {}, strokes = {}, textStrokes = {}, texts = {} }
		local function captureAccent(object)
			if object.Name == "AffordBar" or object:FindFirstAncestor("AffordBar") or isInsideUpgradeNudge(object) then
				return
			end

			if object:IsA("GuiObject") then
				if isNearMissBlue(object.BackgroundColor3) then
					table.insert(accents.backgrounds, {
						object = object,
						originalTransparency = object.BackgroundTransparency,
						originalColor = object.BackgroundColor3,
						-- The Template's own background is a single large tint layer, not a stacked
						-- filler frame, so it must keep its authored transparency instead of the
						-- solid pre-blended fade (which exists only to stop overlapping fillers from
						-- doubling up). Sell-mode red still applies.
						isRowBackground = object == row,
					})
				end
				if isNearMissBlue(object.BorderColor3) then
					table.insert(accents.borders, { object = object, originalColor = object.BorderColor3 })
				end
				if (object:IsA("ImageLabel") or object:IsA("ImageButton")) and isNearMissBlue(object.ImageColor3) then
					table.insert(accents.images, {
						object = object,
						originalTransparency = object.ImageTransparency,
						originalColor = object.ImageColor3,
					})
				end
				if (object:IsA("TextLabel") or object:IsA("TextButton")) and isNearMissBlue(object.TextColor3) then
					table.insert(accents.texts, {
						object = object,
						originalTransparency = object.TextTransparency,
						originalColor = object.TextColor3,
					})
				end
				if (object:IsA("TextLabel") or object:IsA("TextButton")) and isNearMissBlue(object.TextStrokeColor3) then
					table.insert(accents.textStrokes, { object = object, originalColor = object.TextStrokeColor3 })
				end
			elseif object:IsA("UIStroke") and isNearMissBlue(object.Color) then
				table.insert(accents.strokes, { object = object, originalColor = object.Color })
			end
		end

		captureAccent(row)
		for _, descendant in ipairs(row:GetDescendants()) do
			captureAccent(descendant)
		end

		blueAccentsByRow[row] = accents
		return accents
	end

	local function cancelBlueAccentTweens(row)
		local tweens = blueAccentTweensByRow[row]
		if not tweens then
			return
		end

		for _, tween in ipairs(tweens) do
			tween:Cancel()
		end
		table.clear(tweens)
	end

	local function applyBlueAccentGoal(row, object, goal, animate)
		if animate then
			local tweens = blueAccentTweensByRow[row]
			if not tweens then
				tweens = {}
				blueAccentTweensByRow[row] = tweens
			end

			local tween = UiMotion.create(object, BLUE_ACCENT_TWEEN_INFO, goal)
			table.insert(tweens, tween)
			tween:Play()
			return
		end

		for property, value in pairs(goal) do
			object[property] = value
		end
	end

	local function setBlueAccentsState(row, state)
		local previousState = blueAccentStateByRow[row]
		if previousState == state then
			return
		end
		blueAccentStateByRow[row] = state

		cancelBlueAccentTweens(row)
		local animate = state == "sell" or previousState == "sell"
		local accents = getBlueAccents(row)
		for _, entry in ipairs(accents.backgrounds) do
			if entry.object.Parent then
				local color = entry.originalColor
				local transparency = entry.originalTransparency
				if state == "sell" then
					color = NEAR_MISS.SELL_RED
				elseif state == "faded" and entry.originalTransparency < 1 and not entry.isRowBackground then
					-- Solid pre-blended colour at full opacity (so stacked filler frames don't
					-- double up). Placeholders that were invisible (transparency 1) stay so.
					-- The row's own background is skipped so it keeps its authored 0.9 tint.
					color = NEAR_MISS.FADED_BLUE
					transparency = 0
				end
				applyBlueAccentGoal(row, entry.object, {
					BackgroundColor3 = color,
					BackgroundTransparency = transparency,
				}, animate)
			end
		end
		for _, entry in ipairs(accents.borders) do
			if entry.object.Parent then
				local color = entry.originalColor
				if state == "sell" then
					color = NEAR_MISS.SELL_RED
				elseif state == "faded" then
					color = NEAR_MISS.FADED_BLUE
				end
				applyBlueAccentGoal(row, entry.object, { BorderColor3 = color }, animate)
			end
		end
		for _, entry in ipairs(accents.images) do
			if entry.object.Parent then
				local color = entry.originalColor
				if state == "sell" then
					color = NEAR_MISS.SELL_RED
				elseif state == "faded" and entry.originalTransparency < 1 then
					color = NEAR_MISS.FADED_BLUE
				end
				applyBlueAccentGoal(row, entry.object, {
					ImageColor3 = color,
					ImageTransparency = entry.originalTransparency,
				}, animate)
			end
		end
		for _, entry in ipairs(accents.strokes) do
			if entry.object.Parent then
				local color = entry.originalColor
				if state == "sell" then
					color = NEAR_MISS.SELL_RED
				elseif state == "faded" then
					color = NEAR_MISS.FADED_BLUE
				end
				applyBlueAccentGoal(row, entry.object, { Color = color }, animate)
			end
		end
		for _, entry in ipairs(accents.textStrokes) do
			if entry.object.Parent then
				local color = entry.originalColor
				if state == "sell" then
					color = NEAR_MISS.SELL_RED
				elseif state == "faded" then
					color = NEAR_MISS.FADED_BLUE
				end
				applyBlueAccentGoal(row, entry.object, { TextStrokeColor3 = color }, animate)
			end
		end
		for _, entry in ipairs(accents.texts) do
			if entry.object.Parent then
				local color = entry.originalColor
				local transparency = entry.originalTransparency
				if state == "sell" then
					color = NEAR_MISS.SELL_RED
				elseif state == "faded" then
					transparency = math.max(entry.originalTransparency, NEAR_MISS.FADE)
				end
				applyBlueAccentGoal(row, entry.object, {
					TextColor3 = color,
					TextTransparency = transparency,
				}, animate)
			end
		end
	end

	local function setBlueAccentsFaded(row, faded)
		setBlueAccentsState(row, faded and "faded" or "normal")
	end

	local function updateRowAffordability(upgradeId)
		local row = rowsByUpgradeId[upgradeId]
		if not row or not row:IsA("GuiObject") then
			return
		end

		local config = UpgradeConfig[upgradeId]
		local bar, fill = getAffordanceUi(row)

		-- Selling shows refunds, not affordability — keep the near-miss chrome out of it.
		if ctx.isSellMode() then
			if bar then
				bar.Visible = false
			end
			setBlueAccentsState(row, "sell")
			return
		end

		local affordable, progress, lockText = getRowAffordability(upgradeId)

		-- AffordBar sourcing differs by template:
		--   • Template (Building): UNCHANGED — silhouette progress bar shown only while the
		--     building has never been bought, tracking its cookie/unlock progress.
		--   • TemplateUpgrade (non-building): the bar tracks the unlock-requirement BUILDING
		--     count (owned/required), shown only while that gate is unmet, hidden once met.
		local showBar, fillProgress
		if config ~= nil and config.TemplateKind == "Building" then
			showBar = ctx.isBuildingLocked(upgradeId, config)
			fillProgress = progress
		else
			local nextLevel = config and config.Levels and config.Levels[getOwnedCount(upgradeId) + 1] or nil
			local requiredId, requiredCount, ownedCount = getLockedRequirement(upgradeId, config, nextLevel)
			if requiredId and requiredCount and requiredCount > 0 then
				showBar = true
				fillProgress = math.clamp((ownedCount or 0) / requiredCount, 0, 1)
			else
				showBar = false
			end
		end

		if bar then
			bar.Visible = showBar
		end
		if fill and showBar then
			fill.Size = UDim2.fromScale(math.clamp(fillProgress or 0, 0, 1), 1)
		end

		-- Fade the blue accents when the next purchase is out of reach.
		setBlueAccentsFaded(row, not affordable)

		if lockText then
			setText(row, "Cost", lockText)
		end
	end

	-- ── blocked-tap feedback ─────────────────────────────────────────────────────
	-- Blocked buy taps keep the persistent explanation in place. Cookie shortages flash
	-- the visible numbers red; building requirements flash their N/N count and only pulse
	-- the required-building preview.
	local numberFlashStateByText = setmetatable({}, { __mode = "k" })

	local function flashTextObject(textObject)
		if not textObject or not (textObject:IsA("TextLabel") or textObject:IsA("TextButton")) then
			return
		end

		local state = numberFlashStateByText[textObject]
		if not state then
			state = { token = 0, baseColor = textObject.TextColor3, tween = nil }
			numberFlashStateByText[textObject] = state
		end

		state.token += 1
		if state.tween then
			state.tween:Cancel()
		end

		textObject.TextColor3 = NUMBER_FLASH_COLOR
		local token = state.token
		state.tween = UiMotion.create(textObject, NUMBER_FLASH_TWEEN, { TextColor3 = state.baseColor })
		state.tween:Play()
		state.tween.Completed:Connect(function(playbackState)
			if numberFlashStateByText[textObject] ~= state or token ~= state.token then
				return
			end

			if playbackState == Enum.PlaybackState.Completed then
				numberFlashStateByText[textObject] = nil
			end
		end)
	end

	local function flashNumberText(container)
		if not container then
			return
		end

		local function maybeFlash(object)
			if (object:IsA("TextLabel") or object:IsA("TextButton")) and object.Visible and string.find(object.Text, "%d") then
				flashTextObject(object)
			end
		end

		maybeFlash(container)
		for _, descendant in ipairs(container:GetDescendants()) do
			maybeFlash(descendant)
		end
	end

	local function pulseRequirementPreview(requirement)
		if not requirement or not requirement:IsA("GuiObject") or not requirement.Visible then
			return
		end

		local preview = requirement:FindFirstChild("RequirementPreview", true)
		if not preview or not preview:IsA("GuiObject") or not preview.Visible then
			return
		end

		local scale = preview:FindFirstChild("RequirementPreviewPulse")
		if not (scale and scale:IsA("UIScale")) then
			scale = Instance.new("UIScale")
			scale.Name = "RequirementPreviewPulse"
			scale.Scale = 1
			scale.Parent = preview
		end

		scale.Scale = 1
		UiMotion.create(scale, REQUIREMENT_PREVIEW_PULSE_TWEEN, { Scale = REQUIREMENT_PREVIEW_PULSE_SCALE }):Play()
	end

	-- Returns the name of the explanatory widget ("Requirement" / "cookieCost") when a buy
	-- click is blocked, or nil to allow it. Mirrors the gates in UpgradeService.Purchase and
	-- the near-miss chrome so a click can never disagree with what the row is showing.
	local function getPurchaseBlock(upgradeId, config)
		local count = getOwnedCount(upgradeId)
		local nextLevel = config.Levels and config.Levels[count + 1] or nil

		-- Building/ownership requirement (covers UnlockRequirement and BuildingUpgrade levels).
		local requiredId = getLockedRequirement(upgradeId, config, nextLevel)
		if requiredId then
			return "Requirement"
		end

		-- Cookie cost (maxed/free upgrades have no cost and are never blocked here).
		local cost = getUpgradeCost(upgradeId, count)
		if cost and cost > 0 and cookiesValue.Value < cost then
			return "cookieCost"
		end

		return nil
	end

	return {
		getLockedRequirement = getLockedRequirement,
		getRowAffordability = getRowAffordability,
		updateRowAffordability = updateRowAffordability,
		getPurchaseBlock = getPurchaseBlock,
		flashNumberText = flashNumberText,
		pulseRequirementPreview = pulseRequirementPreview,
	}
end

return StoreAffordance
