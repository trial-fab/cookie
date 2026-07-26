-- BoostFieldPlacement: the world half of dropping a boost — the radius ghost and its commit.
--
-- A field runs through the SAME placement session buildings use: `PlacementActive` raises the
-- authored Cancel / Confirm faces, parks the store toggle, adjusts the build camera, and gives
-- touch and gamepad the same controls they already have for buildings (decision 10). Two things
-- make that safe, and both were missing in the first attempt that wedged the hotbar:
--
--   * `BoostFieldPlacementActive` makes StorePlacementControls inert, so the shared faces route
--     their taps here instead of into a StorePlacement that has no session of its own.
--   * The teardown clears the one-shot `PlacementInstantExit` intent the same way StorePlacement's
--     own `stopPlacement` does, so HotbarPlacementMode's exit path sees consistent state.
--
-- Over a plot, the ghost is resolved the way a BUILDING ghost is: by intersecting the pointer ray
-- with the floor SURFACE PLANES (FloorGeometry), never by raycasting world geometry. That is what
-- makes it float exactly where the field will land — a raycast answers "what is under the cursor",
-- so it parks the disc on a building's roof or the crater wall while the server drops the field on
-- the floor below.
--
-- Away from a plot the ghost keeps following the pointer (resting on whatever world geometry is
-- under it) rather than sticking to the last plot edge, so the player can see where they are
-- aiming. It just goes red and says so: aiming somewhere illegal should read as illegal, not as
-- the ghost refusing to move.
--
-- Unlike buildings, ANY player's plot is a legal target (a field is a gift, §12.3), so the surface
-- set spans every occupied sheet rather than just the local player's.
--
-- Input parity with buildings: with screen controls on (always on touch and gamepad),
-- Cancel/Confirm are the hotbar faces and a world tap only repositions. With them off (PC classic)
-- the ghost follows the mouse and a click commits. X / Escape / B and the item's own hotbar key
-- cancel anywhere.
--
-- The ghost is the Studio-authored `BoostFieldGhost` template. This module only ever sets its
-- Size (scaled from the authored `ReferenceRadius`), position, and Color — never Transparency or
-- Material, which the user owns.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local BoostShopConfig = require(shared:WaitForChild("BoostShopConfig"))
local FloorConfig = require(shared:WaitForChild("FloorConfig"))
local FloorGeometry = require(shared:WaitForChild("FloorGeometry"))
local Net = require(shared:WaitForChild("Net"))
local PlacementControls = require(shared:WaitForChild("PlacementControls"))

local BoostFieldCoverage = require(script.Parent:WaitForChild("BoostFieldCoverage"))
local BoostFieldPulse = require(script.Parent:WaitForChild("BoostFieldPulse"))

local BoostFieldPlacement = {}

-- World-space bottom of a model. `Model:GetBoundingBox` is aligned to the model's PIVOT, and these
-- canisters pivot on a part that is rolled 90 degrees, so its `size.Y` is the model's WIDTH, not
-- its height. Projecting each part's own box onto world Y is the version that actually answers
-- "where does the Foot touch down".
local function lowestWorldY(model)
	local lowest = math.huge
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			local cframe, size = part.CFrame, part.Size
			local halfHeight = 0.5
				* (
					math.abs(cframe.XVector.Y) * size.X
					+ math.abs(cframe.YVector.Y) * size.Y
					+ math.abs(cframe.ZVector.Y) * size.Z
				)
			lowest = math.min(lowest, cframe.Position.Y - halfHeight)
		end
	end
	return lowest ~= math.huge and lowest or model:GetPivot().Position.Y
end

local INVALID_COLOR = Color3.fromRGB(200, 60, 60)
local RAY_LENGTH = 2000
-- Keeps a disc resting on ordinary world geometry (the off-plot case) out of z-fighting with it.
local WORLD_LIFT = 0.15
-- Plot geometry is read from live parts, so it cannot be cached for a whole session (sheets are
-- re-placed as the ring grows and trims). Rebuilding it per frame would walk every sheet 60 times
-- a second, so it is rebuilt at this cadence instead: far too fast to see, far too slow to cost.
local SURFACE_REFRESH_SECONDS = 0.25

