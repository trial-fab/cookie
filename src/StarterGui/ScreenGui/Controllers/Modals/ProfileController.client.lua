-- ProfileController — logic only. The Profile modal (StarterGui.ScreenGui.
-- ProfileModal) — avatar header, big stat numbers, production panel, equipped-skin
-- slots and ghost bottom-bar pills — is authored in Studio. This drives the values
-- from live replicated data (leaderstats, player attributes, UpgradeCountData) and
-- the open/close behavior. Skins/achievements are Phase 2/6 placeholders. The
-- Profile menu icon tints to 0,170,255 while the modal is open (active, not hover).
-- Only one of Help/Settings/Profile is open at a time via ScreenGui.OpenModal.
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))
local UserInputService = game:GetService("UserInputService")
local ModalOutsideClose = require(script.Parent:WaitForChild("ModalOutsideClose"))
local ModalCoordinator = require(script.Parent:WaitForChild("ModalCoordinator"))

local MY = "Profile"
local ACTIVE_COLOR = Color3.fromRGB(0, 170, 255)

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("ProfileController must live inside a ScreenGui")
	return
end
if screenGui:GetAttribute("ProfileControllerRunning") then
	return
end
screenGui:SetAttribute("ProfileControllerRunning", true)

local player = Players.LocalPlayer
local modal = screenGui:WaitForChild("ProfileModal", 10)
if not modal then
	warn("ProfileController disabled: ProfileModal not found")
	return
end

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormat = require(Shared:WaitForChild("NumberFormat"))
local Attrs = require(Shared:WaitForChild("Attrs"))
local GuiNames = require(Shared:WaitForChild("GuiNames"))
local UpgradeConfig = require(Shared:WaitForChild("UpgradeConfig"))
local MobileScale = require(Shared:WaitForChild("MobileScale"))

local scaleInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local body = modal:WaitForChild("Body")

local function abbreviate(n)
	n = typeof(n) == "number" and n or 0
	return NumberFormat.abbreviate(n)
end

local function setNumber(frameName, text)
	local f = body:FindFirstChild(frameName, true)
	local lbl = f and (f:FindFirstChild("Number") or f:FindFirstChild("Value"))
	if lbl and lbl:IsA("TextLabel") then lbl.Text = text end
end

-- ── Live data ──
local leaderstats = player:WaitForChild("leaderstats", 10)
local upgradeCountData = player:WaitForChild("UpgradeCountData", 10)

local buildingIds = {}
for id, config in pairs(UpgradeConfig) do
	if type(config) == "table" and config.TemplateKind == "Building" then
		buildingIds[id] = true
	end
end
local function countBuildings()
	local total = 0
	if upgradeCountData then
		for id in pairs(buildingIds) do
			local v = upgradeCountData:FindFirstChild(id)
			if v and v:IsA("IntValue") then total += v.Value end
		end
	end
	return total
end

-- Avatar thumbnail (set once).
do
	local avatar = body:FindFirstChild("Avatar", true)
	if avatar and avatar:IsA("ImageLabel") then
		avatar.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(player.UserId)
	end
	local uname = body:FindFirstChild("Username", true)
	if uname and uname:IsA("TextLabel") then
		uname.Text = player.DisplayName ~= "" and player.DisplayName or player.Name
	end
end

local function refresh()
	if not modal.Visible then return end
	local cookies = leaderstats and leaderstats:FindFirstChild("Cookies")
	local cps = tonumber(player:GetAttribute(Attrs.Cps)) or 0
	local perClick = player:FindFirstChild("CookiesGainedPerClick")
	local buildings = countBuildings()
	local playTime = leaderstats and leaderstats:FindFirstChild("Play Time")

	setNumber("Cookies", abbreviate(cookies and cookies.Value or 0))
	setNumber("Cps", abbreviate(cps))
	setNumber("PerClick", abbreviate(perClick and perClick.Value or 0))
	setNumber("Golden", abbreviate(player:GetAttribute(Attrs.GoldenCookies)))

	setNumber("Buildings", tostring(buildings))
	setNumber("Cpm", abbreviate(cps * 60))
	setNumber("PlayTime", playTime and tostring(playTime.Value) or "00:00")

	local pill = body:FindFirstChild("BuildingsPill", true)
	local pillVal = pill and pill:FindFirstChild("Value")
	if pillVal then pillVal.Text = buildings .. (buildings == 1 and " Building" or " Buildings") end
	local subtitle = body:FindFirstChild("Subtitle", true)
	if subtitle then subtitle.Text = "Played " .. (playTime and tostring(playTime.Value) or "00:00") end
end

-- Live updates while open.
do
	local function connect(inst, prop)
		if inst then inst:GetPropertyChangedSignal(prop):Connect(refresh) end
	end
	if leaderstats then
		connect(leaderstats:FindFirstChild("Cookies"), "Value")
		connect(leaderstats:FindFirstChild("Play Time"), "Value")
	end
	connect(player:FindFirstChild("CookiesGainedPerClick"), "Value")
	player:GetAttributeChangedSignal(Attrs.Cps):Connect(refresh)
	player:GetAttributeChangedSignal(Attrs.GoldenCookies):Connect(refresh)
	if upgradeCountData then
		upgradeCountData.ChildAdded:Connect(function(child)
			child:GetPropertyChangedSignal("Value"):Connect(refresh)
			refresh()
		end)
		for _, child in ipairs(upgradeCountData:GetChildren()) do
			child:GetPropertyChangedSignal("Value"):Connect(refresh)
		end
	end
