-- Thin WheelModal orchestrator. Studio owns the authored pages/templates; focused modules
-- own reel/preview and lazy collection behavior.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ModalOutsideClose = require(script.Parent:WaitForChild("ModalOutsideClose"))
local ModalCoordinator = require(script.Parent:WaitForChild("ModalCoordinator"))
local ModalPageTransition = require(script.Parent:WaitForChild("ModalPageTransition"))
local ModalResponsiveLayout = require(script.Parent:WaitForChild("ModalResponsiveLayout"))

local ctx = {}
ctx.preview = require(script.Parent:WaitForChild("WheelGooPreview"))

local MY = "Wheel"
local TINY_RESULT_MAX_SHORT_SIDE = 439
local TIGHT_CONDENSED_MAX_SHORT_SIDE = 570
local CONDENSED_WHEEL_MAX_SHORT_SIDE = 640
local FALLBACK_ACTIVE_COLOR = Color3.fromRGB(5, 142, 109)
local FALLBACK_MUTED_COLOR = Color3.fromRGB(150, 160, 175)
local WAIT_TIMEOUT = 10

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("WheelController must live inside a ScreenGui")
	return
end
if screenGui:GetAttribute("WheelControllerRunning") then
	return
end
screenGui:SetAttribute("WheelControllerRunning", true)

local player = Players.LocalPlayer
local modal = screenGui:WaitForChild("WheelModal", WAIT_TIMEOUT)
if not modal then
	warn("WheelController disabled: WheelModal not found")
	return
end

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Attrs = require(Shared:WaitForChild("Attrs"))
local GuiNames = require(Shared:WaitForChild("GuiNames"))
local UiMotion = require(Shared:WaitForChild("UiMotion"))
local NumberFormat = require(Shared:WaitForChild("NumberFormat"))
local WheelConfig = require(Shared:WaitForChild("WheelConfig"))
local DailyRewardConfig = require(Shared:WaitForChild("DailyRewardConfig"))

local function waitChild(parent, name)
	return parent and parent:WaitForChild(name, WAIT_TIMEOUT) or nil
end

local function waitDescendant(parent, name)
	if not parent then
		return nil
	end
	local found = parent:FindFirstChild(name, true)
	local deadline = tick() + WAIT_TIMEOUT
	while not found and tick() < deadline do
		task.wait(0.05)
		found = parent:FindFirstChild(name, true)
	end
	return found
end

local header = waitChild(modal, "Header")
local gcValue = header and header:FindFirstChild("GcPill", true)
gcValue = gcValue and (gcValue:FindFirstChild("Value") or gcValue)
local pages = waitChild(modal, "Pages")
if pages then
	-- UIPageLayout keeps every slot visible and positions inactive pages off-screen. Clip at the
	-- page viewport so moving WheelModal.Pages during a modal-to-modal swipe cannot expose an
	-- adjacent stale tab (Skins/Daily) over the incoming modal.
	pages.ClipsDescendants = true
end
local pageLayout = pages and pages:FindFirstChildOfClass("UIPageLayout")
local spinPage = waitDescendant(pages or modal, "SpinPage")
local skinsPage = waitDescendant(pages or modal, "SkinsPage")
local dailyPage = waitDescendant(pages or modal, "DailyPage")
local spinButton = waitChild(spinPage, "SpinButton") or (spinPage and spinPage:FindFirstChild("SpinButton", true))

-- Studio-authored action/selection references. Runtime copies their state properties only.
local stateReferences = modal:FindFirstChild("StateReferences")
local BUTTON_PROPERTIES = { "BackgroundColor3", "BackgroundTransparency", "TextColor3", "TextTransparency" }
local STROKE_PROPERTIES = { "Color", "Enabled", "Thickness", "Transparency" }

local function captureProperties(instance, properties)
	if not instance then
		return nil
	end
	local values = {}
	for _, property in ipairs(properties) do
		values[property] = instance[property]
	end
	return values
end

local function captureButtonStyle(reference)
	if not (reference and reference:IsA("TextButton")) then
		return nil
	end
	return {
		button = captureProperties(reference, BUTTON_PROPERTIES),
		stroke = captureProperties(reference:FindFirstChildWhichIsA("UIStroke"), STROKE_PROPERTIES),
	}
