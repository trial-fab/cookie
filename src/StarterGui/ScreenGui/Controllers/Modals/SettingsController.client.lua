-- SettingsController — logic only. The Settings modal (StarterGui.ScreenGui.
-- SettingsModal) with its grouped panels, icon/title/description rows and tick
-- checkboxes is authored in Studio; this binds the ticks and open/close behavior.
-- Preferences are stored as attributes on the ScreenGui so other controllers can
-- read them (AnimationsEnabled, etc.). Multi-Place ticks are gated on
-- the §4c entitlements the server replicates onto player.UpgradeCountData and show
-- a ghosted tick while locked. Reset Stats lives in the bottom bar and is driven by
-- ResetStatsController. Only one of Help/Settings/Profile is open at a time, via the
-- shared ScreenGui "OpenModal" attribute.
local Players = game:GetService("Players")
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))
local GuiNames = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GuiNames"))
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ModalOutsideClose = require(script.Parent:WaitForChild("ModalOutsideClose"))
local ModalCoordinator = require(script.Parent:WaitForChild("ModalCoordinator"))
local MobileScale = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MobileScale"))

local MY = "Settings"
local INTRO_REPLAY_EVENT_NAME = "ReplayIntroRequested"

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("SettingsController must live inside a ScreenGui")
	return
end
if screenGui:GetAttribute("SettingsControllerRunning") then
	return
end
screenGui:SetAttribute("SettingsControllerRunning", true)

local player = Players.LocalPlayer
local modal = screenGui:WaitForChild("SettingsModal", 10)
if not modal then
	warn("SettingsController disabled: SettingsModal not found")
	return
end
local body = modal:WaitForChild("Body")

local scaleInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ACCENT = Color3.fromRGB(0, 170, 255)
local OFF_BG = Color3.fromRGB(36, 40, 51)
local STROKE_OFF = Color3.fromRGB(70, 78, 94)
local TEXT = Color3.fromRGB(244, 247, 252)
local MUTED = Color3.fromRGB(150, 160, 175)

local SIMPLE = {
	Animations = Attrs.AnimationsEnabled,
	Music = "MusicEnabled",
	Sfx = "SfxEnabled",
	-- On-ground rotate/cancel/confirm pad during placement. Default is device-aware
	-- (see getDefault): on for touch-only devices, off when a mouse is present.
	PlacementControls = Attrs.PlacementControlsEnabled,
	UpgradeReminders = Attrs.UpgradeRemindersEnabled,
	-- Opening the store also enters build mode (and closing exits). Device-aware default
	-- (see getDefault): on for touch-only devices (no V key), off when a keyboard is present.
	AutoBuildMode = Attrs.AutoBuildMode,
}
local GATED = {
	MultiPlace = { attribute = Attrs.MultiPlaceEnabled, entitlement = "Multi-Place" },
}

local function getDefault(attr)
	if attr == Attrs.MultiPlaceEnabled then
		return false
	end
	-- Placement pad is opt-out on touch-only devices (no R/Esc/keyboard there) and
	-- opt-in when a mouse is present. The same rule lives in StoreController so the
	-- two agree regardless of which controller initializes the attribute first.
	if attr == "PlacementControlsEnabled" then
		return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	end
	-- Auto build mode is opt-out on touch-only devices (tapping the store toggle is the only
	-- build affordance there) and opt-in on PC, where B and V are separate keys by default.
	if attr == Attrs.AutoBuildMode then
		return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	end
	return true
end
local function ensureAttr(attr)
	if screenGui:GetAttribute(attr) == nil then
		screenGui:SetAttribute(attr, getDefault(attr))
	end
end

local upgradeCountData = player:WaitForChild("UpgradeCountData", 10)
local function ownsEntitlement(upgradeId)
	if not upgradeCountData then return false end
	local v = upgradeCountData:FindFirstChild(upgradeId)
	return v ~= nil and v:IsA("IntValue") and v.Value > 0
end

local function getPreference(attr)
	local playerValue = player:GetAttribute(attr)
	if type(playerValue) == "boolean" then
		return playerValue
	end

	local guiValue = screenGui:GetAttribute(attr)
	if type(guiValue) == "boolean" then
		return guiValue
	end

	return nil
end

local function setPreference(attr, value)
	value = value == true
	player:SetAttribute(attr, value)
	screenGui:SetAttribute(attr, value)
end

-- ── Tick visuals ──────────────────────────────────────────────────────────────
-- state: "on" | "off" | "ghost"
local function findRow(name)
	for _, panel in ipairs(body:GetChildren()) do
		local r = panel:IsA("Frame") and panel:FindFirstChild(name)
		if r then return r end
	end
	return body:FindFirstChild(name, true)
end

