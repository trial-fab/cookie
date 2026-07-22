-- Profile title selector. All visual instances are authored under Header.TitleSelector; this
-- module clones the approved row template, drives the chevron/dropdown motion, and sends only
-- server-validated title IDs. Locked rows expose their level requirement through CursorTooltip.
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local CursorTooltip = require(Shared:WaitForChild("CursorTooltip"))
local Net = require(Shared:WaitForChild("Net"))
local TitleTextEffects = require(Shared:WaitForChild("TitleTextEffects"))
local UiMotion = require(Shared:WaitForChild("UiMotion"))
local XpConfig = require(Shared:WaitForChild("XpConfig"))

local ProfileTitleSelector = {}

local OPEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local ICON_OPEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ICON_CLOSE_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TITLE_MOVE_INFO = TweenInfo.new(0.24, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local RESET_MOTION_INFO = TweenInfo.new(0.48, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local ICON_GAP = 4

local function isText(instance)
	return instance and (instance:IsA("TextLabel") or instance:IsA("TextButton"))
end

local function pointInside(guiObject, point)
	if not (guiObject and guiObject.Visible) then
		return false
	end
	local topLeft = guiObject.AbsolutePosition
	local size = guiObject.AbsoluteSize
	return point.X >= topLeft.X
		and point.X <= topLeft.X + size.X
		and point.Y >= topLeft.Y
		and point.Y <= topLeft.Y + size.Y
end

function ProfileTitleSelector.bind(ctx)
	local header = ctx.body:FindFirstChild("Header", true)
	local root = header and header:FindFirstChild("TitleSelector")
	local currentLabel = header and header:FindFirstChild("PlayerTitle", true)
	if not (root and root:IsA("GuiObject") and isText(currentLabel)) then
		return {
			refresh = function() end,
			close = function() end,
		}
	end
	if root:GetAttribute("ExemplarApproved") ~= true then
		root.Visible = false
		return {
			refresh = function() end,
			close = function() end,
		}
	end

	local toggleButton = root:FindFirstChild("ToggleButton", true)
	local dropdown = root:FindFirstChild("Dropdown", true)
	local rowTemplate = dropdown and dropdown:FindFirstChild("TitleRowTemplate")
	local resetButton = root:FindFirstChild("ResetAutoButton", true)
	local controls = root:FindFirstChild("Controls")
	local iconRail = controls and controls:FindFirstChild("IconRail")
	local chevron = root:FindFirstChild("Chevron", true)
	local leftLine = chevron and chevron:FindFirstChild("LeftLine")
	local rightLine = chevron and chevron:FindFirstChild("RightLine")
	if
		not (
			toggleButton
			and toggleButton:IsA("GuiButton")
			and dropdown
			and dropdown:IsA("ScrollingFrame")
			and rowTemplate
			and rowTemplate:IsA("GuiButton")
			and resetButton
			and resetButton:IsA("ImageButton")
			and controls
			and controls:IsA("GuiObject")
			and iconRail
			and iconRail:IsA("GuiObject")
			and leftLine
			and leftLine:IsA("GuiObject")
			and rightLine
			and rightLine:IsA("GuiObject")
		)
	then
		warn("ProfileTitleSelector disabled: TitleSelector exemplar is incomplete")
		return {
			refresh = function() end,
			close = function() end,
		}
	end

	local tooltip = CursorTooltip.get(ctx.screenGui)
	local currentEffects = TitleTextEffects.bind(currentLabel)
	local authoredDropdownSize = dropdown.Size
	local rowsById = {}
	local effectHandles = {}
	local registrations = {}
	local open = false
	local selecting = false
	local selectedTitleId = ctx.player:GetAttribute(Attrs.SelectedTitleId) or XpConfig.AutoTitleId
	local dropdownTween
	local iconMoveTween
	local resetTween
	local resetRetiring = false
	local resetSpinCompleted = false
	local resetRestRotation = resetButton.Rotation % 360
	local previousAuto
	local displayedTitle
	local displayedTitleWidth
	local transitioningTitle
	local titleTransitionGeneration = 0
	local iconTweens = {}
	local parentScrollingFrame = dropdown:FindFirstAncestorWhichIsA("ScrollingFrame")
	local parentScrollBlocked = false
	local parentScrollRestoreEnabled = true

	rowTemplate.Visible = false
	dropdown.Visible = false
	dropdown.Size = UDim2.new(authoredDropdownSize.X.Scale, authoredDropdownSize.X.Offset, 0, 0)

	local function playIconTween(line, tweenInfo, rotation)
		local previous = iconTweens[line]
		if previous then
			previous:Cancel()
		end
		local tween = UiMotion.create(line, tweenInfo, { Rotation = rotation })
		iconTweens[line] = tween
		tween.Completed:Once(function()
			if iconTweens[line] == tween then
				iconTweens[line] = nil
			end
		end)
		tween:Play()
	end

	local function setParentScrollBlocked(value)
		if not parentScrollingFrame or parentScrollBlocked == value then
			return
		end
		parentScrollBlocked = value
		if value then
			parentScrollRestoreEnabled = parentScrollingFrame.ScrollingEnabled
			parentScrollingFrame.ScrollingEnabled = false
		else
			parentScrollingFrame.ScrollingEnabled = parentScrollRestoreEnabled
		end
	end

	local function setOpen(value, instant)
		value = value == true and ctx.isVisible()
		if open == value and not instant then
			return
		end
		open = value
		if not open then
			setParentScrollBlocked(false)
		end
		root:SetAttribute(Attrs.Open, open)
		toggleButton:SetAttribute(Attrs.Active, open)

		if dropdownTween then
			dropdownTween:Cancel()
			dropdownTween = nil
		end
		if instant then
			dropdown.Size = open and authoredDropdownSize
				or UDim2.new(authoredDropdownSize.X.Scale, authoredDropdownSize.X.Offset, 0, 0)
			dropdown.Visible = open
			leftLine.Rotation = open and -45 or 45
			rightLine.Rotation = open and 45 or -45
		else
			dropdown.Visible = true
			local goal = open and authoredDropdownSize
				or UDim2.new(authoredDropdownSize.X.Scale, authoredDropdownSize.X.Offset, 0, 0)
			local tween = UiMotion.create(dropdown, open and OPEN_INFO or CLOSE_INFO, { Size = goal })
			dropdownTween = tween
			tween.Completed:Once(function()
				if dropdownTween == tween then
					dropdownTween = nil
					if not open then
						dropdown.Visible = false
					end
				end
			end)
			tween:Play()
			playIconTween(leftLine, open and ICON_OPEN_INFO or ICON_CLOSE_INFO, open and -45 or 45)
			playIconTween(rightLine, open and ICON_OPEN_INFO or ICON_CLOSE_INFO, open and 45 or -45)
		end

		for titleId, handle in pairs(effectHandles) do
			local row = rowsById[titleId]
			handle.setActive(open and row and row:GetAttribute(Attrs.Active) == true)
		end
	end

	local refresh
	local function requestSelection(titleId)
		if selecting then
			return
		end
		selecting = true
		if titleId ~= XpConfig.AutoTitleId then
			resetRetiring = false
			if resetTween then
				resetTween:Cancel()
				resetTween = nil
			end
			resetButton.Rotation = resetRestRotation
			if resetButton.Visible then
				resetButton.ImageTransparency = 0
			end
		end
		refresh()
		task.spawn(function()
			local ok, result = pcall(function()
				return Net.invoke(Net.Names.SelectTitle, titleId)
			end)
			selecting = false
			if ok and type(result) == "table" and result.Success then
				selectedTitleId = result.SelectedTitleId or XpConfig.AutoTitleId
			end
			refresh()
		end)
	end

	for _, titleDef in ipairs(XpConfig.Titles) do
		local row = rowTemplate:Clone()
		row.Name = "TitleRow_" .. titleDef.Id
		row.LayoutOrder = titleDef.Order
		row:SetAttribute("TitleId", titleDef.Id)
		row:SetAttribute("RuntimeTitleRow", true)
		row.Visible = true
		row.Parent = dropdown
		rowsById[titleDef.Id] = row

		local nameLabel = row:FindFirstChild("TitleName", true)
		if isText(nameLabel) then
			nameLabel.Text = titleDef.Title
			effectHandles[titleDef.Id] = TitleTextEffects.bind(nameLabel)
		end

		registrations[titleDef.Id] = tooltip:registerGui(row, {
			trigger = CursorTooltip.Trigger.HoverAndClick,
			getContent = function()
				if row:GetAttribute("TitleUnlocked") == true then
					return nil
				end
				return {
					mode = "Hint",
					title = "Locked title",
					description = ("Reach Level %d to unlock."):format(titleDef.MinLevel),
				}
			end,
		})

		row.Activated:Connect(function()
			if selecting or row:GetAttribute("TitleUnlocked") ~= true then
				return
			end
			requestSelection(titleDef.Id)
		end)

		row.Destroying:Once(function()
			local registration = registrations[titleDef.Id]
			if registration then
				registration:disconnect()
			end
			local effectHandle = effectHandles[titleDef.Id]
			if effectHandle then
				effectHandle.destroy()
			end
		end)
	end

	local function objectWidth(guiObject, fallback)
		local width = math.ceil(guiObject.AbsoluteSize.X)
		if width <= 0 then
			width = math.ceil(guiObject.Size.X.Offset)
		end
		return math.max(fallback or 1, width)
	end

	local function objectHeight(guiObject, fallback)
		local height = math.ceil(guiObject.AbsoluteSize.Y)
		if height <= 0 then
			height = math.ceil(guiObject.Size.Y.Offset)
		end
		return math.max(fallback or 1, height)
	end

	local function measureTitle(text)
		local bounds = TextService:GetTextSize(
			text,
			currentLabel.TextSize,
			currentLabel.Font,
			Vector2.new(10000, objectHeight(currentLabel, 20))
		)
		return math.max(1, math.ceil(bounds.X))
	end

	local function setTitleWidth(width)
		currentLabel.AutomaticSize = Enum.AutomaticSize.None
		currentLabel.Size = UDim2.new(0, width, currentLabel.Size.Y.Scale, currentLabel.Size.Y.Offset)
		toggleButton.AutomaticSize = Enum.AutomaticSize.None
		toggleButton.Size = UDim2.new(
			0,
			width + ICON_GAP + objectWidth(chevron, 18),
			toggleButton.Size.Y.Scale,
			toggleButton.Size.Y.Offset
		)
	end

	local function layoutIconRail(includeReset)
		local chevronWidth = objectWidth(chevron, 18)
		local chevronHeight = objectHeight(chevron, 18)
		local resetWidth = objectWidth(resetButton, 18)
		local resetHeight = objectHeight(resetButton, 18)
		local railHeight = math.max(objectHeight(controls, 20), chevronHeight, resetHeight)
		local railWidth = chevronWidth
		if includeReset then
			railWidth += ICON_GAP + resetWidth
		end

		-- Vertical placement is authored in Studio. Runtime layout only owns the X axis.
		chevron.Position = UDim2.new(0, 0, chevron.Position.Y.Scale, chevron.Position.Y.Offset)
		resetButton.Position =
			UDim2.new(0, chevronWidth + ICON_GAP, resetButton.Position.Y.Scale, resetButton.Position.Y.Offset)
		iconRail.Size = UDim2.fromOffset(railWidth, railHeight)
		return railWidth
	end

	local function setContainerWidth(titleWidth, includeReset)
		local railWidth = layoutIconRail(includeReset)
		local width = math.max(1, titleWidth + ICON_GAP + railWidth)
		controls.Size = UDim2.new(0, width, controls.Size.Y.Scale, controls.Size.Y.Offset)
		root.Size = UDim2.new(0, width, root.Size.Y.Scale, root.Size.Y.Offset)
	end

	local function railPosition(titleWidth)
		return UDim2.new(0, titleWidth + ICON_GAP, iconRail.Position.Y.Scale, iconRail.Position.Y.Offset)
	end

	local function applyTitle(info, width)
		currentLabel.Text = info.title
		currentEffects.apply(info.titleDef, true)
		setTitleWidth(width)
		displayedTitle = info.title
		displayedTitleWidth = width
	end

	local function transitionTitle(info)
		local newWidth = measureTitle(info.title)
		local includeReset = resetButton.Visible
		if iconMoveTween and transitioningTitle == info.title then
			return
		end
		titleTransitionGeneration += 1
		local generation = titleTransitionGeneration
		if iconMoveTween then
			iconMoveTween:Cancel()
			iconMoveTween = nil
			transitioningTitle = nil
		end

		if displayedTitle == nil or not ctx.isVisible() then
			transitioningTitle = nil
			applyTitle(info, newWidth)
			iconRail.Position = railPosition(newWidth)
			setContainerWidth(newWidth, includeReset)
			return
		end

		if displayedTitle == info.title then
			transitioningTitle = nil
			currentEffects.apply(info.titleDef, true)
			setTitleWidth(newWidth)
			displayedTitleWidth = newWidth
			iconRail.Position = railPosition(newWidth)
			setContainerWidth(newWidth, includeReset)
			return
		end

		local oldWidth = displayedTitleWidth or measureTitle(displayedTitle)
		if newWidth > oldWidth then
			-- Make room first, glide the icons outward, then reveal the longer title.
			setContainerWidth(newWidth, includeReset)
		else
			-- Reveal the shorter title first, then let the icons settle beside it.
			applyTitle(info, newWidth)
			setContainerWidth(math.max(oldWidth, newWidth), includeReset)
		end

		local tween = UiMotion.create(iconRail, TITLE_MOVE_INFO, { Position = railPosition(newWidth) })
		iconMoveTween = tween
		transitioningTitle = info.title
		tween.Completed:Once(function(playbackState)
			if iconMoveTween ~= tween or generation ~= titleTransitionGeneration then
				return
			end
			iconMoveTween = nil
			transitioningTitle = nil
			if playbackState ~= Enum.PlaybackState.Completed then
				return
			end
			if newWidth > oldWidth then
				applyTitle(info, newWidth)
			end
			setContainerWidth(newWidth, resetButton.Visible)
		end)
		tween:Play()
	end

	local function cancelResetTween()
		if resetTween then
			resetTween:Cancel()
			resetTween = nil
		end
	end

	local finishResetRetire

	local function playResetArrival()
		cancelResetTween()
		resetButton.Visible = true
		resetButton.ImageTransparency = 1
		resetButton.Rotation = resetRestRotation
		local tween = UiMotion.create(resetButton, RESET_MOTION_INFO, {
			ImageTransparency = 0,
			Rotation = resetRestRotation + 180,
		})
		resetTween = tween
		tween.Completed:Once(function()
			if resetTween == tween then
				resetTween = nil
				resetButton.Rotation = resetRestRotation
			end
		end)
		tween:Play()
	end

	local function playResetDeparture()
		cancelResetTween()
		resetSpinCompleted = false
		resetButton.Visible = true
		resetButton.ImageTransparency = 0
		resetButton.Rotation = resetRestRotation
		local tween = UiMotion.create(resetButton, RESET_MOTION_INFO, { Rotation = resetRestRotation + 180 })
		resetTween = tween
		tween.Completed:Once(function(playbackState)
			if resetTween ~= tween then
				return
			end
			resetTween = nil
			resetButton.Rotation = resetRestRotation
			resetSpinCompleted = playbackState == Enum.PlaybackState.Completed
			finishResetRetire()
		end)
		tween:Play()
	end

	finishResetRetire = function()
		if not resetRetiring or not resetSpinCompleted or selecting then
			return
		end
		if selectedTitleId ~= XpConfig.AutoTitleId then
			resetRetiring = false
			resetButton.ImageTransparency = 0
			resetButton.Active = true
			resetButton.Selectable = true
			return
		end

		cancelResetTween()
		local tween = UiMotion.create(resetButton, RESET_MOTION_INFO, { ImageTransparency = 1 })
		resetTween = tween
		tween.Completed:Once(function(playbackState)
			if resetTween ~= tween then
				return
			end
			resetTween = nil
			if playbackState == Enum.PlaybackState.Completed then
				resetRetiring = false
				resetButton.Visible = false
				layoutIconRail(false)
				setContainerWidth(displayedTitleWidth or measureTitle(currentLabel.Text), false)
			end
		end)
		tween:Play()
	end

	local function updateResetMode(auto)
		if previousAuto == nil then
			resetButton.Visible = not auto
			resetButton.ImageTransparency = auto and 1 or 0
		elseif previousAuto and not auto then
			playResetArrival()
		elseif auto and not resetRetiring then
			cancelResetTween()
			resetButton.Visible = false
			resetButton.ImageTransparency = 1
		elseif not auto then
			resetButton.Visible = true
		end
		previousAuto = auto
		layoutIconRail(resetButton.Visible)
	end

	refresh = function()
		local info = XpConfig.GetLevelInfo(ctx.player:GetAttribute(Attrs.Xp), selectedTitleId)
		selectedTitleId = info.selectedTitleId
		local auto = selectedTitleId == XpConfig.AutoTitleId
		updateResetMode(auto)
		transitionTitle(info)
		currentEffects.setActive(ctx.isVisible())
		resetButton.Active = not selecting and not auto and not resetRetiring
		resetButton.Selectable = not auto and not resetRetiring
		finishResetRetire()

		for _, titleDef in ipairs(XpConfig.Titles) do
			local row = rowsById[titleDef.Id]
			local unlocked = info.level >= titleDef.MinLevel
			local selected = info.titleId == titleDef.Id
			row:SetAttribute("TitleUnlocked", unlocked)
			row:SetAttribute(Attrs.Active, selected)
			row.Active = not selecting
			row.AutoButtonColor = unlocked and not selecting

			local lockMarker = row:FindFirstChild("LockMarker", true)
			if lockMarker and lockMarker:IsA("GuiObject") then
				lockMarker.Visible = not unlocked
			end
			local selectionStroke = row:FindFirstChild("SelectionStroke", true)
			if selectionStroke and selectionStroke:IsA("UIStroke") then
				selectionStroke.Enabled = selected
			end
			local effectHandle = effectHandles[titleDef.Id]
			if effectHandle then
				effectHandle.apply(titleDef, unlocked)
				effectHandle.setActive(open and unlocked and selected)
			end
			local registration = registrations[titleDef.Id]
			if registration then
				registration:refresh()
			end
		end
	end

	resetButton.Activated:Connect(function()
		if selecting or resetRetiring or selectedTitleId == XpConfig.AutoTitleId then
			return
		end
		resetRetiring = true
		playResetDeparture()
		requestSelection(XpConfig.AutoTitleId)
	end)

	toggleButton.Activated:Connect(function()
		setOpen(not open, false)
	end)

	dropdown.MouseEnter:Connect(function()
		if open then
			setParentScrollBlocked(true)
		end
	end)
	dropdown.MouseLeave:Connect(function()
		setParentScrollBlocked(false)
	end)

	UserInputService.InputBegan:Connect(function(input)
		if not open then
			return
		end
		local inputType = input.UserInputType
		if
			inputType ~= Enum.UserInputType.MouseButton1
			and inputType ~= Enum.UserInputType.MouseButton2
			and inputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local point = Vector2.new(input.Position.X, input.Position.Y)
		if not ctx.screenGui.IgnoreGuiInset then
			point -= GuiService:GetGuiInset()
		end
		if not pointInside(root, point) and not pointInside(dropdown, point) then
			setOpen(false, false)
		end
	end)

	ctx.player:GetAttributeChangedSignal(Attrs.Xp):Connect(refresh)
	ctx.player:GetAttributeChangedSignal(Attrs.SelectedTitleId):Connect(function()
		selectedTitleId = ctx.player:GetAttribute(Attrs.SelectedTitleId) or XpConfig.AutoTitleId
		refresh()
	end)
	ctx.modal:GetAttributeChangedSignal(Attrs.Open):Connect(function()
		if not ctx.isVisible() then
			setOpen(false, true)
		end
		refresh()
	end)

	setOpen(false, true)
	refresh()

	return {
		refresh = refresh,
		close = function()
			setOpen(false, false)
		end,
		destroy = function()
			setParentScrollBlocked(false)
			cancelResetTween()
			if iconMoveTween then
				iconMoveTween:Cancel()
				iconMoveTween = nil
				transitioningTitle = nil
			end
			currentEffects.destroy()
		end,
	}
end

return ProfileTitleSelector
