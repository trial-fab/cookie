local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	return
end

local shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(shared:WaitForChild("Net"))
local NumberFormat = require(shared:WaitForChild("NumberFormat"))
local PvpConfig = require(shared:WaitForChild("PvpConfig"))
local UiMotion = require(shared:WaitForChild("UiMotion"))

local shieldFrame = screenGui:WaitForChild("Shield", 10)
if not shieldFrame or not shieldFrame:IsA("GuiObject") then
	warn("ShieldUiController disabled: ScreenGui.Shield not found")
	return
end

-- PVP paused (Shared.PvpConfig): hide the shield HUD and do no wiring.
if not PvpConfig.IsActive() then
	shieldFrame.Visible = false
	return
end

local shieldButton = shieldFrame:WaitForChild("ShieldEnabled", 10)
if not shieldButton or not shieldButton:IsA("GuiButton") then
	warn("ShieldUiController disabled: Shield.ShieldEnabled button not found")
	return
end

local shieldBackground = shieldButton:WaitForChild("ShieldBackground", 10)
local shieldIcon = shieldButton:WaitForChild("ShieldEnabled", 10)
local statusBox = shieldFrame:WaitForChild("statusTime", 10)
local statusText = statusBox and statusBox:FindFirstChild("ShieldTime")
local statusStroke = statusBox and statusBox:FindFirstChildWhichIsA("UIStroke")

if not shieldBackground or not shieldBackground:IsA("ImageLabel") and not shieldBackground:IsA("ImageButton") then
	warn("ShieldUiController disabled: ShieldBackground image not found")
	return
end
if not shieldIcon or not shieldIcon:IsA("ImageLabel") and not shieldIcon:IsA("ImageButton") then
	warn("ShieldUiController disabled: inner ShieldEnabled image not found")
	return
end
if not statusBox or not statusBox:IsA("GuiObject") or not statusText or not statusText:IsA("TextLabel") then
	warn("ShieldUiController disabled: statusTime/ShieldTime text not found")
	return
end

local cookieSheets = Workspace:WaitForChild("CookieSheets")

local OFF_COLOR = Color3.fromRGB(8, 12, 11)
local ON_COLOR = Color3.fromRGB(0, 170, 127)
local OPEN_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

local function getAuthoredStatusBox()
	local authoredScreenGui = StarterGui:FindFirstChild(screenGui.Name)
	local authoredShield = authoredScreenGui and authoredScreenGui:FindFirstChild(shieldFrame.Name)
	local authoredStatusBox = authoredShield and authoredShield:FindFirstChild(statusBox.Name)
	if authoredStatusBox and authoredStatusBox:IsA("GuiObject") then
		return authoredStatusBox
	end

	return statusBox
end

local authoredStatusBox = getAuthoredStatusBox()
local openStatusAnchorPoint = authoredStatusBox.AnchorPoint
local timerStatusSize = authoredStatusBox.Size
local closedStatusSize = UDim2.new(0, 0, timerStatusSize.Y.Scale, timerStatusSize.Y.Offset)
local openStatusPosition = authoredStatusBox.Position
local statusTween
local statusTweenToken = 0
local strokeTween
local statusMode = "closed"
local lastOpenStatusSize = timerStatusSize
local statusStrokeActive = false
local hovering = false
local debounce = false
local shieldEnabledValue
local shieldTimeValue

statusBox.ClipsDescendants = true
statusBox.AnchorPoint = openStatusAnchorPoint
statusText.Visible = true
if statusStroke then
	statusStroke.Color = ON_COLOR
	statusStroke.Enabled = false
end

local function getPlayerCookieSheet()
	for _, sheet in ipairs(cookieSheets:GetChildren()) do
		local sheetOwner = sheet:FindFirstChild("SheetOwner")
		if sheetOwner and sheetOwner.Value == player then
			return sheet
		end
	end

	return nil
end

local function waitForShieldEnabled()
	local sheet = getPlayerCookieSheet()
	while not sheet do
		task.wait(0.25)
		sheet = getPlayerCookieSheet()
	end

	return sheet:WaitForChild("ShieldEnabled")
end

local function getCookiesValue()
	local leaderstats = player:FindFirstChild("leaderstats")
	return leaderstats and leaderstats:FindFirstChild("Cookies")
end

local function getShieldCost()
	local cookies = getCookiesValue()
	if not cookies then
		return 0
	end

	return math.max(0, math.floor(cookies.Value * 0.5))
end

local function getRemainingShieldTime()
	if not shieldTimeValue then
		return 0
	end

	return math.max(0, math.floor(shieldTimeValue.Value))
end

local function formatTime(totalSeconds)
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds % 60
	return string.format("%02d:%02d", minutes, seconds)
end

local function setStatusText(text)
	if statusText.Text == text then
		return false
	end

	statusText.Text = text
	return true
end

local function getTextPaddingOffset()
	local padding = statusText:FindFirstChildWhichIsA("UIPadding")
	if not padding then
		return 0
	end

	return padding.PaddingLeft.Offset + padding.PaddingRight.Offset
end

