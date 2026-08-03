-- Declarative protocol-v2 renderer for the Studio-authored tracked card and selector.
-- Explicit transitions drive ceremony; snapshots only drive convergent current state.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local CursorTooltip = require(ReplicatedStorage.Shared.CursorTooltip)
local NumberFormat = require(ReplicatedStorage.Shared.NumberFormat)
local QuestContentReader = require(ReplicatedStorage.Shared.Quest.QuestContentReader)
local QuestCopy = require(ReplicatedStorage.Shared.Quest.QuestCopy)
local UiMotion = require(ReplicatedStorage.Shared.UiMotion)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local QuestProgressQuestList = {}

local SELECTED_COLOR = Color3.fromRGB(0, 170, 255)
local UNSELECTED_COLOR = Color3.fromRGB(232, 232, 236)
local OPEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

local function child(parent, name, className, recursive)
	local value = parent and parent:FindFirstChild(name, recursive == true)
	if value and (not className or value:IsA(className)) then return value end
	return nil
end

local function setText(value, text)
	if value and (value:IsA("TextLabel") or value:IsA("TextButton")) then
		value.Text = tostring(text or "")
	end
end

local function selectedInstance(snapshot)
	for _, instance in ipairs(snapshot and snapshot.Instances or {}) do
		if instance.Selected == true or instance.InstanceId == snapshot.SelectedInstanceId then
			return instance
		end
	end
	return nil
end

local function findInstance(snapshot, instanceId)
	for _, instance in ipairs(snapshot and snapshot.Instances or {}) do
		if instance.InstanceId == instanceId then return instance end
	end
	return nil
end

local function findArc(snapshot, arcId)
	for _, arc in ipairs(snapshot and snapshot.Arcs or {}) do
		if arc.ArcId == arcId then return arc end
	end
	return nil
end

local function inputKind()
	if UserInputService.PreferredInput == Enum.PreferredInput.KeyboardAndMouse then return "Keyboard" end
	if UserInputService.PreferredInput == Enum.PreferredInput.Gamepad then return "Gamepad" end
	return "Touch"
end

