-- InviteController: one-click branded invite flow.
-- Click HUD Invite -> closed envelope fades open -> Roblox invite prompt opens.
-- When Roblox's prompt closes, the envelope fades closed and disappears.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local TweenService = game:GetService("TweenService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local MobileScale = require(shared:WaitForChild("MobileScale"))

local ModalCoordinator = require(script.Parent:WaitForChild("ModalCoordinator"))

local MY = "Invite"
local CLOSED_IMAGE = "rbxassetid://134856115618779"
local OPEN_IMAGE = "rbxassetid://83241550129591"
local PROMPT_MESSAGE = "Invite friends to bake cookies with you!"

local OPEN_TWEEN = TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local ELIGIBILITY_RETRY_DELAY = 0.45

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("InviteController must live inside a ScreenGui")
	return
end
if screenGui:GetAttribute("InviteControllerRunning") then
	return
end
screenGui:SetAttribute("InviteControllerRunning", true)

local player = Players.LocalPlayer
local modal = screenGui:WaitForChild(GuiNames.InviteModal, 10)
if not (modal and modal:IsA("GuiObject")) then
	warn("InviteController disabled: ScreenGui.InviteModal was not found")
	return
end

local closedEnvelope = modal:FindFirstChild("ClosedEnvelope", true)
local openEnvelope = modal:FindFirstChild("OpenEnvelope", true)
if not (closedEnvelope and closedEnvelope:IsA("ImageLabel")) then
	warn("InviteController disabled: InviteModal.ClosedEnvelope was not found")
	return
end
if not (openEnvelope and openEnvelope:IsA("ImageLabel")) then
	warn("InviteController disabled: InviteModal.OpenEnvelope was not found")
	return
end

closedEnvelope.Image = closedEnvelope.Image ~= "" and closedEnvelope.Image or CLOSED_IMAGE
openEnvelope.Image = openEnvelope.Image ~= "" and openEnvelope.Image or OPEN_IMAGE

-- The modal is a full-screen backdrop; the envelopes are centre-anchored. On phones the authored
-- 520x400 art fills the whole screen, so shrink each envelope's box (it stays centred via its
-- 0.5,0.5 anchor). Untouched on PC. Only the Size is driven here -- the open/close animation owns
-- ImageTransparency, so the two never fight.
MobileScale.applyMobileScale(closedEnvelope, { mobileScale = 0.8 })
MobileScale.applyMobileScale(openEnvelope, { mobileScale = 0.8 })

local function findButton(root, name)
	local object = root:FindFirstChild(name, true)
	if object and object:IsA("GuiButton") then
		return object
	end
	return nil
end

local function findHudInviteButton()
	local hud = screenGui:FindFirstChild("BottomRightHud")
	local friendBoost = hud and hud:FindFirstChild("FriendBoost", true)
	local button = friendBoost and friendBoost:FindFirstChild(GuiNames.InviteButton)
	if button and button:IsA("GuiButton") then
		return button
	end
	return findButton(screenGui, GuiNames.InviteButton)
end

local launchButton = findHudInviteButton()
local open = false
local busy = false
local activeTweenA = nil
local activeTweenB = nil
local animationToken = 0

local function cancelTweens()
	if activeTweenA then
		activeTweenA:Cancel()
		activeTweenA = nil
	end
	if activeTweenB then
		activeTweenB:Cancel()
		activeTweenB = nil
	end
end

local function setEnvelope(closedTransparency, openTransparency)
	closedEnvelope.Visible = true
	openEnvelope.Visible = true
	closedEnvelope.ImageTransparency = closedTransparency
	openEnvelope.ImageTransparency = openTransparency
end

local function readInviteEligibility()
	local success, canSend = pcall(function()
		return SocialService:CanSendGameInviteAsync(player)
	end)
	if success then
		return {
			success = true,
			canSend = canSend == true,
		}
	end
	return {
		success = false,
		canSend = false,
		error = canSend,
	}
end