local function getDynamicCostStatusSize()
	local textBounds = TextService:GetTextSize(
		statusText.Text,
		statusText.TextSize,
		statusText.Font,
		Vector2.new(10000, math.max(1, statusText.AbsoluteSize.Y))
	)
	local textFrameOffset = statusText.Position.X.Offset - statusText.Size.X.Offset
	local measuredWidth = math.ceil(textBounds.X + getTextPaddingOffset() + textFrameOffset)
	local width = math.max(timerStatusSize.X.Offset, measuredWidth)

	return UDim2.new(timerStatusSize.X.Scale, width, timerStatusSize.Y.Scale, timerStatusSize.Y.Offset)
end

local function getClosedStatusPosition(openSize)
	return UDim2.new(
		openStatusPosition.X.Scale + (openSize.X.Scale * (1 - openStatusAnchorPoint.X)),
		openStatusPosition.X.Offset + (openSize.X.Offset * (1 - openStatusAnchorPoint.X)),
		openStatusPosition.Y.Scale,
		openStatusPosition.Y.Offset
	)
end

local function setStatusStrokeEnabled(enabled)
	if not statusStroke then
		return
	end
	if statusStrokeActive == enabled then
		return
	end

	statusStrokeActive = enabled
	if strokeTween then
		strokeTween:Cancel()
		strokeTween = nil
	end

	statusStroke.Color = ON_COLOR
	if enabled then
		statusStroke.Enabled = true
		statusStroke.Transparency = 1
		strokeTween = UiMotion.create(statusStroke, OPEN_TWEEN, { Transparency = 0 })
		strokeTween:Play()
	else
		strokeTween = UiMotion.create(statusStroke, CLOSE_TWEEN, { Transparency = 1 })
		strokeTween.Completed:Once(function()
			if statusStroke.Transparency >= 1 then
				statusStroke.Enabled = false
			end
		end)
		strokeTween:Play()
	end
end

local function setStatusMode(mode, force)
	if statusMode == mode and not force then
		return
	end

	statusMode = mode
	statusTweenToken += 1
	local token = statusTweenToken
	if statusTween then
		statusTween:Cancel()
		statusTween = nil
	end

	local targetSize = closedStatusSize
	local targetPosition = getClosedStatusPosition(lastOpenStatusSize)
	local tweenInfo = CLOSE_TWEEN

	if mode == "cost" then
		local costStatusSize = getDynamicCostStatusSize()
		targetSize = costStatusSize
		targetPosition = openStatusPosition
		tweenInfo = OPEN_TWEEN
		lastOpenStatusSize = costStatusSize
	elseif mode == "timer" then
		targetSize = timerStatusSize
		targetPosition = openStatusPosition
		tweenInfo = OPEN_TWEEN
		lastOpenStatusSize = timerStatusSize
	elseif mode == "closed" then
		targetPosition = getClosedStatusPosition(lastOpenStatusSize)
	end

	statusBox.Visible = true
	statusTween = UiMotion.create(statusBox, tweenInfo, {
		Size = targetSize,
		Position = targetPosition,
	})
	statusTween.Completed:Once(function()
		if token ~= statusTweenToken then
			return
		end
		statusBox.Size = targetSize
		statusBox.Position = targetPosition
	end)
	statusTween:Play()
end

local function setShieldVisual(enabled)
	shieldIcon.ImageColor3 = OFF_COLOR
	shieldBackground.ImageColor3 = enabled and ON_COLOR or OFF_COLOR
end

local function updateUi()
	if not shieldEnabledValue then
		return
	end

	local enabled = shieldEnabledValue.Value
	setShieldVisual(enabled)

	if enabled then
		setStatusText(formatTime(getRemainingShieldTime()))
		setStatusStrokeEnabled(true)
		setStatusMode("timer")
	else
		local costTextChanged = setStatusText("Cost " .. NumberFormat.abbreviate(getShieldCost()))
		setStatusStrokeEnabled(false)
		setStatusMode(hovering and "cost" or "closed", hovering and costTextChanged)
	end
end

local function setHovering(value)
	hovering = value
	updateUi()
end

local function onShieldClicked()
	if debounce or not shieldEnabledValue then
		return
	end

	debounce = true
	Net.fireServer(Net.Names.ToggleShield)
	task.delay(0.25, function()
		debounce = false
		updateUi()
	end)
end

local function connectButton(button)
	if button and button:IsA("GuiButton") then
		button.Activated:Connect(onShieldClicked)
	end
end

shieldEnabledValue = waitForShieldEnabled()
shieldTimeValue = player:WaitForChild("ShieldTime")
local cookiesValue = getCookiesValue()
if cookiesValue then
	cookiesValue.Changed:Connect(updateUi)
end

statusBox.Size = shieldEnabledValue.Value and timerStatusSize or closedStatusSize
statusBox.Position = shieldEnabledValue.Value and openStatusPosition or getClosedStatusPosition(lastOpenStatusSize)
statusMode = shieldEnabledValue.Value and "timer" or "closed"
updateUi()

shieldEnabledValue.Changed:Connect(updateUi)
shieldTimeValue.Changed:Connect(updateUi)

shieldButton.MouseEnter:Connect(function()
	setHovering(true)
end)
shieldButton.MouseLeave:Connect(function()
	setHovering(false)
end)

connectButton(shieldButton)
connectButton(shieldBackground)
connectButton(shieldIcon)

task.spawn(function()
	while true do
		task.wait(1)
		if shieldEnabledValue then
			updateUi()
		end
	end
end)
