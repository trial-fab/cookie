-- CursorTooltipController: binds the shared cursor-following Hint presentation to
-- stable, icon-led controls across the main HUD. The Studio-authored CursorTooltip
-- owns appearance; this controller owns only target discovery and player-facing copy.
--
-- Cursor hints are intentionally keyboard-and-mouse only. Touch has no persistent
-- pointer to follow, and console/gamepad UX is not part of the current launch target.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	return
end
if screenGui:GetAttribute("CursorTooltipControllerRunning") == true then
	return
end
screenGui:SetAttribute("CursorTooltipControllerRunning", true)

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local CursorTooltip = require(shared:WaitForChild("CursorTooltip"))
local CursorTooltipTuning = require(shared:WaitForChild("CursorTooltipTuning"))
local GuiNames = require(shared:WaitForChild("GuiNames"))

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local tooltip = CursorTooltip.get(screenGui)
local WAIT_SECONDS = 10

local function waitForDescendant(parent, name)
	local object = parent and parent:FindFirstChild(name, true)
	if object then
		return object
	end

	local deadline = os.clock() + WAIT_SECONDS
	repeat
		task.wait(0.05)
		object = parent and parent:FindFirstChild(name, true)
	until object or os.clock() >= deadline
	return object
end

local function register(target, tuningTarget, activeProvider, contentTransform)
	if not (target and target:IsA("GuiObject")) then
		return
	end
	tooltip:registerGui(target, {
		trigger = tooltip.Trigger.Hover,
		getContent = function()
			if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
				return nil
			end
			local content = CursorTooltipTuning.getHint(tuningTarget, activeProvider and activeProvider() or false)
			return contentTransform and contentTransform(content) or content
		end,
	})
end

local function registerNamedHitbox(parent, containerName, tuningTarget, stateProvider, contentTransform)
	task.spawn(function()
		local container = waitForDescendant(parent, containerName)
		local hitbox = container
			and (container:FindFirstChild("Hitbox", true) or container:FindFirstChild("hitbox", true))
		if container and not hitbox then
			hitbox = waitForDescendant(container, "Hitbox") or waitForDescendant(container, "hitbox")
		end
		local activeProvider = stateProvider and function()
			return stateProvider(container)
		end or nil
		register(hitbox, tuningTarget, activeProvider, contentTransform)
	end)
end

-- Menu pill controls create their full-frame hitboxes in their owning controllers.
local menuPill = screenGui:FindFirstChild(GuiNames.MenuPill)
if menuPill then
	registerNamedHitbox(menuPill, "Toggle", "Menu", function(container)
		return container:GetAttribute(Attrs.Open) == true
	end)
	registerNamedHitbox(menuPill, GuiNames.Help, "Help")
	registerNamedHitbox(menuPill, GuiNames.Profile, "Profile")
	registerNamedHitbox(menuPill, GuiNames.Wheel, "Rewards")
	registerNamedHitbox(menuPill, GuiNames.Settings, "Settings")
end

-- The leaderboard and both open/closed Mixer controls already have authored hitboxes.
registerNamedHitbox(screenGui, "BoardToggle", "Leaderboard", function()
	return screenGui:GetAttribute(Attrs.LeaderboardOpen) == true
end)
local store = screenGui:FindFirstChild(GuiNames.StoreBottom, true)
local function contextualizeMixer(content)
	if content and store and store:GetAttribute(Attrs.CurrentCategory) == "Robux" then
		content.title = "Robux"
	end
	return content
end
registerNamedHitbox(screenGui, GuiNames.StoreBottomOff, "MixerClosed", nil, contextualizeMixer)
registerNamedHitbox(screenGui, GuiNames.StoreBottomOn, "MixerOpen", nil, contextualizeMixer)

-- Build View lives in a separate topbar ScreenGui, but can publish through the main
-- ScreenGui's shared presenter. Its owning animator creates one outer-frame hitbox.
task.spawn(function()
	local topbarGui = playerGui:WaitForChild(GuiNames.TopbarHudGui, WAIT_SECONDS)
	local frame = topbarGui and waitForDescendant(topbarGui, GuiNames.BuildModeFrame)
	local hitbox = frame and waitForDescendant(frame, "Hitbox")
	register(hitbox, "BuildView", function()
		return screenGui:GetAttribute(Attrs.BuildModeActive) == true
	end)
end)
