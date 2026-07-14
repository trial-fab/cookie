local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local PlayerMetricsService = require(ServerScriptService.Services.PlayerMetricsService)
local StoryService = require(ServerScriptService.Services.StoryService)
local SheetService = require(ServerScriptService.Services.SheetService)
local XpService = require(ServerScriptService.Services.XpService)
local NumberFormat = require(ReplicatedStorage.Shared.NumberFormat)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local GridPlacement = require(ReplicatedStorage.Shared.GridPlacement)
local Net = require(ReplicatedStorage.Shared.Net)
local Attrs = require(ReplicatedStorage.Shared.Attrs)
local PvpConfig = require(ReplicatedStorage.Shared.PvpConfig)

local UpgradeService = {}

local SELL_REFUND_RATIO = 0.5
local UPGRADE_TEMPLATES_FOLDER = "UpgradeTemplates"
local DEFAULT_DIMENSION = "Earth"
-- GRID_SIZE drives Base Expansion sizing; per-footprint placement math now lives in
-- ReplicatedStorage.Shared.GridPlacement.
local GRID_SIZE = GridPlacement.GRID_SIZE
-- Plot is fixed-width (tangential) and grows in DEPTH (radial) OUTWARD via Base Expansion.
-- Depth must stay an EVEN number of cells so the Base-local placement grid stays aligned
-- with the inner-edge anchor that persisted buildings are stored against (each expansion
-- moves the Base center outward by depth/2; even cells keep that a whole-cell multiple).
local PLOT_WIDTH_CELLS = 22         -- 132 studs, fixed tangential width
local PLOT_INITIAL_DEPTH_CELLS = 6  -- 36 studs starting radial depth
-- First expansion (ring 1) can be gated behind the portal item. Off until the portal
-- teleport flow is wired, so expansion is pure cookies for now.
local RING1_PORTAL_GATE_ENABLED = false
local PORTAL_UNLOCK_ATTRIBUTE = "ExpansionPortalUnlocked"
local MAX_TOOL_DAMAGE_DISTANCE = 18
local TOUCH_DAMAGE_OWNER_PROTECTION_ENABLED = false
local BASE_MAX_HEALTH = 100
local BUILDING_BREAK_EFFECT_SECONDS = 2
local PICKAXE_TOOLS = {
	PickAxe = true,
	["PA High Tech"] = true,
}

