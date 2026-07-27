-- Projects server snapshots into the Studio-authored tracked card and grouped selector.
-- One tracked row and one selector row are authored; the selector renders the tracked
-- quest until the grouped multi-row composition is authored in Studio.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local CurrencyRewardFlightConfig = require(ReplicatedStorage.Shared.CurrencyRewardFlightConfig)
local QuestSnapshot = require(ReplicatedStorage.Shared.QuestSnapshot)
local UiMotion = require(ReplicatedStorage.Shared.UiMotion)
local QuestProgressCompletionStrike = require(script.Parent:WaitForChild("QuestProgressCompletionStrike"))

local QuestProgressQuestList = {}
local OPEN_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local CLOSE_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local SELECTED_QUEST_COLOR = Color3.fromRGB(0, 170, 255)
local UNSELECTED_QUEST_COLOR = Color3.fromRGB(232, 232, 236)
local COMPLETION_HOLD_TIMEOUT_SECONDS = 10
local INTRO_STEP_HOLD_SECONDS = 2

local function child(parent, name, className, recursive)
	local instance = parent and parent:FindFirstChild(name, recursive == true)
	if instance and (not className or instance:IsA(className)) then
		return instance
	end
	return nil
end

local function setText(instance, text)
	if instance and (instance:IsA("TextLabel") or instance:IsA("TextButton")) then
		instance.Text = tostring(text or "")
	end
end

local function getEvent(parent, name)
	local event = parent and parent:FindFirstChild(name)
	if event and event:IsA("BindableEvent") then
		return event
	end
	if not parent then
		return nil
	end
	event = Instance.new("BindableEvent")
	event.Name = name
	event.Parent = parent
	return event
end

local function formatStep(quest)
	if quest.Completed then
		return ""
	end
	return ("%d/%d"):format(quest.StepIndex, quest.StepCount)
end

