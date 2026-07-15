-- SettingsController — logic only. The Settings modal (StarterGui.ScreenGui.
-- SettingsModal) with its grouped panels, icon/title/description rows and tick
-- checkboxes is authored in Studio; this binds the ticks and open/close behavior.
-- Preferences are mirrored as attributes on the ScreenGui so other controllers can
-- read them (ReducedMotionEnabled, etc.) and persisted by SettingsPersistence. Upgrade-owned
-- toggles such as Multi-Place live in the Store. Reset Stats lives in the bottom bar and is
-- driven by ResetStatsController. Only one of Help/Settings/Profile/Wheel is open at a time.
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))
local GuiNames = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GuiNames"))
local SettingsConfig =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SettingsConfig"))
local UserInputService = game:GetService("UserInputService")
local ModalOutsideClose = require(script.Parent:WaitForChild("ModalOutsideClose"))
local ModalCoordinator = require(script.Parent:WaitForChild("ModalCoordinator"))
local ModalPageTransition = require(script.Parent:WaitForChild("ModalPageTransition"))
local ModalResponsiveLayout = require(script.Parent:WaitForChild("ModalResponsiveLayout"))
local SettingsMusicWaveform = require(script.Parent:WaitForChild("SettingsMusicWaveform"))
local SettingsPersistence = require(script.Parent:WaitForChild("SettingsPersistence"))
local SettingsReducedMotionGlyph = require(script.Parent:WaitForChild("SettingsReducedMotionGlyph"))
local SettingsResetButton = require(script.Parent:WaitForChild("SettingsResetButton"))
local SettingsSfxGlyph = require(script.Parent:WaitForChild("SettingsSfxGlyph"))
local SettingsToggleGlyphs = require(script.Parent:WaitForChild("SettingsToggleGlyphs"))
local SettingsUpgradeReminderPulse = require(script.Parent:WaitForChild("SettingsUpgradeReminderPulse"))

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

local modal = screenGui:WaitForChild("SettingsModal", 10)
if not modal then
	warn("SettingsController disabled: SettingsModal not found")
	return
end
local body = modal:WaitForChild("Body")
local musicWaveform = SettingsMusicWaveform.new(body)
local reducedMotionGlyph = SettingsReducedMotionGlyph.new(body)
local sfxGlyph = SettingsSfxGlyph.new(body)
local upgradeReminderPulse = SettingsUpgradeReminderPulse.new(body)
local currentDeviceType =
	SettingsConfig.GetDeviceType(
		UserInputService.TouchEnabled,
		UserInputService.MouseEnabled,
		RunService:IsStudio() and UserInputService.PreferredInput == Enum.PreferredInput.Touch
	)

local SIMPLE = {
	ReducedMotion = Attrs.ReducedMotionEnabled,
	Music = Attrs.MusicEnabled,
	Sfx = Attrs.SfxEnabled,
	-- On-ground rotate/cancel/confirm pad during placement. Default is device-aware
	-- (see getDefault): on for touch-only devices, off when a mouse is present.
	PlacementControls = Attrs.PlacementControlsEnabled,
	UpgradeReminders = Attrs.UpgradeRemindersEnabled,
	-- Opening the store also enters build mode (and closing exits). Device-aware default
	-- (see getDefault): on for touch-only devices (no V key), off when a keyboard is present.
	AutoBuildMode = Attrs.AutoBuildMode,
}
local function getDefault(attr)
	if attr == Attrs.ReducedMotionEnabled then
		return false
	end
	-- Placement pad is opt-out on touch-only devices (no R/Esc/keyboard there) and
	-- opt-in when a mouse is present. The same rule lives in StoreController so the
	-- two agree regardless of which controller initializes the attribute first.
	if attr == Attrs.PlacementControlsEnabled then
		return currentDeviceType == SettingsConfig.DeviceType.Mobile
	end
	-- Auto build mode is opt-out on touch-only devices (tapping the store toggle is the only
	-- build affordance there) and opt-in on PC, where B and V are separate keys by default.
	if attr == Attrs.AutoBuildMode then
		return currentDeviceType == SettingsConfig.DeviceType.Mobile
	end
	return true
end
local function ensureAttr(attr)
	if screenGui:GetAttribute(attr) == nil then
		screenGui:SetAttribute(attr, getDefault(attr))
	end
end