local function getCookiesValue(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return nil
	end

	return leaderstats:FindFirstChild("Cookies")
end

local function getUpgradeCountValue(player, upgradeId)
	local upgradeCountData = player:FindFirstChild("UpgradeCountData")
	if not upgradeCountData then
		return nil
	end

	local value = upgradeCountData:FindFirstChild(upgradeId)
	if value and value:IsA("IntValue") then
		return value
	end

	return nil
end

local function ensureUpgradeCountValue(player, upgradeId, config)
	local upgradeCountData = player:FindFirstChild("UpgradeCountData")
	if not upgradeCountData then
		return nil
	end

	local value = getUpgradeCountValue(player, upgradeId)
	if value then
		return value
	end

	value = Instance.new("IntValue")
	value.Name = upgradeId
	value.Value = config.InitialCount or 0
	value.Parent = upgradeCountData
	return value
end

local function findUpgradeTemplateContainer()
	return ServerStorage:FindFirstChild(UPGRADE_TEMPLATES_FOLDER)
end

local function findUpgradeTemplate(config)
	local container = findUpgradeTemplateContainer()
	if not container then
		return nil
	end

	local templateName = config.TemplateName or config.DisplayName
	if not templateName then
		return nil
	end

	return container:FindFirstChild(templateName)
end

local function findToolTemplate(config)
	local template = findUpgradeTemplate(config)

	if template and template:IsA("Tool") then
		return template
	elseif template then
		local tool = template:FindFirstChildWhichIsA("Tool", true)
		if tool then
			return tool
		end
	end

	return nil
end

local function removeToolFromContainer(container, toolName)
	local tool = container and container:FindFirstChild(toolName)
	if tool and tool:IsA("Tool") then
		tool:Destroy()
	end
end

local function disableLegacyPickaxeScripts(tool)
	if not tool or not PICKAXE_TOOLS[tool.Name] then
		return
	end

	for _, descendant in ipairs(tool:GetDescendants()) do
		if descendant:IsA("LocalScript") and descendant.Name == "PickaxeScript" then
			descendant.Disabled = true
		end
	end
end

local function grantTool(player, config)
	local template = findToolTemplate(config)
	if not template then
		return false, "Upgrade tool template was not found."
	end

	local backpack = player:FindFirstChild("Backpack") or player:WaitForChild("Backpack", 5)
	local starterGear = player:FindFirstChild("StarterGear") or player:WaitForChild("StarterGear", 5)
	if not backpack or not starterGear then
		return false, "Player inventory is not ready."
	end

	removeToolFromContainer(backpack, template.Name)
	removeToolFromContainer(starterGear, template.Name)
	removeToolFromContainer(player.Character, template.Name)

	local backpackTool = template:Clone()
	disableLegacyPickaxeScripts(backpackTool)
	backpackTool.Parent = backpack

	local starterGearTool = template:Clone()
	disableLegacyPickaxeScripts(starterGearTool)
	starterGearTool.Parent = starterGear

	return true
end

local function revokeTool(player, config)
	local template = findToolTemplate(config)
	if not template then
		return
	end

	removeToolFromContainer(player:FindFirstChild("Backpack"), template.Name)
	removeToolFromContainer(player:FindFirstChild("StarterGear"), template.Name)
	removeToolFromContainer(player.Character, template.Name)
end

local function getBuildingSlotIndex(upgradeId)
	local buildingIds = {}
	for id, config in pairs(UpgradeConfig) do
		if config.TemplateKind == "Building" then
			table.insert(buildingIds, id)
		end
	end
	table.sort(buildingIds)

	for index, id in ipairs(buildingIds) do
		if id == upgradeId then
			return index
		end
	end

	return 1
end

local function getPlacementBasePart(sheet)
	local base = sheet:FindFirstChild("Base")
	if base and base:IsA("BasePart") then
		return base
	end

	return nil
end

local function getBlockedCenterPart(sheet)
	local center = sheet:FindFirstChild("Center")
	if center and center:IsA("BasePart") then
		return center
	end

	return nil
end

local function getBuildingCFrame(sheet, upgradeId, offsetIndex)
	local base = getPlacementBasePart(sheet)
	if not base then
		return nil
	end

	local slotIndex = (offsetIndex or getBuildingSlotIndex(upgradeId)) - 1
	local column = slotIndex % 4
	local row = math.floor(slotIndex / 4)
	local xOffset = (column - 1.5) * 34
	local zOffset = 34 + row * 34

	return base.CFrame * CFrame.new(xOffset, 0, zOffset)
end

local function getSavedBuildingCFrame(sheet, placement)
	local base = getPlacementBasePart(sheet)
	if not base or type(placement) ~= "table" then
		return nil
	end

	local x = tonumber(placement.X)
	local y = tonumber(placement.Y)
	local z = tonumber(placement.Z)
	if not x or not y or not z then
		return nil
	end

	local anchor = GridPlacement.getPlacementAnchorCFrame(base)
	return anchor * CFrame.new(x, y, z) * CFrame.Angles(0, tonumber(placement.RY) or 0, 0)
end

local function getAlignedModelPivotCFrame(model, desiredBoundingCFrame)
	local boundingCFrame = model:GetBoundingBox()
	local pivotOffset = boundingCFrame:ToObjectSpace(model:GetPivot())
	return desiredBoundingCFrame * pivotOffset
end

local function getPlotPlacementCFrame(sheet, requestedCFrame, template, config)
	local base = getPlacementBasePart(sheet)
	if not base then
		return nil
	end

	if typeof(requestedCFrame) ~= "CFrame" then
		return nil
	end

	local localPosition = base.CFrame:PointToObjectSpace(requestedCFrame.Position)
	local _, templateSize = template:GetBoundingBox()
	local _, rotationY = requestedCFrame:ToOrientation()
	local cellsX, cellsZ = GridPlacement.getFootprintCells(config, rotationY)
	local solved = GridPlacement.solvePlacement(localPosition, base.Size, cellsX, cellsZ)
	if not solved.inBounds then
		return nil
	end

	local snappedX, snappedZ = solved.snappedX, solved.snappedZ
	local worldPosition = base.CFrame:PointToWorldSpace(Vector3.new(
		snappedX,
		base.Size.Y / 2 + templateSize.Y / 2,
		snappedZ
	))
	local desiredBoundingCFrame = CFrame.new(worldPosition) * CFrame.Angles(0, rotationY, 0)
	local footprintCFrame = GridPlacement.getFootprintCFrame(base.CFrame, base.Size.Y, snappedX, snappedZ)

	return getAlignedModelPivotCFrame(template, desiredBoundingCFrame), footprintCFrame, rotationY
end

local function getBuildingFootprintCFrame(sheet, buildingCFrame)
	local base = getPlacementBasePart(sheet)
	if not base then
		return nil
	end

	local localPosition = base.CFrame:PointToObjectSpace(buildingCFrame.Position)
	return GridPlacement.getFootprintCFrame(base.CFrame, base.Size.Y, localPosition.X, localPosition.Z)
end

local function setBuildingOwner(building, player)
	local owner = building:FindFirstChild("Owner")
	if owner and not owner:IsA("ObjectValue") then
		owner:Destroy()
		owner = nil
	end

	if not owner then
		owner = Instance.new("ObjectValue")
		owner.Name = "Owner"
		owner.Parent = building
	end

	owner.Value = player
	building:SetAttribute("OwnerUserId", player.UserId)
end

local function ensureBuildingIntegrity(building, config)
	local maxIntegrity = building:FindFirstChild("MaxIntegrity")
	if maxIntegrity and not maxIntegrity:IsA("IntValue") then
		maxIntegrity:Destroy()
		maxIntegrity = nil
	end

	if not maxIntegrity and config.MaxIntegrity then
		maxIntegrity = Instance.new("IntValue")
		maxIntegrity.Name = "MaxIntegrity"
		maxIntegrity.Parent = building
	end

	if maxIntegrity and config.MaxIntegrity then
		maxIntegrity.Value = config.MaxIntegrity
	end

	local integrity = building:FindFirstChild("Integrity")
	if integrity and not integrity:IsA("IntValue") then
		integrity:Destroy()
		integrity = nil
	end

	if not integrity and config.MaxIntegrity then
		integrity = Instance.new("IntValue")
		integrity.Name = "Integrity"
		integrity.Parent = building
	end

	if integrity and config.MaxIntegrity then
		integrity.Value = config.MaxIntegrity
	end
end

local function findOwnedBuilding(player, upgradeId)
	local sheet = SheetService.GetPlayerSheet(player)
	if not sheet then
		return nil
	end

	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(Attrs.UpgradeId) == upgradeId then
			return child
		end
	end

	return nil
end

local function getOwnedBuildings(player, upgradeId)
	local sheet = SheetService.GetPlayerSheet(player)
	if not sheet then
		return {}
	end

	local buildings = {}
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(Attrs.UpgradeId) == upgradeId then
			table.insert(buildings, child)
		end
	end

	return buildings
end

local function getBuildingRootPart(building)
	local main = building:FindFirstChild("Main", true)
	if main and main:IsA("BasePart") then
		return main
	end

	return building:FindFirstChildWhichIsA("BasePart", true)
end

local function showBuildingDamage(building, targetPart, damage, integrity, maxIntegrity)
	local part = targetPart
	if not part or not part:IsA("BasePart") then
		part = getBuildingRootPart(building)
	end
	if not part then
		return
	end

	for _, descendant in ipairs(building:GetDescendants()) do
		if descendant:IsA("BillboardGui") and descendant.Name == "BuildingDamage" then
			descendant:Destroy()
		end
	end

	local percent = 0
	if maxIntegrity and maxIntegrity > 0 then
		percent = math.clamp(math.floor((math.max(0, integrity) / maxIntegrity) * 100 + 0.5), 0, 100)
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BuildingDamage"
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(150, 42)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.Adornee = part
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.SourceSansBold
	label.TextScaled = true
	label.TextStrokeTransparency = 0.35
	label.TextColor3 = integrity <= 0 and Color3.fromRGB(255, 220, 80) or Color3.fromRGB(255, 90, 90)
	label.Text = integrity <= 0 and "Destroyed!" or ("-" .. NumberFormat.abbreviate(damage) .. " (" .. tostring(percent) .. "%)")
	label.Parent = billboard

	Debris:AddItem(billboard, 1.1)
end

local function decrementBuildingCount(player, upgradeId)
	local config = UpgradeConfig[upgradeId]
	if not config then
		return false
	end

	local countValue = getUpgradeCountValue(player, upgradeId)
	if countValue and countValue.Value > (config.InitialCount or 0) then
		countValue.Value -= 1
		return true
	end

	return false
end

-- §4c effect-handler registry (finding 8): config entries declare effects in
-- `config.Effects = { EffectName = value }`; ApplyUpgrade walks them and calls
-- the matching handler. Consumers query totals derived from upgrade counts via
-- getEffectTotal/hasEffect rather than relying on mutated state.
local function getEffectTotal(player, effectName)
	local total = 0
	local upgradeCountData = player:FindFirstChild("UpgradeCountData")
	if not upgradeCountData then
		return total
	end

	for upgradeId, config in pairs(UpgradeConfig) do
		local countValue = upgradeCountData:FindFirstChild(upgradeId)
		local count = countValue and countValue:IsA("IntValue") and countValue.Value or config.InitialCount or 0
		local ownedCount = math.max(0, count - (config.InitialCount or 0))

		local value = config.Effects and config.Effects[effectName]
		if value then
			total += ownedCount * value
		end

		if config.Levels then
			for level = 1, math.min(ownedCount, #config.Levels) do
				local levelValue = config.Levels[level].Effects and config.Levels[level].Effects[effectName]
				if levelValue then
					total += levelValue
				end
			end
		end
	end

	return total
end

local function hasEffect(player, effectName)
	return getEffectTotal(player, effectName) > 0
end

-- Building "unlocked" state (store silhouette/near-miss): a building stays unlocked
-- once ever purchased, even if later sold to 0. Tracked as a JSON set on the
-- `UnlockedBuildingsJson` attribute, persisted by PlayerDataService and read by
-- StoreController. Mirrors the OwnedSkins attribute pattern.
local UNLOCKED_BUILDINGS_ATTRIBUTE = "UnlockedBuildingsJson"

local function getUnlockedBuildings(player)
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(player:GetAttribute(UNLOCKED_BUILDINGS_ATTRIBUTE) or "{}")
	end)
	return (ok and type(decoded) == "table") and decoded or {}
end

local function markBuildingUnlocked(player, upgradeId)
	local set = getUnlockedBuildings(player)
	if set[upgradeId] then
		return false
	end

	set[upgradeId] = true
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(set)
	end)
	if ok then
		player:SetAttribute(UNLOCKED_BUILDINGS_ATTRIBUTE, encoded)
		return true
	end

	return false