local function canSendInvite()
	local first = readInviteEligibility()
	if first.success and first.canSend then
		return true
	end

	task.wait(ELIGIBILITY_RETRY_DELAY)

	local second = readInviteEligibility()
	if second.success and second.canSend then
		return true
	end

	if not first.success or not second.success then
		warn(
			"InviteController: CanSendGameInviteAsync failed",
			"firstError=" .. tostring(first.error),
			"secondError=" .. tostring(second.error)
		)
	else
		warn("InviteController: CanSendGameInviteAsync returned false twice; player or platform is not eligible right now")
	end

	return false
end

local setVisible

local function promptRobloxInvite(token, canInvite)
	if token ~= animationToken or not open then
		return
	end

	if canInvite == nil then
		canInvite = canSendInvite()
	end
	if not canInvite then
		setVisible(false)
		return
	end

	if token ~= animationToken or not open then
		return
	end

	local inviteOptions = Instance.new("ExperienceInviteOptions")
	inviteOptions.PromptMessage = PROMPT_MESSAGE

	local success, err = pcall(function()
		SocialService:PromptGameInvite(player, inviteOptions)
	end)
	if not success then
		warn("InviteController: PromptGameInvite failed:", err)
		setVisible(false)
	end
end

local modalSlot = ModalCoordinator.register(MY, function()
	if open then
		setVisible(false)
	end
end)

function setVisible(value)
	if value == open then
		return
	end

	open = value
	busy = true
	modal:SetAttribute(Attrs.Open, value)

	if value then
		modalSlot.open()
	else
		modalSlot.close()
	end

	cancelTweens()
	animationToken += 1
	local token = animationToken
	local animate = screenGui:GetAttribute(Attrs.AnimationsEnabled) ~= false

	if value then
		modal.Visible = true
		setEnvelope(0, 1)

		local eligibilityReady = false
		local canInvite = false
		task.spawn(function()
			canInvite = canSendInvite()
			eligibilityReady = true
		end)

		local function promptAfterEligibility()
			task.spawn(function()
				while token == animationToken and open and not eligibilityReady do
					task.wait()
				end
				if token == animationToken and open then
					promptRobloxInvite(token, canInvite)
				end
			end)
		end

		if animate then
			activeTweenA = TweenService:Create(closedEnvelope, OPEN_TWEEN, { ImageTransparency = 1 })
			activeTweenB = TweenService:Create(openEnvelope, OPEN_TWEEN, { ImageTransparency = 0 })
			activeTweenA:Play()
			activeTweenB:Play()
			activeTweenB.Completed:Once(function()
				if token ~= animationToken or not open then
					return
				end
				busy = false
				promptAfterEligibility()
			end)
		else
			setEnvelope(1, 0)
			busy = false
			promptAfterEligibility()
		end
	else
		setEnvelope(closedEnvelope.ImageTransparency, openEnvelope.ImageTransparency)

		if animate then
			activeTweenA = TweenService:Create(closedEnvelope, CLOSE_TWEEN, { ImageTransparency = 0 })
			activeTweenB = TweenService:Create(openEnvelope, CLOSE_TWEEN, { ImageTransparency = 1 })
			activeTweenA:Play()
			activeTweenB:Play()
			activeTweenB.Completed:Once(function()
				if token ~= animationToken or open then
					return
				end
				modal.Visible = false
				setEnvelope(0, 1)
				busy = false
			end)
		else
			modal.Visible = false
			setEnvelope(0, 1)
			busy = false
		end
	end
end

modal.Visible = false
modal:SetAttribute(Attrs.Open, false)
setEnvelope(0, 1)

if launchButton then
	launchButton.Activated:Connect(function()
		if not busy and not open then
			setVisible(true)
		end
	end)
else
	warn("InviteController could not find BottomRightHud FriendBoost InviteButton")
end

SocialService.GameInvitePromptClosed:Connect(function(closedPlayer)
	if closedPlayer == player and open then
		setVisible(false)
	end
end)
