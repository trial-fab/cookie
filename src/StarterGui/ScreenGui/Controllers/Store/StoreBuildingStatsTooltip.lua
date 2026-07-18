-- StoreBuildingStatsTooltip: independent world inspection for owned placed buildings.
-- Mouse users dwell on one building before it highlights and publishes stats beside the
-- cursor. Touch users must tap the building directly; their tooltip stays projected above
-- that building until the next tap. Store Stats Eye state intentionally does not gate this.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BuildingInspectionConfig = require(Shared:WaitForChild("BuildingInspectionConfig"))
local CursorTooltipTuning = require(Shared:WaitForChild("CursorTooltipTuning"))

local StoreBuildingStatsTooltip = {}

local MAX_RAY_DISTANCE = 2048

local function isVisibleGuiSurface(object)
	if object:IsA("GuiButton") or object:IsA("TextBox") or object:IsA("ScrollingFrame") then
		return true
	end
	if object.BackgroundTransparency < 1 then
		return true
	end
	if (object:IsA("TextLabel") or object:IsA("TextButton")) and object.TextTransparency < 1 then
		return object.Text ~= ""
	end
	if (object:IsA("ImageLabel") or object:IsA("ImageButton")) and object.ImageTransparency < 1 then
		return object.Image ~= ""
	end
	return false
end

