-- FloorGeometry: resolves Studio-authored placement markers or a deterministic,
-- non-player-facing fallback surface while floor geometry is still absent.
--
-- Authored contract under each CookieSheet:
--   Floors/<FloorId>/PlacementBounds (BasePart)
--   Floors/<FloorId>/PlacementBounds/PlacementOrigin (Attachment)
-- Ground continues to use CookieSheet.Base.
--
-- It also owns the QUERY half of a surface (ray/plane intersection, containment, top-of-surface
-- points). Those live here rather than in one caller because placement, boost fields, and the
-- server's authoritative drop resolution must all agree on where a surface is: a raycast against
-- world geometry answers a different question (it lands on whatever building or prop is in the
-- way) and drifts from the plane the server actually places on.
local FloorConfig = require(script.Parent.FloorConfig)
local GridPlacement = require(script.Parent.GridPlacement)

local FloorGeometry = {}

local PLANE_EPSILON = 1e-6
local BOUNDS_EPSILON = 1e-4

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
	-- The promoted terraced floors already carry one exact, minimum-part build
	-- surface named Base. Reuse it when a dedicated marker is absent instead of
	-- layering an overlapping invisible part over approved geometry.
	if not (bounds and bounds:IsA("BasePart")) then
		bounds = model and model:FindFirstChild("Base")
	end
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

-- Ordered Ground-first list of the surfaces the player may build on right now: Ground
-- plus every unlocked floor with authored geometry. Derived fallback surfaces are
-- logic-only (save/load and tests), so they are excluded -- player-facing systems
-- (placement grids, Build View fly bounds) must never present a surface that does not
-- physically exist. unlockedCount is the caller-resolved UnlockedFloorCount attribute.
function FloorGeometry.GetUnlockedSurfaces(sheet, unlockedCount)
	unlockedCount = math.clamp(
		math.floor(tonumber(unlockedCount) or 0),
		0,
		FloorConfig.UnlockableFloorCount
	)
	local surfaces = {}
	for _, definition in ipairs(FloorConfig.GetDefinitions()) do
		if definition.Order <= unlockedCount then
			local surface = FloorGeometry.GetSurface(sheet, definition.Id)
			if surface and (definition.Order == 0 or not surface.isFallback) then
				table.insert(surfaces, surface)
			end
		end
	end
	return surfaces
end

-- ── Surface queries ─────────────────────────────────────────────────────────────

-- World point on the top face of `surface` directly above/below `position`, ignoring the point's
-- own height. This is where anything "sitting on the floor" belongs, and the single definition
-- both the placement ghost and the server's field drop use so they cannot disagree.
function FloorGeometry.GetTopPosition(surface, position, lift)
	local localPosition = surface.cframe:PointToObjectSpace(position)
	return surface.cframe:PointToWorldSpace(
		Vector3.new(localPosition.X, surface.size.Y / 2 + (lift or 0), localPosition.Z)
	)
end

-- Where `ray` crosses the surface's top plane. `requireBounds` rejects a hit outside the surface
-- rectangle; without it the caller gets the unbounded plane point (used to keep a ghost moving
-- when the pointer wanders past the plot edge, before clamping it back in).
function FloorGeometry.IntersectRay(ray, surface, requireBounds)
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

-- Nearest in-bounds surface the ray crosses. Returns surface, hitPosition, distance.
function FloorGeometry.FindSurfaceAlongRay(ray, surfaces)
	local bestSurface, bestHit = nil, nil
	local bestDistance = math.huge
	for _, surface in ipairs(surfaces) do
		local hitPosition, distance = FloorGeometry.IntersectRay(ray, surface, true)
		if hitPosition and distance < bestDistance then
			bestSurface, bestHit, bestDistance = surface, hitPosition, distance
		end
	end
	return bestSurface, bestHit, bestDistance
end

-- Pulls `position` inside the surface rectangle and onto its top face. A point already inside is
-- only lifted onto the surface, so this is safe to apply unconditionally.
function FloorGeometry.ClampToSurface(surface, position, lift)
	local localPosition = surface.cframe:PointToObjectSpace(position)
	return surface.cframe:PointToWorldSpace(Vector3.new(
		math.clamp(localPosition.X, -surface.size.X / 2, surface.size.X / 2),
		surface.size.Y / 2 + (lift or 0),
		math.clamp(localPosition.Z, -surface.size.Z / 2, surface.size.Z / 2)
	))
end

-- The surface `position` sits on, choosing the CLOSEST one vertically rather than the first that
-- happens to match: a terraced stack puts several floors within any usable tolerance, and picking
-- by iteration order would bind a field to whichever floor the definition list named first.
function FloorGeometry.FindSurfaceAtPoint(surfaces, position, toleranceY)
	local bestSurface = nil
	local bestOffset = math.huge
	for _, surface in ipairs(surfaces) do
		local localPosition = surface.cframe:PointToObjectSpace(position)
		local offsetY = math.abs(localPosition.Y) - surface.size.Y / 2
		if
			math.abs(localPosition.X) <= surface.size.X / 2 + BOUNDS_EPSILON
			and math.abs(localPosition.Z) <= surface.size.Z / 2 + BOUNDS_EPSILON
			and offsetY <= toleranceY
			and offsetY < bestOffset
		then
			bestSurface, bestOffset = surface, offsetY
		end
	end
	return bestSurface
end

return FloorGeometry
