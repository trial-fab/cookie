-- DevTuningControls: generated feature groups, typed controls, search, and server applies.

local DevTuningControls = {}

local ROW_HEIGHT = 112
local CONTROL_HEIGHT = 40

local function addCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addStroke(parent, color)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Transparency = 0.25
	stroke.Thickness = 1
	stroke.Parent = parent
end

local function makeButton(name, text, parent, ctx)
	local button = Instance.new("TextButton")
	button.Name = name
	button.AutoButtonColor = true
	button.BackgroundColor3 = ctx.colors.surface
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

local function buildValueControl(ctx, definition, valueArea, rowState)
	if definition.kind == "boolean" then
		local toggle = makeButton("ValueButton", "", valueArea, ctx)
		toggle.Size = UDim2.new(1, 0, 1, 0)
		table.insert(
			ctx.connections,
			toggle.Activated:Connect(function()
				submitAsync(ctx, definition, rowState.value ~= true)
			end)
		)
		return function(value)
			toggle.Text = value and "ON" or "OFF"
			toggle.BackgroundColor3 = value and ctx.colors.accent or ctx.colors.surface
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
		return function(value)
			box.Text = formatNumber(value)
		end
	end
end

local function buildRow(ctx, definition, parent, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = definition.key
	row.LayoutOrder = layoutOrder
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundColor3 = ctx.colors.surface
	row.BorderSizePixel = 0
	row.Parent = parent
	addCorner(row, 9)
	addStroke(row, ctx.colors.border)

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.Position = UDim2.fromOffset(12, 8)
	name.Size = UDim2.new(1, -114, 0, 22)
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
	description.Size = UDim2.new(1, -24, 0, 30)
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

	local heading = Instance.new("TextLabel")
	heading.Name = "Heading"
	heading.LayoutOrder = 0
	heading.Size = UDim2.new(1, 0, 0, 34)
	heading.BackgroundColor3 = Color3.fromRGB(36, 42, 55)
	heading.BorderSizePixel = 0
	heading.Font = Enum.Font.ArialBold
	heading.Text = "  " .. feature.name
	heading.TextColor3 = ctx.colors.text
	heading.TextSize = 17
	heading.TextXAlignment = Enum.TextXAlignment.Left
	heading.Parent = group
	addCorner(heading, 8)

	local groupRecord = {
		instance = group,
		rows = {},
	}
	for index, definition in ipairs(feature.tunables) do
		local rowRecord = buildRow(ctx, definition, group, index)
		table.insert(groupRecord.rows, rowRecord)
		table.insert(ctx.rows, rowRecord)
	end
	return groupRecord
end

function DevTuningControls.mount(ctx)
	for index, feature in ipairs(ctx.catalog.features) do
		table.insert(ctx.groups, buildFeature(ctx, feature, index))
	end
end

function DevTuningControls.applySearch(ctx, query)
	query = string.lower(query or "")
	for _, group in ipairs(ctx.groups) do
		local anyVisible = false
		for _, row in ipairs(group.rows) do
			local visible = query == "" or string.find(row.searchText, query, 1, true) ~= nil
			row.instance.Visible = visible
			anyVisible = anyVisible or visible
		end
		group.instance.Visible = anyVisible
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
