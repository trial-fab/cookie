-- FloorGeometry: resolves Studio-authored placement markers or a deterministic,
-- non-player-facing fallback surface while floor geometry is still absent.
--
-- Authored contract under each CookieSheet:
--   Floors/<FloorId>/PlacementBounds (BasePart)
--   Floors/<FloorId>/PlacementBounds/PlacementOrigin (Attachment)
-- Ground continues to use CookieSheet.Base.
local FloorConfig = require(script.Parent.FloorConfig)
local GridPlacement = require(script.Parent.GridPlacement)

local FloorGeometry = {}

local function getGroundBase(sheet)
	local base = sheet and sheet:FindFirstChild("Base")
	return base and base:IsA("BasePart") and base or nil
end

function FloorGeometry.GetFloorModel(sheet, floorId)
	local definition = FloorConfig.Get(floorId)
	if not definition or definition.Order == 0 then
		return nil
	end

	local floors = sheet and sheet:FindFirstChild(FloorConfig.Geometry.FloorsContainerName)
	local model = floors and floors:FindFirstChild(definition.GeometryName or definition.Id)
	return model and model:IsA("Model") and model or nil
end

local function getAuthoredSurface(sheet, definition)
	local model = FloorGeometry.GetFloorModel(sheet, definition.Id)
	local bounds = model and model:FindFirstChild(FloorConfig.Geometry.PlacementBoundsName, true)
	if not (bounds and bounds:IsA("BasePart")) then
		return nil
	end

	local origin = bounds:FindFirstChild(FloorConfig.Geometry.PlacementOriginName)
	local originCFrame = origin and origin:IsA("Attachment") and origin.WorldCFrame
		or GridPlacement.getPlacementAnchorCFrame(bounds)
	return {
		floorId = definition.Id,
		cframe = bounds.CFrame,
		size = bounds.Size,
		originCFrame = originCFrame,
		boundsPart = bounds,
		floorModel = model,
		isFallback = false,
	}
end

local function getDerivedSurface(sheet, definition)
	local base = getGroundBase(sheet)
	if not base then
		return nil
	end

	-- The fallback has no guessed height constant: each level is separated by the
	-- larger authored Ground span. It exists only for save/load and logic tests until
	-- Studio supplies PlacementBounds; authored markers replace it automatically.
	local stackSpan = math.max(base.Size.X, base.Size.Z)
	local cframe = base.CFrame * CFrame.new(0, stackSpan * definition.Order, 0)
	return {
		floorId = definition.Id,
		cframe = cframe,
		size = base.Size,
		originCFrame = cframe * CFrame.new(0, 0, -base.Size.Z / 2),
		boundsPart = nil,
		floorModel = FloorGeometry.GetFloorModel(sheet, definition.Id),
		isFallback = definition.Order > 0,
	}
end

function FloorGeometry.GetSurface(sheet, floorId)
	local definition = FloorConfig.Get(floorId)
	if not definition then
		return nil
	end

	if definition.Order == 0 then
		local base = getGroundBase(sheet)
		if not base then
			return nil
		end
		return {
			floorId = definition.Id,
			cframe = base.CFrame,
			size = base.Size,
			originCFrame = GridPlacement.getPlacementAnchorCFrame(base),
			boundsPart = base,
			floorModel = nil,
			isFallback = false,
		}
	end

	return getAuthoredSurface(sheet, definition) or getDerivedSurface(sheet, definition)
end

return FloorGeometry
