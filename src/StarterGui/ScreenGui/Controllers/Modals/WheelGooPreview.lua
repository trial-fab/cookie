-- Static ViewportFrame renderer for wheel/collection goo previews. Models come from the
-- same ReplicatedStorage.GooSkinAssets library used by StoryService.
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GooSkinConfig = require(ReplicatedStorage.Shared.GooSkinConfig)
local GooSkinAssets = require(ReplicatedStorage.Shared.GooSkinAssets)

local Renderer = {}
local SILHOUETTE = Color3.fromRGB(18, 20, 28)
local DEFAULT_SKYBOX = {
	SkyboxBk = "rbxasset://textures/sky/sky512_bk.tex",
	SkyboxDn = "rbxasset://textures/sky/sky512_dn.tex",
	SkyboxFt = "rbxasset://textures/sky/sky512_ft.tex",
	SkyboxLf = "rbxasset://textures/sky/sky512_lf.tex",
	SkyboxRt = "rbxasset://textures/sky/sky512_rt.tex",
	SkyboxUp = "rbxasset://textures/sky/sky512_up.tex",
}
local cachedBaselineBoxCFrame
local cachedBaselineBoxSize

local function clear(viewport, destroyBundle)
	local world = viewport:FindFirstChild("PreviewWorld")
	if world and world:IsA("WorldModel") then
		world:ClearAllChildren()
		if destroyBundle then
			world:Destroy()
		end
	end
	if destroyBundle then
		local camera = viewport:FindFirstChild("PreviewCamera")
		if camera then
			camera:Destroy()
		end
		local sky = viewport:FindFirstChild("PreviewSky")
		if sky and sky:IsA("Sky") and sky:GetAttribute("GooPreviewRuntime") == true then
			sky:Destroy()
		end
		viewport.CurrentCamera = nil
	end
end

local function ensureReflectionSky(viewport)
	-- Respect a cubemap authored directly on the ViewportFrame; only provide a runtime fallback
	-- when the preview has no reflection environment of its own.
	local existing = viewport:FindFirstChildOfClass("Sky")
	if existing then
		return existing
	end

	local source = Lighting:FindFirstChildOfClass("Sky")
	local sky
	if source then
		sky = source:Clone()
	else
		sky = Instance.new("Sky")
		for property, contentId in pairs(DEFAULT_SKYBOX) do
			sky[property] = contentId
		end
	end
	sky.Name = "PreviewSky"
	sky:SetAttribute("GooPreviewRuntime", true)
	sky.Parent = viewport
	return sky
end

local function isViewportEffect(object)
	return object:IsA("ParticleEmitter")
		or object:IsA("Sparkles")
		or object:IsA("Light")
		or object:IsA("Beam")
		or object:IsA("Trail")
		or object:IsA("Fire")
		or object:IsA("Smoke")
end

local function prepare(model, locked, lightweight)
	for _, object in ipairs(model:GetDescendants()) do
		if object:IsA("BasePart") then
			object.Anchored = true
			object.CanCollide = false
			object.CanTouch = false
			object.CanQuery = false
			if locked then
				object.Color = SILHOUETTE
				object.Material = Enum.Material.SmoothPlastic
				object.MaterialVariant = ""
				object.Reflectance = 0
				if object:IsA("MeshPart") then
					object.TextureID = ""
				end
			end
		elseif object:IsA("Decal") or object:IsA("Texture") then
			if locked then
				object.Transparency = 1
			end
		elseif isViewportEffect(object) then
			-- These classes do not render in ViewportFrames. Removing them avoids needless
			-- simulation and keeps preview clones hygienic in every state.
			object:Destroy()
		elseif object:IsA("Script") or object:IsA("LocalScript") then
			object:Destroy()
		end
	end
end

local function getBaseline()
	if cachedBaselineBoxCFrame then
		return cachedBaselineBoxCFrame, cachedBaselineBoxSize
	end
	local source = GooSkinAssets.Resolve(GooSkinConfig.DefaultSkinId)
	if not source then
		return CFrame.new(), Vector3.new(4, 4, 4)
	end
	local clone = source:Clone()
	prepare(clone, false, true)
	clone:PivotTo(CFrame.new())
	local boxCFrame, boxSize = clone:GetBoundingBox()
	clone:Destroy()
	cachedBaselineBoxCFrame = boxCFrame
	cachedBaselineBoxSize = boxSize
	return cachedBaselineBoxCFrame, cachedBaselineBoxSize
end

local function viewportAspect(viewport)
	local absoluteSize = viewport.AbsoluteSize
	if absoluteSize.X > 0 and absoluteSize.Y > 0 then
		return absoluteSize.X / absoluteSize.Y
	end
	local size = viewport.Size
	if size.X.Offset > 0 and size.Y.Offset > 0 then
		return size.X.Offset / size.Y.Offset
	end
	return 1
