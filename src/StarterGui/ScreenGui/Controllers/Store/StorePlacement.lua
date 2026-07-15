-- StorePlacement: the building placement flow + on-ground control buttons, plus sell-by-
-- click/tap. Owns all placement state (preview model, footprint, grid, rotation, the pad
-- table) and the sell highlight. Projects the pointer onto the plot Base analytically and
-- mirrors GridPlacement so the local preview can't drift from server validation. Reads
-- sellMode/currentCategory via ctx getters and reports via ctx.showStatus.
-- Exposes start(upgradeId), tick() (RenderStepped), and handleInputBegan/Ended/Changed
-- (wired to UserInputService by the orchestrator). Signals BuildViewController via the
-- screenGui PlacementActive attribute.
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local SettingsConfig = require(Shared:WaitForChild("SettingsConfig"))

local StorePlacement = {}

function StorePlacement.new(ctx)
	local player = ctx.player
	local mouse = ctx.mouse
	local screenGui = ctx.screenGui
	local UpgradeConfig = ctx.UpgradeConfig
	local buildingPreviews = ctx.buildingPreviews
	local GridPlacement = ctx.GridPlacement
	-- Purchase/Sell go through ctx.invokePurchase / ctx.invokeSell (RemoteFunction request/
	-- response). They're referenced at call time, not captured here, because the orchestrator
	-- binds them onto ctx after constructing this module.

	local GRID_SIZE = GridPlacement.GRID_SIZE

	-- Gap (studs) between the building footprint edge and the nearest control button —
	-- kept small so the bundle hugs the building. Negative pulls the bundle inward, over
	-- the building's edge, bringing the controls closer to the center.
	local CONTROL_GAP = -1

	local placementUpgradeId = nil
	local placementPreview = nil
	local placementHighlight = nil
	local placementFootprint = nil
	local placementGrid = nil
	local placementCFrame = nil
	local placementIsValid = false
	local placementRotation = 0
	local rememberedPlacementRotation = 0
	local placementStartedAt = 0
	local lastPlacementScreenPosition = nil
	local activePlacementTouch = nil
	local placementPurchaseInFlight = false
	-- Touch bookkeeping so a two-finger camera gesture (pinch/rotate) never also drags the
	-- ghost: while 2+ fingers are down we freeze the ghost, and the finger left behind after a
	-- pinch is ignored until ALL fingers lift (mirrors the camera's own multi-touch discipline).
	local placementTouchCount = 0
	local placementMultiTouch = false
	local placementMouseDown = false -- PC pad mode: left button held → dragging the ghost
	-- All placement-control state lives in one table. Fields:
	--   controls     the cloned control model (3 button discs) while placement is live
	--   buttonParts  { cancel=, confirm=, rotate= } disc parts, repositioned each move
	--   lastLocal    last sampled Base-local hit point, reused so Rotate can re-pivot in
	--                place and the ghost can hold its grid spot without chasing the cursor
	--   lastOnBase   whether that sampled point was on the Base
	--   template     the Studio-authored PlacementControls template (ReplicatedStorage);
	--                absent → no buttons shown
	local pad = {
		controls = nil,
		buttonParts = nil,
		-- Rigid-bundle data captured from the Studio template at clone time + the ghost's
		-- current footprint, used to re-anchor the whole bundle to the camera-facing edge:
		offsets = nil, -- { name = CFrame } each button relative to the cluster center
		inwardReach = 0, -- studs the bundle reaches toward the building (template -Z)
		heightOffset = 0, -- lift so the discs rest just above the Base top
		clampedX = nil,
		clampedZ = nil,
		footprintSize = nil,
		lastLocal = nil,
		lastOnBase = false,
		template = ReplicatedStorage:FindFirstChild("PlacementControls"),
	}
	local sellHighlight = nil
	local hoveredSellBuilding = nil

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

	local function getBuildingFromTarget(target)
		if not target then
			return nil
		end

		local sheet = getPlayerSheet()
		if not sheet then
			return nil
		end

		local candidate = target
		while candidate and candidate ~= sheet do
			if candidate:IsA("Model") and candidate.Parent == sheet and candidate:GetAttribute(Attrs.UpgradeId) then
				return candidate
			end
			candidate = candidate.Parent
		end

		return nil
	end

	local function getPlacementBasePart(sheet)
		local base = sheet and sheet:FindFirstChild("Base")
		if base and base:IsA("BasePart") then
			return base
		end

		return nil
	end

	-- Project a pointer ray onto the Base's top surface PLANE analytically rather than
	-- raycasting the scene. Raycasting hit whatever was nearest the camera — including the
	-- transparent MainShield dome (its ShieldParts have CanQuery=true) and tall buildings —
	-- so once the Build View camera dropped below the shield roof the ray struck the shield
	-- and placement broke. A plane projection ignores every occluder and works at any zoom.
	-- Returns (worldHitPosition, isOnBase) or (nil, false) if the ray can't meet the plane.
	local function getBasePlaneHit(base, screenPosition)
		local camera = Workspace.CurrentCamera
		if not base or not camera then
			return nil, false
		end

		local ray
		if screenPosition then
			ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
		else
			ray = mouse.UnitRay -- PC cursor; camera-relative, no GUI-inset math needed
		end

		local origin = ray.Origin
		local dir = ray.Direction.Unit
		local normal = base.CFrame.UpVector
		local denom = dir:Dot(normal)
		if math.abs(denom) < 1e-6 then
			return nil, false -- ray parallel to the surface
		end

		local planePoint = base.CFrame:PointToWorldSpace(Vector3.new(0, base.Size.Y / 2, 0))
		local t = (planePoint - origin):Dot(normal) / denom
		if t < 0 then
			return nil, false -- plane is behind the camera
		end

		local hit = origin + dir * t
		local localPosition = base.CFrame:PointToObjectSpace(hit)
		local isOnBase = math.abs(localPosition.X) <= base.Size.X / 2
			and math.abs(localPosition.Z) <= base.Size.Z / 2
		return hit, isOnBase
	end

	local function getBuildingFromScreenPosition(screenPosition)
		local sheet = getPlayerSheet()
		local camera = Workspace.CurrentCamera
		if not sheet or not camera or not screenPosition then
			return nil
		end

		local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Include
		raycastParams.FilterDescendantsInstances = { sheet }

		local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, raycastParams)
		if not result then
			return nil
		end

		return getBuildingFromTarget(result.Instance)
	end

	local function getBlockedCenterPart(sheet)
		local center = sheet and sheet:FindFirstChild("Center")
		if center and center:IsA("BasePart") then
			return center
		end

		return nil
	end

	-- Whether the on-ground control buttons (rotate/cancel/confirm) are active. Mirrors the
	-- SettingsController preference + its device-aware default (touch-only on, mouse off)
	-- so the two stay in sync regardless of which controller set the attribute first.
	function pad.enabled()
		local pref = screenGui:GetAttribute(Attrs.PlacementControlsEnabled)
		if pref == nil then
			local deviceType = SettingsConfig.GetDeviceType(
				UserInputService.TouchEnabled,
				UserInputService.MouseEnabled,
				RunService:IsStudio() and UserInputService.PreferredInput == Enum.PreferredInput.Touch
			)
			return deviceType == SettingsConfig.DeviceType.Mobile
		end

		return pref == true
	end

	local function createPlacementGrid(base)
		local grid = Instance.new("Model")
		grid.Name = "PlacementGrid"

		local topY = base.Position.Y + base.Size.Y / 2 + 0.04
		local halfX = math.floor(base.Size.X / GRID_SIZE / 2)
		local halfZ = math.floor(base.Size.Z / GRID_SIZE / 2)

		for x = -halfX, halfX do
			local line = Instance.new("Part")
			line.Name = "GridLine"
			line.Anchored = true
			line.CanCollide = false
			line.CanQuery = false
			line.CanTouch = false
			line.Material = Enum.Material.Neon
			line.Color = Color3.fromRGB(120, 210, 255)
			line.Transparency = 0.65
			line.Size = Vector3.new(0.08, 0.08, base.Size.Z)
			line.CFrame = base.CFrame * CFrame.new(x * GRID_SIZE, topY - base.Position.Y, 0)
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
			line.Color = Color3.fromRGB(120, 210, 255)
			line.Transparency = 0.65
			line.Size = Vector3.new(base.Size.X, 0.08, 0.08)
			line.CFrame = base.CFrame * CFrame.new(0, topY - base.Position.Y, z * GRID_SIZE)
			line.Parent = grid
		end

		grid.Parent = Workspace
		return grid
	end

	local function setModelPreviewState(model)
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
				descendant.Transparency = math.max(descendant.Transparency, 0.35)
			elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
				descendant.Disabled = true
			end
		end
	end

	local function removeFrontMarker(model)
		local marker = model:FindFirstChild("Front", true)
		if marker and marker:IsA("BasePart") then
			marker:Destroy()
		end
	end

	local function createPlacementPreview(upgradeId)
		local config = UpgradeConfig[upgradeId]
		local templateName = config and (config.TemplateName or config.DisplayName)
		local template = templateName and buildingPreviews:FindFirstChild(templateName)
		if not template then
			return nil
		end

		local model = template:Clone()
		model.Name = "BuildingPlacementPreview"
		setModelPreviewState(model)
		removeFrontMarker(model)
		model.Parent = Workspace

		local highlight = Instance.new("Highlight")
		highlight.Name = "PlacementHighlight"
		highlight.Adornee = model
		highlight.FillTransparency = 0.65
		highlight.OutlineTransparency = 0
		highlight.Parent = model
		placementHighlight = highlight

		return model
	end

	local function getAlignedModelPivotCFrame(model, desiredBoundingCFrame)
		local boundingCFrame = model:GetBoundingBox()
		local pivotOffset = boundingCFrame:ToObjectSpace(model:GetPivot())
		return desiredBoundingCFrame * pivotOffset
	end

	local function stopPlacement()
		-- Signal for BuildViewController's mobile nudge; never gates placement itself.
		screenGui:SetAttribute(Attrs.PlacementActive, false)
		placementUpgradeId = nil
		placementPurchaseInFlight = false
		placementCFrame = nil
		placementIsValid = false
		lastPlacementScreenPosition = nil
		activePlacementTouch = nil
		placementTouchCount = 0
		placementMultiTouch = false
		if placementPreview then
			placementPreview:Destroy()
			placementPreview = nil
		end
		if placementFootprint then
			placementFootprint:Destroy()
			placementFootprint = nil
		end
		if placementGrid then
			placementGrid:Destroy()
			placementGrid = nil
		end
		if pad.controls then
			pad.controls:Destroy()
			pad.controls = nil
		end
		pad.buttonParts = nil
		pad.offsets = nil
		pad.clampedX = nil
		pad.clampedZ = nil
		pad.footprintSize = nil
		pad.lastLocal = nil
		pad.lastOnBase = false
		placementMouseDown = false
		placementHighlight = nil
	end

	local function hasMultiPlace()
		local playerPreference = player:GetAttribute(Attrs.MultiPlaceEnabled)
		local enabled = type(playerPreference) == "boolean" and playerPreference
			or screenGui:GetAttribute(Attrs.MultiPlaceEnabled) == true

		return ctx.getOwnedCount
			and ctx.getOwnedCount("Multi-Place") > 0
			and enabled == true
	end

	local function overlapsPlacedBuilding(cframe, size)
		local sheet = getPlayerSheet()
		if not sheet then
			return true
		end

		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include
		overlapParams.FilterDescendantsInstances = { sheet }
		local querySize = GridPlacement.getOverlapQuerySize(size)

		for _, part in ipairs(Workspace:GetPartBoundsInBox(cframe, querySize, overlapParams)) do
			local building = getBuildingFromTarget(part)
			if building then
				return true
			end
		end

		return false
	end

	local function updatePlacementPreview(screenPosition, reuseLast)
		if not placementUpgradeId or not placementPreview then
			return
		end

		local sheet = getPlayerSheet()
		local base = getPlacementBasePart(sheet)
		if not base then
			placementIsValid = false
			return
		end

		local _, size = placementPreview:GetBoundingBox()

		-- reuseLast keeps the ghost on its current grid spot (used by Rotate so it
		-- pivots in place) instead of resampling the pointer. Otherwise we read the
		-- tap's screenPosition, or — on PC pad mode — the mouse ray, and remember it.
		local localPosition, isOnBase
		if reuseLast and pad.lastLocal then
			localPosition, isOnBase = pad.lastLocal, pad.lastOnBase
		else
			local hitPosition, onBase = getBasePlaneHit(base, screenPosition)
			if not hitPosition then
				placementIsValid = false
				return
			end
			localPosition = base.CFrame:PointToObjectSpace(hitPosition)
			isOnBase = onBase
			pad.lastLocal = localPosition
			pad.lastOnBase = onBase
		end

		local config = UpgradeConfig[placementUpgradeId]
		local cellsX, cellsZ = GridPlacement.getFootprintCells(config, placementRotation)
		local footprintSize = GridPlacement.getFootprintSize(cellsX, cellsZ)
		local solved = GridPlacement.solvePlacement(localPosition, base.Size, cellsX, cellsZ)
		local clampedX, clampedZ = solved.clampedX, solved.clampedZ
		local y = base.Size.Y / 2 + size.Y / 2
		local worldPosition = base.CFrame:PointToWorldSpace(Vector3.new(clampedX, y, clampedZ))
		local footprintCFrame = GridPlacement.getFootprintCFrame(base.CFrame, base.Size.Y, clampedX, clampedZ)
		local blockedCenter = getBlockedCenterPart(sheet)
		local outsideBlockedCenter = not (blockedCenter and GridPlacement.footprintOverlapsPartXZ(footprintCFrame, footprintSize, blockedCenter))

		if placementFootprint and placementFootprint.Size ~= footprintSize then
			placementFootprint.Size = footprintSize
		end

		placementCFrame = CFrame.new(worldPosition) * CFrame.Angles(0, placementRotation, 0)
		placementPreview:PivotTo(getAlignedModelPivotCFrame(placementPreview, placementCFrame))
		if placementFootprint then
			placementFootprint.CFrame = footprintCFrame
		end

		-- Remember the ghost's footprint so the control bundle can be re-anchored to the
		-- camera-facing edge every frame (pad.reposition), even while the ghost sits still.
		pad.clampedX = clampedX
		pad.clampedZ = clampedZ
		pad.footprintSize = footprintSize
		pad.reposition()

		-- The ghost is always snapped to a clamped, in-bounds grid spot, so it's placeable
		-- wherever it shows -- a tap past the plot edge just slides it to the nearest valid cell
		-- (the server re-snaps the same clamped CFrame, so it accepts it too). Validity only
		-- fails on the blocked center pad or overlapping another building, not on where you tapped.
		placementIsValid = outsideBlockedCenter and not overlapsPlacedBuilding(footprintCFrame, footprintSize)

		if placementHighlight then
			placementHighlight.FillColor = placementIsValid and Color3.fromRGB(70, 220, 110) or Color3.fromRGB(220, 60, 60)
			placementHighlight.OutlineColor = placementHighlight.FillColor
		end
		if placementFootprint then
			placementFootprint.Color = placementIsValid and Color3.fromRGB(70, 220, 110) or Color3.fromRGB(220, 60, 60)
		end
	end

	-- Quarter-turn rotation shared by the keyboard R key and the Rotate button.
	function pad.rotate()
		if not placementUpgradeId then
			return
		end

		placementRotation = (placementRotation + math.rad(90)) % math.rad(360)
		rememberedPlacementRotation = placementRotation
		-- Pivot in place: keep the ghost on its current grid spot rather than jumping
		-- it to wherever the cursor/last tap was.
		updatePlacementPreview(nil, true)
	end

	-- Re-anchor the whole control bundle onto the footprint edge that faces the camera,
	-- preserving the authored spacing + per-button rotation. Recomputed every frame so the
	-- bundle slides to the near side as the camera orbits or the ghost moves — easy to
	-- see and tap. Cheap no-op until the bundle + a footprint have been captured.
	function pad.reposition()
		if not pad.buttonParts or not pad.offsets or pad.clampedX == nil then
			return
		end

		local sheet = getPlayerSheet()
		local base = getPlacementBasePart(sheet)
		local camera = Workspace.CurrentCamera
		if not base or not camera then
			return
		end

		local footprintSize = pad.footprintSize
		local up = base.CFrame.UpVector
		local centerWorld = base.CFrame:PointToWorldSpace(Vector3.new(pad.clampedX, base.Size.Y / 2, pad.clampedZ))

		-- Outward = from the building toward the camera, flattened onto the Base plane, so
		-- the cluster always rides whichever footprint face is nearest the screen. Falls
		-- back gracefully when the camera looks straight down (no horizontal component).
		local toCam = camera.CFrame.Position - centerWorld
		local flat = toCam - toCam:Dot(up) * up
		if flat.Magnitude < 1e-3 then
			local look = camera.CFrame.LookVector
			flat = -(look - look:Dot(up) * up)
			if flat.Magnitude < 1e-3 then
				flat = base.CFrame.LookVector
			end
		end
		local outwardDir = flat.Unit

		-- Constant radius from the footprint center: the bounding-circle radius (half the
		-- diagonal). Riding the rectangle EDGE made the bundle slide in/out as the camera
		-- orbited — closest on a flat face, farthest at a corner. The circumscribed circle
		-- is angle-independent and still clears the whole footprint on every side, so the
		-- controls now sit at a fixed distance no matter where the camera looks.
		local edgeDist = math.sqrt((footprintSize.X / 2) ^ 2 + (footprintSize.Z / 2) ^ 2)

		local anchorPos = centerWorld
			+ outwardDir * (edgeDist + CONTROL_GAP + pad.inwardReach)
			+ up * pad.heightOffset
		-- Bundle's template +Z is mapped to outwardDir (CFrame back vector), keeping Up
		-- vertical so the disc tops still face the sky and the icons read upright.
		local xAxis = up:Cross(outwardDir).Unit
		local anchorCF = CFrame.fromMatrix(anchorPos, xAxis, up, outwardDir)

		for name, part in pairs(pad.buttonParts) do
			if part and pad.offsets[name] then
				part.CFrame = anchorCF * pad.offsets[name]
			end
		end
	end

	-- Clone + wire the Studio-authored control buttons (ReplicatedStorage.PlacementControls:
	-- three disc parts named Cancel / Confirm / Rotate, each carrying a SurfaceGui ImageButton).
	-- Buttons drive the same paths as the keyboard flow; they only exist while placement is
	-- live, so wiring once per clone is fine (the clone is destroyed in stopPlacement).
	function pad.createControls()
		if not pad.enabled() or not pad.template then
			return nil
		end

		local controls = pad.template:Clone()
		for _, descendant in ipairs(controls:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanTouch = false
			end
		end

		local function wire(name, handler)
			local part = controls:FindFirstChild(name)
			if not part then
				return nil
			end
			local button = part:FindFirstChildWhichIsA("GuiButton", true)
			if button then
				button.MouseButton1Click:Connect(handler)
			end
			return part
		end

		local cancelPart = wire("Cancel", function()
			stopPlacement()
			ctx.showStatus("Placement canceled.")
		end)
		local confirmPart = wire("Confirm", function()
			pad.tryConfirm(true)
		end)
		local rotatePart = wire("Rotate", pad.rotate)
		pad.buttonParts = { cancel = cancelPart, confirm = confirmPart, rotate = rotatePart }

		-- Capture the authored cluster as a rigid bundle: each button's CFrame relative to
		-- the cluster center (so the spacing + per-button rotation set in Studio are kept),
		-- plus how far it reaches toward the building (template -Z) so reposition() can
		-- clear the footprint edge by exactly CONTROL_GAP, and the lift off the Base top.
		local present = {}
		for name, part in pairs(pad.buttonParts) do
			if part then
				present[name] = part
			end
		end
		pad.offsets = nil
		if next(present) then
			local sum, count = Vector3.zero, 0
			for _, part in pairs(present) do
				sum += part.Position
				count += 1
			end
			local refCF = CFrame.new(sum / count)
			pad.offsets = {}
			pad.inwardReach = 0
			local thickness = 0
			for name, part in pairs(present) do
				pad.offsets[name] = refCF:ToObjectSpace(part.CFrame)
				pad.inwardReach = math.max(pad.inwardReach, -(part.Position.Z - refCF.Position.Z) + part.Size.Z / 2)
				thickness = math.max(thickness, part.Size.Y)
			end
			pad.heightOffset = thickness / 2 + 0.06
		end

		controls.Parent = Workspace
		return controls
	end

	local function startPlacement(upgradeId)
		stopPlacement()
		placementUpgradeId = upgradeId
		placementRotation = rememberedPlacementRotation
		placementStartedAt = os.clock()
		lastPlacementScreenPosition = nil
		activePlacementTouch = nil
		placementPreview = createPlacementPreview(upgradeId)
		if not placementPreview then
			ctx.showStatus("Building preview was not found.")
			stopPlacement()
			return
		end
		local sheet = getPlayerSheet()
		local base = getPlacementBasePart(sheet)
		if base then
			placementGrid = createPlacementGrid(base)
		end
		placementFootprint = Instance.new("Part")
		placementFootprint.Name = "BuildingPlacementFootprint"
		placementFootprint.Anchored = true
		placementFootprint.CanCollide = false
		placementFootprint.CanQuery = false
		placementFootprint.CanTouch = false
		placementFootprint.Material = Enum.Material.ForceField
		local initialCellsX, initialCellsZ = GridPlacement.getFootprintCells(UpgradeConfig[upgradeId], placementRotation)
		placementFootprint.Size = GridPlacement.getFootprintSize(initialCellsX, initialCellsZ)
		placementFootprint.Transparency = 0.35
		placementFootprint.Parent = Workspace
		placementMouseDown = false
		pad.controls = pad.createControls()
		-- Placement is live: lets BuildViewController offer its Build View nudge on touch.
		screenGui:SetAttribute(Attrs.PlacementActive, true)
		local displayName = UpgradeConfig[upgradeId].DisplayName or upgradeId
		if pad.controls then
			-- Seed the ghost at the pointer so it shows immediately; from here it holds
			-- its grid spot until the player taps or drags it to another one.
			updatePlacementPreview(nil, false)
			ctx.showStatus("Tap or drag to position " .. displayName .. ", then use the buttons to rotate, cancel, or confirm.")
		else
			ctx.showStatus("Press and hold your plot to preview " .. displayName .. ". Release to place.")
		end
	end

	local function updateSellHighlight()
		if not ctx.isSellMode() or ctx.getCurrentCategory() ~= "Building" or placementUpgradeId then
			hoveredSellBuilding = nil
			if sellHighlight then
				sellHighlight:Destroy()
				sellHighlight = nil
			end
			return
		end

		local building = getBuildingFromTarget(mouse.Target)
		hoveredSellBuilding = building
		if not building then
			if sellHighlight then
				sellHighlight:Destroy()
				sellHighlight = nil
			end
			return
		end

		if not sellHighlight then
			sellHighlight = Instance.new("Highlight")
			sellHighlight.Name = "SellHighlight"
			sellHighlight.FillColor = Color3.fromRGB(255, 45, 45)
			sellHighlight.OutlineColor = Color3.fromRGB(255, 0, 0)
			sellHighlight.Parent = Workspace
		end

		local pulse = (math.sin(os.clock() * 8) + 1) / 2
		sellHighlight.Adornee = building
		sellHighlight.FillTransparency = 0.35 + pulse * 0.25
		sellHighlight.OutlineTransparency = 0
	end

	function pad.tryConfirm(ignoreStartDelay)
		local delayPassed = ignoreStartDelay or os.clock() - placementStartedAt >= 0.2
		if placementCFrame and placementIsValid and delayPassed and not placementPurchaseInFlight then
			local requestedUpgradeId = placementUpgradeId
			placementPurchaseInFlight = true
			ctx.invokePurchase(requestedUpgradeId, placementCFrame, function(result)
				local success = result and result.success == true
				placementPurchaseInFlight = false
				if success and placementUpgradeId == requestedUpgradeId and hasMultiPlace() then
					updatePlacementPreview(lastPlacementScreenPosition)
					return
				end

				stopPlacement()
			end)
		elseif not placementIsValid then
			ctx.showStatus("Can't place there — it overlaps the Center or another building.")
		end
	end

	local function handleInputBegan(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.Touch then
			placementTouchCount += 1
			if placementTouchCount >= 2 then
				-- Second finger down: this is a camera pinch/rotate. Freeze the ghost and stop
				-- treating the first finger as a placement drag until every finger lifts.
				placementMultiTouch = true
				activePlacementTouch = nil
			end
		end
		if gameProcessed then
			return
		end

		if input.KeyCode == Enum.KeyCode.R and placementUpgradeId then
			pad.rotate()
			return
		end

		if (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.X) and placementUpgradeId then
			stopPlacement()
			ctx.showStatus("Placement canceled.")
			return
		end

		local isPrimaryPlacementInput = input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		if not isPrimaryPlacementInput then
			return
		end

		if input.UserInputType == Enum.UserInputType.Touch then
			local screenPosition = Vector2.new(input.Position.X, input.Position.Y)
			if ctx.isSellMode() and ctx.getCurrentCategory() == "Building" and not placementUpgradeId then
				local building = getBuildingFromScreenPosition(screenPosition)
				if building then
					hoveredSellBuilding = building
					ctx.invokeSell(building)
				else
					ctx.showStatus("Tap a placed building to sell it.")
				end
				return
			end

			if placementUpgradeId and not placementMultiTouch then
				if not activePlacementTouch then
					activePlacementTouch = input
				end
				lastPlacementScreenPosition = screenPosition
				updatePlacementPreview(lastPlacementScreenPosition)
			end
			return
		end

		if placementUpgradeId then
			if pad.enabled() then
				-- Pad mode: a click on the plot jumps the ghost to that grid spot and
				-- begins a drag; only the Confirm button actually places.
				placementMouseDown = true
				updatePlacementPreview(nil, false)
			else
				pad.tryConfirm(false)
			end
		elseif ctx.isSellMode() and ctx.getCurrentCategory() == "Building" and hoveredSellBuilding then
			ctx.invokeSell(hoveredSellBuilding)
		end
	end

	local function handleInputEnded(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- End of a PC pad-mode drag; the ghost just stays on its grid spot.
			placementMouseDown = false
			return
		end

		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		placementTouchCount = math.max(0, placementTouchCount - 1)
		if placementTouchCount == 0 then
			-- Every finger is up: clear the multi-touch freeze so the next single touch can move
			-- the ghost again. (A fresh tap re-acquires the placement finger.)
			placementMultiTouch = false
		end

		-- Only the finger that owns the placement drag commits/parks. The finger left over from a
		-- pinch was cleared (activePlacementTouch = nil), so lifting it never moves or places.
		if placementUpgradeId and input == activePlacementTouch then
			lastPlacementScreenPosition = Vector2.new(input.Position.X, input.Position.Y)
			updatePlacementPreview(lastPlacementScreenPosition)
			-- With the pad on, lifting the finger only parks the preview — the Confirm
			-- button commits. Without it, release-to-place stays the mobile flow.
			if not pad.enabled() then
				pad.tryConfirm(true)
			end
			activePlacementTouch = nil
		end
	end

	local function handleInputChanged(input, gameProcessed)
		if gameProcessed then
			return
		end

		if placementUpgradeId and not placementMultiTouch and input == activePlacementTouch then
			lastPlacementScreenPosition = Vector2.new(input.Position.X, input.Position.Y)
			updatePlacementPreview(lastPlacementScreenPosition)
		elseif placementUpgradeId and input.UserInputType == Enum.UserInputType.MouseMovement
			and pad.enabled() and placementMouseDown then
			-- PC pad-mode drag: follow the cursor across grid spots while held.
			updatePlacementPreview(nil, false)
		end
	end

	-- RenderStepped tick: when the pad is OFF (legacy PC opt-out flow) free-follow the
	-- cursor every frame; when it's ON the ghost holds its grid spot and only moves on
	-- tap/click/drag. Always pulse the sell highlight, preserving the original
	-- (updatePlacementPreview then updateSellHighlight) order from the orchestrator's loop.
	local function tick()
		if not pad.enabled() then
			updatePlacementPreview(lastPlacementScreenPosition)
		end
		-- Keep the control bundle riding the camera-facing edge as the view orbits, even
		-- when the ghost is parked (no-op until a bundle + footprint are live).
		pad.reposition()
		updateSellHighlight()
	end

	return {
		start = startPlacement,
		tick = tick,
		handleInputBegan = handleInputBegan,
		handleInputEnded = handleInputEnded,
		handleInputChanged = handleInputChanged,
	}
end

return StorePlacement