end

local function applyProperties(instance, values)
	if not (instance and values) then
		return
	end
	for property, value in pairs(values) do
		instance[property] = value
	end
end

local function applyButtonStyle(button, style)
	if not (button and button:IsA("TextButton") and style) then
		return
	end
	applyProperties(button, style.button)
	applyProperties(button:FindFirstChildWhichIsA("UIStroke"), style.stroke)
end

local authoredActionEnabled = captureButtonStyle(stateReferences and stateReferences:FindFirstChild("ActionEnabled"))
local authoredActionDisabled = captureButtonStyle(stateReferences and stateReferences:FindFirstChild("ActionDisabled"))
local authoredEquipOff = captureButtonStyle(stateReferences and stateReferences:FindFirstChild("EquipOff"))
local authoredEquipOn = captureButtonStyle(stateReferences and stateReferences:FindFirstChild("EquipOn"))
local authoredSelectAvailable = captureButtonStyle(
	stateReferences and stateReferences:FindFirstChild("SelectAvailable")
) or authoredEquipOff
local authoredSelected = captureButtonStyle(stateReferences and stateReferences:FindFirstChild("Selected"))
	or authoredEquipOn
local authoredLocked = captureButtonStyle(stateReferences and stateReferences:FindFirstChild("Locked"))
	or authoredActionDisabled

-- Tabs -------------------------------------------------------------------------
local tabBar = waitChild(modal, "TabBar")
local spinTab = tabBar and tabBar:FindFirstChild("SpinTab")
local skinsTab = tabBar and tabBar:FindFirstChild("SkinsTab")
local dailyTab = tabBar and tabBar:FindFirstChild("DailyTab")
local refreshDaily

local function captureTabStyle(tab)
	if not (tab and tab:IsA("TextButton")) then
		return nil
	end
	local underline = tab:FindFirstChild("Underline")
	return {
		textColor = tab.TextColor3,
		textTransparency = tab.TextTransparency,
		backgroundColor = tab.BackgroundColor3,
		backgroundTransparency = tab.BackgroundTransparency,
		underlineVisible = underline and underline.Visible or false,
		underlineColor = underline and underline.BackgroundColor3 or FALLBACK_ACTIVE_COLOR,
		underlineTransparency = underline and underline.BackgroundTransparency or 0,
	}
end

local authoredActiveTabStyle = captureTabStyle(spinTab)
local authoredInactiveTabStyle = captureTabStyle(skinsTab)

local function styleTab(tab, active)
	if not (tab and tab:IsA("TextButton")) then
		return
	end
	local style = active and authoredActiveTabStyle or authoredInactiveTabStyle
	tab.TextColor3 = style and style.textColor or (active and FALLBACK_ACTIVE_COLOR or FALLBACK_MUTED_COLOR)
	if style then
		tab.TextTransparency = style.textTransparency
		tab.BackgroundColor3 = style.backgroundColor
		tab.BackgroundTransparency = style.backgroundTransparency
	end
	local underline = tab:FindFirstChild("Underline")
	if underline then
		underline.Visible = style and style.underlineVisible or active
		if style then
			underline.BackgroundColor3 = style.underlineColor
			underline.BackgroundTransparency = style.underlineTransparency
		end
	end
end

local currentTab = "Spin"
local function setTab(name)
	currentTab = name
	local target = if name == "Skins" then skinsPage elseif name == "Daily" then dailyPage else spinPage
	if pageLayout and target and target.Parent and target.Parent.Parent == pages then
		pageLayout:JumpTo(target.Parent)
	else
		if spinPage then
			spinPage.Visible = name == "Spin"
		end
		if skinsPage then
			skinsPage.Visible = name == "Skins"
		end
		if dailyPage then
			dailyPage.Visible = name == "Daily"
		end
	end
	styleTab(spinTab, name == "Spin")
	styleTab(skinsTab, name == "Skins")
	styleTab(dailyTab, name == "Daily")
	local open = modal:GetAttribute(Attrs.Open) == true
	if ctx.reel then
		ctx.reel.setVisible(open and name == "Spin")
	end
	if ctx.collection then
		ctx.collection.setVisible(open and name == "Skins")
	end
	if name == "Daily" and refreshDaily then
		refreshDaily()
	end