end

local function fitDistance(boxCFrame, boxSize, direction, verticalHalfAngle, aspect)
	local horizontalHalfAngle = math.atan(math.tan(verticalHalfAngle) * math.max(aspect, 0.01))
	local tanVertical = math.tan(verticalHalfAngle)
	local tanHorizontal = math.tan(horizontalHalfAngle)
	local right = direction:Cross(Vector3.yAxis).Unit
	local up = right:Cross(direction).Unit
	local center = boxCFrame.Position
	local half = boxSize * 0.5
	local distance = 0

	for xSign = -1, 1, 2 do
		for ySign = -1, 1, 2 do
			for zSign = -1, 1, 2 do
				local corner = boxCFrame:PointToWorldSpace(Vector3.new(half.X * xSign, half.Y * ySign, half.Z * zSign))
				local relative = corner - center
				local depth = relative:Dot(direction)
				distance = math.max(
					distance,
					math.abs(relative:Dot(right)) / tanHorizontal - depth,
					math.abs(relative:Dot(up)) / tanVertical - depth
				)
			end
		end
	end

	return math.max(distance, 0.1)
end

function Renderer.Render(viewport, skinId, options)
	if not (viewport and viewport:IsA("ViewportFrame")) then
		return false
	end
	ensureReflectionSky(viewport)
	options = options or {}
	local locked = options.Locked == true
	local lightweight = options.Lightweight == true
	local aspect = viewportAspect(viewport)
	local renderedAspect = tonumber(viewport:GetAttribute("PreviewAspect"))
	if
		viewport:GetAttribute("PreviewSkinId") == skinId
		and viewport:GetAttribute("PreviewLocked") == locked
		and viewport:GetAttribute("PreviewLightweight") == lightweight
		and renderedAspect ~= nil
		and math.abs(renderedAspect - aspect) < 0.001
	then
		return true
	end

	clear(viewport, false)
	local source = GooSkinAssets.Resolve(skinId)
	if not source then
		return false
	end

	local world = viewport:FindFirstChild("PreviewWorld")
	if not (world and world:IsA("WorldModel")) then
		world = Instance.new("WorldModel")
		world.Name = "PreviewWorld"
		world:SetAttribute("GooPreviewRuntime", true)
		world.Parent = viewport
	end
	local model = source:Clone()
	model.Name = "PreviewGoo"
	prepare(model, locked, lightweight)
	local previewScale = tonumber(source:GetAttribute("PreviewScale")) or 1
	if previewScale > 0 and previewScale ~= 1 then
		model:ScaleTo(model:GetScale() * previewScale)
	end
	model.Parent = world
	model:PivotTo(CFrame.new())

	local camera = viewport:FindFirstChild("PreviewCamera")
	if not (camera and camera:IsA("Camera")) then
		camera = Instance.new("Camera")
		camera.Name = "PreviewCamera"
		camera:SetAttribute("GooPreviewRuntime", true)
		camera.Parent = viewport
	end
	camera.FieldOfView = 28
	viewport.CurrentCamera = camera
	viewport.Ambient = Color3.fromRGB(185, 190, 205)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-1, -1, -1)

	local yaw = math.rad(tonumber(source:GetAttribute("PreviewYaw")) or 0)
	local direction = CFrame.Angles(0, yaw, 0).LookVector
	local boxCFrame, boxSize = model:GetBoundingBox()
	local baselineBoxCFrame, baselineBoxSize = getBaseline()
	local halfAngle = math.rad(camera.FieldOfView * 0.5)
	-- Keep the default goo's apparent scale for normal variants, but always back away far enough
	-- to contain the actual model in both axes. Using the live ViewportFrame aspect prevents tall
	-- or narrow compact previews from cropping wide variants such as Titan.
	local baselineDistance = fitDistance(baselineBoxCFrame, baselineBoxSize, direction, halfAngle, aspect)
	local modelDistance = fitDistance(boxCFrame, boxSize, direction, halfAngle, aspect)
	local distance = math.max(4, baselineDistance, modelDistance) * 1.1
	local center = boxCFrame.Position
	camera.CFrame = CFrame.lookAt(center - direction * distance, center)

	viewport:SetAttribute("PreviewSkinId", skinId)
	viewport:SetAttribute("PreviewLocked", locked)
	viewport:SetAttribute("PreviewLightweight", lightweight)
	viewport:SetAttribute("PreviewAspect", aspect)
	return true
end

function Renderer.Clear(viewport)
	if viewport and viewport:IsA("ViewportFrame") then
		clear(viewport, true)
		viewport:SetAttribute("PreviewSkinId", nil)
		viewport:SetAttribute("PreviewLocked", nil)
		viewport:SetAttribute("PreviewLightweight", nil)
		viewport:SetAttribute("PreviewAspect", nil)
	end
end

return Renderer
