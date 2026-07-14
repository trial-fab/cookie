-- Pure behavior: finds pre-existing pill and wires the toggle tween.
-- Enable this instead of (or alongside) MenuController when you want Studio
-- edits to the pill to be preserved at runtime.
local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then return end

local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))
local GuiNames = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GuiNames"))
local MobileScale = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MobileScale"))

local openInfo = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local closeInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local iconOpenInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local iconCloseInfo = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local pill = screenGui:WaitForChild(GuiNames.MenuPill, 10)
if not pill then
	warn("MenuBehaviorController: MenuPill not found within 10 s")
	return
end

local authoredPillBackgroundTransparency = pill.BackgroundTransparency
local authoredPillZIndex = pill.ZIndex
local compactModalActive = false
local compactMenuRestoreRequested = false
local refreshCompactMenuLayout = nil
local function updateCompactModalPresentation()
	compactModalActive = screenGui:GetAttribute(Attrs.CompactModalActive) == true
	compactMenuRestoreRequested = screenGui:GetAttribute(Attrs.CompactMenuRestoreRequested) == true
	-- Keep the menu controls available so players can switch directly between the four main
	-- modals. Only its surrounding pill disappears into the full-screen modal surface.
	pill.Visible = true
	pill.BackgroundTransparency = compactModalActive and 1 or authoredPillBackgroundTransparency
	pill.ZIndex = compactModalActive and math.max(authoredPillZIndex, 102) or authoredPillZIndex
	if refreshCompactMenuLayout then
		refreshCompactMenuLayout()
	end
end
screenGui:GetAttributeChangedSignal(Attrs.CompactModalActive):Connect(updateCompactModalPresentation)
screenGui:GetAttributeChangedSignal(Attrs.CompactMenuRestoreRequested):Connect(updateCompactModalPresentation)
updateCompactModalPresentation()

-- On mobile, nudge the pill 10px further from the right edge so it clears the rounded screen
-- corner now that ClipToDeviceSafeArea is off. Re-applies on orientation changes. Open/close
-- only grows pill.Size leftward (anchor 1,0), so nothing else owns pill.Position.
local basePillPosition = pill.Position
MobileScale.onViewportChanged(function()
	pill.Position = MobileScale.shiftLeftOnMobile(basePillPosition, 10, pill)
end)

local toggle = pill:FindFirstChild("Toggle") or pill:FindFirstChild("ToggleButton")
if not toggle then
	toggle = pill:WaitForChild("Toggle", 5) or pill:FindFirstChild("ToggleButton")
end
if not toggle then
	warn("MenuBehaviorController: Toggle frame not found inside MenuPill")
	return
end

local cornerDotNames = {
	topLeft = 45,
	bottomRight = 45,
	topRight = -45,
	bottomLeft = -45,
}

local middleDotNames = {
	"topMiddle",
	"middleLeft",
	"middleMiddle",
	"middleRight",
	"bottomMiddle",
}

local defaultDotPositions = {
	topLeft = UDim2.new(0, 0, 0, 0),
	topMiddle = UDim2.new(0.5, 0, 0, 0),
	topRight = UDim2.new(1, 0, 0, 0),
	middleLeft = UDim2.new(0, 0, 0.5, 0),
	middleMiddle = UDim2.new(0.5, 0, 0.5, 0),
	middleRight = UDim2.new(1, 0, 0.5, 0),
	bottomLeft = UDim2.new(0, 0, 1, 0),
	bottomMiddle = UDim2.new(0.5, 0, 1, 0),
	bottomRight = UDim2.new(1, 0, 1, 0),
}

local function ensureToggleHitbox(toggleFrame)
	if toggleFrame:IsA("GuiButton") then
		return toggleFrame
	end

	local hitbox = toggleFrame:FindFirstChild("Hitbox")
	if not hitbox or not hitbox:IsA("TextButton") then
		if hitbox then
			hitbox:Destroy()
		end
		hitbox = Instance.new("TextButton")
		hitbox.Name = "Hitbox"
		hitbox.Parent = toggleFrame
	end

	hitbox.BackgroundTransparency = 1
	hitbox.BorderSizePixel = 0
	hitbox.Text = ""
	hitbox.TextTransparency = 1
	hitbox.AutoButtonColor = false
	hitbox.Selectable = true
	hitbox:SetAttribute(Attrs.IconOnly, true)
	hitbox.ZIndex = toggleFrame.ZIndex + 10

	local padding = toggleFrame:FindFirstChildWhichIsA("UIPadding")
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

	return hitbox
end