function QuestProgressQuestList.bind(root, config)
	config = config or {}
	local content = assert(config.Content, "quest renderer needs canonical content")
	local getLiveFacts = type(config.GetLiveFacts) == "function" and config.GetLiveFacts or nil
	local revealClip = child(root, "QuestRevealClip", "Frame")
	local questList = child(revealClip, "QuestList", "Frame")
	local trackedRow = child(questList, "QuestRow01", "Frame")
	local selector = child(questList, "QuestSelector", "ScrollingFrame")
	local collapseButton = child(root, "QuestProgressToggle", "GuiButton", true)
	if not (questList and trackedRow and selector and collapseButton) then
		warn("Quest renderer disabled: approved Studio hierarchy is incomplete")
		return nil
	end

	local toggleFrame = child(root, "ProgressToggleFrame", "Frame")
	local arcHeaderClip = child(root, "ArcHeaderClip", "Frame")
	local arcHeader = child(arcHeaderClip, "ArcHeader", "Frame")
	local arcHeaderButton = child(arcHeaderClip, "ArcHeaderButton", "GuiButton")
	local arcRewardLine = child(arcHeader, "RewardLine", "Frame", true)
	local trackedTitleButton = child(trackedRow, "QuestTitleButton", "GuiButton")
	local trackedTitle = child(trackedRow, "QuestTitle", "TextLabel")
	local trackedDescription = child(trackedRow, "QuestDescription", "TextLabel", true)
	local trackedBody = child(trackedRow, "QuestBody", "Frame")
	local questProgressBar = child(trackedBody, "QuestProgressBar", "Frame")
	local questProgressFill = child(questProgressBar, "Fill", "Frame")
	local rewardStrip = child(trackedRow, "QuestRewardStrip", "Frame", true)
	local rewardLabel = child(rewardStrip, "QuestRewardLabel", "TextLabel", true)
	local rewardAmount = child(rewardStrip, "RewardAmount", "TextLabel", true)
	local rewardIcon = child(rewardStrip, "RewardIcon", "ImageLabel", true)
	local hideCompleted = child(selector, "HideCompletedToggle", "GuiButton")
	local selectorArcHeader = child(selector, "SelectorArcHeader", "Frame")
	local rows = {}
	for index = 1, 20 do
		local row = child(selector, ("QuestSelectorRow%02d"):format(index), "GuiButton")
		if row then table.insert(rows, row) end
	end
	for index = 2, 20 do
		local stale = questList:FindFirstChild(("QuestRow%02d"):format(index))
		if stale and stale:IsA("GuiObject") then stale.Visible = false end
	end

	local snapshot
	local replay
	local eventDisplay
	local completionInstanceId
	local localProgress
	local expanded = root:GetAttribute("QuestsExpanded") ~= false
	local selectorOpen = false
	local connections = {}
	local revealTween
	local arcTween
	local questProgressTween
	local rewardTooltipRegistration
	-- QuestProgressPresentationCoordinator publishes the advanced snapshot BEFORE it
	-- enqueues the transitions that present the step the player just finished. So a
	-- completing step always renders one pass showing the NEXT step's progress, and the
	-- bar tweened down toward it before the ceremony tweened it back to full. Hold the bar
	-- across that gap; the ordered presentation below releases it. (The old whole-quest bar
	-- hid this behind a monotonic high-water table, which also blocked the honest backwards
	-- movement when a player spends what they were saving.)
	local barAwaitingPresentation = false
	local openPosition = questList:GetAttribute("OpenPosition")
	local closedPosition = questList:GetAttribute("ClosedPosition")
	local arcOpenPosition = arcHeader and arcHeader:GetAttribute("OpenPosition")
	local arcClosedPosition = arcHeader and arcHeader:GetAttribute("ClosedPosition")
	local toggleOpenPosition = toggleFrame and toggleFrame:GetAttribute("OpenPosition")
	if typeof(openPosition) ~= "UDim2" then openPosition = questList.Position end
	if typeof(closedPosition) ~= "UDim2" then closedPosition = UDim2.fromOffset(-questList.Size.X.Offset, openPosition.Y.Offset) end
	if arcHeader and typeof(arcOpenPosition) ~= "UDim2" then arcOpenPosition = arcHeader.Position end
	if arcHeader and typeof(arcClosedPosition) ~= "UDim2" then
		arcClosedPosition = arcOpenPosition - UDim2.fromOffset(arcHeaderClip.Size.X.Offset, 0)
	end
	if toggleFrame and typeof(toggleOpenPosition) ~= "UDim2" then toggleOpenPosition = toggleFrame.Position end

	local function connect(signal, callback)
		table.insert(connections, signal:Connect(callback))
	end

	local function copyContext()
		return {
			InputKind = inputKind(),
			FormatNumber = NumberFormat.exact,
			ResolveUpgradeDisplayName = function(upgradeId)
				local value = UpgradeConfig[upgradeId]
				return value and value.DisplayName or upgradeId
			end,
		}
	end

	local function renderDescription(definitionId, stepId, projection)
		if not (definitionId and stepId and projection) then return "" end
		local rendered = QuestContentReader.RenderStep(content, definitionId, stepId, projection, copyContext())
		return rendered or ""
	end

	-- The straight bar is the CURRENT STEP's own 0..1, not the quest's. Overall progress is
	-- the ring's job, and a bar that crawled a fraction of a step's share was the least
	-- useful of the three signals on screen. Objectives can narrow it to counted phases
	-- when one objective transitions from accumulating a count to a binary action.
	local function isCountedStep(step, projection)
		if not (step and step.Objective) then return false end
		return content.Objectives.ShowsProgressBar(step.Objective, projection)
	end

	-- Objective kinds explicitly declare any non-authoritative live count they present.
	-- The shared registry resolves that contract so this renderer never needs a kind table.
	local function resolveLiveProgress(step, projection)
		if not (getLiveFacts and step and step.Objective and projection) then return projection end
		return content.Objectives.ResolveLiveProgress(step.Objective, projection, getLiveFacts())
	end

	local function stepProgress(projection)
		local declared = tonumber(projection and projection.ProgressFraction)
		if declared then return math.clamp(declared, 0, 1) end
		local current = tonumber(projection and projection.Current)
		local target = tonumber(projection and projection.Target)
		if current and target and target > 0 then return math.clamp(current / target, 0, 1) end
		return 0
	end

	local function arcProgress(arc, instance)
		if not arc then return 0 end
		local currentQuestProgress = 0
		if instance and not instance.Completed then
			currentQuestProgress = math.clamp(
				((tonumber(instance.StepIndex) or 1) - 1) / math.max(1, tonumber(instance.StepCount) or 1),
				0,
				1
			)
		end
		return math.clamp(
			((tonumber(arc.CompletedQuestCount) or 0) + currentQuestProgress)
				/ math.max(1, tonumber(arc.DisplayQuestCount) or 1),
			0,
			1
		)
	end

	local function displayInstance()
		if eventDisplay and eventDisplay.InstanceId then
			local eventInstance = findInstance(snapshot, eventDisplay.InstanceId)
			if eventInstance then return eventInstance end
		end
		if completionInstanceId then
			local held = findInstance(snapshot, completionInstanceId)
			if held then return held end
		end
		local selected = selectedInstance(snapshot)
		if selected then return selected end
		-- A completed terminal arc has no successor to select. Keep its most
		-- recent completed quest as the tracked card instead of hiding the HUD.
		local terminal
		local terminalOrder = -math.huge
		for index, instance in ipairs(snapshot and snapshot.Instances or {}) do
			if instance.Completed then
				local definition = content.DefinitionsById[instance.DefinitionId]
				local order = tonumber(definition and definition.Order) or index
				if order >= terminalOrder then
					terminal = instance
					terminalOrder = order
				end
			end
		end
		return terminal
	end

	local function definitionArcFor(arc)
		for _, candidate in ipairs(content.Arcs or {}) do
			if arc and candidate.Id == arc.ArcId then return candidate end
		end
		return nil
	end

	local function arcReward(definitionArc)
		local reference = definitionArc and definitionArc.Reward
		local definition = reference and content.DefinitionsById[reference.DefinitionId]
		local declaration = definition and definition.RewardBySlotId and definition.RewardBySlotId[reference.SlotId]
		if not declaration then return nil end

		local projection = content.Rewards and content.Rewards.Project
			and select(1, content.Rewards.Project(declaration))
		if not projection then return nil end
		local result = {
			RewardSlotId = declaration.SlotId,
			RewardKind = declaration.Kind,
			Granted = false,
			Projection = projection,
		}
		local instance = findInstance(snapshot, definition.InstanceId)
		for _, candidate in ipairs(instance and instance.Rewards or {}) do
			if candidate.RewardSlotId == reference.SlotId then return candidate end
		end
		return result
	end

	local function renderArcHeader(container, arc, showReward)
		if not container then return end
		local definitionArc = definitionArcFor(arc)
		setText(child(container, "ArcTitle", "TextLabel", true), definitionArc and QuestCopy.ResolveLocalized(definitionArc.Title, copyContext()) or "")
		setText(child(container, "ArcProgress", "TextLabel", true), arc and (("%d/%d"):format(arc.CompletedQuestCount, arc.DisplayQuestCount)) or "")
		local line = child(container, "RewardLine", "Frame", true)
		if line then
			local reward = arcReward(definitionArc)
			line.Visible = arc ~= nil and reward ~= nil and showReward == true
			local resolved = reward and reward.Projection.Resolved ~= false
			setText(child(line, "ArcRewardLabel", "TextLabel", true), reward and (resolved and reward.Granted and "Unlocked" or "Quest Reward") or "")
			setText(child(line, "RewardName", "TextLabel", true), reward and (resolved and reward.Projection.DisplayName
				or reward.Projection.MysteryDisplayName or reward.RewardKind) or "")
			local silhouette = child(line, "RewardSilhouette", "ImageLabel", true)
			if silhouette then
				silhouette.ImageColor3 = reward and reward.Granted and Color3.new(1, 1, 1) or Color3.fromRGB(35, 40, 52)
			end
			local lock = child(line, "RewardLock", "ImageLabel", true)
			if lock then lock.Visible = reward ~= nil and (not resolved or reward.Granted ~= true) end
		end
	end

	local screenGui = root:FindFirstAncestorOfClass("ScreenGui")
	if screenGui and arcRewardLine then
		rewardTooltipRegistration = CursorTooltip.get(screenGui):registerGui(arcRewardLine, {
			trigger = CursorTooltip.Trigger.Hover,
			getContent = function()
				local instance = displayInstance()
				local arc = instance and findArc(snapshot, instance.ArcId) or snapshot and snapshot.Arcs[1]
				local definitionArc = definitionArcFor(arc)
				local reward = arcReward(definitionArc)
				local projection = reward and reward.Projection or {}
				local resolved = projection.Resolved ~= false
				local name = resolved and projection.DisplayName or projection.MysteryDisplayName
				-- This reward is granted by the arc's final quest, not the tracked one.
				local arcTitle = definitionArc and QuestCopy.ResolveLocalized(definitionArc.Title, copyContext())
				return {
					mode = "Hint",
					title = tostring(name or reward and reward.RewardKind or "Quest Reward") .. ":",
					description = arcTitle and ("Complete every quest in %s to unlock."):format(arcTitle)
						or "Complete every quest in this line to unlock.",
				}
			end,
		})
	end

	local function renderSelector()
		local selected = selectedInstance(snapshot)
		local arc = selected and findArc(snapshot, selected.ArcId) or snapshot and snapshot.Arcs[1]
		renderArcHeader(selectorArcHeader, arc, false)
		local visible = {}
		for _, instanceId in ipairs(arc and arc.InstanceIds or {}) do
			local instance = findInstance(snapshot, instanceId)
			if instance and not (snapshot.HideCompleted and instance.Completed) then table.insert(visible, instance) end
		end
		for index, row in ipairs(rows) do
			local instance = visible[index]
			row.Visible = instance ~= nil
			row.Active = instance ~= nil and instance.Completed ~= true
			row.Selectable = instance ~= nil and instance.Completed ~= true
			row:SetAttribute("InstanceId", instance and instance.InstanceId or nil)
			if instance then
				local definition = content.DefinitionsById[instance.DefinitionId]
				setText(child(row, "QuestTitle", "TextLabel", true), definition and QuestCopy.ResolveLocalized(definition.Title, copyContext()) or instance.QuestId)
				local stepState = instance.Completed and "" or (("%d/%d"):format(instance.StepIndex, instance.StepCount))
				setText(child(row, "QuestStep", "TextLabel", true), stepState)
				local tick = child(row, "CompletedTick", "ImageLabel", true)
				if tick then tick.Visible = instance.Completed end
				local stroke = row:FindFirstChildWhichIsA("UIStroke")
				if stroke then stroke.Color = instance.Completed and SELECTED_COLOR or UNSELECTED_COLOR end
			end
		end
		if hideCompleted then
			local hidden = snapshot and snapshot.HideCompleted == true
			local eyeVisible = child(hideCompleted, "EyeVisible", "GuiObject", true)
			local eyeHidden = child(hideCompleted, "EyeHidden", "GuiObject", true)
			if eyeVisible then eyeVisible.Visible = not hidden end
			if eyeHidden then eyeHidden.Visible = hidden end
			setText(child(hideCompleted, "AccessibleLabel", "TextLabel", true), hidden and "Show completed quests" or "Hide completed quests")
		end
		local focus = {}
		for _, row in ipairs(rows) do
			if row.Visible and row.Selectable then
				table.insert(focus, row)
			end
		end
		if hideCompleted and hideCompleted.Visible and hideCompleted.Selectable then
			table.insert(focus, hideCompleted)
		end
		for index, button in ipairs(focus) do
			button.NextSelectionUp = focus[index - 1] or focus[#focus]
			button.NextSelectionDown = focus[index + 1] or focus[1]
		end
		if selectorOpen then
			task.defer(function()
				if selectorOpen then
					local layout = selector:FindFirstChildWhichIsA("UIListLayout")
					local padding = selector:FindFirstChildWhichIsA("UIPadding")
					local paddingHeight = padding and padding.PaddingTop.Offset + padding.PaddingBottom.Offset or 0
					local contentHeight = layout and layout.AbsoluteContentSize.Y or 92
					selector.Size = UDim2.new(1, 0, 0, math.min(112, contentHeight + paddingHeight))
				end
			end)
		end
	end

	local function updateSelectorSize()
		local layout = selector:FindFirstChildWhichIsA("UIListLayout")
		local padding = selector:FindFirstChildWhichIsA("UIPadding")
		local paddingHeight = padding and padding.PaddingTop.Offset + padding.PaddingBottom.Offset or 0
		local contentHeight = layout and layout.AbsoluteContentSize.Y or 92
		selector.Size = UDim2.new(1, 0, 0, math.min(112, contentHeight + paddingHeight))
	end

	local function setSelectorOpen(value)
		selectorOpen = value == true
		root:SetAttribute("QuestSelectorOpen", selectorOpen)
		selector.Visible = selectorOpen
		selector.ScrollingEnabled = selectorOpen
		trackedRow.Visible = not selectorOpen and displayInstance() ~= nil
		if selectorOpen then
			selector.AutomaticCanvasSize = Enum.AutomaticSize.Y
			updateSelectorSize()
			local firstSelectable
			for _, row in ipairs(rows) do
				if row.Visible and row.Selectable then
					firstSelectable = row
					break
				end
			end
			if UserInputService.PreferredInput == Enum.PreferredInput.Gamepad then
				local selection = firstSelectable or hideCompleted
				if selection and selection.Visible and selection:IsDescendantOf(screenGui) then
					GuiService.SelectedObject = selection
				end
			end
		elseif GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(selector) then
			GuiService.SelectedObject = arcHeaderButton or trackedTitleButton or collapseButton
		end
		if not selectorOpen then
			selector.Size = UDim2.new(1, 0, 0, 0)
		end
	end

	local function renderReward(instance)
		local reward = instance and instance.Rewards and instance.Rewards[1]
		if not reward then
			rewardStrip.Visible = false
			return
		end
		rewardStrip.Visible = true
		if reward.RewardKind == "Gems" then
			setText(rewardLabel, reward.Granted and "Received" or "Reward")
			setText(rewardAmount, tostring(math.floor(tonumber(reward.Projection.Amount) or 0)))
			if rewardIcon then rewardIcon.Visible = true end
		else
			setText(rewardLabel, reward.Granted and "Unlocked" or "Reward")
			setText(rewardAmount, tostring((reward.Projection.Resolved ~= false and reward.Projection.DisplayName)
				or reward.Projection.MysteryDisplayName or reward.RewardKind))
			if rewardIcon then rewardIcon.Visible = false end
		end
	end

	local function renderTrackedCard(instance)
		local definition = content.DefinitionsById[instance.DefinitionId]
		local projection = instance.CurrentStep.Projection
		local definitionId = instance.DefinitionId
		local stepId = instance.CurrentStep.StepId
		if eventDisplay then
			definitionId = eventDisplay.DefinitionId or definitionId
			stepId = eventDisplay.StepId or stepId
			projection = eventDisplay.Projection or projection
		end
		local step = definition and definition.StepById[stepId]
		local localCardProjection
		if step and step.LocalProgress then
			if localProgress and localProgress.StepId == stepId then
				localCardProjection = {
					Satisfied = localProgress.Current >= localProgress.Target,
					Phase = localProgress.Current >= localProgress.Target and "Satisfied" or "Waiting",
					Current = localProgress.Current,
					Target = localProgress.Target,
					Tokens = { Current = localProgress.Current, Target = localProgress.Target },
				}
			elseif eventDisplay and eventDisplay.Kind == "LocalPresentationMilestone" then
				-- Freeze the completed local count with its outgoing copy until the
				-- strike releases; a newer server snapshot must not remove only “(5/5)”.
				localCardProjection = projection
			elseif not eventDisplay and instance.CurrentStep.StepId == stepId then
				-- Local progress has not fired yet, so render the declared zero state
				-- instead of making the count appear only after the first interaction.
				localCardProjection = {
					Satisfied = false,
					Phase = "Waiting",
					Current = 0,
					Target = step.LocalProgress.Target,
					Tokens = { Current = 0, Target = step.LocalProgress.Target },
				}
			end
		end
		if localCardProjection then
			projection = localCardProjection
			local rendered = QuestCopy.Render(step.LocalProgress.Card, projection, copyContext())
			setText(trackedDescription, rendered or "")
		else
			projection = resolveLiveProgress(step, projection)
			setText(trackedDescription, renderDescription(definitionId, stepId, projection))
		end
		setText(trackedTitle, definition and QuestCopy.ResolveLocalized(definition.Title, copyContext()) or instance.QuestId)
		local counted = isCountedStep(step, projection)
		if questProgressBar and not barAwaitingPresentation then questProgressBar.Visible = counted end
		if questProgressFill and not barAwaitingPresentation then
			if questProgressTween then questProgressTween:Cancel() end
			if counted then
				questProgressTween = UiMotion.create(
					questProgressFill,
					TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Size = UDim2.fromScale(stepProgress(projection), 1) }
				)
				questProgressTween:Play()
			else
				-- Snap empty while hidden so the next counted step starts from zero instead
				-- of animating down from the previous step's fill on its first visible frame.
				questProgressFill.Size = UDim2.fromScale(0, 1)
			end
		end
	end

	local function render()
		if replay then
			root.Visible = true
			setText(trackedTitle, replay.Title)
			setText(trackedDescription, replay.Description)
			rewardStrip.Visible = false
			-- Replay carries its own whole-chapter progress rather than a step count, so the
			-- bar stays visible here and keeps showing that.
			if questProgressBar then questProgressBar.Visible = true end
			if questProgressFill then
				questProgressFill.Size = UDim2.fromScale(math.clamp(replay.Progress or 0, 0, 1), 1)
			end
			local selected = selectedInstance(snapshot)
			local arc = selected and findArc(snapshot, selected.ArcId) or snapshot and snapshot.Arcs[1]
			root:SetAttribute("Progress", arcProgress(arc, selected))
			trackedRow.Visible = not selectorOpen
			return
		end
		local instance = displayInstance()
		root.Visible = instance ~= nil
		trackedRow.Visible = not selectorOpen and instance ~= nil
		if not instance then return end
		renderTrackedCard(instance)
		local arc = findArc(snapshot, instance.ArcId)
		root:SetAttribute("Progress", arcProgress(arc, instance))
		renderArcHeader(arcHeader, arc, true)
		renderReward(instance)
		renderSelector()
	end

	local function setExpanded(value, animate)
		expanded = value == true
		root:SetAttribute("QuestsExpanded", expanded)
		if not expanded then setSelectorOpen(false) end
		if arcHeaderButton then
			arcHeaderButton.Visible = expanded
			arcHeaderButton.Active = expanded
			arcHeaderButton.Interactable = expanded
			arcHeaderButton.Selectable = expanded
		end
		if revealTween then revealTween:Cancel() end
		if arcTween then arcTween:Cancel() end
		questList.Visible = true
		if arcHeaderClip then arcHeaderClip.Visible = true end
		local info = expanded and OPEN_INFO or CLOSE_INFO
		local questTarget = expanded and openPosition or closedPosition
		local arcTarget = expanded and arcOpenPosition or arcClosedPosition
		if animate then
			revealTween = UiMotion.create(questList, info, { Position = questTarget })
			local current = revealTween
			current.Completed:Once(function(state)
				if revealTween == current and state == Enum.PlaybackState.Completed then
					revealTween = nil
					questList.Visible = expanded
				end
			end)
			revealTween:Play()
			if arcHeader and arcTarget then arcTween = UiMotion.create(arcHeader, info, { Position = arcTarget }); arcTween:Play() end
		else
			questList.Position = questTarget
			questList.Visible = expanded
			if arcHeader and arcTarget then arcHeader.Position = arcTarget end
		end
		if toggleFrame and toggleOpenPosition then
			toggleFrame.Position = expanded and toggleOpenPosition or toggleOpenPosition
		end
	end

	connect(collapseButton.Activated, function() setExpanded(not expanded, true) end)
	connect(UserInputService.InputBegan, function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.Q and UserInputService:GetFocusedTextBox() == nil
			and snapshot and root.Visible
		then
			setExpanded(not expanded, true)
		end
	end)
	if arcHeaderButton then connect(arcHeaderButton.Activated, function() setSelectorOpen(not selectorOpen) end) end
	if trackedTitleButton then connect(trackedTitleButton.Activated, function() setSelectorOpen(not selectorOpen) end) end
	if hideCompleted then
		connect(hideCompleted.Activated, function()
			if snapshot and config.OnSetHideCompleted then config.OnSetHideCompleted(snapshot.HideCompleted ~= true) end
		end)
	end
	for _, row in ipairs(rows) do
		connect(row.Activated, function()
			local instanceId = row:GetAttribute("InstanceId")
			local instance = findInstance(snapshot, instanceId)
			if instance and not instance.Completed and config.OnSelectInstance then
				config.OnSelectInstance(instance.InstanceId)
			end
			setSelectorOpen(false)
		end)
	end
	connect(UserInputService:GetPropertyChangedSignal("PreferredInput"), render)
	setExpanded(expanded, false)
	setSelectorOpen(false)
	render()

	return {
		ApplySnapshot = function(nextSnapshot, metadata)
			-- Transitions accompanying this snapshot mean a presentation is coming for the
			-- step being left behind; no transitions means this snapshot IS the current
			-- state and the bar should track it (which also releases a hold that a
			-- suppressed presentation queue would otherwise strand).
			barAwaitingPresentation = (tonumber(metadata and metadata.TransitionCount) or 0) > 0
			snapshot = nextSnapshot
			if localProgress then
				local selected = selectedInstance(snapshot)
				if not selected or selected.CurrentStep.StepId ~= localProgress.StepId then localProgress = nil end
			end
			render()
		end,
		RenderEvent = function(context)
			local transition = context.Transition or {}
			barAwaitingPresentation = false
			eventDisplay = {
				Kind = transition.Kind,
				InstanceId = transition.InstanceId,
				DefinitionId = transition.DefinitionId,
				StepId = transition.StepId,
				StepIndex = transition.StepIndex,
				Projection = transition.Projection,
			}
			render()
		end,
		RenderCurrent = function()
			barAwaitingPresentation = false
			eventDisplay = nil
			render()
		end,
		RefreshLiveProgress = function()
			-- Ordered event copy is frozen at event time. Replacing its text beneath an
			-- active strike would desynchronize the overlay geometry and ceremony.
			if replay or eventDisplay or completionInstanceId or barAwaitingPresentation then return end
			local instance = not replay and displayInstance() or nil
			if instance then renderTrackedCard(instance) end
		end,
		BeginCompletion = function(context)
			completionInstanceId = context.Transition and context.Transition.InstanceId
			render()
		end,
		EndCompletion = function()
			completionInstanceId = nil
			-- Preserve the completed event copy when there is no successor. Its
			-- strike is the terminal state of the tracked card, not a transition
			-- overlay waiting to be cleared.
			if selectedInstance(snapshot) then eventDisplay = nil end
			render()
		end,
		ResetPresentation = function()
			barAwaitingPresentation = false
			eventDisplay = nil
			completionInstanceId = nil
			localProgress = nil
		end,
		SetLocalProgress = function(stepId, current, target)
			target = math.max(1, math.floor(tonumber(target) or 1))
			localProgress = { StepId = tostring(stepId), Current = math.clamp(math.floor(tonumber(current) or 0), 0, target), Target = target }
			render()
		end,
		renderReplay = function(nextReplay)
			replay = nextReplay
			setSelectorOpen(false)
			render()
		end,
		GetDescription = function() return trackedDescription end,
		GetDisplayedInstance = displayInstance,
		GetRewardSource = function() return rewardIcon or rewardStrip end,
		destroy = function()
			if revealTween then revealTween:Cancel() end
			if arcTween then arcTween:Cancel() end
			if questProgressTween then questProgressTween:Cancel() end
			if rewardTooltipRegistration then rewardTooltipRegistration:disconnect() end
			for _, connection in ipairs(connections) do connection:Disconnect() end
			table.clear(connections)
		end,
	}
end

return QuestProgressQuestList