end

for name, tab in pairs({ Spin = spinTab, Skins = skinsTab, Daily = dailyTab }) do
	if tab and tab:IsA("GuiButton") then
		tab.Activated:Connect(function()
			setTab(name)
		end)
	end
end

ctx.reel = require(script.Parent:WaitForChild("WheelReel")).bind({
	player = player,
	spinPage = spinPage,
	spinButton = spinButton,
	gcValue = gcValue,
	waitChild = waitChild,
	config = WheelConfig,
	net = Net,
	attrs = Attrs,
	uiMotion = UiMotion,
	numberFormat = NumberFormat,
	preview = ctx.preview,
	applyButtonStyle = applyButtonStyle,
	styles = { actionEnabled = authoredActionEnabled, actionDisabled = authoredActionDisabled },
})

-- Goo collection ---------------------------------------------------------------
local gooCollection = waitChild(skinsPage, "GooCollection")
local gooCardTemplate = waitChild(gooCollection, "GooSkinCardTemplate")
local buildingCollection = waitChild(skinsPage, "BuildingCollection")
local skinKindBar = waitChild(skinsPage, "SkinKindBar")
local gooKindTab = skinKindBar and skinKindBar:FindFirstChild("GooTab")
local buildingKindTab = skinKindBar and skinKindBar:FindFirstChild("BuildingsTab")
local bestBonusPill = waitChild(skinsPage, "BestBonusPill")

if skinKindBar then
	-- Keep the authored family switcher dormant until building skins have a complete
	-- collection/acquisition path. It can be revealed later without rebuilding the UI.
	skinKindBar.Visible = WheelConfig.FeatureFlags.BuildingSkinsEnabled
end
if buildingCollection then
	buildingCollection.Visible = false
end
if buildingKindTab then
	buildingKindTab.Visible = false
end
if gooCollection then
	gooCollection.Visible = true
end
if gooKindTab then
	gooKindTab:SetAttribute(Attrs.Active, true)
end

ctx.collection = require(script.Parent:WaitForChild("WheelCollection")).bind({
	player = player,
	collection = gooCollection,
	cardTemplate = gooCardTemplate,
	bestBonusPill = bestBonusPill,
	config = WheelConfig,
	net = Net,
	attrs = Attrs,
	preview = ctx.preview,
	applyButtonStyle = applyButtonStyle,
	styles = {
		selectAvailable = authoredSelectAvailable,
		selected = authoredSelected,
		locked = authoredLocked,
	},
})

-- Daily rewards ----------------------------------------------------------------
local daysHolder = waitChild(dailyPage, "Days")
local dayCardTemplate = waitChild(dailyPage, "DayCardTemplate")
local claimButton = waitChild(dailyPage, "ClaimButton")
local dailyStatus = waitChild(dailyPage, "Status")
local streakLabel = waitChild(dailyPage, "Streak")

local function currentUtcDay()
	return math.floor(os.time() / 86400)
end

local function readDailyInt(attribute)
	local value = player:GetAttribute(attribute)
	return typeof(value) == "number" and math.floor(value) or 0
end

local function dailyState()
	local today = currentUtcDay()
	local lastDay = readDailyInt(Attrs.LastLoginDay)
	local streak = readDailyInt(Attrs.LoginStreak)
	local pending = if lastDay == today then math.max(1, streak) elseif lastDay == today - 1 then streak + 1 else 1
	return {
		canClaim = lastDay ~= today,
		streak = streak,
		dayInCycle = DailyRewardConfig.GetDayInCycle(pending),
	}
end

local function formatCountdown(seconds)
	seconds = math.max(0, math.floor(seconds))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor(seconds % 3600 / 60)
	return hours > 0 and string.format("%dh %dm", hours, minutes) or string.format("%dm", math.max(1, minutes))
end

local function updateDailyStatus(state)
	if dailyStatus and dailyStatus:IsA("TextLabel") then
		dailyStatus.Text = state.canClaim and "Your daily reward is ready!"
			or ("Next reward in " .. formatCountdown(86400 - os.time() % 86400))
	end
