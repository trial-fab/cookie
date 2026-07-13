local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local UiMotion = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiMotion"))

local StoreDescription = {}

local TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LOCK_HEIGHT_TO_TEXT = true -- Set false to use the Studio-authored description height.

local function findInfoButton(row)
	local info = row:FindFirstChild("info", true)
	return info and info:IsA("GuiObject") and info or nil
end

local function findDescription(row)
	for _, descendant in ipairs(row:GetDescendants()) do
		if descendant:IsA("GuiObject") and descendant.Name == "Description" then
			local label = descendant:FindFirstChild("Description")
			if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
				return descendant, label
			end
		end
	end
	return nil, nil
end

local function resolve(udim, parentPixels)
	return parentPixels * udim.Scale + udim.Offset
end

local function getPadding(gui, axis, parentPixels)
	local padding = gui:FindFirstChildWhichIsA("UIPadding")
	if not padding then
		return 0
	end

	local first = axis == "X" and padding.PaddingLeft or padding.PaddingTop
	local second = axis == "X" and padding.PaddingRight or padding.PaddingBottom
	return resolve(first, parentPixels) + resolve(second, parentPixels)
end

local function measureHeight(record)
	local frame = record.frame
	local label = record.label
	local parentSize = frame.Parent.AbsoluteSize
	local frameWidth = math.max(1, resolve(record.expandedSize.X, parentSize.X))
	local contentWidth = math.max(1, frameWidth - getPadding(frame, "X", frameWidth))
	local labelWidth = math.max(1, resolve(record.labelSize.X, contentWidth))
	labelWidth = math.max(1, labelWidth - getPadding(label, "X", labelWidth))

	local params = Instance.new("GetTextBoundsParams")
	params.Text = label.Text
	params.Font = label.FontFace
	params.Size = label.TextSize
	params.Width = labelWidth
	params.RichText = label.RichText
	local ok, bounds = pcall(function()
		return TextService:GetTextBoundsAsync(params)
	end)
	params:Destroy()

	local textHeight = ok and bounds.Y or math.max(label.TextBounds.Y, label.TextSize)
	local labelHeight = math.ceil(textHeight + getPadding(label, "Y", textHeight))
	label.Size = UDim2.new(record.labelSize.X.Scale, record.labelSize.X.Offset, 0, labelHeight)
	return math.max(record.info.AbsoluteSize.Y, labelHeight + getPadding(frame, "Y", labelHeight))
end

local function collapsedGeometry(record)
	local info = record.info
	local parent = record.frame.Parent
	local anchor = info.AnchorPoint

	if info.Parent == parent then
		return {
			AnchorPoint = anchor,
			Position = info.Position,
			Size = info.Size,
		}
	end

	local parentPosition = parent:IsA("GuiObject") and parent.AbsolutePosition or Vector2.zero
	local parentSize = parent:IsA("GuiObject") and parent.AbsoluteSize or Vector2.zero
	local anchorOffset = Vector2.new(info.AbsoluteSize.X * anchor.X, info.AbsoluteSize.Y * anchor.Y)
	local anchorPosition = info.AbsolutePosition - parentPosition + anchorOffset
	local width = math.max(1, parentSize.X)
	local height = math.max(1, parentSize.Y)

	local size = UDim2.fromScale(info.AbsoluteSize.X / width, info.AbsoluteSize.Y / height)
	return {
		AnchorPoint = anchor,
		Position = UDim2.fromScale(anchorPosition.X / width, anchorPosition.Y / height),
		Size = size,
	}
end

