-- SettingsController — logic only. The Settings modal (StarterGui.ScreenGui.
-- SettingsModal) with its grouped panels, icon/title/description rows and tick
-- checkboxes is authored in Studio; this binds the ticks and open/close behavior.
-- Preferences are stored as attributes on the ScreenGui so other controllers can
-- read them (ReducedMotionEnabled, etc.). Upgrade-owned toggles such as Multi-Place
-- live in the Store. Reset Stats lives in the bottom bar and is driven by
-- ResetStatsController. Only one of Help/Settings/Profile is open at a time.
local GuiService = game:GetService("GuiService")
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))
local GuiNames = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GuiNames"))
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))
local UserInputService = game:GetService("UserInputService")
local ModalOutsideClose = require(script.Parent:WaitForChild("ModalOutsideClose"))
local ModalCoordinator = require(script.Parent:WaitForChild("ModalCoordinator"))
local SettingsAnimationGlyph = require(script.Parent:WaitForChild("SettingsAnimationGlyph"))
local SettingsMusicWaveform = require(script.Parent:WaitForChild("SettingsMusicWaveform"))
local SettingsSfxGlyph = require(script.Parent:WaitForChild("SettingsSfxGlyph"))
local SettingsUpgradeReminderPulse = require(script.Parent:WaitForChild("SettingsUpgradeReminderPulse"))
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

local modal = screenGui:WaitForChild("SettingsModal", 10)
if not modal then
	warn("SettingsController disabled: SettingsModal not found")
	return
end
local body = modal:WaitForChild("Body")
local animationGlyph = SettingsAnimationGlyph.new(body)
local musicWaveform = SettingsMusicWaveform.new(body)
local sfxGlyph = SettingsSfxGlyph.new(body)
local upgradeReminderPulse = SettingsUpgradeReminderPulse.new(body)

local scaleInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

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

local function updateUpgradeReminderPulse()
	local modalOpen = modal:GetAttribute(Attrs.Open) == true
	local enabled = screenGui:GetAttribute(Attrs.UpgradeRemindersEnabled) == true
	local reduced = screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
	upgradeReminderPulse.setState(enabled, modalOpen and enabled and not reduced, modalOpen and reduced)
end
screenGui:GetAttributeChangedSignal(Attrs.UpgradeRemindersEnabled):Connect(updateUpgradeReminderPulse)

local function updateAnimationGlyph()
	local active = modal:GetAttribute(Attrs.Open) == true
		and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) ~= true
	animationGlyph.setActive(active)
end
screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
	updateAnimationGlyph()
	updateUpgradeReminderPulse()
end)

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
	return MobileScale.resolveModal(modal, designSize, {
		mobileScale = 0.82,
		nativeTextDesktop = true,
	})
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
	modal:SetAttribute(Attrs.Open, value)
	local _, container = resolveButton()
	if container then container:SetAttribute(Attrs.Active, value) end

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
		updateMusicWaveform()
		updateSfxGlyph(false)
		updateAnimationGlyph()
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
		local rest = restScale()
		if animate then
			scale.Scale = rest * 0.92
			activeTween = UiMotion.create(scale, scaleInfo, { Scale = rest })
			activeTween:Play()
		else
			scale.Scale = rest
		end
	else
		updateMusicWaveform()
		updateSfxGlyph(false)
		updateAnimationGlyph()
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
