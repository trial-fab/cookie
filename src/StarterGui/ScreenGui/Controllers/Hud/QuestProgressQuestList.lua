-- Projects server snapshots into the Studio-authored tracked card and grouped selector.
-- One tracked row and one selector row are authored; the selector renders the tracked
-- quest until the grouped multi-row composition is authored in Studio.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local CursorTooltip = require(ReplicatedStorage.Shared.CursorTooltip)
local CurrencyRewardFlightConfig = require(ReplicatedStorage.Shared.CurrencyRewardFlightConfig)
local QuestSnapshot = require(ReplicatedStorage.Shared.QuestSnapshot)
local UiMotion = require(ReplicatedStorage.Shared.UiMotion)
local QuestProgressCompletionStrike = require(script.Parent:WaitForChild("QuestProgressCompletionStrike"))
local QuestProgressStepTransitions = require(script.Parent:WaitForChild("QuestProgressStepTransitions"))

local QuestProgressQuestList = {}
local OPEN_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local CLOSE_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local QUEST_PROGRESS_TWEEN_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SELECTED_QUEST_COLOR = Color3.fromRGB(0, 170, 255)
local UNSELECTED_QUEST_COLOR = Color3.fromRGB(232, 232, 236)
local COMPLETION_HOLD_TIMEOUT_SECONDS = 10

-- How much of a step's share of the straight bar a finished count may fill. Short of 1 on
-- purpose: reaching a count is not always the same as finishing the step. The first-helper
-- step counts cookies toward a price and still needs the building placed afterwards, so a
-- full bar there would claim the step was done while the player still had work to do.
local SUB_PROGRESS_BAR_CAP = 0.9

-- Steps whose sub-progress reaches its target while the server deliberately holds the step
-- open for a world presentation. Their line strikes where it stands and STAYS struck until
-- the step advances, because the wording does not change underneath it.
--
-- Deliberately not generic. An affordability step also reports current == target, but its
-- wording swaps to a new instruction at that moment: leaving it struck in place would cross
-- out "Buy and place a Noob Clicker" while the player still has to do exactly that. Those
-- steps take the holdWithinStep path instead, which strikes the half that finished and then
-- reveals the new half clean.
local IN_PLACE_STRIKE_STEPS = {
	help_goo_recover = true,
}

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

-- A keyboard variant exists only for steps that may name a keybind. Touch and gamepad
-- players must never be shown one.
local function resolveDescription(quest)
	if
		quest.DescriptionKeyboard
		and UserInputService.PreferredInput == Enum.PreferredInput.KeyboardAndMouse
	then
		return tostring(quest.DescriptionKeyboard)
	end
	return tostring(quest.Description or "")
end

