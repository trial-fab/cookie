-- StoreUpgradeNudge: a small callout on building rows whenever that building has
-- an unlocked, unowned building upgrade available in the Upgrades tab.
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))
local TweenService = game:GetService("TweenService")

local StoreUpgradeNudge = {}

local NUDGE_NAME = "UpgradeNudge"
local CIRCLE_IMAGE = "rbxassetid://107794869621542"
local DEFAULT_TEMPLATE_STROKE_COLOR = Color3.fromRGB(0, 170, 255)
local SELL_STROKE_COLOR = Color3.fromRGB(255, 75, 75)
local PULSE_TWEEN_INFO = TweenInfo.new(1.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false, 0.15)
local PULSE_START_TRANSPARENCY = 0.45
local PULSE_TARGET_TRANSPARENCY = 1

function StoreUpgradeNudge.new(ctx)
	local UpgradeConfig = ctx.UpgradeConfig
	local screenGui = ctx.screenGui
	local buildingUpgradeByTarget = {}
	local boundNudges = setmetatable({}, { __mode = "k" })
	local targetUpgradeByNudge = setmetatable({}, { __mode = "k" })
	local clickActionByNudge = setmetatable({}, { __mode = "k" })
	local pulseTweensByNudge = setmetatable({}, { __mode = "k" })
	local pulseBaseSizeByNudge = setmetatable({}, { __mode = "k" })
	local baseStrokeColorByRow = setmetatable({}, { __mode = "k" })

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
		return
			math.abs(color.R - SELL_STROKE_COLOR.R) < 0.02
			and math.abs(color.G - SELL_STROKE_COLOR.G) < 0.02
			and math.abs(color.B - SELL_STROKE_COLOR.B) < 0.02
	end

	local function findNudgeStrokeColor(nudge)
		local stroke = nudge and nudge:FindFirstChildWhichIsA("UIStroke", true)
		return stroke and stroke.Color or nil
	end

	local function getTemplateStrokeColor(row, nudge)
		local stroke = row:FindFirstChildWhichIsA("UIStroke")
		if not stroke then
			stroke = row:FindFirstChildWhichIsA("UIStroke", true)
		end

		if ctx.isSellMode() then
			return SELL_STROKE_COLOR
		end

		if stroke and not isSellStrokeColor(stroke.Color) then
			baseStrokeColorByRow[row] = stroke.Color
			return stroke.Color
		end

		return baseStrokeColorByRow[row] or findNudgeStrokeColor(nudge) or DEFAULT_TEMPLATE_STROKE_COLOR
	end

	local function stopPulse(nudge)
		local tween = pulseTweensByNudge[nudge]
		if tween then
			tween:Cancel()
			pulseTweensByNudge[nudge] = nil
		end
	end

	local function configureCircle(circle, color)
		circle.Image = CIRCLE_IMAGE
		circle.ImageColor3 = color
		circle.BackgroundTransparency = 1
		circle.AnchorPoint = Vector2.new(0.5, 0.5)
		circle.Position = UDim2.fromScale(0.5, 0.5)
	end

	local function startPulse(row, nudge)
		local mainCircle = findCircle(nudge, { "MainCircle", "CircleMain", "Circle" })
		local pulseCircle = findCircle(nudge, { "PulseCircle", "CirclePulse", "Pulse" })
		if not mainCircle or not pulseCircle then
			return
		end

		stopPulse(nudge)

		local color = getTemplateStrokeColor(row, nudge)
		configureCircle(mainCircle, color)
		configureCircle(pulseCircle, color)
		mainCircle.ImageTransparency = 0
		pulseCircle.ImageTransparency = PULSE_START_TRANSPARENCY
		pulseCircle.Size = pulseBaseSizeByNudge[nudge] or pulseCircle.Size
		pulseBaseSizeByNudge[nudge] = pulseCircle.Size

		local tween = TweenService:Create(pulseCircle, PULSE_TWEEN_INFO, {
			ImageTransparency = PULSE_TARGET_TRANSPARENCY,
			Size = UDim2.fromScale(1, 1),
		})
		pulseTweensByNudge[nudge] = tween
		tween:Play()
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

		if ctx.affordance and ctx.affordance.getPurchaseBlock and ctx.affordance.getPurchaseBlock(upgradeId, config) then
			return nil
		end

		return upgradeId
	end

	local function setHidden(row)
		local nudge = findNudge(row)
		if nudge then
			stopPulse(nudge)
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
				stopPulse(nudge)
				nudge.Visible = false
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
		targetUpgradeByNudge[nudge] = targetUpgradeId
		clickActionByNudge[nudge] = clickAction
		nudge.Visible = true
		startPulse(row, nudge)
	end

	return M
end

return StoreUpgradeNudge
