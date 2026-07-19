-- StoreFloorPlacement: owns the temporary placement grids and direct-aim floor
-- selection shared by mouse and touch placement. Every unlocked authored surface
-- is visible while placement is active; only a pointer/tap ray changes floors after
-- initialization, so camera movement alone never changes the active floor.
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local FloorConfig = require(Shared:WaitForChild("FloorConfig"))
local FloorGeometry = require(Shared:WaitForChild("FloorGeometry"))

local StoreFloorPlacement = {}

local ACTIVE_TRANSPARENCY_ID = "FloorGrids.ActiveTransparency"
local INACTIVE_TRANSPARENCY_ID = "FloorGrids.InactiveTransparency"
local PLANE_EPSILON = 1e-6
local BOUNDS_EPSILON = 1e-4
local GRID_HEIGHT_OFFSET = 0.04
local GRID_LINE_THICKNESS = 0.08

local function asBase(surface)
	if not surface then
		return nil
	end
	return surface.boundsPart
		or {
			CFrame = surface.cframe,
			Position = surface.cframe.Position,
			Size = surface.size,
		}
end

function StoreFloorPlacement.new(ctx)
	local player = ctx.player
	local mouse = ctx.mouse
	local screenGui = ctx.screenGui
	local gridSize = ctx.GridPlacement.GRID_SIZE

	local placementActive = false
	local gridsRoot = nil
	local gridsByFloorId = {}
	local surfacesByFloorId = {}
	local observations = {}
	local availabilityChanged = nil
	local initialHitPosition = nil
	local activeTransparency = DevTuning.get(ACTIVE_TRANSPARENCY_ID)
	local inactiveTransparency = DevTuning.get(INACTIVE_TRANSPARENCY_ID)

	local function getPlayerSheet()
		local cookieSheets = Workspace:FindFirstChild("CookieSheets")
		if not cookieSheets then
			return nil
		end
		for _, sheet in ipairs(cookieSheets:GetChildren()) do
			local owner = sheet:FindFirstChild("SheetOwner")
			if owner and owner.Value == player then
				return sheet
			end
		end
		return nil
	end

	local function getUnlockedCount()
		return math.clamp(
			math.floor(tonumber(player:GetAttribute(Attrs.UnlockedFloorCount)) or 0),
			0,
			FloorConfig.UnlockableFloorCount
		)
	end

	local function refreshSurfaces()
		table.clear(surfacesByFloorId)
		local sheet = getPlayerSheet()
		if not sheet then
			return
		end

		-- Shared resolver (also drives the Build View fly bounds): Ground plus unlocked
		-- authored floors only; derived fallback surfaces never become player-facing grids.
		for _, surface in ipairs(FloorGeometry.GetUnlockedSurfaces(sheet, getUnlockedCount())) do
			surfacesByFloorId[surface.floorId] = surface
		end
	end

	local function getActiveFloorId()
		local requested = FloorConfig.NormalizeId(screenGui:GetAttribute(Attrs.ActiveFloorId))
		if surfacesByFloorId[requested] then
			return requested
		end
		if surfacesByFloorId[FloorConfig.GroundFloorId] then
			return FloorConfig.GroundFloorId
		end
		return next(surfacesByFloorId)
	end

	local function setGridTransparency(grid, transparency)
		if not grid then
			return
		end
		for _, line in ipairs(grid:GetChildren()) do
			if line:IsA("BasePart") then
				line.Transparency = transparency
			end
		end
	end

	local function refreshGridEmphasis()
		local activeFloorId = getActiveFloorId()
		for floorId, grid in pairs(gridsByFloorId) do
			local isActive = floorId == activeFloorId
			grid:SetAttribute(Attrs.Active, isActive)
			setGridTransparency(grid, isActive and activeTransparency or inactiveTransparency)
		end
	end

	local function setGridColor(grid, color)
		if not grid or typeof(color) ~= "Color3" then
			return
		end
		for _, line in ipairs(grid:GetChildren()) do
			if line:IsA("BasePart") then
				line.Color = color
			end
		end
	end

	local function createGrid(surface, definition)
		local grid = Instance.new("Model")
		grid.Name = "PlacementGrid_" .. definition.Id
		grid:SetAttribute(Attrs.FloorId, definition.Id)

		local halfX = math.floor(surface.size.X / gridSize / 2)
		local halfZ = math.floor(surface.size.Z / gridSize / 2)
		local lineColor = DevTuning.get(definition.GridColorTuningId)

		for x = -halfX, halfX do
			local line = Instance.new("Part")
			line.Name = "GridLine"
			line.Anchored = true
			line.CanCollide = false
			line.CanQuery = false
			line.CanTouch = false
			line.Material = Enum.Material.Neon
			line.Color = lineColor
			line.Size = Vector3.new(GRID_LINE_THICKNESS, GRID_LINE_THICKNESS, surface.size.Z)
			line.CFrame = surface.cframe * CFrame.new(x * gridSize, surface.size.Y / 2 + GRID_HEIGHT_OFFSET, 0)
			line.Parent = grid
		end

		for z = -halfZ, halfZ do
			local line = Instance.new("Part")
			line.Name = "GridLine"
			line.Anchored = true
			line.CanCollide = false
			line.CanQuery = false
			line.CanTouch = false
			line.Material = Enum.Material.Neon
			line.Color = lineColor
			line.Size = Vector3.new(surface.size.X, GRID_LINE_THICKNESS, GRID_LINE_THICKNESS)
			line.CFrame = surface.cframe * CFrame.new(0, surface.size.Y / 2 + GRID_HEIGHT_OFFSET, z * gridSize)
			line.Parent = grid
		end

		grid.Parent = gridsRoot
		gridsByFloorId[definition.Id] = grid
		table.insert(
			observations,
			DevTuning.observe(definition.GridColorTuningId, function(color)
				if gridsByFloorId[definition.Id] == grid then
					setGridColor(grid, color)
				end
			end)
		)
	end

	local function clearGrids()
		for _, observation in ipairs(observations) do
			observation:Disconnect()
		end
		table.clear(observations)
		table.clear(gridsByFloorId)
		if gridsRoot then
			gridsRoot:Destroy()
			gridsRoot = nil
		end
	end

	local function buildGrids()
		clearGrids()
		gridsRoot = Instance.new("Model")
		gridsRoot.Name = "PlacementGrids"
		gridsRoot.Parent = Workspace

		for _, definition in ipairs(FloorConfig.GetDefinitions()) do
			local surface = surfacesByFloorId[definition.Id]
			if surface then
				createGrid(surface, definition)
			end
		end

		table.insert(
			observations,
			DevTuning.observe(ACTIVE_TRANSPARENCY_ID, function(value)
				activeTransparency = value
				refreshGridEmphasis()
			end)
		)
		table.insert(
			observations,
			DevTuning.observe(INACTIVE_TRANSPARENCY_ID, function(value)
				inactiveTransparency = value
				refreshGridEmphasis()
			end)
		)
		refreshGridEmphasis()
	end

	local function setActiveFloor(floorId)
		if not surfacesByFloorId[floorId] then
			floorId = surfacesByFloorId[FloorConfig.GroundFloorId] and FloorConfig.GroundFloorId
				or next(surfacesByFloorId)
		end
		if not floorId then
			return false
		end

		local changed = screenGui:GetAttribute(Attrs.ActiveFloorId) ~= floorId
		if changed then
			screenGui:SetAttribute(Attrs.ActiveFloorId, floorId)
		end
		refreshGridEmphasis()
		return changed
	end

	local function intersectSurface(ray, surface, requireBounds)
		local direction = ray.Direction
		if direction.Magnitude <= PLANE_EPSILON then
			return nil
		end
		direction = direction.Unit
		local normal = surface.cframe.UpVector
		local denominator = direction:Dot(normal)
		if math.abs(denominator) < PLANE_EPSILON then
			return nil
		end

		local planePoint = surface.cframe:PointToWorldSpace(Vector3.new(0, surface.size.Y / 2, 0))
		local distance = (planePoint - ray.Origin):Dot(normal) / denominator
		if distance < 0 then
			return nil
		end

		local hitPosition = ray.Origin + direction * distance
		if requireBounds then
			local localPosition = surface.cframe:PointToObjectSpace(hitPosition)
			if
				math.abs(localPosition.X) > surface.size.X / 2 + BOUNDS_EPSILON
				or math.abs(localPosition.Z) > surface.size.Z / 2 + BOUNDS_EPSILON
			then
				return nil
			end
		end
		return hitPosition, distance
	end

	local function findSurfaceAlongRay(ray)
		local bestFloorId = nil
		local bestHitPosition = nil
		local bestDistance = math.huge
		for floorId, surface in pairs(surfacesByFloorId) do
			local hitPosition, distance = intersectSurface(ray, surface, true)
			if hitPosition and distance < bestDistance then
				bestFloorId = floorId
				bestHitPosition = hitPosition
				bestDistance = distance
			end
		end
		return bestFloorId, bestHitPosition
	end

	local function getPointerRay(screenPosition)
		local camera = Workspace.CurrentCamera
		if not camera then
			return nil
		end
		if screenPosition then
			return camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
		end
		return mouse.UnitRay
	end

	local function chooseClosestToCharacter()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return nil
		end

		local bestFloorId = nil
		local bestHitPosition = nil
		local bestDistance = math.huge
		for floorId, surface in pairs(surfacesByFloorId) do
			local localPosition = surface.cframe:PointToObjectSpace(root.Position)
			local closestLocal = Vector3.new(
				math.clamp(localPosition.X, -surface.size.X / 2, surface.size.X / 2),
				surface.size.Y / 2,
				math.clamp(localPosition.Z, -surface.size.Z / 2, surface.size.Z / 2)
			)
			local closestWorld = surface.cframe:PointToWorldSpace(closestLocal)
			local distance = (root.Position - closestWorld).Magnitude
			if distance < bestDistance then
				bestFloorId = floorId
				bestHitPosition = closestWorld
				bestDistance = distance
			end
		end
		return bestFloorId, bestHitPosition
	end

	local function chooseFromCameraCenter()
		local camera = Workspace.CurrentCamera
		if not camera then
			return nil
		end
		local viewport = camera.ViewportSize
		local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
		return findSurfaceAlongRay(ray)
	end

	local function chooseInitialFloor()
		local floorId = nil
		local hitPosition = nil
		if screenGui:GetAttribute(Attrs.BuildModeActive) == true then
			floorId, hitPosition = chooseFromCameraCenter()
		else
			floorId, hitPosition = chooseClosestToCharacter()
		end
		if not floorId then
			local previous = FloorConfig.NormalizeId(screenGui:GetAttribute(Attrs.ActiveFloorId))
			floorId = surfacesByFloorId[previous] and previous or FloorConfig.GroundFloorId
		end
		setActiveFloor(floorId)
		local surface = surfacesByFloorId[getActiveFloorId()]
		initialHitPosition = hitPosition
			or (surface and surface.cframe:PointToWorldSpace(Vector3.new(0, surface.size.Y / 2, 0)))
	end

	local function refreshAvailability()
		local previousFloorId = getActiveFloorId()
		refreshSurfaces()
		if not placementActive then
			if not surfacesByFloorId[previousFloorId] then
				setActiveFloor(FloorConfig.GroundFloorId)
			end
			return
		end

		buildGrids()
		local changed = setActiveFloor(previousFloorId)
		if changed then
			local surface = surfacesByFloorId[getActiveFloorId()]
			initialHitPosition = surface and surface.cframe:PointToWorldSpace(Vector3.new(0, surface.size.Y / 2, 0))
				or nil
		end
		if availabilityChanged then
			availabilityChanged(getActiveFloorId(), changed)
		end
	end

	player:GetAttributeChangedSignal(Attrs.UnlockedFloorCount):Connect(refreshAvailability)

	local api = {}

	function api.begin(onAvailabilityChanged)
		placementActive = true
		availabilityChanged = onAvailabilityChanged
		refreshSurfaces()
		buildGrids()
		chooseInitialFloor()
	end

	function api.stop()
		placementActive = false
		availabilityChanged = nil
		initialHitPosition = nil
		clearGrids()
	end

	function api.getActiveFloorId()
		return getActiveFloorId() or FloorConfig.GroundFloorId
	end

	function api.getActiveBase()
		return asBase(surfacesByFloorId[getActiveFloorId()])
	end

	function api.resolveInitial()
		return api.getActiveBase(), initialHitPosition, false
	end

	function api.resolvePointer(screenPosition)
		local ray = getPointerRay(screenPosition)
		if not ray then
			return api.getActiveBase(), nil, false
		end

		local floorId, hitPosition = findSurfaceAlongRay(ray)
		local changed = false
		if floorId then
			changed = setActiveFloor(floorId)
			return asBase(surfacesByFloorId[floorId]), hitPosition, changed
		end

		local activeSurface = surfacesByFloorId[getActiveFloorId()]
		local fallbackHit = activeSurface and intersectSurface(ray, activeSurface, false) or nil
		return asBase(activeSurface), fallbackHit, false
	end

	return api
end

return StoreFloorPlacement
