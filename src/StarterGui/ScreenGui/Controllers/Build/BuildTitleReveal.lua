-- BuildTitleReveal: owns the "Build" title (StoreBottom.TopBar.BuildTitle) reveal/hide. Split
-- out of the old BuildToggleAnimator when the store band was decoupled from build mode -- the
-- title is a build-mode header, so it follows BuildModeActive, not the store cookie.
--
-- ctx: { screenGui, store }. Self-wires to the BuildModeActive attribute and only BINDS to the
-- Studio-authored BuildTitle (never builds it); degrades gracefully when it's absent.
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Attrs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Attrs"))

local BuildTitleReveal = {}

function BuildTitleReveal.new(ctx)
	local screenGui = ctx.screenGui
	local store = ctx.store

	local topBar = store and store:FindFirstChild("TopBar")
	local buildTitle = (topBar and topBar:FindFirstChild("BuildTitle"))
		or (store and store:FindFirstChild("BuildTitle"))
	if buildTitle and not buildTitle:IsA("GuiObject") then
		buildTitle = nil
	end
	if not buildTitle then
		return {}
	end

	local BUILD_TITLE_REVEAL_DELAY = 0.1
	local BUILD_TITLE_REVEAL_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local BUILD_TITLE_HIDE_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Sine, Enum.EasingDirection.In)

	local baseSize = buildTitle.Size
	local basePosition = buildTitle.Position
	local tweens = {}
	local transparencyTargets = {}
	local token = 0

	for _, object in ipairs(buildTitle:GetDescendants()) do
		if object:IsA("GuiObject") then
			table.insert(transparencyTargets, {
				object = object,
				background = object.BackgroundTransparency,
				text = (object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox"))
					and object.TextTransparency
					or nil,
				image = (object:IsA("ImageLabel") or object:IsA("ImageButton")) and object.ImageTransparency or nil,
			})
		end
	end
	table.insert(transparencyTargets, {
		object = buildTitle,
		background = buildTitle.BackgroundTransparency,
		text = nil,
		image = nil,
	})

	local function collapsedSize()
		return UDim2.new(baseSize.X.Scale, baseSize.X.Offset, 0, 0)
	end

	local function collapsedPosition()
		return UDim2.new(
			basePosition.X.Scale,
			basePosition.X.Offset,
			basePosition.Y.Scale + baseSize.Y.Scale,
			basePosition.Y.Offset + baseSize.Y.Offset
		)
	end

	local function cancelTweens()
		for _, tween in ipairs(tweens) do
			tween:Cancel()
		end
		table.clear(tweens)
	end

	local function setTransparency(hidden)
		for _, target in ipairs(transparencyTargets) do
			local object = target.object
			object.BackgroundTransparency = hidden and 1 or target.background
			if target.text ~= nil then
				object.TextTransparency = hidden and 1 or target.text
			end
			if target.image ~= nil then
				object.ImageTransparency = hidden and 1 or target.image
			end
		end
	end

	local function tweenTransparency(info, hidden)
		for _, target in ipairs(transparencyTargets) do
			local object = target.object
			local goals = {
				BackgroundTransparency = hidden and 1 or target.background,
			}
			if target.text ~= nil then
				goals.TextTransparency = hidden and 1 or target.text
			end
			if target.image ~= nil then
				goals.ImageTransparency = hidden and 1 or target.image
			end
			local tween = TweenService:Create(object, info, goals)
			table.insert(tweens, tween)
			tween:Play()
		end
	end

	local function show()
		token += 1
		local myToken = token
		cancelTweens()
		buildTitle.Visible = true
		buildTitle.Size = collapsedSize()
		buildTitle.Position = collapsedPosition()
		setTransparency(true)

		task.delay(BUILD_TITLE_REVEAL_DELAY, function()
			if myToken ~= token then
				return
			end
			cancelTweens()
			local sizeTween = TweenService:Create(buildTitle, BUILD_TITLE_REVEAL_INFO, {
				Position = basePosition,
				Size = baseSize,
			})
			table.insert(tweens, sizeTween)
			sizeTween:Play()
			tweenTransparency(BUILD_TITLE_REVEAL_INFO, false)
		end)
	end

	local function hide(instant)
		token += 1
		local myToken = token
		cancelTweens()

		if instant then
			buildTitle.Size = collapsedSize()
			buildTitle.Position = collapsedPosition()
			setTransparency(true)
			buildTitle.Visible = false
			return
		end

		local sizeTween = TweenService:Create(buildTitle, BUILD_TITLE_HIDE_INFO, {
			Position = collapsedPosition(),
			Size = collapsedSize(),
		})
		table.insert(tweens, sizeTween)
		sizeTween.Completed:Once(function()
			if myToken == token then
				buildTitle.Visible = false
			end
		end)
		sizeTween:Play()
		tweenTransparency(BUILD_TITLE_HIDE_INFO, true)
	end

	hide(true)
	screenGui:GetAttributeChangedSignal(Attrs.BuildModeActive):Connect(function()
		if screenGui:GetAttribute(Attrs.BuildModeActive) == true then
			show()
		else
			hide(false)
		end
	end)

	return {}
end

return BuildTitleReveal
