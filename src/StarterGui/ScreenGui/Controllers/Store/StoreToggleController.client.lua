-- StoreToggleController: orchestrator that owns the StoreBottom band's open/close state.
--
-- The store band was decoupled from build mode: it is now driven by its own ScreenGui StoreOpen
-- attribute, which this controller owns. Several controllers react to it:
--   * StoreVisibilityController   — slides the band on/off screen.
--   * StoreToggleAnimator         — the cookie launch/descent + active-toggle artwork.
--   * BuildViewController         — applies the AutoBuildMode coupling (enter/exit build).
--
-- Entry points wired here (all authored in Studio; degrade gracefully when absent):
--   * StoreBottomOff/On cookie toggles — via StoreToggleAnimator (constructed below).
--   * The B key                        — open/close the band.
--   * The floating HUD BuildButton     — open/close the band (the off-band HUD entry).
--   * The band's Close button          — close the band.
--
-- Build-mode entry is NOT owned here: BuildViewController owns BuildModeActive and the camera.
-- Opening the store only flips StoreOpen; if the player has AutoBuildMode on, BuildViewController
-- picks that up and enters build mode itself. Build mode entered from its own button/V sets
-- StoreOpen=true from that side, so the band is always present while building.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("StoreToggleController must live inside a ScreenGui")
	return
end
if screenGui:GetAttribute("StoreToggleControllerRunning") then
	return
end
screenGui:SetAttribute("StoreToggleControllerRunning", true)

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local SettingsConfig = require(shared:WaitForChild("SettingsConfig"))
local StoreShell = require(shared:WaitForChild("StoreShell"))
local ModalCoordinator = require(script.Parent.Parent:WaitForChild("Modals"):WaitForChild("ModalCoordinator"))

local player = Players.LocalPlayer
local store = StoreShell.getActive(screenGui)

-- Building (and therefore the build shop) is gated on the Mixer being unlocked, mirroring the
-- old build-mode gate. While locked the band can't be opened and the toggles stay hidden.
local function mixerUnlocked()
	return player:GetAttribute(Attrs.MixerUnlocked) == true
end

-- Owner of the StoreOpen attribute. Everything else reacts to it.
local function setStoreOpen(open)
	open = open == true
	if open and screenGui:GetAttribute(Attrs.CompactModalActive) == true then
		return
	end
	if open and not mixerUnlocked() then
		return
	end
	if open and ModalCoordinator.isOpen() then
		ModalCoordinator.overrideBackground(true, false)
		return
	end
	if (screenGui:GetAttribute(Attrs.StoreOpen) == true) == open then
		return
	end
	screenGui:SetAttribute(Attrs.StoreOpen, open)
end

local function toggleStore()
	setStoreOpen(not (screenGui:GetAttribute(Attrs.StoreOpen) == true))
end

local HOTBAR_ITEM_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
}

-- Seed the attribute closed so reactive controllers have a defined starting state.
if screenGui:GetAttribute(Attrs.StoreOpen) == nil then
	screenGui:SetAttribute(Attrs.StoreOpen, false)
end

-- Direct StoreOpen writes (notably BuildViewController) still override an active
-- modal session. Normal toggles route through setStoreOpen above.
screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(function()
	if
		screenGui:GetAttribute(Attrs.StoreOpen) == true
		and ModalCoordinator.isOpen()
	then
		if screenGui:GetAttribute(Attrs.CompactModalActive) == true then
			screenGui:SetAttribute(Attrs.StoreOpen, false)
		else
			ModalCoordinator.overrideBackground(true, false)
		end
	end
end)

