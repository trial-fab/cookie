-- Shared grid-placement math for building placement.
-- Owns snapping, bounds, footprint sizing/CFrame, and overlap-region math so the
-- server validation (UpgradeService) and the client preview (StoreController) can
-- never drift. Parameterized by a building's FootprintCells (default {1, 1}).
--
-- Conventions:
--   * Local coordinates are relative to the sheet's Base part (Base.CFrame space).
--   * Odd-width footprints snap to cell CENTERS; even-width footprints snap to cell
--     CORNERS (grid lines). A 1x1 footprint reproduces the legacy single-cell math
--     exactly.
--   * Bounds clamp the snapped center by the footprint's half-extent so the whole
--     footprint stays on the Base.
local GridPlacement = {}

local GRID_SIZE = 6
local GRID_HEIGHT = 0.6
-- Matches the shield/placement edge tolerance the server and client used before
-- this module existed; keeps overlap acceptance identical for 1x1 footprints.
local EDGE_TOLERANCE = 0.15
-- A footprint placed flush on top of the Base sits half a grid-height above it,
-- plus a small bias to avoid z-fighting with the Base surface.
local SURFACE_BIAS = 0.06

GridPlacement.GRID_SIZE = GRID_SIZE
GridPlacement.GRID_HEIGHT = GRID_HEIGHT
GridPlacement.EDGE_TOLERANCE = EDGE_TOLERANCE
GridPlacement.DEFAULT_FOOTPRINT_CELLS = { 1, 1 }

-- Resolve a config's footprint (in cells) for each plot axis, accounting for a
-- 90/270-degree rotation that swaps the width/depth axes. Square footprints
-- (e.g. Portal {2, 2}) are unaffected by rotation.
function GridPlacement.getFootprintCells(config, rotationY)
	local cells = (config and config.FootprintCells) or GridPlacement.DEFAULT_FOOTPRINT_CELLS
	local width = math.max(1, math.floor(tonumber(cells[1]) or 1))
	local depth = math.max(1, math.floor(tonumber(cells[2]) or 1))

	if rotationY then
		-- Snap rotation to the nearest quarter turn; an odd quarter turn swaps axes.
		local quarter = math.floor((rotationY / (math.pi / 2)) + 0.5) % 2
		if quarter == 1 then
			width, depth = depth, width
		end
	end

	return width, depth
end

-- World-space size of a footprint occupying cellsX x cellsZ cells.
function GridPlacement.getFootprintSize(cellsX, cellsZ)
	return Vector3.new(cellsX * GRID_SIZE, GRID_HEIGHT, cellsZ * GRID_SIZE)
end

-- Snap one local axis coordinate for a footprint that is `cells` wide on that axis.
-- Odd -> cell center; even -> cell corner (grid line).
function GridPlacement.snapAxis(value, cells)
	if cells % 2 == 0 then
		return math.floor(value / GRID_SIZE + 0.5) * GRID_SIZE
	end
	return math.floor(value / GRID_SIZE) * GRID_SIZE + GRID_SIZE / 2
end

-- Min/max snapped center for one axis, clamped so the footprint's half-extent stays
-- within a Base of the given size. For cells == 1 this matches the legacy
-- getGridCenterBounds exactly (e.g. size 132 -> -63, 63).
function GridPlacement.getAxisBounds(size, cells)
	local halfSpan = math.floor(size / GRID_SIZE / 2) * GRID_SIZE
	if halfSpan <= 0 then
		return 0, 0
	end

	local inset = cells * GRID_SIZE / 2
	return -halfSpan + inset, halfSpan - inset
end

-- Resolve a hit point (in Base-local space) to a snapped footprint center.
-- Returns a table with both the raw snapped coordinate and the bounds-clamped one,
-- plus whether the raw snap was already in bounds:
--   server rejects when `inBounds` is false; client uses the clamped coordinate so
--   the preview slides along the plot edge.
function GridPlacement.solvePlacement(localPosition, baseSize, cellsX, cellsZ)
	local snappedX = GridPlacement.snapAxis(localPosition.X, cellsX)
	local snappedZ = GridPlacement.snapAxis(localPosition.Z, cellsZ)
	local minX, maxX = GridPlacement.getAxisBounds(baseSize.X, cellsX)
	local minZ, maxZ = GridPlacement.getAxisBounds(baseSize.Z, cellsZ)

	local inBounds = minX <= maxX
		and minZ <= maxZ
		and snappedX >= minX
		and snappedX <= maxX
		and snappedZ >= minZ
		and snappedZ <= maxZ

	return {
		snappedX = snappedX,
		snappedZ = snappedZ,
		clampedX = math.clamp(snappedX, math.min(minX, maxX), math.max(minX, maxX)),
		clampedZ = math.clamp(snappedZ, math.min(minZ, maxZ), math.max(minZ, maxZ)),
		inBounds = inBounds,
	}
end

-- CFrame of the footprint plane (flush on the Base surface) for a snapped center.
function GridPlacement.getFootprintCFrame(baseCFrame, baseSizeY, localX, localZ)
	return baseCFrame * CFrame.new(localX, baseSizeY / 2 + GRID_HEIGHT / 2 + SURFACE_BIAS, localZ)
end

-- XZ axis-aligned overlap test between a footprint and an arbitrary part (e.g. the
-- blocked center pad). Uses the shared edge tolerance.
function GridPlacement.footprintOverlapsPartXZ(footprintCFrame, footprintSize, part)
	local localPosition = part.CFrame:PointToObjectSpace(footprintCFrame.Position)
	local halfX = part.Size.X / 2 + footprintSize.X / 2 - EDGE_TOLERANCE
	local halfZ = part.Size.Z / 2 + footprintSize.Z / 2 - EDGE_TOLERANCE
	return math.abs(localPosition.X) < halfX and math.abs(localPosition.Z) < halfZ
end

-- Size of the physics query box for a footprint-overlap check (GetPartBoundsInBox).
-- Insets XZ slightly so flush-adjacent footprints don't register as overlapping.
function GridPlacement.getOverlapQuerySize(footprintSize)
	return Vector3.new(
		math.max(0.1, footprintSize.X - 0.2),
		footprintSize.Y + 2,
		math.max(0.1, footprintSize.Z - 0.2)
	)
end

-- Fixed placement anchor: the plot's INNER (hub-facing) edge midpoint, with +Z still
-- pointing outward (same rotation as the Base). Persisted building offsets are stored
-- relative to THIS frame instead of Base.CFrame, so they stay put when the Base grows
-- outward (the inner edge never moves; only the outer edge and center advance). Local Z
-- is the depth/radial axis; the inner edge sits at the Base's local -Z face.
function GridPlacement.getPlacementAnchorCFrame(base)
	return base.CFrame * CFrame.new(0, 0, -base.Size.Z / 2)
end

return GridPlacement