local function ensureDotsIcon(toggleFrame)
	local dots = toggleFrame:FindFirstChild("dots")
	if not dots or not dots:IsA("Frame") then
		if dots then
			dots:Destroy()
		end
		dots = Instance.new("Frame")
		dots.Name = "dots"
		dots.Parent = toggleFrame
	end

	dots.BackgroundTransparency = 1
	dots.AnchorPoint = Vector2.new(0.5, 0.5)
	dots.Position = UDim2.fromScale(0.5, 0.5)
	if dots.Size == UDim2.new() then
		dots.Size = UDim2.fromOffset(16, 16)
	end
	dots.ClipsDescendants = false

	local function ensureDot(name)
		local dot = dots:FindFirstChild(name)
		if not dot or not dot:IsA("Frame") then
			if dot then
				dot:Destroy()
			end
			dot = Instance.new("Frame")
			dot.Name = name
			dot.AnchorPoint = Vector2.new(0.5, 0.5)
			dot.Position = defaultDotPositions[name]
			dot.Size = UDim2.fromOffset(4, 4)
			dot.BackgroundColor3 = Color3.new(1, 1, 1)
			dot.BorderSizePixel = 0
			dot.ZIndex = dots.ZIndex + 1
			dot.Parent = dots
		end
		if not dot:FindFirstChildOfClass("UICorner") then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = dot
		end
		dot.Visible = true
		return dot
	end

	for name in pairs(defaultDotPositions) do
		ensureDot(name)
	end

	return dots
end

local function captureDot(dot)
	return {
		Position = dot.Position,
		Size = dot.Size,
		Rotation = dot.Rotation,
		BackgroundTransparency = dot.BackgroundTransparency,
		AnchorPoint = dot.AnchorPoint,
	}
end

local function findDot(dots, name)
	local dot = dots:FindFirstChild(name)
	if dot and dot:IsA("Frame") then
		return dot
	end
	return nil
end

local function getXBarSize()
	local boardToggle = screenGui:FindFirstChild("BoardToggle")
	local hamburger = boardToggle and (boardToggle:FindFirstChild("hamburger") or boardToggle:FindFirstChild("HamburgerIcon"))
	local topBar = hamburger and (hamburger:FindFirstChild("TopBar") or hamburger:FindFirstChild("Bar1"))

	local width = 20
	local height = 2
	if hamburger and hamburger:IsA("GuiObject") and hamburger.Size.X.Offset > 0 then
		width = hamburger.Size.X.Offset
	end
	if topBar and topBar:IsA("GuiObject") and topBar.Size.Y.Offset > 0 then
		height = topBar.Size.Y.Offset
	end

	return UDim2.fromOffset(width, height)
end

local toggleButton = ensureToggleHitbox(toggle)
local dots = ensureDotsIcon(toggle)
local openSize = pill.Size
local closedSize = UDim2.new(openSize.Y.Scale, openSize.Y.Offset, openSize.Y.Scale, openSize.Y.Offset)
local layout = pill:FindFirstChildOfClass("UIListLayout")

local function getOffsetSize(size)
	return Vector2.new(size.X.Offset, size.Y.Offset)
end

local function getOrderedMenuItems()
	local items = {}
	for _, child in ipairs(pill:GetChildren()) do
		if child:IsA("GuiObject") and child ~= toggle and child.Name ~= "MenuItemsClip" then
			table.insert(items, child)
		end
	end

	table.sort(items, function(left, right)
		if left.LayoutOrder == right.LayoutOrder then
			return left.Name < right.Name
		end
		return left.LayoutOrder < right.LayoutOrder
	end)

	return items
end

local maxMenuHeight = math.max(openSize.Y.Offset, closedSize.Y.Offset)
local toggleSize = getOffsetSize(toggle.Size)
local compactOpenSize = UDim2.new(
	openSize.X.Scale - toggle.Size.X.Scale,
	openSize.X.Offset - toggleSize.X,
	openSize.Y.Scale,
	openSize.Y.Offset
)
local revealItems = getOrderedMenuItems()
local revealClip = pill:FindFirstChild("MenuItemsClip")
if not revealClip or not revealClip:IsA("Frame") then
	if revealClip then
		revealClip:Destroy()
	end
	revealClip = Instance.new("Frame")
	revealClip.Name = "MenuItemsClip"
	revealClip.Parent = pill
end

revealClip.BackgroundTransparency = 1
revealClip.BorderSizePixel = 0
revealClip.ClipsDescendants = true
revealClip.ZIndex = pill.ZIndex + 1

local function layoutRevealItems()
	local x = 0
	for _, item in ipairs(revealItems) do
		item.Parent = revealClip
		item.AnchorPoint = Vector2.new(0, 0)
		item.Position = UDim2.fromOffset(x, math.floor((maxMenuHeight - item.Size.Y.Offset) / 2 + 0.5))
		x += item.Size.X.Offset
	end
end

if layout then
	layout.Parent = nil
end

local menuOpen = false
local compactToggleCollapsed = false
local activeTween = nil

