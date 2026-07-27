-- WorldTrackedLabels — screen-space labels that sit at a world part's projected screen point and
-- never grow past their authored size (they only shrink with distance), staying crisp on mobile.
--
-- Same technique the touch building-stats tooltip uses (StoreBuildingTooltipPresenter): every
-- frame we project the tracked world point with Camera:WorldToViewportPoint, drive a `WorldScale`
-- UIScale with clamp(RefDistance / distance, MinScale, MaxScale), then position from the frame's
-- actual scaled bounds. A final AbsolutePosition correction accounts for DeviceSafeInsets and
-- other screen-space transforms, keeping the label's visual center pinned to the projected point.
--
-- Opt in from Studio: tag a Frame "WorldTrackedLabel" with a `WorldScale` UIScale, an `Anchor`
-- ObjectValue -> the world BasePart to follow, and either plain number attributes
-- (WorldOffsetY / ScreenOffsetX / Gap / MaxDistance / RefDistance / MinScale / MaxScale), boolean
-- attributes AllowOffscreen / OcclusionEnabled. Boost-shop labels use `TuningFeature` +
-- `TuningKey` as selectors for their baked BoostShopPresentationConfig values.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BoostShopPresentationConfig =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BoostShopPresentationConfig"))

local TAG = "WorldTrackedLabel"
local DEFAULTS = {
	WorldOffsetY = 3,
	ScreenOffsetX = 0,
	Gap = 0,
	MaxDistance = math.huge,
	AllowOffscreen = false,
	OcclusionEnabled = true,
	RefDistance = 40,
	MinScale = 0.25,
	MaxScale = 1,
}

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local labels = {} -- frame -> { scale, anchorValue, screenGui, config = {}|nil }

local function bindConfig(info, frame)
	local feature = frame:GetAttribute("TuningFeature")
	local key = frame:GetAttribute("TuningKey")
	if feature ~= "BoostShopLabels" or type(key) ~= "string" then
		return
	end
	info.config = BoostShopPresentationConfig.Labels[key]
end

local function track(frame)
	-- Only drive the live PlayerGui copies; ignore the StarterGui template copies.
	if not (frame:IsA("GuiObject") and frame:IsDescendantOf(playerGui)) then
		return
	end
	local info = {
		scale = frame:FindFirstChild("WorldScale"),
		anchorValue = frame:FindFirstChild("Anchor"),
		screenGui = frame:FindFirstAncestorWhichIsA("ScreenGui"),
	}
	bindConfig(info, frame)
	labels[frame] = info
	frame.AnchorPoint = Vector2.zero
	frame.Visible = false
end

local function untrack(frame)
	labels[frame] = nil
end

for _, frame in ipairs(CollectionService:GetTagged(TAG)) do
	track(frame)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)

local function value(frame, info, field)
	if info.config and info.config[field] ~= nil then
		return info.config[field]
	end
	if info.config and BoostShopPresentationConfig.Scale[field] ~= nil then
		return BoostShopPresentationConfig.Scale[field]
	end
	local attribute = frame:GetAttribute(field)
	if attribute ~= nil then
		if type(DEFAULTS[field]) == "number" then
			attribute = tonumber(attribute)
		end
	end
	if attribute ~= nil then
		return attribute
	end
	return DEFAULTS[field]
end

local castPoints = table.create(1)
local occlusionIgnoreList = table.create(1)

local function isOccluded(camera, worldPoint)
	castPoints[1] = worldPoint
	local character = Players.LocalPlayer.Character
	if character then
		occlusionIgnoreList[1] = character
	else
		table.clear(occlusionIgnoreList)
	end

	for _, part in ipairs(camera:GetPartsObscuringTarget(castPoints, occlusionIgnoreList)) do
		-- Invisible query/helper parts should not hide a label that is visibly unobstructed.
		if part.Transparency < 0.95 then
			return true
		end
	end
	return false
end

-- GetPartsObscuringTarget is a spatial query and is by far the most expensive thing in the
-- per-frame loop below, so it runs on its own cadence and the last answer is reused in between.
-- The cache lives on the label's `info` table, so untrack() disposes of it with the label.
-- ~12Hz is imperceptible here: a label crossing behind geometry is already fading rather than
-- cutting, and every cheaper visibility test (distance, viewport, Z) still runs every frame.
local OCCLUSION_INTERVAL_SECONDS = 1 / 12

local function isOccludedThrottled(info, camera, worldPoint, now)
	if info.occludedCheckedAt and now - info.occludedCheckedAt < OCCLUSION_INTERVAL_SECONDS then
		return info.occluded
	end
	info.occludedCheckedAt = now
	info.occluded = isOccluded(camera, worldPoint)
	return info.occluded
end

RunService.RenderStepped:Connect(function()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local camPos = camera.CFrame.Position
	local viewport = camera.ViewportSize
	local now = os.clock()
	for frame, info in pairs(labels) do
		local anchor = info.anchorValue and info.anchorValue.Value
		if not (anchor and anchor:IsA("BasePart") and frame.Parent) then
			frame.Visible = false
		else
			local distance = math.max(1, (camPos - anchor.Position).Magnitude)
			local worldPoint = anchor.Position + Vector3.new(0, value(frame, info, "WorldOffsetY"), 0)
			local ignoreInset = info.screenGui and info.screenGui.IgnoreGuiInset
			local screenPoint = ignoreInset and camera:WorldToScreenPoint(worldPoint)
				or camera:WorldToViewportPoint(worldPoint)
			local withinViewport = screenPoint.X >= 0
				and screenPoint.X <= viewport.X
				and screenPoint.Y >= 0
				and screenPoint.Y <= viewport.Y
			local allowOffscreen = value(frame, info, "AllowOffscreen") == true
			local visible = screenPoint.Z > 0
				and distance <= value(frame, info, "MaxDistance")
				and (allowOffscreen or withinViewport)
				and (
					value(frame, info, "OcclusionEnabled") ~= true
					or not isOccludedThrottled(info, camera, worldPoint, now)
				)
			if not visible then
				frame.Visible = false
			else
				local scale = math.clamp(
					value(frame, info, "RefDistance") / distance,
					value(frame, info, "MinScale"),
					value(frame, info, "MaxScale")
				)
				if info.scale and info.scale:IsA("UIScale") then
					info.scale.Scale = scale
				end
				local gap = value(frame, info, "Gap")
				local desiredCenter =
					Vector2.new(screenPoint.X + value(frame, info, "ScreenOffsetX"), screenPoint.Y - gap)
				local desiredPosition = desiredCenter - frame.AbsoluteSize / 2
				desiredPosition = Vector2.new(math.round(desiredPosition.X), math.round(desiredPosition.Y))
				frame.Position = UDim2.fromOffset(desiredPosition.X, desiredPosition.Y)

				-- Position offsets can be transformed by DeviceSafeInsets or an ancestor GuiObject.
				-- Correct from the rendered top-left so distance-driven UIScale changes cannot move
				-- the visual center away from the projected world point.
				local correction = desiredPosition - frame.AbsolutePosition
				if correction.Magnitude >= 0.5 then
					frame.Position = UDim2.fromOffset(
						desiredPosition.X + math.round(correction.X),
						desiredPosition.Y + math.round(correction.Y)
					)
				end
				frame.Visible = true
			end
		end
	end
end)
