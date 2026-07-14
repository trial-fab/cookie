-- Static ViewportFrame renderer for wheel/collection goo previews. Models come from the
-- same ReplicatedStorage.GooSkinAssets library used by StoryService.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GooSkinConfig = require(ReplicatedStorage.Shared.GooSkinConfig)
local GooSkinAssets = require(ReplicatedStorage.Shared.GooSkinAssets)

local Renderer = {}
local SILHOUETTE = Color3.fromRGB(18, 20, 28)
local cachedBaselineCenter
local cachedBaselineRadius

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
		viewport.CurrentCamera = nil
	end
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
	if cachedBaselineCenter then
		return cachedBaselineCenter, cachedBaselineRadius
	end
	local source = GooSkinAssets.Resolve(GooSkinConfig.DefaultSkinId)
	if not source then
		return Vector3.zero, 2
	end
	local clone = source:Clone()
	prepare(clone, false, true)
	clone:PivotTo(CFrame.new())
	local boxCFrame, boxSize = clone:GetBoundingBox()
	clone:Destroy()
	cachedBaselineCenter = boxCFrame.Position
	cachedBaselineRadius = math.max(boxSize.X, boxSize.Y, boxSize.Z) * 0.5
	return cachedBaselineCenter, cachedBaselineRadius
end

function Renderer.Render(viewport, skinId, options)
	if not (viewport and viewport:IsA("ViewportFrame")) then
		return false
	end
	options = options or {}
	local locked = options.Locked == true
	local lightweight = options.Lightweight == true
	if
		viewport:GetAttribute("PreviewSkinId") == skinId
		and viewport:GetAttribute("PreviewLocked") == locked
		and viewport:GetAttribute("PreviewLightweight") == lightweight
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

	local baselineCenter, baselineRadius = getBaseline()
	local _, boxSize = model:GetBoundingBox()
	local radius = math.max(boxSize.X, boxSize.Y, boxSize.Z) * 0.5
	local halfAngle = math.rad(camera.FieldOfView * 0.5)
	local baselineDistance = math.max(4, baselineRadius / math.tan(halfAngle) * 1.15)
	-- Keep the Classic Blue camera for normal variants so relative size remains visible.
	-- Only back away when a future morph exceeds the baseline envelope by >35%, preventing
	-- catastrophic clipping without normalizing every model to the same apparent size.
	local safetyDistance = radius / 1.35 / math.tan(halfAngle) * 1.15
	local distance = math.max(baselineDistance, safetyDistance)
	local yaw = math.rad(tonumber(source:GetAttribute("PreviewYaw")) or 0)
	local direction = CFrame.Angles(0, yaw, 0).LookVector
	local center = baselineCenter
	camera.CFrame = CFrame.lookAt(center - direction * distance, center)

	viewport:SetAttribute("PreviewSkinId", skinId)
	viewport:SetAttribute("PreviewLocked", locked)
	viewport:SetAttribute("PreviewLightweight", lightweight)
	return true
end

function Renderer.Clear(viewport)
	if viewport and viewport:IsA("ViewportFrame") then
		clear(viewport, true)
		viewport:SetAttribute("PreviewSkinId", nil)
		viewport:SetAttribute("PreviewLocked", nil)
		viewport:SetAttribute("PreviewLightweight", nil)
	end
end

return Renderer
