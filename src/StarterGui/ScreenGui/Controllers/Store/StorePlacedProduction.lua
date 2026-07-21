-- StorePlacedProduction: sums the exact floor-aware output of a player's placed
-- buildings and reports placement changes that can affect a Store row's TCPM.
local Workspace = game:GetService("Workspace")

local StorePlacedProduction = {}

local function getObjectValue(parent, name)
	local value = parent and parent:FindFirstChild(name)
	return value and value:IsA("ObjectValue") and value or nil
end

function StorePlacedProduction.new(ctx, onChanged)
	local cookieSheets = Workspace:WaitForChild("CookieSheets")
	local observedSheets = {}
	local observedBuildings = {}
	local observedObjectValues = {}

	local M = {}

	local function getSheetOwner(sheet)
		local owner = getObjectValue(sheet, "SheetOwner")
		return owner and owner.Value or nil
	end

	local function getBuildingOwner(building)
		local owner = getObjectValue(building, "Owner")
		return owner and owner.Value or nil
	end

	local function emit(upgradeId)
		if onChanged then
			onChanged(type(upgradeId) == "string" and upgradeId or nil)
		end
	end

	local function watchObjectValue(value, callback)
		if not value or observedObjectValues[value] then
			return
		end
		observedObjectValues[value] = true
		value:GetPropertyChangedSignal("Value"):Connect(callback)
	end

	local function watchBuilding(sheet, building)
		if observedBuildings[building] then
			return
		end
		observedBuildings[building] = true

		local lastUpgradeId = building:GetAttribute(ctx.Attrs.UpgradeId)
		local function emitIfOwned(previousUpgradeId)
			if getSheetOwner(sheet) ~= ctx.player then
				return
			end
			if previousUpgradeId then
				emit(previousUpgradeId)
			end
			local upgradeId = building:GetAttribute(ctx.Attrs.UpgradeId)
			if upgradeId ~= previousUpgradeId then
				emit(upgradeId)
			end
		end

		building:GetAttributeChangedSignal(ctx.Attrs.FloorId):Connect(function()
			emitIfOwned()
		end)
		building:GetAttributeChangedSignal(ctx.Attrs.UpgradeId):Connect(function()
			local previousUpgradeId = lastUpgradeId
			lastUpgradeId = building:GetAttribute(ctx.Attrs.UpgradeId)
			emitIfOwned(previousUpgradeId)
		end)

		local function watchOwner(owner)
			watchObjectValue(owner, function()
				emitIfOwned()
			end)
		end
		watchOwner(getObjectValue(building, "Owner"))
		building.ChildAdded:Connect(function(child)
			if child.Name == "Owner" and child:IsA("ObjectValue") then
				watchOwner(child)
				emitIfOwned()
			end
		end)
		building.ChildRemoved:Connect(function(child)
			if child.Name == "Owner" then
				emitIfOwned()
			end
		end)
	end

	local function watchSheet(sheet)
		if observedSheets[sheet] then
			return
		end
		observedSheets[sheet] = true

		local function watchSheetOwner(owner)
			watchObjectValue(owner, function()
				emit(nil)
			end)
		end
		watchSheetOwner(getObjectValue(sheet, "SheetOwner"))

		for _, child in ipairs(sheet:GetChildren()) do
			if child:IsA("Model") then
				watchBuilding(sheet, child)
			end
		end

		sheet.ChildAdded:Connect(function(child)
			if child.Name == "SheetOwner" and child:IsA("ObjectValue") then
				watchSheetOwner(child)
				emit(nil)
			elseif child:IsA("Model") then
				watchBuilding(sheet, child)
				if getSheetOwner(sheet) == ctx.player then
					emit(child:GetAttribute(ctx.Attrs.UpgradeId))
				end
			end
		end)

		sheet.ChildRemoved:Connect(function(child)
			if child.Name == "SheetOwner" then
				emit(nil)
			elseif child:IsA("Model") and getSheetOwner(sheet) == ctx.player then
				emit(child:GetAttribute(ctx.Attrs.UpgradeId))
			end
		end)
	end

	for _, sheet in ipairs(cookieSheets:GetChildren()) do
		watchSheet(sheet)
	end
	cookieSheets.ChildAdded:Connect(function(sheet)
		watchSheet(sheet)
		emit(nil)
	end)
	cookieSheets.ChildRemoved:Connect(function()
		emit(nil)
	end)

	function M.getTotalCpm(upgradeId, config, expectedCount)
		if not config or config.TemplateKind ~= "Building" or expectedCount <= 0 then
			return nil
		end

		local playerSheet
		for _, sheet in ipairs(cookieSheets:GetChildren()) do
			if getSheetOwner(sheet) == ctx.player then
				playerSheet = sheet
				break
			end
		end
		if not playerSheet then
			return nil
		end

		local matchedCount = 0
		local totalCpm = 0
		for _, building in ipairs(playerSheet:GetChildren()) do
			if
				building:IsA("Model")
				and building:GetAttribute(ctx.Attrs.UpgradeId) == upgradeId
				and getBuildingOwner(building) == ctx.player
			then
				matchedCount += 1
				totalCpm += ctx.ProductionFormula.GetCps(ctx.player, upgradeId, config, building) * 60
			end
		end

		-- Count values and placed models can replicate on different frames. Keep the
		-- established fallback until both views agree, then the placement observers
		-- above refresh TCPM with the exact floor-aware total.
		if matchedCount ~= expectedCount then
			return nil
		end
		return totalCpm
	end

	return M
end

return StorePlacedProduction
