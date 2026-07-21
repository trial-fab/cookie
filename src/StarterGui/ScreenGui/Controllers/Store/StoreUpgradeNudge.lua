-- StoreUpgradeNudge: a small callout on building rows whenever that building has
-- an unlocked, unowned building upgrade available in the Upgrades tab.
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))
local ReminderPulse = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ReminderPulse"))
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))

local StoreUpgradeNudge = {}

local NUDGE_NAME = "UpgradeNudge"
local DEFAULT_TEMPLATE_STROKE_COLOR = Color3.fromRGB(0, 170, 255)
local SELL_STROKE_COLOR = Color3.fromRGB(255, 75, 75)

function StoreUpgradeNudge.new(ctx)
	local UpgradeConfig = ctx.UpgradeConfig
	local screenGui = ctx.screenGui
	local buildingUpgradeByTarget = {}
	local boundNudges = setmetatable({}, { __mode = "k" })
	local targetUpgradeByNudge = setmetatable({}, { __mode = "k" })
	local clickActionByNudge = setmetatable({}, { __mode = "k" })
	local rowByNudge = setmetatable({}, { __mode = "k" })
	local pulseTweensByNudge = setmetatable({}, { __mode = "k" })
	local pulseBaseSizeByNudge = setmetatable({}, { __mode = "k" })
	local baseNudgeColorByNudge = setmetatable({}, { __mode = "k" })

	for upgradeId, config in pairs(UpgradeConfig) do
		if config.TemplateKind == "BuildingUpgrade" and type(config.TargetBuilding) == "string" then
			buildingUpgradeByTarget[config.TargetBuilding] = upgradeId
		end
	end

	local M = {}

	local function getOwnedCount(upgradeId)
		return ctx.getOwnedCount and ctx.getOwnedCount(upgradeId) or 0
	end

	local function remindersEnabled()
		return not screenGui or screenGui:GetAttribute(Attrs.UpgradeRemindersEnabled) ~= false
	end

	local function findNudge(row)
		if not row then
			return nil
		end

		local named = row:FindFirstChild(NUDGE_NAME, true)
		if named and named:IsA("GuiButton") then
			return named
		end

		for _, descendant in ipairs(row:GetDescendants()) do
			if descendant.Name == NUDGE_NAME and descendant:IsA("GuiButton") then
				return descendant
			end
		end

		return nil
	end

	local function findCircle(nudge, names)
		for _, name in ipairs(names) do
			local object = nudge:FindFirstChild(name, true)
			if object and (object:IsA("ImageLabel") or object:IsA("ImageButton")) then
				return object
			end
		end

		return nil
	end

	local function isSellStrokeColor(color)
		return math.abs(color.R - SELL_STROKE_COLOR.R) < 0.02
			and math.abs(color.G - SELL_STROKE_COLOR.G) < 0.02
			and math.abs(color.B - SELL_STROKE_COLOR.B) < 0.02
	end

	local function findNudgeStrokeColor(nudge)
		local stroke = nudge and nudge:FindFirstChildWhichIsA("UIStroke", true)
		return stroke and stroke.Color or nil
	end

	local function getTemplateStrokeColor(row, nudge)
		if ctx.isSellMode() then
			return SELL_STROKE_COLOR
		end

		local baseColor = baseNudgeColorByNudge[nudge]
		if not baseColor then
			local authoredColor = findNudgeStrokeColor(nudge)
			baseColor = authoredColor and not isSellStrokeColor(authoredColor) and authoredColor
				or DEFAULT_TEMPLATE_STROKE_COLOR
			baseNudgeColorByNudge[nudge] = baseColor
		end
		return baseColor
	end

	local function stopPulse(nudge)
		local tween = pulseTweensByNudge[nudge]
		if tween then
			ReminderPulse.stop(tween)
			pulseTweensByNudge[nudge] = nil
		end
	end

	local function startPulse(row, nudge)
		local mainCircle = findCircle(nudge, { "MainCircle", "CircleMain", "Circle" })
		local pulseCircle = findCircle(nudge, { "PulseCircle", "CirclePulse", "Pulse" })
		if not mainCircle or not pulseCircle then
			return
		end

		stopPulse(nudge)
		local baseSize = pulseBaseSizeByNudge[nudge] or pulseCircle.Size
		pulseBaseSizeByNudge[nudge] = baseSize
		local color = getTemplateStrokeColor(row, nudge)
		if UiMotion.isReduced(nudge) then
			ReminderPulse.setStatic(mainCircle, pulseCircle, {
				color = color,
			})
			return
		end

		local tween = ReminderPulse.start(mainCircle, pulseCircle, {
			baseSize = baseSize,
			color = color,
		})
		pulseTweensByNudge[nudge] = tween
	end

	if screenGui then
		screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
			for nudge, row in pairs(rowByNudge) do
				if nudge.Parent and nudge.Visible and row.Parent then
					startPulse(row, nudge)
				end
			end
		end)
	end

	local function getAvailableUpgradeId(buildingId)
		local upgradeId = buildingUpgradeByTarget[buildingId]
		local upgradeConfig = upgradeId and UpgradeConfig[upgradeId]
		if not upgradeConfig or type(upgradeConfig.Levels) ~= "table" then
			return nil
		end

		local levelsOwned = getOwnedCount(upgradeId)
		local nextLevel = upgradeConfig.Levels[levelsOwned + 1]
		if not nextLevel then
			return nil
		end

		local needed = nextLevel.UnlockCount or math.huge
		if getOwnedCount(buildingId) < needed then
			return nil
		end

		return upgradeId
	end

	local function getPurchasableBuildingUpgradeId(upgradeId, config)
		if not config or config.TemplateKind ~= "BuildingUpgrade" or type(config.Levels) ~= "table" then
			return nil
		end

		local levelsOwned = getOwnedCount(upgradeId)
		local nextLevel = config.Levels[levelsOwned + 1]
		if not nextLevel then
			return nil
		end

		if
			ctx.affordance
			and ctx.affordance.getPurchaseBlock
			and ctx.affordance.getPurchaseBlock(upgradeId, config)
		then
			return nil
		end

		return upgradeId
	end

	local function setHidden(row)
		local nudge = findNudge(row)
		if nudge then
			stopPulse(nudge)
			rowByNudge[nudge] = nil
			targetUpgradeByNudge[nudge] = nil
			clickActionByNudge[nudge] = nil
			nudge.Visible = false
		end
	end
	M.hideRow = setHidden

	local function bindNudge(nudge)
		if boundNudges[nudge] then
			return
		end
		boundNudges[nudge] = true
		nudge.Activated:Connect(function()
			if clickActionByNudge[nudge] == "openUpgradeCategory" and ctx.openUpgradeCategory then
				-- Clicking only navigates to the available upgrade; it does not consume it.
				-- Keep visibility derived from updateRow so returning to Buildings cannot
				-- leave an active nudge hidden by stale click state.
				ctx.openUpgradeCategory(targetUpgradeByNudge[nudge])
			end
		end)
	end

	function M.updateRow(row, upgradeId)
		local config = UpgradeConfig[upgradeId]
		if not row or not row:IsA("GuiObject") or not config then
			return
		end

		local currentCategory = ctx.getCurrentCategory()
		local targetUpgradeId = nil
		local clickAction = nil
		if config.TemplateKind == "Building" and currentCategory == "Building" then
			targetUpgradeId = getAvailableUpgradeId(upgradeId)
			clickAction = "openUpgradeCategory"
		elseif config.TemplateKind == "BuildingUpgrade" and currentCategory == "Upgrade" then
			targetUpgradeId = getPurchasableBuildingUpgradeId(upgradeId, config)
			clickAction = "none"
		end

		if not remindersEnabled() or not targetUpgradeId then
			setHidden(row)
			return
		end

		local nudge = findNudge(row)
		if not nudge then
			setHidden(row)
			return
		end

		bindNudge(nudge)
		rowByNudge[nudge] = row
		targetUpgradeByNudge[nudge] = targetUpgradeId
		clickActionByNudge[nudge] = clickAction
		nudge.Visible = true
		startPulse(row, nudge)
	end

	return M
end

return StoreUpgradeNudge
