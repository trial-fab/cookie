-- Coordinates the directional swipe shared by the four main menu modals.
-- Modal roots remain fixed so their authored backgrounds stay centered. Only their
-- direct GuiObject children move; mark a direct child SwipeStationary=true to exclude it.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Attrs"))
local UiMotion = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiMotion"))

local ModalPageTransition = {}

local PAGE_BY_NAME = {
	Settings = 1,
	Profile = 2,
	Wheel = 3,
	Help = 4,
}

local ROOT_BY_NAME = {
	Settings = "SettingsModal",
	Profile = "ProfileModal",
	Wheel = "WheelModal",
	Help = "Help",
}

local SCALE_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SWIPE_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local COMPACT_MENU_RESTORE_TIME = 0.22

local function shifted(position, xOffset)
	return UDim2.new(
		position.X.Scale,
		position.X.Offset + xOffset,
		position.Y.Scale,
		position.Y.Offset
	)
end

local function shiftedY(position, yOffset)
	return UDim2.new(
		position.X.Scale,
		position.X.Offset,
		position.Y.Scale,
		position.Y.Offset + yOffset
	)
end

local function localWidth(root)
	local offsetWidth = root.Size.X.Offset
	if offsetWidth > 0 then
		return offsetWidth
	end
	return root.AbsoluteSize.X
end

local function resolve(screenGui, fromName, toName)
	local fromPage = PAGE_BY_NAME[fromName]
	local toPage = PAGE_BY_NAME[toName]
	if not fromPage or not toPage or fromPage == toPage then
		return nil
	end

	local fromRoot = screenGui:FindFirstChild(ROOT_BY_NAME[fromName])
	local toRoot = screenGui:FindFirstChild(ROOT_BY_NAME[toName])
	if not (fromRoot and fromRoot:IsA("GuiObject") and toRoot and toRoot:IsA("GuiObject")) then
		return nil
	end

	-- Increasing page numbers move left; decreasing page numbers move right.
	local motionX = if toPage > fromPage then -1 else 1
	local distance = math.max(1, (localWidth(fromRoot) + localWidth(toRoot)) / 2)

	return {
		distance = distance,
		motionX = motionX,
		reduced = screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true,
	}
end

local function movingChildren(modal)
	local children = {}
	for _, child in ipairs(modal:GetChildren()) do
		if child:IsA("GuiObject") and child:GetAttribute("SwipeStationary") ~= true then
			table.insert(children, {
				gui = child,
				restPosition = child.Position,
			})
		end
	end
	return children
end

local function captureRootAppearance(modal, suppressBackground)
	local state = {
		backgroundTransparency = modal.BackgroundTransparency,
		clipsDescendants = modal.ClipsDescendants,
		strokes = {},
	}
	modal.ClipsDescendants = true
	if suppressBackground then
		modal.BackgroundTransparency = 1
		for _, child in ipairs(modal:GetChildren()) do
			if child:IsA("UIStroke") then
				table.insert(state.strokes, { stroke = child, enabled = child.Enabled })
				child.Enabled = false
			end
		end
	end
	return state
end

local function restore(entries, modal, rootState)
	for _, entry in ipairs(entries) do
		if entry.gui.Parent then
			entry.gui.Position = entry.restPosition
		end
	end
	if modal.Parent then
		modal.BackgroundTransparency = rootState.backgroundTransparency
		modal.ClipsDescendants = rootState.clipsDescendants
	end
	for _, entry in ipairs(rootState.strokes) do
		if entry.stroke.Parent then
			entry.stroke.Enabled = entry.enabled
		end
	end
end

local function playGroup(entries, modal, rootState, goalForEntry, onComplete)
	if #entries == 0 then
		onComplete()
		restore(entries, modal, rootState)
		return nil
	end

	local handle = {
		PlaybackState = Enum.PlaybackState.Playing,
		tweens = {},
	}
	local remaining = #entries
	local finished = false

	local function finish()
		if finished then
			return
		end
		finished = true
		handle.PlaybackState = Enum.PlaybackState.Completed
		onComplete()
		restore(entries, modal, rootState)
	end

	function handle:Cancel()
		if finished then
			return
		end
		finished = true
		self.PlaybackState = Enum.PlaybackState.Cancelled
		for _, tween in ipairs(self.tweens) do
			tween:Cancel()
		end
		restore(entries, modal, rootState)
	end

	for _, entry in ipairs(entries) do
		local tween = UiMotion.create(entry.gui, SWIPE_TWEEN_INFO, {
			Position = goalForEntry(entry),
		})
		table.insert(handle.tweens, tween)
		tween.Completed:Once(function(state)
			if finished or state ~= Enum.PlaybackState.Completed then
				return
			end
			remaining -= 1
			if remaining == 0 then
				finish()
			end
		end)
	end
	for _, tween in ipairs(handle.tweens) do
		tween:Play()
	end
	return handle