function StoreDescription.new(ctx)
	local records = setmetatable({}, { __mode = "k" })
	local setExpanded
	local activeRecord
	local function hideInfoStroke(record, hidden)
		if record.infoStroke then
			record.infoStroke.Transparency = hidden and 1 or record.infoStrokeTransparency
		end
	end

	local function closeWhenUnhovered(record)
		task.defer(function()
			if not record.overInfo and not record.overFrame and record.frame.Parent then
				setExpanded(record, false)
			end
		end)
	end

	setExpanded = function(record, expanded)
		if expanded and activeRecord ~= record then
			if activeRecord then
				setExpanded(activeRecord, false)
			end
			activeRecord = record
		elseif not expanded and activeRecord == record then
			activeRecord = nil
		end
		record.expanded = expanded
		record.token += 1
		local token = record.token
		if record.tween then
			record.tween:Cancel()
		end
		if record.textTween then
			record.textTween:Cancel()
		end
		if expanded or record.frame.Visible then
			hideInfoStroke(record, true)
		end

		local goals
		if expanded then
			local wasHidden = not record.frame.Visible
			local height = LOCK_HEIGHT_TO_TEXT and measureHeight(record)
				or resolve(record.expandedSize.Y, record.frame.Parent.AbsoluteSize.Y)
			if record.token ~= token or not record.frame.Parent then
				return
			end
			if wasHidden then
				local collapsed = collapsedGeometry(record)
				record.frame.AnchorPoint = collapsed.AnchorPoint
				record.frame.Position = collapsed.Position
				record.frame.Size = collapsed.Size
				record.label.TextTransparency = 1
				record.label.TextStrokeTransparency = 1
				record.frame.Visible = true
			end
			goals = {
				AnchorPoint = record.expandedAnchorPoint,
				Position = record.expandedPosition,
				Size = UDim2.new(record.expandedSize.X.Scale, record.expandedSize.X.Offset, 0, height),
			}
		else
			goals = collapsedGeometry(record)
		end

		local textGoals = {
			TextTransparency = expanded and record.textTransparency or 1,
			TextStrokeTransparency = expanded and record.textStrokeTransparency or 1,
		}

		record.tween = UiMotion.create(record.frame, TWEEN_INFO, goals)
		record.textTween = UiMotion.create(record.label, TWEEN_INFO, textGoals)
		record.tween:Play()
		record.textTween:Play()
		if not expanded then
			record.tween.Completed:Once(function()
				if record.token == token and record.frame.Parent then
					record.frame.Visible = false
					hideInfoStroke(record, false)
				end
			end)
		end
	end

	local function setup(row, upgradeId)
		if records[row] then
			return records[row]
		end

		local info = findInfoButton(row)
		local frame, label = findDescription(row)
		if not (info and frame and label) then
			return nil
		end
		local touchTarget = row:FindFirstChild("InfoHitbox", true)
		if not (touchTarget and touchTarget:IsA("GuiButton")) then
			touchTarget = info
		else
			touchTarget.Visible = UserInputService.TouchEnabled
		end

		label.Text = (ctx.UpgradeConfig[upgradeId] and ctx.UpgradeConfig[upgradeId].Description) or ""
		local record = {
			info = info,
			infoStroke = info:FindFirstChildWhichIsA("UIStroke", true),
			touchTarget = touchTarget,
			frame = frame,
			label = label,
			labelSize = label.Size,
			textTransparency = label.TextTransparency,
			textStrokeTransparency = label.TextStrokeTransparency,
			expandedAnchorPoint = frame.AnchorPoint,
			expandedPosition = frame.Position,
			expandedSize = frame.Size,
			expanded = false,
			overInfo = false,
			overFrame = false,
			token = 0,
		}
		record.infoStrokeTransparency = record.infoStroke and record.infoStroke.Transparency or 1
		records[row] = record
		frame.Visible = false

		info.MouseEnter:Connect(function()
			if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
				return
			end
			record.overInfo = true
			setExpanded(record, true)
		end)
		info.MouseLeave:Connect(function()
			if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
				return
			end
			record.overInfo = false
			closeWhenUnhovered(record)
		end)
		touchTarget.Activated:Connect(function(input)
			if
				UserInputService.PreferredInput == Enum.PreferredInput.Touch
				or (input and input.UserInputType == Enum.UserInputType.Touch)
			then
				setExpanded(record, not record.expanded)
			end
		end)
		info.SelectionGained:Connect(function()
			setExpanded(record, true)
		end)
		info.SelectionLost:Connect(function()
			closeWhenUnhovered(record)
		end)
		frame.MouseEnter:Connect(function()
			if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
				return
			end
			record.overFrame = true
			setExpanded(record, true)
		end)
		frame.MouseLeave:Connect(function()
			if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
				return
			end
			record.overFrame = false
			closeWhenUnhovered(record)
		end)

		return record
	end

	UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch or not activeRecord then
			return
		end

		local point = Vector2.new(input.Position.X, input.Position.Y)
		if not ctx.screenGui.IgnoreGuiInset then
			point -= GuiService:GetGuiInset()
		end
		local function contains(object)
			local position = object.AbsolutePosition
			local size = object.AbsoluteSize
			return point.X >= position.X
				and point.X <= position.X + size.X
				and point.Y >= position.Y
				and point.Y <= position.Y + size.Y
		end

		if not contains(activeRecord.touchTarget) and not contains(activeRecord.frame) then
			setExpanded(activeRecord, false)
		end
	end)

	return {
		setup = setup,
	}
end

return StoreDescription