local function getReplayIntroEvent()
	local existing = screenGui:FindFirstChild(INTRO_REPLAY_EVENT_NAME)
	if existing and existing:IsA("BindableEvent") then
		return existing
	end
	local event = Instance.new("BindableEvent")
	event.Name = INTRO_REPLAY_EVENT_NAME
	event.Parent = screenGui
	return event
end

local function getGeneralPanel()
	for _, child in ipairs(body:GetChildren()) do
		if child:IsA("Frame") and child.Name == "Panel" then
			return child
		end
	end
	return nil
end

local function createReplayIntroRow()
	local existing = findRow("ReplayIntro")
	if existing then
		return existing
	end

	local panel = getGeneralPanel()
	if not panel then
		return nil
	end

	local row = Instance.new("Frame")
	row.Name = "ReplayIntro"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 58)
	row.LayoutOrder = 60
	row.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = row

	local icon = Instance.new("Frame")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	icon.Size = UDim2.fromOffset(34, 34)
	icon.BackgroundColor3 = Color3.fromRGB(26, 35, 52)
	icon.BackgroundTransparency = 0.05
	icon.Parent = row
	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(0, 8)
	iconCorner.Parent = icon
	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.Font = Enum.Font.GothamBold
	glyph.Text = ">"
	glyph.TextColor3 = TEXT
	glyph.TextSize = 20
	glyph.Parent = icon

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(46, 6)
	title.Size = UDim2.new(1, -160, 0, 22)
	title.Font = Enum.Font.GothamBold
	title.Text = "Replay Chapter 1"
	title.TextColor3 = TEXT
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = row

	local desc = Instance.new("TextLabel")
	desc.Name = "Desc"
	desc.BackgroundTransparency = 1
	desc.Position = UDim2.fromOffset(46, 29)
	desc.Size = UDim2.new(1, -160, 0, 20)
	desc.Font = Enum.Font.Gotham
	desc.Text = "Replay the meteor, alien rescue, lore, and first build"
	desc.TextColor3 = MUTED
	desc.TextSize = 13
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.TextTruncate = Enum.TextTruncate.AtEnd
	desc.Parent = row

	local button = Instance.new("TextButton")
	button.Name = "Replay"
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, 0, 0.5, 0)
	button.Size = UDim2.fromOffset(92, 32)
	button.BackgroundColor3 = ACCENT
	button.Text = "Replay"
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 14
	button.AutoButtonColor = true
	button.Parent = row
	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 8)
	buttonCorner.Parent = button

	return row
end

local function styleTick(row, state)
	local tick = row:FindFirstChild("Tick")
	if not tick then return end
	local check = tick:FindFirstChild("Check")
	local box = tick:FindFirstChild("Box")
	local title = row:FindFirstChild("Title")
	local desc = row:FindFirstChild("Desc")
	local glyph = row:FindFirstChild("Icon") and row.Icon:FindFirstChild("Glyph")

	local dim = state == "ghost"
	if title then title.TextTransparency = dim and 0.5 or 0 end
	if desc then desc.TextTransparency = dim and 0.55 or 0 end
	if glyph then glyph.TextTransparency = dim and 0.5 or 0 end

	if state == "on" then
		tick.BackgroundColor3 = ACCENT
		tick.BackgroundTransparency = 0
		if box then box.Transparency = 1 end
		if check then check.Visible = true; check.TextTransparency = 0 end
		tick.AutoButtonColor = false
		tick.Active = true
	elseif state == "off" then
		tick.BackgroundColor3 = OFF_BG
		tick.BackgroundTransparency = 0.5
		if box then box.Transparency = 0; box.Color = STROKE_OFF end
		if check then check.Visible = false end
		tick.Active = true
	else -- ghost (locked)
		tick.BackgroundColor3 = OFF_BG
		tick.BackgroundTransparency = 0.7
		if box then box.Transparency = 0.6; box.Color = STROKE_OFF end
		if check then check.Visible = true; check.TextTransparency = 0.6 end
		tick.Active = false
	end
end

-- ── Simple toggles ────────────────────────────────────────────────────────────
for rowName, attr in pairs(SIMPLE) do
	local row = findRow(rowName)
	local tick = row and row:FindFirstChild("Tick")
	if tick and tick:IsA("TextButton") then
		ensureAttr(attr)
		local function refresh()
			styleTick(row, screenGui:GetAttribute(attr) and "on" or "off")
		end
		refresh()
		tick.MouseButton1Click:Connect(function()
			screenGui:SetAttribute(attr, not (screenGui:GetAttribute(attr) == true))
		end)
		screenGui:GetAttributeChangedSignal(attr):Connect(refresh)
	end
end

