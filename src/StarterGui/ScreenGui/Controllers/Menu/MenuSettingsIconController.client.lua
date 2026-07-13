local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))
local GuiNames = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GuiNames"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	return
end

local pill = screenGui:WaitForChild(GuiNames.MenuPill, 10)
if not pill then
	warn("MenuSettingsIconController: MenuPill not found")
	return
end

local settingsFrame = pill:FindFirstChild(GuiNames.Settings, true)
local settingsDeadline = os.clock() + 10
while not settingsFrame and os.clock() < settingsDeadline do
	task.wait(0.05)
	settingsFrame = pill:FindFirstChild(GuiNames.Settings, true)
end
if not settingsFrame or not settingsFrame:IsA("GuiObject") then
	warn("MenuSettingsIconController: Settings frame not found")
	return
end

local settingsButton = settingsFrame:FindFirstChild(GuiNames.SettingsButton)
if not settingsButton or not settingsButton:IsA("ImageButton") then
	warn("MenuSettingsIconController: SettingsButton image button not found")
	return
end

local defaultImage = settingsButton:GetAttribute("SettingsDefaultImage")
if typeof(defaultImage) ~= "string" or defaultImage == "" then
	defaultImage = settingsButton.Image
	settingsButton:SetAttribute("SettingsDefaultImage", defaultImage)
end

local activeImage = settingsButton:GetAttribute("SettingsActiveImage")
if typeof(activeImage) ~= "string" or activeImage == "" then
	activeImage = settingsButton.PressedImage ~= "" and settingsButton.PressedImage or defaultImage
	settingsButton:SetAttribute("SettingsActiveImage", activeImage)
end

local hitbox = settingsFrame:FindFirstChild("Hitbox")
if not hitbox or not hitbox:IsA("TextButton") then
	if hitbox then
		hitbox:Destroy()
	end
	hitbox = Instance.new("TextButton")
	hitbox.Name = "Hitbox"
	hitbox.Parent = settingsFrame
end

hitbox.BackgroundTransparency = 1
hitbox.BorderSizePixel = 0
hitbox.Text = ""
hitbox.TextTransparency = 1
hitbox.AutoButtonColor = false
hitbox.Selectable = true
hitbox:SetAttribute(Attrs.IconOnly, true)
hitbox.ZIndex = math.max(settingsFrame.ZIndex, settingsButton.ZIndex) + 10

local padding = settingsFrame:FindFirstChildWhichIsA("UIPadding")
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

settingsButton.AutoButtonColor = false
settingsButton.Rotation = 0

local spinTweenInfo = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local returnTweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local activeTween = nil
local hovering = false
local pressing = false

local function isActive()
	return settingsFrame:GetAttribute(Attrs.Active) == true
		or settingsButton:GetAttribute(Attrs.Active) == true
		or hitbox:GetAttribute(Attrs.Active) == true
end

local function tweenRotation(rotation, tweenInfo)
	if activeTween then
		activeTween:Cancel()
	end
	activeTween = UiMotion.create(settingsButton, tweenInfo, { Rotation = rotation })
	activeTween:Play()
end

local function snapRotation(rotation)
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	settingsButton.Rotation = rotation
end

local function updateImage()
	if isActive() or pressing then
		settingsButton.Image = activeImage
		snapRotation(0)
	else
		settingsButton.Image = defaultImage
	end
end

local function setActive(active)
	settingsFrame:SetAttribute(Attrs.Active, active)
	settingsButton:SetAttribute(Attrs.Active, active)
	hitbox:SetAttribute(Attrs.Active, active)
	updateImage()
end

hitbox.MouseEnter:Connect(function()
	hovering = true
	settingsFrame:SetAttribute(Attrs.Hovering, true)
	settingsButton:SetAttribute(Attrs.Hovering, true)
	if not isActive() and not pressing then
		tweenRotation(90, spinTweenInfo)
	end
end)

hitbox.MouseLeave:Connect(function()
	hovering = false
	settingsFrame:SetAttribute(Attrs.Hovering, false)
	settingsButton:SetAttribute(Attrs.Hovering, false)
	pressing = false
	tweenRotation(0, returnTweenInfo)
	updateImage()
end)

hitbox.MouseButton1Down:Connect(function()
	pressing = true
	updateImage()
end)

hitbox.MouseButton1Up:Connect(function()
	pressing = false
	updateImage()
	if not hovering and not isActive() then
		tweenRotation(0, returnTweenInfo)
	end
end)

-- NOTE: the "Active" attribute is owned by SettingsController (it tracks the
-- Settings modal's open state). This controller must not toggle Active on click —
-- doing so raced SettingsController on the shared hitbox and left the gear/face
-- out of sync (gear stuck on default while open; profile face stuck toward
-- Settings while closed). We only render the icon from whatever Active is set to.
settingsFrame:GetAttributeChangedSignal(Attrs.Active):Connect(updateImage)
settingsButton:GetAttributeChangedSignal(Attrs.Active):Connect(updateImage)
hitbox:GetAttributeChangedSignal(Attrs.Active):Connect(updateImage)

updateImage()
