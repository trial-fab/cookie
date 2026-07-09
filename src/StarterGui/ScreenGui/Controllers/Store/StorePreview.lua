-- StorePreview: building preview viewports + drag-to-spin interaction state. Each built
-- model spins like a microwave turntable; rows can be dragged to rotate manually. Owns the
-- previewSpinners registry and the previewInteraction object (returned as ctx.preview) whose
-- shared drag state (activeDragOwner / touchControllers / activeTouchController) is driven by
-- StoreCookieStats. ensureViewport consults ctx.isBuildingLocked to render the locked
-- silhouette; setRequirementUi uses ctx.format for the count text.
local StorePreview = {}
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))

function StorePreview.new(ctx)
	local UpgradeConfig = ctx.UpgradeConfig
	local buildingPreviews = ctx.buildingPreviews
	local formatCount = ctx.format.formatCount
	local placeholderIcon = ctx.placeholderIcon

	-- Preview models slowly spin in place like a microwave turntable. Each built model
	-- registers its rest pivot + bounding-box centre; the render loop rotates it about
	-- the vertical axis through that centre. Keyed by viewport so rebuilds replace it.
	local previewSpinners = {}
	local previewInteraction = {
		autoSpinSpeed = 0.35,
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

	-- Buildings may hold a Studio-authored "Front" marker part (invisible, non-collidable) that
	-- pinpoints the static upgrade preview's camera. It must be pulled from EVERY cloned preview
	-- before measuring/rendering so it never inflates the bounding box or shows up. Only the static
	-- upgrade preview uses the returned position; the spinning cards and requirement previews just
	-- discard it. Returns the marker's world position, or nil if there is none.
	local function extractFrontMarker(model)
		local part = model:FindFirstChild("Front", true)
		if part and part:IsA("BasePart") then
			local pos = part.Position
			part:Destroy()
			return pos
		end
		return nil
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
		extractFrontMarker(model)
		model.Parent = world

		local boundingCFrame, size = model:GetBoundingBox()
		local center = boundingCFrame.Position
		local maxDimension = math.max(size.X, size.Y, size.Z, 1)

		local camera = Instance.new("Camera")
		camera.Name = "RequirementCamera"
		camera.FieldOfView = 35
		camera.CFrame = CFrame.lookAt(center + Vector3.new(maxDimension * 1.2, maxDimension * 0.75, maxDimension * 1.25), center)
		camera.Parent = viewport
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

	-- Renders a building model into a viewport as a STATIC (non-spinning) front-facing shot,
	-- zoomed a little tighter than the spinning building cards. Never registered in
	-- previewSpinners, so the render loop leaves it alone. Only rebuilds when the target changes.
	-- Frame chrome (background, border, size, position) is Studio's; this sets only the lighting
	-- and 3D contents. targetConfig.PreviewYaw (degrees) dials a building's front per-building.
	local function renderStaticBuilding(viewport, sourceModel, targetName, targetConfig)
		if viewport:GetAttribute(Attrs.UpgradeId) == targetName and viewport.CurrentCamera then
			return
		end
		for _, child in ipairs(viewport:GetChildren()) do
			child:Destroy()
		end
		viewport.CurrentCamera = nil
		viewport:SetAttribute(Attrs.UpgradeId, targetName)
		viewport.Ambient = Color3.fromRGB(170, 180, 190)
		viewport.LightColor = Color3.fromRGB(255, 245, 220)
		viewport.LightDirection = Vector3.new(-0.4, -0.8, -0.35)

		local world = Instance.new("WorldModel")
		world.Name = "PreviewWorld"
		world.Parent = viewport

		local model = sourceModel:Clone()
		model.Name = "PreviewModel"
		setPreviewModelState(model)
		-- The "Front" marker (if any) sits at the camera's vantage point: the camera goes to its
		-- position and looks at the building's centre, so its placement controls both the front
		-- angle and the zoom distance. It is removed here so it never inflates the box or renders.
		local frontPos = extractFrontMarker(model)
		model.Parent = world

		local boundingCFrame, size = model:GetBoundingBox()
		local center = boundingCFrame.Position
		local maxDimension = math.max(size.X, size.Y, size.Z, 1)

		local camCFrame
		if frontPos then
			camCFrame = CFrame.lookAt(frontPos, center)
		else
			-- No Front marker: straight-on +Z view, PreviewYaw-rotatable, at a fixed zoom.
			local yaw = math.rad(tonumber(targetConfig and targetConfig.PreviewYaw) or 0)
			local dist = maxDimension * 1.35
			local offset = CFrame.Angles(0, yaw, 0):VectorToWorldSpace(Vector3.new(0, size.Y * 0.12, dist))
			camCFrame = CFrame.lookAt(center + offset, center)
		end

		local camera = Instance.new("Camera")
		camera.Name = "PreviewCamera"
		camera.FieldOfView = 35
		camera.CFrame = camCFrame
		camera.Parent = viewport
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
		renderStaticBuilding(viewport, sourceModel, targetName, targetConfig)
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
		if viewport:GetAttribute(Attrs.UpgradeId) == row.Name and viewport:GetAttribute("Silhouette") == wantSilhouette and viewport.CurrentCamera then
			return
		end

		clearViewport(row)
		viewport:SetAttribute(Attrs.UpgradeId, row.Name)
		viewport:SetAttribute("Silhouette", wantSilhouette)
		viewport.BackgroundTransparency = 1
		viewport.BorderSizePixel = 0
		viewport.Ambient = Color3.fromRGB(170, 180, 190)
		viewport.LightColor = Color3.fromRGB(255, 245, 220)
		viewport.LightDirection = Vector3.new(-0.4, -0.8, -0.35)

		local templateName = config.TemplateName or config.DisplayName
		local sourceModel = templateName and buildingPreviews:FindFirstChild(templateName)
		if not sourceModel then
			-- No 3D preview model yet: show the "?" placeholder so the card still reads.
			setPreviewPlaceholder(viewport, true)
			return
		end
		setPreviewPlaceholder(viewport, false)

		local world = Instance.new("WorldModel")
		world.Name = "PreviewWorld"
		world.Parent = viewport

		local model = sourceModel:Clone()
		model.Name = "PreviewModel"
		setPreviewModelState(model)
		extractFrontMarker(model)
		if wantSilhouette then
			applyPreviewSilhouette(model)
		end
		model.Parent = world

		local boundingCFrame, size = model:GetBoundingBox()
		local center = boundingCFrame.Position
		local maxDimension = math.max(size.X, size.Y, size.Z, 1)

		local camera = Instance.new("Camera")
		camera.Name = "PreviewCamera"
		camera.FieldOfView = 35
		camera.CFrame = CFrame.lookAt(center + Vector3.new(maxDimension * 1.2, maxDimension * 0.75, maxDimension * 1.25), center)
		camera.Parent = viewport
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

	return previewInteraction
end

return StorePreview
