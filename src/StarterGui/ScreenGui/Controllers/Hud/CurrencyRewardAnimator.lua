-- CurrencyRewardAnimator: source pop, live-target curved flight, ghost trail, landing pulse,
-- and destination-only +N. The final target is sampled every frame so root UIScale and
-- orientation changes cannot strand a tween at stale screen coordinates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local NumberFormat = require(ReplicatedStorage.Shared.NumberFormat)
local UiMotion = require(ReplicatedStorage.Shared.UiMotion)

local CurrencyRewardAnimator = {}

local function centerOf(object)
	if not (object and object:IsA("GuiObject") and object.Parent and object.AbsoluteSize.Magnitude > 0) then
		return nil
	end
	return object.AbsolutePosition + object.AbsoluteSize / 2
end

local function setIconFrom(icon, source)
	if not (icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton"))) then
		return
	end
	if source and (source:IsA("ImageLabel") or source:IsA("ImageButton")) then
		icon.Image = source.Image
		icon.ImageColor3 = source.ImageColor3
		icon.ImageRectOffset = source.ImageRectOffset
		icon.ImageRectSize = source.ImageRectSize
		icon.ScaleType = source.ScaleType
	end
end

local function setGhostTransparency(root, transparency)
	root.BackgroundTransparency = 1
	local label = root:FindFirstChild("Label", true)
	if label and label:IsA("GuiObject") then
		label.Visible = false
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			descendant.ImageTransparency = transparency
		elseif descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			descendant.Visible = false
		elseif descendant:IsA("GuiObject") then
			descendant.BackgroundTransparency = 1
		end
	end
end

local function easeInQuad(alpha)
	return alpha * alpha
end

local function bezier(startPoint, waypoint, destination, alpha)
	local oneMinus = 1 - alpha
	return oneMinus * oneMinus * startPoint + 2 * oneMinus * alpha * waypoint + alpha * alpha * destination
end

function CurrencyRewardAnimator.new(ctx)
	local screenGui = ctx.screenGui
	local overlay = ctx.overlay
	local template = ctx.template
	local getTuning = ctx.getTuning

	overlay.Visible = true
	template.Visible = false

	local function toOverlayPoint(screenPoint)
		return screenPoint - overlay.AbsolutePosition
	end

	local function resolveSource(anchor)
		local viewport = overlay.AbsoluteSize
		if
			type(anchor) == "table"
			and anchor.Kind == "WorldBounds"
			and typeof(anchor.CFrame) == "CFrame"
			and typeof(anchor.Size) == "Vector3"
		then
			local camera = Workspace.CurrentCamera
			if camera then
				local center = camera:WorldToViewportPoint(anchor.CFrame.Position)
				local minimumY = math.huge
				local hasPointInFront = false
				local half = anchor.Size / 2
				for x = -1, 1, 2 do
					for y = -1, 1, 2 do
						for z = -1, 1, 2 do
							local corner =
								anchor.CFrame:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
							local projected = camera:WorldToViewportPoint(corner)
							if projected.Z > 0 then
								hasPointInFront = true
								minimumY = math.min(minimumY, projected.Y)
							end
						end
					end
				end
				if hasPointInFront and center.Z > 0 then
					return toOverlayPoint(Vector2.new(center.X, minimumY))
				end
			end
		elseif type(anchor) == "table" and anchor.Kind == "World" and typeof(anchor.Position) == "Vector3" then
			local camera = Workspace.CurrentCamera
			if camera then
				local projected, visible = camera:WorldToViewportPoint(anchor.Position)
				local point = Vector2.new(projected.X, projected.Y)
				if visible and projected.Z > 0 then
					return toOverlayPoint(point)
				end
				return Vector2.new(
					math.clamp(point.X, 24, math.max(24, viewport.X - 24)),
					math.clamp(point.Y, 24, math.max(24, viewport.Y - 24))
				)
			end
		elseif type(anchor) == "table" and anchor.Kind == "Ui" then
			local source = ctx.resolveUiSource(anchor.Key)
			local point = centerOf(source)
			if point then
				return toOverlayPoint(point)
			end
		end
		return viewport / 2
	end

	local function cloneFlightVisual(iconSource, ghostTransparency)
		local visual = template:Clone()
		visual.Name = ghostTransparency and "CurrencyGhost" or "CurrencyFlight"
		visual.AnchorPoint = Vector2.new(0.5, 0.5)
		visual.BackgroundTransparency = 1
		visual.Visible = true
		visual.ZIndex = overlay.ZIndex + 2
		for _, descendant in ipairs(visual:GetDescendants()) do
			if descendant:IsA("GuiObject") then
				descendant.ZIndex = visual.ZIndex + 1
			end
		end
		local icon = visual:FindFirstChild("Icon", true)
		setIconFrom(icon, iconSource)
		local label = visual:FindFirstChild("Label", true)
		if label and label:IsA("GuiObject") then
			label.Visible = false
		end
		if ghostTransparency then
			setGhostTransparency(visual, ghostTransparency)
		end
		visual.Parent = overlay
		return visual
	end

	local function pulseDestination(destination)
		local scale = destination and destination:FindFirstChild("LandingScale")
		if not (scale and scale:IsA("UIScale")) then
			return
		end
		local duration = getTuning("LandingPulseSeconds")
		local half = duration / 2
		scale.Scale = 1
		local up = UiMotion.create(
			scale,
			TweenInfo.new(half, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = getTuning("LandingPulseScale") }
		)
		up:Play()
		up.Completed:Wait()
		local down =
			UiMotion.create(scale, TweenInfo.new(half, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 })
		down:Play()
	end

	local function showLandingAmount(visual, item, destinationPoint, amountColor)
		local icon = visual:FindFirstChild("Icon", true)
		if icon and icon:IsA("GuiObject") then
			icon.Visible = false
		end
		local label = visual:FindFirstChild("Label", true)
		if not (label and label:IsA("TextLabel")) then
			visual:Destroy()
			return
		end
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Text = "+" .. NumberFormat.abbreviate(item.amount)
		if amountColor then
			label.TextColor3 = amountColor
		end
		label.TextTransparency = 0
		label.Visible = true
		visual.Position = UDim2.fromOffset(destinationPoint.X, destinationPoint.Y - 24)
		task.wait(getTuning("LandingLabelHoldSeconds"))
		local fadeSeconds = getTuning("LandingLabelFadeSeconds")
		local fadeInfo = TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		UiMotion.create(label, fadeInfo, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
		for _, descendant in ipairs(label:GetDescendants()) do
			if descendant:IsA("UIStroke") then
				UiMotion.create(descendant, fadeInfo, { Transparency = 1 }):Play()
			end
		end
		local rise =
			UiMotion.create(visual, fadeInfo, {
				Position = visual.Position - UDim2.fromOffset(0, 18),
			})
		rise:Play()
		rise.Completed:Wait()
		visual:Destroy()
	end

	local function play(item)
		local preparationStarted = os.clock()
		local preparedDestination = ctx.prepareDestination(item.currency)
		local iconSource = ctx.getIconSource(item.currency) or preparedDestination
		local sourcePoint = resolveSource(item.sourceAnchor)
		local flightStartPoint = sourcePoint
		local visual = cloneFlightVisual(iconSource)
		local baseSize = visual.Size
		visual.Position = UDim2.fromOffset(sourcePoint.X, sourcePoint.Y)
		local reduced = UiMotion.isReduced(screenGui)
		if not reduced then
			visual.Size = UDim2.new(
				baseSize.X.Scale * 0.75,
				math.floor(baseSize.X.Offset * 0.75),
				baseSize.Y.Scale * 0.75,
				math.floor(baseSize.Y.Offset * 0.75)
			)
			flightStartPoint = sourcePoint - Vector2.new(0, getTuning("SourceRisePixels"))
			local rise = UiMotion.create(
				visual,
				TweenInfo.new(getTuning("SourceRiseSeconds"), Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
				{
					Position = UDim2.fromOffset(flightStartPoint.X, flightStartPoint.Y),
					Size = baseSize,
				}
			)
			rise:Play()
			rise.Completed:Wait()
			task.wait(getTuning("SourcePauseSeconds"))
		end
		-- Destination reveal begins before the source icon is created. If tuning makes the
		-- rise shorter than the StoreBottom reveal, hold at the top only for the remainder.
		local revealRemaining = getTuning("StoreRevealSeconds") - (os.clock() - preparationStarted)
		if revealRemaining > 0 then
			task.wait(revealRemaining)
		end

		local destination = ctx.resolveDestination(item.currency)
		local destinationPoint = centerOf(destination)
		if destinationPoint then
			destinationPoint = toOverlayPoint(destinationPoint)
		end

		if not reduced and destinationPoint then
			local ghostCount = math.max(0, math.floor(getTuning("GhostCount")))
			local ghosts = {}
			for index = 1, ghostCount do
				local ghost = cloneFlightVisual(iconSource, math.clamp(0.45 + index * 0.12, 0, 0.92))
				ghost.Position = visual.Position
				table.insert(ghosts, ghost)
			end

			local started = os.clock()
			local duration = math.max(0.05, getTuning("FlightSeconds"))
			local ghostDelay = getTuning("GhostDelaySeconds")
			while visual.Parent do
				local elapsed = os.clock() - started
				local alpha = math.clamp(elapsed / duration, 0, 1)
				local liveDestination = ctx.resolveDestination(item.currency)
				local livePoint = centerOf(liveDestination)
				if livePoint then
					destination = liveDestination
					destinationPoint = toOverlayPoint(livePoint)
				end
				local waypoint = flightStartPoint:Lerp(destinationPoint, getTuning("WaypointProgress"))
					+ Vector2.new(0, -overlay.AbsoluteSize.Y * getTuning("WaypointHeightScale"))
				local eased = easeInQuad(alpha)
				local point = bezier(flightStartPoint, waypoint, destinationPoint, eased)
				visual.Position = UDim2.fromOffset(point.X, point.Y)
				for index, ghost in ipairs(ghosts) do
					local ghostAlpha = math.clamp((elapsed - index * ghostDelay) / duration, 0, 1)
					local ghostPoint = bezier(flightStartPoint, waypoint, destinationPoint, easeInQuad(ghostAlpha))
					ghost.Position = UDim2.fromOffset(ghostPoint.X, ghostPoint.Y)
				end
				if alpha >= 1 then
					break
				end
				RunService.RenderStepped:Wait()
			end
			for _, ghost in ipairs(ghosts) do
				ghost:Destroy()
			end
		end

		-- Resolve once more at impact. If every destination disappeared, the source point is the
		-- fallback landing location and the authoritative count still reconciles immediately.
		destination = ctx.resolveDestination(item.currency)
		local finalScreenPoint = centerOf(destination)
		if finalScreenPoint then
			destinationPoint = toOverlayPoint(finalScreenPoint)
		else
			destinationPoint = flightStartPoint
		end
		visual.Position = UDim2.fromOffset(destinationPoint.X, destinationPoint.Y)
		local icon = visual:FindFirstChild("Icon", true)
		if icon and icon:IsA("GuiObject") then
			UiMotion.create(icon, TweenInfo.new(0.1), { ImageTransparency = 1 }):Play()
		end
		if destination then
			task.spawn(pulseDestination, destination)
		end
		-- onArrival performs the first tick synchronously and schedules the remainder, so the
		-- visible number begins changing on the exact frame the +N label is revealed below.
		ctx.onArrival(item, getTuning("CountUpSeconds"))

		local amountColor
		if destination and destination.Parent then
			local amount = destination.Parent:FindFirstChild("Amount", true)
			if amount and (amount:IsA("TextLabel") or amount:IsA("TextButton")) then
				amountColor = amount.TextColor3
			end
		end
		showLandingAmount(visual, item, destinationPoint, amountColor)
	end

	return { play = play }
end

return CurrencyRewardAnimator
