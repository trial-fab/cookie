-- BottomRightHudController: binds the always-on bottom-right HUD.
--
-- Logic only. The HUD frame and labels are authored in Studio at
-- StarterGui.ScreenGui.BottomRightHud, mirroring docs/bottom-right.png.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))
local UserInputService = game:GetService("UserInputService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local LiveCookieCount = require(shared:WaitForChild("LiveCookieCount"))
local MobileScale = require(shared:WaitForChild("MobileScale"))
local NumberFormat = require(shared:WaitForChild("NumberFormat"))
local TitleTextEffects = require(shared:WaitForChild("TitleTextEffects"))
local XpConfig = require(shared:WaitForChild("XpConfig"))
local HudStoreTransition = require(script.Parent:WaitForChild("HudStoreTransition"))
local XpBarShimmerPresenter = require(script.Parent:WaitForChild("XpBarShimmerPresenter"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("BottomRightHudController must be inside a ScreenGui")
	return
end
if screenGui:GetAttribute("BottomRightHudControllerRunning") then
	return
end
screenGui:SetAttribute("BottomRightHudControllerRunning", true)

local player = Players.LocalPlayer
local leaderstats = player:WaitForChild("leaderstats")
local cookiesValue = leaderstats:WaitForChild("Cookies")

local hud = screenGui:WaitForChild("BottomRightHud", 10)
if not (hud and hud:IsA("GuiObject")) then
	warn("BottomRightHudController disabled: ScreenGui.BottomRightHud was not found")
	return
end

local function findText(name)
	local object = hud:FindFirstChild(name, true)
	if object and (object:IsA("TextLabel") or object:IsA("TextButton")) then
		return object
	end
	return nil
end

local function findGui(name)
	local object = hud:FindFirstChild(name, true)
	if object and object:IsA("GuiObject") then
		return object
	end
	return nil
end

local function findAmount(containerName)
	local container = hud:FindFirstChild(containerName, true)
	if container then
		local amount = container:FindFirstChild("Amount", true)
		if amount and (amount:IsA("TextLabel") or amount:IsA("TextButton")) then
			return amount
		end
	end
	return findText(containerName .. "Amount")
end

local titleLabel = findText("TitleLabel")
local levelLabel = findText("LevelLabel")
local friendBoostAmount = findAmount("FriendBoost") or findText("FriendBoostAmount")
local xpBar = findGui("XpBar")
local xpFill = xpBar and xpBar:FindFirstChild("Fill", true) or nil
local xpHoverHitbox = xpBar and xpBar:FindFirstChild("HoverHitbox", true) or nil
local xpText = xpBar and xpBar:FindFirstChild("Tooltip", true) or nil
local liveCookieCount = findGui("LiveCookieCount")
local titleEffects = titleLabel and TitleTextEffects.bind(titleLabel) or nil
if titleEffects then
	titleEffects.setActive(true)
end

local xpShimmerPresenter = XpBarShimmerPresenter.bind(xpFill)

if xpText and (xpText:IsA("TextLabel") or xpText:IsA("TextButton")) then
	local shownTransparency = xpText.TextTransparency
	local shownStrokeTransparency = xpText.TextStrokeTransparency
	local fadeTween
	local touchShown = false
	local pointerOver = false
	xpText.TextTransparency = 1
	xpText.TextStrokeTransparency = 1
	local hoverTarget = xpHoverHitbox and xpHoverHitbox:IsA("GuiObject") and xpHoverHitbox or xpBar
	if UserInputService.TouchEnabled then
		hoverTarget.AnchorPoint = Vector2.new(0.5, 0.5)
		hoverTarget.Position = UDim2.fromScale(0.5, 0.5)
		hoverTarget.Size = UDim2.new(1, 0, 0, 36)
	end
	local function fadeTo(textTransparency, strokeTransparency)
		if hud:GetAttribute(Attrs.HudStoreSuppressed) == true then
			touchShown = false
			textTransparency = 1
			strokeTransparency = 1
		end
		if fadeTween then
			fadeTween:Cancel()
		end
		fadeTween = UiMotion.create(xpText, TweenInfo.new(0.12), {
			TextTransparency = textTransparency,
			TextStrokeTransparency = strokeTransparency,
		})
		fadeTween:Play()
	end
	hoverTarget.MouseEnter:Connect(function()
		pointerOver = true
		if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
			return
		end
		fadeTo(shownTransparency, shownStrokeTransparency)
	end)
	hoverTarget.MouseLeave:Connect(function()
		pointerOver = false
		if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
			return
		end
		fadeTo(1, 1)
	end)
	if hoverTarget:IsA("GuiButton") then
		hoverTarget.Activated:Connect(function(input)
			if
				UserInputService.PreferredInput == Enum.PreferredInput.Touch
				or (input and input.UserInputType == Enum.UserInputType.Touch)
			then
				touchShown = not touchShown
				fadeTo(touchShown and shownTransparency or 1, touchShown and shownStrokeTransparency or 1)
			end
		end)
		hoverTarget.SelectionGained:Connect(function()
			if UserInputService.PreferredInput == Enum.PreferredInput.Gamepad then
				fadeTo(shownTransparency, shownStrokeTransparency)
			end
		end)
		hoverTarget.SelectionLost:Connect(function()
			if UserInputService.PreferredInput == Enum.PreferredInput.Gamepad then
				fadeTo(1, 1)
			end
		end)
	end
	UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch or not touchShown then
			return
		end
		local point = Vector2.new(input.Position.X, input.Position.Y)
		if not screenGui.IgnoreGuiInset then
			point -= GuiService:GetGuiInset()
		end
		local position = hoverTarget.AbsolutePosition
		local size = hoverTarget.AbsoluteSize
		if
			point.X < position.X
			or point.X > position.X + size.X
			or point.Y < position.Y
			or point.Y > position.Y + size.Y
		then
			touchShown = false
			fadeTo(1, 1)
		end
	end)
	hud:GetAttributeChangedSignal(Attrs.HudStoreSuppressed):Connect(function()
		if hud:GetAttribute(Attrs.HudStoreSuppressed) == true then
			fadeTo(1, 1)
		elseif pointerOver and UserInputService.PreferredInput == Enum.PreferredInput.KeyboardAndMouse then
			fadeTo(shownTransparency, shownStrokeTransparency)
		elseif
			GuiService.SelectedObject == hoverTarget
			and UserInputService.PreferredInput == Enum.PreferredInput.Gamepad
		then
			fadeTo(shownTransparency, shownStrokeTransparency)
		end
	end)
end

if friendBoostAmount then
	friendBoostAmount.Text = "+0%"
end

local liveCountBinding = LiveCookieCount.bind(liveCookieCount, cookiesValue)

local fillTween
local fillTweenInfo = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function setXpFill(progress)
	if not (xpFill and xpFill:IsA("GuiObject")) then
		return
	end

	progress = math.clamp(tonumber(progress) or 0, 0, 1)
	if fillTween then
		fillTween:Cancel()
	end
	fillTween = UiMotion.create(xpFill, fillTweenInfo, {
		Size = UDim2.new(progress, 0, xpFill.Size.Y.Scale, xpFill.Size.Y.Offset),
	})
	fillTween:Play()
end

local function renderXp()
	local info = XpConfig.GetLevelInfo(player:GetAttribute(Attrs.Xp), player:GetAttribute(Attrs.SelectedTitleId))

	if titleLabel then
		titleLabel.Text = info.title
		titleEffects.apply(info.titleDef, true)
	end
	if levelLabel then
		levelLabel.Text = "Level " .. tostring(info.level)
	end

	local currentXpText = NumberFormat.exact(info.currentXp) .. "/" .. NumberFormat.exact(info.neededXp) .. " XP"
	if xpText then
		xpText.Text = currentXpText
	end

	setXpFill(info.progress)
end

player:GetAttributeChangedSignal(Attrs.Xp):Connect(renderXp)
player:GetAttributeChangedSignal(Attrs.SelectedTitleId):Connect(renderXp)

renderXp()
liveCountBinding.refresh()

-- Shrink the HUD on phones so it stops bleeding into the hotbar; UIScale-only so its mixed
-- scale/offset layout scales as one and never distorts. Untouched on PC (mobileFactor = 1 without
-- touch).
MobileScale.applyMobileScale(hud, { mobileScale = 0.6 })

-- On mobile the HUD moves out of the crowded bottom bar and into the leaderboard's top-right slot,
-- where the two are interchangeable: the board is closed on spawn (HUD showing), and opening it
-- slides the board in over this slot, so the HUD hides and reappears when the board closes. On PC
-- nothing changes -- the HUD stays in its authored bottom-right corner and is always shown.
local pcAnchor = hud.AnchorPoint
local pcPosition = hud.Position

-- Mirror the leaderboard's authored top-right slot (Leaderboard is AnchorPoint (1,0) at
-- {1,-10},{0,62}, with the same 10px mobile edge nudge). Both share the slot 1:1 on mobile.
local BOARD_SLOT_ANCHOR = Vector2.new(1, 0)
local BOARD_SLOT_POSITION = UDim2.new(1, -10, 0, 62)

local function updatePlacement()
	if MobileScale.shouldUseMobile(hud) then
		hud.AnchorPoint = BOARD_SLOT_ANCHOR
		hud.Position = MobileScale.shiftLeftOnMobile(BOARD_SLOT_POSITION, 10, hud)
	else
		hud.AnchorPoint = pcAnchor
		hud.Position = pcPosition
	end
end

local function updateVisibility()
	-- PC: always visible. Mobile: visible only while the leaderboard is closed (they swap places).
	local leaderboardOpen = screenGui:GetAttribute(Attrs.LeaderboardOpen) == true
	local compactModal = screenGui:GetAttribute(Attrs.CompactModalActive) == true
	hud.Visible = not compactModal and not (MobileScale.shouldUseMobile(hud) and leaderboardOpen)
end

-- Mobile-only reflow of the HUD's stacked layout: XpBar rides on top of the Top block, and each
-- Top column gets its own order. The Studio-authored LayoutOrder is captured up front and restored
-- verbatim on PC, so this only ever reshuffles on a phone. (All three frames sort by LayoutOrder.)
local mobileLayoutOrder = {}
local authoredLayoutOrder = {}
local function registerOrder(instance, mobileOrder)
	if instance and instance:IsA("GuiObject") then
		mobileLayoutOrder[instance] = mobileOrder
		authoredLayoutOrder[instance] = instance.LayoutOrder
	end
end

do
	local top = hud:FindFirstChild("Top")
	local left = top and top:FindFirstChild("Left")

	registerOrder(hud:FindFirstChild("XpBar"), 0)
	registerOrder(top, 1)
	if left then
		registerOrder(left:FindFirstChild("LevelLabel"), 1)
		registerOrder(left:FindFirstChild("TitleLabel"), 2)
		registerOrder(left:FindFirstChild("empty"), 3)
	end
	-- Right-column order and the nested cookieCount row are authored entirely in Studio.
end

local function updateLayoutOrder()
	local mobile = MobileScale.shouldUseMobile(hud)
	for instance, mobileOrder in pairs(mobileLayoutOrder) do
		instance.LayoutOrder = mobile and mobileOrder or authoredLayoutOrder[instance]
	end
end

MobileScale.onViewportChanged(function()
	updatePlacement()
	updateVisibility()
	updateLayoutOrder()
end)
screenGui:GetAttributeChangedSignal(Attrs.LeaderboardOpen):Connect(updateVisibility)
screenGui:GetAttributeChangedSignal(Attrs.CompactModalActive):Connect(updateVisibility)

-- Fade the whole HUD out while the store band is up, and back in when it closes.
HudStoreTransition.start({
	screenGui = screenGui,
	hud = hud,
})
