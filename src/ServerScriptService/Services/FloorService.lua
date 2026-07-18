-- FloorService: derives sequential floor ownership from the persisted Base Expansion
-- count and publishes state hooks for later Studio-authored geometry/reveal logic.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attrs = require(Shared.Attrs)
local DevTuning = require(Shared.DevTuning.DevTuning)
local FloorConfig = require(Shared.FloorConfig)
local FloorGeometry = require(Shared.FloorGeometry)
local DevTuningService = require(script.Parent.DevTuningService)
local FloorAnalyticsService = require(script.Parent.FloorAnalyticsService)
local FloorRevealAnimator = require(script.Parent.FloorRevealAnimator)
local PlayerMetricsService = require(script.Parent.PlayerMetricsService)
local SheetService = require(script.Parent.SheetService)

local FloorService = {}
local previewFloorOrderByPlayer = setmetatable({}, { __mode = "k" })
local previewRevealByPlayer = setmetatable({}, { __mode = "k" })

local function getExpansionCountValue(player)
	local upgradeCountData = player and player:FindFirstChild("UpgradeCountData")
	local countValue = upgradeCountData and upgradeCountData:FindFirstChild(FloorConfig.ExpansionUpgradeId)
	return countValue and countValue:IsA("IntValue") and countValue or nil
end

function FloorService.GetUnlockedCount(player)
	local countValue = getExpansionCountValue(player)
	return math.clamp(countValue and countValue.Value or 0, 0, FloorConfig.UnlockableFloorCount)
end

function FloorService.IsUnlocked(player, floorId)
	local definition = FloorConfig.Get(floorId)
	return definition ~= nil and definition.Order <= FloorService.GetUnlockedCount(player)
end

function FloorService.RefreshPlayer(player, animatedFloorId)
	local unlockedCount = FloorService.GetUnlockedCount(player)
	player:SetAttribute(Attrs.UnlockedFloorCount, unlockedCount)

	local sheet = SheetService.GetPlayerSheet(player)
	if not sheet then
		return
	end

	for _, definition in ipairs(FloorConfig.GetDefinitions()) do
		local model = FloorGeometry.GetFloorModel(sheet, definition.Id)
		if model then
			model:SetAttribute(Attrs.FloorId, definition.Id)
			model:SetAttribute(Attrs.FloorOrder, definition.Order)
			model:SetAttribute(Attrs.FloorUnlocked, definition.Order <= unlockedCount)
			FloorRevealAnimator.SetFloorState(
				sheet,
				definition.Id,
				definition.Order <= unlockedCount,
				definition.Id == animatedFloorId
			)
		end
	end
end

-- Called after UpgradeService has incremented the Base Expansion count but before
-- the transaction commits. Returning false makes the generic purchase path roll
-- back the count and refund the already-deducted cookies.
function FloorService.ApplyUnlock(player, floorId, amount)
	if amount <= 0 then
		FloorService.RefreshPlayer(player)
		return true
	end

	local definition = FloorConfig.Get(floorId)
	local countValue = getExpansionCountValue(player)
	if not definition or definition.Order <= 0 or not countValue then
		return false, "Floor data is not ready."
	end
	if countValue.Value ~= definition.Order then
		return false, "Floors must be unlocked in order."
	end

	FloorService.RefreshPlayer(player, definition.Id)
	PlayerMetricsService.RecordFloorUnlocked(player, definition.Order)
	FloorAnalyticsService.RecordFloorUnlocked(player, definition)
	return true
end

function FloorService.SetupPlayer(player)
	FloorService.RefreshPlayer(player)
end

function FloorService.ResetPlayer(player)
	FloorService.RefreshPlayer(player)
end

local function getPreviewFloorOrder(player)
	return previewFloorOrderByPlayer[player]
		or math.round(DevTuning.get("VerticalFloors.PreviewFloorOrder"))
end

local function setPreviewVisual(player, floorOrder, revealed, animate)
	local sheet = SheetService.GetPlayerSheet(player)
	local definition = FloorConfig.GetByOrder(floorOrder)
	if not sheet or not definition or definition.Order <= 0 then
		return
	end
	FloorRevealAnimator.SetFloorState(sheet, definition.Id, revealed, animate)
end

local function restoreOwnedVisual(player, floorOrder)
	setPreviewVisual(player, floorOrder, floorOrder <= FloorService.GetUnlockedCount(player), true)
end

local function setupPreviewControls()
	if not DevTuning.Enabled then
		return
	end

	DevTuningService.ObserveApply("VerticalFloors.PreviewFloorOrder", function(player, value, previousValue)
		local previousOrder = previewFloorOrderByPlayer[player]
			or (type(previousValue) == "number" and math.round(previousValue))
		local nextOrder = math.round(value)
		if previousOrder and previousOrder ~= nextOrder then
			restoreOwnedVisual(player, previousOrder)
		end
		previewFloorOrderByPlayer[player] = nextOrder
		local previewRevealed = previewRevealByPlayer[player]
		if previewRevealed == nil then
			previewRevealed = DevTuning.get("VerticalFloors.PreviewReveal")
		end
		setPreviewVisual(player, nextOrder, previewRevealed, true)
	end)

	DevTuningService.ObserveApply("VerticalFloors.PreviewReveal", function(player, value)
		previewRevealByPlayer[player] = value
		setPreviewVisual(player, getPreviewFloorOrder(player), value, true)
	end)
end

function FloorService.Init()
	FloorRevealAnimator.Init()
	setupPreviewControls()
end

return FloorService