local function formatCompletedDescription(quest)
	local description = resolveDescription(quest)
	local target = tonumber(quest.SubProgressTarget)
	if not target then
		return description
	end
	local completedCount = math.max(0, math.floor(target))
	return description:gsub("%(%d+/%d+%)%s*$", ("(%d/%d)"):format(completedCount, completedCount), 1)
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
	local arcRewardLine = child(arcHeader, "RewardLine", "Frame", true)
	local selectorArcHeader = child(selector, "SelectorArcHeader", "Frame")
	local selectorRewardLine = child(selectorArcHeader, "RewardLine", "Frame", true)
	local hideCompletedToggle = child(selector, "HideCompletedToggle", "GuiButton")
	local trackedTitle = child(trackedRow, "QuestTitle", nil)
	local trackedBody = child(trackedRow, "QuestBody", "Frame")
	local trackedDescription = child(trackedRow, "QuestDescription", "TextLabel", true)
	local trackedTitleButton = child(trackedRow, "QuestTitleButton", "GuiButton")
	local questProgressBar = child(trackedBody, "QuestProgressBar", "Frame")
	local questProgressFill = child(questProgressBar, "Fill", "Frame")
	local rewardStrip = child(trackedRow, "QuestRewardStrip", "Frame", true)
	local rewardIcon = child(rewardStrip, "RewardIcon", "ImageLabel", true)
	local selectorRows = {}
	for index = 1, 20 do
		local row = child(selector, ("QuestSelectorRow%02d"):format(index), "GuiButton")
		if row then
			table.insert(selectorRows, row)
		end
	end
	local screenGui = root:FindFirstAncestorOfClass("ScreenGui")
	local rewardTooltipRegistration = screenGui
		and arcRewardLine
		and CursorTooltip.get(screenGui):registerGui(arcRewardLine, {
			trigger = CursorTooltip.Trigger.Hover,
			content = {
				mode = "Hint",
				title = "Mystery Goo:",
				description = "Unlock by completing this quest.",
			},
		})
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
	local questProgressTween
	local questProgressTarget
	local completionHold = false
	local completionHoldGeneration = 0
	local completionQuestId
	local pendingCompletionCueKey
	local stepTransitions
	local presenting = false
	local lastBarProgress = 0
	local lastBarQuestId
	-- Cue keys whose strike has already animated. Steps and quests never un-complete, so a
	-- key that has struck once must never strike again from a second trigger.
	local animatedCueKeys = {}
	local questOpenPosition = questList:GetAttribute("OpenPosition")
	local questClosedPosition = questList:GetAttribute("ClosedPosition")
	local arcOpenPosition = arcHeader and arcHeader:GetAttribute("OpenPosition")
	local arcClosedPosition = arcHeader and arcHeader:GetAttribute("ClosedPosition")
	local toggleOpenPosition = toggleFrame and toggleFrame:GetAttribute("OpenPosition")
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
		arcClosedPosition = arcOpenPosition
			- UDim2.fromOffset(arcHeaderClip and arcHeaderClip.Size.X.Offset or questList.Size.X.Offset, 0)
	end
	if toggleFrame and typeof(toggleOpenPosition) ~= "UDim2" then
		toggleOpenPosition = toggleFrame.Position
	end
	if selectorRewardLine then
		selectorRewardLine.Visible = false
	end
	for index = 2, 20 do
		local unusedTracked = questList:FindFirstChild(("QuestRow%02d"):format(index))
		if unusedTracked and unusedTracked:IsA("GuiObject") then
			unusedTracked.Visible = false
		end
	end
	for _, row in ipairs(selectorRows) do
		row.Visible = false
		row.Active = false
		row.Selectable = false
	end

	local function connect(signal, callback)
		table.insert(connections, signal:Connect(callback))
	end

	local function currentArcAndQuest()
		return QuestSnapshot.getTracked(snapshot)
	end

	-- The rubble is counted on the client, because the server only ever sees the gated story
	-- transition. The count is appended to the ONE authored objective: keeping a second
	-- sentence here is what made the card read as two different objectives for one action.
	local function withLocalCount(quest, description, completed)
		if not (localSubProgress and quest and quest.StepId == localSubProgress.StepId) then
			return description
		end
		local current = if completed then localSubProgress.Target else localSubProgress.Current
		return ("%s (%d/%d)"):format(description, current, localSubProgress.Target)
	end

	local function findQuest(questId)
		if not (snapshot and questId) then
			return nil, nil
		end
		for _, arc in ipairs(snapshot.Arcs or {}) do
			for _, quest in ipairs(arc.Quests or {}) do
				if quest.Id == questId then
					return arc, quest
				end
			end
		end
		return nil, nil
	end

	-- What the card is presenting: a quest whose completion is still being celebrated,
	-- otherwise the tracked one. The server retargets selection to the successor in the
	-- SAME snapshot that reports a completion, so a just-completed quest is never the
	-- tracked one and can only be found by id.
	local function displayArcAndQuest()
		if completionQuestId then
			local arc, quest = findQuest(completionQuestId)
			if arc and quest then
				return arc, quest
			end
		end
		return currentArcAndQuest()
	end

	local function updateTrackedRowVisibility()
		local _, quest = displayArcAndQuest()
		trackedRow.Visible = not selectorOpen
			and quest ~= nil
			and (replay ~= nil or quest.Completed ~= true or completionHold)
	end

	local function updateSelectorSize()
		local layout = selector:FindFirstChildWhichIsA("UIListLayout")
		local padding = selector:FindFirstChildWhichIsA("UIPadding")
		local paddingHeight = padding and padding.PaddingTop.Offset + padding.PaddingBottom.Offset or 0
		local contentHeight = layout and layout.AbsoluteContentSize.Y or 92
		selector.Size = UDim2.new(1, 0, 0, math.min(112, contentHeight + paddingHeight))
	end

	local function setSelectorOpen(open)
		selectorOpen = open == true
		root:SetAttribute("QuestSelectorOpen", selectorOpen)
		selector.Visible = selectorOpen
		selector.ScrollingEnabled = selectorOpen
		updateTrackedRowVisibility()
		if selectorOpen then
			selector.AutomaticCanvasSize = Enum.AutomaticSize.Y
			updateSelectorSize()
			local firstSelectable = hideCompletedToggle
			for _, row in ipairs(selectorRows) do
				if row.Visible and row.Selectable then
					firstSelectable = row
					break
				end
			end
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

	local function renderSelectorRows(arc)
		local previousSelectable
		for index, row in ipairs(selectorRows) do
			local quest = arc.Quests and arc.Quests[index]
			local visible = quest ~= nil and not (snapshot.HideCompleted == true and quest.Completed)
			row.Visible = visible
			row.Active = visible and quest.Selectable == true
			row.Interactable = visible and quest.Selectable == true
			row.Selectable = visible and quest.Selectable == true
			row.NextSelectionUp = nil
			row.NextSelectionDown = nil

			if not quest then
				row:SetAttribute("QuestId", nil)
				continue
			end

			row:SetAttribute("QuestId", quest.Id)
			row:SetAttribute("Completed", quest.Completed == true)
			row:SetAttribute("Selected", quest.Selected == true)
			setText(child(row, "QuestTitle", nil), quest.Title)
			local selectorStep = child(row, "QuestStep", nil)
			setText(selectorStep, formatStep(quest))
			if selectorStep and selectorStep:IsA("GuiObject") then
				selectorStep.Visible = not quest.Completed
			end
			local completedTick = child(row, "CompletedTick", "ImageLabel")
			if completedTick then
				completedTick.Visible = quest.Completed == true
			end

			local selectorTitle = child(row, "QuestTitle", nil, true)
			local selectorStroke = row:FindFirstChildOfClass("UIStroke")
			local selectorColor = if quest.Selected then SELECTED_QUEST_COLOR else UNSELECTED_QUEST_COLOR
			if selectorTitle and (selectorTitle:IsA("TextLabel") or selectorTitle:IsA("TextButton")) then
				selectorTitle.TextColor3 = selectorColor
			end
			row.BackgroundColor3 = Color3.fromRGB(6, 7, 9)
			row.BackgroundTransparency = 0.15
			if selectorStroke then
				selectorStroke.Color = selectorColor
			end

			if row.Selectable then
				if previousSelectable then
					previousSelectable.NextSelectionDown = row
					row.NextSelectionUp = previousSelectable
				end
				previousSelectable = row
			end
		end

		if arc.Quests and #arc.Quests > #selectorRows then
			warn(("Quest selector needs %d authored rows but only has %d"):format(#arc.Quests, #selectorRows))
		end
		if hideCompletedToggle then
			hideCompletedToggle.NextSelectionUp = previousSelectable
			if previousSelectable then
				previousSelectable.NextSelectionDown = hideCompletedToggle
			end
		end
		if selectorOpen then
			task.defer(function()
				if selectorOpen then
					updateSelectorSize()
				end
			end)
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
		local toggleTarget = toggleFrame and toggleOpenPosition
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
				end
			end)
			currentArcTween:Play()
		end
	end

	local function renderQuestProgress(progress)
		if not questProgressFill then
			return
		end
		progress = math.clamp(tonumber(progress) or 0, 0, 1)
		if questProgressTarget and math.abs(progress - questProgressTarget) < 0.001 then
			return
		end
		questProgressTarget = progress
		if questProgressTween then
			questProgressTween:Cancel()
		end
		questProgressTween = UiMotion.create(questProgressFill, QUEST_PROGRESS_TWEEN_INFO, {
			Size = UDim2.new(progress, 0, questProgressFill.Size.Y.Scale, questProgressFill.Size.Y.Offset),
		})
		questProgressTween:Play()
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

	-- "The card is showing a finished objective, not the live one." Guidance waits on this so
	-- the next instruction and the cue that points at it arrive together, instead of the cue
	-- appearing while the player is still reading the struck-through previous step.
	local function setPresenting(value)
		value = value == true
		if value == presenting then
			return
		end
		presenting = value
		if callbacks.onPresentingChanged then
			callbacks.onPresentingChanged(presenting)
		end
	end

	local function render()
		if not snapshot then
			root.Visible = false
			setPresenting(false)
			return
		end
		local arc, quest = displayArcAndQuest()
		if not (arc and quest) then
			root.Visible = false
			setPresenting(false)
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
		updateTrackedRowVisibility()
		setText(trackedTitle, shownQuest.Title)
		local shownDescription = resolveDescription(shownQuest)
		local shownProgress = replayActive and shownQuest.Progress or quest.Progress
		local completionCueKey
		if not replayActive then
			shownDescription = withLocalCount(quest, shownDescription, false)
		end
		local heldStep = not replayActive and stepTransitions and stepTransitions.current() or nil
		if heldStep then
			-- The outgoing objective stays struck on screen; the ring has already moved on.
			shownDescription = heldStep.Description
			shownProgress = heldStep.Progress
			completionCueKey = "step:" .. heldStep.StepId
		elseif not replayActive and completedNow then
			completionCueKey = "quest:" .. tostring(quest.Id)
		elseif
			not replayActive
			and localSubProgress
			and localSubProgress.StepId == quest.StepId
			and localSubProgress.Current >= localSubProgress.Target
		then
			-- A client-counted step (the rubble) finishes before the server credits it, so
			-- the ring takes its own step forward with the final interaction.
			completionCueKey = "step:" .. quest.StepId
			shownProgress = math.min(1, shownProgress + 1 / math.max(1, quest.StepCount))
		elseif
			not replayActive
			and IN_PLACE_STRIKE_STEPS[quest.StepId]
			and questSubProgressTarget
			and questSubProgress
			and questSubProgress >= questSubProgressTarget
		then
			-- Authoritative sub-progress reached its target while the step is still tracked:
			-- strike in place rather than waiting for the advance.
			completionCueKey = "step:" .. quest.StepId
		end
		if completionStrike then
			-- Once per cue, ever. The rubble step strikes when the client counts its fifth
			-- interaction and again when the server credits the step; without this guard the
			-- player watches the same line get crossed out twice.
			local animateCue = completionCueKey ~= nil
				and pendingCompletionCueKey == completionCueKey
				and not animatedCueKeys[completionCueKey]
			if animateCue then
				animatedCueKeys[completionCueKey] = true
			end
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

		-- The straight bar also fills WITHIN a step, so a running count gives immediate
		-- feedback that what the player is doing counts, instead of nothing moving until a
		-- whole step ticks over. The ring is deliberately left alone: it carries ARC
		-- progress, where a fractional step would read as noise rather than information.
		local barProgress = shownProgress
		if not (replayActive or heldStep or completedNow) then
			local stepCount = math.max(1, tonumber(quest.StepCount) or 1)
			local current, target
			if localSubProgress and localSubProgress.StepId == quest.StepId then
				current, target = localSubProgress.Current, localSubProgress.Target
			else
				current, target = questSubProgress, questSubProgressTarget
			end
			if current and target and target > 0 then
				local fraction = math.min(current / target, SUB_PROGRESS_BAR_CAP)
				local base = math.clamp(tonumber(quest.Progress) or 0, 0, 1)
				-- Never below the step-based value: the rubble step advances the ring a whole
				-- step on its final interaction, and the bar must not step backwards from it.
				barProgress = math.max(barProgress, math.min(1, base + fraction / stepCount))
			end
		end

		-- Within one quest the bar only ever moves forward. Several things legitimately
		-- compute a lower number than the frame before -- a strike hold reports the step
		-- boundary rather than the sub-count that just filled, and sub-progress itself can
		-- regress when the player sells or spends -- and none of them is worth animating
		-- backwards. A bar that retreats reads as a bug however defensible the number is.
		if replayActive then
			lastBarQuestId = nil
			lastBarProgress = 0
		else
			if lastBarQuestId == quest.Id then
				barProgress = math.max(barProgress, lastBarProgress)
			else
				lastBarQuestId = quest.Id
			end
			lastBarProgress = barProgress
		end
		renderQuestProgress(barProgress)
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

		-- Is the card still showing a finished objective rather than the live one? Gated holds
		-- are excluded deliberately: those wait on a world presentation that guidance itself
		-- drives (the Mixer unlock flight), so pausing guidance for one would deadlock it.
		setPresenting(completionHold or (heldStep ~= nil and heldStep.Gate == nil))

		local currentQuestArcProgress = if quest.Completed
			then 0
			else math.clamp(tonumber(if replayActive then quest.Progress else shownProgress) or 0, 0, 1)
		local arcProgress = (arc.CompletedCount + currentQuestArcProgress) / math.max(1, arc.QuestCount)
		root:SetAttribute("Progress", math.clamp(arcProgress, 0, 1))
		root:SetAttribute("SelectedQuestId", replayActive and "chapter_replay" or snapshot.SelectedQuestId)
		renderSelectorRows(arc)
	end

	local function releaseCompletionHold()
		if not (completionHold or completionQuestId) then
			return
		end
		completionHold = false
		completionQuestId = nil
		completionHoldGeneration += 1
		render()
	end

	-- Keep the completed card on screen through its strike and reward flight, then hand the
	-- card back to the successor quest.
	local function beginCompletionPresentation(questId)
		completionQuestId = questId
		completionHold = true
		completionHoldGeneration += 1
		local generation = completionHoldGeneration
		-- Presentation failure must never strand the card, so the hold is bounded even if
		-- the reward flight never reports back.
		task.delay(COMPLETION_HOLD_TIMEOUT_SECONDS, function()
			if completionHoldGeneration == generation then
				completionHold = false
				completionQuestId = nil
				render()
			end
		end)
	end

	stepTransitions = QuestProgressStepTransitions.new({
		onExpired = render,
		isGateOpen = function(gate)
			return screenGui:GetAttribute(gate) == true
		end,
	})

	connect(collapseButton.Activated, function()
		setExpanded(not expanded, true)
	end)
	connect(UserInputService.InputBegan, function(input, gameProcessed)
		if
			gameProcessed
			or input.KeyCode ~= Enum.KeyCode.Q
			or UserInputService:GetFocusedTextBox() ~= nil
			or not snapshot
			or not root.Visible
		then
			return
		end
		setExpanded(not expanded, true)
	end)
	if arcHeader then
		arcHeader.AnchorPoint = Vector2.new(0, 0)
	end
	if rewardFlightCompleted then
		connect(rewardFlightCompleted.Event, function(currency, source)
			-- Release when THIS card's own reward lands. This used to compare against one
			-- hardcoded quest id, so every other quest sat out the full fallback timeout.
			if
				completionHold
				and completionQuestId
				and currency == "Gems"
				and source == "quest:" .. tostring(completionQuestId)
			then
				releaseCompletionHold()
			end
		end)
	end
	connect(screenGui:GetAttributeChangedSignal(Attrs.MixerUnlockPresented), function()
		if
			screenGui:GetAttribute(Attrs.MixerUnlockPresented) == true
			and stepTransitions.gateOpened(Attrs.MixerUnlockPresented)
		then
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
	for _, row in ipairs(selectorRows) do
		local selectorQuestRow = row
		connect(selectorQuestRow.Activated, function()
			local questId = selectorQuestRow:GetAttribute("QuestId")
			local arc = currentArcAndQuest()
			for _, quest in ipairs((arc and arc.Quests) or {}) do
				if quest.Id == questId and quest.Selectable then
					setSelectorOpen(false)
					if callbacks.onSelectQuest then
						callbacks.onSelectQuest(quest.Id)
					end
					break
				end
			end
		end)
	end
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
			snapshot = nextSnapshot
			local _, nextQuest = QuestSnapshot.getTracked(nextSnapshot)

			-- Did the quest we were tracking just complete? It has to be looked up by id:
			-- the server retargets selection to the successor in this very snapshot, so a
			-- just-completed quest is never the tracked one.
			if previousQuest and previousQuest.Completed ~= true and not completionQuestId then
				local _, completedSelf = findQuest(previousQuest.Id)
				if completedSelf and completedSelf.Completed == true then
					stepTransitions.reconcile(nil)
					pendingCompletionCueKey = "quest:" .. tostring(previousQuest.Id)
					beginCompletionPresentation(previousQuest.Id)
				end
			end

			if not completionQuestId then
				-- The struck outgoing line keeps its client-side count, so it does not drop
				-- "(5/5)" the instant the server credits the step.
				local stepCue = stepTransitions.observe(previousQuest, nextQuest, function(outgoing)
					return withLocalCount(outgoing, formatCompletedDescription(outgoing), true)
				end, function(stepId)
					return animatedCueKeys["step:" .. tostring(stepId)] == true
				end)
				if stepCue then
					pendingCompletionCueKey = stepCue
				elseif
					previousQuest
					and nextQuest
					and previousQuest.Id == nextQuest.Id
					and previousQuest.StepId == nextQuest.StepId
					and nextQuest.Completed ~= true
				then
					local previousCurrent = tonumber(previousQuest.SubProgress)
					local nextCurrent = tonumber(nextQuest.SubProgress)
					local nextTarget = tonumber(nextQuest.SubProgressTarget)
					if
						nextTarget
						and nextCurrent
						and nextCurrent >= nextTarget
						and (not previousCurrent or previousCurrent < nextTarget)
					then
						local completed = formatCompletedDescription(previousQuest)
						if IN_PLACE_STRIKE_STEPS[nextQuest.StepId] then
							-- The server holds this step open for a world presentation, so the
							-- line stays struck where it is rather than being replaced.
							pendingCompletionCueKey = "step:" .. tostring(previousQuest.StepId)
						elseif completed ~= resolveDescription(nextQuest) then
							-- The step's own instruction just changed: the player finished
							-- saving and is now being asked to buy. Strike and hold the half
							-- they completed before the new half appears.
							pendingCompletionCueKey =
								stepTransitions.holdWithinStep(previousQuest, nextQuest, completed)
						end
					end
				end
				stepTransitions.reconcile(nextQuest)
			end

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
		isPresenting = function()
			return presenting
		end,
		destroy = function()
			cancelRevealTweens()
			stepTransitions.destroy()
			if rewardTooltipRegistration then
				rewardTooltipRegistration:disconnect()
			end
			if questProgressTween then
				questProgressTween:Cancel()
				questProgressTween = nil
			end
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
