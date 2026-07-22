-- Animates Studio-authored dizzy stars on a flat world-space orbit above goo mascots.
-- MascotService owns whether the BillboardGuis are enabled; this controller owns motion only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local tuning = require(Shared:WaitForChild("DizzyStarsConfig"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui or screenGui:GetAttribute("DizzyStarsControllerRunning") == true then
	return
end
screenGui:SetAttribute("DizzyStarsControllerRunning", true)

local MAX_STARS = 3
local MAX_TRAILS = 3
local TAU = math.pi * 2
local tracked = {}

local function getIcon(billboard)
	local icon = billboard:FindFirstChild("Icon")
	return if icon and icon:IsA("ImageLabel") then icon else nil
end

local function register(root)
	if tracked[root]
		or not root:IsA("Folder")
		or root.Name ~= "DizzyStars"
		or root:GetAttribute("DizzyStars") ~= true
	then
		return
	end

	local stars = {}
	local trails = {}
	for starIndex = 1, MAX_STARS do
		local billboard = root:FindFirstChild("Star" .. starIndex)
		local icon = billboard and billboard:IsA("BillboardGui") and getIcon(billboard)
		if not icon then
			return
		end
		stars[starIndex] = { billboard = billboard, icon = icon }
		trails[starIndex] = {}
		for trailIndex = 1, MAX_TRAILS do
			local trailBillboard = root:FindFirstChild(("Star%dTrail%d"):format(starIndex, trailIndex))
			local trailIcon = trailBillboard
				and trailBillboard:IsA("BillboardGui")
				and getIcon(trailBillboard)
			if not trailIcon then
				return
			end
			trails[starIndex][trailIndex] = { billboard = trailBillboard, icon = trailIcon }
		end
	end

	tracked[root] = {
		stars = stars,
		trails = trails,
		heightOffsetDelta = if typeof(root:GetAttribute("HeightOffsetDeltaStuds")) == "number"
			then root:GetAttribute("HeightOffsetDeltaStuds")
			else 0,
	}
end

local function registerFromDescendant(descendant)
	local root = descendant
	if root.Name ~= "DizzyStars" then
		root = descendant:FindFirstAncestor("DizzyStars")
	end
	if root then
		register(root)
	end
end

local function setPresentation(item, angle, heightOffsetDelta, size, transparency, color, rotation)
	item.billboard.Size = UDim2.fromScale(size, size)
	item.billboard.StudsOffsetWorldSpace = Vector3.new(
		tuning.OffsetXStuds + math.cos(angle) * tuning.RadiusXStuds,
		tuning.HeightOffsetStuds + heightOffsetDelta,
		tuning.OffsetZStuds + math.sin(angle) * tuning.RadiusZStuds
	)
	item.icon.ImageColor3 = color
	item.icon.ImageTransparency = transparency
	item.icon.Rotation = rotation
	item.icon.Visible = true
end

local function hideStar(state, starIndex)
	state.stars[starIndex].icon.Visible = false
	for _, trail in ipairs(state.trails[starIndex]) do
		trail.icon.Visible = false
	end
end

local function updateStatic(state)
	local starCount = math.clamp(math.round(tuning.StarCount), 1, MAX_STARS)
	for starIndex, star in ipairs(state.stars) do
		if starIndex > starCount then
			hideStar(state, starIndex)
			continue
		end
		local angle = ((starIndex - 1) / starCount) * TAU
		setPresentation(star, angle, state.heightOffsetDelta, tuning.StarSizeStuds, 0, tuning.StarColor, 0)
		for _, trail in ipairs(state.trails[starIndex]) do
			trail.icon.Visible = false
		end
	end
end

local function updateAnimated(state, elapsed)
	local starCount = math.clamp(math.round(tuning.StarCount), 1, MAX_STARS)
	local trailCount = math.clamp(math.round(tuning.TrailCount), 0, MAX_TRAILS)
	local orbitDirection = if tuning.Clockwise then 1 else -1
	local orbitAngle = elapsed * TAU / math.max(0.1, tuning.RevolutionSeconds) * orbitDirection
	local trailLag = math.rad(tuning.TrailLagDegrees) * orbitDirection

	for starIndex, star in ipairs(state.stars) do
		if starIndex > starCount then
			hideStar(state, starIndex)
			continue
		end

		local phase = ((starIndex - 1) / starCount) * TAU
		local angle = orbitAngle + phase
		local rotation = (elapsed * tuning.SpinDegreesPerSecond + (starIndex - 1) * 35) % 360
		setPresentation(
			star,
			angle,
			state.heightOffsetDelta,
			tuning.StarSizeStuds,
			0,
			tuning.StarColor,
			rotation
		)

		for trailIndex, trail in ipairs(state.trails[starIndex]) do
			if trailIndex > trailCount then
				trail.icon.Visible = false
				continue
			end
			local trailAngle = angle - trailLag * trailIndex
			local trailFalloff = tuning.TrailScaleFalloff ^ (trailIndex - 1)
			setPresentation(
				trail,
				trailAngle,
				state.heightOffsetDelta,
				tuning.StarSizeStuds * tuning.TrailScale * trailFalloff,
				math.clamp(
					tuning.TrailTransparency + (trailIndex - 1) * tuning.TrailFadePerGhost,
					0,
					1
				),
				tuning.TrailColor,
				rotation - 12 * trailIndex * orbitDirection
			)
		end
	end
end

for _, descendant in ipairs(Workspace:GetDescendants()) do
	registerFromDescendant(descendant)
end
Workspace.DescendantAdded:Connect(registerFromDescendant)

RunService.RenderStepped:Connect(function()
	local elapsed = os.clock()
	local reducedMotion = screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
	for root, state in pairs(tracked) do
		if not root:IsDescendantOf(Workspace) then
			tracked[root] = nil
		elseif state.stars[1].billboard.Enabled then
			if reducedMotion then
				updateStatic(state)
			else
				updateAnimated(state, elapsed)
			end
		end
	end
end)