function StoreBuildingStatsTooltip.new(ctx)
	local source = ctx.cursorTooltip
		and ctx.cursorTooltip:createSource({ priority = ctx.cursorTooltip.Priority.BuildingStats })
	if not source then
		return {
			destroy = function() end,
		}
	end

	local player = ctx.player
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local mouse = ctx.mouse
	local tooltipRoot = ctx.screenGui:FindFirstChild("CursorTooltip")
	local connections = {}
	local hoverCandidate = nil
	local hoverGeneration = 0
	local selectedBuilding = nil
	local selectedUpgradeId = nil
	local selectedConfig = nil
	local selectionInput = nil
	local selectedDestroyConnection = nil
	local destroyed = false

	-- An enabled Highlight with no explicit Adornee falls back to its parent. Keep the
	-- prewarmed effect under an empty client-only folder so idle state has no geometry to tint;
	-- parenting it directly to Workspace would implicitly highlight the entire map.
	local effectContainer = Instance.new("Folder")
	effectContainer.Name = "BuildingInspectionEffects"
	effectContainer.Parent = Workspace

	local highlight = Instance.new("Highlight")
	highlight.Name = "BuildingInspectionHighlight"
	highlight.Adornee = nil
	highlight.FillColor = BuildingInspectionConfig.FillColor
	highlight.FillTransparency = BuildingInspectionConfig.FillTransparency
	highlight.OutlineColor = BuildingInspectionConfig.OutlineColor
	highlight.OutlineTransparency = BuildingInspectionConfig.OutlineTransparency
	highlight.DepthMode = BuildingInspectionConfig.DepthMode
	-- Keep the renderer's Highlight pass warm while idle. Adornee=nil displays nothing;
	-- assigning a building no longer enables a fresh pass in the same frame, which avoids the
	-- one-frame full-screen flash seen under Build View's Scriptable camera.
	highlight.Enabled = true
	highlight.Parent = effectContainer

	local function pointerIsOverUiAt(x, y, ignoreTooltip)
		for _, object in ipairs(playerGui:GetGuiObjectsAtPosition(x, y)) do
			if
				(not ignoreTooltip or not tooltipRoot or not object:IsDescendantOf(tooltipRoot))
				and isVisibleGuiSurface(object)
			then
				return true
			end
		end
		return false
	end

	local function interactionIsBlocked()
		return ctx.screenGui:GetAttribute(ctx.Attrs.PlacementActive) == true or (ctx.isSellMode and ctx.isSellMode())
	end

	local function findOwnedBuilding(target)
		local current = target
		while current and current ~= Workspace do
			if current:IsA("Model") then
				local upgradeId = current:GetAttribute(ctx.Attrs.UpgradeId)
				local config = type(upgradeId) == "string" and ctx.UpgradeConfig[upgradeId]
				if config and config.TemplateKind == "Building" then
					local owner = current:FindFirstChild("Owner")
					local isOwned = current:GetAttribute("OwnerUserId") == player.UserId
						or (owner and owner:IsA("ObjectValue") and owner.Value == player)
					return isOwned and current or nil, upgradeId, config
				end
			end
			current = current.Parent
		end
		return nil, nil, nil
	end

	local function clearSelection()
		if selectedDestroyConnection then
			selectedDestroyConnection:Disconnect()
			selectedDestroyConnection = nil
		end
		selectedBuilding = nil
		selectedUpgradeId = nil
		selectedConfig = nil
		selectionInput = nil
		highlight.Adornee = nil
		source:clear()
	end

	local function cancelHover(clearActiveMouseSelection)
		hoverGeneration += 1
		hoverCandidate = nil
		if clearActiveMouseSelection and selectionInput == "Mouse" then
			clearSelection()
		end
	end

	local function getMultiplierText(building, upgradeId, config)
		-- The compact three-column presentation shows the final contextual multiplier only.
		-- ProductionFormula already folds upgrades, skins, boosts, and future formula factors
		-- into this total, so the adjacent production value remains the live effective rate.
		local total = ctx.ProductionFormula.GetMultiplier(player, upgradeId, config, building)
		return ctx.NumberFormat.multiplier(total)
	end

	local function getBuildingScreenPoint(building)
		if not (building and building.Parent) then
			return nil
		end
		local camera = Workspace.CurrentCamera
		if not camera then
			return nil
		end

		local ok, boundingCFrame, boundingSize = pcall(building.GetBoundingBox, building)
		if not ok then
			return nil
		end
		local worldPoint = boundingCFrame.Position + Vector3.yAxis * (boundingSize.Y / 2)
		local screenPoint, onScreen
		if ctx.screenGui.IgnoreGuiInset then
			screenPoint, onScreen = camera:WorldToScreenPoint(worldPoint)
		else
			screenPoint, onScreen = camera:WorldToViewportPoint(worldPoint)
		end
		if not onScreen or screenPoint.Z <= 0 then
			return nil
		end
		return Vector2.new(screenPoint.X, screenPoint.Y)
	end

	local function buildContent(building, upgradeId, config, inputMode)
		local sections = CursorTooltipTuning.getBuildingStatsSections()
		if not sections.enabled then
			return nil
		end

		local productionPerMinute = ctx.ProductionFormula.GetCps(player, upgradeId, config, building) * 60
		local content = {
			mode = "BuildingStats",
			title = sections.showTitle and (config.DisplayName or upgradeId) or nil,
			fields = {
				Owned = sections.showOwned and ("x" .. ctx.NumberFormat.abbreviate(ctx.getOwnedCount(upgradeId))) or "",
				Production = sections.showProduction and ctx.NumberFormat.rate(productionPerMinute) or "",
				Multiplier = sections.showMultiplier and getMultiplierText(building, upgradeId, config) or "",
			},
		}
		if inputMode == "Touch" then
			content.placement = "Above"
			content.getScreenPoint = function()
				return getBuildingScreenPoint(building)
			end
		end
		return content
	end

	local function activateBuilding(building, upgradeId, config, inputMode)
		if destroyed or not building.Parent then
			return
		end
		if selectedDestroyConnection then
			selectedDestroyConnection:Disconnect()
		end
		selectedBuilding = building
		selectedUpgradeId = upgradeId
		selectedConfig = config
		selectionInput = inputMode
		highlight.Adornee = building
		selectedDestroyConnection = building.Destroying:Once(clearSelection)
		local content = buildContent(building, upgradeId, config, inputMode)
		if content then
			source:show(content)
		else
			clearSelection()
		end
	end

	local function refreshSelection()
		if not (selectedBuilding and selectedBuilding.Parent and selectedUpgradeId and selectedConfig) then
			clearSelection()
			return
		end
		source:show(buildContent(selectedBuilding, selectedUpgradeId, selectedConfig, selectionInput))
	end

	local function updateMouseHover()
		if
			destroyed
			or not BuildingInspectionConfig.MouseEnabled
			or UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse
			or interactionIsBlocked()
			or pointerIsOverUiAt(mouse.X, mouse.Y, true)
		then
			cancelHover(true)
			return
		end

		local building, upgradeId, config = findOwnedBuilding(mouse.Target)
		if not building then
			cancelHover(true)
			return
		end
		if selectedBuilding == building and selectionInput == "Mouse" then
			return
		end
		if hoverCandidate == building then
			return
		end

		cancelHover(true)
		hoverCandidate = building
		local generation = hoverGeneration
		local delaySeconds = BuildingInspectionConfig.HoverDelaySeconds
		task.delay(delaySeconds, function()
			if destroyed or generation ~= hoverGeneration or hoverCandidate ~= building then
				return
			end
			local currentBuilding = findOwnedBuilding(mouse.Target)
			if currentBuilding ~= building or interactionIsBlocked() or pointerIsOverUiAt(mouse.X, mouse.Y, true) then
				cancelHover(true)
				return
			end
			activateBuilding(building, upgradeId, config, "Mouse")
		end)
	end

	local function getTappedBuilding(position)
		local camera = Workspace.CurrentCamera
		if not camera then
			return nil, nil, nil
		end
		local ray = camera:ScreenPointToRay(position.X, position.Y)
		local result = Workspace:Raycast(ray.Origin, ray.Direction * MAX_RAY_DISTANCE)
		if not result then
			return nil, nil, nil
		end
		return findOwnedBuilding(result.Instance)
	end

	table.insert(connections, mouse.Move:Connect(updateMouseHover))
	table.insert(
		connections,
		UserInputService.TouchTap:Connect(function(touchPositions, gameProcessed)
			cancelHover(false)
			if
				#touchPositions ~= 1
				or gameProcessed
				or not BuildingInspectionConfig.TouchEnabled
				or interactionIsBlocked()
				or pointerIsOverUiAt(touchPositions[1].X, touchPositions[1].Y, false)
			then
				clearSelection()
				return
			end

			local building, upgradeId, config = getTappedBuilding(touchPositions[1])
			if not building then
				clearSelection()
				return
			end
			activateBuilding(building, upgradeId, config, "Touch")
		end)
	)
	table.insert(
		connections,
		ctx.screenGui:GetAttributeChangedSignal(ctx.Attrs.PlacementActive):Connect(function()
			if interactionIsBlocked() then
				cancelHover(false)
				clearSelection()
			end
		end)
	)
	table.insert(
		connections,
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(function()
			if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
				cancelHover(true)
			end
		end)
	)
	table.insert(connections, player:GetAttributeChangedSignal(ctx.Attrs.GooSkinMultiplier):Connect(refreshSelection))

	local function observeNumberValue(value)
		if value:IsA("NumberValue") or value:IsA("IntValue") then
			table.insert(connections, value.Changed:Connect(refreshSelection))
		end
	end
	for _, value in ipairs(ctx.upgradeCountData:GetChildren()) do
		observeNumberValue(value)
	end
	table.insert(
		connections,
		ctx.upgradeCountData.ChildAdded:Connect(function(child)
			observeNumberValue(child)
			refreshSelection()
		end)
	)
	table.insert(connections, ctx.upgradeCountData.ChildRemoved:Connect(refreshSelection))

	local observedWorldEventFolders = {}
	local function observeWorldEventFolder(folder)
		if observedWorldEventFolders[folder] or folder.Name ~= "WorldEventMultipliers" then
			return
		end
		observedWorldEventFolders[folder] = true
		table.insert(connections, folder.AttributeChanged:Connect(refreshSelection))
		for _, child in ipairs(folder:GetChildren()) do
			observeNumberValue(child)
		end
		table.insert(
			connections,
			folder.ChildAdded:Connect(function(child)
				observeNumberValue(child)
				refreshSelection()
			end)
		)
		table.insert(connections, folder.ChildRemoved:Connect(refreshSelection))
	end
	local worldEvents = ReplicatedStorage:FindFirstChild("WorldEventMultipliers")
	if worldEvents then
		observeWorldEventFolder(worldEvents)
	end
	table.insert(
		connections,
		ReplicatedStorage.ChildAdded:Connect(function(child)
			observeWorldEventFolder(child)
		end)
	)
	table.insert(
		connections,
		ReplicatedStorage.ChildRemoved:Connect(function(child)
			if child.Name == "WorldEventMultipliers" then
				refreshSelection()
			end
		end)
	)

	return {
		refresh = refreshSelection,
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			cancelHover(false)
			clearSelection()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			effectContainer:Destroy()
			source:destroy()
		end,
	}
end

return StoreBuildingStatsTooltip
