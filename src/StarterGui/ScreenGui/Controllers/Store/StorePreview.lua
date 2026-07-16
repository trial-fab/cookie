-- StorePreview: building preview viewports + drag-to-spin interaction state. Each built
-- model spins like a microwave turntable; rows can be dragged to rotate manually. Owns the
-- previewSpinners registry and the previewInteraction object (returned as ctx.preview) whose
-- shared drag state (activeDragOwner / touchControllers / activeTouchController) is driven by
-- StoreCookieStats. ensureViewport consults ctx.isBuildingLocked to render the locked
-- silhouette; setRequirementUi uses ctx.format for the count text.
local StorePreview = {}
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))

function StorePreview.new(ctx)
	local UpgradeConfig = ctx.UpgradeConfig
	local buildingPreviews = ctx.buildingPreviews
	local formatCount = ctx.format.formatCount
	local placeholderIcon = ctx.placeholderIcon
	local screenGui = ctx.screenGui

	-- Preview models slowly spin in place like a microwave turntable. Each built model
	-- registers its rest pivot + bounding-box centre; the render loop rotates it about
	-- the vertical axis through that centre. Keyed by viewport so rebuilds replace it.
	local previewSpinners = {}
	local previewInteraction = {
		autoSpinSpeed = 0.3,
		dragThresholdPx = 6,
		dragRadiansPerPixel = 0.015,
		activeDragOwner = nil,
		activeTouchController = nil,
		touchControllers = {},
	}

	function previewInteraction.getSpinner(row)
		local viewport = row and row:FindFirstChild("Preview", true)
		if viewport and viewport:IsA("ViewportFrame") then
			return previewSpinners[viewport]
		end

		return nil
	end

	function previewInteraction.getAngle(spinner)
		if spinner.isDragging then
			return (spinner.manualAngle or 0) + (spinner.dragAutoTheta or 0)
		end

		return (spinner.manualAngle or 0) + os.clock() * previewInteraction.autoSpinSpeed
	end

	function previewInteraction.setDragging(spinner, isDragging)
		if not spinner then
			return
		end

		if isDragging then
			if not spinner.isDragging then
				spinner.isDragging = true
				spinner.dragAutoTheta = os.clock() * previewInteraction.autoSpinSpeed
			end
		else
			if spinner.isDragging then
				spinner.manualAngle = previewInteraction.getAngle(spinner) - os.clock() * previewInteraction.autoSpinSpeed
				spinner.isDragging = false
				spinner.dragAutoTheta = nil
			end
		end
	end

	function previewInteraction.rotate(row, deltaX)
		local spinner = previewInteraction.getSpinner(row)
		if not spinner then
			return
		end

		previewInteraction.setDragging(spinner, true)
		spinner.manualAngle = (spinner.manualAngle or 0) + deltaX * previewInteraction.dragRadiansPerPixel
	end

	local function clearViewport(row)
		local viewport = row and row:FindFirstChild("Preview", true)
		if viewport and viewport:IsA("ViewportFrame") then
			previewSpinners[viewport] = nil
			for _, child in ipairs(viewport:GetChildren()) do
				child:Destroy()
			end
			viewport.CurrentCamera = nil
		end
	end

	-- Shows/hides a "?" placeholder image over a building card's preview slot when no 3D model
	-- exists for it yet, so the card layout is still visible. The placeholder mirrors the
	-- viewport's transform so it sits exactly where the model would render.
	local function setPreviewPlaceholder(viewport, show)
		local parent = viewport and viewport.Parent
		if not parent then
			return
		end

		local placeholder = parent:FindFirstChild("PreviewPlaceholder")
		if show and placeholderIcon and placeholderIcon ~= "" then
			if not placeholder then
				placeholder = Instance.new("ImageLabel")
				placeholder.Name = "PreviewPlaceholder"
				placeholder.BackgroundTransparency = 1
				placeholder.ScaleType = Enum.ScaleType.Fit
				placeholder.Image = placeholderIcon
				placeholder.Parent = parent
			end
			placeholder.AnchorPoint = viewport.AnchorPoint
			placeholder.Position = viewport.Position
			placeholder.Size = viewport.Size
			placeholder.ZIndex = viewport.ZIndex + 1
			placeholder.Visible = true
		elseif placeholder then
			placeholder.Visible = false
		end
	end

	local function spinModel(spinner)
		local theta = previewInteraction.getAngle(spinner)
		spinner.model:PivotTo(CFrame.new(spinner.center) * CFrame.Angles(0, theta, 0) * CFrame.new(-spinner.center) * spinner.basePivot)
	end

	-- Only viewports actually on-screen need to spin. previewSpinners retains every built
	-- card, including ones scrolled out of the ScrollingFrame, so without this cull we'd
	-- PivotTo heavy models nobody is looking at every frame — and PivotTo forces the viewport
	-- to redraw, defeating the renderer's static-viewport caching. clipFrame is the scrolling
	-- container; a viewport whose rect doesn't intersect it is skipped. Auto-spin is
	-- clock-based (getAngle), so a skipped model resumes at the correct angle when it scrolls
	-- back into view — no visible pop.
	local function spinPreviews(clipFrame)
		if screenGui and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true then
			return
		end
		local clipPos = clipFrame and clipFrame.AbsolutePosition
		local clipSize = clipFrame and clipFrame.AbsoluteSize

		for viewport, spinner in pairs(previewSpinners) do
			if not spinner.model.Parent then
				previewSpinners[viewport] = nil
			elseif not clipPos then
				spinModel(spinner)
			else
				local vpPos = viewport.AbsolutePosition
				local vpSize = viewport.AbsoluteSize
				if vpPos.X < clipPos.X + clipSize.X
					and vpPos.X + vpSize.X > clipPos.X
					and vpPos.Y < clipPos.Y + clipSize.Y
					and vpPos.Y + vpSize.Y > clipPos.Y then
					spinModel(spinner)
				end
			end
		end
	end

	local function setPreviewModelState(model)
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
			elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
				descendant.Disabled = true
			end
		end
	end

	-- Renders a never-purchased building's preview as a flat dark silhouette so the
	-- store reads "locked / undiscovered" until the first one is bought.
	local function applyPreviewSilhouette(model)
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Color = Color3.fromRGB(18, 20, 28)
				descendant.Material = Enum.Material.SmoothPlastic
				descendant.Reflectance = 0
				if descendant:IsA("MeshPart") then
					descendant.TextureID = ""
				end
			elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
				descendant.Transparency = 1
			elseif descendant:IsA("SurfaceAppearance") then
				descendant:Destroy()
			end
		end
	end

	-- Legacy "Front" marker parts may still exist inside preview models (they used to aim
	-- the static camera). The camera no longer uses them, but they must still be pulled from
	-- every clone so an invisible marker never inflates the bounding box. Once the Front
	-- parts are deleted from ReplicatedStorage.BuildingPreviews this helper can go too.
	local function removeFrontMarker(model)
		local part = model:FindFirstChild("Front", true)
		if part and part:IsA("BasePart") then
			part:Destroy()
		end
	end

	-- Universal orbit framing for every STATIC building preview (upgrade rows, reduced-motion
	-- and mobile store cards). The camera FITS the building's oriented bounding box into the
	-- viewport frustum, so flat, tall, and wide buildings all fill the frame equally instead
	-- of sharing a distance keyed to their largest dimension. Zoom is the margin on that fit
	-- (1 = box exactly fills the frame, higher backs off, lower crops in), which also makes
	-- Fov a pure perspective-flatness dial. These final values are intentionally baked: static
	-- upgrade previews and their reduced-motion/mobile card fallback share one fixed composition.
	local function aimStaticCamera(viewport, camera, boxCFrame, boxSize)
		local angle = math.rad(180)
		local upRatio = 0.2
		local zoom = 1
		local ground = 0
		local fov = 20
		local direction = Vector3.new(math.cos(angle), upRatio, math.sin(angle)).Unit
		camera.FieldOfView = fov

		local center = boxCFrame.Position
		local forward = -direction
		local rot = CFrame.lookAt(center + direction, center)
		local right, up = rot.RightVector, rot.UpVector
		local tanVertical = math.tan(math.rad(fov) * 0.5)
		local absSize = viewport.AbsoluteSize
		local aspect = (absSize.X > 0 and absSize.Y > 0) and (absSize.X / absSize.Y) or 1
		local tanHorizontal = tanVertical * aspect

		-- Minimal distance that puts all 8 box corners inside both frustum planes.
		local fitDistance = 0
		local corners = {}
		for xi = -0.5, 0.5 do
			for yi = -0.5, 0.5 do
				for zi = -0.5, 0.5 do
					local corner = boxCFrame:PointToWorldSpace(Vector3.new(boxSize.X * xi, boxSize.Y * yi, boxSize.Z * zi))
					table.insert(corners, corner)
					local offset = corner - center
					local depth = offset:Dot(forward)
					fitDistance = math.max(
						fitDistance,
						math.abs(offset:Dot(right)) / tanHorizontal - depth,
						math.abs(offset:Dot(up)) / tanVertical - depth
					)
				end
			end
		end

		local distance = math.max(fitDistance, 0.5) * zoom

		-- Project all corners through the real tilted perspective camera. Normalized vertical
		-- coordinates are -1 at the bottom frustum plane and 1 at the top.
		local function projectedVerticalExtents(aimY)
			local aim = Vector3.new(center.X, aimY, center.Z)
			local cameraCFrame = CFrame.lookAt(aim + direction * distance, aim)
			local minV = math.huge
			local maxV = -math.huge
			for _, corner in ipairs(corners) do
				local relative = cameraCFrame:PointToObjectSpace(corner)
				local v = relative.Y / (-relative.Z * tanVertical)
				minV = math.min(minV, v)
				maxV = math.max(maxV, v)
			end
			return minV, maxV, cameraCFrame
		end

		-- Both projected extrema decrease as aimY rises. Expand from the box centre until
		-- the requested extent is bracketed, then solve it precisely by bisection.
		local function solveAimY(initialY, targetV, useMaximum)
			local function extentAt(aimY)
				local minV, maxV = projectedVerticalExtents(aimY)
				return useMaximum and maxV or minV
			end

			local initialV = extentAt(initialY)
			if initialV == targetV then
				return initialY
			end

			local lowY = initialY
			local highY = initialY
			local step = math.max(distance * 0.25, boxSize.Magnitude * 0.25, 0.5)
			if initialV > targetV then
				for _ = 1, 16 do
					highY += step
					if extentAt(highY) <= targetV then
						break
					end
					step *= 2
				end
			else
				for _ = 1, 16 do
					lowY -= step
					if extentAt(lowY) >= targetV then
						break
					end
					step *= 2
				end
			end

			for _ = 1, 24 do
				local midY = (lowY + highY) * 0.5
				if extentAt(midY) > targetV then
					lowY = midY
				else
					highY = midY
				end
			end
			return (lowY + highY) * 0.5
		end

		-- Shared ground line: solve the true perspective position of the lowest corner,
		-- then raise the aim only if needed to keep the highest corner inside the frame.
		local targetMinV = -(1 - 2 * ground)
		local aimY = solveAimY(center.Y, targetMinV, false)
		local _, maxV = projectedVerticalExtents(aimY)
		if maxV > 1 then
			aimY = solveAimY(aimY, 1, true)
		end
		local _, _, cameraCFrame = projectedVerticalExtents(aimY)
		camera.CFrame = cameraCFrame
	end

	-- Simple base-anchored framing shared by the spinning StoreBottom cards and the small
	-- requirement thumbnail. A virtual minimum height raises the aim for short buildings without
	-- adding parts or stacking a separate vertical offset on top of the camera composition.
	local function aimBaseAnchoredCamera(camera, boundingCFrame, size, angleDegrees, up, zoom, minimumHeight, fov)
		local angle = math.rad(angleDegrees)
		local frameHeight = math.max(size.Y, minimumHeight)
		local aim = boundingCFrame:PointToWorldSpace(Vector3.new(0, (frameHeight - size.Y) * 0.5, 0))
		local maxDimension = math.max(size.X, frameHeight, size.Z, 1)
		local offset = Vector3.new(math.cos(angle) * zoom, up, math.sin(angle) * zoom) * maxDimension

		camera.FieldOfView = fov
		camera.CFrame = CFrame.lookAt(aim + offset, aim)
	end

	-- Final StoreBottom composition, baked after live tuning.
	local function aimSpinningCamera(camera, boundingCFrame, size)
		aimBaseAnchoredCamera(camera, boundingCFrame, size, 46.16913932790743, 0.5, 1.9, 6, 40)
	end

	local function aimRequirementCamera(camera, boundingCFrame, size)
		aimBaseAnchoredCamera(camera, boundingCFrame, size, 225, 0.5, 1.5, 1, 40)
	end

	function previewInteraction.clearRequirementPreview(viewport)
		if not viewport or not viewport:IsA("ViewportFrame") then
			return
		end

		for _, child in ipairs(viewport:GetChildren()) do
			child:Destroy()
		end
		viewport.CurrentCamera = nil
		viewport:SetAttribute("RequirementUpgradeId", nil)
	end

	function previewInteraction.renderRequirementPreview(viewport, requiredId)
		if not viewport or not viewport:IsA("ViewportFrame") or type(requiredId) ~= "string" then
			return
		end

		if viewport:GetAttribute("RequirementUpgradeId") == requiredId and viewport.CurrentCamera then
			return
		end

		previewInteraction.clearRequirementPreview(viewport)
		viewport:SetAttribute("RequirementUpgradeId", requiredId)
		viewport.BackgroundTransparency = 1
		viewport.BorderSizePixel = 0
		viewport.Ambient = Color3.fromRGB(170, 180, 190)
		viewport.LightColor = Color3.fromRGB(255, 245, 220)
		viewport.LightDirection = Vector3.new(-0.4, -0.8, -0.35)

		local requiredConfig = UpgradeConfig[requiredId]
		local templateName = requiredConfig and (requiredConfig.TemplateName or requiredConfig.DisplayName)
		local sourceModel = templateName and buildingPreviews:FindFirstChild(templateName)
		if not sourceModel then
			return
		end

		local world = Instance.new("WorldModel")
		world.Name = "RequirementWorld"
		world.Parent = viewport

		local model = sourceModel:Clone()
		model.Name = "RequirementModel"
		setPreviewModelState(model)
		removeFrontMarker(model)
		model.Parent = world

		local boundingCFrame, size = model:GetBoundingBox()

		local camera = Instance.new("Camera")
		camera.Name = "RequirementCamera"
		camera.Parent = viewport
		aimRequirementCamera(camera, boundingCFrame, size)
		viewport.CurrentCamera = camera
	end

	-- The requirement overlay is translucent, so the cost-pill stroke behind it would bleed
	-- through. Hide it while locked and restore the authored visible state once unlocked.
	local function setRequirementStrokeHidden(stroke, hidden)
		if not stroke then
			return
		end
		stroke.Transparency = hidden and 1 or 0
	end

	function previewInteraction.setRequirementUi(row, requiredId, requiredCount, ownedCount)
		if not row then
			return
		end

		local shouldShow = type(requiredId) == "string" and type(requiredCount) == "number" and requiredCount > 0

		local requirement = row:FindFirstChild("Requirement", true)
		local requirementValid = requirement ~= nil and requirement:IsA("GuiObject")

		-- The Requirement content may be wrapped in a reqBackground frame (Building Template)
		-- or sit directly under cookieCost (other templates). Toggle the outermost wrapper so
		-- the backing frame and its content reveal together — toggling the inner Requirement
		-- alone leaves the default-hidden (Visible=false) reqBackground covering everything.
		local requirementRoot = requirement
		if requirementValid then
			local wrapper = requirement.Parent
			if wrapper and wrapper:IsA("GuiObject") and wrapper.Name == "reqBackground" then
				requirementRoot = wrapper
			end
		end

		-- Show the Requirement widget in place of the blue cost pill while the gate is
		-- unmet. In the current layout the widget is nested INSIDE cookieCost and opaquely
		-- overlays it (slightly oversized), so hiding cookieCost would hide the widget too —
		-- keep the pill visible and let the overlay cover it. Only toggle the pill in the
		-- legacy layout where the widget is a separate sibling sharing the same row slot.
		local cookieCost = row:FindFirstChild("cookieCost", true)
		if cookieCost and cookieCost:IsA("GuiObject") then
			if requirementValid and requirementRoot:IsDescendantOf(cookieCost) then
				cookieCost.Visible = true
				-- The reqBackground overlay is translucent, so the cost Content would bleed
				-- through it. Hide cookieCost's own Content while the requirement is up, restore
				-- it otherwise. Non-recursive lookup so we grab cookieCost.Content, never the
				-- Requirement's own Content frame.
				local content = cookieCost:FindFirstChild("Content")
				if content and content:IsA("GuiObject") then
					content.Visible = not shouldShow
				end
				-- cookieFrame (Building & Upgrade templates) is hidden outright, and the cookieCost
				-- stroke blanks out, while the requirement overlay is up so they don't bleed through.
				local cookieFrame = cookieCost:FindFirstChild("cookieFrame")
				if cookieFrame and cookieFrame:IsA("GuiObject") then
					cookieFrame.Visible = not shouldShow
				end
			else
				cookieCost.Visible = not shouldShow
			end
			setRequirementStrokeHidden(cookieCost:FindFirstChildOfClass("UIStroke"), shouldShow)
		end

		if not requirementValid then
			return
		end

		requirementRoot.Visible = shouldShow
		if requirementRoot ~= requirement then
			requirement.Visible = true
		end
		if not shouldShow then
			previewInteraction.clearRequirementPreview(requirement:FindFirstChild("RequirementPreview", true))
			return
		end

		local countLabel = requirement:FindFirstChild("RequirementCount", true)
		if countLabel and (countLabel:IsA("TextLabel") or countLabel:IsA("TextButton")) then
			countLabel.Text = formatCount(ownedCount or 0) .. "/" .. formatCount(requiredCount)
		end

		previewInteraction.renderRequirementPreview(requirement:FindFirstChild("RequirementPreview", true), requiredId)
	end

	-- Renders a building model into a viewport as a STATIC (non-spinning) shot using the
	-- universal orbit framing (aimStaticCamera). BuildingUpgrade rows always use it; building
	-- cards reuse it while Reduced Motion is on. Never registered in previewSpinners, so the
	-- render loop leaves it alone. Only rebuilds when the target or style changes. Frame chrome
	-- (background, border, size, position) is Studio's; this sets only the lighting and 3D contents.
	local function renderStaticBuilding(viewport, sourceModel, targetName, silhouette)
		silhouette = silhouette == true
		if viewport:GetAttribute(Attrs.UpgradeId) == targetName
			and viewport:GetAttribute("PreviewMode") == "Static"
			and viewport:GetAttribute("Silhouette") == silhouette
			and viewport.CurrentCamera then
			return
		end
		previewSpinners[viewport] = nil
		for _, child in ipairs(viewport:GetChildren()) do
			child:Destroy()
		end
		viewport.CurrentCamera = nil
		viewport:SetAttribute(Attrs.UpgradeId, targetName)
		viewport:SetAttribute("PreviewMode", "Static")
		viewport:SetAttribute("Silhouette", silhouette)
		viewport.Ambient = Color3.fromRGB(170, 180, 190)
		viewport.LightColor = Color3.fromRGB(255, 245, 220)
		viewport.LightDirection = Vector3.new(-0.4, -0.8, -0.35)

		local world = Instance.new("WorldModel")
		world.Name = "PreviewWorld"
		world.Parent = viewport

		local model = sourceModel:Clone()
		model.Name = "PreviewModel"
		setPreviewModelState(model)
		if silhouette then
			applyPreviewSilhouette(model)
		end
		removeFrontMarker(model)
		model.Parent = world

		local boundingCFrame, size = model:GetBoundingBox()

		local camera = Instance.new("Camera")
		camera.Name = "PreviewCamera"
		camera.Parent = viewport
		aimStaticCamera(viewport, camera, boundingCFrame, size)
		viewport.CurrentCamera = camera
	end

	-- BuildingUpgrade rows show their TargetBuilding as a static preview, filling a Studio-authored
	-- ViewportFrame named "UpgradePreview" on the row template (the user owns its size/position/
	-- background). Until that slot exists the icon renderer stays in charge of the row.
	local function ensureUpgradePreview(row, config)
		local viewport = row:FindFirstChild("UpgradePreview", true)
		if not viewport or not viewport:IsA("ViewportFrame") then
			row:SetAttribute("BuildingPreviewActive", nil)
			return
		end

		local targetName = config.TargetBuilding
		local targetConfig = targetName and UpgradeConfig[targetName]
		local templateName = targetConfig and (targetConfig.TemplateName or targetConfig.DisplayName) or targetName
		local sourceModel = templateName and buildingPreviews:FindFirstChild(templateName)
		if not sourceModel then
			row:SetAttribute("BuildingPreviewActive", nil)
			return
		end

		row:SetAttribute("BuildingPreviewActive", true)
		-- The row's Icon slot is shared with Stat rows via TemplateUpgrade, so it can't be hidden in
		-- the template — hide it per BuildingUpgrade row here so the placeholder "?" doesn't sit
		-- under the preview. applyUpgradeIcon is guarded on BuildingPreviewActive, so it stays hidden.
		local icon = row:FindFirstChild("Icon", true)
		if icon and icon:IsA("GuiObject") then
			icon.Visible = false
		end
		renderStaticBuilding(viewport, sourceModel, targetName, false)
	end

	local function ensureViewport(row, config)
		if not row or not row:IsA("GuiObject") or not config then
			clearViewport(row)
			return
		end
		if config.TemplateKind == "BuildingUpgrade" then
			ensureUpgradePreview(row, config)
			return
		end
		if config.TemplateKind ~= "Building" then
			clearViewport(row)
			return
		end

		local viewport = row:FindFirstChild("Preview", true)
		if not viewport then
			viewport = Instance.new("ViewportFrame")
			viewport.Name = "Preview"
			viewport.Parent = row
		end

		-- Rebuild when the target changes or when the silhouette state flips (first buy).
		local wantSilhouette = ctx.isBuildingLocked(row.Name, config)
		local reducedMotion = screenGui and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
		local wantedMode = reducedMotion and "Static" or "Spinning"
		if viewport:GetAttribute(Attrs.UpgradeId) == row.Name
			and viewport:GetAttribute("PreviewMode") == wantedMode
			and viewport:GetAttribute("Silhouette") == wantSilhouette
			and viewport.CurrentCamera then
			return
		end

		local templateName = config.TemplateName or config.DisplayName
		local sourceModel = templateName and buildingPreviews:FindFirstChild(templateName)
		if not sourceModel then
			-- No 3D preview model yet: show the "?" placeholder so the card still reads.
			clearViewport(row)
			setPreviewPlaceholder(viewport, true)
			return
		end
		setPreviewPlaceholder(viewport, false)
		viewport.BackgroundTransparency = 1
		viewport.BorderSizePixel = 0
		if reducedMotion then
			-- Reuse the same universal static composition as BuildingUpgrade rows.
			-- Locked buildings keep their existing dark silhouette treatment.
			renderStaticBuilding(viewport, sourceModel, row.Name, wantSilhouette)
			return
		end

		clearViewport(row)
		viewport:SetAttribute(Attrs.UpgradeId, row.Name)
		viewport:SetAttribute("PreviewMode", "Spinning")
		viewport:SetAttribute("Silhouette", wantSilhouette)
		viewport.BackgroundTransparency = 1
		viewport.BorderSizePixel = 0
		viewport.Ambient = Color3.fromRGB(170, 180, 190)
		viewport.LightColor = Color3.fromRGB(255, 245, 220)
		viewport.LightDirection = Vector3.new(-0.4, -0.8, -0.35)

		local world = Instance.new("WorldModel")
		world.Name = "PreviewWorld"
		world.Parent = viewport

		local model = sourceModel:Clone()
		model.Name = "PreviewModel"
		setPreviewModelState(model)
		removeFrontMarker(model)
		if wantSilhouette then
			applyPreviewSilhouette(model)
		end
		model.Parent = world

		local boundingCFrame, size = model:GetBoundingBox()
		local center = boundingCFrame.Position

		local camera = Instance.new("Camera")
		camera.Name = "PreviewCamera"
		camera.Parent = viewport
		aimSpinningCamera(camera, boundingCFrame, size)
		viewport.CurrentCamera = camera

		previewSpinners[viewport] = {
			model = model,
			basePivot = model:GetPivot(),
			center = center,
			manualAngle = 0,
			isDragging = false,
		}
	end

	-- Attach the standalone viewport helpers to the returned object so the orchestrator
	-- can call them (and alias them) alongside the previewInteraction methods.
	previewInteraction.clearViewport = clearViewport
	previewInteraction.spinPreviews = spinPreviews
	previewInteraction.ensureViewport = ensureViewport

	if screenGui then
		screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
			for upgradeId, row in pairs(ctx.rowsByUpgradeId) do
				ensureViewport(row, UpgradeConfig[upgradeId])
			end
		end)
	end

	return previewInteraction
end

return StorePreview
