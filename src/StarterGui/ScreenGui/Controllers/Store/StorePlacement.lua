-- StorePlacement: the building placement flow plus sell-by-click/tap. Owns placement state
-- (preview model, footprint, validity, and remembered rotation) and the sell highlight;
-- StoreFloorPlacement owns unlocked-floor grids and direct-aim floor selection.
-- The fixed hotbar controls are bound separately by StorePlacementControls. Projects the pointer
-- onto the plot Base analytically and
-- mirrors GridPlacement so the local preview can't drift from server validation. Reads
-- sellMode/currentCategory via ctx getters and reports via ctx.showStatus.
-- Exposes start(upgradeId), tick() (RenderStepped), and handleInputBegan/Ended/Changed
-- (wired to UserInputService by the orchestrator). Signals BuildViewController via the
-- screenGui PlacementActive attribute.
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local FloorConfig = require(Shared:WaitForChild("FloorConfig"))

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

	local placementUpgradeId = nil
	local placementPreview = nil
	local placementHighlight = nil
	local placementFootprint = nil
	local placementCFrame = nil
	local placementIsValid = false
	local placementRotation = 0
	local rememberedPlacementRotation = 0
	local placementStartedAt = 0
	local lastPlacementScreenPosition = nil
	local lastPlacementLocal = nil
	local activePlacementTouch = nil
	local placementPurchaseInFlight = false
	-- Touch bookkeeping so a two-finger camera gesture (pinch/rotate) never also drags the
	-- ghost: while 2+ fingers are down we freeze the ghost, and the finger left behind after a
	-- pinch is ignored until ALL fingers lift (mirrors the camera's own multi-touch discipline).
	local placementTouchCount = 0
	local placementMultiTouch = false
	local placementMouseDown = false
	local multiPlaceSessionActive = false
	local multiPlaceSessionCount = 0
	local sellHighlight = nil
	local hoveredSellBuilding = nil

	local function usesScreenPlacementControls()
		return screenGui:GetAttribute(Attrs.PlacementControlsEnabled) == true
	end

	local function refreshConfirmState()
		if ctx.placementControls then
			ctx.placementControls.setConfirmState(placementIsValid, placementPurchaseInFlight)
		end
	end

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

	local function getActiveFloorId()
		return ctx.floorPlacement.getActiveFloorId()
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
		if getActiveFloorId() ~= FloorConfig.GroundFloorId then
			return nil
		end
		local center = sheet and sheet:FindFirstChild("Center")
		if center and center:IsA("BasePart") then
			return center
		end

		return nil
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

	local function stopPlacement(instantControlsExit)
		-- Signal for BuildViewController's mobile nudge; never gates placement itself.
		screenGui:SetAttribute(Attrs.PlacementInstantExit, instantControlsExit == true)
		screenGui:SetAttribute(Attrs.PlacementActive, false)
		if instantControlsExit then
			-- Attribute listeners consume the one-shot intent synchronously with PlacementActive.
			screenGui:SetAttribute(Attrs.PlacementInstantExit, false)
		end
		multiPlaceSessionActive = false
		multiPlaceSessionCount = 0
		screenGui:SetAttribute(Attrs.MultiPlaceSessionActive, false)
		screenGui:SetAttribute(Attrs.MultiPlaceSessionCount, 0)
		if screenGui:GetAttribute(Attrs.MultiplierContextMode) == "Placement" then
			screenGui:SetAttribute(Attrs.MultiplierContextMode, nil)
			screenGui:SetAttribute(Attrs.MultiplierContextBuildingId, nil)
			screenGui:SetAttribute(Attrs.MultiplierContextFloorId, nil)
		end
		placementUpgradeId = nil
		placementPurchaseInFlight = false
		placementCFrame = nil
		placementIsValid = false
		lastPlacementScreenPosition = nil
		lastPlacementLocal = nil
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
		ctx.floorPlacement.stop()
		placementMouseDown = false
		placementHighlight = nil
		refreshConfirmState()
	end

	local function hasMultiPlace()
		local playerPreference = player:GetAttribute(Attrs.MultiPlaceEnabled)
		local enabled = type(playerPreference) == "boolean" and playerPreference
			or screenGui:GetAttribute(Attrs.MultiPlaceEnabled) == true

		return ctx.getOwnedCount and ctx.getOwnedCount("Multi-Place") > 0 and enabled == true
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

	local function updatePlacementPreview(screenPosition, reuseLast, useInitialFloorPosition)
		if not placementUpgradeId or not placementPreview then
			return
		end

		local sheet = getPlayerSheet()
		local _, size = placementPreview:GetBoundingBox()

		-- reuseLast keeps the ghost on its current grid spot (used by Rotate so it
		-- pivots in place) instead of resampling the pointer. Otherwise we read the
		-- tap's screenPosition, or the mouse ray, and remember it.
		local base
		local localPosition
		if reuseLast and lastPlacementLocal then
			base = ctx.floorPlacement.getActiveBase()
			localPosition = lastPlacementLocal
		else
			local hitPosition
			local activeFloorChanged
			if useInitialFloorPosition then
				base, hitPosition, activeFloorChanged = ctx.floorPlacement.resolveInitial()
			else
				base, hitPosition, activeFloorChanged = ctx.floorPlacement.resolvePointer(screenPosition)
			end
			if activeFloorChanged then
				lastPlacementLocal = nil
			end
			if not base or not hitPosition then
				placementIsValid = false
				refreshConfirmState()
				return
			end
			localPosition = base.CFrame:PointToObjectSpace(hitPosition)
			lastPlacementLocal = localPosition
		end
		if not base then
			placementIsValid = false
			refreshConfirmState()
			return
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
		local outsideBlockedCenter = not (
			blockedCenter and GridPlacement.footprintOverlapsPartXZ(footprintCFrame, footprintSize, blockedCenter)
		)

		if placementFootprint and placementFootprint.Size ~= footprintSize then
			placementFootprint.Size = footprintSize
		end

		placementCFrame = CFrame.new(worldPosition) * CFrame.Angles(0, placementRotation, 0)
		placementPreview:PivotTo(getAlignedModelPivotCFrame(placementPreview, placementCFrame))
		if placementFootprint then
			placementFootprint.CFrame = footprintCFrame
		end

		-- The ghost is always snapped to a clamped, in-bounds grid spot, so it's placeable
		-- wherever it shows -- a tap past the plot edge just slides it to the nearest valid cell
		-- (the server re-snaps the same clamped CFrame, so it accepts it too). Validity only
		-- fails on the blocked center pad or overlapping another building, not on where you tapped.
		placementIsValid = outsideBlockedCenter and not overlapsPlacedBuilding(footprintCFrame, footprintSize)

		if placementHighlight then
			placementHighlight.FillColor = placementIsValid and Color3.fromRGB(70, 220, 110)
				or Color3.fromRGB(220, 60, 60)
			placementHighlight.OutlineColor = placementHighlight.FillColor
		end
		if placementFootprint then
			placementFootprint.Color = placementIsValid and Color3.fromRGB(70, 220, 110) or Color3.fromRGB(220, 60, 60)
		end
		refreshConfirmState()
	end

	-- Quarter-turn rotation shared by the keyboard R key and the Rotate button.
	local function rotatePlacement()
		if not placementUpgradeId then
			return
		end

		placementRotation = (placementRotation + math.rad(90)) % math.rad(360)
		rememberedPlacementRotation = placementRotation
		-- Pivot in place: keep the ghost on its current grid spot rather than jumping
		-- it to wherever the cursor/last tap was.
		updatePlacementPreview(nil, true)
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
		screenGui:SetAttribute(Attrs.MultiplierContextMode, "Placement")
		screenGui:SetAttribute(Attrs.MultiplierContextBuildingId, upgradeId)
		screenGui:SetAttribute(Attrs.MultiplierContextFloorId, nil)
		ctx.floorPlacement.begin(function(_, activeFloorChanged)
			lastPlacementLocal = nil
			task.defer(function()
				if placementUpgradeId then
					updatePlacementPreview(lastPlacementScreenPosition, false, activeFloorChanged)
				end
			end)
		end)
		placementFootprint = Instance.new("Part")
		placementFootprint.Name = "BuildingPlacementFootprint"
		placementFootprint.Anchored = true
		placementFootprint.CanCollide = false
		placementFootprint.CanQuery = false
		placementFootprint.CanTouch = false
		placementFootprint.Material = Enum.Material.ForceField
		local initialCellsX, initialCellsZ =
			GridPlacement.getFootprintCells(UpgradeConfig[upgradeId], placementRotation)
		placementFootprint.Size = GridPlacement.getFootprintSize(initialCellsX, initialCellsZ)
		placementFootprint.Transparency = 0.35
		placementFootprint.Parent = Workspace
		placementMouseDown = false
		multiPlaceSessionActive = hasMultiPlace()
		multiPlaceSessionCount = 0
		screenGui:SetAttribute(Attrs.MultiPlaceSessionCount, 0)
		screenGui:SetAttribute(Attrs.MultiPlaceSessionActive, multiPlaceSessionActive)
		-- Placement is live: lets BuildViewController offer its Build View nudge on touch.
		screenGui:SetAttribute(Attrs.PlacementActive, true)
		local displayName = UpgradeConfig[upgradeId].DisplayName or upgradeId
		-- Classic mouse mode seeds from the pointer. Fixed-control modes seed from the
		-- character-nearest or Build View center-ray floor, then park until direct input.
		updatePlacementPreview(nil, false, usesScreenPlacementControls())
		if usesScreenPlacementControls() then
			ctx.showStatus("Tap or drag to position " .. displayName .. " then use the bottom controls")
		else
			ctx.showStatus("Move the mouse and click to place " .. displayName)
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

	local function cancelPlacement()
		if not placementUpgradeId then
			return
		end
		local returnToStore = multiPlaceSessionActive
		local showCanceled = multiPlaceSessionCount == 0
		stopPlacement(true)
		if returnToStore then
			-- Let every placement teardown listener settle before returning the Store. This
			-- prevents a synchronous close reaction from winning after the session ends.
			task.defer(function()
				if
					screenGui:GetAttribute(Attrs.PlacementActive) ~= true
					and screenGui:GetAttribute(Attrs.BackgroundSurfacesSuspended) ~= true
				then
					screenGui:SetAttribute(Attrs.StoreOpen, true)
				end
			end)
		end
		if showCanceled then
			ctx.showStatus("Placement canceled.")
		end
	end

	local function tryConfirm(ignoreStartDelay)
		local delayPassed = ignoreStartDelay or os.clock() - placementStartedAt >= 0.2
		if placementCFrame and placementIsValid and delayPassed and not placementPurchaseInFlight then
			local requestedUpgradeId = placementUpgradeId
			placementPurchaseInFlight = true
			refreshConfirmState()
			ctx.invokePurchase(requestedUpgradeId, placementCFrame, function(result)
				local success = result and result.success == true
				placementPurchaseInFlight = false
				if
					success
					and placementUpgradeId == requestedUpgradeId
					and multiPlaceSessionActive
					and hasMultiPlace()
				then
					multiPlaceSessionCount += 1
					screenGui:SetAttribute(Attrs.MultiPlaceSessionCount, multiPlaceSessionCount)
					updatePlacementPreview(lastPlacementScreenPosition)
					return
				end

				-- StoreBottom returns as soon as single-place ends, so release the shared hotbar
				-- immediately instead of letting placement controls overlap its upward tween.
				stopPlacement(success)
			end, getActiveFloorId())
		elseif not placementIsValid then
			ctx.showStatus("Can't place there: it overlaps the Center or another building.")
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
			if ctx.placementControls then
				ctx.placementControls.reportKeyboard("Rotate")
			end
			rotatePlacement()
			return
		end

		if input.KeyCode == Enum.KeyCode.C and placementUpgradeId then
			if ctx.placementControls then
				ctx.placementControls.reportKeyboard("Confirm")
			end
			tryConfirm(true)
			return
		end

		if (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.X) and placementUpgradeId then
			if ctx.placementControls then
				ctx.placementControls.reportKeyboard("Cancel")
			end
			cancelPlacement()
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
			-- A click on the plot jumps the ghost to that grid spot and begins a drag. Screen-control
			-- mode parks it for Confirm; desktop classic mode commits when the mouse is released.
			placementMouseDown = true
			updatePlacementPreview(nil, false)
		elseif ctx.isSellMode() and ctx.getCurrentCategory() == "Building" and hoveredSellBuilding then
			ctx.invokeSell(hoveredSellBuilding)
		end
	end

	local function handleInputEnded(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local wasDraggingPlacement = placementMouseDown
			placementMouseDown = false
			if wasDraggingPlacement and placementUpgradeId and not usesScreenPlacementControls() then
				-- Desktop classic mode: release commits the current mouse position. The start delay
				-- prevents the Store-card click that began placement from also buying immediately.
				tryConfirm(false)
			end
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
			-- Lifting only parks the preview. The fixed Confirm action commits it.
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
		elseif
			placementUpgradeId
			and input.UserInputType == Enum.UserInputType.MouseMovement
			and placementMouseDown
		then
			-- PC drag: follow the cursor across grid spots while held.
			updatePlacementPreview(nil, false)
		end
	end

	-- Desktop classic placement continuously follows the mouse and commits on click. The fixed
	-- screen-control mode remains event-driven so its ghost parks after a tap, click, or drag.
	local function tick()
		if placementUpgradeId and not usesScreenPlacementControls() then
			updatePlacementPreview(nil, false)
		end
		updateSellHighlight()
	end

	-- Placement is subordinate to Build View/Store/modal/character lifecycle. These paths are
	-- deliberately idempotent because one teardown can change several attributes together.
	screenGui:GetAttributeChangedSignal(Attrs.BuildModeActive):Connect(function()
		if placementUpgradeId and screenGui:GetAttribute(Attrs.BuildModeActive) ~= true then
			stopPlacement()
		end
	end)
	screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(function()
		if placementUpgradeId and screenGui:GetAttribute(Attrs.StoreOpen) ~= true then
			stopPlacement(true)
		end
	end)
	screenGui:GetAttributeChangedSignal(Attrs.OpenModal):Connect(function()
		if placementUpgradeId and (screenGui:GetAttribute(Attrs.OpenModal) or "") ~= "" then
			stopPlacement(true)
		end
	end)
	player.CharacterRemoving:Connect(function()
		if placementUpgradeId then
			stopPlacement()
		end
	end)

	return {
		start = startPlacement,
		cancel = cancelPlacement,
		rotate = rotatePlacement,
		confirm = tryConfirm,
		tick = tick,
		handleInputBegan = handleInputBegan,
		handleInputEnded = handleInputEnded,
		handleInputChanged = handleInputChanged,
	}
end

return StorePlacement