end

local dayCards = {}
local function buildDayCards()
	if #dayCards > 0 or not (dayCardTemplate and daysHolder) then
		return
	end
	for index = 1, DailyRewardConfig.CycleLength do
		local reward = DailyRewardConfig.Cycle[index]
		local card = dayCardTemplate:Clone()
		card.Name = "DayCard"
		card.LayoutOrder = index
		card.Visible = true
		local dayLabel = card:FindFirstChild("DayLabel")
		local rewardLabel = card:FindFirstChild("Reward")
		if dayLabel and dayLabel:IsA("TextLabel") then
			dayLabel.Text = "Day " .. index
		end
		if rewardLabel and rewardLabel:IsA("TextLabel") then
			rewardLabel.Text = "+"
				.. NumberFormat.abbreviate((reward and reward.Gc) or 0)
				.. ((reward and reward.SkinId) and " + Skin" or "")
		end
		local preview = card:FindFirstChild("Preview")
		if preview and preview:IsA("ViewportFrame") then
			preview.Visible = reward and reward.SkinId ~= nil
			if reward and reward.SkinId then
				ctx.preview.Render(preview, reward.SkinId, { Lightweight = false })
			end
		end
		card.Parent = daysHolder
		dayCards[index] = card
	end
end

refreshDaily = function()
	buildDayCards()
	local state = dailyState()
	local claimedThrough = state.canClaim and state.dayInCycle - 1 or state.dayInCycle
	for index, card in ipairs(dayCards) do
		local check = card:FindFirstChild("Check")
		local highlight = card:FindFirstChild("Highlight")
		if check then
			check.Visible = index <= claimedThrough
		end
		if highlight then
			highlight.Visible = index == state.dayInCycle and state.canClaim
		end
	end
	if streakLabel and streakLabel:IsA("TextLabel") then
		streakLabel.Text = ("Day streak: %d"):format(state.streak)
	end
	if claimButton and claimButton:IsA("GuiButton") then
		claimButton.Active = state.canClaim
		claimButton.AutoButtonColor = state.canClaim
		if claimButton:IsA("TextButton") then
			applyButtonStyle(claimButton, state.canClaim and authoredActionEnabled or authoredActionDisabled)
			claimButton.Text = state.canClaim and ("Claim Day %d"):format(state.dayInCycle) or "Claimed"
		end
	end
	updateDailyStatus(state)
end

local claiming = false
if claimButton and claimButton:IsA("GuiButton") then
	claimButton.Activated:Connect(function()
		if claiming or not dailyState().canClaim then
			return
		end
		claiming = true
		if claimButton:IsA("TextButton") then
			claimButton.Text = "Claiming…"
		end
		task.spawn(function()
			local ok, result = pcall(function()
				return Net.invoke(Net.Names.ClaimDailyReward)
			end)
			claiming = false
			if dailyStatus and dailyStatus:IsA("TextLabel") then
				if ok and type(result) == "table" and result.Success then
					local message = "Claimed +" .. NumberFormat.abbreviate(result.RewardGC or 0) .. " GC!"
					if result.SkinId and result.SkinGranted then
						message ..= " Mythical skin unlocked!"
					end
					dailyStatus.Text = message
				elseif ok and type(result) == "table" and result.Reason == "AlreadyClaimed" then
					dailyStatus.Text = "Already claimed today."
				else
					dailyStatus.Text = "Claim failed — try again."
				end
			end
			refreshDaily()
		end)
	end)
end

task.spawn(function()
	while true do
		task.wait(1)
		if currentTab == "Daily" and modal:GetAttribute(Attrs.Open) == true then
			local state = dailyState()
			if not state.canClaim then
				updateDailyStatus(state)
			end
		end
	end
end)

-- Open/close -------------------------------------------------------------------
local function getResponsiveScale()
	local scale = modal:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "AnimScale"
		scale.Scale = 1
		scale.Parent = modal
	end
	return scale
end