function QuestProgressQuestList.bind(root, callbacks)
	callbacks = callbacks or {}
	local revealClip = child(root, "QuestRevealClip", "Frame")
	local questList = child(revealClip, "QuestList", "Frame")
	local trackedRow = child(questList, "QuestRow01", "Frame")
	local selector = child(questList, "QuestSelector", "ScrollingFrame")
	local selectorRow = child(selector, "QuestSelectorRow01", "GuiButton")
	local collapseButton = child(root, "QuestProgressToggle", "GuiButton", true)
	if not (questList and trackedRow and selector and selectorRow and collapseButton) then
		warn("Quest list disabled: the Studio-authored Stage 1 scaffold is incomplete")
		return nil
	end

	local toggleFrame = child(root, "ProgressToggleFrame", "Frame")
	local arcHeaderClip = child(root, "ArcHeaderClip", "Frame")
	local arcHeader = child(arcHeaderClip, "ArcHeader", "Frame") or child(questList, "ArcHeader", "Frame")
	local arcHeaderButton = child(arcHeaderClip, "ArcHeaderButton", "GuiButton")
		or child(arcHeader, "ArcHeaderButton", "GuiButton")
	local selectorArcHeader = child(selector, "SelectorArcHeader", "Frame")
	local selectorRewardLine = child(selectorArcHeader, "RewardLine", "Frame", true)
	local hideCompletedToggle = child(selector, "HideCompletedToggle", "GuiButton")
	local trackedTitle = child(trackedRow, "QuestTitle", nil)
	local trackedBody = child(trackedRow, "QuestBody", "Frame")
	local trackedDescription = child(trackedRow, "QuestDescription", "TextLabel", true)
	local trackedTitleButton = child(trackedRow, "QuestTitleButton", "GuiButton")
	local rewardStrip = child(trackedRow, "QuestRewardStrip", "Frame", true)
	local rewardIcon = child(rewardStrip, "RewardIcon", "ImageLabel", true)
	local completedTick = child(selectorRow, "CompletedTick", "ImageLabel")
	local screenGui = root:FindFirstAncestorOfClass("ScreenGui")
	local rewardFlightCompleted = getEvent(screenGui, CurrencyRewardFlightConfig.CompletedEventName)
	local questStrikeCompleted = getEvent(screenGui, CurrencyRewardFlightConfig.QuestStrikeCompletedEventName)
	local completionStrike = QuestProgressCompletionStrike.bind(trackedDescription)
	local expanded = root:GetAttribute("QuestsExpanded") ~= false
	local selectorOpen = false
	local snapshot
	local replay
	local localSubProgress
	local connections = {}
	local revealTween
	local arcTween
	local toggleTween
	local activeQuestVisible = false
	local completionHold = false
	local completionHoldGeneration = 0
	local lastQuestCompleted
	local heldStepTransition
	local pendingCompletionCueKey
	local introStepTransition
	local introStepTransitionGeneration = 0
	local questOpenPosition = questList:GetAttribute("OpenPosition")
	local questClosedPosition = questList:GetAttribute("ClosedPosition")
	local arcOpenPosition = arcHeader and arcHeader:GetAttribute("OpenPosition")
	local arcClosedPosition = arcHeader and arcHeader:GetAttribute("ClosedPosition")
	local toggleOpenPosition = toggleFrame and toggleFrame:GetAttribute("OpenPosition")
	local toggleClosedPosition = toggleFrame and toggleFrame:GetAttribute("ClosedPosition")
	if typeof(questOpenPosition) ~= "UDim2" then
		questOpenPosition = questList.Position
	end
	if typeof(questClosedPosition) ~= "UDim2" then
		questClosedPosition = UDim2.fromOffset(-questList.Size.X.Offset, questOpenPosition.Y.Offset)
	end
	if arcHeader and typeof(arcOpenPosition) ~= "UDim2" then
		arcOpenPosition = arcHeader.Position
	end
	if arcHeader and typeof(arcClosedPosition) ~= "UDim2" then
		arcClosedPosition = arcOpenPosition + UDim2.fromOffset(0, arcHeaderClip and arcHeaderClip.Size.Y.Offset or 38)
	end
	if arcHeader then
		arcOpenPosition = UDim2.fromOffset(0, arcOpenPosition.Y.Offset)
		arcClosedPosition = UDim2.fromOffset(0, arcClosedPosition.Y.Offset)
	end
	if toggleFrame and typeof(toggleOpenPosition) ~= "UDim2" then
		toggleOpenPosition = toggleFrame.Position
	end
	if toggleFrame and typeof(toggleClosedPosition) ~= "UDim2" then
		toggleClosedPosition = UDim2.fromOffset(toggleOpenPosition.X.Offset, 0)
	end
	local defaultToggleOpenPosition = toggleOpenPosition
	if selectorRewardLine then
		selectorRewardLine.Visible = false
	end
	for index = 2, 20 do
		local unusedTracked = questList:FindFirstChild(("QuestRow%02d"):format(index))
		local unusedSelector = selector:FindFirstChild(("QuestSelectorRow%02d"):format(index))
		if unusedTracked and unusedTracked:IsA("GuiObject") then
			unusedTracked.Visible = false
		end
		if unusedSelector and unusedSelector:IsA("GuiObject") then
			unusedSelector.Visible = false
			unusedSelector.Active = false
			unusedSelector.Selectable = false
		end
	end

	local function connect(signal, callback)
		table.insert(connections, signal:Connect(callback))
	end

	local function currentArcAndQuest()
		return QuestSnapshot.getTracked(snapshot)
	end

	local function updateToggleVerticalPosition()
		if not (toggleFrame and defaultToggleOpenPosition) then
			return
		end

		local target = defaultToggleOpenPosition
		if activeQuestVisible and trackedTitle and trackedBody then
			local contentTop = math.min(trackedTitle.Position.Y.Offset, trackedBody.Position.Y.Offset)
			local contentBottom = math.max(
				trackedTitle.Position.Y.Offset + trackedTitle.AbsoluteSize.Y,
				trackedBody.Position.Y.Offset + trackedBody.AbsoluteSize.Y
			)
			local rowTop = revealClip.Position.Y.Offset + questOpenPosition.Y.Offset + trackedRow.Position.Y.Offset
			local targetY = rowTop + (contentTop + contentBottom) / 2 - toggleFrame.AbsoluteSize.Y / 2
			target = UDim2.fromOffset(defaultToggleOpenPosition.X.Offset, targetY)
		end

		toggleOpenPosition = target
		if expanded and not toggleTween then
			toggleFrame.Position = target
		end
	end

	local function setSelectorOpen(open)
		selectorOpen = open == true
		root:SetAttribute("QuestSelectorOpen", selectorOpen)
		selector.Visible = selectorOpen
		selector.ScrollingEnabled = selectorOpen
		if selectorOpen then
			selector.AutomaticCanvasSize = Enum.AutomaticSize.Y
			local layout = selector:FindFirstChildWhichIsA("UIListLayout")
			local padding = selector:FindFirstChildWhichIsA("UIPadding")
			local paddingHeight = padding and padding.PaddingTop.Offset + padding.PaddingBottom.Offset or 0
			local contentHeight = layout and layout.AbsoluteContentSize.Y or 92
			selector.Size = UDim2.new(1, 0, 0, math.min(112, contentHeight + paddingHeight))
			local _, quest = currentArcAndQuest()
			local firstSelectable = quest and quest.Selectable and selectorRow or hideCompletedToggle
			if UserInputService.PreferredInput == Enum.PreferredInput.Gamepad and firstSelectable then
				GuiService.SelectedObject = firstSelectable
			end
		elseif GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(selector) then
			GuiService.SelectedObject = arcHeaderButton or trackedTitleButton or collapseButton
		end
		if not selectorOpen then
			selector.Size = UDim2.new(1, 0, 0, 0)
		end
	end

	local function cancelRevealTweens()
		if revealTween then
			revealTween:Cancel()
			revealTween = nil
		end
		if arcTween then
			arcTween:Cancel()
			arcTween = nil
		end
		if toggleTween then
			toggleTween:Cancel()
			toggleTween = nil
		end
	end

	local function setExpanded(value, animate)
		expanded = value ~= false
		local transitionExpanded = expanded
		root:SetAttribute("QuestsExpanded", expanded)
		if arcHeaderButton then
			arcHeaderButton.Visible = expanded
			arcHeaderButton.Active = expanded
			arcHeaderButton.Interactable = expanded
			arcHeaderButton.Selectable = expanded
		end
		if not expanded then
			setSelectorOpen(false)
		end
		cancelRevealTweens()
		questList.Visible = true
		if arcHeaderClip then
			arcHeaderClip.Visible = true
		end
		local questTarget = expanded and questOpenPosition or questClosedPosition
		local arcTarget = arcHeader and (expanded and arcOpenPosition or arcClosedPosition)
		local toggleTarget = toggleFrame and (expanded and toggleOpenPosition or toggleClosedPosition)
		if animate ~= true then
			questList.Position = questTarget
			questList.Visible = expanded
			if arcHeader and arcTarget then
				arcHeader.Position = arcTarget
			end
			if toggleFrame and toggleTarget then
				toggleFrame.Position = toggleTarget
			end
			return
		end

		local function tweenToggle(target, tweenInfo)
			if not (toggleFrame and target) then
				return
			end
			toggleTween = UiMotion.create(toggleFrame, tweenInfo, { Position = target })
			local tween = toggleTween
			tween.Completed:Once(function(playbackState)
				if toggleTween ~= tween then
					return
				end
				toggleTween = nil
				if playbackState == Enum.PlaybackState.Completed then
					toggleFrame.Position = target
				end
			end)
			tween:Play()
		end

		revealTween =
			UiMotion.create(questList, expanded and OPEN_TWEEN_INFO or CLOSE_TWEEN_INFO, { Position = questTarget })
		local currentRevealTween = revealTween
		currentRevealTween.Completed:Once(function(playbackState)
			if revealTween ~= currentRevealTween then
				return
			end
			revealTween = nil
			if playbackState == Enum.PlaybackState.Completed then
				questList.Position = questTarget
				questList.Visible = transitionExpanded
			end
		end)
		currentRevealTween:Play()

		if arcHeader and arcTarget then
			arcTween =
				UiMotion.create(arcHeader, expanded and OPEN_TWEEN_INFO or CLOSE_TWEEN_INFO, { Position = arcTarget })
			local currentArcTween = arcTween
			currentArcTween.Completed:Once(function(playbackState)
				if arcTween ~= currentArcTween then
					return
				end
				arcTween = nil
				if playbackState == Enum.PlaybackState.Completed then
					arcHeader.Position = arcTarget
					if not transitionExpanded then
						tweenToggle(toggleTarget, CLOSE_TWEEN_INFO)
					end
				end
			end)
			currentArcTween:Play()
		elseif not transitionExpanded then
			tweenToggle(toggleTarget, CLOSE_TWEEN_INFO)
		end

		if transitionExpanded then
			tweenToggle(toggleTarget, OPEN_TWEEN_INFO)
		end
	end

	local function renderArcReward(container, arc)
		if not container then
			return
		end
		setText(child(container, "ArcTitle", nil, true), arc.Title)
		setText(child(container, "ArcProgress", nil, true), ("%d/%d"):format(arc.CompletedCount, arc.QuestCount))
		setText(child(container, "RewardName", nil, true), arc.ArcReward.DisplayName)
		local silhouette = child(container, "RewardSilhouette", "ImageLabel", true)
		local lock = child(container, "RewardLock", "ImageLabel", true)
		if silhouette then
			silhouette.ImageColor3 = if arc.ArcReward.Received then Color3.new(1, 1, 1) else Color3.fromRGB(35, 40, 52)
		end
		if lock then
			lock.Visible = not arc.ArcReward.Received
		end
	end

	local function renderHideCompleted(hidden)
		if not hideCompletedToggle then
			return
		end
		local visibleEye = child(hideCompletedToggle, "EyeVisible", "ImageLabel")
		local hiddenEye = child(hideCompletedToggle, "EyeHidden", "ImageLabel")
		local label = child(hideCompletedToggle, "AccessibleLabel", nil, true)
		local accessibleText = hidden and "Show completed quests" or "Hide completed quests"
		if visibleEye then
			visibleEye.Visible = not hidden
		end
		if hiddenEye then
			hiddenEye.Visible = hidden
		end
		setText(label, accessibleText)
		hideCompletedToggle:SetAttribute("AccessibleText", accessibleText)
	end

	local function render()
		if not snapshot then
			root.Visible = false
			return
		end
		local arc, quest = currentArcAndQuest()
		if not (arc and quest) then
			root.Visible = false
			return
		end
		root.Visible = true

		renderArcReward(arcHeader, arc)
		renderArcReward(selectorArcHeader, arc)
		if selectorRewardLine then
			selectorRewardLine.Visible = false
		end
		renderHideCompleted(snapshot.HideCompleted == true)

		local shownQuest = replay or quest
		local replayActive = replay ~= nil
		local completedNow = quest.Completed == true
		local questSubProgress = tonumber(quest.SubProgress)
		local questSubProgressTarget = tonumber(quest.SubProgressTarget)
		if not completedNow then
			completionHold = false
			completionHoldGeneration += 1
		elseif lastQuestCompleted == false and quest.Reward and quest.Reward.Granted == true then
			completionHold = true
			completionHoldGeneration += 1
			local generation = completionHoldGeneration
			task.delay(COMPLETION_HOLD_TIMEOUT_SECONDS, function()
				if completionHold and completionHoldGeneration == generation then
					completionHold = false
					render()
				end
			end)
		end
		lastQuestCompleted = completedNow
		trackedRow.Visible = replayActive or not completedNow or completionHold
		activeQuestVisible = trackedRow.Visible
		setText(trackedTitle, shownQuest.Title)
		-- A keyboard variant exists only for steps that may name a keybind. Touch and
		-- gamepad players must never be shown one.
		local shownDescription = shownQuest.Description
		if
			shownQuest.DescriptionKeyboard
			and UserInputService.PreferredInput == Enum.PreferredInput.KeyboardAndMouse
		then
			shownDescription = shownQuest.DescriptionKeyboard
		end
		local shownProgress = replayActive and shownQuest.Progress or quest.Progress
		local completionCueKey
		if
			not replayActive
			and localSubProgress
			and quest.StepId == localSubProgress.StepId
			and quest.StepId == "unearth_cookie"
		then
			shownDescription = ("Clear the meteor rubble. (%d/%d)"):format(
				localSubProgress.Current,
				localSubProgress.Target
			)
		end
		if not replayActive and introStepTransition then
			shownDescription = introStepTransition.Description
			shownProgress = introStepTransition.Progress
			completionCueKey = "step:" .. introStepTransition.StepId
		elseif not replayActive and heldStepTransition then
			shownDescription = heldStepTransition.Description
			shownProgress = heldStepTransition.Progress
			completionCueKey = "step:" .. heldStepTransition.StepId
		elseif not replayActive and completedNow then
			completionCueKey = "quest:" .. tostring(quest.Id)
		elseif
			not replayActive
			and quest.StepId == "unearth_cookie"
			and localSubProgress
			and localSubProgress.StepId == quest.StepId
			and localSubProgress.Current >= localSubProgress.Target
		then
			completionCueKey = "step:" .. quest.StepId
			shownProgress = math.min(1, shownProgress + 1 / math.max(1, quest.StepCount))
		elseif
			not replayActive
			and quest.StepId == "help_goo_recover"
			and questSubProgressTarget
			and questSubProgress
			and questSubProgress >= questSubProgressTarget
		then
			completionCueKey = "step:" .. quest.StepId
		end
		if completionStrike then
			local animateCue = completionCueKey ~= nil and pendingCompletionCueKey == completionCueKey
			local onStrikeCompleted
			if animateCue and string.sub(completionCueKey, 1, 6) == "quest:" then
				local completedQuestId = string.sub(completionCueKey, 7)
				onStrikeCompleted = function()
					questStrikeCompleted:Fire(completedQuestId)
				end
			end
			completionStrike.render(shownDescription, completionCueKey ~= nil, animateCue, onStrikeCompleted)
		else
			setText(trackedDescription, shownDescription)
			if
				completionCueKey
				and pendingCompletionCueKey == completionCueKey
				and string.sub(completionCueKey, 1, 6) == "quest:"
			then
				questStrikeCompleted:Fire(string.sub(completionCueKey, 7))
			end
		end
		pendingCompletionCueKey = nil
		task.defer(updateToggleVerticalPosition)
		if rewardStrip then
			rewardStrip.Visible = true
			setText(
				child(rewardStrip, "QuestRewardLabel", nil, true),
				replayActive and "Chapter Replay" or "Quest Reward"
			)
			setText(
				child(rewardStrip, "RewardAmount", nil, true),
				replayActive and "No Reward" or tostring(quest.Reward.Amount)
			)
			if rewardIcon then
				rewardIcon.Visible = not replayActive
			end
		end

		root:SetAttribute("Progress", math.clamp(tonumber(shownProgress) or 0, 0, 1))
		root:SetAttribute("SelectedQuestId", replayActive and "chapter_replay" or snapshot.SelectedQuestId)

		local selectorRowVisible = not (snapshot.HideCompleted == true and quest.Completed)
		selectorRow.Visible = selectorRowVisible
		selectorRow.Active = quest.Selectable == true
		selectorRow.Interactable = quest.Selectable == true
		selectorRow.Selectable = quest.Selectable == true
		setText(child(selectorRow, "QuestTitle", nil), quest.Title)
		local selectorStep = child(selectorRow, "QuestStep", nil)
		setText(selectorStep, formatStep(quest))
		if selectorStep and selectorStep:IsA("GuiObject") then
			selectorStep.Visible = not quest.Completed
		end
		if completedTick then
			completedTick.Visible = quest.Completed == true
		end
		selectorRow:SetAttribute("Completed", quest.Completed == true)
		selectorRow:SetAttribute("Selected", quest.Selected == true)
		local selectorTitle = child(selectorRow, "QuestTitle", nil, true)
		local selectorStroke = selectorRow:FindFirstChildOfClass("UIStroke")
		local selectorColor = if quest.Selected then SELECTED_QUEST_COLOR else UNSELECTED_QUEST_COLOR
		if selectorTitle and (selectorTitle:IsA("TextLabel") or selectorTitle:IsA("TextButton")) then
			selectorTitle.TextColor3 = selectorColor
		end
		selectorRow.BackgroundColor3 = Color3.fromRGB(6, 7, 9)
		selectorRow.BackgroundTransparency = 0.15
		if selectorStroke then
			selectorStroke.Color = selectorColor
		end

		if hideCompletedToggle then
			selectorRow.NextSelectionDown = hideCompletedToggle
			hideCompletedToggle.NextSelectionUp = if quest.Selectable then selectorRow else nil
		end
	end

	connect(collapseButton.Activated, function()
		setExpanded(not expanded, true)
	end)
	if trackedTitle then
		connect(trackedTitle:GetPropertyChangedSignal("AbsoluteSize"), updateToggleVerticalPosition)
	end
	if trackedBody then
		connect(trackedBody:GetPropertyChangedSignal("AbsoluteSize"), updateToggleVerticalPosition)
	end
	if arcHeader then
		arcHeader.AnchorPoint = Vector2.new(0, 0)
	end
	if rewardFlightCompleted then
		connect(rewardFlightCompleted.Event, function(currency, source)
			if completionHold and currency == "Gems" and source == "quest:gooey_beginning" then
				completionHold = false
				completionHoldGeneration += 1
				render()
			end
		end)
	end
	connect(screenGui:GetAttributeChangedSignal(Attrs.MixerUnlockPresented), function()
		if heldStepTransition and screenGui:GetAttribute(Attrs.MixerUnlockPresented) == true then
			heldStepTransition = nil
			render()
		end
	end)
	-- Picking up a controller mid-step must drop the keyboard wording on the next frame.
	connect(UserInputService:GetPropertyChangedSignal("PreferredInput"), function()
		if snapshot then
			render()
		end
	end)
	if arcHeaderButton then
		connect(arcHeaderButton.Activated, function()
			setSelectorOpen(not selectorOpen)
		end)
	end
	if trackedTitleButton then
		connect(trackedTitleButton.Activated, function()
			setSelectorOpen(not selectorOpen)
		end)
	end
	connect(selectorRow.Activated, function()
		local _, quest = currentArcAndQuest()
		if quest and quest.Selectable then
			setSelectorOpen(false)
			if callbacks.onSelectQuest then
				callbacks.onSelectQuest(quest.Id)
			end
		end
	end)
	if hideCompletedToggle then
		connect(hideCompletedToggle.Activated, function()
			if snapshot and callbacks.onSetHideCompleted then
				callbacks.onSetHideCompleted(snapshot.HideCompleted ~= true)
			end
		end)
	end
	setExpanded(expanded, false)
	setSelectorOpen(false)
	render()

	return {
		renderSnapshot = function(nextSnapshot)
			local _, previousQuest = currentArcAndQuest()
			local _, nextQuest = QuestSnapshot.getTracked(nextSnapshot)
			if previousQuest and nextQuest then
				local previousCurrent = tonumber(previousQuest.SubProgress)
				local nextCurrent = tonumber(nextQuest.SubProgress)
				local nextTarget = tonumber(nextQuest.SubProgressTarget)
				if
					previousQuest.StepId == "begin_rescue"
					and nextQuest.StepId == "unearth_cookie"
					and nextQuest.Completed ~= true
				then
					introStepTransitionGeneration += 1
					local generation = introStepTransitionGeneration
					introStepTransition = {
						StepId = previousQuest.StepId,
						Description = previousQuest.Description,
						Progress = nextQuest.Progress,
					}
					pendingCompletionCueKey = "step:" .. previousQuest.StepId
					task.delay(INTRO_STEP_HOLD_SECONDS, function()
						if introStepTransition and introStepTransitionGeneration == generation then
							introStepTransition = nil
							render()
						end
					end)
				elseif
					previousQuest.StepId == "help_goo_recover"
					and nextQuest.StepId == previousQuest.StepId
					and nextTarget
					and nextCurrent
					and nextCurrent >= nextTarget
					and (not previousCurrent or previousCurrent < nextTarget)
				then
					pendingCompletionCueKey = "step:" .. previousQuest.StepId
				elseif
					previousQuest.StepId == "unlock_mixer"
					and nextQuest.StepId == "build_first_helper"
					and nextQuest.Completed ~= true
					and screenGui:GetAttribute(Attrs.MixerUnlockPresented) ~= true
				then
					heldStepTransition = {
						StepId = previousQuest.StepId,
						Description = previousQuest.Description,
						Progress = nextQuest.Progress,
					}
					pendingCompletionCueKey = "step:" .. previousQuest.StepId
				elseif previousQuest.Completed ~= true and nextQuest.Completed == true then
					pendingCompletionCueKey = "quest:" .. tostring(nextQuest.Id)
				end
			end
			if
				introStepTransition
				and (not nextQuest or nextQuest.StepId ~= "unearth_cookie" or nextQuest.Completed)
			then
				introStepTransition = nil
				introStepTransitionGeneration += 1
			end
			if
				heldStepTransition
				and (not nextQuest or nextQuest.StepId ~= "build_first_helper" or nextQuest.Completed)
			then
				heldStepTransition = nil
			end
			snapshot = nextSnapshot
			if localSubProgress and (not nextQuest or nextQuest.StepId ~= localSubProgress.StepId) then
				localSubProgress = nil
			end
			render()
		end,
		setLocalSubProgress = function(stepId, current, target)
			target = math.max(1, math.floor(tonumber(target) or 1))
			local previousCurrent = localSubProgress
					and localSubProgress.StepId == tostring(stepId or "")
					and localSubProgress.Current
				or 0
			localSubProgress = {
				StepId = tostring(stepId or ""),
				Current = math.clamp(math.floor(tonumber(current) or 0), 0, target),
				Target = target,
			}
			if previousCurrent < target and localSubProgress.Current >= target then
				pendingCompletionCueKey = "step:" .. localSubProgress.StepId
			end
			render()
		end,
		renderReplay = function(nextReplay)
			replay = nextReplay
			setSelectorOpen(false)
			render()
		end,
		getRewardSource = function()
			return rewardIcon or rewardStrip
		end,
		destroy = function()
			cancelRevealTweens()
			if completionStrike then
				completionStrike.destroy()
			end
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			table.clear(connections)
		end,
	}
end

return QuestProgressQuestList