-- ── Gated toggles ─────────────────────────────────────────────────────────────
for rowName, def in pairs(GATED) do
	local row = findRow(rowName)
	local tick = row and row:FindFirstChild("Tick")
	if tick and tick:IsA("TextButton") then
		local desc = row:FindFirstChild("Desc")
		local descDefault = desc and desc.Text

		local function refresh()
			if not ownsEntitlement(def.entitlement) then
				if screenGui:GetAttribute(def.attribute) ~= false then
					screenGui:SetAttribute(def.attribute, false)
				end
				if desc then desc.Text = "Unlock in the store" end
				styleTick(row, "ghost")
			else
				local preference = getPreference(def.attribute)
				if preference == nil then
					setPreference(def.attribute, true)
					preference = true
				elseif screenGui:GetAttribute(def.attribute) ~= preference then
					screenGui:SetAttribute(def.attribute, preference)
				end
				if desc and descDefault then desc.Text = descDefault end
				styleTick(row, preference and "on" or "off")
			end
		end
		refresh()
		tick.MouseButton1Click:Connect(function()
			if not ownsEntitlement(def.entitlement) then return end
			setPreference(def.attribute, not (getPreference(def.attribute) == true))
		end)
		screenGui:GetAttributeChangedSignal(def.attribute):Connect(refresh)
		player:GetAttributeChangedSignal(def.attribute):Connect(refresh)

		if upgradeCountData then
			local function watch(child)
				if child.Name == def.entitlement and child:IsA("IntValue") then
					child:GetPropertyChangedSignal("Value"):Connect(refresh)
					refresh()
				end
			end
			for _, child in ipairs(upgradeCountData:GetChildren()) do watch(child) end
			upgradeCountData.ChildAdded:Connect(watch)
		end
	end
end

-- ── Open / close (+ single-open coordination) ─────────────────────────────────
local function getAnimScale()
	local s = modal:FindFirstChild("AnimScale")
	if not s or not s:IsA("UIScale") then
		s = Instance.new("UIScale")
		s.Name = "AnimScale"
		s.Scale = 1
		s.Parent = modal
	end
	return s
end

-- Resting scale: the shared continuous responsive factor (1 at 1080p, smaller on phones).
-- The open/close pop is expressed RELATIVE to this so both compose on the single AnimScale
-- UIScale (Roblox honours only one UIScale per object).
-- Captured once before the first resolveModal call (which rewrites modal.Size on mobile).
local designSize = Vector2.new(modal.Size.X.Offset, modal.Size.Y.Offset)
local function restScale()
	return MobileScale.resolveModal(modal, designSize)
end

local function resolveButton()
	local container = screenGui:FindFirstChild(GuiNames.Settings, true)
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
function setVisible(value)
	modal:SetAttribute(Attrs.Open, value)
	local _, container = resolveButton()
	if container then container:SetAttribute(Attrs.Active, value) end

	if value then
		modalSlot.open()
	else
		modalSlot.close()
	end

	if activeTween then activeTween:Cancel(); activeTween = nil end
	local animate = screenGui:GetAttribute(Attrs.AnimationsEnabled) ~= false
	local scale = getAnimScale()
	if value then
		modal.Visible = true
		local rest = restScale()
		if animate then
			scale.Scale = rest * 0.92
			activeTween = TweenService:Create(scale, scaleInfo, { Scale = rest })
			activeTween:Play()
		else
			scale.Scale = rest
		end
	else
		if animate then
			activeTween = TweenService:Create(scale, scaleInfo, { Scale = restScale() * 0.92 })
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

-- Keep the resting scale right across viewport/orientation changes. Skip while a pop tween
-- is mid-flight (it lands on restScale() itself) so we don't snap over the animation.
MobileScale.onViewportChanged(function()
	local rest = restScale() -- also re-lays out size + position for the current viewport
	-- Skip only while a pop is actually animating; a finished tween lingers non-nil and must not
	-- block live re-scaling when the window is resized.
	if activeTween and activeTween.PlaybackState == Enum.PlaybackState.Playing then return end
	getAnimScale().Scale = rest
end)

do
	local replayRow = createReplayIntroRow()
	local replayButton = replayRow and replayRow:FindFirstChild("Replay")
	if replayButton and replayButton:IsA("TextButton") then
		replayButton.MouseButton1Click:Connect(function()
			setVisible(false)
			task.delay(0.08, function()
				getReplayIntroEvent():Fire()
			end)
		end)
	end
end

modal.Visible = false
modal:SetAttribute(Attrs.Open, false)
-- Own the gear/face "Active" state from the start (cleared = closed).
do
	local _, container = resolveButton()
	if container then container:SetAttribute(Attrs.Active, false) end
end

task.defer(function()
	local button = select(1, resolveButton())
	if not button then
		local deadline = tick() + 8
		repeat task.wait(0.1); button = select(1, resolveButton()) until button or tick() > deadline
	end
	if button then
		button.MouseButton1Click:Connect(function()
			setVisible(not (modal:GetAttribute(Attrs.Open) == true))
		end)
	else
		warn("SettingsController: Settings button not found")
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
