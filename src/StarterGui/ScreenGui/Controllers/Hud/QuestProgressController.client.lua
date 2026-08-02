local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local GuiNames = require(Shared:WaitForChild("GuiNames"))
local Net = require(Shared:WaitForChild("Net"))
local QuestReplayConfig = require(Shared:WaitForChild("QuestReplayConfig"))
local QuestSnapshot = require(Shared:WaitForChild("QuestSnapshot"))
local QuestProgressGuidance = require(script.Parent:WaitForChild("QuestProgressGuidance"))
local QuestProgressObservations = require(script.Parent:WaitForChild("QuestProgressObservations"))
local QuestProgressPosition = require(script.Parent:WaitForChild("QuestProgressPosition"))
local QuestProgressPresenter = require(script.Parent:WaitForChild("QuestProgressPresenter"))
local QuestProgressQuestList = require(script.Parent:WaitForChild("QuestProgressQuestList"))
local QuestProgressReplay = require(script.Parent:WaitForChild("QuestProgressReplay"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui or screenGui:GetAttribute("QuestProgressControllerRunning") then
	return
end
screenGui:SetAttribute("QuestProgressControllerRunning", true)
screenGui:SetAttribute(Attrs.QuestSnapshotReady, false)

local root = screenGui:WaitForChild(GuiNames.QuestProgress, 10)
if not (root and root:IsA("GuiObject")) then
	warn("QuestProgressController disabled: ScreenGui.QuestProgress was not found")
	return
end
root.Visible = false

QuestProgressPosition.bind(root)
QuestProgressPresenter.bind(root)

local guidance = QuestProgressGuidance.new(screenGui, root)
local latestSnapshot
local pendingGuidanceSnapshot
local replayActive = false
local list

-- Guidance follows the CARD, not the server. While the card is still holding a struck-out
-- objective, the cue for the next step is withheld, so the new instruction and the thing it
-- points at appear together. Without this the highlight lands first and the player is being
-- pointed somewhere before the text has told them why.
local function refreshGuidance()
	if replayActive or not list then
		guidance.stop()
		return
	end
	if list.isPresenting() then
		guidance.stop()
		return
	end
	if pendingGuidanceSnapshot then
		local snapshot = pendingGuidanceSnapshot
		pendingGuidanceSnapshot = nil
		guidance.setSnapshot(snapshot)
	end
end

list = QuestProgressQuestList.bind(root, {
	onSelectQuest = function(questId)
		guidance.stop()
		Net.fireServer(Net.Names.QuestAction, "SelectQuest", questId)
	end,
	onSetHideCompleted = function(hidden)
		Net.fireServer(Net.Names.QuestAction, "SetHideCompleted", hidden)
	end,
	onPresentingChanged = function()
		refreshGuidance()
	end,
})
if not list then
	return
end

local observations = QuestProgressObservations.bind(screenGui, function(key)
	Net.fireServer(Net.Names.QuestAction, "Observe", key)
end)

local rubbleProgressEvent = screenGui:FindFirstChild(QuestReplayConfig.RubbleProgressEvent)
if not rubbleProgressEvent then
	rubbleProgressEvent = Instance.new("BindableEvent")
	rubbleProgressEvent.Name = QuestReplayConfig.RubbleProgressEvent
	rubbleProgressEvent.Parent = screenGui
end
if rubbleProgressEvent:IsA("BindableEvent") then
	rubbleProgressEvent.Event:Connect(function(current, target)
		list.setLocalSubProgress("unearth_cookie", current, target)
	end)
end

QuestProgressReplay.new(screenGui, list, function()
	replayActive = true
	guidance.stop()
end, function()
	replayActive = false
	pendingGuidanceSnapshot = latestSnapshot
	refreshGuidance()
end)

Net.on(Net.Names.QuestSnapshot, function(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	latestSnapshot = snapshot
	pendingGuidanceSnapshot = snapshot
	-- Render first: this is what starts (or ends) a hold, so the guidance decision below
	-- reads the card's settled state rather than the previous frame's.
	list.renderSnapshot(snapshot)
	local _, trackedQuest = QuestSnapshot.getTracked(snapshot)
	observations.setAwaiting(trackedQuest and trackedQuest.AwaitingObservation or nil)
	screenGui:SetAttribute(Attrs.QuestSnapshotReady, true)
	refreshGuidance()
end)

Net.fireServer(Net.Names.QuestAction, "RequestSnapshot")