-- Seed the AutoBuildMode default device-aware (on for touch-only, off on PC) so the coupling
-- works before the Settings row is opened. SettingsController owns it once the row exists; the
-- same default rule lives there (mirrors how PlacementControlsEnabled is seeded in two places).
if screenGui:GetAttribute(Attrs.AutoBuildMode) == nil then
	local deviceType = SettingsConfig.GetDeviceType(
		UserInputService.TouchEnabled,
		UserInputService.MouseEnabled,
		RunService:IsStudio() and UserInputService.PreferredInput == Enum.PreferredInput.Touch
	)
	screenGui:SetAttribute(Attrs.AutoBuildMode, deviceType == SettingsConfig.DeviceType.Mobile)
end

-- Build the cookie animator (StoreController-style ctx module). It binds the StoreBottomOff/On
-- toggles and calls setStoreOpen from their input.
local animator = require(script.Parent.StoreToggleAnimator).new({
	screenGui = screenGui,
	store = store,
	setStoreOpen = setStoreOpen,
})

-- The custom hotbar / carousel (Phase 1). It owns the toolbar's spin/cycle, the spin->open
-- sequencing gate, and the toolbar's hide-on-open / show-first-on-close visibility. B and the
-- mixer tap route through it so they share the same spin->open path; it degrades to a direct
-- toggle when no scaffold is present.
local carousel = require(script.Parent.HotbarCarousel).new({
	screenGui = screenGui,
	store = store,
	setStoreOpen = setStoreOpen,
})

-- Mixer gate: hide the toggles and force the band closed until building is unlocked.
local function refreshMixerGate()
	local unlocked = mixerUnlocked()
	if not unlocked and screenGui:GetAttribute(Attrs.StoreOpen) == true then
		screenGui:SetAttribute(Attrs.StoreOpen, false)
	end
	if animator and animator.setGatedVisible then
		animator.setGatedVisible(unlocked)
	end
	if carousel and carousel.setUnlocked then
		carousel.setUnlocked(unlocked)
	end
end
player:GetAttributeChangedSignal(Attrs.MixerUnlocked):Connect(refreshMixerGate)
refreshMixerGate()

-- Floating HUD BuildButton: the off-band entry point that brings the band up (and closes it).
-- Authored in Studio as ScreenGui.BuildButton with a `.hitbox` GuiButton (or as a GuiButton).
local buildButton = screenGui:FindFirstChild(GuiNames.BuildButton)
local buildButtonHit = buildButton and (buildButton:FindFirstChild("hitbox") or buildButton)
if buildButton and buildButton:IsA("GuiObject") then
	local authoredBuildButtonVisible = buildButton.Visible
	local function updateBuildButtonVisibility()
		buildButton.Visible = authoredBuildButtonVisible
			and screenGui:GetAttribute(Attrs.CompactModalActive) ~= true
	end
	screenGui:GetAttributeChangedSignal(Attrs.CompactModalActive):Connect(updateBuildButtonVisibility)
	updateBuildButtonVisibility()
end
if buildButtonHit and buildButtonHit:IsA("GuiButton") then
	buildButtonHit.Activated:Connect(toggleStore)
end

-- The band's Close button closes the band (StoreVisibilityController + StoreToggleAnimator react).
local closeButton = store and store:FindFirstChild(GuiNames.Close, true)
if closeButton and closeButton:IsA("GuiButton") then
	closeButton.Activated:Connect(function()
		setStoreOpen(false)
	end)
end

-- Keyboard: B opens/closes the band; 1/2/3 select stable hotbar item identities.
-- gameProcessed is respected so typing in a TextBox never toggles/selects anything.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.B then
		-- Route B through the carousel so it shares the spin->open path (spin the mixer to centre,
		-- then open). The carousel handles the already-open case as a close and falls back to a
		-- direct toggle when no scaffold exists.
		if carousel and carousel.requestOpenMixer then
			carousel.requestOpenMixer()
		else
			toggleStore()
		end
		return
	end
	local hotbarItemNumber = HOTBAR_ITEM_KEYS[input.KeyCode]
	if hotbarItemNumber and carousel and carousel.selectItemNumber then
		carousel.selectItemNumber(hotbarItemNumber)
	end
end)
