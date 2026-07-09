-- Positions a Studio-authored BuildModeFrame immediately after Roblox's dynamic top-left
-- CoreGui controls. GuiService.TopbarInset accounts for controls like the optional mic button.
-- The parent ScreenGui uses TopbarSafeInsets, so its local origin is already the free topbar
-- space after Roblox's own buttons. Keep this frame 8px from that local origin.

local GuiService = game:GetService("GuiService")

local BuildModeTopbarPosition = {}

local GAP_PX = 8
local Y_OFFSET_PX = 12

local function applyPosition(frame)
	if not frame or not frame:IsA("GuiObject") then
		return
	end

	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = UDim2.fromOffset(GAP_PX, Y_OFFSET_PX)
end

local function configureTopbarGui(frame)
	local gui = frame:FindFirstAncestorOfClass("ScreenGui")
	if not gui then
		return
	end

	gui.ScreenInsets = Enum.ScreenInsets.TopbarSafeInsets
	gui.ClipToDeviceSafeArea = true
	gui.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
end

function BuildModeTopbarPosition.bind(frame)
	if not frame or not frame:IsA("GuiObject") then
		return nil
	end

	configureTopbarGui(frame)

	local connections = {}
	local function refresh()
		applyPosition(frame)
	end

	table.insert(connections, GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(refresh))
	table.insert(connections, frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(refresh))
	table.insert(connections, frame:GetPropertyChangedSignal("AnchorPoint"):Connect(refresh))

	refresh()
	task.defer(refresh)

	return {
		refresh = refresh,
		destroy = function()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			table.clear(connections)
		end,
	}
end

return BuildModeTopbarPosition