local function updateMenuLayout()
	local pillWidth = pill.Size.X.Offset
	local pillHeight = math.max(pill.Size.Y.Offset, maxMenuHeight)
	local toggleX = math.max(0, pillWidth - toggleSize.X)
	local revealWidth = compactToggleCollapsed and pillWidth or toggleX

	revealClip.Position = UDim2.fromOffset(0, 0)
	revealClip.Size = UDim2.fromOffset(revealWidth, pillHeight)
	toggle.Position = UDim2.fromOffset(toggleX, math.floor((pillHeight - toggleSize.Y) / 2 + 0.5))
end

layoutRevealItems()
pill:GetPropertyChangedSignal("Size"):Connect(updateMenuLayout)

local closedDots = {}
for name in pairs(cornerDotNames) do
	local dot = findDot(dots, name)
	if dot then
		closedDots[name] = captureDot(dot)
	end
end
for _, name in ipairs(middleDotNames) do
	local dot = findDot(dots, name)
	if dot then
		closedDots[name] = captureDot(dot)
	end
end

local iconTweens = {}

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

local function setIconOpen(open)
	if open then
		local xBarSize = getXBarSize()
		for name, rotation in pairs(cornerDotNames) do
			local dot = findDot(dots, name)
			if dot then
				dot.AnchorPoint = Vector2.new(0.5, 0.5)
				playIconTween(dot, iconOpenInfo, {
					Position = UDim2.fromScale(0.5, 0.5),
					Size = xBarSize,
					Rotation = rotation,
					BackgroundTransparency = 0,
				})
			end
		end
		for _, name in ipairs(middleDotNames) do
			local dot = findDot(dots, name)
			if dot then
				playIconTween(dot, iconOpenInfo, {
					Size = UDim2.fromOffset(0, 0),
					BackgroundTransparency = 1,
				})
			end
		end
	else
		for name, closedState in pairs(closedDots) do
			local dot = findDot(dots, name)
			if dot then
				dot.AnchorPoint = closedState.AnchorPoint
				playIconTween(dot, iconCloseInfo, {
					Position = closedState.Position,
					Size = closedState.Size,
					Rotation = closedState.Rotation,
					BackgroundTransparency = closedState.BackgroundTransparency,
				})
			end
		end
	end
end

local function tweenMenuSize(targetSize, tweenInfo, onComplete)
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	local tween = UiMotion.create(pill, tweenInfo, { Size = targetSize })
	activeTween = tween
	tween.Completed:Once(function(playbackState)
		if activeTween ~= tween then
			return
		end
		activeTween = nil
		if playbackState == Enum.PlaybackState.Completed and onComplete then
			onComplete()
		end
	end)
	tween:Play()
end

local function setMenuOpen(open)
	menuOpen = open
	toggle:SetAttribute(Attrs.Open, open)
	toggleButton:SetAttribute(Attrs.Active, open)
	if toggle:IsA("TextButton") then
		toggle.Text = ""
	end
	setIconOpen(open)
	pill.ClipsDescendants = true
	compactToggleCollapsed = compactModalActive and open
	toggle.Visible = not compactToggleCollapsed
	updateMenuLayout()
	tweenMenuSize(
		open and (compactToggleCollapsed and compactOpenSize or openSize) or closedSize,
		open and openInfo or closeInfo
	)
end

refreshCompactMenuLayout = function()
	local shouldCollapseToggle = compactModalActive and menuOpen and not compactMenuRestoreRequested
	if shouldCollapseToggle then
		-- The fullscreen modal already supplies the top-right X. Remove the menu's duplicate X,
		-- give its slot to the reveal row, and shrink the right-anchored pill so the row slides right.
		compactToggleCollapsed = true
		toggle.Visible = false
		updateMenuLayout()
		tweenMenuSize(compactOpenSize, closeInfo)
	elseif compactModalActive and menuOpen and compactToggleCollapsed and compactMenuRestoreRequested then
		-- Recreate the open menu's empty toggle slot while the fullscreen modal still covers the
		-- HUD. The modal is released on this tween's final frame, so its X is never shown twice.
		toggle.Visible = false
		updateMenuLayout()
		tweenMenuSize(openSize, openInfo, function()
			if compactModalActive and compactMenuRestoreRequested and menuOpen then
				compactToggleCollapsed = false
				updateMenuLayout()
			end
		end)
	elseif menuOpen and not compactModalActive then
		compactToggleCollapsed = false
		toggle.Visible = true
		pill.Size = openSize
		updateMenuLayout()
	elseif not menuOpen then
		compactToggleCollapsed = false
		toggle.Visible = true
		updateMenuLayout()
	end
end

-- Reset to closed on startup (pill may have been baked open for design view).
pill.Size = closedSize
pill.ClipsDescendants = true
updateMenuLayout()
dots.Visible = true
if toggle:IsA("TextButton") then
	toggle.Text = ""
end
toggle:SetAttribute(Attrs.Open, false)
toggleButton:SetAttribute(Attrs.Active, false)
setIconOpen(false)
updateCompactModalPresentation()

toggleButton.MouseButton1Click:Connect(function()
	setMenuOpen(not menuOpen)
end)
