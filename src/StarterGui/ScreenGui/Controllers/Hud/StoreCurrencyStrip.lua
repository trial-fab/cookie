-- StoreCurrencyStrip: one parent-frame size tween for StoreBottom's three transparent counts.
-- LiveCounts is anchored on the right and clips its children, so growing its width reveals the
-- authored Cookie/GC/Gem row as one continuous block. All widths remain unscaled logical pixels.

local HapticService = game:GetService("HapticService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local UiMotion = require(ReplicatedStorage.Shared.UiMotion)

local StoreCurrencyStrip = {}

local OPEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local HOLD_SECONDS = 0.5
local HAPTIC_SECONDS = 0.08
local SESSION_LOCK_ATTRIBUTE = "StoreCurrencyStripLockedSession"

local function pulseTouchHaptic()
	local supported = false
	pcall(function()
		supported = HapticService:IsMotorSupported(Enum.UserInputType.Touch, Enum.VibrationMotor.Small)
	end)
	if not supported then
		return
	end
	pcall(function()
		HapticService:SetMotor(Enum.UserInputType.Touch, Enum.VibrationMotor.Small, 1)
	end)
	task.delay(HAPTIC_SECONDS, function()
		pcall(function()
			HapticService:SetMotor(Enum.UserInputType.Touch, Enum.VibrationMotor.Small, 0)
		end)
	end)
end

function StoreCurrencyStrip.new(ctx)
	local player = ctx.player
	local screenGui = ctx.screenGui
	local store = ctx.store
	local root = ctx.root
	local cookie = ctx.cookie
	local golden = ctx.golden
	local gems = ctx.gems
	local bindings
	local hovering = false
	local touchReveal = false
	local rewardActive = false
	local locked = player:GetAttribute(SESSION_LOCK_ATTRIBUTE) == true
	local expanded = locked
	local sizeTween

	root.Active = true
	root.AnchorPoint = Vector2.new(1, 0.5)
	root.ClipsDescendants = true
	for _, pill in ipairs({ cookie, golden, gems }) do
		pill.Active = false
		pill.AnchorPoint = Vector2.new(0, 0.5)
	end

	local function paddingOffsets()
		local padding = root:FindFirstChildOfClass("UIPadding")
		if not padding then
			return 0, 0
		end
		return padding.PaddingLeft.Offset, padding.PaddingRight.Offset
	end

	local function pillWidth(name, pill, useTarget)
		local binding = bindings and bindings[name]
		if useTarget and binding then
			return binding.getTargetWidth()
		end
		return pill.Size.X.Offset
	end

	local function rowWidth(showAll, useTarget)
		local left, right = paddingOffsets()
		local width = left + pillWidth("cookie", cookie, useTarget) + right
		if showAll then
			width += pillWidth("golden", golden, useTarget) + pillWidth("gems", gems, useTarget)
		end
		return math.max(1, math.ceil(width))
	end

	local function layoutChildren()
		local left = paddingOffsets()
		cookie.Position = UDim2.new(0, left, 0.5, 0)
		golden.Position = UDim2.new(0, left + cookie.Size.X.Offset, 0.5, 0)
		gems.Position = UDim2.new(0, left + cookie.Size.X.Offset + golden.Size.X.Offset, 0.5, 0)
	end

	local function shouldExpand()
		return hovering or touchReveal or rewardActive or locked
	end

	local function tweenWidth(width, animate)
		if sizeTween then
			sizeTween:Cancel()
			sizeTween = nil
		end
		local target = UDim2.new(0, width, root.Size.Y.Scale, root.Size.Y.Offset)
		if not animate or UiMotion.isReduced(screenGui) then
			root.Size = target
			golden.Visible = expanded
			gems.Visible = expanded
			return
		end

		if expanded then
			golden.Visible = true
			gems.Visible = true
		end
		local tween = UiMotion.create(root, expanded and OPEN_INFO or CLOSE_INFO, { Size = target })
		sizeTween = tween
		tween.Completed:Connect(function(state)
			if sizeTween ~= tween or state ~= Enum.PlaybackState.Completed then
				return
			end
			sizeTween = nil
			if not expanded then
				golden.Visible = false
				gems.Visible = false
			end
		end)
		tween:Play()
	end

	local function applyLayout(animate)
		local show = shouldExpand()
		if expanded == show then
			layoutChildren()
			return
		end
		expanded = show
		layoutChildren()
		tweenWidth(rowWidth(show, true), animate)
	end

	local function toggleLock()
		locked = not locked
		player:SetAttribute(SESSION_LOCK_ATTRIBUTE, locked)
		applyLayout(true)
	end

	root.MouseEnter:Connect(function()
		if UserInputService.PreferredInput == Enum.PreferredInput.KeyboardAndMouse then
			hovering = true
			applyLayout(true)
		end
	end)
	root.MouseLeave:Connect(function()
		if UserInputService.PreferredInput == Enum.PreferredInput.KeyboardAndMouse then
			hovering = false
			applyLayout(true)
		end
	end)

	local touchInput
	local touchGeneration = 0
	local holdCompleted = false
	root.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			toggleLock()
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Touch or touchInput then
			return
		end
		touchInput = input
		holdCompleted = false
		touchGeneration += 1
		local generation = touchGeneration
		task.delay(HOLD_SECONDS, function()
			if touchInput == input and touchGeneration == generation then
				holdCompleted = true
				toggleLock()
				pulseTouchHaptic()
			end
		end)
	end)
	root.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch or touchInput ~= input then
			return
		end
		local wasHold = holdCompleted
		touchGeneration += 1
		touchInput = nil
		holdCompleted = false
		if not wasHold then
			touchReveal = not touchReveal
			applyLayout(true)
		end
	end)

	cookie:GetPropertyChangedSignal("Size"):Connect(layoutChildren)
	golden:GetPropertyChangedSignal("Size"):Connect(layoutChildren)
	gems:GetPropertyChangedSignal("Size"):Connect(layoutChildren)

	layoutChildren()
	root.Size = UDim2.new(0, rowWidth(expanded, false), root.Size.Y.Scale, root.Size.Y.Offset)
	golden.Visible = expanded
	gems.Visible = expanded

	return {
		setBindings = function(nextBindings)
			bindings = nextBindings
			layoutChildren()
			root.Size = UDim2.new(0, rowWidth(expanded, true), root.Size.Y.Scale, root.Size.Y.Offset)
		end,
		refreshWidths = function(immediate)
			layoutChildren()
			tweenWidth(rowWidth(expanded, true), not immediate)
		end,
		setRewardActive = function(active)
			rewardActive = active == true
			applyLayout(true)
		end,
		isExpanded = function()
			return expanded
		end,
		isStoreVisible = function()
			local storeOpen = screenGui:GetAttribute(Attrs.StoreOpen) == true
			local buildOpen = screenGui:GetAttribute(Attrs.BuildModeActive) == true
				and screenGui:GetAttribute(Attrs.AutoBuildMode) == true
			return store.Visible
				and (storeOpen or buildOpen)
				and screenGui:GetAttribute(Attrs.PlacementActive) ~= true
				and screenGui:GetAttribute(Attrs.BackgroundSurfacesSuspended) ~= true
		end,
	}
end

return StoreCurrencyStrip