end

local function applyPlayerMaxHealth(player, character, healthDelta)
	character = character or player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local desiredMaxHealth = math.max(1, BASE_MAX_HEALTH + getEffectTotal(player, "MaxHealthBonus"))
	local previousMaxHealth = humanoid.MaxHealth
	humanoid.MaxHealth = desiredMaxHealth

	if healthDelta then
		humanoid.Health = math.clamp(humanoid.Health + healthDelta, 0, desiredMaxHealth)
	elseif humanoid.Health >= previousMaxHealth then
		humanoid.Health = desiredMaxHealth
	else
		humanoid.Health = math.min(humanoid.Health, desiredMaxHealth)
	end
end

local function playBuildingBreakEffect(building, hitPosition)
	local effectModel = Instance.new("Model")
	effectModel.Name = "BuildingBreakEffect"
	effectModel.Parent = Workspace

	local explosionPosition = hitPosition
	local fallbackPart = getBuildingRootPart(building)
	if typeof(explosionPosition) ~= "Vector3" then
		explosionPosition = fallbackPart and fallbackPart.Position or building:GetPivot().Position
	end

	local explosion = Instance.new("Explosion")
	explosion.BlastPressure = 0
	explosion.BlastRadius = 8
	explosion.DestroyJointRadiusPercent = 0
	explosion.Position = explosionPosition
	explosion.Parent = Workspace

	for _, descendant in ipairs(building:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local clone = descendant:Clone()
			clone.Name = descendant.Name .. " Debris"
			clone.Anchored = false
			clone.CanCollide = false
			clone.CanTouch = false
			clone.CanQuery = false
			clone.CFrame = descendant.CFrame
			clone.Parent = effectModel
			clone.AssemblyLinearVelocity = Vector3.new(
				math.random(-45, 45),
				math.random(28, 65),
				math.random(-45, 45)
			)
			clone.AssemblyAngularVelocity = Vector3.new(
				math.random(-12, 12),
				math.random(-12, 12),
				math.random(-12, 12)
			)
		end
	end

	Debris:AddItem(effectModel, BUILDING_BREAK_EFFECT_SECONDS)
end

local function destroyBuilding(building, player, upgradeId, decrementCount, breakEffectPosition)
	if decrementCount and not building:GetAttribute(Attrs.CountAdjusted) then
		decrementBuildingCount(player, upgradeId)
		building:SetAttribute(Attrs.CountAdjusted, true)
	end

	if breakEffectPosition then
		playBuildingBreakEffect(building, breakEffectPosition)
	end

	building:Destroy()
end

local function markBuildingCountAdjusted(building)
	if building then
		building:SetAttribute(Attrs.CountAdjusted, true)
	end
end

local function connectBuildingDestruction(building, player, upgradeId)
	building.AncestryChanged:Connect(function(_, parent)
		if parent == nil and not building:GetAttribute(Attrs.CountAdjusted) then
			building:SetAttribute(Attrs.CountAdjusted, true)
			decrementBuildingCount(player, upgradeId)
		end
	end)

	local integrity = building:FindFirstChild("Integrity")
	if not integrity or not integrity:IsA("IntValue") then
		return
	end

	integrity.Changed:Connect(function()
		if building:GetAttribute("SuppressIntegrityDestroy") then
			return
		end

		if integrity.Value <= 0 and building.Parent then
			destroyBuilding(building, player, upgradeId, true)
		end
	end)
end

local function hasBuildingOverlap(sheet, cframe, size)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = { sheet }
	local querySize = GridPlacement.getOverlapQuerySize(size)

	for _, part in ipairs(Workspace:GetPartBoundsInBox(cframe, querySize, overlapParams)) do
		local candidate = part
		while candidate and candidate ~= sheet do
			if candidate:IsA("Model") and candidate.Parent == sheet and candidate:GetAttribute(Attrs.UpgradeId) then
				return true
			end
			candidate = candidate.Parent
		end
	end

	return false
end

local function getHumanoidFromTouchedPart(part)
	local candidate = part
	while candidate and candidate ~= Workspace do
		if candidate:IsA("Model") then
			local humanoid = candidate:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return humanoid, candidate
			end
		end
		candidate = candidate.Parent
	end

	return nil, nil
end

local function isBuildingOwnerCharacter(building, character)
	if not TOUCH_DAMAGE_OWNER_PROTECTION_ENABLED then
		return false
	end

	local owner = building:FindFirstChild("Owner")
	if owner and owner:IsA("ObjectValue") and owner.Value then
		return owner.Value.Character == character
	end

	local player = Players:GetPlayerFromCharacter(character)
	return player ~= nil and building:GetAttribute("OwnerUserId") == player.UserId
end

local function connectBuildingTouchDamage(building, config)
	if not config.TouchDamage or building:GetAttribute("TouchDamageConnected") then
		return
	end

	building:SetAttribute("TouchDamageConnected", true)
	local touchingPartsByHumanoid = {}
	local damagingHumanoids = {}
	local damageInterval = math.max(0.2, config.TouchDamageInterval or 1)
	local damagePerTick = math.max(0, config.TouchDamagePerSecond or 10) * damageInterval
	local touchPartName = config.TouchDamagePartName

	local function connectPart(part)
		if not part:IsA("BasePart") then
			return
		end

		if touchPartName and part.Name ~= touchPartName then
			return
		end

		local function removeTouch(touchedPart)
			local humanoid = getHumanoidFromTouchedPart(touchedPart)
			if not humanoid or not touchingPartsByHumanoid[humanoid] then
				return
			end

			touchingPartsByHumanoid[humanoid][part] = nil
			if not next(touchingPartsByHumanoid[humanoid]) then
				touchingPartsByHumanoid[humanoid] = nil
			end
		end

		part.Touched:Connect(function(touchedPart)
			if not building.Parent then
				return
			end

			local humanoid, character = getHumanoidFromTouchedPart(touchedPart)
			if not humanoid or humanoid.Health <= 0 or not character then
				return
			end

			if isBuildingOwnerCharacter(building, character) then
				return
			end

			touchingPartsByHumanoid[humanoid] = touchingPartsByHumanoid[humanoid] or {}
			touchingPartsByHumanoid[humanoid][part] = true
			if damagingHumanoids[humanoid] then
				return
			end

			damagingHumanoids[humanoid] = true
			task.spawn(function()
				while building.Parent and humanoid.Parent and humanoid.Health > 0 and touchingPartsByHumanoid[humanoid] do
					humanoid:TakeDamage(damagePerTick)
					task.wait(damageInterval)
				end

				damagingHumanoids[humanoid] = nil
			end)
		end)

		part.TouchEnded:Connect(removeTouch)
	end

	for _, descendant in ipairs(building:GetDescendants()) do
		connectPart(descendant)
	end

	building.DescendantAdded:Connect(connectPart)
end

local function placeBuilding(player, upgradeId, config, requestedCFrame, offsetIndex)
	local sheet = SheetService.GetPlayerSheet(player) or SheetService.AssignSheet(player)
	if not sheet then
		return false, "No cookie sheet is available."
	end

	local template = findUpgradeTemplate(config)
	if not template or not template:IsA("Model") then
		return false, "Building template was not found."
	end

	local cframe
	local footprintCFrame
	local placementRotationY
	if requestedCFrame then
		cframe, footprintCFrame, placementRotationY = getPlotPlacementCFrame(sheet, requestedCFrame, template, config)
		if not cframe then
			return false, "Place buildings on your cookie sheet."
		end
	end

	cframe = cframe or getBuildingCFrame(sheet, upgradeId, offsetIndex)
	if not cframe then
		return false, "Cookie sheet is missing Base."
	end

	footprintCFrame = footprintCFrame or getBuildingFootprintCFrame(sheet, cframe)
	if not footprintCFrame then
		return false, "Cookie sheet is missing Base."
	end

	local cellsX, cellsZ = GridPlacement.getFootprintCells(config, placementRotationY)
	local footprintSize = GridPlacement.getFootprintSize(cellsX, cellsZ)
	local blockedCenter = getBlockedCenterPart(sheet)
	if blockedCenter and GridPlacement.footprintOverlapsPartXZ(footprintCFrame, footprintSize, blockedCenter) then
		return false, "Place buildings outside the center."
	end

	if hasBuildingOverlap(sheet, footprintCFrame, footprintSize) then
		return false, "That spot overlaps another building."
	end

	local building = template:Clone()
	building:SetAttribute(Attrs.UpgradeId, upgradeId)
	if placementRotationY then
		building:SetAttribute(Attrs.PlacementRotationY, placementRotationY)
	else
		local _, fallbackRotationY = cframe:ToOrientation()
		building:SetAttribute(Attrs.PlacementRotationY, fallbackRotationY)
	end
	setBuildingOwner(building, player)
	ensureBuildingIntegrity(building, config)
	building:PivotTo(cframe)

	building.Parent = sheet
	connectBuildingDestruction(building, player, upgradeId)
	connectBuildingTouchDamage(building, config)

	return true, nil, building
end

local function removeBuilding(player, upgradeId)
	local building = findOwnedBuilding(player, upgradeId)
	if building then
		markBuildingCountAdjusted(building)
		building:Destroy()
	end
end

local function removeAllBuildings(player, upgradeId)
	for _, building in ipairs(getOwnedBuildings(player, upgradeId)) do
		markBuildingCountAdjusted(building)
		building:Destroy()
	end
end

local function getEquippedBuildingTool(player)
	local character = player.Character
	if not character then
		return nil
	end

	local tool = character:FindFirstChildOfClass("Tool")
	if not tool then
		return nil
	end

	if tool.Name == "PickAxe" then
		return tool, 10
	elseif tool.Name == "PA High Tech" then
		return tool, 40
	end

	return nil
end

local function getBuildingFromPart(part)
	if not part or not part:IsA("BasePart") then
		return nil
	end

	local candidate = part
	while candidate do
		if candidate:IsA("Model") and candidate:GetAttribute(Attrs.UpgradeId) then
			return candidate
		end
		candidate = candidate.Parent
	end

	return nil
end

function UpgradeService.DamageBuilding(player, targetPart, hitPosition)
	local tool, damage = getEquippedBuildingTool(player)
	if not tool then
		return
	end

	if typeof(targetPart) ~= "Instance" or not targetPart:IsA("BasePart") then
		return
	end

	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end

	local damagePosition = typeof(hitPosition) == "Vector3" and hitPosition or targetPart.Position
	if (handle.Position - damagePosition).Magnitude > MAX_TOOL_DAMAGE_DISTANCE then
		return
	end

	local building = getBuildingFromPart(targetPart)
	if not building then
		return
	end

	local integrity = building:FindFirstChild("Integrity")
	if not integrity or not integrity:IsA("IntValue") then
		return
	end

	local maxIntegrity = building:FindFirstChild("MaxIntegrity")
	local maxIntegrityValue = maxIntegrity and maxIntegrity:IsA("IntValue") and maxIntegrity.Value or integrity.Value
	if integrity.Value - damage <= 0 then
		building:SetAttribute("SuppressIntegrityDestroy", true)
	end

	integrity.Value -= damage
	showBuildingDamage(building, targetPart, damage, integrity.Value, maxIntegrityValue)
	if integrity.Value <= 0 then
		local upgradeId = building:GetAttribute(Attrs.UpgradeId)
		if type(upgradeId) == "string" then
			destroyBuilding(building, player, upgradeId, true, damagePosition)
		else
			playBuildingBreakEffect(building, damagePosition)
			building:Destroy()
		end
	end
end

-- Move the physical ExpansionButton to the plot's current outer (frontier) edge.
local function repositionExpansionButton(sheet, base, outward, depth)
	local btn = sheet:FindFirstChild("ExpansionButton")
	if not (btn and btn:IsA("Model") and btn.PrimaryPart) then
		return
	end
	local outerEdge = base.Position + outward * (depth / 2)
	local baseTop = base.Position.Y + base.Size.Y / 2
	local pos = Vector3.new(outerEdge.X, baseTop + 2.5, outerEdge.Z) + outward * 2
	local rot = btn:GetPivot().Rotation
	btn:PivotTo(CFrame.new(pos) * rot)
end

-- Refresh the ExpansionButton billboard/prompt with the next expansion's cookie cost
-- (or the portal-gate / MAXED state).
local function updateExpansionButton(player)
	local sheet = SheetService.GetPlayerSheet(player)
	if not sheet then
		return
	end
	local btn = sheet:FindFirstChild("ExpansionButton")
	if not (btn and btn:IsA("Model")) then
		return
	end

	local countValue = getUpgradeCountValue(player, "Base Expansion")
	local count = countValue and countValue.Value or 0
	local nextCost = UpgradeService.GetCost("Base Expansion", count)

	local label, action
	if RING1_PORTAL_GATE_ENABLED and count == 0 and not player:GetAttribute(PORTAL_UNLOCK_ATTRIBUTE) then
		label, action = "ENTER PORTAL", "Locked"
	elseif nextCost == nil then
		label, action = "MAXED", "Maxed"
	else
		label, action = "Expand\n" .. NumberFormat.abbreviate(nextCost), "Expand"
	end

	local prompt = btn:FindFirstChild("ExpandPrompt", true)
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.ActionText = action
		prompt.Enabled = (action == "Expand")
	end
	local textLabel = btn:FindFirstChild("CostLabel", true)
	if textLabel and textLabel:IsA("TextLabel") then
		textLabel.Text = label
	end
end
UpgradeService.UpdateExpansionButton = updateExpansionButton

-- Base Expansion effect (GridExpansion, in cells): grows the plot OUTWARD only. Width stays
-- fixed; depth grows along the plot's local +Z (radial). The inner (hub-facing) edge stays
-- pinned, so the cookie/spawn cluster and persisted buildings (stored against the inner-edge
-- anchor) don't move. Recomputed from owned-upgrade totals so it stays correct on rejoin.
local function applyGridExpansion(player)
	local sheet = SheetService.GetPlayerSheet(player)
	local base = sheet and getPlacementBasePart(sheet)
	if not base then
		return
	end

	local expansionCells = getEffectTotal(player, "GridExpansion")
	local width = PLOT_WIDTH_CELLS * GRID_SIZE
	local newDepth = (PLOT_INITIAL_DEPTH_CELLS + expansionCells) * GRID_SIZE

	-- Grow outward: keep the inner edge fixed, advance the center along +Z.
	local outward = -base.CFrame.LookVector
	local innerEdge = base.Position - outward * (base.Size.Z / 2)
	base.Size = Vector3.new(width, base.Size.Y, newDepth)
	base.Position = innerEdge + outward * (newDepth / 2)

	SheetService.SyncEdge(sheet)
	repositionExpansionButton(sheet, base, outward, newDepth)
	updateExpansionButton(player)
end

local EffectHandlers = {
	MaxHealthBonus = {
		apply = function(player, value, amount)
			applyPlayerMaxHealth(player, nil, value * amount)
		end,
	},
	ClickPowerMultiplier = {
		apply = function(player)
			CookieService.RefreshCookiesPerClickDisplay(player)
		end,
	},
	GridExpansion = {
		apply = function(player)
			applyGridExpansion(player)
		end,
	},
	-- Toggles/entitlements query ownership via UpgradeService.HasEffect from
	-- counts, so no apply-time mutation is needed.
	UnlocksMultiPlace = { apply = function() end },
	OfflineCapHours = { apply = function() end },
}

function UpgradeService.GetCost(upgradeId, currentCount)
	local config = UpgradeConfig[upgradeId]
	if not config then
		return nil
	end

	-- Leveled upgrades: cost is the next unowned level's cost (nil when maxed).
	if config.Levels then
		local nextLevel = config.Levels and config.Levels[currentCount + 1]
		return nextLevel and nextLevel.Cost or nil
	end

	local baseCost = config.BaseCost or 0
	local multiplier = config.CostMultiplier or 1
	return math.floor(baseCost * (multiplier ^ currentCount))
end

function UpgradeService.ApplyUpgrade(player, upgradeId, amount, placementCFrame)
	local config = UpgradeConfig[upgradeId]
	if not config then
		return false
	end

	if config.TemplateKind == "Gear" and amount > 0 then
		return grantTool(player, config)
	elseif config.TemplateKind == "Building" and amount > 0 then
		return placeBuilding(player, upgradeId, config, placementCFrame)
	elseif config.TemplateKind == "Building" then
		removeBuilding(player, upgradeId)
		return true
	end

	local function applyEffects(effects)
		for effectName, value in pairs(effects) do
			local handler = EffectHandlers[effectName]
			if handler then
				handler.apply(player, value, amount, config)
			end
		end
	end

	if config.Effects then
		applyEffects(config.Effects)
	end

	if config.Levels then
		local countValue = getUpgradeCountValue(player, upgradeId)
		local levelIndex = countValue and (amount > 0 and countValue.Value or countValue.Value + 1) or nil
		local level = levelIndex and config.Levels[levelIndex]
		if level and level.Effects then
			applyEffects(level.Effects)
		end
	end

	return true
end

function UpgradeService.Purchase(player, upgradeId, placementCFrame)
	local config = UpgradeConfig[upgradeId]
	if not config then
		return false, "Unknown upgrade."
	end

	if config.StoreVisible == false then
		return false, "This item is currently unavailable."
	end

	-- PVP paused (Shared.PvpConfig): the store hides these rows; this also blocks a
	-- crafted remote from buying a hidden item while paused.
	if PvpConfig.IsUpgradePaused(upgradeId) then
		return false, "This item is currently unavailable."
	end

	local countValue = ensureUpgradeCountValue(player, upgradeId, config)
	if not countValue then
		return false, "Upgrade data is not ready."
	end

	if config.Levels and countValue.Value >= #config.Levels then
		return false, "Fully upgraded."
	end

	if config.MaxCount and countValue.Value >= config.MaxCount then
		return false, "You already own this upgrade."
	end

	if config.TemplateKind == "Building" and typeof(placementCFrame) ~= "CFrame" then
		return false, "Choose a place on your plot first."
	end

	if config.TemplateKind == "BuildingUpgrade" then
		local nextLevel = config.Levels and config.Levels[countValue.Value + 1]
		if not nextLevel then
			return false, "Fully upgraded."
		end

		local targetId = config.TargetBuilding
		local requiredCount = nextLevel.UnlockCount or 0
		if type(targetId) == "string" and requiredCount > 0 then
			local ownedValue = getUpgradeCountValue(player, targetId)
			local owned = ownedValue and ownedValue.Value or 0
			if owned < requiredCount then
				local targetConfig = UpgradeConfig[targetId]
				local targetName = targetConfig and targetConfig.DisplayName or targetId
				return false, "Requires " .. requiredCount .. " " .. targetName .. "."
			end
		end
	end

	-- Generic ownership gate, applied to ALL TemplateKinds (e.g. Portal requires a
	-- Research Facility). BuildingUpgrade levels keep their own per-level UnlockCount.
	local requirement = config.UnlockRequirement
	if type(requirement) == "table" then
		local requiredId = requirement.Building or requirement.TargetBuilding
		local requiredCount = requirement.Count or 1
		if type(requiredId) == "string" and requiredCount > 0 then
			local ownedValue = getUpgradeCountValue(player, requiredId)
			local owned = ownedValue and ownedValue.Value or 0
			if owned < requiredCount then
				local requiredConfig = UpgradeConfig[requiredId]
				local requiredName = requiredConfig and requiredConfig.DisplayName or requiredId
				return false, "Requires " .. requiredCount .. " " .. requiredName .. "."
			end
		end
	end

	local cost = UpgradeService.GetCost(upgradeId, countValue.Value)
	local cookies = getCookiesValue(player)
	if not cookies or cookies.Value < cost then
		return false, "Not enough cookies."
	end

	if config.TemplateKind == "Stat" then
		countValue.Value += 1
		local applied, applyMessage = UpgradeService.ApplyUpgrade(player, upgradeId, 1, placementCFrame)
		if not applied then
			countValue.Value -= 1
			return false, applyMessage or "Upgrade could not be applied."
		end

		CookieService.AddCookies(player, -cost, PlayerMetricsService.CookieSources.Purchase)
		return true, "Purchased " .. (config.DisplayName or upgradeId) .. "."
	end

	-- Deduct BEFORE applying: grantTool can yield (WaitForChild), and paying after a
	-- yield lets two overlapped purchases both pass the funds check above. Refund if
	-- the apply then fails.
	CookieService.AddCookies(player, -cost, PlayerMetricsService.CookieSources.PendingPurchase)
	local applied, applyMessage = UpgradeService.ApplyUpgrade(player, upgradeId, 1, placementCFrame)
	if not applied then
		CookieService.AddCookies(player, cost, PlayerMetricsService.CookieSources.Refund)
		return false, applyMessage or "Upgrade could not be applied."
	end

	countValue.Value += 1
	PlayerMetricsService.RecordCookiesSpent(player, cost)

	if config.TemplateKind == "Building" then
		PlayerMetricsService.RecordBuildingPlaced(player)
		local newlyUnlocked = markBuildingUnlocked(player, upgradeId)
		if newlyUnlocked then
			XpService.AwardBuildingUnlock(player, upgradeId, config)
		end
		StoryService.OnBuildingPlaced(player, upgradeId)
	end

	return true, "Purchased " .. (config.DisplayName or upgradeId) .. "."
end

function UpgradeService.Sell(player, upgradeId)
	local config = UpgradeConfig[upgradeId]
	if not config then
		return false, "Unknown upgrade."
	end

	if config.Sellable == false then
		return false, "This upgrade cannot be sold."
	end

	local countValue = ensureUpgradeCountValue(player, upgradeId, config)
	if not countValue then
		return false, "Upgrade data is not ready."
	end

	local minimumCount = config.InitialCount or 0
	if countValue.Value <= minimumCount then
		return false, "You cannot sell this upgrade."
	end

	local previousPurchaseCost = UpgradeService.GetCost(upgradeId, countValue.Value - 1) or 0
	local refund = math.floor(previousPurchaseCost * SELL_REFUND_RATIO)

	countValue.Value -= 1
	UpgradeService.ApplyUpgrade(player, upgradeId, -1)
	if config.TemplateKind == "Gear" and countValue.Value <= minimumCount then
		revokeTool(player, config)
	elseif config.TemplateKind == "Building" and countValue.Value <= minimumCount then
		removeBuilding(player, upgradeId)
	end
	CookieService.AddCookies(player, refund, PlayerMetricsService.CookieSources.Refund)

	return true, "Sold " .. (config.DisplayName or upgradeId) .. " for " .. refund .. "."
end

function UpgradeService.SellBuilding(player, building)
	if typeof(building) ~= "Instance" or not building:IsA("Model") then
		return false, "Choose a building to sell."
	end

	local sheet = SheetService.GetPlayerSheet(player)
	if not sheet or building.Parent ~= sheet then
		return false, "That building is not on your cookie sheet."
	end

	local upgradeId = building:GetAttribute(Attrs.UpgradeId)
	local config = type(upgradeId) == "string" and UpgradeConfig[upgradeId]
	if not config or config.TemplateKind ~= "Building" then
		return false, "That building cannot be sold."
	end

	local countValue = ensureUpgradeCountValue(player, upgradeId, config)
	local minimumCount = config.InitialCount or 0
	if not countValue or countValue.Value <= minimumCount then
		return false, "You cannot sell this building."
	end

	local previousPurchaseCost = UpgradeService.GetCost(upgradeId, countValue.Value - 1) or 0
	local refund = math.floor(previousPurchaseCost * SELL_REFUND_RATIO)

	countValue.Value -= 1
	markBuildingCountAdjusted(building)
	building:Destroy()
	CookieService.AddCookies(player, refund, PlayerMetricsService.CookieSources.Refund)

	return true, "Sold " .. (config.DisplayName or upgradeId) .. " for " .. refund .. ".", upgradeId
end

function UpgradeService.SellAllBuildings(player, upgradeId)
	if type(upgradeId) ~= "string" then
		return false, "Invalid building."
	end

	local config = UpgradeConfig[upgradeId]
	if not config or config.TemplateKind ~= "Building" then
		return false, "That building cannot be sold."
	end

	local countValue = ensureUpgradeCountValue(player, upgradeId, config)
	local minimumCount = config.InitialCount or 0
	if not countValue or countValue.Value <= minimumCount then
		return false, "You have none to sell."
	end

	-- Sum the same per-building math the single sell uses, over every sellable
	-- count, so the bulk refund is exactly N individual sells.
	local soldCount = countValue.Value - minimumCount
	local refund = 0
	for count = minimumCount + 1, countValue.Value do
		local previousPurchaseCost = UpgradeService.GetCost(upgradeId, count - 1) or 0
		refund += math.floor(previousPurchaseCost * SELL_REFUND_RATIO)
	end

	countValue.Value = minimumCount
	removeAllBuildings(player, upgradeId)
	CookieService.AddCookies(player, refund, PlayerMetricsService.CookieSources.Refund)

	return true, "Sold " .. soldCount .. " " .. (config.DisplayName or upgradeId) .. " for " .. refund .. ".", upgradeId
end

function UpgradeService.SetupPlayer(player, buildingPlacements)
	UpgradeService.SyncPlayerUpgrades(player, buildingPlacements)
end

local function getDimensionPlacements(buildingPlacements)
	if type(buildingPlacements) ~= "table" then
		return nil
	end

	return buildingPlacements[DEFAULT_DIMENSION]
end

function UpgradeService.SyncPlayerUpgrades(player, buildingPlacements)
	local dimensionPlacements = getDimensionPlacements(buildingPlacements)

	for upgradeId, config in pairs(UpgradeConfig) do
		ensureUpgradeCountValue(player, upgradeId, config)
	end

	-- Expand the sheet before restoring buildings so saved placements in the
	-- expansion area validate and resume producing after rejoin.
	applyGridExpansion(player)

	for upgradeId, config in pairs(UpgradeConfig) do
		local countValue = ensureUpgradeCountValue(player, upgradeId, config)
		local minimumCount = config.InitialCount or 0
		-- PVP paused (Shared.PvpConfig): keep the saved count but don't materialize
		-- the tool/building — it falls through to the revoke/remove branch below.
		if countValue and countValue.Value > minimumCount and not PvpConfig.IsUpgradePaused(upgradeId) then
			if config.TemplateKind == "Gear" then
				grantTool(player, config)
			elseif config.TemplateKind == "Building" then
				-- Backfill: any building currently owned counts as unlocked (covers
				-- saves predating this feature, and keeps it unlocked through sells).
				markBuildingUnlocked(player, upgradeId)
				local desiredCount = countValue.Value - minimumCount
				local existingBuildings = getOwnedBuildings(player, upgradeId)
				local existingCount = #existingBuildings
				while existingCount > desiredCount do
					markBuildingCountAdjusted(existingBuildings[existingCount])
					existingBuildings[existingCount]:Destroy()
					existingCount -= 1
				end

				local sheet = SheetService.GetPlayerSheet(player) or SheetService.AssignSheet(player)
				local savedPlacements = type(dimensionPlacements) == "table" and dimensionPlacements[upgradeId] or nil
				for index = existingCount + 1, desiredCount do
					local savedCFrame = sheet and getSavedBuildingCFrame(sheet, savedPlacements and savedPlacements[index])
					placeBuilding(player, upgradeId, config, savedCFrame, index)
				end
			end
		elseif countValue then
			if config.TemplateKind == "Gear" then
				revokeTool(player, config)
			elseif config.TemplateKind == "Building" then
				removeAllBuildings(player, upgradeId)
			end
		end
	end

	UpgradeService.ApplyPlayerCharacterStats(player)
end

function UpgradeService.ApplyPlayerCharacterStats(player, character)
	applyPlayerMaxHealth(player, character)
end

-- §4c effect queries: consumers derive entitlements from upgrade counts.
-- Reset (cookie economy) wipes building unlocks back to locked. GC/skins survive
-- resets (invariant 7), but buildings are cookie-economy progression.
function UpgradeService.ClearUnlockedBuildings(player)
	player:SetAttribute(UNLOCKED_BUILDINGS_ATTRIBUTE, "{}")
end

function UpgradeService.GetEffectTotal(player, effectName)
	return getEffectTotal(player, effectName)
end

function UpgradeService.HasEffect(player, effectName)
	return hasEffect(player, effectName)
end

-- Walk up from a prompt to the CookieSheet model that owns it (has a SheetOwner value).
local function sheetFromPrompt(prompt)
	local node = prompt.Parent
	while node and node ~= game do
		if node:IsA("Model") and node:FindFirstChild("SheetOwner") then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- Physical ExpansionButton press: buy a Base Expansion for the plot's owner (reusing the
-- full purchase pipeline — cost check, count, GridExpansion effect). Optionally gated on the
-- portal item for the first expansion.
local function handleExpansionPrompt(player, prompt)
	local sheet = sheetFromPrompt(prompt)
	local owner = sheet and sheet:FindFirstChild("SheetOwner")
	if not (owner and owner.Value == player) then
		return -- only the plot's owner can expand it
	end

	if RING1_PORTAL_GATE_ENABLED then
		local countValue = getUpgradeCountValue(player, "Base Expansion")
		local count = countValue and countValue.Value or 0
		if count == 0 and not player:GetAttribute(PORTAL_UNLOCK_ATTRIBUTE) then
			return -- first expansion gated behind the portal item
		end
	end

	UpgradeService.Purchase(player, "Base Expansion")
	updateExpansionButton(player)