end

-- ── Profile icon active tint ──
local function getProfileImage()
	local container = screenGui:FindFirstChild(GuiNames.Profile, true)
	if not container then return nil end
	local img = container:FindFirstChild(GuiNames.ProfileButton)
	if img and img:IsA("ImageButton") then return img end
	return container:FindFirstChildWhichIsA("ImageButton", true)
end
local function setIconActive(active)
	local img = getProfileImage()
	if img then img.ImageColor3 = active and ACTIVE_COLOR or Color3.fromRGB(255, 255, 255) end
end

-- ── Open / close (+ single-open coordination) ──
local function getAnimScale()
	local s = modal:FindFirstChild("AnimScale")
	if not s or not s:IsA("UIScale") then
		s = Instance.new("UIScale"); s.Name = "AnimScale"; s.Scale = 1; s.Parent = modal
	end
	return s
end
-- Resting scale: the shared continuous responsive factor (1 at 1080p, smaller on phones).
-- The open/close pop is expressed RELATIVE to this so both compose on the single AnimScale
-- UIScale (Roblox honours only one UIScale per object).
-- Captured once before the first resolveModal call (which rewrites modal.Size on mobile).
local designSize = Vector2.new(modal.Size.X.Offset, modal.Size.Y.Offset)
local function restScale()
	return MobileScale.resolveModal(modal, designSize, {
		mobileScale = 0.82,
		nativeTextDesktop = true,
	})
end
local function resolveButton()
	local container = screenGui:FindFirstChild(GuiNames.Profile, true)
	if not container then return nil, nil end
	local hitbox = container:FindFirstChild("Hitbox")
	if hitbox and hitbox:IsA("GuiButton") then return hitbox, container end
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("GuiButton") then return d, container end
	end
	return nil, container
end

-- Single-open coordination: only one of Help/Settings/Profile open at a time.
local setVisible
local modalSlot = ModalCoordinator.register(MY, function()
	if modal:GetAttribute(Attrs.Open) then
		setVisible(false)
	end
end)

local activeTween
local previousSelection
local gamepadFocusOwned = false

function setVisible(value)
	modal:SetAttribute(Attrs.Open, value)
	local _, container = resolveButton()
	if container then container:SetAttribute(Attrs.Active, value) end
	setIconActive(value)

	if value then
		modalSlot.open()
	else
		modalSlot.close()
	end

	if activeTween then activeTween:Cancel(); activeTween = nil end
	local animate = true -- Short modal transition intentionally remains under Reduced Motion.
	local scale = getAnimScale()
	if value then
		modal.Visible = true
		refresh()
		if UserInputService.PreferredInput == Enum.PreferredInput.Gamepad then
			previousSelection = GuiService.SelectedObject
			gamepadFocusOwned = true
			task.defer(function()
				if modal:GetAttribute(Attrs.Open) then
					GuiService.SelectedObject = body
				end
			end)
		end
		local rest = restScale()
		if animate then
			scale.Scale = rest * 0.92
			activeTween = UiMotion.create(scale, scaleInfo, { Scale = rest })
			activeTween:Play()
		else
			scale.Scale = rest
		end
	else
		if gamepadFocusOwned then
			gamepadFocusOwned = false
			local restore = previousSelection
			previousSelection = nil
			if not (restore and restore.Parent and restore:IsA("GuiObject") and restore.Selectable) then
				restore = select(1, resolveButton())
			end
			task.defer(function()
				if restore and restore.Parent and restore:IsA("GuiObject") and restore.Selectable then
					GuiService.SelectedObject = restore
				end
			end)
		end
		if animate then
			activeTween = UiMotion.create(scale, scaleInfo, { Scale = restScale() * 0.92 })
			activeTween.Completed:Once(function()
				if not modal:GetAttribute(Attrs.Open) then modal.Visible = false end
				scale.Scale = restScale()
			end)
			activeTween:Play()
		else
			modal.Visible = false
		end
	end
end

modal.Visible = false
modal:SetAttribute(Attrs.Open, false)

-- Keep the resting scale right across viewport/orientation changes. Skip while a pop tween
-- is mid-flight (it lands on restScale() itself) so we don't snap over the animation.
MobileScale.onViewportChanged(function()
	local rest = restScale() -- also re-lays out size + position for the current viewport
	-- Skip only while a pop is actually animating; a finished tween lingers non-nil and must not
	-- block live re-scaling when the window is resized.
	if activeTween and activeTween.PlaybackState == Enum.PlaybackState.Playing then return end
	getAnimScale().Scale = rest
end)

task.defer(function()
	local button = select(1, resolveButton())
	if not button then
		local deadline = tick() + 8
		repeat task.wait(0.1); button = select(1, resolveButton()) until button or tick() > deadline
	end
	if button then
		button.Activated:Connect(function()
			setVisible(not (modal:GetAttribute(Attrs.Open) == true))
		end)
	else
		warn("ProfileController: Profile button not found")
	end
end)

UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.ButtonB and modal:GetAttribute(Attrs.Open) == true then
		setVisible(false)
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