local setVisible
local responsiveLayout = ModalResponsiveLayout.bind({
	modal = modal,
	close = function()
		if setVisible then
			setVisible(false)
		end
	end,
})
local function restScale()
	local scale = responsiveLayout.restScale()
	local compact = responsiveLayout.isCompact()
	local camera = Workspace.CurrentCamera
	local viewportSize = camera and camera.ViewportSize or Vector2.zero
	local shortSide = math.min(viewportSize.X, viewportSize.Y)
	local condensed = not compact and shortSide > 0 and shortSide < CONDENSED_WHEEL_MAX_SHORT_SIDE
	local tightCondensed = condensed and shortSide <= TIGHT_CONDENSED_MAX_SHORT_SIDE
	local tinyResult = compact and shortSide > 0 and shortSide < TINY_RESULT_MAX_SHORT_SIDE
	ctx.reel.setCompactLayout(compact, condensed, tightCondensed, tinyResult)
	return scale
end

local function resolveButton()
	local container = screenGui:FindFirstChild(GuiNames.Wheel, true)
	if not container then
		return nil, nil
	end
	local hitbox = container:FindFirstChild("Hitbox")
	if hitbox and hitbox:IsA("GuiButton") then
		return hitbox, container
	end
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("GuiButton") then
			return descendant, container
		end
	end
	return nil, container
end

local modalSlot = ModalCoordinator.register(MY, function()
	if modal:GetAttribute(Attrs.Open) then
		setVisible(false)
	end
end)

local activeTween
function setVisible(value)
	local previousOwner = ModalCoordinator.current()
	local deferCompactClose = not value and responsiveLayout.isCompact() and previousOwner == MY
	modal:SetAttribute(Attrs.Open, value)
	local _, container = resolveButton()
	if container then
		container:SetAttribute(Attrs.Active, value)
	end
	if value then
		modalSlot.open()
	elseif not deferCompactClose then
		modalSlot.close()
	end
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	local scale = getResponsiveScale()
	local rest = restScale()
	local restPosition = modal.Position
	scale.Scale = rest
	if value then
		ctx.collection.loadFromAttributes()
		modal.Visible = true
		setTab("Spin")
		ctx.reel.refresh()
		if responsiveLayout.isCompact() then
			activeTween = ModalPageTransition.openCompact(screenGui, modal, previousOwner, MY)
		else
			local switched
			activeTween, switched = ModalPageTransition.open(screenGui, modal, previousOwner, MY, restPosition)
			if not switched then
				activeTween = ModalPageTransition.openSession(scale, rest)
			end
		end
	else
		ctx.reel.setVisible(false)
		ctx.collection.setVisible(false)
		local function finishClose()
			if not modal:GetAttribute(Attrs.Open) then
				modal.Visible = false
			end
		end
		if responsiveLayout.isCompact() then
			if deferCompactClose then
				activeTween = ModalPageTransition.closeCompactAfterMenu(screenGui, function()
					modalSlot.close()
				end, finishClose)
			else
				activeTween =
					ModalPageTransition.closeCompact(screenGui, modal, MY, ModalCoordinator.current(), finishClose)
			end
		else
			local switched
			activeTween, switched =
				ModalPageTransition.close(screenGui, modal, MY, ModalCoordinator.current(), restPosition, finishClose)
			if not switched then
				activeTween = ModalPageTransition.closeSession(scale, rest, finishClose)
			end
		end
	end
end

screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
	ctx.reel.restartForMotionSetting()
end)

modal.Visible = false
modal:SetAttribute(Attrs.Open, false)
do
	local _, container = resolveButton()
	if container then
		container:SetAttribute(Attrs.Active, false)
	end
end

responsiveLayout.bindViewport(getResponsiveScale, function()
	return activeTween
end)

task.defer(function()
	local button = select(1, resolveButton())
	local deadline = tick() + 8
	while not button and tick() < deadline do
		task.wait(0.1)
		button = select(1, resolveButton())
	end
	if button then
		button.Activated:Connect(function()
			setVisible(not (modal:GetAttribute(Attrs.Open) == true))
		end)
	else
		warn("WheelController: Wheel button not found")
	end
end)

ModalOutsideClose.bind({
	modal = modal,
	isOpen = function()
		return modal:GetAttribute(Attrs.Open) == true
	end,
	close = function()
		setVisible(false)
	end,
	getIgnoreRoots = function()
		local button, container = resolveButton()
		return { button, container }
	end,
})