-- ── Tick visuals ──────────────────────────────────────────────────────────────
-- ReducedMotion.Tick (legacy name: Animations.Tick) and Music.Tick are the
-- Studio-authored off/on references.
-- Runtime only captures those appearances and applies the matching state.
local function findRow(name)
	for _, panel in ipairs(body:GetChildren()) do
		local r = panel:IsA("Frame") and panel:FindFirstChild(name)
		if r then return r end
	end
	local found = body:FindFirstChild(name, true)
	-- UI instances are Studio-owned. Support the previous row name until the authored
	-- Animations row/title is renamed to ReducedMotion in Studio.
	if not found and name == "ReducedMotion" then
		return body:FindFirstChild("Animations", true)
	end
	return found
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

local TICK_STYLE_PROPERTIES = {
	"BackgroundColor3",
	"BackgroundTransparency",
	"TextColor3",
	"TextTransparency",
	"TextStrokeColor3",
	"TextStrokeTransparency",
}
local STROKE_STYLE_PROPERTIES = {
	"ApplyStrokeMode",
	"Color",
	"Enabled",
	"LineJoinMode",
	"Thickness",
	"Transparency",
}
local CHECK_STYLE_PROPERTIES = {
	"BackgroundColor3",
	"BackgroundTransparency",
	"Image",
	"ImageColor3",
	"ImageTransparency",
	"Visible",
}

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

local function applyProperties(instance, values)
	if not (instance and values) then
		return
	end
	for property, value in pairs(values) do
		instance[property] = value
	end
end

local function captureTickStyle(tick)
	return {
		tick = captureProperties(tick, TICK_STYLE_PROPERTIES),
		stroke = captureProperties(tick:FindFirstChildWhichIsA("UIStroke"), STROKE_STYLE_PROPERTIES),
		check = captureProperties(tick:FindFirstChild("Check"), CHECK_STYLE_PROPERTIES),
	}
end

local offReferenceRow = findRow("ReducedMotion")
local offReferenceTick = offReferenceRow and offReferenceRow:FindFirstChild("Tick")
local authoredOffStyle = offReferenceTick and captureTickStyle(offReferenceTick) or nil
local onReferenceRow = findRow("Music")
local onReferenceTick = onReferenceRow and onReferenceRow:FindFirstChild("Tick")
local authoredOnStyle = onReferenceTick and captureTickStyle(onReferenceTick) or nil

local function styleTick(row, state, offStyle, onStyle)
	local tick = row:FindFirstChild("Tick")
	if not tick then
		return
	end
	local check = tick:FindFirstChild("Check")
	local stroke = tick:FindFirstChildWhichIsA("UIStroke")
	local style = state == "on" and onStyle or offStyle
	applyProperties(tick, style.tick)
	applyProperties(stroke, style.stroke)
	applyProperties(check, style.check)
	tick.AutoButtonColor = false
	tick.Active = true
	tick.Selectable = true
end

-- ── Simple toggles ────────────────────────────────────────────────────────────
for rowName, attr in pairs(SIMPLE) do
	local row = findRow(rowName)
	local tick = row and row:FindFirstChild("Tick")
	if tick and tick:IsA("TextButton") then
		local offStyle = authoredOffStyle or captureTickStyle(tick)
		local onStyle = authoredOnStyle or offStyle
		ensureAttr(attr)
		local function refresh()
			styleTick(row, screenGui:GetAttribute(attr) and "on" or "off", offStyle, onStyle)
		end
		refresh()
		tick.Activated:Connect(function()
			screenGui:SetAttribute(attr, not (screenGui:GetAttribute(attr) == true))
		end)
		screenGui:GetAttributeChangedSignal(attr):Connect(refresh)
	end
end

local settingsPersistence = SettingsPersistence.new(screenGui, currentDeviceType)
SettingsResetButton.new(body, function()
	settingsPersistence.resetToDefaults(getDefault)
end)
SettingsToggleGlyphs.new(body, screenGui)

local function updateUpgradeReminderPulse()
	local modalOpen = modal:GetAttribute(Attrs.Open) == true
	local enabled = screenGui:GetAttribute(Attrs.UpgradeRemindersEnabled) == true
	local reduced = screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
	upgradeReminderPulse.setState(enabled, modalOpen and enabled and not reduced)
end
screenGui:GetAttributeChangedSignal(Attrs.UpgradeRemindersEnabled):Connect(updateUpgradeReminderPulse)

local function updateReducedMotionGlyph(animate)
	local enabled = screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
	local modalOpen = modal:GetAttribute(Attrs.Open) == true
	reducedMotionGlyph.setEnabled(enabled, animate == true and modalOpen)
