local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then return end

local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))
local MobileScale = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MobileScale"))

local boardToggle = screenGui:WaitForChild("BoardToggle", 10)
if not boardToggle then
	warn("BoardToggleController: BoardToggle not found within 10 s")
	return
end

local function updateCompactModalVisibility()
	boardToggle.Visible = screenGui:GetAttribute(Attrs.CompactModalActive) ~= true
end
screenGui:GetAttributeChangedSignal(Attrs.CompactModalActive):Connect(updateCompactModalVisibility)
updateCompactModalVisibility()

-- On mobile, nudge the toggle 10px further from the right edge so it clears the rounded screen
-- corner now that ClipToDeviceSafeArea is off. Re-applies on orientation changes.
local baseTogglePosition = boardToggle.Position
MobileScale.onViewportChanged(function()
	boardToggle.Position = MobileScale.shiftLeftOnMobile(baseTogglePosition, 10, boardToggle)
end)

local hitbox = boardToggle:FindFirstChild("Hitbox")
if not hitbox or not hitbox:IsA("TextButton") then
	if hitbox then
		hitbox:Destroy()
	end
	hitbox = Instance.new("TextButton")
	hitbox.Name = "Hitbox"
	hitbox.Parent = boardToggle
end

hitbox.BackgroundTransparency = 1
hitbox.BorderSizePixel = 0
hitbox.Text = ""
hitbox.TextTransparency = 1
hitbox.AutoButtonColor = false
hitbox.Selectable = false
hitbox:SetAttribute(Attrs.IconOnly, true)
hitbox.ZIndex = boardToggle.ZIndex + 10

local padding = boardToggle:FindFirstChildWhichIsA("UIPadding")
if padding then
	hitbox.Position = UDim2.new(-padding.PaddingLeft.Scale, -padding.PaddingLeft.Offset, -padding.PaddingTop.Scale, -padding.PaddingTop.Offset)
	hitbox.Size = UDim2.new(
		1 + padding.PaddingLeft.Scale + padding.PaddingRight.Scale,
		padding.PaddingLeft.Offset + padding.PaddingRight.Offset,
		1 + padding.PaddingTop.Scale + padding.PaddingBottom.Scale,
		padding.PaddingTop.Offset + padding.PaddingBottom.Offset
	)
else
	hitbox.Position = UDim2.fromScale(0, 0)
	hitbox.Size = UDim2.fromScale(1, 1)
end

local function ensureHamburgerBars(toggleFrame)
	local icon = toggleFrame:FindFirstChild("hamburger") or toggleFrame:FindFirstChild("HamburgerIcon")
	if not icon or not icon:IsA("Frame") then
		if icon then
			icon:Destroy()
		end
		icon = Instance.new("Frame")
		icon.Name = "hamburger"
		icon.Parent = toggleFrame
	end

	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	if icon.Size == UDim2.new() then
		icon.Size = UDim2.fromOffset(20, 16)
	end
	icon.ClipsDescendants = false

	local function ensureBar(name, yScale)
		local bar = icon:FindFirstChild(name)
		if not bar or not bar:IsA("Frame") then
			if bar then
				bar:Destroy()
			end
			bar = Instance.new("Frame")
			bar.Name = name
			bar.Parent = icon
			bar.AnchorPoint = Vector2.new(0.5, 0.5)
			bar.Position = UDim2.fromScale(0.5, yScale)
			bar.Size = UDim2.new(1, 0, 0, 2)
			bar.BackgroundColor3 = Color3.new(1, 1, 1)
			bar.BorderSizePixel = 0
			bar.ZIndex = icon.ZIndex + 1
		end
		if not bar:FindFirstChildOfClass("UICorner") then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 1)
			corner.Parent = bar
		end
		bar.Visible = true
		return bar
	end

	local topBar = ensureBar("TopBar", 0)
	local middleBar = ensureBar("MiddleBar", 0.5)
	local bottomBar = ensureBar("BottomBar", 1)

	return icon, topBar, middleBar, bottomBar
end

local _, topBar, middleBar, bottomBar = ensureHamburgerBars(boardToggle)

local closedBars = {
	top = {
		Position = topBar.Position,
		Size = topBar.Size,
		Rotation = topBar.Rotation,
		BackgroundTransparency = topBar.BackgroundTransparency,
	},
	middle = {
		Position = middleBar.Position,
		Size = middleBar.Size,
		Rotation = middleBar.Rotation,
		BackgroundTransparency = middleBar.BackgroundTransparency,
	},
	bottom = {
		Position = bottomBar.Position,
		Size = bottomBar.Size,
		Rotation = bottomBar.Rotation,
		BackgroundTransparency = bottomBar.BackgroundTransparency,
	},
}

local iconOpenInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local iconCloseInfo = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local iconTweens = {}
local isOpen = false

local function playIconTween(instance, tweenInfo, goals)
	local previous = iconTweens[instance]
	if previous then
		previous:Cancel()
	end
	local tween = UiMotion.create(instance, tweenInfo, goals)
	iconTweens[instance] = tween
	tween.Completed:Once(function()
		if iconTweens[instance] == tween then
			iconTweens[instance] = nil
		end
	end)
	tween:Play()
end

local function setOpen(open)
	isOpen = open
	boardToggle:SetAttribute(Attrs.Open, open)
	hitbox:SetAttribute(Attrs.Active, open)

	if open then
		playIconTween(topBar, iconOpenInfo, {
			Position = UDim2.fromScale(0.5, 0.5),
			Rotation = 45,
			BackgroundTransparency = 0,
		})
		playIconTween(middleBar, iconOpenInfo, {
			Size = UDim2.new(0, 0, closedBars.middle.Size.Y.Scale, closedBars.middle.Size.Y.Offset),
			BackgroundTransparency = 1,
		})
		playIconTween(bottomBar, iconOpenInfo, {
			Position = UDim2.fromScale(0.5, 0.5),
			Rotation = -45,
			BackgroundTransparency = 0,
		})
	else
		playIconTween(topBar, iconCloseInfo, closedBars.top)
		playIconTween(middleBar, iconCloseInfo, closedBars.middle)
		playIconTween(bottomBar, iconCloseInfo, closedBars.bottom)
	end
end

setOpen(boardToggle:GetAttribute(Attrs.Open) == true)

boardToggle:GetAttributeChangedSignal(Attrs.Open):Connect(function()
	local requestedOpen = boardToggle:GetAttribute(Attrs.Open) == true
	if requestedOpen ~= isOpen then
		setOpen(requestedOpen)
	end
end)
