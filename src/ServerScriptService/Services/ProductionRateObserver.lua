local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProductionRateObserver = {}

local observedMultiplierSources = setmetatable({}, { __mode = "k" })
local refreshPlayer
local initialized = false

local function refreshDeferred(player)
	task.defer(function()
		if refreshPlayer and player.Parent then
			refreshPlayer(player)
		end
	end)
end

local function refreshAll()
	if not refreshPlayer then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player:FindFirstChild("UpgradeCountData") then
			refreshPlayer(player)
		end
	end
end

local function observeMultiplierSource(source)
	if observedMultiplierSources[source] then
		return
	end
	observedMultiplierSources[source] = true

	source.AttributeChanged:Connect(refreshAll)
	source.ChildAdded:Connect(function(child)
		observeMultiplierSource(child)
		refreshAll()
	end)
	source.ChildRemoved:Connect(refreshAll)

	if source:IsA("NumberValue") or source:IsA("IntValue") then
		source:GetPropertyChangedSignal("Value"):Connect(refreshAll)
	end

	for _, child in ipairs(source:GetChildren()) do
		observeMultiplierSource(child)
	end
end

local function observeWorldEventMultipliers()
	local worldEventMultipliers = ReplicatedStorage:FindFirstChild("WorldEventMultipliers")
	if worldEventMultipliers then
		observeMultiplierSource(worldEventMultipliers)
	end

	ReplicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == "WorldEventMultipliers" then
			observeMultiplierSource(child)
			refreshAll()
		end
	end)
end

function ProductionRateObserver.Init(refreshCallback)
	refreshPlayer = refreshCallback
	if initialized then
		return
	end
	initialized = true

	observeWorldEventMultipliers()
end

function ProductionRateObserver.ObservePlayer(player)
	task.spawn(function()
		local upgradeCountData = player:WaitForChild("UpgradeCountData", 30)
		if not upgradeCountData or not player.Parent then
			return
		end

		local function observeValue(child)
			if child:IsA("IntValue") then
				child:GetPropertyChangedSignal("Value"):Connect(function()
					refreshDeferred(player)
				end)
			end
		end

		upgradeCountData.ChildAdded:Connect(function(child)
			observeValue(child)
			refreshDeferred(player)
		end)
		upgradeCountData.ChildRemoved:Connect(function()
			refreshDeferred(player)
		end)

		for _, child in ipairs(upgradeCountData:GetChildren()) do
			observeValue(child)
		end
	end)
end

return ProductionRateObserver
