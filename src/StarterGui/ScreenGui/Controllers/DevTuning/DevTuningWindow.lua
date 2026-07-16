-- DevTuningWindow: drag and resize behavior for the dev panel shell (dev-only tooling,
-- exempt from the Studio-authored-UI rule like the rest of the panel).

local UserInputService = game:GetService("UserInputService")

local DevTuningWindow = {}

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
end

function DevTuningWindow.attach(ctx)
	local panel = ctx.panel
	local gui = ctx.gui

	-- The shell is authored as a centered, scale-sized frame. Convert to top-left
	-- offset geometry on first interaction so drag/resize deltas apply predictably
	-- and the panel stays where it was put on later viewport changes.
	local function toOffsetGeometry()
		if panel.AnchorPoint ~= Vector2.new(0, 0) then
			local absolutePosition = panel.AbsolutePosition
			local absoluteSize = panel.AbsoluteSize
			panel.AnchorPoint = Vector2.new(0, 0)
			panel.Position = UDim2.fromOffset(absolutePosition.X, absolutePosition.Y)
			panel.Size = UDim2.fromOffset(absoluteSize.X, absoluteSize.Y)
		end
	end

	local function beginTrack(input, onDelta)
		local startPoint = input.Position
		local moveConnection, endConnection
		moveConnection = UserInputService.InputChanged:Connect(function(moved)
			if isMove(moved) then
				onDelta(Vector2.new(moved.Position.X - startPoint.X, moved.Position.Y - startPoint.Y))
			end
		end)
		endConnection = UserInputService.InputEnded:Connect(function(ended)
			if isPress(ended) then
				moveConnection:Disconnect()
				endConnection:Disconnect()
			end
		end)
		table.insert(ctx.connections, moveConnection)
		table.insert(ctx.connections, endConnection)
	end

	local dragHandle = Instance.new("TextButton")
	dragHandle.Name = "DragHandle"
	dragHandle.BackgroundTransparency = 1
	dragHandle.Text = ""
	dragHandle.Position = UDim2.fromOffset(0, 0)
	dragHandle.Size = UDim2.new(1, -120, 0, 52)
	dragHandle.ZIndex = 5
	dragHandle.Parent = panel

	table.insert(
		ctx.connections,
		dragHandle.InputBegan:Connect(function(input)
			if not isPress(input) then
				return
			end
			toOffsetGeometry()
			local origin = panel.AbsolutePosition
			beginTrack(input, function(delta)
				-- Keep at least a grabbable sliver of the panel on screen.
				local x = math.clamp(origin.X + delta.X, 60 - panel.AbsoluteSize.X, gui.AbsoluteSize.X - 60)
				local y = math.clamp(origin.Y + delta.Y, 0, gui.AbsoluteSize.Y - 48)
				panel.Position = UDim2.fromOffset(x, y)
			end)
		end)
	)

	local grip = Instance.new("TextButton")
	grip.Name = "ResizeGrip"
	grip.AnchorPoint = Vector2.new(1, 1)
	grip.Position = UDim2.new(1, -2, 1, -2)
	grip.Size = UDim2.fromOffset(26, 26)
	grip.BackgroundColor3 = ctx.colors.surface
	grip.BackgroundTransparency = 0.3
	grip.BorderSizePixel = 0
	grip.Font = Enum.Font.ArialBold
	grip.Text = "\u{25E2}"
	grip.TextColor3 = ctx.colors.muted
	grip.TextSize = 14
	grip.ZIndex = 6
	grip.Parent = panel
	local gripCorner = Instance.new("UICorner")
	gripCorner.CornerRadius = UDim.new(0, 6)
	gripCorner.Parent = grip

	table.insert(
		ctx.connections,
		grip.InputBegan:Connect(function(input)
			if not isPress(input) then
				return
			end
			toOffsetGeometry()
			local startSize = panel.AbsoluteSize
			beginTrack(input, function(delta)
				-- The shell's UISizeConstraint clamps the extremes.
				panel.Size = UDim2.fromOffset(startSize.X + delta.X, startSize.Y + delta.Y)
			end)
		end)
	)
end

return DevTuningWindow
