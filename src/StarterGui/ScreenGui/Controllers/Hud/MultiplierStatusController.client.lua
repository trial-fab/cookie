-- MultiplierStatusController: publishes the player's complete active production sources
-- through the fixed Studio-authored icon slots. No player-facing UI is created here.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local MultiplierHudConfig = require(Shared:WaitForChild("MultiplierHudConfig"))
local MultiplierStatusPresenter = require(script.Parent:WaitForChild("MultiplierStatusPresenter"))
local MultiplierStatusSources = require(script.Parent:WaitForChild("MultiplierStatusSources"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui or screenGui:GetAttribute("MultiplierStatusControllerRunning") == true then
	return
end
screenGui:SetAttribute("MultiplierStatusControllerRunning", true)

local player = Players.LocalPlayer
local presenter = MultiplierStatusPresenter.new(screenGui)
if not presenter then
	return
end

local connections = {}
local observedEventValues = setmetatable({}, { __mode = "k" })
local observedUpgradeValues = setmetatable({}, { __mode = "k" })
local observedHudInstances = setmetatable({}, { __mode = "k" })
local observedSheetFolders = setmetatable({}, { __mode = "k" })
local refreshQueued = false
local destroyed = false
local queueRefresh

local function refresh()
	refreshQueued = false
	if destroyed then
		return
	end
	presenter:applySources(MultiplierStatusSources.get(player))
	local storeOpen = screenGui:GetAttribute(Attrs.StoreOpen) == true
	local buildMode = screenGui:GetAttribute(Attrs.BuildModeActive) == true
	local autoBuild = screenGui:GetAttribute(Attrs.AutoBuildMode) == true
	local placing = screenGui:GetAttribute(Attrs.PlacementActive) == true
	local backgroundSuspended = screenGui:GetAttribute(Attrs.BackgroundSurfacesSuspended) == true
	local storeVisible = (storeOpen or (buildMode and autoBuild)) and not placing and not backgroundSuspended
	presenter:setSuppressed(screenGui:GetAttribute(Attrs.CompactModalActive) == true or storeVisible)
end

local function observeHudInstance(instance)
	if observedHudInstances[instance] then
		return
	end
	if instance:IsA("Model") then
		observedHudInstances[instance] = true
		table.insert(
			connections,
			instance.AttributeChanged:Connect(function(attribute)
				-- Field timers are read directly by the presenter's existing countdown loop.
				-- Rebuilding every production source once per server timer tick would be wasted work.
				if attribute ~= "RemainingSeconds" then
					queueRefresh()
				end
			end)
		)
	elseif instance:IsA("ObjectValue") then
		observedHudInstances[instance] = true
		table.insert(connections, instance:GetPropertyChangedSignal("Value"):Connect(queueRefresh))
	end
end

local function observeSheetFolder(folder)
	if observedSheetFolders[folder] or folder.Name ~= "CookieSheets" then
		return
	end
	observedSheetFolders[folder] = true
	for _, descendant in ipairs(folder:GetDescendants()) do
		observeHudInstance(descendant)
	end
	table.insert(
		connections,
		folder.DescendantAdded:Connect(function(descendant)
			observeHudInstance(descendant)
			queueRefresh()
		end)
	)
	table.insert(connections, folder.DescendantRemoving:Connect(queueRefresh))
	table.insert(connections, folder.ChildAdded:Connect(queueRefresh))
	table.insert(connections, folder.ChildRemoved:Connect(queueRefresh))
end

queueRefresh = function()
	if refreshQueued or destroyed then
		return
	end
	refreshQueued = true
	task.defer(refresh)
end

local function observeEventValue(value)
	if observedEventValues[value] or not (value:IsA("NumberValue") or value:IsA("IntValue")) then
		return
	end
	observedEventValues[value] = true
	table.insert(connections, value:GetPropertyChangedSignal("Value"):Connect(queueRefresh))
	table.insert(connections, value.AttributeChanged:Connect(queueRefresh))
end

local function observeEventFolder(folder)
	if folder.Name ~= MultiplierHudConfig.WorldEventFolderName then
		return
	end
	for _, child in ipairs(folder:GetChildren()) do
		observeEventValue(child)
	end
	table.insert(connections, folder.AttributeChanged:Connect(queueRefresh))
	table.insert(
		connections,
		folder.ChildAdded:Connect(function(child)
			observeEventValue(child)
			queueRefresh()
		end)
	)
	table.insert(connections, folder.ChildRemoved:Connect(queueRefresh))
end

local function observeUpgradeValue(value)
	if observedUpgradeValues[value] or not value:IsA("IntValue") then
		return
	end
	observedUpgradeValues[value] = true
	table.insert(connections, value:GetPropertyChangedSignal("Value"):Connect(queueRefresh))
end

local upgradeCountData = player:WaitForChild("UpgradeCountData", 30)
if upgradeCountData then
	for _, child in ipairs(upgradeCountData:GetChildren()) do
		observeUpgradeValue(child)
	end
	table.insert(
		connections,
		upgradeCountData.ChildAdded:Connect(function(child)
			observeUpgradeValue(child)
			queueRefresh()
		end)
	)
	table.insert(connections, upgradeCountData.ChildRemoved:Connect(queueRefresh))
end

local eventFolder = ReplicatedStorage:FindFirstChild(MultiplierHudConfig.WorldEventFolderName)
if eventFolder then
	observeEventFolder(eventFolder)
end
table.insert(
	connections,
	ReplicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == MultiplierHudConfig.WorldEventFolderName then
			observeEventFolder(child)
			queueRefresh()
		end
	end)
)
table.insert(
	connections,
	ReplicatedStorage.ChildRemoved:Connect(function(child)
		if child.Name == MultiplierHudConfig.WorldEventFolderName then
			queueRefresh()
		end
	end)
)
table.insert(
	connections,
	ReplicatedStorage:GetAttributeChangedSignal(MultiplierHudConfig.ServerBoostEndsAtAttribute):Connect(queueRefresh)
)
table.insert(connections, player:GetAttributeChangedSignal(Attrs.GooSkinMultiplier):Connect(queueRefresh))
table.insert(connections, player:GetAttributeChangedSignal(Attrs.UnlockedFloorCount):Connect(queueRefresh))

for _, attribute in ipairs({
	Attrs.CompactModalActive,
	Attrs.StoreOpen,
	Attrs.BuildModeActive,
	Attrs.AutoBuildMode,
	Attrs.PlacementActive,
	Attrs.BackgroundSurfacesSuspended,
}) do
	table.insert(connections, screenGui:GetAttributeChangedSignal(attribute):Connect(queueRefresh))
end

local sheetFolder = Workspace:FindFirstChild("CookieSheets")
if sheetFolder then
	observeSheetFolder(sheetFolder)
end
table.insert(
	connections,
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "CookieSheets" then
			observeSheetFolder(child)
			queueRefresh()
		end
	end)
)
table.insert(
	connections,
	Workspace.ChildRemoved:Connect(function(child)
		if child.Name == "CookieSheets" then
			queueRefresh()
		end
	end)
)

screenGui.Destroying:Once(function()
	destroyed = true
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	presenter:destroy()
end)

task.spawn(function()
	while not destroyed and screenGui.Parent do
		task.wait(DevTuning.get("MultiplierHud.CountdownRefreshSeconds"))
		presenter:refreshCountdowns()
	end
end)

refresh()