end
screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
	updateReducedMotionGlyph(true)
	updateUpgradeReminderPulse()
end)
updateReducedMotionGlyph(false)

local function updateSfxGlyph(animate)
	local enabled = screenGui:GetAttribute(Attrs.SfxEnabled) == true
	local modalOpen = modal:GetAttribute(Attrs.Open) == true
	sfxGlyph.setEnabled(enabled, animate == true and modalOpen)
end
screenGui:GetAttributeChangedSignal(Attrs.SfxEnabled):Connect(function()
	updateSfxGlyph(true)
end)
updateSfxGlyph(false)

local function updateMusicWaveform()
	local enabled = modal:GetAttribute(Attrs.Open) == true
		and screenGui:GetAttribute(Attrs.MusicEnabled) == true
	local animate = enabled and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) ~= true
	musicWaveform.setState(enabled, animate)
end
screenGui:GetAttributeChangedSignal(Attrs.MusicEnabled):Connect(updateMusicWaveform)
screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
	updateMusicWaveform()
	updateSfxGlyph(false)
end)

-- ── Open / close (+ single-open coordination) ─────────────────────────────────
local function getResponsiveScale()
	local s = modal:FindFirstChild("AnimScale")
	if not s or not s:IsA("UIScale") then
		s = modal:FindFirstChildOfClass("UIScale")
		if not s then
			s = Instance.new("UIScale")
			s.Name = "AnimScale"
			s.Scale = 1
			s.Parent = modal
		end
	end
	return s
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
	return responsiveLayout.restScale()
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

-- Single-open coordination: only one main modal is open at a time.
local modalSlot = ModalCoordinator.register(MY, function()
	if modal:GetAttribute(Attrs.Open) then
		setVisible(false)
	end
end)

local activeTween
local previousSelection
local gamepadFocusOwned = false

local function firstSettingControl()
	local firstRow = findRow("ReducedMotion")
	local firstTick = firstRow and firstRow:FindFirstChild("Tick")
	if firstTick and firstTick:IsA("GuiButton") and firstTick.Selectable then
		return firstTick
	end
	return body
end

function setVisible(value)
	local previousOwner = ModalCoordinator.current()
	local deferCompactClose = not value and responsiveLayout.isCompact() and previousOwner == MY
	modal:SetAttribute(Attrs.Open, value)
	local _, container = resolveButton()
	if container then container:SetAttribute(Attrs.Active, value) end

	if value then
		modalSlot.open()
	elseif not deferCompactClose then
		modalSlot.close()
	end

	if activeTween then activeTween:Cancel(); activeTween = nil end
	local scale = getResponsiveScale()
	local rest = restScale()
	local restPosition = modal.Position
	scale.Scale = rest
	if value then
		modal.Visible = true
		updateMusicWaveform()
		updateSfxGlyph(false)
		updateReducedMotionGlyph(false)
		updateUpgradeReminderPulse()
		if UserInputService.PreferredInput == Enum.PreferredInput.Gamepad then
			previousSelection = GuiService.SelectedObject
			gamepadFocusOwned = true
			task.defer(function()
				if modal:GetAttribute(Attrs.Open) then
					GuiService.SelectedObject = firstSettingControl()
				end
			end)
		end
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
		updateMusicWaveform()
		updateSfxGlyph(false)
		updateReducedMotionGlyph(false)
		updateUpgradeReminderPulse()
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
			activeTween, switched = ModalPageTransition.close(
				screenGui,
				modal,
				MY,
				ModalCoordinator.current(),
				restPosition,
				finishClose
			)
			if not switched then
				activeTween = ModalPageTransition.closeSession(scale, rest, finishClose)
			end
		end
	end
end

responsiveLayout.bindViewport(getResponsiveScale, function()
	return activeTween
end)

do
	local replayRow = findRow("ReplayIntro")
	local replayButton = replayRow and replayRow:FindFirstChild("Replay")
	if replayButton and replayButton:IsA("GuiButton") then
		replayButton.Activated:Connect(function()
			setVisible(false)
			task.delay(0.08, function()
				getReplayIntroEvent():Fire()
			end)
		end)
	else
		warn("SettingsController: Studio-authored ReplayIntro.Replay button not found")
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
		button.Activated:Connect(function()
			setVisible(not (modal:GetAttribute(Attrs.Open) == true))
		end)
	else
		warn("SettingsController: Settings button not found")
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