-- options: { screenGui, onMessage }
function BoostFieldPlacement.new(options)
	local screenGui = options.screenGui
	local player = Players.LocalPlayer

	local template = ReplicatedStorage:FindFirstChild(BoostShopConfig.GhostTemplateName)
	if not template then
		warn(
			("BoostFieldPlacement: no `%s` template in ReplicatedStorage — field placement disabled."):format(
				BoostShopConfig.GhostTemplateName
			)
		)
		return nil
	end

	local hotbar = screenGui:FindFirstChild("Hotbar")
	local function slotHitbox(slotName)
		local slot = hotbar and hotbar:FindFirstChild(slotName)
		local button = slot and slot:FindFirstChild("hitbox")
		return button and button:IsA("GuiButton") and button or nil
	end
	-- Which slot carries which action depends on the placement mode, exactly as it does for
	-- buildings: with screen controls ON the bar is Cancel | Rotate | Confirm across the three
	-- slots; with them OFF (PC classic) the flanks are hidden and the CENTRE slot is Cancel.
	local cancelHitbox = slotHitbox("SlotLeft")
	local confirmHitbox = slotHitbox("SlotRight")
	local centerHitbox = slotHitbox("SlotCenter")
	-- A circle has no rotation. HotbarPlacementMode drops the middle control and lays the remaining
	-- pair out symmetrically when PlacementControlsNoRotate is set, so nothing here touches slots.

	-- Touch bookkeeping mirrors StorePlacement's: a single finger drags the ghost, and a second
	-- finger means the player is doing a camera pinch/rotate, so the ghost freezes until every
	-- finger lifts. Without this the disc chases the camera gesture around the plot.
	local touchCount = 0
	local multiTouch = false
	local activeTouch = nil
	local touchPosition = nil
	-- Only used by the opt-in screen-controls mode on PC, where a held click drags the ghost.
	local mouseDown = false

	local warningLabel = screenGui:FindFirstChild(BoostShopConfig.WarningLabelName, true)
	if not (warningLabel and warningLabel:IsA("TextLabel")) then
		warningLabel = nil
		warn(
			("BoostFieldPlacement: no `%s` TextLabel under the ScreenGui — invalid placements will be silent."):format(
				BoostShopConfig.WarningLabelName
			)
		)
	end

	local activeItem = nil
	local heldModel = nil
	local ghost = nil
	local ghostRotation = CFrame.identity
	local ghostValid = false
	local ghostPosition = nil
	-- The disc's own parts, so validity recolouring never touches the canister standing on it. The
	-- ping is narrower still: it only ever moves the inner sweep part, which BoostFieldPulse finds
	-- by name so the fixed outer boundary keeps showing the field's real coverage.
	local discParts = {}
	local pulse = nil
	local renderConn = nil
	local dropInFlight = false
	-- Radius of the session's item, captured once so coverage is measured against the same figure
	-- the disc was scaled to.
	local activeRadius = 0
	local coverage = BoostFieldCoverage.new({ screenGui = screenGui })

	local cachedSurfaces = nil
	local cachedSurfacesAt = 0

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local function message(text)
		if options.onMessage then
			options.onMessage(text)
		end
	end

	local function screenControlsOn()
		return PlacementControls.screenControlsActive(screenGui)
	end

	-- Every occupied plot's unlocked floors. Each surface is tagged with the sheet it came from so
	-- the caller can check that plot for an existing field of the same type; FloorGeometry builds a
	-- fresh table per call, so tagging it cannot leak into anyone else's copy.
	local function collectSurfaces()
		local now = os.clock()
		if cachedSurfaces and now - cachedSurfacesAt < SURFACE_REFRESH_SECONDS then
			return cachedSurfaces
		end

		local surfaces = {}
		local sheets = Workspace:FindFirstChild("CookieSheets")
		for _, sheet in ipairs(sheets and sheets:GetChildren() or {}) do
			local ownerValue = sheet:FindFirstChild("SheetOwner")
			local owner = ownerValue and ownerValue:IsA("ObjectValue") and ownerValue.Value or nil
			if owner then
				for _, surface in
					ipairs(FloorGeometry.GetUnlockedSurfaces(sheet, owner:GetAttribute(Attrs.UnlockedFloorCount)))
				do
					surface.sheet = sheet
					table.insert(surfaces, surface)
				end
			end
		end

		cachedSurfaces = surfaces
		cachedSurfacesAt = now
		return surfaces
	end

	-- Cosmetic only: the canister appears in the character's hand while the item is equipped. It is
	-- a welded clone of the preview template, never a Tool — a real Tool would drop on death, take
	-- Backspace, and add a second "where did you click" path competing with the ghost.
	local function destroyHeld()
		if heldModel then
			heldModel:Destroy()
			heldModel = nil
		end
	end

	local function buildHeld(item)
		local previews = ReplicatedStorage:FindFirstChild(BoostShopConfig.PreviewFolderName)
		local source = previews and previews:FindFirstChild(item.CanisterName)
		local character = player.Character
		local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
		if not (source and hand and hand:IsA("BasePart")) then
			return nil
		end

		local model = source:Clone()
		model.Name = "BoostFieldHeld"
		local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		if not primary then
			model:Destroy()
			return nil
		end

		model:PivotTo(hand.CFrame * CFrame.new(0, -1.2, 0))
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = false
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.Massless = true
				if part ~= primary then
					local weld = Instance.new("WeldConstraint")
					weld.Part0 = primary
					weld.Part1 = part
					weld.Parent = primary
				end
			end
		end

		local handWeld = Instance.new("WeldConstraint")
		handWeld.Part0 = hand
		handWeld.Part1 = primary
		handWeld.Parent = primary
		model.Parent = character
		return model
	end

	local function destroyGhost()
		if renderConn then
			renderConn:Disconnect()
			renderConn = nil
		end
		if pulse then
			pulse.stop()
			pulse = nil
		end
		if ghost then
			ghost:Destroy()
			ghost = nil
		end
		table.clear(discParts)
		ghostValid = false
		ghostPosition = nil
		coverage.clear()
		if warningLabel then
			warningLabel.Visible = false
		end
	end

	local function exit()
		if not activeItem then
			return
		end
		activeItem = nil
		destroyGhost()
		destroyHeld()
		PlacementControls.clearGamepadFocus(confirmHitbox)
		PlacementControls.clearGamepadFocus(cancelHitbox)
		PlacementControls.clearGamepadFocus(centerHitbox)
		-- Order matters: clear the one-shot intent first (StorePlacement's stopPlacement does the
		-- same), then drop the session flags so every listener sees consistent state.
		screenGui:SetAttribute(Attrs.PlacementInstantExit, false)
		screenGui:SetAttribute(Attrs.PlacementControlsOpenEntrance, false)
		screenGui:SetAttribute(Attrs.PlacementControlsNoRotate, false)
		screenGui:SetAttribute(Attrs.BoostFieldPlacementActive, false)
		screenGui:SetAttribute(Attrs.PlacementActive, false)
	end

	local function buildGhost(item)
		local model = template:Clone()
		-- The authored disc is a Cylinder laid flat (its X axis points up), so Y and Z are the
		-- radial axes and X is the thickness that must not change with radius. Radius comes from
		-- the same tuning the server builds the real field from, or the preview would stop matching
		-- the field the moment the value is tuned.
		local radius = item.Radius
		activeRadius = radius
		local referenceRadius = tonumber(template:GetAttribute("ReferenceRadius")) or radius
		local scale = radius / referenceRadius
		-- Collected before the canister joins the model: only the DISC recolours for validity, or
		-- the canister would lose its authored colours the first time the ghost went red.
		table.clear(discParts)
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Size = Vector3.new(part.Size.X, part.Size.Y * scale, part.Size.Z * scale)
				part.Color = item.FieldColor
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				table.insert(discParts, part)
			elseif part:IsA("Highlight") then
				-- The sonar ring starts in the item's colour; setGhostValid swaps it to red.
				part.OutlineColor = item.FieldColor
			elseif part:IsA("ParticleEmitter") then
				-- The aura belongs to a field that EXISTS, not to one being aimed. A ghost that
				-- already threw energy off the ground would read as placed, and it would drag that
				-- plume across the plot as the player moved the disc around.
				part:Destroy()
			end
		end
		model:SetAttribute("AgentDraft", nil)
		model.Name = "BoostFieldGhostPreview"
		-- Read BEFORE the canister is added, and unaffected by it anyway (the template sets a
		-- PrimaryPart), so the disc's authored flat orientation is what the ghost is placed with.
		ghostRotation = model:GetPivot().Rotation

		-- The item's own canister, standing at the centre of the radius. A bare disc says how big
		-- the field is but not WHICH field, and both discs are the same shape.
		local previews = ReplicatedStorage:FindFirstChild(BoostShopConfig.PreviewFolderName)
		local source = previews and previews:FindFirstChild(item.CanisterName)
		if source then
			local canister = source:Clone()
			canister.Name = "GhostItem"
			for _, part in ipairs(canister:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					if not BoostShopConfig.GhostItemSolidParts[part.Name] then
						-- Ghosted like every other placement preview in the game (StorePlacement uses
						-- the same floor), so it reads as "about to be placed" rather than already
						-- there. The Core is exempt: it is the only thing that tells the two
						-- canisters apart, and a faded Neon ball stops reading as an energy core.
						part.Transparency = math.max(part.Transparency, BoostShopConfig.GhostItemTransparency)
					end
				elseif part:IsA("Script") or part:IsA("LocalScript") then
					part.Disabled = true
				end
			end
			canister.Parent = model

			-- Keep the canister's AUTHORED rotation. Its Foot/Shell/Cap are Cylinders turned on end,
			-- so the model's pivot carries a 90 degree roll; placing it with an identity rotation
			-- (as this first did) cancels that roll and lays the canister on its side.
			local uprightRotation = source:GetPivot().Rotation
			-- Stand it ON the disc rather than through it: measure how far the pivot sits above the
			-- model's lowest point, so the Foot lands on the surface whatever the user restyles the
			-- canister to. Set in WORLD space, because the DISC's pivot is rotated too (its local Y
			-- points along world -X) and a local offset would shove the canister sideways. Later
			-- PivotTo calls move the model rigidly at a fixed rotation, so this survives the session.
			local pivotAboveFoot = canister:GetPivot().Position.Y - lowestWorldY(canister)
			local discCentre = model:GetPivot().Position
			canister:PivotTo(
				CFrame.new(discCentre + Vector3.new(0, pivotAboveFoot + BoostShopConfig.GhostItemLift, 0))
					* uprightRotation
			)
		end

		return model
	end

	local function setWarning(text)
		if warningLabel then
			warningLabel.Text = text or warningLabel.Text
			warningLabel.Visible = text ~= nil
		end
	end

	-- Hidden by unparenting, never by Transparency: the disc's opacity is authored content.
	local function setGhostShown(shown)
		if ghost then
			ghost.Parent = shown and Workspace or nil
		end
		if not shown then
			setWarning(nil)
			coverage.clear()
		end
	end

	-- `reason` is nil when the spot is legal, otherwise the line the warning label shows.
	local function setGhostValid(valid, reason)
		setWarning(if valid then nil else reason)
		if valid == ghostValid or not (ghost and activeItem) then
			return
		end
		ghostValid = valid
		local color = valid and activeItem.FieldColor or INVALID_COLOR
		for _, part in ipairs(discParts) do
			part.Color = color
		end
		-- The sonar ring is a Highlight, not a part, so it needs colouring separately or the ping
		-- keeps travelling in the item's colour over a disc that has already gone red.
		for _, descendant in ipairs(ghost:GetDescendants()) do
			if descendant:IsA("Highlight") then
				descendant.OutlineColor = color
			end
		end
	end

	-- Where the player is aiming. Touch uses the last finger position in SCREEN space (which
	-- includes the topbar inset, hence ScreenPointToRay); the mouse reports viewport space. A
	-- gamepad has no pointer at all and aims down the centre of the screen.
	local function pointerRay(camera)
		if touchPosition then
			return camera:ScreenPointToRay(touchPosition.X, touchPosition.Y)
		end
		if PlacementControls.isGamepad() then
			local viewport = camera.ViewportSize
			return camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
		end
		if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
			-- Touch, but the player has not touched the world yet: hold the seeded position rather
			-- than snapping the disc somewhere arbitrary.
			return nil
		end
		local location = UserInputService:GetMouseLocation()
		return camera:ViewportPointToRay(location.X, location.Y)
	end

	-- Each floor can hold one field of each type, so a floor that already has this one is refused.
	-- Checking it here turns a wasted commit into a red disc before the player taps.
	local function duplicateOn(surface)
		local sheet = surface and surface.sheet
		if not sheet then
			return false
		end
		local targetFloorId = FloorConfig.NormalizeId(surface.floorId)
		for _, child in ipairs(sheet:GetChildren()) do
			if
				child.Name == BoostShopConfig.FieldNamePrefix .. activeItem.Id
				and FloorConfig.NormalizeId(child:GetAttribute(Attrs.FloorId)) == targetFloorId
			then
				return true
			end
		end
		return false
	end

	local function moveGhostTo(position)
		ghostPosition = position
		ghost:PivotTo(CFrame.new(position) * ghostRotation)
		setGhostShown(true)
	end

	-- Over a plot: the point sits on the floor plane, which is exactly where the server will put
	-- the field.
	local function placeGhostAt(surface, hitPosition)
		moveGhostTo(FloorGeometry.ClampToSurface(surface, hitPosition, BoostShopConfig.FieldSurfaceLift))
		setGhostValid(not duplicateOn(surface), BoostShopConfig.Warnings.Duplicate)
		-- Counted even when the plot already has this field: the player still wants to know what a
		-- spot is worth while they hunt for a legal one.
		coverage.update(surface, ghostPosition, activeRadius, activeItem.FieldColor)
	end

	-- Off any plot: the ghost still follows the pointer, resting on whatever is under it, and says
	-- why it cannot be dropped there.
	local function placeGhostOffPlot(position)
		moveGhostTo(position + Vector3.new(0, WORLD_LIFT, 0))
		setGhostValid(false, BoostShopConfig.Warnings.OffPlot)
		coverage.clear()
	end

	-- Opening pose, mirroring StoreFloorPlacement.chooseInitialFloor: park the disc on the plot
	-- surface nearest the character so a touch or gamepad session starts with something on screen
	-- instead of an invisible ghost waiting for a first input.
	local function seedFromCharacter()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			return false
		end

		local bestSurface, bestPoint = nil, nil
		local bestDistance = math.huge
		for _, surface in ipairs(collectSurfaces()) do
			local point = FloorGeometry.ClampToSurface(surface, root.Position, BoostShopConfig.FieldSurfaceLift)
			local distance = (root.Position - point).Magnitude
			if distance < bestDistance then
				bestSurface, bestPoint, bestDistance = surface, point, distance
			end
		end
		if not bestSurface then
			return false
		end
		placeGhostAt(bestSurface, bestPoint)
		return true
	end

	-- Who re-aims the ghost every frame, and who only re-aims it on an input.
	--
	-- Classic PC placement follows the cursor continuously, and a gamepad has to track the camera
	-- because its aim IS the camera. TOUCH does neither: the disc sits where the last tap or drag
	-- put it and stays there, which is exactly how a building placement behaves once the screen
	-- controls are up (StorePlacement.tick skips its per-frame update in that mode for the same
	-- reason). Continuously re-resolving on touch made the disc chase the camera around the plot.
	local function usesContinuousAim()
		return not screenControlsOn() or PlacementControls.isGamepad()
	end

	local function refreshGhost()
		if not (ghost and activeItem) then
			return
		end
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local ray = pointerRay(camera)
		if not ray then
			return
		end

		-- Plot surfaces first. This is the only result that is exactly where the field will land,
		-- so it wins over anything the world raycast below would have found in front of it.
		local surface, hitPosition = FloorGeometry.FindSurfaceAlongRay(ray, collectSurfaces())
		if surface then
			placeGhostAt(surface, hitPosition)
			return
		end

		-- Nowhere legal: let the disc keep following the pointer over ordinary world geometry, red
		-- and captioned, instead of sticking to the last plot edge. Aiming somewhere illegal should
		-- look illegal, not look broken.
		local character = player.Character
		rayParams.FilterDescendantsInstances = character and { ghost, character } or { ghost }
		local result = Workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, rayParams)
		if result then
			placeGhostOffPlot(result.Position)
		else
			setGhostShown(false)
		end
	end

	local function tickGhost()
		if usesContinuousAim() then
			refreshGhost()
		end
	end

	local function confirm()
		if not (activeItem and ghost) or dropInFlight then
			return
		end
		-- The warning label is already saying why, and the disc is already red, so a refused Confirm
		-- just does nothing rather than stacking a second explanation on top of the first.
		if not (ghostPosition and ghostValid) then
			return
		end

		local item = activeItem
		local position = ghostPosition
		dropInFlight = true

		task.spawn(function()
			local ok, result = pcall(Net.invoke, Net.Names.DropBoostField, item.Id, position)
			dropInFlight = false

			if not ok or type(result) ~= "table" then
				message("Couldn't place the field. Try again.")
				return
			end
			-- The charge is spent (or explicitly refused) either way, so the session always ends:
			-- leaving the ghost up after a refusal invites the player to burn taps on a plot that
			-- already has this field.
			if activeItem == item then
				exit()
			end
			if not result.success then
				message(result.message or "Couldn't place the field. Try again.")
			end
		end)
	end

	-- Refused while a building placement owns the world, so only one ghost is ever live. Entering
	-- again for the item already held toggles the session off (the hotbar key doubles as cancel).
	local function enter(item)
		if activeItem then
			exit()
			return false
		end
		if screenGui:GetAttribute(Attrs.PlacementActive) == true then
			return false
		end

		activeItem = item
		touchPosition = nil
		activeTouch = nil
		multiTouch = false
		touchCount = 0
		mouseDown = false
		heldModel = buildHeld(item)
		ghost = buildGhost(item)
		ghostValid = false
		ghostPosition = nil
		dropInFlight = false
		cachedSurfaces = nil

		-- BoostFieldPlacementActive is raised FIRST so the building controls are already inert by
		-- the time PlacementActive brings the shared faces up. The open entrance goes up with it:
		-- a field starts from the visible hotbar, so without it the controls would slide over from
		-- their carousel poses instead of opening the way they do out of the store band.
		screenGui:SetAttribute(Attrs.BoostFieldPlacementActive, true)
		screenGui:SetAttribute(Attrs.PlacementControlsOpenEntrance, true)
		screenGui:SetAttribute(Attrs.PlacementControlsNoRotate, true)
		screenGui:SetAttribute(Attrs.PlacementActive, true)
		task.defer(function()
			-- Runs after HotbarPlacementMode has laid out the faces for this session.
			if not activeItem then
				return
			end
			-- StorePlacementControls leaves Confirm's Active/Interactable wherever its last BUILDING
			-- session left them (it only writes these while it owns the session), so a field must
			-- claim the buttons it drives or they stay dead from a previous placement.
			local function claim(button)
				if button then
					button.Active = true
					button.Interactable = true
				end
			end
			if screenControlsOn() then
				claim(cancelHitbox)
				claim(confirmHitbox)
				-- A controller reaches the faces only as the engine's selected object.
				PlacementControls.setGamepadFocus(confirmHitbox)
			else
				claim(centerHitbox)
			end
		end)

		if not seedFromCharacter() then
			setGhostShown(false)
		end
		-- On touch this is a no-op, leaving the seeded pose alone until the player taps the world.
		tickGhost()
		renderConn = RunService.RenderStepped:Connect(tickGhost)
		pulse = BoostFieldPulse.attach(ghost, BoostShopConfig.Pulse.Ghost)
		return true
	end

	if cancelHitbox then
		cancelHitbox.Activated:Connect(function()
			if activeItem and screenControlsOn() then
				exit()
			end
		end)
	end
	if confirmHitbox then
		confirmHitbox.Activated:Connect(function()
			if activeItem and screenControlsOn() then
				confirm()
			end
		end)
	end
	if centerHitbox then
		centerHitbox.Activated:Connect(function()
			-- Classic only: the centre is Rotate when screen controls are on, and a field never
			-- rotates, so the tap is simply ignored there.
			if activeItem and not screenControlsOn() then
				exit()
			end
		end)
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.Touch then
			touchCount += 1
			if touchCount >= 2 then
				multiTouch = true
				activeTouch = nil
			end
		end
		if not activeItem then
			return
		end
		-- B matches the console back button used by every modal in this game; X and Escape are the
		-- keyboard cancels buildings already use.
		if
			input.KeyCode == Enum.KeyCode.X
			or input.KeyCode == Enum.KeyCode.Escape
			or input.KeyCode == Enum.KeyCode.ButtonB
		then
			exit()
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch then
			-- The tap IS the reposition on touch: nothing re-aims the ghost per frame in this mode,
			-- so it moves here and then stays put until the next tap or drag.
			if not (processed or multiTouch) then
				activeTouch = activeTouch or input
				touchPosition = Vector2.new(input.Position.X, input.Position.Y)
				refreshGhost()
			end
			return
		end
		-- `processed` keeps the very tap that equipped the item (a GUI click on its hotbar slot)
		-- from committing the drop underneath it.
		if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if screenControlsOn() then
			-- Screen controls opted in on a PC: a click only REPOSITIONS and Confirm commits, the
			-- same two-step buildings give this mode. Without this the ghost would be frozen, since
			-- nothing re-aims it per frame here and a mouse produces no touch events.
			mouseDown = true
			refreshGhost()
			return
		end
		confirm()
	end)

	-- The drag half of tap-and-drag. Only the finger that owns the placement moves the ghost; the
	-- one left over from a camera pinch was cleared, so it never drags the disc along with it.
	UserInputService.InputChanged:Connect(function(input)
		if
			activeItem
			and input.UserInputType == Enum.UserInputType.Touch
			and input == activeTouch
			and not multiTouch
		then
			touchPosition = Vector2.new(input.Position.X, input.Position.Y)
			refreshGhost()
		elseif
			activeItem
			and mouseDown
			and input.UserInputType == Enum.UserInputType.MouseMovement
			and screenControlsOn()
		then
			-- The drag half of the PC screen-controls mode.
			refreshGhost()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseDown = false
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		touchCount = math.max(0, touchCount - 1)
		if input == activeTouch then
			activeTouch = nil
		end
		if touchCount == 0 then
			-- Every finger is up: the next single touch is a placement drag again.
			multiTouch = false
		end
	end)

	-- Placement is subordinate to the store, modals, and the character, exactly as StorePlacement
	-- is. Without these a field session survives underneath an open Settings window, holding the
	-- hotbar hostage and leaving a live ghost the player cannot see to cancel.
	screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(function()
		if screenGui:GetAttribute(Attrs.StoreOpen) == true then
			exit()
		end
	end)
	screenGui:GetAttributeChangedSignal(Attrs.OpenModal):Connect(function()
		if (screenGui:GetAttribute(Attrs.OpenModal) or "") ~= "" then
			exit()
		end
	end)
	screenGui:GetAttributeChangedSignal(Attrs.BackgroundSurfacesSuspended):Connect(function()
		if screenGui:GetAttribute(Attrs.BackgroundSurfacesSuspended) == true then
			exit()
		end
	end)
	player.CharacterRemoving:Connect(exit)

	return {
		enter = enter,
		exit = exit,
		isActive = function()
			return activeItem ~= nil
		end,
		activeItemId = function()
			return activeItem and activeItem.Id or nil
		end,
	}
end

return BoostFieldPlacement
