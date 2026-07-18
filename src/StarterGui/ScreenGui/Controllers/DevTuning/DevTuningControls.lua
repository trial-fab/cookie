-- DevTuningControls: generated feature groups, typed controls, search, and server applies.

local UserInputService = game:GetService("UserInputService")

local DevTuningControls = {}

local ROW_HEIGHT = 112
local SLIDER_ROW_HEIGHT = 146
local CONTROL_HEIGHT = 40
-- Ranges with more steps than this are impossible to set precisely by sliding;
-- they keep the text box only (e.g. MultiPlaceCounterTestCount's huge range).
local MAX_SLIDER_STEPS = 10000

local function addCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addStroke(parent, color)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Transparency = 0.25
	stroke.Thickness = 2
	stroke.Parent = parent
end

local function sliderEligible(definition)
	return definition.kind == "number"
		and type(definition.min) == "number"
		and type(definition.max) == "number"
		and definition.max > definition.min
		and (definition.max - definition.min) / math.max(definition.step or 0, 1e-9) <= MAX_SLIDER_STEPS
end

local function makeButton(name, text, parent, ctx)
	local button = Instance.new("TextButton")
	button.Name = name
	button.AutoButtonColor = true
	button.BackgroundColor3 = ctx.colors.surface
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Font = Enum.Font.ArialBold
	button.Text = text
	button.TextColor3 = ctx.colors.text
	button.TextSize = 14
	button.Parent = parent
	addCorner(button, 7)
	addStroke(button, ctx.colors.border)
	return button
end

local function makeTextBox(name, parent, ctx)
	local box = Instance.new("TextBox")
	box.Name = name
	box.BackgroundColor3 = Color3.fromRGB(21, 24, 32)
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.Arial
	box.TextColor3 = ctx.colors.text
	box.TextSize = 14
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Parent = parent
	addCorner(box, 7)
	addStroke(box, ctx.colors.border)

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = box
	return box
end

local function formatNumber(value)
	return ("%.10g"):format(value)
end

local function formatColor(value)
	return ("%d, %d, %d"):format(math.round(value.R * 255), math.round(value.G * 255), math.round(value.B * 255))
end

local function parseColor(text)
	local red, green, blue = string.match(text, "^%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*$")
	red, green, blue = tonumber(red), tonumber(green), tonumber(blue)
	if not red or not green or not blue then
		return nil
	end
	if red ~= red or green ~= green or blue ~= blue then
		return nil
	end
	return Color3.fromRGB(math.clamp(red, 0, 255), math.clamp(green, 0, 255), math.clamp(blue, 0, 255))
end

local function submit(ctx, definition, candidateValue)
	if ctx.pending[definition.fullId] then
		return
	end
	ctx.pending[definition.fullId] = true
	ctx.setStatus("Applying " .. definition.fullId .. "...", false)

	local ok, result = pcall(ctx.Net.invoke, ctx.Net.Names.DevTuningApply, definition.fullId, candidateValue)
	ctx.pending[definition.fullId] = nil
	if not ok then
		ctx.setStatus("Apply failed: " .. tostring(result), true)
	elseif type(result) ~= "table" or result.success ~= true then
		local reason = type(result) == "table" and result.reason or "MalformedResponse"
		ctx.setStatus("Apply rejected: " .. tostring(reason), true)
	else
		ctx.setStatus("Applied " .. definition.fullId .. "; awaiting replication.", false)
	end
end

local function submitAsync(ctx, definition, candidateValue)
	task.spawn(submit, ctx, definition, candidateValue)
end

-- Drag slider for bounded numeric tunables. Applies throttled live submits while
-- dragging (so previews react in real time) and a final submit on release; the
-- server still clamps and step-quantizes as its own invariant.
local function buildSlider(ctx, definition, row)
	local area = Instance.new("Frame")
	area.Name = "Slider"
	area.Position = UDim2.fromOffset(12, ROW_HEIGHT - 2)
	area.Size = UDim2.new(1, -24, 0, 28)
	area.BackgroundTransparency = 1
	area.Active = true
	area.Parent = row

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 0, 0.5, 0)
	track.Size = UDim2.new(1, 0, 0, 6)
	track.BackgroundColor3 = Color3.fromRGB(21, 24, 32)
	track.BorderSizePixel = 0
	track.Parent = area
	addCorner(track, 3)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = ctx.colors.accent
	fill.BorderSizePixel = 0
	fill.Parent = track
	addCorner(fill, 3)

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(0, 0, 0.5, 0)
	knob.Size = UDim2.fromOffset(18, 18)
	knob.BackgroundColor3 = ctx.colors.text
	knob.BorderSizePixel = 0
	knob.ZIndex = 2
	knob.Parent = area
	addCorner(knob, 9)

	local function render(value)
		local alpha = math.clamp((value - definition.min) / (definition.max - definition.min), 0, 1)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
	end

	local function valueFromX(x)
		local width = math.max(track.AbsoluteSize.X, 1)
		local alpha = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
		local value = definition.min + alpha * (definition.max - definition.min)
		local step = definition.step
		if type(step) == "number" and step > 0 then
			value = definition.min + math.round((value - definition.min) / step) * step
		end
		return math.clamp(value, definition.min, definition.max)
	end

	local dragging = false
	local lastSent = nil
	local lastSendClock = 0

	local function handle(x, final)
		local value = valueFromX(x)
		render(value)
		if final then
			if value ~= lastSent then
				lastSent = value
				submitAsync(ctx, definition, value)
			end
		elseif value ~= lastSent and os.clock() - lastSendClock > 0.15 then
			lastSent = value
			lastSendClock = os.clock()
			submitAsync(ctx, definition, value)
		end
	end

	table.insert(
		ctx.connections,
		area.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = true
				handle(input.Position.X, false)
			end
		end)
	)
	table.insert(
		ctx.connections,
		UserInputService.InputChanged:Connect(function(input)
			if
				dragging
				and (
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				handle(input.Position.X, false)
			end
		end)
	)
	table.insert(
		ctx.connections,
		UserInputService.InputEnded:Connect(function(input)
			if
				dragging
				and (
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				dragging = false
				handle(input.Position.X, true)
			end
		end)
	)

	return render
end

local function buildValueControl(ctx, definition, valueArea, rowState)
	if definition.kind == "boolean" then
		local toggle = makeButton("ValueButton", "", valueArea, ctx)
		toggle.Size = UDim2.new(1, 0, 1, 0)
		local toggleStroke = toggle:FindFirstChildOfClass("UIStroke")
		table.insert(
			ctx.connections,
			toggle.Activated:Connect(function()
				submitAsync(ctx, definition, rowState.value ~= true)
			end)
		)
		return function(value)
			toggle.Text = value and "ON" or "OFF"
			toggle.TextColor3 = value and ctx.colors.accent or ctx.colors.muted
			if toggleStroke then
				toggleStroke.Color = value and ctx.colors.accent or ctx.colors.border
			end
		end
	elseif definition.kind == "enum" then
		local selector = makeButton("ValueButton", "", valueArea, ctx)
		selector.Size = UDim2.new(1, 0, 1, 0)
		table.insert(
			ctx.connections,
			selector.Activated:Connect(function()
				local nextIndex = 1
				for index, option in ipairs(definition.options) do
					if option == rowState.value then
						nextIndex = (index % #definition.options) + 1
						break
					end
				end
				submitAsync(ctx, definition, definition.options[nextIndex])
			end)
		)
		return function(value)
			selector.Text = value.Name .. "  \u{25B8}"
		end
	elseif definition.kind == "string" then
		local box = makeTextBox("ValueBox", valueArea, ctx)
		box.Size = UDim2.new(1, -84, 1, 0)
		local apply = makeButton("ApplyButton", "Apply", valueArea, ctx)
		apply.AnchorPoint = Vector2.new(1, 0)
		apply.Position = UDim2.fromScale(1, 0)
		apply.Size = UDim2.fromOffset(76, CONTROL_HEIGHT)
		table.insert(
			ctx.connections,
			apply.Activated:Connect(function()
				submitAsync(ctx, definition, box.Text)
			end)
		)
		return function(value)
			box.Text = value
		end
	elseif definition.kind == "Color3" then
		local box = makeTextBox("ValueBox", valueArea, ctx)
		box.Size = UDim2.new(1, -84, 1, 0)
		local apply = makeButton("ApplyButton", "Apply", valueArea, ctx)
		apply.AnchorPoint = Vector2.new(1, 0)
		apply.Position = UDim2.new(1, 0, 0, 0)
		apply.Size = UDim2.fromOffset(76, CONTROL_HEIGHT)
		table.insert(
			ctx.connections,
			apply.Activated:Connect(function()
				local parsed = parseColor(box.Text)
				if parsed then
					submitAsync(ctx, definition, parsed)
				else
					ctx.setStatus("Use Color3 as R, G, B values from 0 to 255.", true)
				end
			end)
		)
		return function(value)
			box.Text = formatColor(value)
		end
	else
		local box = makeTextBox("ValueBox", valueArea, ctx)
		box.Size = UDim2.new(1, -84, 1, 0)
		local apply = makeButton("ApplyButton", "Apply", valueArea, ctx)
		apply.AnchorPoint = Vector2.new(1, 0)
		apply.Position = UDim2.new(1, 0, 0, 0)
		apply.Size = UDim2.fromOffset(76, CONTROL_HEIGHT)
		table.insert(
			ctx.connections,
			apply.Activated:Connect(function()
				local candidate = tonumber(box.Text)
				if candidate then
					submitAsync(ctx, definition, candidate)
				else
					ctx.setStatus("Enter a valid number for " .. definition.fullId .. ".", true)
				end
			end)
		)
		local renderSlider = nil
		if sliderEligible(definition) then
			renderSlider = buildSlider(ctx, definition, valueArea.Parent)
		end
		return function(value)
			box.Text = formatNumber(value)
			if renderSlider then
				renderSlider(value)
			end
		end
	end
end

local function buildRow(ctx, definition, parent, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = definition.key
	row.LayoutOrder = layoutOrder
	row.Size = UDim2.new(1, 0, 0, sliderEligible(definition) and SLIDER_ROW_HEIGHT or ROW_HEIGHT)
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Parent = parent

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.Position = UDim2.fromOffset(12, 8)
	-- Keep the header column clear of the 92px Default button (plus margins) so
	-- text never runs underneath it.
	name.Size = UDim2.new(1, -124, 0, 22)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.ArialBold
	name.Text = definition.key .. "  [" .. definition.scope .. "]"
	name.TextColor3 = ctx.colors.text
	name.TextSize = 15
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Parent = row

	local description = Instance.new("TextLabel")
	description.Name = "Description"
	description.Position = UDim2.fromOffset(12, 31)
	description.Size = UDim2.new(1, -124, 0, 30)
	description.BackgroundTransparency = 1
	description.Font = Enum.Font.Arial
	description.Text = definition.description
	description.TextColor3 = ctx.colors.muted
	description.TextSize = 13
	description.TextWrapped = true
	description.TextXAlignment = Enum.TextXAlignment.Left
	description.TextYAlignment = Enum.TextYAlignment.Top
	description.Parent = row

	local reset = makeButton("ResetButton", "Default", row, ctx)
	reset.AnchorPoint = Vector2.new(1, 0)
	reset.Position = UDim2.new(1, -10, 0, 8)
	reset.Size = UDim2.fromOffset(92, 44)

	local valueArea = Instance.new("Frame")
	valueArea.Name = "ValueArea"
	valueArea.Position = UDim2.fromOffset(10, 64)
	valueArea.Size = UDim2.new(1, -20, 0, CONTROL_HEIGHT)
	valueArea.BackgroundTransparency = 1
	valueArea.Parent = row

	local rowState = { value = definition.default }
	local renderValue = buildValueControl(ctx, definition, valueArea, rowState)
	table.insert(
		ctx.connections,
		reset.Activated:Connect(function()
			submitAsync(ctx, definition, definition.default)
		end)
	)

	local observation = ctx.DevTuning.observe(definition.fullId, function(value)
		rowState.value = value
		renderValue(value)
	end)
	table.insert(ctx.observations, observation)

	local searchText = string.lower(definition.feature .. " " .. definition.key .. " " .. definition.description)
	return {
		instance = row,
		definition = definition,
		searchText = searchText,
	}
end

local function buildFeature(ctx, feature, layoutOrder)
	local group = Instance.new("Frame")
	group.Name = feature.name
	group.LayoutOrder = layoutOrder
	group.Size = UDim2.new(1, -4, 0, 0)
	group.AutomaticSize = Enum.AutomaticSize.Y
	group.BackgroundTransparency = 1
	group.Parent = ctx.content

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 7)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = group

	-- 1px hairline separating this section from the previous one.
	local separator = Instance.new("Frame")
	separator.Name = "Separator"
	separator.LayoutOrder = -1
	separator.Size = UDim2.new(1, 0, 0, 1)
	separator.BackgroundColor3 = ctx.colors.border
	separator.BackgroundTransparency = 0.4
	separator.BorderSizePixel = 0
	separator.Parent = group

	local heading = Instance.new("TextButton")
	heading.Name = "Heading"
	heading.LayoutOrder = 0
	heading.Size = UDim2.new(1, 0, 0, 30)
	heading.AutoButtonColor = false
	heading.BackgroundTransparency = 1
	heading.BorderSizePixel = 0
	heading.Font = Enum.Font.ArialBold
	heading.TextColor3 = ctx.colors.text
	heading.TextSize = 17
	heading.TextXAlignment = Enum.TextXAlignment.Left
	heading.Parent = group

	local groupRecord = {
		instance = group,
		heading = heading,
		collapsed = feature.collapsedByDefault == true,
		rows = {},
	}
	for index, definition in ipairs(feature.tunables) do
		local rowRecord = buildRow(ctx, definition, group, index)
		table.insert(groupRecord.rows, rowRecord)
		table.insert(ctx.rows, rowRecord)
	end

	local function updateHeading()
		heading.Text = "  " .. feature.name .. (groupRecord.collapsed and "  [Show]" or "  [Hide]")
		heading.TextColor3 = groupRecord.collapsed and ctx.colors.muted or ctx.colors.text
	end
	for _, row in ipairs(groupRecord.rows) do
		row.instance.Visible = not groupRecord.collapsed
	end
	updateHeading()
	table.insert(
		ctx.connections,
		heading.Activated:Connect(function()
			groupRecord.collapsed = not groupRecord.collapsed
			updateHeading()
			DevTuningControls.applySearch(ctx, ctx.searchQuery or "")
		end)
	)
	return groupRecord
end

function DevTuningControls.mount(ctx)
	ctx.searchQuery = ""
	for index, feature in ipairs(ctx.catalog.features) do
		table.insert(ctx.groups, buildFeature(ctx, feature, index))
	end
end

function DevTuningControls.applySearch(ctx, query)
	query = string.lower(query or "")
	ctx.searchQuery = query
	for _, group in ipairs(ctx.groups) do
		local anyMatch = false
		for _, row in ipairs(group.rows) do
			local matches = query == "" or string.find(row.searchText, query, 1, true) ~= nil
			local visible = matches and (query ~= "" or not group.collapsed)
			row.instance.Visible = visible
			anyMatch = anyMatch or matches
		end
		-- With no search, keep collapsed headers visible so they can be reopened.
		-- Active searches temporarily expose matching rows without changing collapse state.
		group.instance.Visible = query == "" or anyMatch
	end
end

function DevTuningControls.resetAll(ctx)
	if ctx.resettingAll then
		return
	end
	ctx.resettingAll = true
	task.spawn(function()
		for _, row in ipairs(ctx.rows) do
			submit(ctx, row.definition, row.definition.default)
		end
		ctx.resettingAll = false
		ctx.setStatus("All tunables reset to registry defaults.", false)
	end)
end

return DevTuningControls
