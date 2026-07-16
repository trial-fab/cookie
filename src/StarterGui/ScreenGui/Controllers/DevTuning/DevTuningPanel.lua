-- DevTuningPanel: constructs the exempt dev-tooling shell and responsive safe-area layout.

local DevTuningPanel = {}

local COLORS = {
	background = Color3.fromRGB(18, 20, 27),
	surface = Color3.fromRGB(29, 33, 43),
	border = Color3.fromRGB(72, 83, 108),
	accent = Color3.fromRGB(74, 141, 255),
	text = Color3.fromRGB(242, 245, 252),
	muted = Color3.fromRGB(166, 175, 194),
}

local function addCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addStroke(parent)
	local stroke = Instance.new("UIStroke")
	stroke.Color = COLORS.border
	stroke.Transparency = 0.2
	stroke.Thickness = 2
	stroke.Parent = parent
end

local function makeButton(name, text, parent)
	local button = Instance.new("TextButton")
	button.Name = name
	button.AutoButtonColor = true
	button.BackgroundColor3 = COLORS.surface
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Font = Enum.Font.ArialBold
	button.Text = text
	button.TextColor3 = COLORS.text
	button.TextSize = 15
	button.Parent = parent
	addCorner(button, 8)
	addStroke(button)
	return button
end

function DevTuningPanel.create(ctx)
	local gui = Instance.new("ScreenGui")
	gui.Name = ctx.guiName
	gui.DisplayOrder = 1100
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.ClipToDeviceSafeArea = true

	local shutdown = Instance.new("BindableEvent")
	shutdown.Name = "Shutdown"
	shutdown.Parent = gui

	local gear = makeButton("EntryButton", "\u{2699}", gui)
	gear.AnchorPoint = Vector2.new(1, 0)
	gear.Position = UDim2.new(1, -12, 0, 60)
	gear.Size = UDim2.fromOffset(48, 48)
	gear.BackgroundColor3 = COLORS.background
	gear.BackgroundTransparency = 0.5
	gear.TextSize = 26
	gear.ZIndex = 2

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(1, -24, 1, -88)
	panel.BackgroundColor3 = COLORS.background
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = gui
	addCorner(panel, 12)
	addStroke(panel)

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(280, 340)
	sizeConstraint.MaxSize = Vector2.new(960, 1080)
	sizeConstraint.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.fromOffset(16, 8)
	title.Size = UDim2.new(1, -80, 0, 44)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.ArialBold
	title.Text = "Dev Tuning"
	title.TextColor3 = COLORS.text
	title.TextSize = 24
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = panel

	local close = makeButton("CloseButton", "X", panel)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -8, 0, 8)
	close.Size = UDim2.fromOffset(44, 44)

	local search = Instance.new("TextBox")
	search.Name = "SearchBox"
	search.Position = UDim2.fromOffset(12, 60)
	search.Size = UDim2.new(1, -172, 0, 44)
	search.BackgroundColor3 = COLORS.surface
	search.BackgroundTransparency = 1
	search.BorderSizePixel = 0
	search.ClearTextOnFocus = false
	search.Font = Enum.Font.Arial
	search.PlaceholderColor3 = COLORS.muted
	search.PlaceholderText = "Search feature, key, or description"
	search.Text = ""
	search.TextColor3 = COLORS.text
	search.TextSize = 15
	search.TextXAlignment = Enum.TextXAlignment.Left
	search.Parent = panel
	addCorner(search, 8)
	addStroke(search)

	local searchPadding = Instance.new("UIPadding")
	searchPadding.PaddingLeft = UDim.new(0, 12)
	searchPadding.PaddingRight = UDim.new(0, 12)
	searchPadding.Parent = search

	local resetAll = makeButton("ResetAllButton", "Reset all", panel)
	resetAll.AnchorPoint = Vector2.new(1, 0)
	resetAll.Position = UDim2.new(1, -12, 0, 60)
	resetAll.Size = UDim2.fromOffset(140, 44)

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Position = UDim2.fromOffset(14, 108)
	status.Size = UDim2.new(1, -28, 0, 24)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.Arial
	status.Text = "Live values are local to this server."
	status.TextColor3 = COLORS.muted
	status.TextSize = 13
	status.TextTruncate = Enum.TextTruncate.AtEnd
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Parent = panel

	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(12, 136)
	content.Size = UDim2.new(1, -24, 1, -148)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.CanvasSize = UDim2.new()
	content.ScrollBarImageColor3 = COLORS.border
	content.ScrollBarThickness = 8
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.Parent = panel

	local contentLayout = Instance.new("UIListLayout")
	contentLayout.Padding = UDim.new(0, 10)
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Parent = content

	local contentPadding = Instance.new("UIPadding")
	contentPadding.PaddingBottom = UDim.new(0, 4)
	contentPadding.PaddingRight = UDim.new(0, 4)
	contentPadding.Parent = content

	ctx.gui = gui
	ctx.shutdown = shutdown
	ctx.panel = panel
	ctx.search = search
	ctx.status = status
	ctx.content = content
	ctx.colors = COLORS
	ctx.setStatus = function(message, isError)
		status.Text = message
		status.TextColor3 = isError and Color3.fromRGB(255, 128, 128) or COLORS.muted
	end

	table.insert(
		ctx.connections,
		gear.Activated:Connect(function()
			panel.Visible = not panel.Visible
		end)
	)
	table.insert(
		ctx.connections,
		close.Activated:Connect(function()
			panel.Visible = false
		end)
	)
	table.insert(
		ctx.connections,
		search:GetPropertyChangedSignal("Text"):Connect(function()
			ctx.controls.applySearch(ctx, search.Text)
		end)
	)
	table.insert(
		ctx.connections,
		resetAll.Activated:Connect(function()
			ctx.controls.resetAll(ctx)
		end)
	)

	gui.Parent = ctx.playerGui
end

return DevTuningPanel
