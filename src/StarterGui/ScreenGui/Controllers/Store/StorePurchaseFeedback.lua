-- StorePurchaseFeedback: positions and fades the Studio-authored blocked-purchase text.
-- The label lives inside StoreBottom and stays horizontally centered on the viewport.
-- It ends 4px above PageTemplate unless that placement overlaps a top-row control;
-- in that case it moves vertically above the colliding control(s).

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local GuiNames = require(ReplicatedStorage.Shared.GuiNames)
local UiMotion = require(ReplicatedStorage.Shared.UiMotion)

local StorePurchaseFeedback = {}

local HOLD_SECONDS = 1.1
local FADE_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EDGE_GAP_PX = 4
local TEXT_HORIZONTAL_PADDING_PX = 12

local function renderedWidth(instance, scale)
	local width = instance.AbsoluteSize.X
	if width > 0 then
		return width
	end
	return math.max(0, instance.Size.X.Offset * scale)
end

function StorePurchaseFeedback.new(ctx)
	local store = ctx.store
	local label = store and store:FindFirstChild(GuiNames.StorePurchaseFeedback)
	if label and not label:IsA("TextLabel") then
		label = nil
	end
	if not label then
		warn("Store affordability feedback disabled: StoreBottom.StorePurchaseFeedback TextLabel is missing")
	end

	local tabBar = store and store:FindFirstChild("TabBar")
	local liveCounts = store and store:FindFirstChild("LiveCounts")
	local robuxSubTabs = store and store:FindFirstChild("RobuxSubTabs")
	local upgradeSubTabs =
		store and (store:FindFirstChild("UpgradeSubTabs") or store:FindFirstChild("UpgradesSubTabs"))
	local pageContainer = ctx.pageContainer
	local count = 0
	local baseText
	local generation = 0
	local fadeTween

	local function storeScale()
		local scale = ctx.storeScale and ctx.storeScale.Scale or 1
		return math.max(0.01, scale)
	end

	local function place()
		if
			not label
			or not label.Parent
			or not (store and store:IsA("GuiObject"))
			or not (pageContainer and pageContainer:IsA("GuiObject"))
		then
			return
		end

		local scale = storeScale()
		local storePosition = store.AbsolutePosition
		local storeSize = store.AbsoluteSize
		local camera = workspace.CurrentCamera
		local viewportWidth = camera and camera.ViewportSize.X or 0
		local targetX = storePosition.X + storeSize.X / 2
		if viewportWidth > 0 then
			targetX = viewportWidth / 2
		end
		local targetBottomY = pageContainer.AbsolutePosition.Y - EDGE_GAP_PX
		local labelWidth = renderedWidth(label, scale)
		local labelHeight = label.AbsoluteSize.Y
		if labelHeight <= 0 then
			labelHeight = math.max(0, label.Size.Y.Offset * scale)
		end
		local labelLeft = targetX - labelWidth / 2
		local labelRight = targetX + labelWidth / 2
		local labelTop = targetBottomY - labelHeight
		local collidingTopY

		local function includeCollision(control)
			if not (control and control:IsA("GuiObject") and control.Visible) then
				return
			end
			local width = renderedWidth(control, scale)
			local height = control.AbsoluteSize.Y
			if height <= 0 then
				height = math.max(0, control.Size.Y.Offset * scale)
			end
			if width <= 0 or height <= 0 then
				return
			end

			local controlPosition = control.AbsolutePosition
			local horizontalOverlap = labelLeft < controlPosition.X + width and labelRight > controlPosition.X
			local verticalOverlap = labelTop < controlPosition.Y + height and targetBottomY > controlPosition.Y
			if horizontalOverlap and verticalOverlap then
				collidingTopY = math.min(collidingTopY or controlPosition.Y, controlPosition.Y)
			end
		end

		includeCollision(tabBar)
		includeCollision(robuxSubTabs)
		includeCollision(upgradeSubTabs)
		includeCollision(liveCounts)
		if collidingTopY then
			targetBottomY = collidingTopY - EDGE_GAP_PX
		end

		-- Position offsets are local, unscaled StoreBottom coordinates. The target
		-- geometry above is rendered screen space so tweened widths and UIScale are exact.
		label.Position = UDim2.fromOffset(
			math.floor((targetX - storePosition.X) / scale + 0.5),
			math.floor((targetBottomY - storePosition.Y) / scale + 0.5)
		)
	end

	local function show(message)
		if not label or not label.Parent then
			return
		end
		message = tostring(message or "")
		if message == "" then
			return
		end

		generation += 1
		if baseText ~= message then
			baseText = message
			count = 0
		end
		count += 1
		if fadeTween then
			fadeTween:Cancel()
			fadeTween = nil
		end

		local displayText = baseText .. (if count == 1 then "" else (" x%d"):format(count))
		label.Text = displayText
		-- Match the store's existing synchronous text-measurement pattern so the
		-- collision box reflects this exact message before it is positioned.
		local textWidth = TextService:GetTextSize(
			displayText,
			label.TextSize,
			label.Font,
			Vector2.new(10000, 10000)
		).X
		label.Size = UDim2.new(
			0,
			math.ceil(textWidth + TEXT_HORIZONTAL_PADDING_PX * 2),
			label.Size.Y.Scale,
			label.Size.Y.Offset
		)
		label.TextTransparency = 0
		label.Visible = true
		place()

		local showGeneration = generation
		task.delay(HOLD_SECONDS, function()
			if showGeneration ~= generation or not label.Parent then
				return
			end

			local fade = UiMotion.create(label, FADE_TWEEN, { TextTransparency = 1 })
			fadeTween = fade
			fade.Completed:Once(function(playbackState)
				if showGeneration ~= generation or fadeTween ~= fade then
					return
				end
				fadeTween = nil
				if playbackState == Enum.PlaybackState.Completed then
					label.Visible = false
					count = 0
					baseText = nil
				end
			end)
			fade:Play()
		end)
	end

	if label then
		label.Visible = false
		label.TextTransparency = 1
		place()
		-- Subtabs and LiveCounts both tween their widths. Re-evaluating only while the
		-- message is visible follows every intermediate frame without permanent layout work.
		RunService.RenderStepped:Connect(function()
			if label.Visible then
				place()
			end
		end)
	end

	return {
		show = show,
	}
end

return StorePurchaseFeedback