end

function ModalPageTransition.open(screenGui, modal, fromName, toName, _restPosition)
	local transition = resolve(screenGui, fromName, toName)
	if not transition then
		return nil, false
	end

	local entries = movingChildren(modal)
	local rootState = captureRootAppearance(modal, false)
	if transition.reduced then
		restore(entries, modal, rootState)
		return nil, true
	end

	-- If content moves left, incoming children begin one page-width to the right.
	for _, entry in ipairs(entries) do
		entry.gui.Position = shifted(entry.restPosition, -transition.motionX * transition.distance)
	end
	local handle = playGroup(entries, modal, rootState, function(entry)
		return entry.restPosition
	end, function() end)
	return handle, true
end

function ModalPageTransition.close(screenGui, modal, fromName, toName, _restPosition, onComplete)
	local transition = resolve(screenGui, fromName, toName)
	if not transition then
		return nil, false
	end

	local entries = movingChildren(modal)
	local rootState = captureRootAppearance(modal, true)
	if transition.reduced then
		onComplete()
		restore(entries, modal, rootState)
		return nil, true
	end

	local handle = playGroup(entries, modal, rootState, function(entry)
		return shifted(entry.restPosition, transition.motionX * transition.distance)
	end, onComplete)
	return handle, true
end

-- Compact-phone sessions keep the opaque full-screen surface fixed and animate only its direct
-- content. This prevents the old 0.92 root-scale pop from exposing clickable HUD around the
-- edges. MobileClose is expected to carry SwipeStationary=true in Studio.
function ModalPageTransition.openCompact(screenGui, modal, fromName, toName)
	local swipe, switched = ModalPageTransition.open(screenGui, modal, fromName, toName)
	if switched then
		return swipe
	end

	local entries = movingChildren(modal)
	local rootState = captureRootAppearance(modal, false)
	if screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true then
		restore(entries, modal, rootState)
		return nil
	end
	for _, entry in ipairs(entries) do
		entry.gui.Position = shiftedY(entry.restPosition, 18)
	end
	return playGroup(entries, modal, rootState, function(entry)
		return entry.restPosition
	end, function() end)
end

function ModalPageTransition.closeCompact(screenGui, modal, fromName, toName, onComplete)
	local swipe, switched = ModalPageTransition.close(screenGui, modal, fromName, toName, nil, onComplete)
	if switched then
		return swipe
	end

	local entries = movingChildren(modal)
	local rootState = captureRootAppearance(modal, false)
	if screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true then
		onComplete()
		restore(entries, modal, rootState)
		return nil
	end
	return playGroup(entries, modal, rootState, function(entry)
		return shiftedY(entry.restPosition, 18)
	end, onComplete)
end

-- Manual fullscreen exit has one ordered handoff: MenuPill expands left while its toggle remains
-- hidden, then the modal disappears immediately on the same frame that the regular HUD returns.
-- Module-to-module changes do not use this path; they keep the horizontal desktop swipe.
function ModalPageTransition.closeCompactAfterMenu(screenGui, releaseModal, onComplete)
	local handle = {
		PlaybackState = Enum.PlaybackState.Playing,
		cancelled = false,
	}
	screenGui:SetAttribute(Attrs.CompactMenuRestoreRequested, true)

	function handle:Cancel()
		if self.PlaybackState ~= Enum.PlaybackState.Playing then
			return
		end
		self.cancelled = true
		self.PlaybackState = Enum.PlaybackState.Cancelled
		screenGui:SetAttribute(Attrs.CompactMenuRestoreRequested, false)
	end

	local delayTime = if screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
		then 0
		else COMPACT_MENU_RESTORE_TIME
	task.delay(delayTime, function()
		if handle.cancelled then
			return
		end
		releaseModal()
		screenGui:SetAttribute(Attrs.CompactMenuRestoreRequested, false)
		handle.PlaybackState = Enum.PlaybackState.Completed
		onComplete()
	end)

	return handle
end

-- Scale is used only when entering or leaving the four-page modal session. Direct
-- page switches use the child swipe above and keep this resting scale unchanged.
function ModalPageTransition.openSession(scale, restScale)
	scale.Scale = restScale * 0.92
	local tween = UiMotion.create(scale, SCALE_TWEEN_INFO, { Scale = restScale })
	tween:Play()
	return tween
end

function ModalPageTransition.closeSession(scale, restScale, onComplete)
	local tween = UiMotion.create(scale, SCALE_TWEEN_INFO, { Scale = restScale * 0.92 })
	tween.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed then
			onComplete()
		end
		scale.Scale = restScale
	end)
	tween:Play()
	return tween
end

return ModalPageTransition