end

-- Collecting the OtherDimension ExpansionItem unlocks the first (ring-1) expansion.
local function handleExpansionItemCollect(player)
	player:SetAttribute(PORTAL_UNLOCK_ATTRIBUTE, true)
	updateExpansionButton(player)
end

function UpgradeService.Init()
	local Names = Net.Names

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name == "ExpandPrompt" then
			handleExpansionPrompt(player, prompt)
		elseif prompt.Name == "CollectPrompt" then
			handleExpansionItemCollect(player)
		end
	end)

	-- Pre-create the request/response channels so a client that boots first finds them
	-- immediately instead of hanging at WaitForChild until the first purchase/sell.
	Net.fn(Names.PurchaseUpgrade)
	Net.fn(Names.SellUpgrade)

	-- Request/response: the result returns to the calling client (Net.onInvoke pcall-isolates
	-- the handler and substitutes a failure table on error). `upgradeId` is echoed back so the
	-- building-sell path (which sends an Instance) can tell the client which row to refresh.
	Net.onInvoke(Names.PurchaseUpgrade, function(player, upgradeId, placementCFrame)
		if type(upgradeId) ~= "string" then
			return { success = false, message = "Invalid upgrade." }
		end

		local success, message = UpgradeService.Purchase(player, upgradeId, placementCFrame)
		return { success = success, message = message, upgradeId = upgradeId }
	end)

	Net.onInvoke(Names.SellUpgrade, function(player, upgradeId)
		if typeof(upgradeId) == "Instance" then
			local success, message, soldUpgradeId = UpgradeService.SellBuilding(player, upgradeId)
			return { success = success, message = message, upgradeId = soldUpgradeId }
		end

		if type(upgradeId) ~= "string" then
			return { success = false, message = "Invalid upgrade." }
		end

		local success, message = UpgradeService.Sell(player, upgradeId)
		return { success = success, message = message, upgradeId = upgradeId }
	end)

	Net.onInvoke(Names.SellAll, function(player, upgradeId)
		local success, message, soldUpgradeId = UpgradeService.SellAllBuildings(player, upgradeId)
		return { success = success, message = message, upgradeId = soldUpgradeId }
	end)

	Net.on(Names.DamageBuilding, function(player, targetPart, hitPosition)
		UpgradeService.DamageBuilding(player, targetPart, hitPosition)
	end)

	print("UpgradeService initialized")
end

return UpgradeService
